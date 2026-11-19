/*
 * cap_ddr.c — DDR4 commands (CAPS bit 0; project 05_ddr4)
 *
 *   ddr status                   calibration, quiesce and persona state
 *   ddr test [options]           run the loaded test persona on one or both channels
 *   ddr quiesce on|off           stop / resume the persona's DDR traffic
 *   ddr peek CH ADDR             read one 576-bit word through the shell mailbox
 *   ddr poke CH ADDR VALUE       write one word (VALUE repeated 18 times)
 *
 * BAR0 offsets come from the profile ([regs] ddr_*, persona_win; [ddr]
 * constants). The DDR test persona registers are relative to the persona
 * window and fixed by the persona ABI. Register maps: projects/05_ddr4/README.md.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tool.h"

/* Persona registers, relative to regs.persona_win (DDR test personas, ABI 1) */
#define P_ID             0x000u
#define P_CTRL           0x004u
#define P_START          0x008u
#define P_END            0x00Cu
#define P_SEED           0x010u
#define P_STATUS         0x014u
#define P_CAPS           0x018u
#define P_CH(c)          ((c) ? 0x800u : 0x400u)

#define DEFAULT_LAST_WORD 0x1FFFFFFu   /* usage text only, when the profile has no ddr.last_word */

static struct {
    uint32_t status, quiesce, mbox_ctrl, mbox_addr, mbox_go, mbox_status, info;
    uint32_t mbox_wdata, mbox_rdata, pwin;
    uint32_t word_bytes, last_word;
    double   usr_clk_hz;
} R;

static void load_regs(void)
{
    R.status      = reg("regs.ddr_status");
    R.quiesce     = reg("regs.ddr_quiesce");
    R.mbox_ctrl   = reg("regs.ddr_mbox_ctrl");
    R.mbox_addr   = reg("regs.ddr_mbox_addr");
    R.mbox_go     = reg("regs.ddr_mbox_go");
    R.mbox_status = reg("regs.ddr_mbox_status");
    R.info        = reg("regs.ddr_info");
    R.mbox_wdata  = reg("regs.ddr_mbox_wdata");
    R.mbox_rdata  = reg("regs.ddr_mbox_rdata");
    R.pwin        = reg("regs.persona_win");
    R.word_bytes  = reg("ddr.word_bytes");
    R.last_word   = reg("ddr.last_word");
    R.usr_clk_hz  = (double)reg("ddr.user_clock_hz");
}

static uint32_t prd(uint32_t off)
{
    return rd(R.pwin + off);
}

static void pwr(uint32_t off, uint32_t v)
{
    wr(R.pwin + off, v);
}

static const char *ch_name[2] = { "top", "bottom" };

static int require_ddr(void)
{
    if (require_id() != 0)
        return -1;
    if (need_cap(CAP_DDR4, "ddr") != 0)
        return -1;
    load_regs();
    return 0;
}

static unsigned ch_status(uint32_t st, int c)
{
    return (st >> (8 * c)) & 0xFu;
}

void ddr_print_info(void)
{
    load_regs();
    uint32_t st = rd(R.status);
    printf("Shell:   0x%08X, DDR_INFO 0x%08X, quiesce %s\n", (unsigned)rd(reg("regs.shell_id")),
           (unsigned)rd(R.info), (st >> 16) & 1u ? "REQUESTED" : "off");
    for (int c = 0; c < 2; c++) {
        unsigned s = ch_status(st, c);
        printf("DDR %-6s cal %s%s, user reset %s, quiesced %u\n", ch_name[c],
               (s & 1u) ? "SUCCESS" : "-", (s & 2u) ? " FAIL" : "",
               (s & 4u) ? "released" : "ASSERTED", (s >> 3) & 1u);
    }
    uint32_t pid = prd(P_ID);
    printf("Persona: window ID 0x%08X", (unsigned)pid);
    if ((pid >> 16) == 1u) {
        uint32_t caps = prd(P_CAPS);
        printf(" (DDR test ABI 1, pattern %s%s)\n",
               (caps & 0xFFu) == 1 ? "walking one" : (caps & 0xFFu) == 2 ? "PRBS-31" : "?",
               (caps >> 8) & 1u ? ", address test" : "");
        uint32_t ps = prd(P_STATUS);
        for (int c = 0; c < 2; c++) {
            unsigned s = (ps >> (8 * c)) & 0xFFu;
            printf("  %-6s busy %u, errors %u, first error %u, aborted %u, runs %u\n", ch_name[c],
                   s & 1u, (s >> 1) & 1u, (s >> 2) & 1u, (s >> 3) & 1u,
                   (unsigned)(prd(P_CH(c) + 0x1Cu) & 0xFFFFu));
        }
    } else {
        printf(" (no DDR test persona)\n");
    }
}

int ddr_quiesce(int on, double timeout_s)
{
    load_regs();
    wr(R.quiesce, on ? 1u : 0u);
    if (!on)
        return 0;
    double t0 = plat_now();
    for (;;) {
        uint32_t st = rd(R.status);
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
        uint32_t e = prd(base + 0x100u + 4u * i), a = prd(base + 0x200u + 4u * i);
        if (e != a)
            printf("    %2u    0x%08X 0x%08X 0x%08X\n", i, (unsigned)e, (unsigned)a, (unsigned)(e ^ a));
    }
}

static int report_channel(int c)
{
    uint32_t b = P_CH(c);
    uint32_t err = prd(b + 0x00u), wb = prd(b + 0x04u), rb = prd(b + 0x08u);
    uint32_t wc = prd(b + 0x0Cu), rc = prd(b + 0x10u), fa = prd(b + 0x14u), fl = prd(b + 0x18u);
    uint32_t l0 = prd(b + 0x20u), l1 = prd(b + 0x24u), l2 = prd(b + 0x28u);
    double ws = wc / R.usr_clk_hz, rs = rc / R.usr_clk_hz;
    double wbytes = (double)R.word_bytes;

    printf("%s channel:\n", ch_name[c]);
    printf("  written %u words (%.1f MiB) in %.3f s = %.0f MB/s\n", (unsigned)wb,
           wb * wbytes / 1048576.0, ws, ws > 0 ? wb * wbytes / ws / 1e6 : 0.0);
    printf("  read    %u words (%.1f MiB) in %.3f s = %.0f MB/s\n", (unsigned)rb,
           rb * wbytes / 1048576.0, rs, rs > 0 ? rb * wbytes / rs / 1e6 : 0.0);
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
    unsigned long start = 0, end = R.last_word, seed = 1;
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
    if (mask == 0 || end > R.last_word || start > end) {
        fprintf(stderr, "ddr test: bad channel or range (words 0..0x%X)\n", (unsigned)R.last_word);
        return 2;
    }

    uint32_t pid = prd(P_ID);
    if ((pid >> 16) != 1u) {
        fprintf(stderr, "No DDR test persona loaded (BAR0 + 0x%X = 0x%08X).\n", (unsigned)R.pwin,
                (unsigned)pid);
        return 3;
    }
    if (at && !((prd(P_CAPS) >> 8) & 1u)) {
        fprintf(stderr, "The loaded persona has no address test.\n");
        return 2;
    }
    uint32_t st = rd(R.status);
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
           (end - start + 1) * (double)R.word_bytes / 1048576.0, seed,
           at ? " address-test" : "", (phases & 1) ? " write" : "", (phases & 2) ? " read" : "",
           inv ? " (inverted)" : "");
    print_temp_line();

    pwr(P_START, (uint32_t)start);
    pwr(P_END, (uint32_t)end);
    pwr(P_SEED, (uint32_t)seed);
    uint32_t ctrl = ((uint32_t)(phases | (inv << 2) | (at << 3)) << 8) | ((uint32_t)mask << 4);
    pwr(P_CTRL, ctrl | 1u);

    double t0 = plat_now(), tlast = t0;
    int aborted = 0;
    for (;;) {
        uint32_t ps = prd(P_STATUS);
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
            pwr(P_CTRL, ctrl | 2u);
            aborted = 1;
        }
        if (aborted && now - t0 > timeout + 5.0) {
            fprintf(stderr, "Run did not stop after abort.\n");
            return 6;
        }
        plat_sleep_ms(20);
    }
    if (aborted)
        pwr(P_CTRL, ctrl);
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
    if (ddr_quiesce(1, 2.0) != 0) {
        fprintf(stderr, "DDR ports did not quiesce.\n");
        ddr_quiesce(0, 0.0);
        return -1;
    }
    wr(R.mbox_ctrl, (uint32_t)c | (write ? 2u : 0u));
    wr(R.mbox_addr, addr);
    wr(R.mbox_go, 1u);
    double t0 = plat_now();
    uint32_t s;
    while (((s = rd(R.mbox_status)) >> (8 * c)) & 1u) {
        if (plat_now() - t0 > 1.0) {
            fprintf(stderr, "Mailbox timeout.\n");
            ddr_quiesce(0, 0.0);
            return -1;
        }
    }
    ddr_quiesce(0, 0.0);
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
        printf("  %2u: 0x%08X\n", i, (unsigned)rd(R.mbox_rdata + 4u * i));
    return 0;
}

static int ddr_poke(int c, uint32_t addr, uint32_t value)
{
    for (unsigned i = 0; i < 18; i++)
        wr(R.mbox_wdata + 4u * i, value);
    if (mbox_op(c, addr, 1) != 0)
        return 6;
    printf("%s word 0x%07X <- 18 x 0x%08X\n", ch_name[c], (unsigned)addr, (unsigned)value);
    return 0;
}

static void ddr_usage(void)
{
    uint32_t last = DEFAULT_LAST_WORD;
    (void)profile_u32(g_prof, "ddr.last_word", &last);
    printf("ddr status\n"
           "ddr test [--ch top|bot|both] [--start W] [--end W] [--seed S] [--invert]\n"
           "         [--addr-test] [--no-write] [--no-read] [--timeout SEC] [--temp-every SEC]\n"
           "         W = 576-bit word address, 0..0x%X per channel (72 bytes per word)\n"
           "ddr quiesce on|off\n"
           "ddr peek top|bot ADDR\n"
           "ddr poke top|bot ADDR VALUE32\n", (unsigned)last);
}

int cmd_ddr(int argc, char **argv)
{
    if (argc < 1 || !strcmp(argv[0], "help")) {
        ddr_usage();
        return argc < 1 ? 2 : 0;
    }
    if (require_ddr() != 0)
        return 3;
    const char *sub = argv[0];
    if (!strcmp(sub, "status")) {
        print_temp_line();
        ddr_print_info();
        return 0;
    }
    if (!strcmp(sub, "test"))
        return ddr_test(argc - 1, argv + 1);
    if (!strcmp(sub, "quiesce") && argc == 2) {
        int on = !strcmp(argv[1], "on");
        int rc = ddr_quiesce(on, 2.0);
        printf("Quiesce %s%s\n", on ? "on" : "off", rc ? " (ports did NOT drain)" : "");
        return rc ? 6 : 0;
    }
    if (!strcmp(sub, "peek") && argc == 3 && parse_ch(argv[1]) >= 0)
        return ddr_peek(parse_ch(argv[1]), (uint32_t)parse_ul(argv[2]) & R.last_word);
    if (!strcmp(sub, "poke") && argc == 4 && parse_ch(argv[1]) >= 0)
        return ddr_poke(parse_ch(argv[1]), (uint32_t)parse_ul(argv[2]) & R.last_word,
                        (uint32_t)parse_ul(argv[3]));
    ddr_usage();
    return 2;
}
