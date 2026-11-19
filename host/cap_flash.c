/*
 * cap_flash.c — read-only configuration flash window (CAPS bit 3; project 05_ddr4)
 *
 *   flash-dump FILE [MB]   read the first MB megabytes of the configuration flash
 *
 * Registers: regs.flash_page (page select), regs.flash_win (window base);
 * constants flash.window_bytes and flash.size_mb. The window is read only in
 * hardware; this module never writes the flash.
 */
#include <stdio.h>
#include <stdlib.h>

#include "sha256.h"
#include "tool.h"

int cmd_flash_dump(int argc, char **argv)
{
    if (argc < 1 || argc > 2) {
        printf("flash-dump FILE [MB]   read the first MB megabytes (default 128) of the\n"
               "                       configuration flash through the read-only window\n");
        return 2;
    }
    if (require_id() != 0 || need_cap(CAP_FLASH, "flash-dump") != 0)
        return 3;
    const uint32_t r_page = reg("regs.flash_page"), win = reg("regs.flash_win");
    const uint32_t win_bytes = reg("flash.window_bytes"), size_mb = reg("flash.size_mb");

    unsigned mb = argc == 2 ? (unsigned)strtoul(argv[1], NULL, 0) : (unsigned)size_mb;
    if (mb == 0 || mb > size_mb) {
        fprintf(stderr, "MB must be 1..%u\n", (unsigned)size_mb);
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
    unsigned pages = (unsigned)(bytes / win_bytes);
    unsigned pages_per_mb = (unsigned)(1048576u / win_bytes);
    for (unsigned p = 0; p < pages; p++) {
        wr(r_page, p);
        (void)rd(r_page);   /* make sure the page write landed before the window reads */
        for (unsigned w = 0; w < win_bytes / 4u; w++) {
            uint32_t v = rd(win + 4u * w);
            size_t o = (size_t)p * win_bytes + 4u * w;
            buf[o] = (uint8_t)v;
            buf[o + 1] = (uint8_t)(v >> 8);
            buf[o + 2] = (uint8_t)(v >> 16);
            buf[o + 3] = (uint8_t)(v >> 24);
        }
        if ((p + 1) % pages_per_mb == 0 || p + 1 == pages) {
            printf("\r  %u/%u MB  %.0f s", (p + 1) / pages_per_mb, mb, plat_now() - t0);
            fflush(stdout);
        }
    }
    printf("\n");
    wr(r_page, 0u);
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
