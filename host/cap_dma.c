/*
 * cap_dma.c — DMA throughput test (CAPS bit 4, projects/07_dma)
 *
 *   dma info                  driver DMA state, PCIe link and MPS / MRRS from
 *                             configuration space, engine constants and state
 *   dma run [options]         one test point, timed and verified
 *   dma bench [options]       test matrix: sizes x directions x modes
 *   dma help
 *
 * Options (sizes take K / M suffixes, powers of two where noted):
 *   --dir h2d|d2h|both        run: direction (default h2d); bench: comma list
 *   --mode pattern|ram        run: data source/sink (default pattern); bench: list
 *   --size BYTES              run: bytes per transfer (default 4M)
 *   --min BYTES --max BYTES   bench: size range (default 4K .. 64M)
 *   --desc BYTES              descriptor size, power of two 256 .. 512K (default 512K)
 *   --loops N                 the FPGA repeats each transfer N times (default 1)
 *   --repeat N                host repetitions per point (run: 1; bench: automatic)
 *   --seed HEX                pattern seed (default 0x1234ABCD)
 *   --no-verify               skip data checks
 *   --csv FILE                bench: also write one CSV line per point
 *
 * Directions are seen from the host: H2D = host -> FPGA (the hard IP's read
 * DMA), D2H = FPGA -> host (write DMA). Modes: "pattern" streams to / from the
 * address-pattern checker / generator in the FPGA (any size); "ram" uses the
 * on-chip RAM (size <= RAM, <= RAM/2 for both directions) and verifies by
 * loopback.
 *
 * Timing: the FPGA counts core clock cycles from the first descriptor handed
 * to the hard IP to the last completion status (CYCLES, "fpga" columns); the
 * host measures QueryPerformanceCounter time from just before the CTRL start
 * write until it sees the status record the FPGA writes into host memory
 * ("app" columns, includes the start IOCTL and the polling latency). GB/s are
 * 10^9 bytes per second.
 *
 * Host buffers: driver common buffers of 4 MB (chunk table entries):
 *   chunk 0          status records (H2D at +0, D2H at +64)
 *   1 .. NB          H2D source
 *   NB+1 .. 2NB      D2H destination
 *   2NB+1            auxiliary data for RAM-mode preloads
 *
 * Profile keys: regs.dma_*, regs.port_index, dma.* (block-relative offsets and
 * constants), see host/profiles/07_dma.ini.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tool.h"

#define CTRL_START_H2D  0x001u
#define CTRL_START_D2H  0x002u
#define CTRL_ABORT      0x010u
#define CTRL_CLEAR_CHK  0x100u

#define DIR_H2D 0
#define DIR_D2H 1

static bar_dma_chunk_t g_pool[BAR_DMA_MAX_CHUNKS];
static unsigned        g_npool;
static uint32_t        g_chunk = 4u << 20;
static unsigned        g_nb;           /* chunks per direction buffer */
static uint32_t        g_seq;
static uint32_t        g_clk_hz;
static uint32_t        g_ram_bytes;
static uint64_t        g_pat_base;

/* ------------------------------------------------------------ helpers */

static uint32_t pat_dw(uint32_t idx, uint32_t seed)
{
    /* identical to dma_pkg::pat_dw in projects/07_dma/dma_pkg.sv */
    uint32_t x = idx ^ seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

static uint32_t blk(int d)
{
    return d == DIR_H2D ? reg("regs.dma_h2d") : reg("regs.dma_d2h");
}

static void dwr(int d, const char *key, uint32_t v)
{
    wr(blk(d) + reg(key), v);
}

static uint32_t drd(int d, const char *key)
{
    return rd(blk(d) + reg(key));
}

static uint64_t drd64(int d, const char *key)
{
    uint32_t off = blk(d) + reg(key);
    uint32_t lo = rd(off), hi = rd(off + 4);
    return ((uint64_t)hi << 32) | lo;
}

static int parse_size(const char *s, uint64_t *out)
{
    char *end;
    unsigned long long v = strtoull(s, &end, 0);
    if (end == s)
        return -1;
    if (*end == 'K' || *end == 'k') { v <<= 10; end++; }
    else if (*end == 'M' || *end == 'm') { v <<= 20; end++; }
    else if (*end == 'G' || *end == 'g') { v <<= 30; end++; }
    if (*end != '\0')
        return -1;
    *out = v;
    return 0;
}

static const char *size_str(uint64_t b, char *buf, size_t n)
{
    if (b >= (1u << 20) && b % (1u << 20) == 0)
        snprintf(buf, n, "%lluM", (unsigned long long)(b >> 20));
    else if (b >= 1024 && b % 1024 == 0)
        snprintf(buf, n, "%lluK", (unsigned long long)(b >> 10));
    else
        snprintf(buf, n, "%llu", (unsigned long long)b);
    return buf;
}

static int log2u(uint64_t v)
{
    int n = -1;
    while (v) { v >>= 1; n++; }
    return n;
}

/* Byte `off` of a buffer that starts at pool chunk c0. */
static uint8_t *bufp(unsigned c0, uint64_t off)
{
    return g_pool[c0 + off / g_chunk].va + off % g_chunk;
}

static unsigned buf_h2d(void) { return 1; }
static unsigned buf_d2h(void) { return 1 + g_nb; }
static unsigned buf_aux(void) { return 1 + 2 * g_nb; }

static volatile uint32_t *stat_rec(int d)
{
    return (volatile uint32_t *)(g_pool[0].va + (d == DIR_H2D ? 0 : 64));
}

static uint64_t stat_bus(int d)
{
    return g_pool[0].bus + (d == DIR_H2D ? 0 : 64);
}

static void fill_pattern(unsigned c0, uint64_t len, uint32_t seed)
{
    for (uint64_t o = 0; o < len; o += g_chunk) {
        uint64_t n = len - o < g_chunk ? len - o : g_chunk;
        uint32_t *p = (uint32_t *)bufp(c0, o);
        uint32_t idx = (uint32_t)((g_pat_base + o) >> 2);
        for (uint64_t i = 0; i < n / 4; i++)
            p[i] = pat_dw(idx + (uint32_t)i, seed);
    }
}

/* Number of dwords that differ from the pattern; first bad offset in *first. */
static uint64_t check_pattern(unsigned c0, uint64_t len, uint32_t seed, uint64_t *first)
{
    uint64_t bad = 0;
    *first = ~0ull;
    for (uint64_t o = 0; o < len; o += g_chunk) {
        uint64_t n = len - o < g_chunk ? len - o : g_chunk;
        const uint32_t *p = (const uint32_t *)bufp(c0, o);
        uint32_t idx = (uint32_t)((g_pat_base + o) >> 2);
        for (uint64_t i = 0; i < n / 4; i++) {
            if (p[i] != pat_dw(idx + (uint32_t)i, seed)) {
                if (!bad)
                    *first = o + 4 * i;
                bad++;
            }
        }
    }
    return bad;
}

static void fill_random(unsigned c0, uint64_t len, uint64_t seed)
{
    uint64_t x = seed | 1;
    for (uint64_t o = 0; o < len; o += g_chunk) {
        uint64_t n = len - o < g_chunk ? len - o : g_chunk;
        uint64_t *p = (uint64_t *)bufp(c0, o);
        for (uint64_t i = 0; i < n / 8; i++) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            p[i] = x;
        }
    }
}

static void fill_zero(unsigned c0, uint64_t len)
{
    for (uint64_t o = 0; o < len; o += g_chunk) {
        uint64_t n = len - o < g_chunk ? len - o : g_chunk;
        memset(bufp(c0, o), 0, (size_t)n);
    }
}

/* Number of dwords that differ between two buffers. */
static uint64_t compare_bufs(unsigned a, unsigned b, uint64_t len, uint64_t *first)
{
    uint64_t bad = 0;
    *first = ~0ull;
    for (uint64_t o = 0; o < len; o += g_chunk) {
        uint64_t n = len - o < g_chunk ? len - o : g_chunk;
        const uint32_t *p = (const uint32_t *)bufp(a, o), *q = (const uint32_t *)bufp(b, o);
        if (memcmp(p, q, (size_t)n) == 0)
            continue;
        for (uint64_t i = 0; i < n / 4; i++) {
            if (p[i] != q[i]) {
                if (!bad)
                    *first = o + 4 * i;
                bad++;
            }
        }
    }
    return bad;
}

/* ------------------------------------------------------------ config space */

typedef struct pcie_cfg {
    int      found;
    unsigned mps, mrrs, mps_sup;     /* bytes */
    unsigned speed, width, cap_speed, cap_width;
    int      ext_tag, relaxed, nosnoop, bus_master;
} pcie_cfg_t;

static int read_pcie_cfg(pcie_cfg_t *c)
{
    memset(c, 0, sizeof(*c));
    uint32_t v;
    if (bar_cfg_read32(g_bar, 0x04, &v) != 0)
        return -1;
    c->bus_master = (v >> 2) & 1;
    if (!((v >> 16) & 0x10))          /* status: capabilities list */
        return 0;
    if (bar_cfg_read32(g_bar, 0x34, &v) != 0)
        return -1;
    unsigned ptr = v & 0xFC;
    for (int guard = 0; ptr && guard < 48; guard++) {
        if (bar_cfg_read32(g_bar, ptr, &v) != 0)
            return -1;
        if ((v & 0xFF) == 0x10) {
            uint32_t devcap, devctl, lnkcap, lnksta;
            if (bar_cfg_read32(g_bar, ptr + 0x04, &devcap) || bar_cfg_read32(g_bar, ptr + 0x08, &devctl) ||
                bar_cfg_read32(g_bar, ptr + 0x0C, &lnkcap) || bar_cfg_read32(g_bar, ptr + 0x10, &lnksta))
                return -1;
            c->found = 1;
            c->mps_sup = 128u << (devcap & 7);
            c->mps = 128u << ((devctl >> 5) & 7);
            c->mrrs = 128u << ((devctl >> 12) & 7);
            c->ext_tag = (devctl >> 8) & 1;
            c->relaxed = (devctl >> 4) & 1;
            c->nosnoop = (devctl >> 11) & 1;
            c->cap_speed = lnkcap & 0xF;
            c->cap_width = (lnkcap >> 4) & 0x3F;
            c->speed = (lnksta >> 16) & 0xF;
            c->width = (lnksta >> 20) & 0x3F;
            return 0;
        }
        ptr = (v >> 8) & 0xFC;
    }
    return 0;
}

static void print_pcie_cfg(void)
{
    pcie_cfg_t c;
    if (read_pcie_cfg(&c) != 0) {
        printf("Config:  not readable (driver 1.1 needed)\n");
        return;
    }
    if (!c.found) {
        printf("Config:  no PCI Express capability found\n");
        return;
    }
    printf("Config:  link Gen%u x%u (capable Gen%u x%u), bus master %s\n", c.speed, c.width,
           c.cap_speed, c.cap_width, c.bus_master ? "on" : "OFF");
    printf("         MPS %u bytes (device supports %u), MRRS %u bytes, extended tags %s, "
           "relaxed ordering %s, no snoop %s\n", c.mps, c.mps_sup, c.mrrs, c.ext_tag ? "on" : "off",
           c.relaxed ? "on" : "off", c.nosnoop ? "on" : "off");
}

/* ------------------------------------------------------------ engine */

typedef struct xfer {
    int      dir;
    uint64_t fpga;
    uint32_t len;
    unsigned chunk0;
    int      shift;
    unsigned loops;
} xfer_t;

typedef struct result {
    int      ok;                /* status record seen, no descriptor errors */
    double   app_s;             /* host time, start write -> status record seen */
    uint64_t cycles;            /* FPGA: first descriptor -> last status */
    uint64_t t_first, t_last;   /* FPGA cycle stamps */
    uint64_t d_first, d_last;   /* FPGA data beats window */
    uint64_t beats;
    uint32_t desc, derr;
} result_t;

static void program_xfer(const xfer_t *x)
{
    int d = x->dir;
    dwr(d, "dma.fpga_lo", (uint32_t)x->fpga);
    dwr(d, "dma.fpga_hi", (uint32_t)(x->fpga >> 32));
    dwr(d, "dma.length", x->len);
    dwr(d, "dma.chunk0", x->chunk0);
    dwr(d, "dma.desc_shift", (uint32_t)x->shift);
    dwr(d, "dma.loops", x->loops);
    dwr(d, "dma.max_out", 64);
    dwr(d, "dma.stat_lo", (uint32_t)stat_bus(d));
    dwr(d, "dma.stat_hi", (uint32_t)(stat_bus(d) >> 32));
}

static void dump_dir(int d)
{
    printf("  %s: STATE 0x%X, issued %u, done %u, errors %u, beats %llu\n", d == DIR_H2D ? "H2D" : "D2H",
           (unsigned)drd(d, "dma.state"), (unsigned)drd(d, "dma.issued"), (unsigned)drd(d, "dma.done"),
           (unsigned)drd(d, "dma.err"), (unsigned long long)drd64(d, "dma.beats"));
}

/*
 * Start the programmed transfers (n = 1 or 2, already programmed with
 * program_xfer) with one CTRL write and wait for their status records.
 */
static int run_xfers(const xfer_t *x, int n, result_t *r, double timeout_s)
{
    uint32_t mask = 0;
    uint32_t seq[2];
    volatile uint32_t *st[2];
    if (rd(reg("regs.dma_status")) & 3u) {
        fprintf(stderr, "dma: engine busy (STATUS 0x%X); abort with 'fpga1768 write %X %X'\n",
                (unsigned)rd(reg("regs.dma_status")), (unsigned)reg("regs.dma_ctrl"), CTRL_ABORT);
        return -1;
    }
    for (int i = 0; i < n; i++) {
        memset(&r[i], 0, sizeof(r[i]));
        seq[i] = ++g_seq;
        if (seq[i] == 0)
            seq[i] = ++g_seq;
        st[i] = stat_rec(x[i].dir);
        st[i][0] = st[i][1] = st[i][2] = st[i][3] = 0;
        dwr(x[i].dir, "dma.seq", seq[i]);
        mask |= x[i].dir == DIR_H2D ? CTRL_START_H2D : CTRL_START_D2H;
    }
    int pending = (1 << n) - 1;
    double t0 = plat_now();
    wr(reg("regs.dma_ctrl"), mask);
    unsigned spin = 0;
    while (pending) {
        for (int i = 0; i < n; i++) {
            if ((pending >> i & 1) && st[i][0] == seq[i]) {
                r[i].app_s = plat_now() - t0;
                pending &= ~(1 << i);
            }
        }
        if (pending && (++spin & 0xFFF) == 0 && plat_now() - t0 > timeout_s) {
            fprintf(stderr, "dma: timeout after %.1f s waiting for the status record(s); STATUS 0x%X\n",
                    timeout_s, (unsigned)rd(reg("regs.dma_status")));
            for (int i = 0; i < n; i++)
                dump_dir(x[i].dir);
            wr(reg("regs.dma_ctrl"), CTRL_ABORT);
            return -1;
        }
    }
    for (int i = 0; i < n; i++) {
        int d = x[i].dir;
        r[i].cycles  = ((uint64_t)st[i][2] << 32) | st[i][1];
        r[i].desc    = st[i][3] & 0xFFFF;
        r[i].derr    = st[i][3] >> 16;
        r[i].t_first = drd64(d, "dma.t_first");
        r[i].t_last  = drd64(d, "dma.t_last");
        r[i].d_first = drd64(d, "dma.d_first");
        r[i].d_last  = drd64(d, "dma.d_last");
        r[i].beats   = drd64(d, "dma.beats");
        r[i].ok      = r[i].derr == 0;
        if (r[i].derr)
            fprintf(stderr, "dma: %s reported %u descriptor errors\n", d == DIR_H2D ? "H2D" : "D2H",
                    (unsigned)r[i].derr);
    }
    return 0;
}

/* One untimed single-direction transfer (preload / read back). */
static int run_single(int dir, uint64_t fpga, uint32_t len, unsigned chunk0)
{
    xfer_t x = { dir, fpga, len, chunk0, 19, 1 };
    result_t r;
    program_xfer(&x);
    return run_xfers(&x, 1, &r, 5.0) == 0 && r.ok ? 0 : -1;
}

static double gbps(uint64_t bytes, double s)
{
    return s > 0 ? (double)bytes / s / 1e9 : 0.0;
}

/* ------------------------------------------------------------ test points */

typedef struct point {
    int      mode;              /* 0 pattern, 1 ram */
    int      dirs;              /* 1 H2D, 2 D2H, 3 both */
    uint64_t size;
    int      shift;
    unsigned loops;
    unsigned repeat;
    int      verify;
    uint32_t seed;
} point_t;

typedef struct stats {
    unsigned runs;
    double   fpga_sum[2], fpga_min[2], fpga_max[2];
    double   app_sum[2], app_max[2];
    double   data_sum[2];
    double   both_sum, both_max;    /* combined H2D + D2H, FPGA clock */
    uint32_t desc[2];
    int      verified;              /* -1 not checked, 0 failed, 1 passed */
    char     note[160];
} stats_t;

static const char *mode_name(int m) { return m ? "ram" : "pattern"; }
static const char *dirs_name(int d) { return d == 1 ? "h2d" : d == 2 ? "d2h" : "both"; }

/* Verification helpers; return 1 pass, 0 fail (note filled in). */
static int verify_h2d_pattern(stats_t *s, uint64_t bytes)
{
    uint32_t e = rd(reg("regs.dma_chk") + reg("dma.chk_err"));
    uint64_t cb = ((uint64_t)rd(reg("regs.dma_chk") + reg("dma.chk_beats") + 4) << 32) |
                  rd(reg("regs.dma_chk") + reg("dma.chk_beats"));
    if (e == 0 && cb == bytes / 32)
        return 1;
    uint32_t base = reg("regs.dma_chk");
    snprintf(s->note, sizeof(s->note), "H2D checker: %u bad dwords, %llu beats (expected %llu), "
             "first at 0x%08X%08X exp 0x%08X got 0x%08X", (unsigned)e, (unsigned long long)cb,
             (unsigned long long)(bytes / 32), (unsigned)rd(base + reg("dma.chk_addr") + 4),
             (unsigned)rd(base + reg("dma.chk_addr")), (unsigned)rd(base + reg("dma.chk_exp")),
             (unsigned)rd(base + reg("dma.chk_got")));
    return 0;
}

static int verify_d2h_pattern(stats_t *s, uint64_t len, uint32_t seed)
{
    uint64_t first;
    uint64_t bad = check_pattern(buf_d2h(), len, seed, &first);
    if (!bad)
        return 1;
    snprintf(s->note, sizeof(s->note), "D2H: %llu bad dwords in host memory, first at offset 0x%llX",
             (unsigned long long)bad, (unsigned long long)first);
    return 0;
}

static int verify_equal(stats_t *s, const char *what, unsigned a, unsigned b, uint64_t len)
{
    uint64_t first;
    uint64_t bad = compare_bufs(a, b, len, &first);
    if (!bad)
        return 1;
    snprintf(s->note, sizeof(s->note), "%s: %llu bad dwords, first at offset 0x%llX", what,
             (unsigned long long)bad, (unsigned long long)first);
    return 0;
}

/*
 * Run one test point. Returns 0 on success (all runs completed and verified),
 * 4 on a data error, 6 on a timeout.
 */
static int run_point(const point_t *p, stats_t *s)
{
    memset(s, 0, sizeof(*s));
    s->verified = p->verify ? 1 : -1;
    for (int i = 0; i < 2; i++)
        s->fpga_min[i] = 1e30;

    uint32_t len = (uint32_t)p->size;
    uint64_t bytes = (uint64_t)len * p->loops;
    uint64_t half = g_ram_bytes / 2;
    xfer_t x[2];
    int n = 0;

    wr(reg("regs.dma_seed"), p->seed);

    if (p->mode == 0) {
        /* pattern: H2D source holds the pattern of [pat_base, +len) */
        if (p->dirs & 1)
            x[n++] = (xfer_t){ DIR_H2D, g_pat_base, len, buf_h2d(), p->shift, p->loops };
        if (p->dirs & 2)
            x[n++] = (xfer_t){ DIR_D2H, g_pat_base, len, buf_d2h(), p->shift, p->loops };
    } else {
        /* ram: H2D -> RAM[0, len); D2H <- RAM[0, len) (one direction) or
         * RAM[half, half + len) (both directions, preloaded from aux) */
        if (p->dirs & 1)
            x[n++] = (xfer_t){ DIR_H2D, 0, len, buf_h2d(), p->shift, p->loops };
        if (p->dirs & 2)
            x[n++] = (xfer_t){ DIR_D2H, p->dirs == 3 ? half : 0, len, buf_d2h(), p->shift, p->loops };
        if (p->dirs & 2) {
            fill_random(buf_aux(), len, 0x9E3779B97F4A7C15ull ^ len);
            if (run_single(DIR_H2D, p->dirs == 3 ? half : 0, len, buf_aux()) != 0) {
                snprintf(s->note, sizeof(s->note), "RAM preload failed");
                return 6;
            }
        }
    }

    for (int i = 0; i < n; i++)
        program_xfer(&x[i]);

    for (unsigned rep = 0; rep < p->repeat; rep++) {
        result_t r[2];
        int check_now = p->verify && (rep == 0 || rep + 1 == p->repeat);
        if (check_now && (p->dirs & 2))
            fill_zero(buf_d2h(), len);
        if (run_xfers(x, n, r, 5.0 + (double)bytes / 5e8) != 0) {
            snprintf(s->note, sizeof(s->note), "timeout in run %u", rep + 1);
            return 6;
        }
        s->runs++;
        uint64_t lo = ~0ull, hi = 0;
        for (int i = 0; i < n; i++) {
            int d = x[i].dir;
            double fs = (double)r[i].cycles / g_clk_hz;
            double g = gbps(bytes, fs);
            s->fpga_sum[d] += g;
            if (g < s->fpga_min[d]) s->fpga_min[d] = g;
            if (g > s->fpga_max[d]) s->fpga_max[d] = g;
            double a = gbps(bytes, r[i].app_s);
            s->app_sum[d] += a;
            if (a > s->app_max[d]) s->app_max[d] = a;
            s->data_sum[d] += gbps(bytes, (double)(r[i].d_last - r[i].d_first + 1) / g_clk_hz);
            s->desc[d] = r[i].desc;
            if (r[i].t_first < lo) lo = r[i].t_first;
            if (r[i].t_last > hi) hi = r[i].t_last;
            if (!r[i].ok && s->verified) {
                s->verified = 0;
                snprintf(s->note, sizeof(s->note), "%s descriptor error status",
                         d == DIR_H2D ? "H2D" : "D2H");
            }
        }
        if (n == 2) {
            double g = gbps(2 * bytes, (double)(hi - lo) / g_clk_hz);
            s->both_sum += g;
            if (g > s->both_max) s->both_max = g;
        }

        if (!p->verify || s->verified == 0)
            continue;
        /* H2D pattern: the checker clears at each H2D start */
        if (p->mode == 0 && (p->dirs & 1) && !verify_h2d_pattern(s, bytes))
            s->verified = 0;
        if (!check_now)
            continue;
        if (p->mode == 0 && (p->dirs & 2) && !verify_d2h_pattern(s, len, p->seed))
            s->verified = 0;
        if (p->mode == 1 && (p->dirs & 2) && !verify_equal(s, "D2H from RAM", buf_d2h(), buf_aux(), len))
            s->verified = 0;
    }

    /* RAM mode, H2D: read RAM[0, len) back and compare with the source */
    if (p->verify && s->verified == 1 && p->mode == 1 && (p->dirs & 1)) {
        fill_zero(buf_d2h(), len);
        if (run_single(DIR_D2H, 0, len, buf_d2h()) != 0) {
            snprintf(s->note, sizeof(s->note), "RAM read-back failed");
            s->verified = 0;
        } else if (!verify_equal(s, "H2D into RAM (read back)", buf_d2h(), buf_h2d(), len)) {
            s->verified = 0;
        }
    }
    return s->verified == 0 ? 4 : 0;
}

/* ------------------------------------------------------------ reporting */

static FILE *g_csv;

static void print_header(void)
{
    printf("\n%-7s %-4s %6s %5s %4s | %8s %8s %8s | %8s %8s | %8s | %6s | %s\n", "mode", "dir", "size",
           "desc", "runs", "fpga", "min", "max", "app", "best", "data", "both", "check");
    printf("%-7s %-4s %6s %5s %4s | %8s %8s %8s | %8s %8s | %8s | %6s |   (* = H2D and D2H at once)\n",
           "", "", "", "", "", "GB/s", "GB/s", "GB/s", "GB/s", "GB/s", "GB/s", "GB/s");
}

static void print_point(const point_t *p, const stats_t *s)
{
    char sz[24], ds[24];
    size_str(p->size, sz, sizeof(sz));
    size_str(p->size < (1ull << p->shift) ? p->size : (1ull << p->shift), ds, sizeof(ds));
    const char *chk = s->verified < 0 ? "-" : s->verified ? "ok" : "FAIL";
    for (int d = 0; d < 2; d++) {
        if (!(p->dirs & (1 << d)) || s->runs == 0)
            continue;
        double r = (double)s->runs;
        char both[16] = "";
        if (p->dirs == 3 && d == 1)
            snprintf(both, sizeof(both), "%6.3f", s->both_sum / r);
        const char *dn = p->dirs == 3 ? (d == 0 ? "h2d*" : "d2h*") : (d == 0 ? "h2d" : "d2h");
        printf("%-7s %-4s %6s %5s %4u | %8.3f %8.3f %8.3f | %8.3f %8.3f | %8.3f | %6s | %s\n",
               mode_name(p->mode), dn, sz, ds, s->runs, s->fpga_sum[d] / r,
               s->fpga_min[d], s->fpga_max[d], s->app_sum[d] / r, s->app_max[d], s->data_sum[d] / r,
               both, chk);
        if (g_csv)
            fprintf(g_csv, "%s,%s,%s,%llu,%llu,%u,%u,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s\n",
                    mode_name(p->mode), dirs_name(p->dirs), d == 0 ? "h2d" : "d2h",
                    (unsigned long long)p->size,
                    (unsigned long long)(p->size < (1ull << p->shift) ? p->size : (1ull << p->shift)),
                    p->loops, s->runs, s->desc[d], s->fpga_sum[d] / r, s->fpga_min[d], s->fpga_max[d],
                    s->app_sum[d] / r, s->app_max[d], s->data_sum[d] / r,
                    p->dirs == 3 ? s->both_sum / r : 0.0, chk);
    }
    if (s->verified == 0 || (s->runs == 0 && s->note[0]))
        printf("        ! %s\n", s->note);
    fflush(stdout);
}

/* ------------------------------------------------------------ setup */

static int dma_setup(uint64_t max_size)
{
    if (need_cap(CAP_DMA, "dma") != 0)
        exit(3);
    if (require_id() != 0)
        exit(3);
    if (rd(reg("regs.dma_version")) != reg("dma.version")) {
        fprintf(stderr, "dma: VERSION reads 0x%08X, profile expects 0x%08X\n",
                (unsigned)rd(reg("regs.dma_version")), (unsigned)reg("dma.version"));
        exit(3);
    }
    g_clk_hz    = rd(reg("regs.dma_clk_hz"));
    g_ram_bytes = rd(reg("regs.dma_ram_bytes"));
    g_pat_base  = (uint64_t)reg("dma.pat_base_hi") << 32;
    uint32_t hw_chunk = 1u << rd(reg("regs.dma_chunk_shift"));
    unsigned hw_count = rd(reg("regs.dma_chunk_count"));

    g_nb = (unsigned)((max_size + hw_chunk - 1) / hw_chunk);
    if (g_nb == 0)
        g_nb = 1;
    unsigned need = 2 + 2 * g_nb;
    if (need > hw_count || need > BAR_DMA_MAX_CHUNKS) {
        fprintf(stderr, "dma: %u chunks of %u MB needed, the engine has %u table entries\n", need,
                (unsigned)(hw_chunk >> 20), hw_count);
        exit(2);
    }
    uint32_t cb = 0;
    if (bar_dma_alloc(g_bar, need, g_pool, &cb) < 0)
        exit(1);
    if (cb != hw_chunk) {
        fprintf(stderr, "dma: driver chunk %u bytes, engine chunk %u bytes\n", (unsigned)cb,
                (unsigned)hw_chunk);
        bar_dma_free(g_bar);
        exit(2);
    }
    g_chunk = cb;
    g_npool = need;
    uint32_t tbl = reg("regs.dma_chunk_table");
    for (unsigned i = 0; i < g_npool; i++) {
        wr(tbl + 8 * i, (uint32_t)g_pool[i].bus);
        wr(tbl + 8 * i + 4, (uint32_t)(g_pool[i].bus >> 32));
    }
    uint64_t above = 0;
    for (unsigned i = 0; i < g_npool; i++)
        above += g_pool[i].bus >= (1ull << 32);
    printf("Buffers: %u x %u MB common buffers (%llu above 4 GB), status records at 0x%llX\n", g_npool,
           (unsigned)(g_chunk >> 20), (unsigned long long)above, (unsigned long long)g_pool[0].bus);
    g_seq = (uint32_t)(plat_now() * 1000.0) << 8;
    return 0;
}

static void dma_teardown(void)
{
    if (g_npool) {
        bar_dma_free(g_bar);
        g_npool = 0;
    }
}

/* ------------------------------------------------------------ commands */

int dma_probe(void)
{
    int bad = 0;
    uint32_t v = rd(reg("regs.dma_version"));
    printf("  DMA       VERSION 0x%04X = 0x%08X  %s\n", (unsigned)reg("regs.dma_version"), (unsigned)v,
           v == reg("dma.version") ? "ok" : "FAIL");
    bad += v != reg("dma.version");
    uint32_t clk = rd(reg("regs.dma_clk_hz")), ram = rd(reg("regs.dma_ram_bytes"));
    uint32_t st = rd(reg("regs.dma_status"));
    printf("  DMA       PORT %u, clock %u Hz, RAM %u KB, chunks %u x %u KB, STATUS 0x%X  %s\n",
           (unsigned)rd(reg("regs.port_index")), (unsigned)clk, (unsigned)(ram >> 10),
           (unsigned)rd(reg("regs.dma_chunk_count")), (unsigned)((1u << rd(reg("regs.dma_chunk_shift"))) >> 10),
           (unsigned)st, (st & 3u) ? "busy" : "ok (idle)");
    bad += (st & 3u) != 0;
    return bad;
}

static void dma_usage(void)
{
    printf("dma info                         driver DMA state, link, MPS/MRRS, engine state\n"
           "dma run   [options]              one test point (default: pattern h2d 4M)\n"
           "dma bench [options]              matrix: modes x directions x sizes\n"
           "options:\n"
           "  --dir h2d|d2h|both             run: direction; bench: comma list (default all)\n"
           "  --mode pattern|ram             run: mode; bench: comma list (default both)\n"
           "  --size BYTES                   run: bytes per transfer, multiple of 32 (default 4M)\n"
           "  --min BYTES --max BYTES        bench: size range, powers of two (default 4K..64M)\n"
           "  --desc BYTES                   descriptor size, power of two 256..512K (default 512K)\n"
           "  --loops N                      FPGA repeats each transfer N times (default 1)\n"
           "  --repeat N                     host repetitions per point (run 1; bench automatic)\n"
           "  --seed HEX                     pattern seed (default 1234ABCD)\n"
           "  --no-verify                    skip data checks\n"
           "  --csv FILE                     bench: append one CSV line per point and direction\n"
           "GB/s = 1e9 bytes/s. fpga = first descriptor to last completion (250 MHz counter);\n"
           "app = host time from the start write to the status record in host memory;\n"
           "data = first to last Avalon data beat in the FPGA; both = H2D + D2H bytes over the\n"
           "combined FPGA window.\n");
}

static int cmd_info(void)
{
    bar_info_t i;
    if (bar_get_info(g_bar, &i) == 0)
        print_link(&i);
    bar_dma_info_t di;
    if (bar_dma_info(g_bar, &di) == 0)
        printf("Driver:  DMA interface 0x%08X, 64-bit enabler %s, chunk %u MB (max %u, allocated %u), "
               "command 0x%04X\n", (unsigned)di.version, di.enabled ? "yes" : "NO",
               (unsigned)(di.chunk_bytes >> 20), (unsigned)di.max_chunks,
               (unsigned)di.allocated, (unsigned)di.command);
    print_pcie_cfg();
    if (need_cap(CAP_DMA, "dma info") != 0)
        return 3;
    printf("Engine:  VERSION 0x%08X, PORT %u, clock %u Hz, RAM %u KB, chunk table %u x %u KB\n",
           (unsigned)rd(reg("regs.dma_version")), (unsigned)rd(reg("regs.port_index")),
           (unsigned)rd(reg("regs.dma_clk_hz")), (unsigned)(rd(reg("regs.dma_ram_bytes")) >> 10),
           (unsigned)rd(reg("regs.dma_chunk_count")), (unsigned)((1u << rd(reg("regs.dma_chunk_shift"))) >> 10));
    printf("STATUS:  0x%X\n", (unsigned)rd(reg("regs.dma_status")));
    dump_dir(DIR_H2D);
    dump_dir(DIR_D2H);
    uint32_t base = reg("regs.dma_chk");
    printf("Checker: %u bad dwords since the last H2D start\n", (unsigned)rd(base + reg("dma.chk_err")));
    print_temp_line();
    return 0;
}

int cmd_dma(int argc, char **argv)
{
    if (argc < 1 || !strcmp(argv[0], "help")) {
        dma_usage();
        return argc < 1 ? 2 : 0;
    }
    const char *sub = argv[0];
    if (!strcmp(sub, "info"))
        return cmd_info();
    int bench = !strcmp(sub, "bench");
    if (!bench && strcmp(sub, "run")) {
        dma_usage();
        return 2;
    }

    const char *dirs = bench ? "h2d,d2h,both" : "h2d";
    const char *modes = bench ? "pattern,ram" : "pattern";
    uint64_t size = 4u << 20, smin = 4096, smax = 64u << 20, desc = 512 * 1024;
    unsigned loops = 1, repeat = 0;
    uint32_t seed = 0x1234ABCDu;
    int verify = 1;
    const char *csv = NULL;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--no-verify")) { verify = 0; continue; }
        if (!v) { fprintf(stderr, "dma: %s needs a value\n", a); return 2; }
        i++;
        if (!strcmp(a, "--dir")) dirs = v;
        else if (!strcmp(a, "--mode")) modes = v;
        else if (!strcmp(a, "--size")) { if (parse_size(v, &size)) goto bad_value; }
        else if (!strcmp(a, "--min")) { if (parse_size(v, &smin)) goto bad_value; }
        else if (!strcmp(a, "--max")) { if (parse_size(v, &smax)) goto bad_value; }
        else if (!strcmp(a, "--desc")) { if (parse_size(v, &desc)) goto bad_value; }
        else if (!strcmp(a, "--loops")) loops = (unsigned)strtoul(v, NULL, 0);
        else if (!strcmp(a, "--repeat")) repeat = (unsigned)strtoul(v, NULL, 0);
        else if (!strcmp(a, "--seed")) seed = (uint32_t)strtoul(v, NULL, 16);
        else if (!strcmp(a, "--csv")) csv = v;
        else { fprintf(stderr, "dma: unknown option %s\n", a); return 2; }
        continue;
    bad_value:
        fprintf(stderr, "dma: bad size '%s' for %s\n", v, a);
        return 2;
    }
    int shift = log2u(desc);
    if ((1ull << shift) != desc || shift < 8 || shift > 19) {
        fprintf(stderr, "dma: --desc must be a power of two from 256 to 512K\n");
        return 2;
    }
    if (loops < 1 || loops > 65535) {
        fprintf(stderr, "dma: --loops must be 1..65535\n");
        return 2;
    }
    int dmask = 0, mmask = 0;
    if (strstr(dirs, "h2d")) dmask |= 1;
    if (strstr(dirs, "d2h")) dmask |= 2;
    if (strstr(dirs, "both")) dmask |= 4;
    if (strstr(modes, "pattern")) mmask |= 1;
    if (strstr(modes, "ram")) mmask |= 2;
    if (!dmask || !mmask) {
        fprintf(stderr, "dma: --dir takes h2d, d2h, both; --mode takes pattern, ram\n");
        return 2;
    }
    if (!bench) {
        if ((dmask & (dmask - 1)) || (mmask & (mmask - 1))) {
            fprintf(stderr, "dma run: give exactly one --dir and one --mode (use 'dma bench' for lists)\n");
            return 2;
        }
        smin = smax = size;
        if (repeat == 0)
            repeat = 1;
        if (mmask == 2 && !need_cap(CAP_DMA, "dma run")) {
            uint64_t ram = rd(reg("regs.dma_ram_bytes"));
            uint64_t lim = dmask == 4 ? ram / 2 : ram;
            if (size > lim) {
                fprintf(stderr, "dma run: ram mode holds at most %llu bytes for --dir %s\n",
                        (unsigned long long)lim, dirs);
                return 2;
            }
        }
    }
    if (smin < 32 || smin % 32 || smax % 32 || smax > 0xFFFFFFE0ull || smin > smax) {
        fprintf(stderr, "dma: sizes must be multiples of 32 bytes, at most 4 GB - 32\n");
        return 2;
    }

    dma_setup(smax);
    char ts[32];
    plat_timestamp(ts, sizeof(ts));
    bar_info_t bi;
    if (bar_get_info(g_bar, &bi) == 0)
        print_link(&bi);
    print_pcie_cfg();
    printf("Engine:  clock %u Hz, RAM %u KB, pattern window 0x%llX, seed 0x%08X, loops %u\n",
           (unsigned)g_clk_hz, (unsigned)(g_ram_bytes >> 10), (unsigned long long)g_pat_base,
           (unsigned)seed, loops);
    printf("Start:   %s\n", ts);
    print_temp_line();

    /* pattern source for H2D, once for the largest size */
    if (mmask & 1)
        fill_pattern(buf_h2d(), smax, seed);

    if (csv) {
        g_csv = fopen(csv, "a");
        if (!g_csv) {
            fprintf(stderr, "dma: cannot open %s\n", csv);
            dma_teardown();
            return 2;
        }
        fprintf(g_csv, "# %s fpga1768 dma %s, seed 0x%08X, loops %u\n", ts, sub, (unsigned)seed, loops);
        fprintf(g_csv, "mode,dirs,dir,size,desc,loops,runs,descriptors,fpga_gbps,fpga_min,fpga_max,"
                       "app_gbps,app_best,data_gbps,both_gbps,check\n");
    }

    print_header();
    int rc = 0;
    for (int m = 0; m < 2 && rc != 6; m++) {
        if (!(mmask & (1 << m)))
            continue;
        for (int dsel = 0; dsel < 3 && rc != 6; dsel++) {
            if (!(dmask & (1 << dsel)))
                continue;
            int dirsv = dsel == 0 ? 1 : dsel == 1 ? 2 : 3;
            for (uint64_t sz = smin; sz <= smax; sz = bench ? sz * 2 : smax + 1) {
                if (m == 1) {
                    uint64_t lim = dirsv == 3 ? g_ram_bytes / 2 : g_ram_bytes;
                    if (sz > lim) {
                        if (!bench)
                            fprintf(stderr, "dma: ram mode holds at most %llu bytes for this direction\n",
                                    (unsigned long long)lim);
                        if (!bench) rc = 2;
                        break;
                    }
                }
                point_t p = { m, dirsv, sz, shift, loops, repeat, verify, seed };
                if (!p.repeat) {
                    /* about 256 MB of traffic per point, 3..2000 runs */
                    uint64_t r = (256ull << 20) / (sz * loops);
                    p.repeat = r < 3 ? 3 : r > 2000 ? 2000 : (unsigned)r;
                }
                stats_t s;
                int prc = run_point(&p, &s);
                print_point(&p, &s);
                if (prc > rc)
                    rc = prc;
                if (prc == 6)
                    break;
            }
        }
    }

    plat_timestamp(ts, sizeof(ts));
    printf("\nEnd:     %s\n", ts);
    print_temp_line();
    if (g_csv) {
        fclose(g_csv);
        g_csv = NULL;
    }
    dma_teardown();
    if (rc == 4)
        printf("Result:  DATA ERRORS (see '!' lines)\n");
    else if (rc == 6)
        printf("Result:  TIMEOUT (engine aborted)\n");
    else if (rc == 0)
        printf("Result:  %s\n", verify ? "all points completed and verified" : "all points completed (not verified)");
    return rc;
}
