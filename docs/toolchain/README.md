# Toolchain

> Status: verified with Quartus Prime Pro 25.1 on Windows 10 x64 · Last verified: 2026-11-17
## What you need

| Component | Version used here | Why |
|-----------|-------------------|-----|
| Quartus Prime **Pro** | 25.1.0.129 | Arria 10 support, `quartus_pgm`, `jtagconfig` |
| Arria 10 device package | `arria10-25.1.0.129.qdz` | device database for `10AXF40AA` |
| FTDI D2XX driver | Windows update / CDM 2.12+ | on-board FT232H programmer |
| USB-Blaster plugin | `jtag_hw_microsoft_catapult.dll` | makes Quartus see the FT232H as a programmer |

Quartus **Standard** also supports Arria 10 and is free; it can compile the designs in this
repo, but the reference OpenCL BSP requires the Pro edition. The community projects were
built with 20.1 Pro/Standard; migration to 25.1 is usually just re-running the flow.

## Pages

- [quartus-install.md](quartus-install.md) — silent install, device package, environment
- [onboard-usb-blaster.md](onboard-usb-blaster.md) — plugin DLL, driver, verification
- [build-and-program.md](build-and-program.md) — build and download commands, flash backup
- [linux.md](linux.md) — Linux equivalents

## Environment

The scripts in this repo assume either:

- `QUARTUS_ROOTDIR` is set (usual on a Quartus install), or
- `scripts/env.ps1` is dot-sourced, which auto-detects `D:\altera_pro\25.1\quartus`,
  `C:\altera_pro\25.1\quartus`, `C:\intelFPGA_pro\*\quartus`, etc.

```powershell
. .\scripts\env.ps1
quartus_sh --version
```

## Licensing

Quartus Prime **Pro** is commercial software and requires a valid licence (or the
evaluation period offered by the installer). This repository does **not** contain licence
files, key generators or patched binaries, and contributors must not add them. If you only
need Arria 10 compilation and do not have a Pro licence, install the free
**Quartus Prime Standard** edition instead — every project in `projects/` compiles there
too.

If `quartus_map` stops with a licence error, that is a toolchain problem, not a board
problem: see [troubleshooting.md](../troubleshooting.md#licence-errors).
