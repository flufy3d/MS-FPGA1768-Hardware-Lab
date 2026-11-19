/*
 * profile.h — per-project host profiles (host/profiles/<project>.ini)
 *
 * A profile describes one project's BAR0: its SHELL_ID, its capability bits and
 * every register offset the capability modules use. The core reads SHELL_ID
 * from BAR0 + 0x00 and selects the profile whose shell_id matches.
 *
 * File format (INI, one file per project):
 *
 *   [profile]           name, project, description, shell_id, caps, caps2
 *   [regs]              register offsets in BAR0 (shell_id, caps, caps2, id, temp, ...)
 *   [<module>]          constants of one capability module (ddr, flash, pr, ...)
 *
 * Keys are looked up as "section.key" (for example "regs.temp", "ddr.word_bytes").
 * Lines starting with ';' or '#' are comments; values are C integers (0x.. hex).
 */
#ifndef PROFILE_H
#define PROFILE_H

#include <stdint.h>

/* Minimal contract shared by every project with a profile (BAR0 offsets). */
#define CONTRACT_SHELL_ID  0x00u
#define CONTRACT_CAPS      0x04u
#define CONTRACT_CAPS2     0x08u   /* reserved, reads 0 */

/* CAPS bits */
#define CAP_DDR4           (1u << 0)
#define CAP_I2C            (1u << 1)
#define CAP_PR             (1u << 2)
#define CAP_FLASH          (1u << 3)
#define CAP_DMA            (1u << 4)

#define PROFILE_MAX_KEYS   160
#define PROFILE_MAX_FILES  64
#define PROFILE_PATH_LEN   512

typedef struct profile_kv {
    char key[48];      /* "section.key" */
    char val[128];
} profile_kv_t;

typedef struct profile {
    char         name[64];
    char         path[PROFILE_PATH_LEN];
    uint32_t     shell_id;
    uint32_t     caps;
    uint32_t     caps2;
    int          nkv;
    profile_kv_t kv[PROFILE_MAX_KEYS];
} profile_t;

/* Parse one file. Returns 0 on success; prints the reason to stderr otherwise. */
int  profile_load(const char *path, profile_t *p);

/* Look up "section.key". Returns 0 and stores the value, or -1 if absent/invalid. */
int         profile_u32(const profile_t *p, const char *key, uint32_t *v);
const char *profile_str(const profile_t *p, const char *key);

/*
 * Profile search path, in order (the first directory that exists is used for
 * each lookup, but all are listed by profile_dirs):
 *   1. $FPGA1768_PROFILES (one directory, or a list separated by ';' on
 *      Windows and ':' elsewhere)
 *   2. <exe dir>/profiles
 *   3. <exe dir>/../profiles        (host/build/fpga1768.exe -> host/profiles)
 *   4. ./profiles, ./host/profiles  (current directory)
 * Returns the number of candidate directories written to dirs.
 */
int  profile_dirs(char dirs[][PROFILE_PATH_LEN], int max);

/*
 * Load every *.ini of every search directory (a name already loaded from an
 * earlier directory hides later ones). Returns the count; *out is malloc()ed.
 */
int  profile_load_all(profile_t **out);

/* Find by name ("05_ddr4") or by file path. NULL if not found. *out malloc()ed. */
profile_t *profile_find(const char *name_or_path);

/* Find the profile whose shell_id matches. NULL if none. *out malloc()ed. */
profile_t *profile_match(uint32_t shell_id);

/* "DDR4 PR FLASH" style text for a CAPS value. */
const char *caps_text(uint32_t caps, char *buf, unsigned len);

#endif
