# Microsoft FPGA 1768 / Catapult v3 "Longs Peak" — Hardware Lab

Working notes, documentation and bring-up projects for a second-hand **Microsoft FPGA 1768**
accelerator card (internal codename **Catapult v3 "Longs Peak"**, OCP sibling
"Dragontails Peak"). The card carries an Altera **Arria 10** FPGA, two x8 PCIe Gen3
interfaces, two DDR4 channels, a 50G QSFP+ port behind a retimer, a Mellanox NIC ASIC and
an on-board FT232H JTAG programmer.

The goal of this repository is to make the card usable as a cheap Arria 10 development
platform and to keep every piece of information that was collected about it in one place.

> **Everything in this repo is experimental.** These cards are salvage hardware with no
> public documentation from Microsoft. Treat all pinouts, rail names and register maps as
> "best known so far" and verify before you rely on them. See each document's `Status`
> header.

---

## Quick start

```powershell
# 1. Toolchain: Quartus Prime Pro 25.1 (Arria 10 device support required)
#    See docs/toolchain/quartus-install.md

# 2. Make Quartus see the on-board FT232H programmer (one-off, needs admin)
.\scripts\install-usb-blaster-plugin.ps1 -QuartusRoot "D:\altera_pro\25.1\quartus"

# 3. Check the JTAG chain (expect IDCODE 0x02E060DD)
.\scripts\jtag-scan.ps1

# 4. Build and load the hello-world design (volatile, does not touch flash)
.\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf
.\scripts\program.ps1 -Sof projects\01_hello_world\output_files\hello_world.sof
```

After step 4 the nine on-board LEDs show a binary counter and a 1 Hz heartbeat.
See [docs/bringup/02-hello-world.md](docs/bringup/02-hello-world.md) for the expected
output and for recovery instructions.

---

## Board at a glance

| Item | Value |
|------|-------|
| Marketing name | Microsoft FPGA 1768 / "50G Accelerator Card" (MSIP-REM-MSK-1768) |
| Internal codename | Catapult v3 **Longs Peak** (PCIe CEM card), sibling **Dragontails Peak** (OCP mezzanine) |
| PCB markings | `M1003380-005`, Microsoft logo, "ALL LEDS ... AT EDGE" silkscreen |
| FPGA | Altera Arria 10, marked **`10AXF40GAA`** (non-standard P/N, 10AX115-class) |
| Configuration flash | Micron **N25Q00AA**, 1 Gb QSPI, active-serial x4 |
| DRAM | 9 × SK hynix **H5AN4G6NAFR-UHC** (4 Gb), two 72-bit DDR4 channels, ≈4.5 GB usable |
| Host interface | 2 × x8 PCIe Gen3 (edge lanes 0-7 and 8-15) + 1 × x8 for the Mellanox ASIC |
| Network | 1 × QSFP+ (4 lanes) through a TI **DS250DF810** retimer |
| NIC ASIC | Mellanox ConnectX-3 Pro / ConnectX-4 Lx (variant dependent, see [docs/hardware/mellanox-nic.md](docs/hardware/mellanox-nic.md)) |
| Debug | On-board **FT232H** USB-JTAG programmer (USB-B), plus J5 external JTAG header |
| Power | PCIe slot + auxiliary 12 V input, on-board multiphase VRs |
| Toolchain | Quartus Prime **Pro 25.1** (Arria 10 support package) |

Full details: [docs/00-what-is-this-board.md](docs/00-what-is-this-board.md).

---

## Repository map

| Path | What lives there |
|------|------------------|
| [`docs/`](docs/README.md) | Everything written down: hardware, toolchain, bring-up, prior art |
| [`hardware/`](hardware/README.md) | Pinout spreadsheets, datasheets, board photos, USB-Blaster plugin binaries |
| [`projects/`](projects/README.md) | Quartus projects maintained in this repo (start with hello world) |
| [`scripts/`](scripts/README.md) | PowerShell helpers: environment, build, program, JTAG scan |
| [`lab-log/`](lab-log/) | Dated log of what was actually done to the physical card |

Start reading here:

1. [What is this board?](docs/00-what-is-this-board.md)
2. [Hardware overview](docs/hardware/overview.md)
3. [Toolchain setup](docs/toolchain/README.md)
4. [Hello world bring-up](docs/bringup/02-hello-world.md)

---

## Status of this card (as measured in this lab)

| Item | State |
|------|-------|
| PCIe enumeration | Card is visible as `1414:B204` (subsystem `0400:1414`, class `0xFF0000`), link trained at Gen2 x8, no driver bound. This is a pre-programmed bitstream that shipped in the config flash. |
| On-board USB programmer | FT232H enumerated as `0403:6014`, D2HD driver (`FTDIBUS`) loaded. Quartus needs the plugin DLL — see [docs/toolchain/onboard-usb-blaster.md](docs/toolchain/onboard-usb-blaster.md). |
| JTAG | Works after a full **AC power cycle**: `jtagconfig` reports `02E060DD  10AT115S(1|2)`. The FT232H latches after a crashed programmer run and then needs VBUS removed (not just a reboot). |
| Hello world | **Success (2026-11-17).** `projects/01_hello_world` compiled (23 ALMs, timing met) and was loaded over JTAG in 8m58s. The LEDs show a 1 Hz heartbeat and a binary seconds counter. See the [lab log](lab-log/). |
| DDR4 | Not yet tested in this lab. Reference designs exist (see [docs/bringup/04-ddr4.md](docs/bringup/04-ddr4.md)). |
| PCIe endpoint | **Partial (2026-11-17).** `projects/02_pcie_pio` built (Gen3 x8 256-bit, timing met) and enumerated as `1172:E003` at `02:00.0`; link Gen2 x8 (max Gen3 x8). BAR0 compute test blocked by a host bugcheck and card power loss; a KMDF test driver is built and test-signed, pending Secure Boot off — see the [lab log](lab-log/2026-11-17-pcie-pio.md). |
| QSFP / retimer | Not tested in this lab. |

---

## Sources and attribution

This repository aggregates information from several public reverse-engineering efforts and
from vendor documentation. The most important ones:

- [tow3rs/catapult-v3-smartnic-re](https://github.com/tow3rs/catapult-v3-smartnic-re) —
  pinouts, BOM, datasheets, Quartus reference projects.
- [thinkoco/microsoft_fpga](https://github.com/thinkoco/microsoft_fpga) — on-board USB-Blaster
  plugin, PCIe/DDR4 demo, OpenCL BSP 18.1.
- Microsoft Research publications on Catapult / Azure SmartNIC.
- Intel/Altera Arria 10 documentation and the Quartus Prime Pro installation.

Vendor documents kept in `hardware/` retain their original attribution; see the README or
NOTICE in each folder. No commercial use is intended.

## License

Original content of this repository (documents, scripts, RTL written here) is released under
the MIT license — see [LICENSE](LICENSE). Third-party material (datasheets, photographs,
plugin binaries) remains under its original terms.
