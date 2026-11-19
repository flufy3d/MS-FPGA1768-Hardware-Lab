//
// pcie_bar.c — minimal KMDF function driver for the lab's PCIe endpoints
// (projects/02_pcie_pio and later, PCI\VEN_1172&DEV_E003).
//
// Maps BAR0, validates the design ID register, and exposes IOCTLs to a
// user-mode client:
//
//   IOCTL_PCIE_BAR_GET_INFO   -> PCIE_BAR_INFO
//   IOCTL_PCIE_BAR_READ32     -> PCIE_BAR_ACCESS { Offset, Value }
//   IOCTL_PCIE_BAR_WRITE32    -> PCIE_BAR_ACCESS { Offset, Value }
//   added in 1.1 (2026-11-19, for projects/07_dma):
//   IOCTL_PCIE_BAR_CFG_READ32 -> PCIE_BAR_ACCESS, PCI configuration space, read only
//   IOCTL_PCIE_BAR_DMA_INFO   -> PCIE_DMA_INFO
//   IOCTL_PCIE_BAR_DMA_ALLOC  -> PCIE_DMA_CHUNKS: 4 MB common buffers mapped
//                                into the caller (64-bit DMA enabler)
//   IOCTL_PCIE_BAR_DMA_FREE
//
// Only 4-byte aligned accesses inside the mapped BAR are accepted. Writes are
// refused unless the ID register matched at start, so a wrong or unassigned BAR
// cannot be written by accident.
//
// DMA: the driver only provides memory. It creates a scatter/gather 64-bit DMA
// enabler (so common buffers may lie above 4 GB), allocates physically
// contiguous 4 MB common buffers on request and maps them into the calling
// process. The user-mode tool programs the device's descriptor engine through
// BAR0 with the bus addresses returned here and polls a status word that the
// device writes into one of the buffers; no interrupts are used. The pool
// belongs to the file handle that allocated it and is unmapped and freed by
// DMA_FREE, when that handle is closed, or when the device stops. ALLOC and
// FREE run in the caller's context (EvtIoInCallerContext) because the user
// mapping must be made in, and removed from, that process.
//

#include <ntifs.h>        // includes ntddk.h; KeStackAttachProcess, KAPC_STATE
#include <wdf.h>
#include <initguid.h>
#include <wdmguid.h>
#include "pcie_bar.h"

static const GUID g_PcieBarInterfaceGuid = GUID_DEVINTERFACE_PCIE_BAR;

typedef struct _DMA_POOL_ENTRY {
    WDFCOMMONBUFFER   Buffer;
    PMDL              Mdl;
    PVOID             UserVa;
    PHYSICAL_ADDRESS  Bus;
} DMA_POOL_ENTRY;

typedef struct _DEVICE_CONTEXT {
    PVOID             BarBase;
    ULONG             BarLength;
    PHYSICAL_ADDRESS  BarPhysical;
    ULONG             BarValid;

    // 1.1: configuration space access and DMA
    BUS_INTERFACE_STANDARD BusIf;
    BOOLEAN           BusIfValid;
    WDFDMAENABLER     DmaEnabler;
    WDFWAITLOCK       PoolLock;
    ULONG             PoolCount;
    DMA_POOL_ENTRY    Pool[PCIE_DMA_MAX_CHUNKS];
    WDFFILEOBJECT     PoolOwner;
    PEPROCESS         PoolProcess;
} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, PcieBarGetContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD PcieBarEvtDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE PcieBarEvtDevicePrepareHardware;
EVT_WDF_DEVICE_RELEASE_HARDWARE PcieBarEvtDeviceReleaseHardware;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL PcieBarEvtIoDeviceControl;
EVT_WDF_IO_IN_CALLER_CONTEXT PcieBarEvtIoInCallerContext;
EVT_WDF_FILE_CLEANUP PcieBarEvtFileCleanup;

static VOID PcieBarDmaFreeLocked(_In_ PDEVICE_CONTEXT Context);

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    NTSTATUS status;

    WDF_DRIVER_CONFIG_INIT(&config, PcieBarEvtDeviceAdd);

    status = WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        WDF_NO_HANDLE);

    return status;
}

NTSTATUS
PcieBarEvtDeviceAdd(
    _In_ WDFDRIVER       Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnpPowerCallbacks;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    WDF_FILEOBJECT_CONFIG fileConfig;
    WDF_DMA_ENABLER_CONFIG dmaConfig;
    WDFDEVICE device;
    PDEVICE_CONTEXT context;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpPowerCallbacks);
    pnpPowerCallbacks.EvtDevicePrepareHardware = PcieBarEvtDevicePrepareHardware;
    pnpPowerCallbacks.EvtDeviceReleaseHardware = PcieBarEvtDeviceReleaseHardware;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpPowerCallbacks);

    WdfDeviceInitSetIoType(DeviceInit, WdfDeviceIoBuffered);

    // 1.1: the DMA pool belongs to a file handle; ALLOC/FREE need the
    // caller's process context.
    WDF_FILEOBJECT_CONFIG_INIT(&fileConfig, WDF_NO_EVENT_CALLBACK,
                               WDF_NO_EVENT_CALLBACK, PcieBarEvtFileCleanup);
    WdfDeviceInitSetFileObjectConfig(DeviceInit, &fileConfig, WDF_NO_OBJECT_ATTRIBUTES);
    WdfDeviceInitSetIoInCallerContextCallback(DeviceInit, PcieBarEvtIoInCallerContext);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, DEVICE_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    context = PcieBarGetContext(device);
    RtlZeroMemory(context, sizeof(*context));

    status = WdfWaitLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &context->PoolLock);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    // 64-bit scatter/gather DMA enabler, used for common buffers only. If it
    // cannot be created, BAR0 access still works and DMA_ALLOC reports
    // STATUS_INVALID_DEVICE_STATE.
    WDF_DMA_ENABLER_CONFIG_INIT(&dmaConfig, WdfDmaProfileScatterGather64,
                                PCIE_DMA_CHUNK_BYTES);
    status = WdfDmaEnablerCreate(device, &dmaConfig, WDF_NO_OBJECT_ATTRIBUTES,
                                 &context->DmaEnabler);
    if (!NT_SUCCESS(status)) {
        context->DmaEnabler = NULL;
    }

    status = WdfDeviceCreateDeviceInterface(
        device,
        &g_PcieBarInterfaceGuid,
        NULL);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchSequential);
    queueConfig.EvtIoDeviceControl = PcieBarEvtIoDeviceControl;

    status = WdfIoQueueCreate(
        device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);

    return status;
}

NTSTATUS
PcieBarEvtDevicePrepareHardware(
    _In_ WDFDEVICE     Device,
    _In_ WDFCMRESLIST  ResourcesRaw,
    _In_ WDFCMRESLIST  ResourcesTranslated
    )
{
    PDEVICE_CONTEXT context = PcieBarGetContext(Device);
    ULONG count;
    ULONG index;

    UNREFERENCED_PARAMETER(ResourcesRaw);

    // 1.1: configuration space access through the PCI bus driver.
    if (NT_SUCCESS(WdfFdoQueryForInterface(Device, &GUID_BUS_INTERFACE_STANDARD,
                                           (PINTERFACE)&context->BusIf,
                                           sizeof(BUS_INTERFACE_STANDARD), 1, NULL))) {
        context->BusIfValid = TRUE;
    }

    count = WdfCmResourceListGetCount(ResourcesTranslated);

    for (index = 0; index < count; index++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR descriptor =
            WdfCmResourceListGetDescriptor(ResourcesTranslated, index);

        if (descriptor == NULL) {
            continue;
        }

        if (descriptor->Type != CmResourceTypeMemory) {
            continue;
        }

        if (descriptor->u.Memory.Length < 0x1000) {
            continue;
        }

        context->BarPhysical = descriptor->u.Memory.Start;
        context->BarLength = descriptor->u.Memory.Length;
        context->BarBase = MmMapIoSpace(
            descriptor->u.Memory.Start,
            descriptor->u.Memory.Length,
            MmNonCached);

        if (context->BarBase == NULL) {
            context->BarPhysical.QuadPart = 0;
            context->BarLength = 0;
            // Start anyway: the client reports "mapped=0" instead of the whole
            // device failing to start.
            return STATUS_SUCCESS;
        }

        // The design puts a fixed ID at BAR0 + 0x40. Only a matching ID makes
        // the write IOCTL legal; a wrong/unassigned BAR stays read-only.
        if (context->BarLength >= 0x44) {
            ULONG id = READ_REGISTER_ULONG(
                (PULONG)((PUCHAR)context->BarBase + 0x40));
            context->BarValid = (id == PCIE_BAR_ID_VALUE) ? 1 : 0;
        } else {
            context->BarValid = 0;
        }

        return STATUS_SUCCESS;
    }

    // No memory BAR was assigned to this function (typical after a PCIe hot-add
    // on this host). Start anyway so the user-mode client can report it:
    // GET_INFO returns BarLength=0 and Mapped=0.
    context->BarBase = NULL;
    context->BarLength = 0;
    context->BarPhysical.QuadPart = 0;
    context->BarValid = 0;

    return STATUS_SUCCESS;
}

NTSTATUS
PcieBarEvtDeviceReleaseHardware(
    _In_ WDFDEVICE     Device,
    _In_ WDFCMRESLIST  ResourcesTranslated
    )
{
    PDEVICE_CONTEXT context = PcieBarGetContext(Device);

    UNREFERENCED_PARAMETER(ResourcesTranslated);

    WdfWaitLockAcquire(context->PoolLock, NULL);
    PcieBarDmaFreeLocked(context);
    WdfWaitLockRelease(context->PoolLock);

    if (context->BusIfValid) {
        context->BusIf.InterfaceDereference(context->BusIf.Context);
        context->BusIfValid = FALSE;
    }

    if (context->BarBase != NULL) {
        MmUnmapIoSpace(context->BarBase, context->BarLength);
        context->BarBase = NULL;
        context->BarLength = 0;
        context->BarPhysical.QuadPart = 0;
        context->BarValid = 0;
    }

    return STATUS_SUCCESS;
}

static BOOLEAN
PcieBarOffsetValid(
    _In_ PDEVICE_CONTEXT Context,
    _In_ ULONG Offset
    )
{
    if (Context->BarBase == NULL) {
        return FALSE;
    }

    if (Context->BarLength < sizeof(ULONG)) {
        return FALSE;
    }

    if ((Offset & (sizeof(ULONG) - 1)) != 0) {
        return FALSE;
    }

    if (Offset > (Context->BarLength - sizeof(ULONG))) {
        return FALSE;
    }

    return TRUE;
}

//
// ------------------------------------------------- 1.1: config space and DMA
//

// Returns the number of bytes read (4 on success).
static ULONG
PcieBarCfgRead32(
    _In_ PDEVICE_CONTEXT Context,
    _In_ ULONG Offset,
    _Out_ PULONG Value
    )
{
    *Value = 0xFFFFFFFF;
    if (!Context->BusIfValid) {
        return 0;
    }
    return Context->BusIf.GetBusData(Context->BusIf.Context, PCI_WHICHSPACE_CONFIG,
                                     Value, Offset, sizeof(ULONG));
}

// Set the bus master enable bit of the command register if it is clear.
static VOID
PcieBarEnableBusMaster(
    _In_ PDEVICE_CONTEXT Context
    )
{
    USHORT command = 0;

    if (!Context->BusIfValid) {
        return;
    }
    if (Context->BusIf.GetBusData(Context->BusIf.Context, PCI_WHICHSPACE_CONFIG,
                                  &command, 0x04, sizeof(command)) != sizeof(command)) {
        return;
    }
    if ((command & PCI_ENABLE_BUS_MASTER) == 0) {
        command |= PCI_ENABLE_BUS_MASTER;
        Context->BusIf.SetBusData(Context->BusIf.Context, PCI_WHICHSPACE_CONFIG,
                                  &command, 0x04, sizeof(command));
    }
}

// Unmap and free the pool. PoolLock must be held. Attaches to the owning
// process when called from another context (device stop).
static VOID
PcieBarDmaFreeLocked(
    _In_ PDEVICE_CONTEXT Context
    )
{
    KAPC_STATE apc;
    BOOLEAN attached = FALSE;
    ULONG i;

    if (Context->PoolCount == 0) {
        return;
    }

    if (Context->PoolProcess != NULL && Context->PoolProcess != PsGetCurrentProcess()) {
        KeStackAttachProcess((PRKPROCESS)Context->PoolProcess, &apc);
        attached = TRUE;
    }
    for (i = 0; i < Context->PoolCount; i++) {
        if (Context->Pool[i].UserVa != NULL) {
            MmUnmapLockedPages(Context->Pool[i].UserVa, Context->Pool[i].Mdl);
            Context->Pool[i].UserVa = NULL;
        }
    }
    if (attached) {
        KeUnstackDetachProcess(&apc);
    }

    for (i = 0; i < Context->PoolCount; i++) {
        if (Context->Pool[i].Mdl != NULL) {
            IoFreeMdl(Context->Pool[i].Mdl);
        }
        if (Context->Pool[i].Buffer != NULL) {
            WdfObjectDelete(Context->Pool[i].Buffer);
        }
        RtlZeroMemory(&Context->Pool[i], sizeof(Context->Pool[i]));
    }
    Context->PoolCount = 0;
    Context->PoolOwner = NULL;
    if (Context->PoolProcess != NULL) {
        ObDereferenceObject(Context->PoolProcess);
        Context->PoolProcess = NULL;
    }
}

// Runs in the caller's context (PASSIVE_LEVEL).
static NTSTATUS
PcieBarDmaAlloc(
    _In_ PDEVICE_CONTEXT Context,
    _In_ WDFREQUEST Request,
    _Out_ size_t *Information
    )
{
    PPCIE_DMA_ALLOC in = NULL;
    PPCIE_DMA_CHUNKS out = NULL;
    NTSTATUS status;
    ULONG count;
    ULONG i;

    *Information = 0;

    if (Context->DmaEnabler == NULL || Context->BarBase == NULL || !Context->BarValid) {
        return STATUS_INVALID_DEVICE_STATE;
    }
    status = WdfRequestRetrieveInputBuffer(Request, sizeof(*in), (PVOID*)&in, NULL);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    status = WdfRequestRetrieveOutputBuffer(Request, sizeof(*out), (PVOID*)&out, NULL);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    // in and out share the system buffer (METHOD_BUFFERED): copy the input first.
    count = in->ChunkCount;
    if (count == 0 || count > PCIE_DMA_MAX_CHUNKS) {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(Context->PoolLock, NULL);

    if (Context->PoolCount != 0) {
        WdfWaitLockRelease(Context->PoolLock);
        return STATUS_DEVICE_BUSY;
    }

    PcieBarEnableBusMaster(Context);

    Context->PoolProcess = PsGetCurrentProcess();
    ObReferenceObject(Context->PoolProcess);
    Context->PoolOwner = WdfRequestGetFileObject(Request);

    status = STATUS_SUCCESS;
    for (i = 0; i < count; i++) {
        DMA_POOL_ENTRY *e = &Context->Pool[i];
        PVOID va;

        Context->PoolCount = i + 1;
        status = WdfCommonBufferCreate(Context->DmaEnabler, PCIE_DMA_CHUNK_BYTES,
                                       WDF_NO_OBJECT_ATTRIBUTES, &e->Buffer);
        if (!NT_SUCCESS(status)) {
            e->Buffer = NULL;
            break;
        }
        va     = WdfCommonBufferGetAlignedVirtualAddress(e->Buffer);
        e->Bus = WdfCommonBufferGetAlignedLogicalAddress(e->Buffer);
        RtlZeroMemory(va, PCIE_DMA_CHUNK_BYTES);

        e->Mdl = IoAllocateMdl(va, PCIE_DMA_CHUNK_BYTES, FALSE, FALSE, NULL);
        if (e->Mdl == NULL) {
            status = STATUS_INSUFFICIENT_RESOURCES;
            break;
        }
        MmBuildMdlForNonPagedPool(e->Mdl);

        __try {
            e->UserVa = MmMapLockedPagesSpecifyCache(e->Mdl, UserMode, MmCached, NULL,
                                                     FALSE,
                                                     NormalPagePriority | MdlMappingNoExecute);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            e->UserVa = NULL;
        }
        if (e->UserVa == NULL) {
            status = STATUS_INSUFFICIENT_RESOURCES;
            break;
        }
    }

    if (!NT_SUCCESS(status)) {
        PcieBarDmaFreeLocked(Context);
        WdfWaitLockRelease(Context->PoolLock);
        return status;
    }

    RtlZeroMemory(out, sizeof(*out));
    out->Count = Context->PoolCount;
    out->ChunkBytes = PCIE_DMA_CHUNK_BYTES;
    for (i = 0; i < Context->PoolCount; i++) {
        out->Chunk[i].UserAddress = (ULONGLONG)(ULONG_PTR)Context->Pool[i].UserVa;
        out->Chunk[i].BusAddress  = (ULONGLONG)Context->Pool[i].Bus.QuadPart;
    }
    *Information = sizeof(*out);

    WdfWaitLockRelease(Context->PoolLock);
    return STATUS_SUCCESS;
}

VOID
PcieBarEvtIoInCallerContext(
    _In_ WDFDEVICE  Device,
    _In_ WDFREQUEST Request
    )
{
    PDEVICE_CONTEXT context = PcieBarGetContext(Device);
    WDF_REQUEST_PARAMETERS params;
    NTSTATUS status;
    size_t information = 0;

    WDF_REQUEST_PARAMETERS_INIT(&params);
    WdfRequestGetParameters(Request, &params);

    if (params.Type == WdfRequestTypeDeviceControl &&
        params.Parameters.DeviceIoControl.IoControlCode == IOCTL_PCIE_BAR_DMA_ALLOC) {
        status = PcieBarDmaAlloc(context, Request, &information);
        WdfRequestCompleteWithInformation(Request, status, information);
        return;
    }

    if (params.Type == WdfRequestTypeDeviceControl &&
        params.Parameters.DeviceIoControl.IoControlCode == IOCTL_PCIE_BAR_DMA_FREE) {
        WdfWaitLockAcquire(context->PoolLock, NULL);
        if (context->PoolCount == 0) {
            status = STATUS_SUCCESS;
        } else if (context->PoolOwner != WdfRequestGetFileObject(Request)) {
            status = STATUS_ACCESS_DENIED;
        } else {
            PcieBarDmaFreeLocked(context);
            status = STATUS_SUCCESS;
        }
        WdfWaitLockRelease(context->PoolLock);
        WdfRequestComplete(Request, status);
        return;
    }

    status = WdfDeviceEnqueueRequest(Device, Request);
    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
    }
}

VOID
PcieBarEvtFileCleanup(
    _In_ WDFFILEOBJECT FileObject
    )
{
    PDEVICE_CONTEXT context = PcieBarGetContext(WdfFileObjectGetDevice(FileObject));

    WdfWaitLockAcquire(context->PoolLock, NULL);
    if (context->PoolCount != 0 && context->PoolOwner == FileObject) {
        PcieBarDmaFreeLocked(context);
    }
    WdfWaitLockRelease(context->PoolLock);
}

VOID
PcieBarEvtIoDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
{
    WDFDEVICE device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT context = PcieBarGetContext(device);
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    size_t information = 0;

    switch (IoControlCode) {

    case IOCTL_PCIE_BAR_GET_INFO:
    {
        PPCIE_BAR_INFO info = NULL;

        if (OutputBufferLength < sizeof(PCIE_BAR_INFO)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        status = WdfRequestRetrieveOutputBuffer(
            Request,
            sizeof(PCIE_BAR_INFO),
            (PVOID*)&info,
            NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }

        RtlZeroMemory(info, sizeof(*info));
        info->VendorId = 0x1172;
        info->DeviceId = 0xE003;
        info->BarPhysicalAddress = (ULONGLONG)context->BarPhysical.QuadPart;
        info->BarLength = context->BarLength;
        info->Mapped = (context->BarBase != NULL && context->BarValid) ? 1 : 0;

        information = sizeof(*info);
        status = STATUS_SUCCESS;
        break;
    }

    case IOCTL_PCIE_BAR_READ32:
    {
        PPCIE_BAR_ACCESS input = NULL;
        PPCIE_BAR_ACCESS output = NULL;

        if (InputBufferLength < sizeof(PCIE_BAR_ACCESS) ||
            OutputBufferLength < sizeof(PCIE_BAR_ACCESS)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        status = WdfRequestRetrieveInputBuffer(
            Request,
            sizeof(PCIE_BAR_ACCESS),
            (PVOID*)&input,
            NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }

        status = WdfRequestRetrieveOutputBuffer(
            Request,
            sizeof(PCIE_BAR_ACCESS),
            (PVOID*)&output,
            NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }

        if (!PcieBarOffsetValid(context, input->Offset)) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        output->Offset = input->Offset;
        output->Value = READ_REGISTER_ULONG(
            (PULONG)((PUCHAR)context->BarBase + input->Offset));

        information = sizeof(*output);
        status = STATUS_SUCCESS;
        break;
    }

    case IOCTL_PCIE_BAR_WRITE32:
    {
        PPCIE_BAR_ACCESS input = NULL;

        if (InputBufferLength < sizeof(PCIE_BAR_ACCESS)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        status = WdfRequestRetrieveInputBuffer(
            Request,
            sizeof(PCIE_BAR_ACCESS),
            (PVOID*)&input,
            NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }

        if (!context->BarValid) {
            status = STATUS_INVALID_DEVICE_STATE;
            break;
        }

        if (!PcieBarOffsetValid(context, input->Offset)) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        WRITE_REGISTER_ULONG(
            (PULONG)((PUCHAR)context->BarBase + input->Offset),
            input->Value);

        information = 0;
        status = STATUS_SUCCESS;
        break;
    }

    case IOCTL_PCIE_BAR_CFG_READ32:
    {
        PPCIE_BAR_ACCESS input = NULL;
        PPCIE_BAR_ACCESS output = NULL;
        ULONG offset;
        ULONG value = 0;

        status = WdfRequestRetrieveInputBuffer(
            Request, sizeof(PCIE_BAR_ACCESS), (PVOID*)&input, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        status = WdfRequestRetrieveOutputBuffer(
            Request, sizeof(PCIE_BAR_ACCESS), (PVOID*)&output, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        offset = input->Offset;
        if ((offset & 3) != 0 || offset > 0xFFC) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }
        if (!context->BusIfValid) {
            status = STATUS_INVALID_DEVICE_STATE;
            break;
        }
        if (PcieBarCfgRead32(context, offset, &value) != sizeof(ULONG)) {
            status = STATUS_UNSUCCESSFUL;
            break;
        }
        output->Offset = offset;
        output->Value = value;
        information = sizeof(*output);
        status = STATUS_SUCCESS;
        break;
    }

    case IOCTL_PCIE_BAR_DMA_INFO:
    {
        PPCIE_DMA_INFO info = NULL;
        ULONG command = 0;

        status = WdfRequestRetrieveOutputBuffer(
            Request, sizeof(PCIE_DMA_INFO), (PVOID*)&info, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        RtlZeroMemory(info, sizeof(*info));
        info->Version = PCIE_DMA_INFO_VERSION;
        info->ChunkBytes = PCIE_DMA_CHUNK_BYTES;
        info->MaxChunks = PCIE_DMA_MAX_CHUNKS;
        info->ChunksAllocated = context->PoolCount;
        info->DmaEnabled = (context->DmaEnabler != NULL) ? 1 : 0;
        if (PcieBarCfgRead32(context, 0x04, &command) == sizeof(ULONG)) {
            info->CommandRegister = command & 0xFFFF;
        }
        information = sizeof(*info);
        status = STATUS_SUCCESS;
        break;
    }

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    WdfRequestCompleteWithInformation(Request, status, information);
}
