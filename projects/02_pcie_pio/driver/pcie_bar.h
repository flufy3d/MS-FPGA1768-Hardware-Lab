#pragma once

//
// Shared definitions for the PCIe BAR0 test driver and its user-mode client.
//
// The user-mode client is C#; it hard-codes the same IOCTL values and struct
// layouts. Keep the two in sync if this file changes.
//

#define IOCTL_PCIE_BAR_GET_INFO \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_PCIE_BAR_READ32 \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_PCIE_BAR_WRITE32 \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

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

// {7A5E3C2B-9D4F-4E8A-9B1C-2D3E4F5A6B7C}
#define GUID_DEVINTERFACE_PCIE_BAR \
    { 0x7a5e3c2b, 0x9d4f, 0x4e8a, \
      { 0x9b, 0x1c, 0x2d, 0x3e, 0x4f, 0x5a, 0x6b, 0x7c } }

// Value of the design's ID register at BAR0 + 0x40.
#define PCIE_BAR_ID_VALUE 0x50434945UL
