/*
 * core.c — BAR0 access, profile selection and capability checks
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tool.h"

bar_t           *g_bar;
const profile_t *g_prof;
int              g_legacy;
uint32_t         g_caps;

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

/*
 * Projects 03 and 04 have no SHELL_ID or CAPS register and no profile file;
 * this built-in table is their register map (see their READMEs).
 */
static const char *legacy_kv[][2] = {
    { "profile.name",        "legacy" },
    { "profile.project",     "projects/03_pcie_gen3, projects/04_pcie_hot_update" },
    { "profile.description", "built in: designs without SHELL_ID/CAPS" },
    { "regs.counter",        "0x0030" },
    { "regs.id",             "0x0040" },
    { "regs.temp",           "0x0050" },
    { "regs.persona",        "0x0060" },
    { "regs.pr_data",        "0x0100" },
    { "regs.pr_csr",         "0x0104" },
    { "regs.pr_version",     "0x0108" },
    { "regs.pr_id",          "0x010C" },
    { "pr.version",          "0xAA500003" },
    { "persona.a",           "0x0000" },
    { "persona.b",           "0x0010" },
    { "persona.sum",         "0x0020" },
};

const profile_t *legacy_profile(void)
{
    static profile_t p;
    static int init;
    if (!init) {
        memset(&p, 0, sizeof(p));
        for (size_t i = 0; i < sizeof(legacy_kv) / sizeof(legacy_kv[0]); i++) {
            snprintf(p.kv[i].key, sizeof(p.kv[i].key), "%s", legacy_kv[i][0]);
            snprintf(p.kv[i].val, sizeof(p.kv[i].val), "%s", legacy_kv[i][1]);
            p.nkv++;
        }
        snprintf(p.name, sizeof(p.name), "legacy");
        snprintf(p.path, sizeof(p.path), "(built in)");
        init = 1;
    }
    return &p;
}

int has_key(const char *key)
{
    uint32_t v;
    return profile_u32(g_prof, key, &v) == 0;
}

uint32_t reg(const char *key)
{
    uint32_t v;
    if (profile_u32(g_prof, key, &v) != 0) {
        fprintf(stderr, "Profile '%s' (%s) has no integer value for '%s'.\n",
                g_prof ? g_prof->name : "?", g_prof ? g_prof->path : "?", key);
        exit(2);
    }
    return v;
}

int core_select_profile(const char *force, int quiet)
{
    static profile_t *owned;
    uint32_t id = rd(CONTRACT_SHELL_ID);

    free(owned);
    owned = NULL;
    if (force) {
        owned = profile_find(force);
        if (!owned) {
            fprintf(stderr, "Profile '%s' not found (see 'fpga1768 list').\n", force);
            return -1;
        }
        if (owned->shell_id != id && !quiet)
            fprintf(stderr, "Note: --profile %s expects SHELL_ID 0x%08X, BAR0 + 0x00 reads 0x%08X.\n",
                    owned->name, (unsigned)owned->shell_id, (unsigned)id);
    } else {
        owned = profile_match(id);
    }

    if (!owned) {
        g_prof = legacy_profile();
        g_legacy = 1;
        g_caps = 0;
        return 0;
    }
    g_prof = owned;
    g_legacy = 0;

    uint32_t hw = rd(CONTRACT_CAPS);
    if (hw == 0 && owned->caps != 0) {
        /* A build of the same project made before the CAPS register existed
         * (the 05_shell image in the lab card's flash, 2026-11-19): the
         * register reads 0, so trust the profile. */
        if (!quiet)
            fprintf(stderr, "Note: CAPS (BAR0 + 0x04) reads 0; bitstream predates the CAPS register, "
                            "using CAPS 0x%08X from profile %s.\n", (unsigned)owned->caps, owned->name);
        g_caps = owned->caps;
    } else {
        if (hw != owned->caps && !quiet)
            fprintf(stderr, "Note: CAPS reads 0x%08X, profile %s says 0x%08X; using the hardware value.\n",
                    (unsigned)hw, owned->name, (unsigned)owned->caps);
        g_caps = hw;
    }
    return 0;
}

static const char *cap_name(uint32_t cap)
{
    switch (cap) {
    case CAP_DDR4:  return "DDR4 (CAPS bit 0)";
    case CAP_I2C:   return "I2C (CAPS bit 1)";
    case CAP_PR:    return "PR (CAPS bit 2)";
    case CAP_FLASH: return "flash window (CAPS bit 3)";
    default:        return "unknown capability";
    }
}

int need_cap(uint32_t cap, const char *command)
{
    if (g_legacy) {
        if (cap == CAP_PR)
            return 0;   /* project 04: checked by the PR module itself */
        fprintf(stderr, "'%s' needs %s, but BAR0 + 0x00 reads 0x%08X, which matches no profile.\n"
                        "Load a design that has this capability, or see 'fpga1768 list'.\n",
                command, cap_name(cap), (unsigned)rd(CONTRACT_SHELL_ID));
        return -1;
    }
    if (!(g_caps & cap)) {
        char t[64];
        fprintf(stderr, "'%s' needs %s, which the loaded design (profile %s, CAPS 0x%08X: %s) "
                        "does not have.\n", command, cap_name(cap), g_prof->name, (unsigned)g_caps,
                caps_text(g_caps, t, sizeof(t)));
        return -1;
    }
    return 0;
}

int require_id(void)
{
    uint32_t id = rd(reg("regs.id"));
    if (id != ID_VALUE) {
        fprintf(stderr, "ID register 0x%08X, expected 0x%08X: wrong bitstream loaded.\n",
                (unsigned)id, (unsigned)ID_VALUE);
        return -1;
    }
    return 0;
}
