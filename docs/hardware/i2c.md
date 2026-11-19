# I2C buses

> Status: verified for buses #1 and #2 from the FPGA side (addresses that answer, pins,
> telemetry reads); bus #3 and the device functions are reported
> Source: `I2C` sheet of [FPGA_Pinouts.xlsx](../../hardware/pinouts/FPGA_Pinouts.xlsx);
> measured on this card with [projects/06_i2c_telemetry](../../projects/06_i2c_telemetry/)
> Last verified: 2026-11-19 (PCB `M1003380-005`,
> [lab log](../../lab-log/2026-11-19-06-i2c.md))

There are **three** I2C buses on the card. Only buses #1 and #2 are driven by the FPGA;
bus #3 is the NIC management bus and is reachable through a header.

The FPGA reaches buses #1 and #2 with open-drain 1.8 V pins at 100 kHz (project 06). Both
buses idle high with the FPGA pins released, so the pull-ups seen by the FPGA are present
(verified 2026-11-19). Their voltage and value were not measured.

## Bus #1 — "board" bus

FPGA pins: **SDA `L20`, SCL `K20`** (verified 2026-11-19: the retimer answers on these
pins). Powered from the board's 3.3 V rail (reported; available even when the host is off,
as long as 12 V is present).

| Address | Device | Function | Status |
|---------|--------|----------|--------|
| `0x22` | U17 `DS250DF810` | 50G retimer | **verified** 2026-11-19: answers; vendor ID `0xFE` = `0x03` (TI); `0xEF`–`0xF3` = `0C 31 10 00 00`; page register `0xFF` and channel select `0xFC` read `0x00` |
| `0x50` | QSFP cage | module EEPROM (SFF-8636) | reported; no answer without a module (none was inserted) |

No other address in `0x08`–`0x77` answers (2026-11-19, no QSFP module).

Also brought out on header **J10** (1 = SCL, 2 = SDA, 3 = GND). This is the easiest place
to attach a USB-I2C adapter.

## Bus #2 — "management" bus

FPGA pins: **SDA `K21`, SCL `J23`** (verified 2026-11-19). Powered from PCIe 3.3 V
(reported).

| Address | Device | Function | Status |
|---------|--------|----------|--------|
| `0x0C` | — | not in the reported map | **answers** (2026-11-19). `0x0C` is the SMBus Alert Response Address: a device may be asserting SMBALERT (`hypothesis`; reading `0x0C` returns the alerting device's address, not done yet) |
| `0x1F` | U12 Mellanox NIC | management | reported device; on this card it **holds SCL low for more than 10 ms** when addressed (one-byte read probe), then releases the bus |
| `0x27` | U55 `PCA9535` | 16-bit GPIO expander | reported; **does not answer** (2026-11-19) |
| `0x40` | U26 `MP2953B` | multiphase VR controller (telemetry) | **verified** answers (2026-11-19); registers not read |
| `0x42` | U13 `LM25066` | hot-swap controller / power monitor | **verified** 2026-11-19, readings below |
| `0x48` | U12 Mellanox NIC | secondary address | reported; **does not answer** (2026-11-19) |
| `0x4C` | U18 `TMP411` | board temperature sensor | **verified** 2026-11-19, readings below |
| `0x4F` | — | not in the reported map | **answers** (2026-11-19); device unknown |
| `0x51` | U16 `M24128` | 128 Kb EEPROM (board identity) | **verified** answers (2026-11-19); contents not read |
| `0x6D` | U56 `9DBV0441` | PCIe clock buffer (output enable / config) | **verified** answers (2026-11-19) |

Also on header **J2** (1 = SCL, 2 = SDA, 3 = GND).

### Readings (2026-11-19, project 06, fan on, die 40.9–41.6 °C)

| Device | Register | Raw | Value |
|--------|----------|-----|-------|
| TMP411 | `0x03` configuration | `0x00` | standard range (0–127 °C, no offset) |
| TMP411 | `0x00` / `0x15` local | `0x28` / `0x00` | 40.00 °C |
| TMP411 | `0x01` / `0x10` remote | `0x2B` / `0x30` | 43.19 °C (42.88–43.19 °C over the session) |
| LM25066 | `0x88` `READ_VIN` | `0x0A6E`–`0x0A70` | 12.179–12.188 V |
| LM25066 | `0x8B` `READ_VOUT` | `0x0A66`–`0x0A69` | 12.143–12.157 V |
| LM25066 | `0x8D` `READ_TEMPERATURE_1` | `0x0286`–`0x028D` | 40.4–40.8 °C |
| LM25066 | `0xD1` `MFR_READ_IIN` | `0x0285`–`0x0296` | not converted: needs the sense resistor value (`unknown`) |
| LM25066 | `0xD2` `MFR_READ_PIN` | `0x01A2`–`0x01A5` | not converted (same reason) |

LM25066 values use the DIRECT format and the datasheet coefficients (Table 41): VIN/VOUT
`m = 22070, b = −1800, R = −2`; temperature `m = 16000, b = 0, R = −3`. Words are little
endian. What the TMP411 remote diode is connected to is `unknown`; its reading tracks the
FPGA die sensor within about 2 °C.

Useful reads (all verified 2026-11-19 unless stated):

- `TMP411` (`0x4C`): local temperature `0x00` (+ `0x15` fraction), remote `0x01`
  (+ `0x10`), configuration read `0x03` (bit 2 = extended range, +64 °C offset).
- `LM25066` (`0x42`): `READ_VIN` (`0x88`), `READ_VOUT` (`0x8B`), `READ_TEMPERATURE_1`
  (`0x8D`), and **`MFR_READ_IIN` (`0xD1`) / `MFR_READ_PIN` (`0xD2`)** for input current and
  power. The standard PMBus `READ_IIN` (`0x89`) and `READ_PIN` (`0x97`) are NACKed. This
  page listed `READ_IOUT (0x8C)` and `READ_PIN (0x97)` before 2026-11-19; that was wrong
  for this part.
- `M24128` (`0x51`): first 256 bytes usually contain a Microsoft inventory string
  (reported; not read yet).
- `PCA9535` (`0x27`): controls LEDs/level-shifter enables; read before writing (reported;
  it did not answer on this card).
- `MP2953B` (`0x40`): read only; never change its configuration without a plan (AGENTS.md,
  section 12).

## Bus #3 — Mellanox management

Reached through header **J9** (PCIe variant) or **U32** (OCP variant); pin 1 = GND,
pin 2 = D3 status LED, pin 3 = SCL, pin 4 = SDA. Also visible from the FPGA through U25/U45
level shifters. Status: reported, not tested.

## Notes on the spreadsheet

The original I2C sheet lists the level shifters (U25, U39, U44, U45) with their pin
numbers, not their FPGA pins. Those are the same `SN74AVC4T774` style parts used around
U22. If you need to drive bus #3 from the FPGA, trace those nets first. The sheet names
U26 `MP2958`; the datasheet kept in `hardware/datasheets/U26 - MP2958/` is the `MP2953B`.

## Bus speed

100 kHz works on buses #1 and #2 (verified 2026-11-19, project 06). No pull-up values were
measured. The retimer and the VR controllers support 400 kHz (reported). Keep a SCL timeout
in any master: the device at `0x1F` stretches SCL for more than 10 ms.
