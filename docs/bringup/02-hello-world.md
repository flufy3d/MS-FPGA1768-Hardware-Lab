# 02 — Hello world (LEDs)

> Status: **blocked** on this card (2026-11-17) — design written, compile blocked by the
> Quartus Pro licence, JTAG chain not responding. See "Current blocker" at the end.

## Goal

Load a design built from scratch in this repository and observe it running. This proves the
whole chain: Quartus → JTAG plugin → FPGA configuration → pin constraints → clock.

The design is `projects/01_hello_world`:

- `led[8]` — 1 Hz heartbeat (0.5 s on, 0.5 s off)
- `led[7:0]` — 8-bit counter, one step per second (wraps every 256 s)
- Clock — 100 MHz oscillator U59 on pin `AP20`
- **Volatile only** — the configuration flash is not touched

## Build

```powershell
. .\scripts\env.ps1
.\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf
```

The first compile of an Arria 10 project takes a few minutes (synthesis, fitter, timing).

Expected tail of the log:

```
Info: Quartus Prime Shell was successful. 0 errors, ...
```

Check the timing report:

```powershell
Select-String -Path projects\01_hello_world\output_files\hello_world.sta.rpt `
              -Pattern 'Timing requirements'
```

## Program

```powershell
jtagconfig
# 1) Microsoft Catapult v3 (64) [USB-0]
#  02E060DD   10AX115

.\scripts\program.ps1 -Sof projects\01_hello_world\output_files\hello_world.sof
```

`quartus_pgm` prints a progress percentage and finishes with:

```
Info: Configuration succeeded -- 1 device(s) configured
```

## What you should see

Two LEDs near the card bracket are active:

- one LED blinking at 1 Hz (on for half a second, off for half a second),
- a group of eight LEDs counting in binary, changing once per second.

The binary counter is the useful part: any doubt about the clock frequency can be resolved
by timing how long it takes to wrap (256 s).

## What this proves

| Layer | Proof |
|-------|-------|
| Power | FPGA configures at all |
| JTAG | `jtagconfig` sees the TAP, download completes |
| Configuration | The FPGA accepts the `.sof` |
| Clock | LED toggles at the expected rate |
| Pin constraints | Correct LEDs light, no smoke |
| Toolchain | Quartus 25.1 + Arria 10 package + plugin all work |

## If it fails

| Symptom | Check |
|---------|-------|
| `quartus_pgm` cannot find a cable | [onboard-usb-blaster.md](../toolchain/onboard-usb-blaster.md) |
| Download succeeds, no LED | Wrong board revision? Check `led[8]` pin `AL18`; scope the pin |
| LEDs all on | Design not configured, bank pulled up — verify the `.sof` was loaded |
| Blink rate 2× or 0.5× | Clock is 50 MHz or 200 MHz — check which oscillator you constrained |
| Counter advances unevenly | Normal; the eye cannot integrate 1 Hz precisely |

## Returning to the factory image

Power-cycle the PC (or the card). Configuration is volatile, so the FPGA reloads the image
from the QSPI flash and the card returns to its as-found state (`1414:B204` on PCIe).
No recovery step is needed as long as you never wrote the flash.

## Current blocker (2026-11-17)

Two independent problems prevented the first download on the lab card:

1. **Licence.** `quartus_syn` stops with
   `Error (19286): No license for family Arria 10`.
   A valid Quartus Pro licence (or the free Quartus Prime Standard edition) is required.
2. **JTAG.** `jtagconfig` finds the on-board cable but reports
   `Unable to read device chain - JTAG chain broken`. An independent MPSSE scan
   (`scripts/jtag_mpsse_idcode.py`) reads `0xFFFFFFFF` on TDO at 100 kHz – 2 MHz,
   i.e. the FPGA does not drive TDO at all.

The design itself is intentionally trivial and is expected to compile and run once the two
blockers are resolved. Nothing has been written to the configuration flash, so the card
still boots its factory image.

## Recording the result

See the lab log for this run:
[lab-log/2026-11-17-first-light.md](../../lab-log/2026-11-17-first-light.md).
