# I2C buses

> Status: reported (community scan), not re-verified in this lab
> Source: `I2C` sheet of [FPGA_Pinouts.xlsx](../../hardware/pinouts/FPGA_Pinouts.xlsx)

There are **three** I2C buses on the card. Only buses #1 and #2 are driven by the FPGA;
bus #3 is the NIC management bus and is reachable through a header.

## Bus #1 — "board" bus

FPGA pins: **SDA `L20`, SCL `K20`**. Powered from the board's 3.3 V rail (available even
when the host is off, as long as 12 V is present).

| Address | Device | Function |
|---------|--------|----------|
| `0x22` | U17 `DS250DF810` | 50G retimer |
| `0x50` | QSFP cage | module EEPROM (SFF-8636) |

Also brought out on header **J10** (1 = SCL, 2 = SDA, 3 = GND). This is the easiest place
to attach a USB-I2C adapter.

## Bus #2 — "management" bus

FPGA pins: **SDA `K21`, SCL `J23`**. Powered from PCIe 3.3 V.

| Address | Device | Function |
|---------|--------|----------|
| `0x1F` | U12 Mellanox NIC | management (secondary address `0x48` also responds) |
| `0x40` | U26 `MP2953B` | multiphase VR controller (telemetry) |
| `0x42` | U13 `LM25066` | hot-swap controller / power monitor |
| `0x4C` | U18 `TMP411` | board temperature sensor |
| `0x51` | U16 `M24128` | 128 Kb EEPROM (board identity) |
| `0x6D` | U56 `9DBV0441` | PCIe clock buffer (output enable / config) |
| `0x27` | U55 `PCA9535` | 16-bit GPIO expander |

Also on header **J2** (1 = SCL, 2 = SDA, 3 = GND).

Useful first reads:

- `TMP411` (`0x4C`): local temperature register `0x00`, remote `0x01`.
- `LM25066` (`0x42`): `READ_VIN` (0x88), `READ_IOUT` (0x8C), `READ_PIN` (0x97).
- `M24128` (`0x51`): first 256 bytes usually contain a Microsoft inventory string.
- `PCA9535` (`0x27`): controls LEDs/level-shifter enables; read before writing.

## Bus #3 — Mellanox management

Reached through header **J9** (PCIe variant) or **U32** (OCP variant); pin 1 = GND,
pin 2 = D3 status LED, pin 3 = SCL, pin 4 = SDA. Also visible from the FPGA through U25/U45
level shifters.

## Notes on the spreadsheet

The original I2C sheet lists the level shifters (U25, U39, U44, U45) with their pin
numbers, not their FPGA pins. Those are the same `SN74AVC4T774` style parts used around
U22. If you need to drive bus #3 from the FPGA, trace those nets first.

## Bus speed

No pull-up values were measured. Assume 100 kHz is safe; the retimer and the VR controllers
support 400 kHz. Use open-drain drivers with the FPGA's 1.8 V I/O and check that the bus is
not already pulled to 3.3 V before connecting.
