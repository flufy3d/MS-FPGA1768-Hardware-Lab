# 2026-11-19 — DS250DF810 retimer status and CDR bypass over I2C (project 06)

- **Date:** 2026-11-19
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`; no QSFP
  module inserted
- **Host:** ASUS X99-E, Windows 10 Pro 19045; fan on the heatsink
- **Toolchain:** design `projects/06_i2c_telemetry` as loaded in
  [2026-11-19-06-i2c.md](2026-11-19-06-i2c.md) (`.sof` SHA-256 `E71229EB…21F98`, persona 1);
  host tool `fpga1768` with the new `retimer` module (commit `573c7e2`)
- **Goal:** read what the retimer (U17, bus 1 `0x22`) reports per channel, and switch its
  output mux to raw data (CDR bypass) and back, using only volatile registers.

## What was done

1. Checked the register definitions against the datasheet PDF text (SNLS513C, Tables 8–12):
   `0x09[5]` `REG_BYPASS_PFD_OV` must be 1 for `0x1E[7:5]` `PFD_SEL_DATA_MUX` to take
   effect (`000` raw data, `001` retimed, `100` pattern generator, `111` mute).
2. 22:24:05 — die 41.6 °C. `fpga1768 retimer status`: writes only `0xFC` / `0xFF` to select
   the shared and channel pages, reads, restores both.
3. `fpga1768 retimer bypass all on`, `retimer status`, `retimer bypass all off`,
   `retimer status`, `i2c status`, `temp` (22:24:18).

## Observations

- IDs `0xEF`–`0xF3` = `0C 31 10 00 00`, vendor `0xFE` = `0x03`. Datasheet Table 10 gives
  `0xF0` = `0x32`, `0xF1` = `0x10`, `0xF3` = `0x00`: `0xF0` reads `0x31` on this card
  (silicon revision difference? `unknown`).
- `0xFF` = `0x00`, `0xFC` = `0x00` before and after every command.
- Shared registers, quad 0 and quad 1 identical: `0x05[4]` `EEPROM_READ_DONE` = 0, `0x11` =
  `0x00` (0 load attempts), `0x0B[6]` `refclk_det` = 1, interrupts `0x08` = `0x00`. The 25 MHz
  reference is present; no EEPROM load was attempted (the part appears to be strapped for
  SMBus slave mode — `hypothesis`).
- All eight channels, before any change: `0x01` = `0x00` (`sigdet` 0, no PRBS detected),
  `0x02` CDR_STATUS = `0x01`, `0x09` = `0x00`, `0x1E` = `0xE9`, HEO/VEO `0x00`/`0x00`,
  `0x2F` = `0x54` (`RATE` = `101`). `0x09`, `0x1E` and `0x2F` equal the datasheet power-up
  defaults, so no configuration had been loaded into the retimer.
- `bypass all on`: per channel `0x1E` `0xE9` → `0x09`, then `0x09` `0x00` → `0x20`; read back
  matches; status shows `raw (CDR bypass)` on channels 0–7.
- `bypass all off`: `0x09` `0x20` → `0x00`, `0x1E` `0x09` → `0xE9`; read back equals the
  defaults on channels 0–7.
- I2C lines high and idle afterwards; die 41.6 °C throughout.

## Result

**Success** for register access: all eight channels can be read and switched between raw
data (CDR bypass) and retimed output over the FPGA I2C master, and returned to the power-up
defaults. The effect on a data stream was **not** observed: no QSFP module was inserted
and the FPGA design does not drive the QSFP transceivers (all channels show no signal).

The community recipe in `docs/hardware/ethernet-qsfp.md` (write `0x1E[7:5]` = `000` only)
omits the `0x09[5]` override that the datasheet requires; corrected there.

## Artifacts

- No bitstream change (same `.sof` as the 06 session).
- Console output kept outside the repository; values above are copied from it.
