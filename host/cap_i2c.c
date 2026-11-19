/*
 * cap_i2c.c — I2C master of the loaded design (CAPS bit 1, projects/06_i2c_telemetry)
 *
 *   i2c status                         master status and live line levels
 *   i2c scan BUS [FIRST LAST]          one-byte read probe of every address
 *   i2c read BUS ADDR REG [LEN]        write command byte, Sr, read LEN bytes
 *   i2c preg BUS ADDR PAGE REG [LEN]   write PAGE to register 0xFF, then read
 *   i2c sensors                        TMP411 and LM25066 readings (read only)
 *   i2c speed KHZ [COMMAND ...]        set SCL (reset value 100 kHz; the
 *                                      setting stays in the FPGA until reload)
 *
 * BUS is 1 or 2 (board bus numbers, docs/hardware/i2c.md); numbers are hex
 * with or without 0x, except LEN and KHZ (decimal).
 *
 * Deliberately no generic write command: the board buses carry the VR
 * controller and the hot-swap controller, whose configuration must not be
 * changed from this tool (AGENTS.md, section 12). The only write the tool
 * issues is the page select of `preg`, and only to addresses listed in the
 * profile key i2c.preg_allow.
 *
 * Profile keys: regs.i2c_ctrl, regs.i2c_addr, regs.i2c_page, regs.i2c_reg,
 * regs.i2c_len, regs.i2c_data, regs.i2c_status, regs.i2c_div, i2c.max_len,
 * i2c.clk_hz, i2c.preg_allow, i2c.tmp411, i2c.lm25066, i2c.sensor_bus.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tool.h"

/* CTRL bits */
#define C_START  0x01u
#define C_BUS2   0x02u
#define C_READ   0x04u
#define C_ABORT  0x08u
#define C_NOREG  0x10u

/* STATUS bits */
#define S_BUSY   0x01u
#define S_NACK   0x02u
#define S_DONE   0x04u
#define S_TMO    0x08u
#define S_ABRT   0x10u

static int parse_hex(const char *s, unsigned max, unsigned *v)
{
    char *end;
    unsigned long x = strtoul(s, &end, 16);
    if (*s == '\0' || *end != '\0' || x > max)
        return -1;
    *v = (unsigned)x;
    return 0;
}

static int parse_bus(const char *s, int *bus)
{
    if (!strcmp(s, "1")) { *bus = 1; return 0; }
    if (!strcmp(s, "2")) { *bus = 2; return 0; }
    fprintf(stderr, "i2c: BUS must be 1 or 2 (got '%s')\n", s);
    return -1;
}

static void status_text(uint32_t s, char *buf, unsigned len)
{
    snprintf(buf, len, "%s%s%s%s%s",
             (s & S_BUSY) ? "busy " : "", (s & S_DONE) ? "done " : "",
             (s & S_NACK) ? "NACK " : "", (s & S_TMO) ? "TIMEOUT " : "",
             (s & S_ABRT) ? "aborted " : "");
}

/*
 * One transaction. flags: C_READ / C_NOREG. page < 0: no page select.
 * Returns 0 on ACK, 1 on NACK, 2 on timeout / abort / host timeout.
 */
static int xfer(int bus, unsigned addr, unsigned regb, int page, uint32_t flags,
                unsigned len, uint8_t *out, uint32_t *status_out)
{
    uint32_t r_status = reg("regs.i2c_status");
    uint32_t s = rd(r_status);
    double t0 = plat_now();
    while (s & S_BUSY) {                      /* previous transaction still running */
        if (plat_now() - t0 > 0.1) {
            wr(reg("regs.i2c_ctrl"), C_ABORT);
            break;
        }
        s = rd(r_status);
    }
    wr(reg("regs.i2c_addr"), addr);
    wr(reg("regs.i2c_reg"), regb);
    wr(reg("regs.i2c_len"), len);
    wr(reg("regs.i2c_page"), page >= 0 ? (0x100u | (unsigned)page) : 0u);
    wr(reg("regs.i2c_ctrl"), C_START | (bus == 2 ? C_BUS2 : 0u) | flags);

    t0 = plat_now();
    do {
        s = rd(r_status);
        if (plat_now() - t0 > 0.2) {          /* 28 bytes at 100 kHz take ~3.5 ms */
            wr(reg("regs.i2c_ctrl"), C_ABORT);
            s = rd(r_status);
            if (status_out)
                *status_out = s;
            return 2;
        }
    } while (!(s & S_DONE));
    if (status_out)
        *status_out = s;
    if (s & (S_TMO | S_ABRT))
        return 2;
    if (s & S_NACK)
        return 1;
    if (out) {
        uint32_t base = reg("regs.i2c_data");
        for (unsigned i = 0; i < len; i += 4) {
            uint32_t w = rd(base + i);
            for (unsigned j = 0; j < 4 && i + j < len; j++)
                out[i + j] = (uint8_t)(w >> (8 * j));
        }
    }
    return 0;
}

static int report_fail(int rc, uint32_t s, int bus, unsigned addr)
{
    char t[64];
    status_text(s, t, sizeof(t));
    if (rc == 1)
        printf("bus %d addr 0x%02X: NACK (no device or register refused)  STATUS 0x%08X %s\n",
               bus, addr, (unsigned)s, t);
    else
        printf("bus %d addr 0x%02X: %s  STATUS 0x%08X %s\n", bus, addr,
               (s & S_TMO) ? "SCL held low (timeout)" : "no completion", (unsigned)s, t);
    return 4;
}

static void print_lines(uint32_t s)
{
    printf("lines:  bus 1 SCL=%u SDA=%u, bus 2 SCL=%u SDA=%u (1 = high)\n",
           (unsigned)((s >> 16) & 1u), (unsigned)((s >> 17) & 1u),
           (unsigned)((s >> 18) & 1u), (unsigned)((s >> 19) & 1u));
}

/* -------------------------------------------------------------- commands */

static int cmd_status(void)
{
    char t[64];
    uint32_t s = rd(reg("regs.i2c_status"));
    uint32_t div = rd(reg("regs.i2c_div"));
    status_text(s, t, sizeof(t));
    printf("STATUS: 0x%08X  %s bytes=%u\n", (unsigned)s, t, (unsigned)((s >> 8) & 0xFFu));
    print_lines(s);
    unsigned d = div & 0xFFFFu;
    if (d < 25)
        d = 25;
    printf("SCL:    SCL_DIV=%u -> %.1f kHz\n", (unsigned)(div & 0xFFFFu),
           (double)reg("i2c.clk_hz") / (4.0 * d) / 1000.0);
    return 0;
}

static int cmd_scan(int bus, unsigned first, unsigned last)
{
    uint32_t s0 = rd(reg("regs.i2c_status"));
    unsigned scl = (unsigned)((s0 >> (bus == 1 ? 16 : 18)) & 1u);
    unsigned sda = (unsigned)((s0 >> (bus == 1 ? 17 : 19)) & 1u);
    if (!scl || !sda) {
        printf("bus %d: SCL=%u SDA=%u before the scan; a line is held low, not scanning\n",
               bus, scl, sda);
        return 4;
    }
    printf("bus %d scan 0x%02X-0x%02X (one-byte read probe, nothing is written)\n", bus, first, last);
    printf("     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f\n");
    int found = 0, errors = 0;
    char line[128];
    for (unsigned row = 0; row < 0x80; row += 16) {
        int n = snprintf(line, sizeof(line), "%02x: ", row);
        for (unsigned a = row; a < row + 16; a++) {
            if (a < first || a > last) {
                n += snprintf(line + n, sizeof(line) - n, "   ");
                continue;
            }
            uint32_t s;
            int rc = xfer(bus, a, 0, -1, C_READ | C_NOREG, 1, NULL, &s);
            if (rc == 0) {
                n += snprintf(line + n, sizeof(line) - n, "%02x ", a);
                found++;
            } else if (rc == 1) {
                n += snprintf(line + n, sizeof(line) - n, "-- ");
            } else {
                n += snprintf(line + n, sizeof(line) - n, "TO ");
                errors++;
                break;
            }
        }
        printf("%s\n", line);
        if (errors) {
            printf("bus %d: timeout (SCL held low); scan stopped\n", bus);
            break;
        }
    }
    printf("bus %d: %d device(s) answered%s\n", bus, found,
           errors ? ", with timeouts (TO)" : "");
    return errors ? 4 : 0;
}

static void hexdump(unsigned regb, const uint8_t *d, unsigned len)
{
    for (unsigned i = 0; i < len; i++)
        printf("  0x%02X: 0x%02X\n", (regb + i) & 0xFFu, d[i]);
    if (len == 2)
        printf("  word (little endian, SMBus): 0x%04X\n", (unsigned)(d[0] | (d[1] << 8)));
}

static int cmd_read(int bus, unsigned addr, unsigned regb, int page, unsigned len)
{
    uint8_t d[32];
    uint32_t s;
    int rc = xfer(bus, addr, regb, page, C_READ, len, d, &s);
    if (rc != 0)
        return report_fail(rc, s, bus, addr);
    if (page >= 0)
        printf("bus %d addr 0x%02X page 0x%02X reg 0x%02X, %u byte(s):\n", bus, addr,
               (unsigned)page, regb, len);
    else
        printf("bus %d addr 0x%02X reg 0x%02X, %u byte(s):\n", bus, addr, regb, len);
    hexdump(regb, d, len);
    return 0;
}

static int preg_allowed(unsigned addr)
{
    const char *list = profile_str(g_prof, "i2c.preg_allow");
    if (!list)
        return 0;
    char buf[128];
    snprintf(buf, sizeof(buf), "%s", list);
    for (char *tok = strtok(buf, " ,"); tok; tok = strtok(NULL, " ,"))
        if (strtoul(tok, NULL, 0) == addr)
            return 1;
    return 0;
}

/* ---- sensors (read only) ---- */

static int rd_bytes(int bus, unsigned addr, unsigned regb, unsigned len, uint8_t *d)
{
    uint32_t s;
    int rc = xfer(bus, addr, regb, -1, C_READ, len, d, &s);
    if (rc != 0)
        report_fail(rc, s, bus, addr);
    return rc;
}

static int cmd_sensors(void)
{
    int bus = (int)reg("i2c.sensor_bus");
    unsigned tmp = reg("i2c.tmp411"), lm = reg("i2c.lm25066");
    int bad = 0;
    uint8_t d[4];

    printf("FPGA die (internal sensor): %.1f degC\n", temp_now());

    /* TMP411 (datasheet: local 0x00 + 0x15, remote 0x01 + 0x10, config read 0x03,
       bit 2 = extended range with +64 offset; low bytes [7:4] in 1/16 degC). */
    uint8_t cfg, lh, ll, rh, rl;
    if (rd_bytes(bus, tmp, 0x03, 1, &cfg) || rd_bytes(bus, tmp, 0x00, 1, &lh) ||
        rd_bytes(bus, tmp, 0x15, 1, &ll) || rd_bytes(bus, tmp, 0x01, 1, &rh) ||
        rd_bytes(bus, tmp, 0x10, 1, &rl)) {
        bad++;
    } else {
        double off = (cfg & 0x04u) ? 64.0 : 0.0;
        double tl = lh - off + (ll >> 4) / 16.0;
        double tr = rh - off + (rl >> 4) / 16.0;
        printf("TMP411  bus %d 0x%02X: config 0x%02X (%s range)\n", bus, tmp, cfg,
               (cfg & 0x04u) ? "extended" : "standard");
        printf("  local  0x00=0x%02X 0x15=0x%02X -> %.2f degC\n", lh, ll, tl);
        printf("  remote 0x01=0x%02X 0x10=0x%02X -> %.2f degC%s\n", rh, rl, tr,
               (rl & 0x02u) ? "  (open-diode flag set)" : "");
    }

    /* LM25066 PMBus DIRECT format, datasheet Table 41:
       X = (Y * 10^-R - b) / m; VIN/VOUT m=22070 b=-1800 R=-2; TEMP m=16000 b=0 R=-3.
       Input current and power are manufacturer commands MFR_READ_IIN (0xD1) and
       MFR_READ_PIN (0xD2); the standard 0x89 / 0x97 are NACKed by this part
       (measured 2026-11-19). Their coefficients depend on the sense resistor
       (unknown): raw only. */
    static const struct { unsigned cmd; const char *name; double m, b; int r; } pm[] = {
        { 0x88, "READ_VIN ", 22070.0, -1800.0, -2 },
        { 0x8B, "READ_VOUT", 22070.0, -1800.0, -2 },
        { 0x8D, "READ_TEMP", 16000.0,     0.0, -3 },
        { 0xD1, "READ_IIN ",     0.0,     0.0,  0 },
        { 0xD2, "READ_PIN ",     0.0,     0.0,  0 },
    };
    printf("LM25066 bus %d 0x%02X:\n", bus, lm);
    for (unsigned i = 0; i < sizeof(pm) / sizeof(pm[0]); i++) {
        if (rd_bytes(bus, lm, pm[i].cmd, 2, d)) {
            bad++;
            continue;
        }
        unsigned y = (unsigned)(d[0] | (d[1] << 8));
        if (pm[i].m > 0) {
            double scale = 1.0;
            for (int k = 0; k < -pm[i].r; k++)
                scale *= 10.0;
            double x = ((double)y * scale - pm[i].b) / pm[i].m;
            printf("  %s 0x%02X = 0x%04X -> %.3f %s\n", pm[i].name, pm[i].cmd, y, x,
                   pm[i].cmd == 0x8D ? "degC" : "V");
        } else {
            printf("  %s 0x%02X = 0x%04X (raw; coefficient needs the sense resistor value)\n",
                   pm[i].name, pm[i].cmd, y);
        }
    }
    return bad ? 4 : 0;
}

static void i2c_help(void)
{
    printf("i2c commands (I2C master, CAPS bit 1):\n"
           "  i2c status                        master status, line levels, SCL rate\n"
           "  i2c scan BUS [FIRST LAST]         read-probe 0x08-0x77 (nothing is written)\n"
           "  i2c read BUS ADDR REG [LEN]       command byte, repeated start, read LEN (1-%u)\n"
           "  i2c preg BUS ADDR PAGE REG [LEN]  WRITES PAGE to register 0xFF first, then reads;\n"
           "                                    only for addresses in i2c.preg_allow\n"
           "  i2c sensors                       TMP411 and LM25066 readings (read only)\n"
           "  i2c speed KHZ [CMD ...]           set SCL, 10-400 kHz (kept until reload)\n"
           "BUS is 1 or 2; ADDR, PAGE, REG in hex; LEN decimal. Exit code 4 = NACK/timeout.\n",
           (unsigned)reg("i2c.max_len"));
}

int cmd_i2c(int argc, char **argv)
{
    if (argc == 0 || !strcmp(argv[0], "help")) {
        if (need_cap(CAP_I2C, "i2c") != 0)
            return 3;
        i2c_help();
        return argc == 0 ? 2 : 0;
    }
    if (need_cap(CAP_I2C, "i2c") != 0)
        return 3;

    /* "i2c speed KHZ <command> ..." sets the rate for the command that follows */
    if (!strcmp(argv[0], "speed")) {
        if (argc < 2 || atof(argv[1]) < 10.0 || atof(argv[1]) > 400.0) {
            fprintf(stderr, "i2c speed: KHZ must be 10..400\n");
            return 2;
        }
        double khz = atof(argv[1]);
        double div = (double)reg("i2c.clk_hz") / (khz * 1000.0 * 4.0);
        wr(reg("regs.i2c_div"), (uint32_t)(div + 0.5));
        printf("SCL_DIV = %u (%.1f kHz)\n", (unsigned)(div + 0.5), khz);
        if (argc == 2)
            return 0;
        argc -= 2;
        argv += 2;
    }

    const char *sub = argv[0];
    unsigned maxlen = reg("i2c.max_len");
    int bus;
    unsigned addr, regb, page, len = 1;

    if (!strcmp(sub, "status") && argc == 1)
        return cmd_status();
    if (!strcmp(sub, "sensors") && argc == 1)
        return cmd_sensors();
    if (!strcmp(sub, "scan") && (argc == 2 || argc == 4)) {
        unsigned first = 0x08, last = 0x77;
        if (parse_bus(argv[1], &bus))
            return 2;
        if (argc == 4 && (parse_hex(argv[2], 0x7F, &first) || parse_hex(argv[3], 0x7F, &last) ||
                          first > last)) {
            fprintf(stderr, "i2c scan: FIRST and LAST are 7-bit hex addresses\n");
            return 2;
        }
        return cmd_scan(bus, first, last);
    }
    if (!strcmp(sub, "read") && (argc == 4 || argc == 5)) {
        if (parse_bus(argv[1], &bus))
            return 2;
        if (parse_hex(argv[2], 0x7F, &addr) || parse_hex(argv[3], 0xFF, &regb)) {
            fprintf(stderr, "i2c read: ADDR is 7-bit hex, REG is 8-bit hex\n");
            return 2;
        }
        if (argc == 5)
            len = (unsigned)atoi(argv[4]);
        if (len < 1 || len > maxlen) {
            fprintf(stderr, "i2c read: LEN must be 1..%u\n", maxlen);
            return 2;
        }
        return cmd_read(bus, addr, regb, -1, len);
    }
    if (!strcmp(sub, "preg") && (argc == 5 || argc == 6)) {
        if (parse_bus(argv[1], &bus))
            return 2;
        if (parse_hex(argv[2], 0x7F, &addr) || parse_hex(argv[3], 0xFF, &page) ||
            parse_hex(argv[4], 0xFF, &regb)) {
            fprintf(stderr, "i2c preg: ADDR is 7-bit hex, PAGE and REG are 8-bit hex\n");
            return 2;
        }
        if (argc == 6)
            len = (unsigned)atoi(argv[5]);
        if (len < 1 || len > maxlen) {
            fprintf(stderr, "i2c preg: LEN must be 1..%u\n", maxlen);
            return 2;
        }
        if (!preg_allowed(addr)) {
            fprintf(stderr, "i2c preg: 0x%02X is not in i2c.preg_allow of profile %s; "
                    "refusing to write its register 0xFF\n", addr, g_prof->name);
            return 3;
        }
        return cmd_read(bus, addr, regb, (int)page, len);
    }
    i2c_help();
    return 2;
}
