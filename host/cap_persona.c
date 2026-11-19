/*
 * cap_persona.c — A + B persona test of project 04 (needs PR)
 *
 *   persona   write A, B and check SUM against the loaded persona
 *             (persona 1: A + B, persona 2: A - B)
 *
 * Registers: persona.a, persona.b, persona.sum (built-in legacy profile).
 * A profile without these keys has no A + B persona; the command then prints
 * the persona state and reports the persona ID as unknown (exit code 4), as
 * the tool did before profiles existed.
 */
#include <stdio.h>

#include "tool.h"

int persona_has_ab(void)
{
    return has_key("persona.a") && has_key("persona.b") && has_key("persona.sum");
}

int cmd_persona(void)
{
    if (require_pr("persona") != 0)
        return 3;
    print_persona();
    unsigned id = rd(reg("regs.persona")) & 0xFFFFu;
    if (!persona_has_ab()) {
        fprintf(stderr, "Unknown persona ID 0x%04X: profile %s has no A + B persona test "
                        "(use the project's own commands).\n", id, g_prof->name);
        return 4;
    }
    const uint32_t r_a = reg("persona.a"), r_b = reg("persona.b"), r_sum = reg("persona.sum");
    const uint32_t a = 0x12345678u, b = 0x11111111u;
    wr(r_a, a);
    wr(r_b, b);
    uint32_t sum = rd(r_sum);
    id = rd(reg("regs.persona")) & 0xFFFFu;
    uint32_t expected;
    const char *op;
    if (id == 1) {
        expected = a + b;
        op = "A + B";
    } else if (id == 2) {
        expected = a - b;
        op = "A - B";
    } else {
        fprintf(stderr, "Unknown persona ID 0x%04X; SUM 0x%08X\n", id, (unsigned)sum);
        return 4;
    }
    printf("A=0x%08X B=0x%08X  persona %u: %s\n", (unsigned)a, (unsigned)b, id, op);
    printf("SUM:     0x%08X (expected 0x%08X)\n", (unsigned)sum, (unsigned)expected);
    print_temp_line();
    if (sum != expected) {
        printf("Persona test FAILED.\n");
        return 4;
    }
    printf("Persona test PASSED.\n");
    return 0;
}
