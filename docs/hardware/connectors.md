# Connectors and headers

> Status: reported · Source: `Header_Pinouts.xlsx`, board photos

All headers are on the top side unless noted. Pin 1 is marked with a square pad on the
silkscreen; verify before inserting a cable.

| Ref | Type | Purpose | Notes |
|-----|------|---------|-------|
| J1 | PCIe x16 edge | host + power | lanes 0-15, 12 V and 3.3 V from the slot |
| J4 | USB type-B | on-board FT232H programmer | bracket; the normal programming port |
| J6 | 4-pin USB header | alternate FT232H USB | muxed with J4; pin 1 = +5 V, 2 = D-, 3 = D+, 4 = GND |
| J5 | 2×5 JTAG | external USB-Blaster | see [jtag.md](jtag.md); pin 10 to GND disables the on-board FT232H |
| J2 | 3-pin I2C | bus #2 | 1 = SCL, 2 = SDA, 3 = GND, 3.3 V PCIe powered |
| J10 | 3-pin I2C | bus #1 | 1 = SCL, 2 = SDA, 3 = GND, board powered |
| J9 (OCP: U32) | 4-pin I2C | bus #3, Mellanox | 1 = GND, 2 = D3 status LED, 3 = SCL, 4 = SDA |
| J11 | 4-pin GPIO | FPGA pins `A24`, `A25`, `A26`, GND | PCIe variant only, 1.8 V with pull-ups |
| J8 | 3-pin fan | 12 V fan | PCIe variant only; pin 1 = NC, 2 = +12 V, 3 = GND |
| J12 | 2-pin unknown | unknown | 3.3 V 10 kΩ pull-down; do not connect |
| — | 6-pin ATX-style | auxiliary 12 V | top-left corner of the PCB; supplements slot power |

## J11 GPIO

Three FPGA pins are brought to J11 on the PCIe variant:

| J11 pin | FPGA pin | Note |
|---------|----------|------|
| 1 | `A24` | 1.8 V, pulled up on the board |
| 2 | `A25` | 1.8 V, pulled up |
| 3 | `A26` | 1.8 V, pulled up |
| 4 | GND | |

This is the only generic user I/O header. With a 1.8 V-level USB-UART adapter you can build
a serial console, but note the pins are 1.8 V — do not connect a 3.3 V or 5 V adapter
directly. Level-shift first.

## J6 vs J4

Both connect to the FT232H's USB pins. The board ships with the bracket USB-B (J4)
connected; J6 is for a chassis-mounted USB port. Only one should be used at a time. There
is a mux controlled by the board (not by the FPGA).

## Auxiliary power

The white 6-pin connector near the top-left corner accepts 12 V. Surplus cards are often
sold without the cable. The card will enumerate and the FPGA will configure from slot power
alone, but heavy FPGA designs (and the 50G PHY) may brown out; connect auxiliary 12 V for
any serious work.

> **Polarity matters.** Measure the connector before making a cable. Do not assume the pin
> order of a standard PCIe 6-pin connector.

## Fan

J8 is a 3-pin header; the card was designed for chassis airflow. For bench use, a 40-60 mm
fan blowing across the FPGA heatsink and the retimer is strongly recommended. The Arria 10
will throttle or fail timing when hot.
