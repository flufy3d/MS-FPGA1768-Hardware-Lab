# 02 — Hello world (LEDs)

> Status: **verified on this card (2026-11-17)** — compiled, programmed over JTAG, LEDs
> observed.

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

## Result of the lab run (2026-11-17)

| Item | Value |
|------|-------|
| Build | 0 errors, 5 warnings, 6m00s |
| Bitstream | `hello_world.sof`, 35,860 KB, Quartus checksum `0x306E0B45` |
| SHA-256 | `B538343AA78C17C1FC160D6A933A2CE55269B07AC8F8C25E717AC051F903CE69` |
| Programming | `quartus_pgm` over the on-board FT232H, 8m58s at 5 MHz TCK |
| Result | `Configuration succeeded`, PCIe endpoint disappeared (no PCIe in this design), LEDs running |
| Timing | setup slack +8.183 ns, hold +0.030 ns, pulse width +4.782 ns |
| Resources | 23 ALMs (0 %), 35 registers, 10 pins |

The first attempt earlier in the day failed because of two unrelated toolchain problems, both
now documented: the Arria 10 licence was missing, and `quartus_pgm`/`quartus_asm` need the
separate Programmer package (`devices\programmer\pgm_dev_info.pcf`).

> If the JTAG scan suddenly returns `0xFFFFFFFF` after a programmer session, power the PC
> off at the PSU and back on. The FT232H latches and a reboot is not enough — see
> [../hardware/jtag.md](../hardware/jtag.md).

## Recording the result

See the lab log for this run:
[lab-log/2026-11-17-first-light.md](../../lab-log/2026-11-17-first-light.md).
