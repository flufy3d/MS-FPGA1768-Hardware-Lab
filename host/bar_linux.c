/*
 * bar_linux.c — BAR0 access on Linux through sysfs, no kernel driver needed
 *
 *   /sys/bus/pci/devices/<BDF>/resource0   mmap()ed read/write (needs root)
 *   /sys/bus/pci/devices/<BDF>/config      command register check
 *   current_link_speed / current_link_width
 *
 * The device must not be bound to another driver that owns BAR0, and memory
 * space decoding must be enabled (PCI command register bit 1). If it is not:
 *   echo 1 | sudo tee /sys/bus/pci/devices/<BDF>/enable
 *
 * Status: built, not tested on hardware (the lab host runs Windows).
 */
#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "bar_access.h"

#define SYSFS_PCI "/sys/bus/pci/devices"

struct bar {
    int                fd;
    volatile uint32_t *base;
    size_t             length;
    char               bdf[64];
};

static int read_sysfs_line(const char *bdf, const char *name, char *buf, size_t len)
{
    char path[256];
    snprintf(path, sizeof(path), SYSFS_PCI "/%.63s/%s", bdf, name);
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    if (!fgets(buf, (int)len, f)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    buf[strcspn(buf, "\n")] = '\0';
    return 0;
}

static long read_sysfs_hex(const char *bdf, const char *name)
{
    char buf[64];
    if (read_sysfs_line(bdf, name, buf, sizeof(buf)) != 0)
        return -1;
    return strtol(buf, NULL, 16);
}

static int find_device(char *bdf, size_t len)
{
    DIR *d = opendir(SYSFS_PCI);
    if (!d) {
        perror(SYSFS_PCI);
        return -1;
    }
    struct dirent *e;
    int found = -1;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        if (read_sysfs_hex(e->d_name, "vendor") == (long)LAB_VENDOR_ID &&
            read_sysfs_hex(e->d_name, "device") == (long)LAB_DEVICE_ID) {
            snprintf(bdf, len, "%.63s", e->d_name);
            found = 0;
            break;
        }
    }
    closedir(d);
    return found;
}

int bar_open(bar_t **out, const char *select)
{
    char bdf[64];
    *out = NULL;

    if (select) {
        snprintf(bdf, sizeof(bdf), "%.63s", select);
    } else if (find_device(bdf, sizeof(bdf)) != 0) {
        fprintf(stderr,
                "No PCI device %04x:%04x found. Load the bitstream, then reboot or\n"
                "rescan (echo 1 | sudo tee /sys/bus/pci/rescan).\n",
                LAB_VENDOR_ID, LAB_DEVICE_ID);
        return -1;
    }

    /* Memory space enable (command register, offset 0x04, bit 1). */
    char cfgpath[256];
    snprintf(cfgpath, sizeof(cfgpath), SYSFS_PCI "/%.63s/config", bdf);
    int cfd = open(cfgpath, O_RDONLY);
    if (cfd >= 0) {
        unsigned char cmd[2] = { 0, 0 };
        if (pread(cfd, cmd, 2, 4) == 2 && !(cmd[0] & 0x02)) {
            fprintf(stderr,
                    "%s: memory space decoding is disabled (command 0x%02x%02x).\n"
                    "Enable it first: echo 1 | sudo tee " SYSFS_PCI "/%s/enable\n",
                    bdf, cmd[1], cmd[0], bdf);
            close(cfd);
            return -1;
        }
        close(cfd);
    }

    char respath[256];
    snprintf(respath, sizeof(respath), SYSFS_PCI "/%.63s/resource0", bdf);
    int fd = open(respath, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s (run as root?)\n", respath, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 0x1000) {
        fprintf(stderr, "%s: BAR0 missing or smaller than 4 KB\n", respath);
        close(fd);
        return -1;
    }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap %s: %s\n", respath, strerror(errno));
        close(fd);
        return -1;
    }

    bar_t *b = calloc(1, sizeof(*b));
    if (!b) {
        munmap(p, (size_t)st.st_size);
        close(fd);
        return -1;
    }
    b->fd = fd;
    b->base = (volatile uint32_t *)p;
    b->length = (size_t)st.st_size;
    snprintf(b->bdf, sizeof(b->bdf), "%s", bdf);
    *out = b;
    return 0;
}

void bar_close(bar_t *b)
{
    if (!b)
        return;
    munmap((void *)b->base, b->length);
    close(b->fd);
    free(b);
}

/* "8.0 GT/s PCIe" -> 3 */
static int parse_speed(const char *s)
{
    double gt = atof(s);
    if (gt >= 63.0) return 6;
    if (gt >= 31.0) return 5;
    if (gt >= 15.0) return 4;
    if (gt >= 7.9)  return 3;
    if (gt >= 4.9)  return 2;
    if (gt >= 2.4)  return 1;
    return -1;
}

int bar_get_info(bar_t *b, bar_info_t *info)
{
    char buf[128];
    memset(info, 0, sizeof(*info));
    info->vendor_id = (uint32_t)read_sysfs_hex(b->bdf, "vendor");
    info->device_id = (uint32_t)read_sysfs_hex(b->bdf, "device");
    info->bar_length = (uint32_t)b->length;
    /* First line of "resource" is BAR0: start end flags. */
    if (read_sysfs_line(b->bdf, "resource", buf, sizeof(buf)) == 0)
        info->bar_phys = strtoull(buf, NULL, 16);
    info->link_speed = read_sysfs_line(b->bdf, "current_link_speed", buf, sizeof(buf)) == 0
                       ? parse_speed(buf) : -1;
    info->link_width = read_sysfs_line(b->bdf, "current_link_width", buf, sizeof(buf)) == 0
                       ? atoi(buf) : -1;
    snprintf(info->location, sizeof(info->location), "%s", b->bdf);
    return 0;
}

static int check_offset(bar_t *b, uint32_t offset)
{
    if ((offset & 3u) || (size_t)offset + 4 > b->length) {
        fprintf(stderr, "offset 0x%X outside BAR0 or unaligned\n", (unsigned)offset);
        return -1;
    }
    return 0;
}

int bar_read32(bar_t *b, uint32_t offset, uint32_t *value)
{
    if (check_offset(b, offset))
        return -1;
    *value = b->base[offset / 4];
    return 0;
}

int bar_write32(bar_t *b, uint32_t offset, uint32_t value)
{
    if (check_offset(b, offset))
        return -1;
    b->base[offset / 4] = value;
    return 0;
}

double plat_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int bar_cfg_read32(bar_t *b, uint32_t offset, uint32_t *value)
{
    char path[256];
    snprintf(path, sizeof(path), SYSFS_PCI "/%.63s/config", b->bdf);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "%s: %s\n", path, strerror(errno));
        return -1;
    }
    uint32_t v = 0xFFFFFFFFu;
    ssize_t n = pread(fd, &v, sizeof(v), (off_t)(offset & 0xFFCu));
    close(fd);
    if (n != (ssize_t)sizeof(v)) {
        fprintf(stderr, "%s: short read at 0x%X (extended config space needs root)\n",
                path, (unsigned)offset);
        return -1;
    }
    *value = v;
    return 0;
}

static int no_dma(void)
{
    fprintf(stderr, "DMA is not implemented in the Linux backend (it needs a kernel driver "
                    "for DMA memory; see host/README.md).\n");
    return -1;
}

int bar_dma_info(bar_t *b, bar_dma_info_t *info)
{
    (void)b;
    memset(info, 0, sizeof(*info));
    return no_dma();
}

int bar_dma_alloc(bar_t *b, unsigned n, bar_dma_chunk_t *chunks, uint32_t *chunk_bytes)
{
    (void)b; (void)n; (void)chunks; (void)chunk_bytes;
    return no_dma();
}

int bar_dma_free(bar_t *b)
{
    (void)b;
    return no_dma();
}

void plat_sleep_ms(unsigned ms)
{
    struct timespec ts = { (time_t)(ms / 1000), (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

void plat_timestamp(char *buf, unsigned len)
{
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(buf, len, "%Y-%m-%dT%H:%M:%S", &tm);
}

int plat_exe_dir(char *buf, unsigned len)
{
    ssize_t n = readlink("/proc/self/exe", buf, (size_t)len - 1);
    if (n <= 0)
        return -1;
    buf[n] = '\0';
    char *slash = strrchr(buf, '/');
    if (!slash)
        return -1;
    *slash = '\0';
    return 0;
}
