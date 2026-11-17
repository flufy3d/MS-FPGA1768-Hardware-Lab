//
// pcie_bar.c — minimal KMDF function driver for the 02_pcie_pio endpoint.
//
// Binds to PCI\VEN_1172&DEV_E003, maps BAR0, validates the design ID register,
// and exposes three IOCTLs to a user-mode client:
//
//   IOCTL_PCIE_BAR_GET_INFO  -> PCIE_BAR_INFO
//   IOCTL_PCIE_BAR_READ32    -> PCIE_BAR_ACCESS { Offset, Value }
//   IOCTL_PCIE_BAR_WRITE32   -> PCIE_BAR_ACCESS { Offset, Value }
//
// Only 4-byte aligned accesses inside the mapped BAR are accepted. Writes are
// refused unless the ID register matched at start, so a wrong or unassigned BAR
// cannot be written by accident.
//

#include <ntddk.h>
#include <wdf.h>
#include "pcie_bar.h"

static const GUID g_PcieBarInterfaceGuid = GUID_DEVINTERFACE_PCIE_BAR;

typedef struct _DEVICE_CONTEXT {
    PVOID             BarBase;
    ULONG             BarLength;
    PHYSICAL_ADDRESS  BarPhysical;
    ULONG             BarValid;
} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, PcieBarGetContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD PcieBarEvtDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE PcieBarEvtDevicePrepareHardware;
EVT_WDF_DEVICE_RELEASE_HARDWARE PcieBarEvtDeviceReleaseHardware;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL PcieBarEvtIoDeviceControl;

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
    WDFDEVICE device;
    PDEVICE_CONTEXT context;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(Driver);

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpPowerCallbacks);
    pnpPowerCallbacks.EvtDevicePrepareHardware = PcieBarEvtDevicePrepareHardware;
    pnpPowerCallbacks.EvtDeviceReleaseHardware = PcieBarEvtDeviceReleaseHardware;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpPowerCallbacks);

    WdfDeviceInitSetIoType(DeviceInit, WdfDeviceIoBuffered);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, DEVICE_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    context = PcieBarGetContext(device);
    context->BarBase = NULL;
    context->BarLength = 0;
    context->BarPhysical.QuadPart = 0;
    context->BarValid = 0;

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
            context->BarLength = 0;
            return STATUS_INSUFFICIENT_RESOURCES;
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

    return STATUS_DEVICE_CONFIGURATION_ERROR;
}

NTSTATUS
PcieBarEvtDeviceReleaseHardware(
    _In_ WDFDEVICE     Device,
    _In_ WDFCMRESLIST  ResourcesTranslated
    )
{
    PDEVICE_CONTEXT context = PcieBarGetContext(Device);

    UNREFERENCED_PARAMETER(ResourcesTranslated);

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

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    WdfRequestCompleteWithInformation(Request, status, information);
}
