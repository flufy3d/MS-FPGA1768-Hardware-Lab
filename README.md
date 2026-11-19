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
| PCIe enumeration | **As received**, the card presented `1414:B204` (subsystem `0400:1414`, class `0xFF0000`) at Gen3 x8 with no driver bound: a pre-programmed Microsoft bitstream in the config flash. **Since 2026-11-19** this card's flash holds `projects/05_shell`, so a power cycle boots it as `1172:E003` with BAR0 `0x383FFFE00000` and no JTAG load. The Microsoft image is gone from this card. |
| Configuration flash | N25Q00AA, 1 Gb, ASx4. Read twice on 2026-11-19 (128 MB, identical SHA-256 `4C727C31…9326C`), then **written** with `shell.jic` and verified by a cold boot — see the [lab log](lab-log/2026-11-19-flash-program.md). A raw dump cannot be turned back into a programming file with Quartus, so a restore would need an external SPI programmer. |
| On-board USB programmer | FT232H enumerated as `0403:6014`, D2HD driver (`FTDIBUS`) loaded. Quartus needs the plugin DLL — see [docs/toolchain/onboard-usb-blaster.md](docs/toolchain/onboard-usb-blaster.md). |
| JTAG | Works after a full **AC power cycle**: `jtagconfig` reports `02E060DD  10AT115S(1|2)`. The FT232H latches after a crashed programmer run and then needs VBUS removed (not just a reboot). |
| Hello world | **Success (2026-11-17).** `projects/01_hello_world` compiled (23 ALMs, timing met) and was loaded over JTAG in 8m58s. The LEDs show a 1 Hz heartbeat and a binary seconds counter. See the [lab log](lab-log/). |
| DDR4 | **Success (2026-11-19).** `projects/05_shell` brings up both channels: Gen3 x8 endpoint with a 64-bit BAR, both EMIFs `cal SUCCESS`, and the full 2304 MiB of each channel passes walking-one and PRBS-31 tests at 18.2 GB/s per channel. The persona is swapped over PCIe (30.5 s, 1.60 MB/s) without JTAG and without losing calibration. The configuration flash was read twice (128 MB, identical SHA-256) for a backup. **Airflow is mandatory:** without a fan the die read 130.2 °C and the card lost power 5 minutes after configuration; with a small fan it held 48 °C. See [docs/hardware/ddr4.md](docs/hardware/ddr4.md), [docs/bringup/04-ddr4.md](docs/bringup/04-ddr4.md) and the [lab log](lab-log/2026-11-19-05-shell-ddr4.md). |
| PCIe endpoint | **Success (2026-11-18).** `projects/02_pcie_pio` (Avalon-MM, Gen2 x8 128-bit, 32-bit non-prefetchable 64 KB BAR0) enumerates as `1172:E003` at `02:00.0`, gets BAR0 at `0xFAFF0000`, and passes the `A + B` MMIO test with the test-signed KMDF driver. The earlier Gen3 x8 DMA variant's 64-bit prefetchable BAR was never assigned — see the [lab log](lab-log/2026-11-18-pcie-pio-bar0-32bit.md). `projects/03_pcie_gen3` then passed the same test at **Gen3 x8** with a 64-bit BAR0 (BIOS link speed Gen3, Above 4G Decoding, warm reboot after the JTAG load) — [lab log](lab-log/2026-11-18-pcie-gen3-bar0-temp.md). Without a fan the die reached 101 °C in 28.5 minutes; add airflow. |
| PCIe hot update (partial reconfiguration) | **Success (2026-11-18).** `projects/04_pcie_hot_update` adds an Arria 10 PR region to the Gen3 x8 endpoint. The host replaced the logic over PCIe (`A + B` → `A − B` → `A + B`, about 8 s per 13 MB PR bitstream) through the PR controller on BAR0, without JTAG and without a reboot; the link stayed Gen3 x8, BAR0 kept its address and the Windows device stayed OK — [lab log](lab-log/2026-11-18-pcie-hot-update.md). CvP update is not available on Arria 10. |
| QSFP / retimer | Not tested in this lab. A [DisplayPort-over-QSFP+ adapter concept](docs/hardware/qsfp-displayport-adapter.md) and [interactive 3D assembly](https://flufy3d.github.io/MS-FPGA1768-Hardware-Lab/qsfp-dp-adapter.html) are documented. |

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
