/*
 * cap_pr.c — partial reconfiguration over PCIe (CAPS bit 2; project 04 in legacy mode)
 *
 *   load-pr FILE   load a persona .rbf over PCIe, check that link and BAR0 did
 *                  not change, then run the persona test
 *
 * Registers: regs.pr_data, regs.pr_csr, regs.pr_version, regs.pr_id, regs.persona;
 * constant pr.version (alt_pr CSR_VERSION).
 */
#include <stdio.h>
#include <stdlib.h>

#include "sha256.h"
#include "tool.h"

static const char *pr_status_name(unsigned s)
{
    static const char *n[8] = { "idle", "PR_ERROR", "CRC_ERROR", "INCOMPATIBLE_BITSTREAM",
                                "IN_PROGRESS", "SUCCESS", "?", "?" };
    return n[s & 7u];
}

static unsigned pr_status(void)
{
    return (rd(reg("regs.pr_csr")) >> 2) & 7u;
}

int has_pr_controller(void)
{
    if (!has_key("regs.pr_version") || !has_key("pr.version"))
        return 0;
    return rd(reg("regs.pr_version")) == reg("pr.version");
}

void print_link(const bar_info_t *i)
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

void print_persona(void)
{
    uint32_t p = rd(reg("regs.persona")), csr = rd(reg("regs.pr_csr"));
    printf("PERSONA: 0x%08X (id 0x%04X, freeze %u, reset %u, PR clock locked %u)\n",
           (unsigned)p, (unsigned)(p & 0xFFFFu), (unsigned)((p >> 16) & 1u),
           (unsigned)((p >> 17) & 1u), (unsigned)((p >> 18) & 1u));
    printf("PR CSR:  0x%08X (status %u %s), version 0x%08X, bitstream ID 0x%08X\n",
           (unsigned)csr, (unsigned)((csr >> 2) & 7u), pr_status_name((csr >> 2) & 7u),
           (unsigned)rd(reg("regs.pr_version")), (unsigned)rd(reg("regs.pr_id")));
}

int require_pr(const char *command)
{
    if (need_cap(CAP_PR, command) != 0)
        return -1;
    if (require_id() != 0)
        return -1;
    if (!has_pr_controller()) {
        fprintf(stderr, "No PR controller at BAR0 + 0x%X (expected version 0x%08X).\n"
                        "Is projects/04_pcie_hot_update loaded?\n",
                (unsigned)reg("regs.pr_version"), (unsigned)reg("pr.version"));
        return -1;
    }
    if (!((rd(reg("regs.persona")) >> 18) & 1u)) {
        fprintf(stderr, "PR controller clock PLL not locked (PERSONA bit 18 = 0).\n");
        return -1;
    }
    return 0;
}

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
int cmd_load_pr(const char *path)
{
    if (require_pr("load-pr") != 0)
        return 3;
    const uint32_t r_data = reg("regs.pr_data"), r_csr = reg("regs.pr_csr");
    const uint32_t r_id = reg("regs.id");

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
    wr(r_csr, 1u);
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
        wr(r_data, w);
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
           same_link ? "unchanged" : "CHANGED", (unsigned)rd(r_id));

    if (st != 5)
        return 7;
    if (!same_bar || !same_link || rd(r_id) != ID_VALUE)
        return 8;
    printf("\n-- persona test\n");
    return cmd_persona();
}
