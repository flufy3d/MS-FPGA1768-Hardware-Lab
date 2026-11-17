# 01 — hello world

Minimal LED blinker for the Microsoft FPGA 1768 / Catapult v3 "Longs Peak" card.

| Item | Value |
|------|-------|
| Top-level entity | `hello_world` |
| Device | `10AXF40AA` (Arria 10) |
| Clock | 100 MHz, pin `AP20` |
| Outputs | `led[8:0]`, 1.8 V |
| Configuration | volatile `.sof` over JTAG |
| Status | **verified on hardware (2026-11-17)** |

## Behaviour

- `led[8]`: 1 Hz heartbeat.
- `led[7:0]`: seconds counter in binary, wraps every 256 s.

## Build

```powershell
. ..\..\scripts\env.ps1
.\..\..\scripts\build.ps1 -Project hello_world.qpf
```

Or with Quartus directly:

```powershell
quartus_sh --flow compile hello_world.qpf -c hello_world
```

## Program

```powershell
..\..\scripts\program.ps1 -Sof output_files\hello_world.sof
```

## Files

| File | Purpose |
|------|---------|
| `hello_world.qpf` | project |
| `hello_world.qsf` | device, source files, pin assignments, configuration scheme |
| `hello_world.sv` | RTL |
| `hello_world.sdc` | 100 MHz clock constraint |

## Pin assignments

| Signal | Pin | Standard |
|--------|-----|----------|
| `clk_100` | `AP20` | 1.8 V |
| `led[0]` | `AM17` | 1.8 V |
| `led[1]` | `AH18` | 1.8 V |
| `led[2]` | `AJ18` | 1.8 V |
| `led[3]` | `AH17` | 1.8 V |
| `led[4]` | `AJ16` | 1.8 V |
| `led[5]` | `AK17` | 1.8 V |
| `led[6]` | `AK16` | 1.8 V |
| `led[7]` | `AK18` | 1.8 V |
| `led[8]` | `AL18` | 1.8 V |

## Results

| Metric | Value |
|--------|-------|
| ALMs | 23 / 427,200 (< 1 %) |
| Registers | 35 |
| Pins | 10 / 826 |
| Timing | met (setup +8.183 ns, hold +0.030 ns) |
| Compile time | 6m00s |
| Bitstream | 35,860 KB, Quartus checksum `0x306E0B45` |
| SHA-256 | `B538343AA78C17C1FC160D6A933A2CE55269B07AC8F8C25E717AC051F903CE69` |
| Programming | 8m58s at 5 MHz TCK over the on-board FT232H |

## Notes for the next run

- At the default 10 MHz the download should be roughly twice as fast; 5 MHz was chosen
  because it was the first successful run. The speed is set with
  `<quartus>\bin64\msftdi.cfg` (`frequency=5000000`); delete the file to use the plugin
  default.
- The `.sof` is not committed; rebuild it or check the SHA-256 above.
- If the JTAG scan ever returns `0xFFFFFFFF`, power off at the PSU (not a reboot) — the
  FT232H latches after an aborted programmer session.

## Notes

- There is no reset: registers initialise to zero after configuration.
- The design intentionally does not instantiate any IP, so it compiles fast and cannot be
  broken by IP migrations.
- The `.sof` is not committed; rebuild it or take it from the lab log's checksum.
