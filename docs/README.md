# Documentation index

Everything we know about the **Microsoft FPGA 1768 / Catapult v3 "Longs Peak"** card,
organised so that a new owner can go from "I have a card" to "I have a bitstream running".

> Language: this project is written in **English** (see [AGENTS.md](../AGENTS.md)).
> Quoted Chinese text from original vendor documents is translated in place.

## Read in this order

| # | Document | Why |
|---|----------|-----|
| 1 | [What is this board?](00-what-is-this-board.md) | Identification, variants, what the markings mean |
| 2 | [Hardware overview](hardware/overview.md) | Block diagram and component list |
| 3 | [Toolchain setup](toolchain/README.md) | Quartus 25.1, licensing, on-board USB-Blaster |
| 4 | [Hello world](bringup/02-hello-world.md) | First bitstream, LED test, recovery |

## Hardware

- [overview.md](hardware/overview.md) — block diagram, main ICs, variants
- [fpga.md](hardware/fpga.md) — Arria 10 part number, configuration scheme, config flash, JTAG IDCODE
- [power.md](hardware/power.md) — rails, hot-swap controller, sequencing, aux power
- [clocks.md](hardware/clocks.md) — every oscillator and its frequency
- [leds.md](hardware/leds.md) — the nine front-edge LEDs
- [ddr4.md](hardware/ddr4.md) — two 72-bit DDR4 channels
- [pcie.md](hardware/pcie.md) — two x8 Gen3 interfaces, refclk, PERST#
- [ethernet-qsfp.md](hardware/ethernet-qsfp.md) — QSFP+ cage, DS250DF810 retimer, programming it
- [qsfp-displayport-adapter.md](hardware/qsfp-displayport-adapter.md) — DisplayPort-over-QSFP+ adapter concept and [interactive demo](https://flufy3d.github.io/MS-FPGA1768-Hardware-Lab/) (unknown, not built)
- [mellanox-nic.md](hardware/mellanox-nic.md) — ConnectX ASIC, its PCIe and XCVR links
- [i2c.md](hardware/i2c.md) — three I2C buses and every device address
- [jtag.md](hardware/jtag.md) — on-board FT232H, J5 header, pin behaviour
- [connectors.md](hardware/connectors.md) — J1/J2/J5/J6/J8/J9/J10/J11/J12, U32

## Toolchain

- [quartus-install.md](toolchain/quartus-install.md) — install Pro 25.1 with Arria 10 support
- [onboard-usb-blaster.md](toolchain/onboard-usb-blaster.md) — make `jtagd` talk to the FT232H
- [build-and-program.md](toolchain/build-and-program.md) — command lines, `.sof` vs `.jic`
- [linux.md](toolchain/linux.md) — Linux notes (udev, D2XX, plugin `.so`)

## Bring-up

- [01-jtag-scan.md](bringup/01-jtag-scan.md)
- [02-hello-world.md](bringup/02-hello-world.md)
- [03-pcie-endpoint.md](bringup/03-pcie-endpoint.md)
- [04-ddr4.md](bringup/04-ddr4.md)
- [Troubleshooting](troubleshooting.md)

## Research

- [prior-art.md](reference/prior-art.md) — what other people already did with these cards
- [links.md](reference/links.md) — papers, forum threads, vendor documents
- [../hardware/pinouts/](../hardware/pinouts/) — machine-readable pinouts

## Conventions used in these documents

Each page starts with a status line:

```
> Status: verified | reported | unknown
```

- **verified** — measured or exercised on the physical card in this lab, on the date shown.
- **reported** — taken from prior art or a datasheet, not independently reproduced here.
- **unknown** — hypothesis or open question, clearly marked as such.

Pin names are written exactly as Quartus expects them (`PIN_AM17`), with the FPGA
package position (e.g. `AM17`) in tables where space allows.
