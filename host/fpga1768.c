/*
 * fpga1768.c — shared host tool for the lab's PCIe designs (projects 03 and up)
 *
 * BAR0 register access, die temperature, and loading of persona PR bitstreams
 * over PCIe (projects/04_pcie_hot_update). Runs on Linux (sysfs mmap,
 * bar_linux.c) and Windows (KMDF test driver, bar_windows.c). See README.md in
 * this directory and the README of each project for the register maps.
 *
 *   fpga1768 [--bdf BDF] <command> [args]
 *
 *   info                 device, link, BAR0 and all registers
 *   read OFF             read 32 bits at BAR0 + OFF (hex)
 *   write OFF VAL        write 32 bits at BAR0 + OFF (hex)
 *   temp [SEC [COUNT]]   print the die temperature; every SEC seconds
 *   persona              write A, B and check SUM against the loaded persona
 *   load-pr FILE         load a persona .rbf over PCIe, check that link and
 *                        BAR0 did not change, then run the persona test
 *   selftest             offline checks (no device needed)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bar_access.h"
#include "sha256.h"
#include "tool.h"

/* Project 03/04 registers (A + B persona). */
#define REG_A        0x00u
#define REG_B        0x10u
#define REG_SUM      0x20u

#define PR_VERSION   0xAA500003u  /* alt_pr CSR_VERSION, Quartus Prime Pro 25.1 */

#define TEMP_NOTE_C  95.0         /* readings at or above this are flagged, nothing else */

bar_t *g_bar;

uint32_t rd(uint32_t off)
{
    uint32_t v = 0;
    if (bar_read32(g_bar, off, &v) != 0)
        exit(5);
    return v;
}

void wr(uint32_t off, uint32_t v)
{
    if (bar_write32(g_bar, off, v) != 0)
        exit(5);
}

int is_shell(void)
{
    return rd(REG_SHELL_ID) == SHELL_ID_V1;
}

static double temp_c(uint32_t reg)
{
    /* [9:0] latched code; vendor formula for the Arria 10 sensor. */
    return (double)(reg & 0x3FFu) * 693.0 / 1024.0 - 265.0;
}

double temp_now(void)
{
    return temp_c(rd(REG_TEMP));
}

void print_temp_line(void)
{
    char ts[32];
    uint32_t t = rd(REG_TEMP);
    double c = temp_c(t);
    plat_timestamp(ts, sizeof(ts));
    printf("%s TEMP reg=0x%08X conv=%u code=%u degC=%.1f%s\n", ts, (unsigned)t,
           (unsigned)(t >> 28), (unsigned)(t & 0x3FFu), c,
           c >= TEMP_NOTE_C ? "  (>= 95 degC, recorded)" : "");
    fflush(stdout);
}

static const char *pr_status_name(unsigned s)
{
    static const char *n[8] = { "idle", "PR_ERROR", "CRC_ERROR", "INCOMPATIBLE_BITSTREAM",
                                "IN_PROGRESS", "SUCCESS", "?", "?" };
    return n[s & 7u];
}

static unsigned pr_status(void)
{
    return (rd(REG_PR_CSR) >> 2) & 7u;
}

static int has_pr_controller(void)
{
    return rd(REG_PR_VER) == PR_VERSION;
}

static void print_link(const bar_info_t *i)
{
    printf("Device:  %s\n", i->location);
    printf("IDs:     %04X:%04X\n", (unsigned)i->vendor_id, (unsigned)i->device_id);
    printf("BAR0:    0x%llX length 0x%X\n", (unsigned long long)i->bar_phys,
           (unsigned)i->bar_length);
    if (i->link_speed > 0)
        printf("Link:    Gen%d x%d\n", i->link_speed, i->link_width);
    else
        printf("Link:    unknown\n");
}

static void print_persona(void)
{
    uint32_t p = rd(REG_PERSONA), csr = rd(REG_PR_CSR);
    printf("PERSONA: 0x%08X (id 0x%04X, freeze %u, reset %u, PR clock locked %u)\n",
           (unsigned)p, (unsigned)(p & 0xFFFFu), (unsigned)((p >> 16) & 1u),
           (unsigned)((p >> 17) & 1u), (unsigned)((p >> 18) & 1u));
    printf("PR CSR:  0x%08X (status %u %s), version 0x%08X, bitstream ID 0x%08X\n",
           (unsigned)csr, (unsigned)((csr >> 2) & 7u), pr_status_name((csr >> 2) & 7u),
           (unsigned)rd(REG_PR_VER), (unsigned)rd(REG_PR_ID));
}

int require_id(void)
{
    uint32_t id = rd(REG_ID);
    if (id != ID_VALUE) {
        fprintf(stderr, "ID register 0x%08X, expected 0x%08X: wrong bitstream loaded.\n",
                (unsigned)id, (unsigned)ID_VALUE);
        return -1;
    }
    return 0;
}

static int require_pr(void)
{
    if (require_id() != 0)
        return -1;
    if (!has_pr_controller()) {
        fprintf(stderr, "No PR controller at BAR0 + 0x108 (expected version 0x%08X).\n"
                        "Is projects/04_pcie_hot_update loaded?\n", (unsigned)PR_VERSION);
        return -1;
    }
    if (!((rd(REG_PERSONA) >> 18) & 1u)) {
        fprintf(stderr, "PR controller clock PLL not locked (PERSONA bit 18 = 0).\n");
        return -1;
    }
    return 0;
}

/* ---------------------------------------------------------------- info */

static int cmd_info(void)
{
    bar_info_t i;
    if (bar_get_info(g_bar, &i) != 0)
        return 5;
    print_link(&i);
    uint32_t c1 = rd(REG_COUNTER), c2 = rd(REG_COUNTER);
    printf("ID:      0x%08X%s\n", (unsigned)rd(REG_ID),
           rd(REG_ID) == ID_VALUE ? "" : "  (unexpected)");
    printf("A:       0x%08X\n", (unsigned)rd(REG_A));
    printf("B:       0x%08X\n", (unsigned)rd(REG_B));
    printf("SUM:     0x%08X\n", (unsigned)rd(REG_SUM));
    printf("COUNTER: 0x%08X then 0x%08X (%s)\n", (unsigned)c1, (unsigned)c2,
           c1 != c2 ? "changing" : "STUCK");
    print_temp_line();
    if (has_pr_controller())
        print_persona();
    else
        printf("PR:      no PR controller (not project 04)\n");
    return 0;
}

/* ------------------------------------------------------------- persona */

static int cmd_persona(void)
{
    if (require_pr() != 0)
        return 3;
    const uint32_t a = 0x12345678u, b = 0x11111111u;
    print_persona();
    wr(REG_A, a);
    wr(REG_B, b);
    uint32_t sum = rd(REG_SUM);
    unsigned id = rd(REG_PERSONA) & 0xFFFFu;
    uint32_t expected;
    const char *op;
    if (id == 1) {
        expected = a + b;
        op = "A + B";
    } else if (id == 2) {
        expected = a - b;
        op = "A - B";
    } else {
        fprintf(stderr, "Unknown persona ID 0x%04X; SUM 0x%08X\n", id, (unsigned)sum);
        return 4;
    }
    printf("A=0x%08X B=0x%08X  persona %u: %s\n", (unsigned)a, (unsigned)b, id, op);
    printf("SUM:     0x%08X (expected 0x%08X)\n", (unsigned)sum, (unsigned)expected);
    print_temp_line();
    if (sum != expected) {
        printf("Persona test FAILED.\n");
        return 4;
    }
    printf("Persona test PASSED.\n");
    return 0;
}

/* ------------------------------------------------------------- load-pr */

static uint8_t *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0) {
        fprintf(stderr, "%s: empty file\n", path);
        fclose(f);
        return NULL;
    }
    /* Room for zero padding to a whole 32-bit word. */
    uint8_t *buf = calloc((size_t)n + 4, 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "%s: read error\n", path);
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

/*
 * Protocol of the Partial Reconfiguration Controller (alt_pr, internal host,
 * Avalon-MM slave), from its RTL in Quartus Prime Pro 25.1:
 *   - write 1 to CSR bit 0: PR starts, freeze rises, status [4:2] = 4;
 *   - write every 32-bit word of the .rbf, little-endian, to the data port;
 *     the slave applies back-pressure (waitrequest) while the device consumes it;
 *   - when the bitstream is complete, freeze falls and status becomes
 *     5 (success), or 1/2/3 on PR error / CRC error / incompatible bitstream.
 */
static int cmd_load_pr(const char *path)
{
    if (require_pr() != 0)
        return 3;

    size_t len = 0;
    uint8_t *data = read_file(path, &len);
    if (!data)
        return 2;
    uint8_t digest[32];
    sha256(data, len, digest);
    size_t words = (len + 3) / 4;

    printf("File:    %s (%zu bytes, %zu words%s)\n", path, len, words,
           len % 4 ? ", zero-padded to a whole word" : "");
    printf("SHA-256: ");
    for (int i = 0; i < 32; i++)
        printf("%02X", digest[i]);
    printf("\n\n-- before\n");

    bar_info_t before, after;
    if (bar_get_info(g_bar, &before) != 0) {
        free(data);
        return 5;
    }
    print_link(&before);
    print_persona();
    print_temp_line();

    if (pr_status() == 4) {
        fprintf(stderr, "PR controller already IN_PROGRESS; not starting another load.\n");
        free(data);
        return 6;
    }

    double t0 = plat_now();
    wr(REG_PR_CSR, 1u);
    unsigned st = pr_status();
    printf("\n-- load\nStart:   status %u %s\n", st, pr_status_name(st));
    if (st != 4) {
        fprintf(stderr, "PR did not start.\n");
        free(data);
        return 6;
    }

    size_t step = words / 10 ? words / 10 : 1;
    for (size_t i = 0; i < words; i++) {
        uint32_t w = (uint32_t)data[4 * i] | (uint32_t)data[4 * i + 1] << 8 |
                     (uint32_t)data[4 * i + 2] << 16 | (uint32_t)data[4 * i + 3] << 24;
        wr(REG_PR_DATA, w);
        if ((i + 1) % step == 0) {
            printf("\r  %3u%%  %zu/%zu words", (unsigned)((i + 1) * 100 / words), i + 1, words);
            fflush(stdout);
        }
    }
    double t_data = plat_now() - t0;
    printf("\n");
    free(data);

    double tp = plat_now();
    while ((st = pr_status()) == 4) {
        if (plat_now() - tp > 5.0) {
            fprintf(stderr, "Timeout: still IN_PROGRESS 5 s after the last word.\n");
            break;
        }
        plat_sleep_ms(1);
    }
    double t_total = plat_now() - t0;
    printf("Result:  status %u %s; data %.3f s (%.2f MB/s), total %.3f s\n", st,
           pr_status_name(st), t_data, (double)len / 1048576.0 / (t_data > 0 ? t_data : 1e-9),
           t_total);

    plat_sleep_ms(10);
    printf("\n-- after\n");
    if (bar_get_info(g_bar, &after) != 0)
        return 5;
    print_link(&after);
    print_persona();
    print_temp_line();

    int same_bar = before.bar_phys == after.bar_phys && before.bar_length == after.bar_length;
    int same_link = before.link_speed == after.link_speed && before.link_width == after.link_width;
    printf("Check:   BAR0 %s, link %s, ID 0x%08X\n", same_bar ? "unchanged" : "CHANGED",
           same_link ? "unchanged" : "CHANGED", (unsigned)rd(REG_ID));

    if (st != 5)
        return 7;
    if (!same_bar || !same_link || rd(REG_ID) != ID_VALUE)
        return 8;
    printf("\n-- persona test\n");
    return cmd_persona();
}

/* ---------------------------------------------------------------- temp */

static int cmd_temp(double interval, long count)
{
    for (long n = 0;; n++) {
        print_temp_line();
        if (interval <= 0 || (count > 0 && n + 1 >= count))
            return 0;
        plat_sleep_ms((unsigned)(interval * 1000.0));
    }
}

/* ------------------------------------------------------------ selftest */

static int cmd_selftest(void)
{
    static const uint8_t abc_ref[32] = {
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad };
    uint8_t d[32];
    sha256((const uint8_t *)"abc", 3, d);
    int ok = memcmp(d, abc_ref, 32) == 0;
    printf("sha256(\"abc\"): %s\n", ok ? "ok" : "FAILED");
    uint32_t a = 0x12345678u, b = 0x11111111u;
    printf("A+B = 0x%08X, A-B = 0x%08X\n", (unsigned)(a + b), (unsigned)(a - b));
    return ok ? 0 : 1;
}

/* ---------------------------------------------------------------- main */

static void usage(void)
{
    printf("usage: fpga1768 [--bdf BDF] <command> [args]\n\n"
           "  info                 device, link, BAR0 and all registers\n"
           "  read OFF             read 32 bits at BAR0 + OFF (hex)\n"
           "  write OFF VAL        write 32 bits at BAR0 + OFF (hex)\n"
           "  temp [SEC [COUNT]]   die temperature, once or every SEC seconds\n"
           "  persona              write A, B and check SUM against the loaded persona\n"
           "  load-pr FILE         load a persona PR bitstream (.rbf), verify link/BAR,\n"
           "                       then run the persona test\n"
           "  selftest             offline checks\n\n"
           "--bdf selects the PCI device on Linux (default: first %04x:%04x).\n",
           LAB_VENDOR_ID, LAB_DEVICE_ID);
}

int main(int argc, char **argv)
{
    const char *bdf = NULL;
    int ai = 1;
    if (ai + 1 < argc && strcmp(argv[ai], "--bdf") == 0) {
        bdf = argv[ai + 1];
        ai += 2;
    }
    if (ai >= argc || !strcmp(argv[ai], "-h") || !strcmp(argv[ai], "--help")) {
        usage();
        return ai >= argc ? 2 : 0;
    }
    const char *cmd = argv[ai++];
    int nargs = argc - ai;

    if (!strcmp(cmd, "selftest"))
        return cmd_selftest();

    if (bar_open(&g_bar, bdf) != 0)
        return 1;

    int rc;
    if (!strcmp(cmd, "info")) {
        rc = cmd_info();
    } else if (!strcmp(cmd, "read") && nargs == 1) {
        uint32_t off = (uint32_t)strtoul(argv[ai], NULL, 16);
        printf("0x%04X: 0x%08X\n", (unsigned)off, (unsigned)rd(off));
        rc = 0;
    } else if (!strcmp(cmd, "write") && nargs == 2) {
        if (require_id() != 0) {
            rc = 3;
        } else {
            uint32_t off = (uint32_t)strtoul(argv[ai], NULL, 16);
            wr(off, (uint32_t)strtoul(argv[ai + 1], NULL, 16));
            printf("0x%04X <- 0x%08X\n", (unsigned)off, (unsigned)strtoul(argv[ai + 1], NULL, 16));
            rc = 0;
        }
    } else if (!strcmp(cmd, "temp") && nargs <= 2) {
        rc = cmd_temp(nargs >= 1 ? atof(argv[ai]) : 0.0, nargs >= 2 ? atol(argv[ai + 1]) : 0);
    } else if (!strcmp(cmd, "persona") && nargs == 0) {
        rc = cmd_persona();
    } else if (!strcmp(cmd, "load-pr") && nargs == 1) {
        rc = cmd_load_pr(argv[ai]);
    } else if (!strcmp(cmd, "ddr")) {
        rc = cmd_ddr(nargs, argv + ai);
    } else if (!strcmp(cmd, "flash-dump")) {
        rc = cmd_flash_dump(nargs, argv + ai);
    } else {
        usage();
        rc = 2;
    }

    bar_close(g_bar);
    return rc;
}
