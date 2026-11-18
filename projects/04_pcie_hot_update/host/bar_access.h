/*
 * bar_access.h — minimal BAR0 access layer for the lab's PCIe designs
 *
 * One implementation per host OS:
 *   bar_linux.c    mmap() of /sys/bus/pci/devices/<BDF>/resource0 (no driver needed)
 *   bar_windows.c  the KMDF test driver in projects/02_pcie_pio/driver (IOCTLs)
 *
 * Only aligned 32-bit accesses are supported; that is all the BAR0 register
 * banks of projects 02-04 need.
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

/* Small platform helpers. */
double plat_now(void);                         /* monotonic seconds */
void   plat_sleep_ms(unsigned ms);
void   plat_timestamp(char *buf, unsigned len); /* local time, ISO 8601 */

#endif
