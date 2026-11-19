#pragma once

//
// Shared definitions for the PCIe BAR0 test driver and its user-mode clients.
//
// The C# client (..\user\pcie_bar_test.cs) hard-codes the values of the first
// three IOCTLs and their structs; host/bar_windows.c includes this file. Keep
// them in sync if this file changes. IOCTLs 0x800-0x802 and their structs are
// unchanged since version 1.0; 0x803-0x806 were added in 1.1 (2026-11-19,
// for projects/07_dma).
//

#define IOCTL_PCIE_BAR_GET_INFO \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_PCIE_BAR_READ32 \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_PCIE_BAR_WRITE32 \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

// 1.1: read one dword of the device's PCI configuration space
// (PCIE_BAR_ACCESS, Offset 0..0xFFC, 4-byte aligned). Read only.
#define IOCTL_PCIE_BAR_CFG_READ32 \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)
// 1.1: DMA capabilities and state -> PCIE_DMA_INFO
#define IOCTL_PCIE_BAR_DMA_INFO \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x804, METHOD_BUFFERED, FILE_ANY_ACCESS)
// 1.1: allocate ChunkCount common buffers of PCIE_DMA_CHUNK_BYTES each, map
// them into the calling process -> PCIE_DMA_CHUNKS. One pool per device; it
// belongs to the handle that allocated it and is freed by DMA_FREE or when
// that handle is closed.
#define IOCTL_PCIE_BAR_DMA_ALLOC \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x805, METHOD_BUFFERED, FILE_ANY_ACCESS)
// 1.1: unmap and free the pool (only the owning handle).
#define IOCTL_PCIE_BAR_DMA_FREE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x806, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _PCIE_BAR_INFO {
    ULONG     VendorId;
    ULONG     DeviceId;
    ULONGLONG BarPhysicalAddress;
    ULONG     BarLength;
    ULONG     Mapped;          // 1 if BAR0 is mapped and the ID register matched
} PCIE_BAR_INFO, *PPCIE_BAR_INFO;

typedef struct _PCIE_BAR_ACCESS {
    ULONG Offset;              // byte offset from BAR0, must be 4-byte aligned
    ULONG Value;               // read result or write value
} PCIE_BAR_ACCESS, *PPCIE_BAR_ACCESS;

// Common buffers are physically contiguous chunks of this size.
#define PCIE_DMA_CHUNK_BYTES  (4UL * 1024UL * 1024UL)
#define PCIE_DMA_MAX_CHUNKS   64

#define PCIE_DMA_INFO_VERSION 0x00010001UL   // driver interface 1.1

typedef struct _PCIE_DMA_INFO {
    ULONG Version;             // PCIE_DMA_INFO_VERSION
    ULONG ChunkBytes;          // PCIE_DMA_CHUNK_BYTES
    ULONG MaxChunks;           // PCIE_DMA_MAX_CHUNKS
    ULONG ChunksAllocated;     // 0 if no pool
    ULONG DmaEnabled;          // 1 if the 64-bit DMA enabler was created
    ULONG CommandRegister;     // PCI command register (bit 2 = bus master)
} PCIE_DMA_INFO, *PPCIE_DMA_INFO;

typedef struct _PCIE_DMA_ALLOC {
    ULONG ChunkCount;          // 1..PCIE_DMA_MAX_CHUNKS
} PCIE_DMA_ALLOC, *PPCIE_DMA_ALLOC;

typedef struct _PCIE_DMA_CHUNK {
    ULONGLONG UserAddress;     // virtual address in the calling process (cached)
    ULONGLONG BusAddress;      // device (logical) address for DMA descriptors
} PCIE_DMA_CHUNK, *PPCIE_DMA_CHUNK;

typedef struct _PCIE_DMA_CHUNKS {
    ULONG          Count;
    ULONG          ChunkBytes;
    PCIE_DMA_CHUNK Chunk[PCIE_DMA_MAX_CHUNKS];
} PCIE_DMA_CHUNKS, *PPCIE_DMA_CHUNKS;

// {7A5E3C2B-9D4F-4E8A-9B1C-2D3E4F5A6B7C}
#define GUID_DEVINTERFACE_PCIE_BAR \
    { 0x7a5e3c2b, 0x9d4f, 0x4e8a, \
      { 0x9b, 0x1c, 0x2d, 0x3e, 0x4f, 0x5a, 0x6b, 0x7c } }

// Value of the design's ID register at BAR0 + 0x40.
#define PCIE_BAR_ID_VALUE 0x50434945UL
