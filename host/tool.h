/*
 * tool.h — core API shared by the fpga1768 capability modules
 *
 * Layout of the tool:
 *   core        fpga1768.c (commands, dispatch), core.c (BAR0 access, profile
 *               selection, capability checks), profile.c (INI files),
 *               bar_windows.c / bar_linux.c (enumerate 1172:E003, map BAR0)
 *   modules     cap_temp.c, cap_pr.c, cap_persona.c, cap_ddr.c, cap_flash.c
 *   profiles    host/profiles/<project>.ini
 *
 * Modules never hard-code a BAR0 offset: they ask for it by name with reg()
 * ("regs.temp", "ddr.status", ...), and the active profile supplies it.
 */
#ifndef TOOL_H
#define TOOL_H

#include <stdint.h>
#include "bar_access.h"
#include "profile.h"

/* The Windows test driver allows BAR0 writes only when BAR0 + regs.id reads this. */
#define ID_VALUE     0x50434945u

extern bar_t *g_bar;

/*
 * Active profile: the one whose shell_id matches BAR0 + 0x00, the one forced
 * with --profile, or the built-in "legacy" profile (projects 03 and 04, which
 * predate the SHELL_ID/CAPS contract). Never NULL after core_select_profile().
 */
extern const profile_t *g_prof;
extern int              g_legacy;     /* 1: built-in legacy profile in use */
extern uint32_t         g_caps;       /* effective CAPS */

uint32_t rd(uint32_t off);              /* exits with code 5 on error */
void     wr(uint32_t off, uint32_t v);

/* Offset or constant "section.key" of the active profile; exits with code 2 if absent. */
uint32_t reg(const char *key);
int      has_key(const char *key);

/* Built-in profile for projects 03/04 (no SHELL_ID / CAPS registers). */
const profile_t *legacy_profile(void);

/* Read SHELL_ID / CAPS and pick the profile. force: name or .ini path, or NULL. */
int      core_select_profile(const char *force, int quiet);

/*
 * Capability check for a command. In profile mode the CAPS bit must be set;
 * otherwise a clear message names the command, the missing capability, the
 * SHELL_ID and the profile, and -1 is returned (callers exit with code 3).
 * In legacy mode PR is left to the command's own checks (project 04 has a PR
 * controller but no CAPS register); DDR4, I2C and FLASH are refused.
 */
int      need_cap(uint32_t cap, const char *command);

int      require_id(void);              /* 0 if the ID register matches */

/* cap_temp.c */
double   temp_now(void);                /* die temperature, degC */
void     print_temp_line(void);
int      cmd_temp(double interval, long count);

/* cap_pr.c */
void     print_link(const bar_info_t *i);
int      require_pr(const char *command);  /* PR capability, ID, controller, PLL lock */
int      has_pr_controller(void);
void     print_persona(void);
int      cmd_load_pr(const char *path);

/* cap_persona.c */
int      cmd_persona(void);
int      persona_has_ab(void);          /* profile defines the A + B persona registers */

/* cap_ddr.c */
void     ddr_print_info(void);
int      ddr_quiesce(int on, double timeout_s);  /* 0 on success */
int      cmd_ddr(int argc, char **argv);

/* cap_flash.c */
int      cmd_flash_dump(int argc, char **argv);

#endif
