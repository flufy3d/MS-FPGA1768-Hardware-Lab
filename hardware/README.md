# Hardware artifacts

Everything physical about the board, in machine-readable or printable form.

| Folder | Contents |
|--------|----------|
| [pinouts/](pinouts/) | FPGA and header pinout spreadsheets, CSV exports, pinout guide |
| [datasheets/](datasheets/) | Vendor datasheets for every identified IC |
| [photos/](photos/) | Board photographs and reference screenshots |
| [tools/usb-blaster/](tools/usb-blaster/) | Quartus JTAG plugin for the on-board FT232H (DLL + SO) |

## What is where

- **Pinouts** — start with [pinouts/README.md](pinouts/README.md). The Excel files are the
  originals from the community; the CSVs are generated from them and are easier to diff and
  grep.
- **Datasheets** — organised by reference designator (`U1`, `U13`, …) where the part is
  known, otherwise by part number.
- **Photos** — `pcie_top.jpg` / `pcie_bottom.jpg` are the Longs Peak card; `ocp_*.jpg` are
  the OCP variant. Screenshots from the upstream project (`device_scan.png`, `emif*.png`,
  `i2c_scan.jpg`, …) document what the tools reported on real hardware.
- **Tools** — do not edit the DLLs; they are binaries from the upstream project. See
  [../docs/toolchain/onboard-usb-blaster.md](../docs/toolchain/onboard-usb-blaster.md).

## Missing / wanted

- A schematic (none is public).
- A dump of the factory configuration flash.
- Close-up photos of U12 (Mellanox marking) and of the power connector pinout.
- Measured rail voltages and current draw.

If you produce any of these, add them here and update
[docs/00-what-is-this-board.md](../docs/00-what-is-this-board.md).
