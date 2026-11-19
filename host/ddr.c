/*
 * ddr.c — fpga1768 commands for the project 05 shell
 *
 *   ddr status                   calibration, quiesce and persona state
 *   ddr test [options]           run the loaded test persona on one or both channels
 *   ddr quiesce on|off           stop / resume the persona's DDR traffic
 *   ddr peek CH ADDR             read one 576-bit word through the shell mailbox
 *   ddr poke CH ADDR VALUE       write one word (VALUE repeated 18 times)
 *   flash-dump FILE [MB]         read the configuration flash (read-only window)
 *
 * Register maps: projects/05_shell/README.md.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tool.h"
#include "sha256.h"

/* Shell registers, BAR0 + 0x200 */
#define SR_BASE          0x200u
#define SR_DDR_STATUS    (SR_BASE + 0x00u)
#define SR_QUIESCE       (SR_BASE + 0x04u)
#define SR_FLASH_PAGE    (SR_BASE + 0x08u)
#define SR_MBOX_CTRL     (SR_BASE + 0x0Cu)
#define SR_MBOX_ADDR     (SR_BASE + 0x10u)
#define SR_MBOX_GO       (SR_BASE + 0x14u)
#define SR_MBOX_STATUS   (SR_BASE + 0x18u)
#define SR_DDR_INFO      (SR_BASE + 0x1Cu)
#define SR_MBOX_WDATA    (SR_BASE + 0x20u)
#define SR_MBOX_RDATA    (SR_BASE + 0x80u)

/* Persona registers, BAR0 + 0x1000 (DDR test personas, ABI 1) */
#define PR_BASE          0x1000u
#define P_ID             (PR_BASE + 0x000u)
#define P_CTRL           (PR_BASE + 0x004u)
#define P_START          (PR_BASE + 0x008u)
#define P_END            (PR_BASE + 0x00Cu)
#define P_SEED           (PR_BASE + 0x010u)
#define P_STATUS         (PR_BASE + 0x014u)
#define P_CAPS           (PR_BASE + 0x018u)
#define P_CH(c)          (PR_BASE + ((c) ? 0x800u : 0x400u))

#define FLASH_WIN        0x4000u
#define FLASH_WIN_BYTES  0x4000u
#define FLASH_BYTES      (128u * 1024u * 1024u)

#define WORD_BYTES       72u          /* 576-bit EMIF user word, ECC off */
#define LAST_WORD        0x1FFFFFFu   /* 2^25 words per channel */
#define USR_CLK_HZ       266666667.0  /* EMIF user clock, quarter rate of 1066.667 MHz */

static const char *ch_name[2] = { "top", "bottom" };

static int require_shell(void)
{
    if (require_id() != 0)
        return -1;
    if (!is_shell()) {
        fprintf(stderr, "BAR0 + 0x00 does not read 0x%08X: the project 05 shell is not loaded.\n",
                (unsigned)SHELL_ID_V1);
        return -1;
    }
    return 0;
}

static unsigned ch_status(uint32_t st, int c)
{
    return (st >> (8 * c)) & 0xFu;
}

void shell_print_info(void)
{
    uint32_t st = rd(SR_DDR_STATUS);
    printf("Shell:   0x%08X, DDR_INFO 0x%08X, quiesce %s\n", (unsigned)rd(REG_SHELL_ID),
           (unsigned)rd(SR_DDR_INFO), (st >> 16) & 1u ? "REQUESTED" : "off");
    for (int c = 0; c < 2; c++) {
        unsigned s = ch_status(st, c);
        printf("DDR %-6s cal %s%s, user reset %s, quiesced %u\n", ch_name[c],
               (s & 1u) ? "SUCCESS" : "-", (s & 2u) ? " FAIL" : "",
               (s & 4u) ? "released" : "ASSERTED", (s >> 3) & 1u);
    }
    uint32_t pid = rd(P_ID);
    printf("Persona: window ID 0x%08X", (unsigned)pid);
    if ((pid >> 16) == 1u) {
        uint32_t caps = rd(P_CAPS);
        printf(" (DDR test ABI 1, pattern %s%s)\n",
               (caps & 0xFFu) == 1 ? "walking one" : (caps & 0xFFu) == 2 ? "PRBS-31" : "?",
               (caps >> 8) & 1u ? ", address test" : "");
        uint32_t ps = rd(P_STATUS);
        for (int c = 0; c < 2; c++) {
            unsigned s = (ps >> (8 * c)) & 0xFFu;
            printf("  %-6s busy %u, errors %u, first error %u, aborted %u, runs %u\n", ch_name[c],
                   s & 1u, (s >> 1) & 1u, (s >> 2) & 1u, (s >> 3) & 1u,
                   (unsigned)(rd(P_CH(c) + 0x1Cu) & 0xFFFFu));
        }
    } else {
        printf(" (no DDR test persona)\n");
    }
}

int shell_quiesce(int on, double timeout_s)
{
    wr(SR_QUIESCE, on ? 1u : 0u);
    if (!on)
        return 0;
    double t0 = plat_now();
    for (;;) {
        uint32_t st = rd(SR_DDR_STATUS);
        int ok = 1;
        for (int c = 0; c < 2; c++) {
            unsigned s = ch_status(st, c);
            /* A channel whose user reset is asserted carries no traffic. */
            if ((s & 4u) && !(s & 8u))
                ok = 0;
        }
        if (ok)
            return 0;
        if (plat_now() - t0 > timeout_s)
            return -1;
        plat_sleep_ms(1);
    }
}

static unsigned long parse_ul(const char *s)
{
    return strtoul(s, NULL, 0);
}

static int parse_ch(const char *s)
{
    if (!strcmp(s, "top") || !strcmp(s, "0")) return 0;
    if (!strcmp(s, "bot") || !strcmp(s, "bottom") || !strcmp(s, "1")) return 1;
    return -1;
}

/* ------------------------------------------------------------ ddr test */

static void print_word_diff(uint32_t base)
{
    printf("    word  expected   actual     xor\n");
    for (unsigned i = 0; i < 18; i++) {
        uint32_t e = rd(base + 0x100u + 4u * i), a = rd(base + 0x200u + 4u * i);
        if (e != a)
            printf("    %2u    0x%08X 0x%08X 0x%08X\n", i, (unsigned)e, (unsigned)a, (unsigned)(e ^ a));
    }
}

static int report_channel(int c)
{
    uint32_t b = P_CH(c);
    uint32_t err = rd(b + 0x00u), wb = rd(b + 0x04u), rb = rd(b + 0x08u);
    uint32_t wc = rd(b + 0x0Cu), rc = rd(b + 0x10u), fa = rd(b + 0x14u), fl = rd(b + 0x18u);
    uint32_t l0 = rd(b + 0x20u), l1 = rd(b + 0x24u), l2 = rd(b + 0x28u);
    double ws = wc / USR_CLK_HZ, rs = rc / USR_CLK_HZ;

    printf("%s channel:\n", ch_name[c]);
    printf("  written %u words (%.1f MiB) in %.3f s = %.0f MB/s\n", (unsigned)wb,
           wb * (double)WORD_BYTES / 1048576.0, ws, ws > 0 ? wb * (double)WORD_BYTES / ws / 1e6 : 0.0);
    printf("  read    %u words (%.1f MiB) in %.3f s = %.0f MB/s\n", (unsigned)rb,
           rb * (double)WORD_BYTES / 1048576.0, rs, rs > 0 ? rb * (double)WORD_BYTES / rs / 1e6 : 0.0);
    printf("  error words %u%s\n", (unsigned)err, (fl & 2u) ? "  (run ABORTED)" : "");
    if (fl & 1u) {
        printf("  first error at word 0x%07X; DQ lanes with errors (mask, bit = DQ line, hypothesis):"
               " 0x%02X_%08X_%08X\n", (unsigned)fa, (unsigned)(l2 & 0xFFu), (unsigned)l1, (unsigned)l0);
        print_word_diff(b);
    }
    return (err != 0 || (fl & 2u)) ? 1 : 0;
}

static int ddr_test(int argc, char **argv)
{
    int mask = 3, phases = 0x3, inv = 0, at = 0;
    unsigned long start = 0, end = LAST_WORD, seed = 1;
    double timeout = 60.0, temp_every = 5.0;

    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!strcmp(a, "--ch") && v) {
            mask = !strcmp(v, "both") ? 3 : (parse_ch(v) == 0 ? 1 : parse_ch(v) == 1 ? 2 : 0);
            i++;
        } else if (!strcmp(a, "--start") && v) { start = parse_ul(v); i++; }
        else if (!strcmp(a, "--end") && v)     { end = parse_ul(v); i++; }
        else if (!strcmp(a, "--seed") && v)    { seed = parse_ul(v); i++; }
        else if (!strcmp(a, "--timeout") && v) { timeout = atof(v); i++; }
        else if (!strcmp(a, "--temp-every") && v) { temp_every = atof(v); i++; }
        else if (!strcmp(a, "--no-write"))     phases &= ~1;
        else if (!strcmp(a, "--no-read"))      phases &= ~2;
        else if (!strcmp(a, "--invert"))       inv = 1;
        else if (!strcmp(a, "--addr-test"))    at = 1;
        else {
            fprintf(stderr, "ddr test: unknown option %s\n", a);
            return 2;
        }
    }
    if (mask == 0 || end > LAST_WORD || start > end) {
        fprintf(stderr, "ddr test: bad channel or range (words 0..0x%X)\n", LAST_WORD);
        return 2;
    }

    uint32_t pid = rd(P_ID);
    if ((pid >> 16) != 1u) {
        fprintf(stderr, "No DDR test persona loaded (BAR0 + 0x1000 = 0x%08X).\n", (unsigned)pid);
        return 3;
    }
    if (at && !((rd(P_CAPS) >> 8) & 1u)) {
        fprintf(stderr, "The loaded persona has no address test.\n");
        return 2;
    }
    uint32_t st = rd(SR_DDR_STATUS);
    for (int c = 0; c < 2; c++) {
        if ((mask >> c) & 1) {
            unsigned s = ch_status(st, c);
            if ((s & 7u) != 5u) {
                fprintf(stderr, "%s channel not ready (cal success %u, fail %u, user reset released %u).\n",
                        ch_name[c], s & 1u, (s >> 1) & 1u, (s >> 2) & 1u);
                return 3;
            }
        }
    }
    if ((st >> 16) & 1u) {
        fprintf(stderr, "Quiesce is on (ddr quiesce off first).\n");
        return 3;
    }

    printf("Persona 0x%04X, channels %s, words 0x%07lX..0x%07lX (%.1f MiB each), seed 0x%08lX,"
           " phases%s%s%s%s\n", (unsigned)(pid & 0xFFFFu),
           mask == 3 ? "top+bottom" : ch_name[mask == 1 ? 0 : 1], start, end,
           (end - start + 1) * (double)WORD_BYTES / 1048576.0, seed,
           at ? " address-test" : "", (phases & 1) ? " write" : "", (phases & 2) ? " read" : "",
           inv ? " (inverted)" : "");
    print_temp_line();

    wr(P_START, (uint32_t)start);
    wr(P_END, (uint32_t)end);
    wr(P_SEED, (uint32_t)seed);
    uint32_t ctrl = ((uint32_t)(phases | (inv << 2) | (at << 3)) << 8) | ((uint32_t)mask << 4);
    wr(P_CTRL, ctrl | 1u);

    double t0 = plat_now(), tlast = t0;
    int aborted = 0;
    for (;;) {
        uint32_t ps = rd(P_STATUS);
        int busy = 0;
        for (int c = 0; c < 2; c++)
            if (((mask >> c) & 1) && (ps >> (8 * c)) & 1u)
                busy = 1;
        if (!busy)
            break;
        double now = plat_now();
        if (temp_every > 0 && now - tlast >= temp_every) {
            print_temp_line();
            tlast = now;
        }
        if (!aborted && now - t0 > timeout) {
            fprintf(stderr, "Timeout after %.0f s: aborting the run.\n", timeout);
            wr(P_CTRL, ctrl | 2u);
            aborted = 1;
        }
        if (aborted && now - t0 > timeout + 5.0) {
            fprintf(stderr, "Run did not stop after abort.\n");
            return 6;
        }
        plat_sleep_ms(20);
    }
    if (aborted)
        wr(P_CTRL, ctrl);
    printf("Elapsed (host): %.3f s\n", plat_now() - t0);
    print_temp_line();

    int bad = 0;
    for (int c = 0; c < 2; c++)
        if ((mask >> c) & 1)
            bad |= report_channel(c);
    printf("%s\n", bad ? "DDR test FAILED." : "DDR test PASSED.");
    return bad ? 4 : 0;
}

/* --------------------------------------------------------- mailbox */

static int mbox_op(int c, uint32_t addr, int write)
{
    if (shell_quiesce(1, 2.0) != 0) {
        fprintf(stderr, "DDR ports did not quiesce.\n");
        shell_quiesce(0, 0.0);
        return -1;
    }
    wr(SR_MBOX_CTRL, (uint32_t)c | (write ? 2u : 0u));
    wr(SR_MBOX_ADDR, addr);
    wr(SR_MBOX_GO, 1u);
    double t0 = plat_now();
    uint32_t s;
    while (((s = rd(SR_MBOX_STATUS)) >> (8 * c)) & 1u) {
        if (plat_now() - t0 > 1.0) {
            fprintf(stderr, "Mailbox timeout.\n");
            shell_quiesce(0, 0.0);
            return -1;
        }
    }
    shell_quiesce(0, 0.0);
    if ((s >> (8 * c + 1)) & 1u) {
        fprintf(stderr, "Mailbox request refused (port not quiesced).\n");
        return -1;
    }
    return 0;
}

static int ddr_peek(int c, uint32_t addr)
{
    if (mbox_op(c, addr, 0) != 0)
        return 6;
    printf("%s word 0x%07X (word 0 = bits [31:0]):\n", ch_name[c], (unsigned)addr);
    for (unsigned i = 0; i < 18; i++)
        printf("  %2u: 0x%08X\n", i, (unsigned)rd(SR_MBOX_RDATA + 4u * i));
    return 0;
}

static int ddr_poke(int c, uint32_t addr, uint32_t value)
{
    for (unsigned i = 0; i < 18; i++)
        wr(SR_MBOX_WDATA + 4u * i, value);
    if (mbox_op(c, addr, 1) != 0)
        return 6;
    printf("%s word 0x%07X <- 18 x 0x%08X\n", ch_name[c], (unsigned)addr, (unsigned)value);
    return 0;
}

static void ddr_usage(void)
{
    printf("ddr status\n"
           "ddr test [--ch top|bot|both] [--start W] [--end W] [--seed S] [--invert]\n"
           "         [--addr-test] [--no-write] [--no-read] [--timeout SEC] [--temp-every SEC]\n"
           "         W = 576-bit word address, 0..0x%X per channel (72 bytes per word)\n"
           "ddr quiesce on|off\n"
           "ddr peek top|bot ADDR\n"
           "ddr poke top|bot ADDR VALUE32\n", LAST_WORD);
}

int cmd_ddr(int argc, char **argv)
{
    if (argc < 1 || !strcmp(argv[0], "help")) {
        ddr_usage();
        return argc < 1 ? 2 : 0;
    }
    if (require_shell() != 0)
        return 3;
    const char *sub = argv[0];
    if (!strcmp(sub, "status")) {
        print_temp_line();
        shell_print_info();
        return 0;
    }
    if (!strcmp(sub, "test"))
        return ddr_test(argc - 1, argv + 1);
    if (!strcmp(sub, "quiesce") && argc == 2) {
        int on = !strcmp(argv[1], "on");
        int rc = shell_quiesce(on, 2.0);
        printf("Quiesce %s%s\n", on ? "on" : "off", rc ? " (ports did NOT drain)" : "");
        return rc ? 6 : 0;
    }
    if (!strcmp(sub, "peek") && argc == 3 && parse_ch(argv[1]) >= 0)
        return ddr_peek(parse_ch(argv[1]), (uint32_t)parse_ul(argv[2]) & LAST_WORD);
    if (!strcmp(sub, "poke") && argc == 4 && parse_ch(argv[1]) >= 0)
        return ddr_poke(parse_ch(argv[1]), (uint32_t)parse_ul(argv[2]) & LAST_WORD,
                        (uint32_t)parse_ul(argv[3]));
    ddr_usage();
    return 2;
}

/* ------------------------------------------------------- flash-dump */

int cmd_flash_dump(int argc, char **argv)
{
    if (argc < 1 || argc > 2) {
        printf("flash-dump FILE [MB]   read the first MB megabytes (default 128) of the\n"
               "                       configuration flash through the read-only window\n");
        return 2;
    }
    if (require_shell() != 0)
        return 3;
    unsigned mb = argc == 2 ? (unsigned)parse_ul(argv[1]) : 128u;
    if (mb == 0 || mb > 128u) {
        fprintf(stderr, "MB must be 1..128\n");
        return 2;
    }
    size_t bytes = (size_t)mb * 1024u * 1024u;
    uint8_t *buf = malloc(bytes);
    if (!buf) {
        fprintf(stderr, "out of memory\n");
        return 2;
    }
    FILE *f = fopen(argv[0], "wb");
    if (!f) {
        perror(argv[0]);
        free(buf);
        return 2;
    }
    print_temp_line();
    double t0 = plat_now();
    unsigned pages = (unsigned)(bytes / FLASH_WIN_BYTES);
    for (unsigned p = 0; p < pages; p++) {
        wr(SR_FLASH_PAGE, p);
        (void)rd(SR_FLASH_PAGE);   /* make sure the page write landed before the window reads */
        for (unsigned w = 0; w < FLASH_WIN_BYTES / 4u; w++) {
            uint32_t v = rd(FLASH_WIN + 4u * w);
            size_t o = (size_t)p * FLASH_WIN_BYTES + 4u * w;
            buf[o] = (uint8_t)v;
            buf[o + 1] = (uint8_t)(v >> 8);
            buf[o + 2] = (uint8_t)(v >> 16);
            buf[o + 3] = (uint8_t)(v >> 24);
        }
        if ((p + 1) % 64u == 0 || p + 1 == pages) {
            printf("\r  %u/%u MB  %.0f s", (p + 1) / 64u, mb, plat_now() - t0);
            fflush(stdout);
        }
    }
    printf("\n");
    wr(SR_FLASH_PAGE, 0u);
    if (fwrite(buf, 1, bytes, f) != bytes) {
        fprintf(stderr, "%s: write error\n", argv[0]);
        fclose(f);
        free(buf);
        return 2;
    }
    fclose(f);
    uint8_t d[32];
    sha256(buf, bytes, d);
    size_t ff = 0;
    for (size_t i = 0; i < bytes; i++)
        if (buf[i] == 0xFF)
            ff++;
    free(buf);
    printf("File:    %s, %zu bytes, %.1f s\n", argv[0], bytes, plat_now() - t0);
    printf("SHA-256: ");
    for (int i = 0; i < 32; i++)
        printf("%02X", d[i]);
    printf("\nErased (0xFF) bytes: %zu (%.1f %%)\n", ff, 100.0 * (double)ff / (double)bytes);
    print_temp_line();
    return 0;
}
