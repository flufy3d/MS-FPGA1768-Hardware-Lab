/*
 * bar_windows.c — BAR0 access through the lab's KMDF test driver
 *
 * Driver: projects/02_pcie_pio/driver (pcie_bar.sys). Its IOCTL codes, structs
 * and device interface GUID come from pcie_bar.h, included directly so the
 * two can never drift apart.
 *
 * The driver only allows writes when it read 0x50434945 at BAR0 + 0x40 when
 * the device started. Link speed and width come from the PnP properties
 * DEVPKEY_PciDevice_CurrentLinkSpeed / CurrentLinkWidth.
 *
 * Driver 1.1 (2026-11-19) adds configuration space reads and DMA common
 * buffers (bar_cfg_read32, bar_dma_*); with a 1.0 driver those calls fail
 * with ERROR_INVALID_FUNCTION and the message says to update the driver.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winioctl.h>
#include <setupapi.h>
#include <initguid.h>
#include <devpropdef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../projects/02_pcie_pio/driver/pcie_bar.h"
#include "bar_access.h"

/* pciprop.h: {3AB22E31-8264-4B4E-9AF5-A8D2D8E33E62}, pid 9 / 10 */
DEFINE_DEVPROPKEY(LAB_DEVPKEY_PciDevice_CurrentLinkSpeed,
    0x3ab22e31, 0x8264, 0x4b4e, 0x9a, 0xf5, 0xa8, 0xd2, 0xd8, 0xe3, 0x3e, 0x62, 9);
DEFINE_DEVPROPKEY(LAB_DEVPKEY_PciDevice_CurrentLinkWidth,
    0x3ab22e31, 0x8264, 0x4b4e, 0x9a, 0xf5, 0xa8, 0xd2, 0xd8, 0xe3, 0x3e, 0x62, 10);

struct bar {
    HANDLE          handle;
    HDEVINFO        devinfo;
    SP_DEVINFO_DATA devdata;
    char            path[128];
};

static const GUID g_iface = GUID_DEVINTERFACE_PCIE_BAR;

int bar_open(bar_t **out, const char *select)
{
    (void)select;
    *out = NULL;

    HDEVINFO set = SetupDiGetClassDevsA(&g_iface, NULL, NULL,
                                        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "SetupDiGetClassDevs failed: %lu\n", GetLastError());
        return -1;
    }

    SP_DEVICE_INTERFACE_DATA ifd;
    memset(&ifd, 0, sizeof(ifd));
    ifd.cbSize = sizeof(ifd);
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &g_iface, i, &ifd); i++) {
        DWORD need = 0;
        SetupDiGetDeviceInterfaceDetailA(set, &ifd, NULL, 0, &need, NULL);
        if (need == 0)
            continue;
        SP_DEVICE_INTERFACE_DETAIL_DATA_A *detail = malloc(need);
        if (!detail)
            break;
        detail->cbSize = sizeof(*detail);
        SP_DEVINFO_DATA dev;
        memset(&dev, 0, sizeof(dev));
        dev.cbSize = sizeof(dev);
        if (SetupDiGetDeviceInterfaceDetailA(set, &ifd, detail, need, NULL, &dev)) {
            HANDLE h = CreateFileA(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                   FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                   OPEN_EXISTING, 0, NULL);
            if (h != INVALID_HANDLE_VALUE) {
                bar_t *b = calloc(1, sizeof(*b));
                if (!b) {
                    CloseHandle(h);
                    free(detail);
                    break;
                }
                b->handle = h;
                b->devinfo = set;
                b->devdata = dev;
                snprintf(b->path, sizeof(b->path), "%s", detail->DevicePath);
                free(detail);
                *out = b;
                return 0;
            }
        }
        free(detail);
    }

    SetupDiDestroyDeviceInfoList(set);
    fprintf(stderr,
            "No pcie_bar device interface found. Install the driver from\n"
            "projects/02_pcie_pio/driver, load the bitstream, warm-reboot, and check\n"
            "that PCI\\VEN_1172&DEV_E003 is present with status OK.\n");
    return -1;
}

void bar_close(bar_t *b)
{
    if (!b)
        return;
    CloseHandle(b->handle);
    SetupDiDestroyDeviceInfoList(b->devinfo);
    free(b);
}

static int dev_prop_u32(bar_t *b, const DEVPROPKEY *key)
{
    DEVPROPTYPE type = 0;
    BYTE buf[8] = { 0 };
    DWORD size = 0;
    if (!SetupDiGetDevicePropertyW(b->devinfo, &b->devdata, key, &type,
                                   buf, sizeof(buf), &size, 0))
        return -1;
    if (type == DEVPROP_TYPE_UINT32 && size >= 4)
        return (int)*(UINT32 *)buf;
    if (type == DEVPROP_TYPE_BYTE && size >= 1)
        return buf[0];
    if (type == DEVPROP_TYPE_UINT16 && size >= 2)
        return *(UINT16 *)buf;
    return -1;
}

int bar_get_info(bar_t *b, bar_info_t *info)
{
    PCIE_BAR_INFO raw;
    DWORD got = 0;
    memset(info, 0, sizeof(*info));
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_GET_INFO, NULL, 0,
                         &raw, sizeof(raw), &got, NULL)) {
        fprintf(stderr, "IOCTL_PCIE_BAR_GET_INFO failed: %lu\n", GetLastError());
        return -1;
    }
    info->vendor_id  = raw.VendorId;
    info->device_id  = raw.DeviceId;
    info->bar_phys   = raw.BarPhysicalAddress;
    info->bar_length = raw.Mapped ? raw.BarLength : 0;
    info->link_speed = dev_prop_u32(b, &LAB_DEVPKEY_PciDevice_CurrentLinkSpeed);
    info->link_width = dev_prop_u32(b, &LAB_DEVPKEY_PciDevice_CurrentLinkWidth);
    snprintf(info->location, sizeof(info->location), "%s", b->path);
    return 0;
}

int bar_read32(bar_t *b, uint32_t offset, uint32_t *value)
{
    PCIE_BAR_ACCESS req = { offset, 0 }, rsp = { 0, 0 };
    DWORD got = 0;
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_READ32, &req, sizeof(req),
                         &rsp, sizeof(rsp), &got, NULL)) {
        fprintf(stderr, "read32(0x%X) failed: %lu\n", (unsigned)offset, GetLastError());
        return -1;
    }
    *value = rsp.Value;
    return 0;
}

int bar_write32(bar_t *b, uint32_t offset, uint32_t value)
{
    PCIE_BAR_ACCESS req = { offset, value };
    DWORD got = 0;
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_WRITE32, &req, sizeof(req),
                         NULL, 0, &got, NULL)) {
        fprintf(stderr, "write32(0x%X) failed: %lu\n", (unsigned)offset, GetLastError());
        return -1;
    }
    return 0;
}

static void report_old_driver(const char *what, DWORD err)
{
    fprintf(stderr, "%s failed: %lu", what, err);
    if (err == ERROR_INVALID_FUNCTION)
        fprintf(stderr, " (driver older than 1.1: rebuild, sign and reinstall "
                        "projects/02_pcie_pio/driver)");
    fprintf(stderr, "\n");
}

int bar_cfg_read32(bar_t *b, uint32_t offset, uint32_t *value)
{
    PCIE_BAR_ACCESS req = { offset, 0 }, rsp = { 0, 0 };
    DWORD got = 0;
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_CFG_READ32, &req, sizeof(req),
                         &rsp, sizeof(rsp), &got, NULL)) {
        report_old_driver("IOCTL_PCIE_BAR_CFG_READ32", GetLastError());
        return -1;
    }
    *value = rsp.Value;
    return 0;
}

int bar_dma_info(bar_t *b, bar_dma_info_t *info)
{
    PCIE_DMA_INFO raw;
    DWORD got = 0;
    memset(info, 0, sizeof(*info));
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_DMA_INFO, NULL, 0,
                         &raw, sizeof(raw), &got, NULL)) {
        report_old_driver("IOCTL_PCIE_BAR_DMA_INFO", GetLastError());
        return -1;
    }
    info->version     = raw.Version;
    info->chunk_bytes = raw.ChunkBytes;
    info->max_chunks  = raw.MaxChunks;
    info->allocated   = raw.ChunksAllocated;
    info->enabled     = raw.DmaEnabled;
    info->command     = raw.CommandRegister;
    return 0;
}

int bar_dma_alloc(bar_t *b, unsigned n, bar_dma_chunk_t *chunks, uint32_t *chunk_bytes)
{
    PCIE_DMA_ALLOC req;
    PCIE_DMA_CHUNKS *rsp = calloc(1, sizeof(*rsp));
    DWORD got = 0;
    if (!rsp)
        return -1;
    req.ChunkCount = n;
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_DMA_ALLOC, &req, sizeof(req),
                         rsp, sizeof(*rsp), &got, NULL)) {
        report_old_driver("IOCTL_PCIE_BAR_DMA_ALLOC", GetLastError());
        free(rsp);
        return -1;
    }
    if (rsp->Count != n) {
        fprintf(stderr, "DMA_ALLOC returned %lu chunks, asked for %u\n",
                (unsigned long)rsp->Count, n);
        free(rsp);
        return -1;
    }
    for (unsigned i = 0; i < n; i++) {
        chunks[i].va  = (uint8_t *)(uintptr_t)rsp->Chunk[i].UserAddress;
        chunks[i].bus = rsp->Chunk[i].BusAddress;
    }
    *chunk_bytes = rsp->ChunkBytes;
    free(rsp);
    return (int)n;
}

int bar_dma_free(bar_t *b)
{
    DWORD got = 0;
    if (!DeviceIoControl(b->handle, IOCTL_PCIE_BAR_DMA_FREE, NULL, 0, NULL, 0, &got, NULL)) {
        report_old_driver("IOCTL_PCIE_BAR_DMA_FREE", GetLastError());
        return -1;
    }
    return 0;
}

double plat_now(void)
{
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;
    if (!freq.QuadPart)
        QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)freq.QuadPart;
}

void plat_sleep_ms(unsigned ms)
{
    Sleep(ms);
}

void plat_timestamp(char *buf, unsigned len)
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    snprintf(buf, len, "%04u-%02u-%02uT%02u:%02u:%02u",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

int plat_exe_dir(char *buf, unsigned len)
{
    DWORD n = GetModuleFileNameA(NULL, buf, len);
    if (n == 0 || n >= len)
        return -1;
    while (n > 0 && buf[n - 1] != '\\' && buf[n - 1] != '/')
        n--;
    if (n == 0)
        return -1;
    buf[n - 1] = '\0';
    return 0;
}
