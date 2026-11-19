/*
 * cap_retimer.c — DS250DF810 retimer (U17) over the FPGA I2C master (CAPS bit 1)
 *
 *   retimer status [CH]            IDs, EEPROM/refclk status, per-channel status
 *   retimer bypass CH|all on|off   output mux: raw (CDR bypass) or retimed
 *
 * Register facts are from the TI datasheet SNLS513C (hardware/datasheets/
 * U17 - DS250DF810), checked against the PDF text on 2026-11-19:
 *   global  0xEF..0xF3 IDs, 0xFE vendor ID (0x03), 0xFC channel select (bit n =
 *           channel n), 0xFF page select ([0] 1 = channel registers, [1]
 *           broadcast, [4] / [5] shared registers of quad 0 / quad 1)
 *   shared  0x05[4] EEPROM_READ_DONE, 0x08 interrupt per channel (quad 0),
 *           0x0B[6] refclk_det, 0x11 EEPROM load status
 *   channel 0x01 [7] sigdet, [4:1] PRBS pattern detected; 0x02 CDR_STATUS
 *           (what it shows is selected by 0x0C[7:4], marked reserved in the
 *           datasheet: printed raw); 0x09[5] REG_BYPASS_PFD_OV (makes
 *           0x1E[7:5] effective); 0x1E[7:5] PFD_SEL_DATA_MUX (000 raw data,
 *           001 retimed, 100 pattern generator, 111 mute; default 111,
 *           register default 0xE9); 0x27 HEO, 0x28 VEO (valid with CDR lock);
 *           0x2F[6:4] RATE (codes in the Programming Guide, not public)
 *
 * Writes go only to the profile's retimer address and only to the registers
 * listed in retimer.write_regs (0xFC 0xFF 0x09 0x1E). Every command restores
 * 0xFC and 0xFF to the values they had before. All settings are volatile in
 * the retimer (lost at power off); nothing is written to its EEPROM.
 *
 * Profile keys: retimer.bus, retimer.addr, retimer.channels, retimer.write_regs.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tool.h"

static int      rt_bus;
static unsigned rt_addr;
static unsigned rt_nch;

static int write_allowed(unsigned r)
{
    const char *list = profile_str(g_prof, "retimer.write_regs");
    if (!list)
        return 0;
    char buf[128];
    snprintf(buf, sizeof(buf), "%s", list);
    for (char *tok = strtok(buf, " ,"); tok; tok = strtok(NULL, " ,"))
        if (strtoul(tok, NULL, 0) == r)
            return 1;
    return 0;
}

static int rd8(unsigned r, uint8_t *v)
{
    int rc = i2c_read_regs(rt_bus, rt_addr, r, 1, v);
    if (rc != 0)
        fprintf(stderr, "retimer: read 0x%02X failed (%s)\n", r, rc == 1 ? "NACK" : "timeout");
    return rc;
}

static int wr8(unsigned r, uint8_t v)
{
    if (!write_allowed(r)) {
        fprintf(stderr, "retimer: register 0x%02X is not in retimer.write_regs; not written\n", r);
        return 3;
    }
    int rc = i2c_write_reg8(rt_bus, rt_addr, r, v);
    if (rc != 0)
        fprintf(stderr, "retimer: write 0x%02X <- 0x%02X failed (%s)\n", r, v,
                rc == 1 ? "NACK" : "timeout");
    return rc;
}

/* Page state saved at the start of a command and restored at the end. */
static uint8_t saved_fc, saved_ff;

static int page_save(void)
{
    return rd8(0xFC, &saved_fc) || rd8(0xFF, &saved_ff);
}

static int page_restore(void)
{
    int rc = wr8(0xFC, saved_fc);
    rc |= wr8(0xFF, saved_ff);
    return rc;
}

static int select_channel(unsigned ch)
{
    return wr8(0xFC, (uint8_t)(1u << ch)) || wr8(0xFF, 0x01);
}

static int select_shared(unsigned quad)
{
    return wr8(0xFF, quad ? 0x20 : 0x10);
}

static const char *mux_text(unsigned m)
{
    switch (m) {
    case 0: return "raw (CDR bypass)";
    case 1: return "retimed";
    case 4: return "pattern generator";
    case 7: return "mute";
    default: return "reserved";
    }
}

static const char *prbs_text(unsigned p)
{
    static const char *t[] = { "PRBS7", "PRBS9", "PRBS11", "PRBS15",
                               "PRBS23", "PRBS31", "PRBS58", "PRBS63" };
    return (p & 8u) ? t[p & 7u] : "none";
}

/* --------------------------------------------------------------- status */

static int status_channel(unsigned ch)
{
    uint8_t r01, r02, r09, r1e, heo, veo, r2f;
    if (select_channel(ch))
        return 4;
    if (rd8(0x01, &r01) || rd8(0x02, &r02) || rd8(0x09, &r09) || rd8(0x1E, &r1e) ||
        rd8(0x27, &heo) || rd8(0x28, &veo) || rd8(0x2F, &r2f))
        return 4;
    unsigned mux = (r1e >> 5) & 7u;
    int ov = (r09 >> 5) & 1;
    printf("  %u   %u      %-6s 0x%02X       0x%02X 0x%02X  %u    %-18s 0x%02X/0x%02X  0x%02X (RATE %u)\n",
           ch, (r01 >> 7) & 1u, prbs_text((r01 >> 1) & 0xFu), r02, r09, r1e, ov,
           ov ? mux_text(mux) : "retimed (default)", heo, veo, r2f, (r2f >> 4) & 7u);
    return 0;
}

static int cmd_status(int one, unsigned ch)
{
    uint8_t id[5], fe, ff, fc;
    if (i2c_read_regs(rt_bus, rt_addr, 0xEF, 5, id) || rd8(0xFE, &fe) || rd8(0xFF, &ff) ||
        rd8(0xFC, &fc)) {
        printf("retimer bus %d 0x%02X: no answer\n", rt_bus, rt_addr);
        return 4;
    }
    printf("DS250DF810 bus %d 0x%02X\n", rt_bus, rt_addr);
    printf("  IDs 0xEF-0xF3: %02X %02X %02X %02X %02X (datasheet: F0=32 F1=10 F3=00)\n",
           id[0], id[1], id[2], id[3], id[4]);
    printf("  vendor 0xFE:   0x%02X %s\n", fe, fe == 0x03 ? "(TI)" : "(unexpected)");
    printf("  page 0xFF=0x%02X, channel select 0xFC=0x%02X (before this command)\n", ff, fc);
    saved_ff = ff;
    saved_fc = fc;

    int bad = 0;
    for (unsigned q = 0; q < (rt_nch + 3) / 4; q++) {
        uint8_t r05, r08, r0b, r11;
        if (select_shared(q) || rd8(0x05, &r05) || rd8(0x08, &r08) || rd8(0x0B, &r0b) ||
            rd8(0x11, &r11)) {
            bad++;
            continue;
        }
        static const char *ee[] = { "load in progress", "load failed after 64 attempts",
                                    "load completed", "not valid" };
        printf("  quad %u shared: EEPROM_READ_DONE %u, 0x11=0x%02X (%s, %u attempts), "
               "refclk_det %u, interrupts 0x08=0x%02X\n",
               q, (r05 >> 4) & 1u, r11, ee[(r11 >> 6) & 3u], r11 & 0x3Fu, (r0b >> 6) & 1u, r08);
    }

    printf("  ch  sigdet PRBS   CDR_STATUS 0x09 0x1E  OV   output             HEO/VEO     0x2F\n");
    for (unsigned c = one ? ch : 0; c < (one ? ch + 1 : rt_nch); c++)
        bad += status_channel(c) != 0;
    if (page_restore())
        bad++;
    printf("  (0xFC/0xFF restored to 0x%02X/0x%02X)\n", saved_fc, saved_ff);
    return bad ? 4 : 0;
}

/* --------------------------------------------------------------- bypass */

static int bypass_channel(unsigned ch, int on)
{
    uint8_t r09, r1e, n09, n1e;
    if (select_channel(ch) || rd8(0x09, &r09) || rd8(0x1E, &r1e))
        return 4;
    if (on) {
        /* mux value first (ignored while the override is off), then the override */
        if (wr8(0x1E, (uint8_t)(r1e & 0x1Fu)) || wr8(0x09, (uint8_t)(r09 | 0x20u)))
            return 4;
    } else {
        /* override off first (back to the CDR's own selection), then the
           mux field back to its default 111 */
        if (wr8(0x09, (uint8_t)(r09 & ~0x20u)) || wr8(0x1E, (uint8_t)(r1e | 0xE0u)))
            return 4;
    }
    if (rd8(0x09, &n09) || rd8(0x1E, &n1e))
        return 4;
    int ok = on ? ((n09 & 0x20u) && ((n1e >> 5) & 7u) == 0)
                : (!(n09 & 0x20u) && ((n1e >> 5) & 7u) == 7);
    printf("  ch %u: 0x09 0x%02X -> 0x%02X, 0x1E 0x%02X -> 0x%02X  %s\n", ch, r09, n09, r1e, n1e,
           ok ? (on ? "raw (CDR bypass)" : "retimed (default)") : "READBACK MISMATCH");
    return ok ? 0 : 4;
}

static int cmd_bypass(const char *chs, const char *mode)
{
    int on;
    if (!strcmp(mode, "on"))
        on = 1;
    else if (!strcmp(mode, "off"))
        on = 0;
    else {
        fprintf(stderr, "retimer bypass: mode must be on or off\n");
        return 2;
    }
    unsigned first, last;
    if (!strcmp(chs, "all")) {
        first = 0;
        last = rt_nch - 1;
    } else {
        char *end;
        unsigned long c = strtoul(chs, &end, 10);
        if (*chs == '\0' || *end != '\0' || c >= rt_nch) {
            fprintf(stderr, "retimer bypass: CH must be 0..%u or all\n", rt_nch - 1);
            return 2;
        }
        first = last = (unsigned)c;
    }
    if (page_save())
        return 4;
    printf("DS250DF810 bus %d 0x%02X: bypass %s, channel(s) %u-%u (volatile)\n", rt_bus, rt_addr,
           on ? "ON (raw data)" : "OFF (retimed)", first, last);
    int bad = 0;
    for (unsigned c = first; c <= last; c++)
        bad += bypass_channel(c, on) != 0;
    if (page_restore())
        bad++;
    printf("  (0xFC/0xFF restored to 0x%02X/0x%02X)\n", saved_fc, saved_ff);
    return bad ? 4 : 0;
}

static void retimer_help(void)
{
    printf("retimer commands (DS250DF810 over the FPGA I2C master, CAPS bit 1):\n"
           "  retimer status [CH]            IDs, EEPROM/refclk, per-channel status (reads;\n"
           "                                 writes only the page registers 0xFC/0xFF)\n"
           "  retimer bypass CH|all on|off   on: 0x1E[7:5]=000 + 0x09[5]=1 (raw data, CDR\n"
           "                                 bypass); off: 0x09[5]=0, 0x1E[7:5]=111 (default)\n"
           "Settings are volatile in the retimer. 0xFC/0xFF are restored afterwards.\n");
}

int cmd_retimer(int argc, char **argv)
{
    if (need_cap(CAP_I2C, "retimer") != 0)
        return 3;
    if (!has_key("retimer.addr")) {
        fprintf(stderr, "retimer: profile %s has no [retimer] section\n", g_prof->name);
        return 2;
    }
    rt_bus = (int)reg("retimer.bus");
    rt_addr = reg("retimer.addr");
    rt_nch = reg("retimer.channels");
    if (rt_nch < 1 || rt_nch > 8)
        rt_nch = 8;

    if (argc >= 1 && !strcmp(argv[0], "status") && argc <= 2) {
        if (argc == 2) {
            unsigned long c = strtoul(argv[1], NULL, 10);
            if (c >= rt_nch) {
                fprintf(stderr, "retimer status: CH must be 0..%u\n", rt_nch - 1);
                return 2;
            }
            return cmd_status(1, (unsigned)c);
        }
        return cmd_status(0, 0);
    }
    if (argc == 3 && !strcmp(argv[0], "bypass"))
        return cmd_bypass(argv[1], argv[2]);
    retimer_help();
    return (argc >= 1 && !strcmp(argv[0], "help")) ? 0 : 2;
}
