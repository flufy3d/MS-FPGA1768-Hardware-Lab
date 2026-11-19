/*
 * tool.h — helpers shared by the fpga1768 command modules
 */
#ifndef TOOL_H
#define TOOL_H

#include <stdint.h>
#include "bar_access.h"

/* BAR0 registers common to projects 03, 04 and 05. */
#define REG_COUNTER  0x30u
#define REG_ID       0x40u
#define REG_TEMP     0x50u
#define REG_PERSONA  0x60u   /* projects 04 and 05 */
#define REG_PR_DATA  0x100u
#define REG_PR_CSR   0x104u
#define REG_PR_VER   0x108u
#define REG_PR_ID    0x10Cu

#define ID_VALUE     0x50434945u

/* Project 05 shell: BAR0 + 0x00 reads SHELL_ID_V1. */
#define REG_SHELL_ID 0x00u
#define SHELL_ID_V1  0x53480501u

extern bar_t *g_bar;

uint32_t rd(uint32_t off);              /* exits with code 5 on error */
void     wr(uint32_t off, uint32_t v);
void     print_temp_line(void);
double   temp_now(void);                /* die temperature, degC */
int      require_id(void);              /* 0 if the ID register matches */
int      is_shell(void);                /* project 05 shell loaded */

/* ddr.c */
void     shell_print_info(void);
int      shell_quiesce(int on, double timeout_s);  /* 0 on success */
int      cmd_ddr(int argc, char **argv);
int      cmd_flash_dump(int argc, char **argv);

#endif
