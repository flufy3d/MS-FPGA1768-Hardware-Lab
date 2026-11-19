/*
 * bar_access.h — minimal BAR0 access layer for the lab's PCIe designs
 *
 * One implementation per host OS:
 *   bar_linux.c    mmap() of /sys/bus/pci/devices/<BDF>/resource0 (no driver needed)
 *   bar_windows.c  the KMDF test driver in projects/02_pcie_pio/driver (IOCTLs)
 *
 * Only aligned 32-bit accesses are supported; that is all the BAR0 register
 * banks of the lab's projects need.
 */
#ifndef BAR_ACCESS_H
#define BAR_ACCESS_H

#include <stdint.h>

#define LAB_VENDOR_ID 0x1172u
#define LAB_DEVICE_ID 0xE003u

typedef struct bar bar_t;

typedef struct bar_info {
    uint32_t vendor_id;
    uint32_t device_id;
    uint64_t bar_phys;        /* BAR0 bus/physical address */
    uint32_t bar_length;      /* BAR0 length in bytes */
    int      link_speed;      /* 1 = 2.5 GT/s, 2 = 5 GT/s, 3 = 8 GT/s; -1 unknown */
    int      link_width;      /* lanes; -1 unknown */
    char     location[128];   /* PCI address or device path */
} bar_info_t;

/*
 * Open BAR0 of the lab device (1172:E003).
 * select: Linux "0000:02:00.0" style BDF, or NULL to find the first match.
 *         Windows: ignored (the first driver instance is used).
 * Returns 0 on success; on failure prints a reason to stderr and returns -1.
 */
int  bar_open(bar_t **bar, const char *select);
void bar_close(bar_t *bar);

/* Fills *info. Link speed/width are re-read on every call. */
int  bar_get_info(bar_t *bar, bar_info_t *info);

/* Aligned 32-bit access at BAR0 + offset. Return 0 on success, -1 on error. */
int  bar_read32(bar_t *bar, uint32_t offset, uint32_t *value);
int  bar_write32(bar_t *bar, uint32_t offset, uint32_t value);

/*
 * PCI configuration space, one aligned dword (offset 0..0xFFC). Read only.
 * Windows: driver 1.1 IOCTL; Linux: /sys/bus/pci/devices/<BDF>/config.
 */
int  bar_cfg_read32(bar_t *bar, uint32_t offset, uint32_t *value);

/*
 * DMA memory (projects/07_dma). The Windows driver (1.1) allocates physically
 * contiguous common buffers of chunk_bytes (4 MB) with a 64-bit DMA enabler
 * and maps them into this process. Not implemented on Linux (returns -1).
 */
#define BAR_DMA_MAX_CHUNKS 64

typedef struct bar_dma_chunk {
    uint8_t *va;              /* mapped into this process (cached) */
    uint64_t bus;             /* address for the device's descriptors */
} bar_dma_chunk_t;

typedef struct bar_dma_info {
    uint32_t version;         /* driver interface, 0x00010001 = 1.1 */
    uint32_t chunk_bytes;
    uint32_t max_chunks;
    uint32_t allocated;       /* chunks in the pool now */
    uint32_t enabled;         /* 64-bit DMA enabler created */
    uint32_t command;         /* PCI command register */
} bar_dma_info_t;

int  bar_dma_info(bar_t *bar, bar_dma_info_t *info);
/* Returns the number of chunks (== n) or -1. The pool is freed by
 * bar_dma_free or when the handle is closed (bar_close). */
int  bar_dma_alloc(bar_t *bar, unsigned n, bar_dma_chunk_t *chunks, uint32_t *chunk_bytes);
int  bar_dma_free(bar_t *bar);

/* Small platform helpers. */
double plat_now(void);                         /* monotonic seconds */
void   plat_sleep_ms(unsigned ms);
void   plat_timestamp(char *buf, unsigned len); /* local time, ISO 8601 */
int    plat_exe_dir(char *buf, unsigned len);   /* directory of this executable; 0 on success */

#endif
