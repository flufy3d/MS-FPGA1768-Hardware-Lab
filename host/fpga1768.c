/*
 * fpga1768.c — shared host tool for the lab's PCIe designs (projects 03 and up)
 *
 * Core: finds the lab device (1172:E003), maps BAR0, reads SHELL_ID at
 * BAR0 + 0x00 and selects the matching profile (host/profiles/<project>.ini),
 * whose CAPS bits decide which capability modules may run. Runs on Linux
 * (sysfs mmap, bar_linux.c) and Windows (KMDF test driver, bar_windows.c).
 * See README.md in this directory and the README of each project.
 *
 *   fpga1768 [--bdf BDF] [--profile NAME] <command> [args]
 *
 *   list                 list the profiles found (no device needed)
 *   probe                check SHELL_ID, CAPS and the profile's offsets (read only)
 *   info                 device, link, BAR0 and all registers
 *   read OFF             read 32 bits at BAR0 + OFF (hex)
 *   write OFF VAL        write 32 bits at BAR0 + OFF (hex)
 *   temp [SEC [COUNT]]   print the die temperature; every SEC seconds
 *   persona              write A, B and check SUM against the loaded persona
 *   load-pr FILE         load a persona .rbf over PCIe, check that link and
 *                        BAR0 did not change, then run the persona test
 *   ddr ...              DDR4 commands ('ddr help')
 *   flash-dump FILE [MB] read the configuration flash (read-only window)
 *   i2c ...              I2C master commands ('i2c help')
 *   selftest             offline checks (no device needed)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "bar_access.h"
#include "sha256.h"
#include "tool.h"

/* ----------------------------------------------------- profile checks */

static const char *keys_core[] = { "regs.shell_id", "regs.caps", "regs.caps2", "regs.id",
                                   "regs.counter", "regs.temp", NULL };
static const char *keys_pr[] = { "regs.persona", "regs.pr_data", "regs.pr_csr",
                                 "regs.pr_version", "regs.pr_id", "pr.version", NULL };
static const char *keys_ddr[] = { "regs.ddr_status", "regs.ddr_quiesce", "regs.ddr_mbox_ctrl",
                                  "regs.ddr_mbox_addr", "regs.ddr_mbox_go", "regs.ddr_mbox_status",
                                  "regs.ddr_info", "regs.ddr_mbox_wdata", "regs.ddr_mbox_rdata",
                                  "regs.persona_win", "ddr.word_bytes", "ddr.last_word",
                                  "ddr.user_clock_hz", "ddr.info_value", NULL };
static const char *keys_flash[] = { "regs.flash_page", "regs.flash_win", "flash.window_bytes",
                                    "flash.size_mb", NULL };
static const char *keys_i2c[] = { "regs.i2c_ctrl", "regs.i2c_addr", "regs.i2c_page", "regs.i2c_reg",
                                  "regs.i2c_len", "regs.i2c_data", "regs.i2c_status", "regs.i2c_div",
                                  "i2c.max_len", "i2c.clk_hz", "i2c.sensor_bus", "i2c.tmp411",
                                  "i2c.lm25066", NULL };

static int check_keys(const profile_t *p, const char *what, const char **keys)
{
    int bad = 0;
    for (int i = 0; keys[i]; i++) {
        uint32_t v;
        if (profile_u32(p, keys[i], &v) != 0) {
            printf("  %-8s missing key %s\n", what, keys[i]);
            bad++;
        }
    }
    return bad;
}

/* Keys required by the contract and by every capability in caps. */
static int check_profile(const profile_t *p, uint32_t caps)
{
    int bad = check_keys(p, "core", keys_core);
    uint32_t v;
    if (profile_u32(p, "regs.shell_id", &v) == 0 && v != CONTRACT_SHELL_ID) {
        printf("  core     regs.shell_id must be 0x%02X (minimal contract)\n", CONTRACT_SHELL_ID);
        bad++;
    }
    if (profile_u32(p, "regs.caps", &v) == 0 && v != CONTRACT_CAPS) {
        printf("  core     regs.caps must be 0x%02X (minimal contract)\n", CONTRACT_CAPS);
        bad++;
    }
    if (profile_u32(p, "regs.caps2", &v) == 0 && v != CONTRACT_CAPS2) {
        printf("  core     regs.caps2 must be 0x%02X (minimal contract)\n", CONTRACT_CAPS2);
        bad++;
    }
    if (caps & CAP_PR)
        bad += check_keys(p, "PR", keys_pr);
    if (caps & CAP_DDR4)
        bad += check_keys(p, "DDR4", keys_ddr);
    if (caps & CAP_FLASH)
        bad += check_keys(p, "FLASH", keys_flash);
    if (caps & CAP_I2C)
        bad += check_keys(p, "I2C", keys_i2c);
    return bad;
}

/* ---------------------------------------------------------------- list */

static int cmd_list(void)
{
    char dirs[8][PROFILE_PATH_LEN];
    int nd = profile_dirs(dirs, 8);
    printf("Profile search path (FPGA1768_PROFILES, <exe>/profiles, <exe>/../profiles, ./profiles, "
           "./host/profiles):\n");
    for (int i = 0; i < nd; i++) {
        struct stat st;
        int ok = stat(dirs[i], &st) == 0 && S_ISDIR(st.st_mode);
        printf("  %-7s %s\n", ok ? "found" : "-", dirs[i]);
    }
    profile_t *all;
    int n = profile_load_all(&all);
    printf("\n%-18s %-10s %-10s %-16s %s\n", "PROFILE", "SHELL_ID", "CAPS", "", "FILE");
    for (int i = 0; i < n; i++) {
        char t[64];
        printf("%-18s 0x%08X 0x%08X %-16s %s\n", all[i].name, (unsigned)all[i].shell_id,
               (unsigned)all[i].caps, caps_text(all[i].caps, t, sizeof(t)), all[i].path);
        const char *d = profile_str(&all[i], "profile.description");
        if (d && *d)
            printf("%-18s %s\n", "", d);
    }
    if (n == 0)
        printf("(no profiles found; set FPGA1768_PROFILES to the host/profiles directory)\n");
    printf("\n%-18s %-10s %-10s %s\n", "legacy", "-", "-",
           "built in: projects 03/04, no SHELL_ID/CAPS registers");
    free(all);
    return n > 0 ? 0 : 1;
}

/* --------------------------------------------------------------- probe */

static int cmd_probe(void)
{
    bar_info_t i;
    if (bar_get_info(g_bar, &i) != 0)
        return 5;
    print_link(&i);

    uint32_t id = rd(CONTRACT_SHELL_ID);
    printf("SHELL_ID: 0x%08X (BAR0 + 0x%02X)\n", (unsigned)id, CONTRACT_SHELL_ID);
    if (g_legacy) {
        printf("Profile:  none matches; built-in legacy profile (projects 03/04)\n");
        printf("ID:       0x%08X%s\n", (unsigned)rd(reg("regs.id")),
               rd(reg("regs.id")) == ID_VALUE ? "" : "  (unexpected)");
        printf("Probe:    no profile for this design (see 'fpga1768 list').\n");
        return 3;
    }
    printf("Profile:  %s (%s)\n", g_prof->name, g_prof->path);
    const char *proj = profile_str(g_prof, "profile.project");
    if (proj)
        printf("Project:  %s\n", proj);

    int bad = 0;
    char t1[64], t2[64];
    uint32_t hw = rd(CONTRACT_CAPS), hw2 = rd(CONTRACT_CAPS2);
    if (g_prof->shell_id != id) {
        printf("  FAIL     profile expects SHELL_ID 0x%08X\n", (unsigned)g_prof->shell_id);
        bad++;
    }
    printf("CAPS:     0x%08X (%s), profile 0x%08X (%s)", (unsigned)hw, caps_text(hw, t1, sizeof(t1)),
           (unsigned)g_prof->caps, caps_text(g_prof->caps, t2, sizeof(t2)));
    if (hw == g_prof->caps) {
        printf("  ok\n");
    } else if (hw == 0) {
        printf("  NOTE: reads 0, bitstream predates the CAPS register; using the profile\n");
    } else {
        printf("  MISMATCH\n");
        bad++;
    }
    printf("CAPS2:    0x%08X, profile 0x%08X  %s\n", (unsigned)hw2, (unsigned)g_prof->caps2,
           hw2 == g_prof->caps2 ? "ok" : "MISMATCH");
    if (hw2 != g_prof->caps2)
        bad++;

    printf("Profile keys:\n");
    int kb = check_profile(g_prof, g_caps | g_prof->caps);
    printf("  %s\n", kb ? "incomplete" : "complete for the core and every capability in CAPS");
    bad += kb;
    if (kb)
        goto done;

    printf("Registers (read only):\n");
    uint32_t v = rd(reg("regs.id"));
    printf("  ID        0x%04X = 0x%08X  %s\n", (unsigned)reg("regs.id"), (unsigned)v,
           v == ID_VALUE ? "ok" : "FAIL");
    bad += v != ID_VALUE;
    uint32_t c1 = rd(reg("regs.counter")), c2 = rd(reg("regs.counter"));
    printf("  COUNTER   0x%04X = 0x%08X then 0x%08X  %s\n", (unsigned)reg("regs.counter"),
           (unsigned)c1, (unsigned)c2, c1 != c2 ? "ok (changing)" : "FAIL (stuck)");
    bad += c1 == c2;
    double tc = temp_now();
    int tok = tc > -40.0 && tc < 125.0;
    printf("  TEMP      0x%04X = %.1f degC  %s\n", (unsigned)reg("regs.temp"), tc,
           tok ? "ok" : "FAIL (implausible)");
    bad += !tok;
    if (g_caps & CAP_PR) {
        v = rd(reg("regs.pr_version"));
        printf("  PR        0x%04X = 0x%08X  %s\n", (unsigned)reg("regs.pr_version"), (unsigned)v,
               v == reg("pr.version") ? "ok" : "FAIL");
        bad += v != reg("pr.version");
        v = rd(reg("regs.persona"));
        printf("  PERSONA   0x%04X = 0x%08X  (id 0x%04X, PR clock locked %u)  %s\n",
               (unsigned)reg("regs.persona"), (unsigned)v, (unsigned)(v & 0xFFFFu),
               (unsigned)((v >> 18) & 1u), (v >> 18) & 1u ? "ok" : "FAIL");
        bad += !((v >> 18) & 1u);
    }
    if (g_caps & CAP_DDR4) {
        v = rd(reg("regs.ddr_info"));
        printf("  DDR_INFO  0x%04X = 0x%08X  %s\n", (unsigned)reg("regs.ddr_info"), (unsigned)v,
               v == reg("ddr.info_value") ? "ok" : "FAIL");
        bad += v != reg("ddr.info_value");
        v = rd(reg("regs.ddr_status"));
        printf("  DDR_STAT  0x%04X = 0x%08X  (top cal %s, bottom cal %s)\n",
               (unsigned)reg("regs.ddr_status"), (unsigned)v, (v & 1u) ? "SUCCESS" : "-",
               (v & 0x100u) ? "SUCCESS" : "-");
    }
    if (g_caps & CAP_FLASH) {
        v = rd(reg("regs.flash_page"));
        printf("  FLASH     page register 0x%04X = 0x%08X, window 0x%04X (%u bytes)  %s\n",
               (unsigned)reg("regs.flash_page"), (unsigned)v, (unsigned)reg("regs.flash_win"),
               (unsigned)reg("flash.window_bytes"), v < 0x2000u ? "ok" : "FAIL");
        bad += v >= 0x2000u;
    }
    if (g_caps & CAP_I2C) {
        v = rd(reg("regs.i2c_status"));
        int idle = (v & 1u) == 0;
        printf("  I2C       STATUS 0x%04X = 0x%08X  (%s, bus 1 SCL/SDA %u/%u, bus 2 %u/%u)  %s\n",
               (unsigned)reg("regs.i2c_status"), (unsigned)v, idle ? "idle" : "busy",
               (unsigned)((v >> 16) & 1u), (unsigned)((v >> 17) & 1u),
               (unsigned)((v >> 18) & 1u), (unsigned)((v >> 19) & 1u), idle ? "ok" : "FAIL");
        bad += !idle;
    }

done:
    printf("Probe:    %s\n", bad ? "FAILED" : "OK");
    return bad ? 3 : 0;
}

/* ---------------------------------------------------------------- info */

static int cmd_info(void)
{
    bar_info_t i;
    if (bar_get_info(g_bar, &i) != 0)
        return 5;
    print_link(&i);
    if (!g_legacy) {
        char t[64];
        printf("Profile: %s (%s)\n", g_prof->name, g_prof->path);
        printf("SHELL:   ID 0x%08X, CAPS 0x%08X (%s), CAPS2 0x%08X\n",
               (unsigned)rd(CONTRACT_SHELL_ID), (unsigned)g_caps, caps_text(g_caps, t, sizeof(t)),
               (unsigned)rd(CONTRACT_CAPS2));
    }
    uint32_t r_id = reg("regs.id"), r_cnt = reg("regs.counter");
    uint32_t c1 = rd(r_cnt), c2 = rd(r_cnt);
    printf("ID:      0x%08X%s\n", (unsigned)rd(r_id), rd(r_id) == ID_VALUE ? "" : "  (unexpected)");
    if (persona_has_ab()) {
        printf("A:       0x%08X\n", (unsigned)rd(reg("persona.a")));
        printf("B:       0x%08X\n", (unsigned)rd(reg("persona.b")));
        printf("SUM:     0x%08X\n", (unsigned)rd(reg("persona.sum")));
    }
    printf("COUNTER: 0x%08X then 0x%08X (%s)\n", (unsigned)c1, (unsigned)c2,
           c1 != c2 ? "changing" : "STUCK");
    print_temp_line();
    if (has_pr_controller())
        print_persona();
    else
        printf("PR:      no PR controller (not project 04)\n");
    return 0;
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

    profile_t *all;
    int n = profile_load_all(&all);
    for (int i = 0; i < n; i++) {
        int bad = check_profile(&all[i], all[i].caps);
        for (int j = 0; j < i; j++) {
            if (all[j].shell_id == all[i].shell_id) {
                printf("  SHELL_ID 0x%08X used by %s and %s\n", (unsigned)all[i].shell_id,
                       all[j].name, all[i].name);
                bad++;
            }
        }
        printf("profile %s: %s\n", all[i].name, bad ? "FAILED" : "ok");
        if (bad)
            ok = 0;
    }
    if (n == 0)
        printf("profiles: none found (see 'fpga1768 list')\n");
    free(all);
    return ok ? 0 : 1;
}

/* ---------------------------------------------------------------- main */

static void usage(void)
{
    printf("usage: fpga1768 [--bdf BDF] [--profile NAME] <command> [args]\n\n"
           "  list                 list the host profiles found (no device needed)\n"
           "  probe                check SHELL_ID, CAPS and the profile against the device\n"
           "  info                 device, link, BAR0 and all registers\n"
           "  read OFF             read 32 bits at BAR0 + OFF (hex)\n"
           "  write OFF VAL        write 32 bits at BAR0 + OFF (hex)\n"
           "  temp [SEC [COUNT]]   die temperature, once or every SEC seconds\n"
           "  persona              write A, B and check SUM against the loaded persona   [PR]\n"
           "  load-pr FILE         load a persona PR bitstream (.rbf), verify link/BAR,  [PR]\n"
           "                       then run the persona test\n"
           "  ddr status|test|quiesce|peek|poke   DDR4 commands, 'ddr help'           [DDR4]\n"
           "  flash-dump FILE [MB] read the configuration flash (read-only window)      [FLASH]\n"
           "  i2c status|scan|read|preg|sensors|speed   I2C commands, 'i2c help'     [I2C]\n"
           "  selftest             offline checks (SHA-256, profile files)\n\n"
           "--bdf selects the PCI device on Linux (default: first %04x:%04x).\n"
           "--profile forces a profile (name or .ini path) instead of matching SHELL_ID.\n"
           "Profiles: $FPGA1768_PROFILES, <exe>/profiles, <exe>/../profiles, ./profiles,\n"
           "./host/profiles. [CAP] = command needs that CAPS bit of the loaded design.\n",
           LAB_VENDOR_ID, LAB_DEVICE_ID);
}

int main(int argc, char **argv)
{
    const char *bdf = NULL, *force = NULL;
    int ai = 1;
    while (ai + 1 < argc && argv[ai][0] == '-' && argv[ai][1] == '-') {
        if (!strcmp(argv[ai], "--bdf"))
            bdf = argv[ai + 1];
        else if (!strcmp(argv[ai], "--profile"))
            force = argv[ai + 1];
        else
            break;
        ai += 2;
    }
    if (ai >= argc || !strcmp(argv[ai], "-h") || !strcmp(argv[ai], "--help") ||
        !strcmp(argv[ai], "help")) {
        usage();
        return ai >= argc ? 2 : 0;
    }
    const char *cmd = argv[ai++];
    int nargs = argc - ai;

    if (!strcmp(cmd, "selftest"))
        return cmd_selftest();
    if (!strcmp(cmd, "list"))
        return cmd_list();

    if (bar_open(&g_bar, bdf) != 0)
        return 1;
    int verbose = !strcmp(cmd, "info") || !strcmp(cmd, "probe");
    if (core_select_profile(force, !verbose) != 0) {
        bar_close(g_bar);
        return 2;
    }

    int rc;
    if (!strcmp(cmd, "probe") && nargs == 0) {
        rc = cmd_probe();
    } else if (!strcmp(cmd, "info")) {
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
    } else if (!strcmp(cmd, "i2c")) {
        rc = cmd_i2c(nargs, argv + ai);
    } else {
        usage();
        rc = 2;
    }

    bar_close(g_bar);
    return rc;
}
