# Mirrored upstream project — quick index

Upstream README: [README.upstream.md](README.upstream.md) (verbatim).

## Projects

| Folder | Design | Pins / resources | Notes |
|--------|--------|------------------|-------|
| `Projects/LEDs` | 9-LED blinker | only `clk_u59` + `leds[8:0]` | smallest possible design, good first compile |
| `Projects/GoldenTop` | exposes clocks, LEDs, both DDR4, both PCIe, QSFP, I2C, J11, U22 | all board I/O | use as a template for new designs |
| `Projects/I2C` | I2C master + scan | bus 1/2 | NIOS II software included |
| `Projects/DDR4/DDR4_Top` | one EMIF (top channel) | 72-bit | calibration status on LEDs |
| `Projects/DDR4/DDR4_Bot` | one EMIF (bottom channel) | 72-bit | |
| `Projects/DDR4/DDR4_Dual` | both channels | 2 × 72-bit | best starting point for a memory-heavy design |
| `Projects/PCIe/PCIe1` | PCIe HIP #1 + BAR0 PIO | x8 | PIO drives `leds[7:0]` |
| `Projects/PCIe/PCIe2` | PCIe HIP #2 + BAR0 PIO | x8 | |
| `Projects/PCIe/PCIe_Dual` | both HIPS | 2 × x8 | needs x8/x8 bifurcation |
| `Projects/Network/SuperliteII_V4_QSFP` | 4-lane 64b/66b link + retimer config | QSFP | needs a second card and a cable |

## How these were built

- Quartus 20.1.1 (Standard/Pro), device `10AXF40AA`.
- Platform Designer (Qsys) systems are included as `.qsys`.
- `GoldenTop` and `PCIe*` use the Arria 10 hard IP; regeneration in a newer Quartus is
  expected.

## What to reuse

- **Pin assignments** — copy from the `.qsf` into your project.
- **Clock/reset structure** — `GoldenTop.v` shows the expected top-level ports.
- **EMIF settings** — keep the original board timing parameters; do not let Quartus guess.
- **Retimer I2C sequence** — `Network/SuperliteII_V4_QSFP/Software/app/i2c_functions.c`.

## What not to reuse

- Device family version-specific IP (regenerate).
- The NIOS II BSP (tied to an old Nios II EDS).
- Any absolute paths (the `.qsf` files contain none, but the `.qsys` may).
