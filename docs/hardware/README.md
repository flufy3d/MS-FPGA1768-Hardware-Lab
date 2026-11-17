# Hardware documentation

Board-level knowledge. Each page starts with a status block and links to the raw data it is
based on.

| Page | Topic |
|------|-------|
| [overview.md](overview.md) | block diagram, component list, interfaces |
| [fpga.md](fpga.md) | Arria 10 part number, configuration, JTAG IDCODE |
| [power.md](power.md) | input power, regulators, sequencing |
| [clocks.md](clocks.md) | oscillators and reference clocks |
| [leds.md](leds.md) | nine user LEDs |
| [ddr4.md](ddr4.md) | two 72-bit DDR4 channels |
| [pcie.md](pcie.md) | two x8 Gen3 endpoints |
| [ethernet-qsfp.md](ethernet-qsfp.md) | QSFP+ and DS250DF810 retimer |
| [qsfp-displayport-adapter.md](qsfp-displayport-adapter.md) | DisplayPort-over-QSFP+ adapter concept (unknown) |
| [mellanox-nic.md](mellanox-nic.md) | ConnectX ASIC and its links |
| [i2c.md](i2c.md) | three I2C buses, addresses |
| [jtag.md](jtag.md) | FT232H programmer, J5 header |
| [connectors.md](connectors.md) | headers J1-J12, U32 |

## Raw data

- [../../hardware/pinouts/](../../hardware/pinouts/) — spreadsheets and CSV exports
- [../../hardware/datasheets/](../../hardware/datasheets/) — vendor PDFs
- [../../hardware/photos/](../../hardware/photos/) — photographs and screenshots

## Confidence

Most of the pinout knowledge is community reverse engineering, not vendor documentation.
Pages marked **reported** have not been re-tested here. If you measure something, update
the page and add a lab log entry — do not just fix the table silently.
