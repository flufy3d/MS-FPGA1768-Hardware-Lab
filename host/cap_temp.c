/*
 * cap_temp.c — die temperature (every project with a profile, and 03/04)
 *
 *   temp [SEC [COUNT]]   print the die temperature; every SEC seconds
 *
 * Register: regs.temp ([9:0] latched sensor code, [31:28] conversion count).
 */
#include <stdio.h>

#include "tool.h"

#define TEMP_NOTE_C  95.0         /* readings at or above this are flagged, nothing else */

static double temp_c(uint32_t r)
{
    /* [9:0] latched code; vendor formula for the Arria 10 sensor. */
    return (double)(r & 0x3FFu) * 693.0 / 1024.0 - 265.0;
}

double temp_now(void)
{
    return temp_c(rd(reg("regs.temp")));
}

void print_temp_line(void)
{
    char ts[32];
    uint32_t t = rd(reg("regs.temp"));
    double c = temp_c(t);
    plat_timestamp(ts, sizeof(ts));
    printf("%s TEMP reg=0x%08X conv=%u code=%u degC=%.1f%s\n", ts, (unsigned)t,
           (unsigned)(t >> 28), (unsigned)(t & 0x3FFu), c,
           c >= TEMP_NOTE_C ? "  (>= 95 degC, recorded)" : "");
    fflush(stdout);
}

int cmd_temp(double interval, long count)
{
    for (long n = 0;; n++) {
        print_temp_line();
        if (interval <= 0 || (count > 0 && n + 1 >= count))
            return 0;
        plat_sleep_ms((unsigned)(interval * 1000.0));
    }
}
