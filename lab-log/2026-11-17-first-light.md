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

1. Collected the public documentation, pinouts, BOM, datasheets and photos into `hardware/`
   and `reference/`.
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

**Partial.**

- Identification and documentation: done.
- Toolchain: installed, but Arria 10 builds need a licence (owner will add one).
- First bitstream: not built, not loaded.
- JTAG: blocked, root cause not yet isolated.

## Artifacts

- No bitstream was produced.
- Diagnostic scripts: `scripts/jtag_mpsse_idcode.py`, `scripts/jtag_probe_pins.py`,
  `scripts/jtag_bitbang_idcode.py`.
- Boot scan log: `C:\ProgramData\jtag-boot-scan.log`.

## Next session

1. Resolve the Quartus licence (Pro licence or free Standard edition) and build
   `projects/01_hello_world`.
2. Read `C:\ProgramData\jtag-boot-scan.log` after a **cold** boot (full shutdown, not a
   restart) to see whether the TAP answers before configuration.
3. If the TAP never answers: try an external USB-Blaster on J5, then check the 1.8 V JTAG
   bank and the level shifter between U21 and the FPGA.
4. Do **not** write the configuration flash until a backup exists.
