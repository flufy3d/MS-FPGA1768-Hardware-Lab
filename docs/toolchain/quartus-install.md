# Installing Quartus Prime Pro 25.1

> Status: verified on this machine (2026-11-17) · Windows 10 x64

## 1. Download / collect the installer

You need three files from the Altera (Intel) download page or your local copy:

```
QuartusProSetup-25.1.0.129-windows.exe     (part 1, ~3.5 GB)
QuartusProSetup-part2-25.1.0.129-windows.qdz (part 2, ~5 GB)
arria10-25.1.0.129.qdz                     (Arria 10 device support, ~8.8 GB)
```

Put them **in the same folder**. The installer picks up the `part2` package automatically
and installs every `*.qdz` device package it finds next to itself. If you keep packages for
other families in that folder they will be installed too; isolate the two or three files you
need in a scratch directory (this repo's lab used `D:\qinstall`).

## 2. Silent install (recommended)

Run from an **elevated** prompt:

```powershell
D:\qinstall\QuartusProSetup-25.1.0.129-windows.exe `
  --mode unattended `
  --unattendedmodeui none `
  --installdir D:\altera_pro\25.1 `
  --accept_eula 1
```

Notes:

- The installer is a BitRock package; `--accept_eula 1` is mandatory for unattended mode.
- It always installs `quartus\`, `quartus\bin64`, `devices\`, and `uninstall\`.
- A full install with Arria 10 takes ~25 GB and 15-40 minutes depending on disk speed.
- The GUI equivalent is the same, just launch the `.exe` and select the Arria 10 device
  package on the component page.

## 3. Verify

```powershell
D:\altera_pro\25.1\quartus\bin64\quartus_sh.exe --version
# Quartus Prime Shell
# Version 25.1.0 Build 129  SJ Pro Edition

D:\altera_pro\25.1\quartus\bin64\quartus_pgm.exe --version
D:\altera_pro\25.1\quartus\bin64\jtagconfig.exe
```

Check that the Arria 10 device database exists:

```powershell
Test-Path D:\altera_pro\25.1\quartus\common\devinfo\arria10
Get-ChildItem D:\altera_pro\25.1\devices\arria10 -ErrorAction SilentlyContinue
```

## 4. Environment

Set these for your user (Quartus' own installer does not always do it):

```powershell
[Environment]::SetEnvironmentVariable('QUARTUS_ROOTDIR','D:\altera_pro\25.1\quartus','User')
$env:Path = "D:\altera_pro\25.1\quartus\bin64;D:\altera_pro\25.1\quartus\bin;$env:Path"
```

Or just use `scripts/env.ps1`, which finds the installation automatically:

```powershell
. .\scripts\env.ps1
```

## 4b. Programmer package (required for `quartus_pgm`)

Recent Quartus releases ship the **Programmer** as a separate package. If only the main
Quartus payload was installed, `quartus_pgm` crashes with:

```
Internal Error: Sub-system: PGMDEV ... device_file:
<install>/devices/programmer/pgm_dev_info.pcf does not exist
```

Install `QuartusProProgrammerSetup-<version>-windows.exe` into the **same** installation
directory:

```powershell
QuartusProProgrammerSetup-25.1.0.129-windows.exe `
  --mode unattended --unattendedmodeui none `
  --installdir D:\altera_pro\25.1 --accept_eula 1
```

On 25.1 this creates a separate tree:

```
D:\altera_pro\25.1\qprogrammer\quartus\bin64\quartus_pgm.exe
D:\altera_pro\25.1\qprogrammer\devices\programmer\pgm_dev_info.pcf
```

Use that `quartus_pgm` (and its `jtagconfig`) with `QUARTUS_ROOTDIR` pointing at
`...\qprogrammer\quartus`. Copy the JTAG plugin into `...\qprogrammer\quartus\bin64` as
well. `scripts/env.ps1` detects this layout and `scripts/program.ps1` switches to it
automatically.

> **Quartus 25.1 also needs the Programmer data for `.sof` assembly.** `quartus_asm`
> loads `devices\programmer\pgm_dev_info.pcf`; without it the assembler dies with the same
> `PGMDEV` internal error. Either install the Programmer into the main tree, or copy the
> folder once:
>
> ```powershell
> Copy-Item D:\altera_pro\25.1\qprogrammer\devices\programmer `
>           D:\altera_pro\25.1\devices\ -Recurse
> ```
>
> After that the normal `quartus_sh --flow compile` produces the `.sof`.

## 5. Optional components

| Installer | Purpose | Needed? |
|-----------|---------|---------|
| `QuartusProProgrammerSetup` | standalone programmer | no — `quartus_pgm` ships with the main install |
| `QuestaSetup` | ModelSim/Questasim simulator | only for RTL simulation |
| `RiscFreeSetup` | Nios V / RISC-V tools | only for soft-core work |
| `DSPBuilderProSetup` | DSP Builder | no |
| `AdvLinkAnalyzerProSetup` | transceiver link analyser | useful for PCIe/QSFP debug |

## Troubleshooting the installer

| Symptom | Fix |
|---------|-----|
| "Another instance is running" | kill `_QuartusProSetup*.exe` and retry |
| Installer refuses to start from a network/removable drive | copy the files to a local disk |
| Only `quartus\` appears, no `devices\` | the `arria10-*.qdz` was not next to the installer |
| Device `10AXF40AA` unknown | Arria 10 package not installed (check `devices\arria10`) |
| `quartus_pgm` cannot find a cable | see [onboard-usb-blaster.md](onboard-usb-blaster.md) |
