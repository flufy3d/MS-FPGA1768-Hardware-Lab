# 2026-11-17 — First light attempt

- **Date:** 2026-11-17
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`, no serial label
- **Host:** ASUS X99 board (i7-5820K), Windows 10 x64 19045, card in a CPU PCIe slot (bus 02:00.0)
- **Toolchain:** Quartus Prime Pro 25.1.0.129 + Arria 10 device package, installed to `D:\altera_pro\25.1`
- **Goal:** identify the card, set up the toolchain, load a first LED design over JTAG

## As found

```
PCI   1414:B204  subsys 0400:1414  class 0xFF0000 (unclassified)  rev 00
      bus 2, dev 0, fn 0
      LnkCap 8 GT/s x8, LnkSta 5 GT/s x8, payload 128 B
      Windows problem code 28 (no driver) — expected for vendor 1414
USB   0403:6014  FTDI FT232H, driver FTDIBUS, port #5
```

The card arrived with a Microsoft bitstream in flash that already enumerates over PCIe. The
configuration flash was **not** touched during this session.

## What was done

1. Collected the public documentation, pinouts, BOM, datasheets and photos into `hardware/`.
2. Installed Quartus Prime Pro 25.1 to `D:\altera_pro\25.1` (not the system drive). The
   official installer hung in the SYSTEM session after unpacking the toolchain, so the
   Arria 10 device package (`arria10-25.1.0.129.qdz`) was extracted into the install tree
   manually. `quartus_sh --version` and all tools work.
3. Copied `jtag_hw_microsoft_catapult.dll` into `quartus\bin64\`.
4. Ran `jtagconfig`: cable enumerated, chain not readable.
5. Wrote an independent FTDI D2XX/MPSSE IDCODE scanner to rule out the Quartus plugin.
6. Wrote the hello-world project (`projects/01_hello_world`) and attempted a build.

## Observations

### Toolchain

```
> quartus_sh --version
Quartus Prime Shell
Version 25.1.0 Build 129 03/26/2025 SC Pro Edition
```

`devices\20nm` contains 1872 files (Arria 10 database present).

### Build

```
Error (19286): No license for family Arria 10, for self-service licensing visit ...
Error: Failed to elaborate design: Fail to setup design for synthesis elaboration
```

Arria 10 synthesis in the Pro edition requires a licence. No licence is installed on this
machine. No crack was applied.

### JTAG

```
> jtagconfig
1) Microsoft Catapult (64) [USB-0]
   Unable to read device chain - JTAG chain broken
```

Independent scan, with the Quartus plugin and jtagd completely out of the picture:

```
> python scripts\jtag_mpsse_idcode.py --speed 500000
TCK=500000 Hz divisor=59 raw=ffffffff
IDCODE=0xFFFFFFFF
NO RESPONSE: TDO stuck (no JTAG TAP driving the line)
```

Tested:

- TCK from 100 kHz to 2 MHz.
- All six TCK/TDI/TMS permutations on ADBUS0/1/3.
- MPSSE loopback self-test passes (`0xAA55` echoed), so the FT232H and the D2XX path work.
- FTDI EEPROM reports `EEPROM_NOT_PROGRAMMED` (blank), i.e. the FT232H uses default pins.

Interpretation: the FPGA does not drive TDO. Either the running Microsoft bitstream disables
the JTAG TAP (JTAG secure mode), or the FT232H → FPGA JTAG path is damaged / disabled. The
card's PCIe endpoint continues to work normally throughout.

### Boot-time scan

A scheduled task `JtagBootScan` (SYSTEM, AtStartup) runs `scripts/jtag_mpsse_idcode.py` in a
loop for five minutes at every boot and writes to `C:\ProgramData\jtag-boot-scan.log`.
Purpose: catch the TAP in the window between power-up and configuration.

## Result

**Success.**

The hello-world design was compiled, loaded over JTAG and observed running on the card.

| Item | Value |
|------|-------|
| Build | Quartus Prime Pro 25.1.0.129, 0 errors, 6m00s |
| Bitstream | `hello_world.sof`, 35,860 KB, Quartus checksum `0x306E0B45` |
| SHA-256 | `B538343AA78C17C1FC160D6A933A2CE55269B07AC8F8C25E717AC051F903CE69` |
| Timing | setup +8.183 ns, hold +0.030 ns, pulse width +4.782 ns (met) |
| Resources | 23 ALMs, 35 registers, 10 pins |
| Download | `quartus_pgm` over the on-board FT232H, `Configuration succeeded`, 8m58s at 5 MHz TCK |
| Observation | `led[8]` 1 Hz heartbeat, `led[7:0]` binary seconds counter |
| Side effect | the `1414:B204` PCIe endpoint disappears (the design has no PCIe) until the next power cycle |

The configuration flash was **not** written. A power cycle restores the factory Microsoft
image.

### What actually blocked us (and what fixed it)

1. **Missing Arria 10 licence.** The owner installed the licence; `quartus_syn` then ran.
2. **Missing Programmer package.** Quartus 25.1 ships the Programmer separately. Without
   `devices\programmer\pgm_dev_info.pcf`, both `quartus_pgm` and `quartus_asm` die with a
   `PGMDEV` internal error and a `.sof` is never produced. Installed
   `QuartusProProgrammerSetup` and copied its device data into the main tree.
3. **JTAG reads `0xFFFFFFFF`.** Not a locked or damaged TAP: the FT232H latches after a
   crashed programmer run and stops passing TDO. Only removing AC power (VBUS) clears it —
   a Windows reboot, `FT_CyclePort` and a PnP restart all fail. After a true cold start the
   same tools read `02E060DD` immediately.

### Addendum — boot-time scan result

The scheduled task `JtagBootScan` ran on a cold boot:

```
LastBootUpTime : 14:48:58
task start     : 14:49:17   (19 s after power-on)
FTDI present   : 14:49:18
attempts       : 1248 in 5 minutes, all rc=3 (TDO stuck)
```

Inconclusive by construction: Windows does not run the task until ~19 s after power-on,
while the FPGA loads its bitstream from flash in well under a second. Hammering
`FT_Open`/`FT_Close` four times per second also crashed the FTDI D2XX driver; the task is
now disabled and rate-limited.

### Addendum — ADBUS4-7 experiment (do not repeat blindly)

Driving the FT232H pins ADBUS4-7 as 3.3 V outputs (`scripts/jtag_gpio_probe.py`) took the
card off the PCIe bus when pattern `0b0000` was applied. It did not come back on release;
a full power cycle was required. At least one of those pins is connected to an FPGA
configuration or power signal. Do not drive them without knowing the net.

## Artifacts

- `projects/01_hello_world/output_files/hello_world.sof` (not committed), SHA-256 above
- `projects/01_hello_world/output_files/hello_world.fit.rpt`, `.sta.rpt`, `.map.rpt`
- Diagnostic scripts: `scripts/jtag_mpsse_idcode.py`, `scripts/ftdi_cycle.py`,
  `scripts/jtag_gpio_probe.py`, `scripts/jtag_config_probe.py`,
  `scripts/jtag_config_hold.py`
- Boot scan log: `C:\ProgramData\jtag-boot-scan.log`

## Next session

1. Back up the configuration flash before writing anything (see
   `docs/toolchain/build-and-program.md`).
2. Bring up the PCIe PIO design from the upstream `PCIe1` project and check BAR access.
3. Try the QSFP retimer I2C scan on bus #1 (0x22 and 0x50).
4. Add a project template that includes the Programmer-package workaround and the cold-start
   checklist, so the next person does not repeat today's detours.
