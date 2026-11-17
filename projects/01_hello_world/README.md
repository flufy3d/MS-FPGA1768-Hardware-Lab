# 01 — hello world

Minimal LED blinker for the Microsoft FPGA 1768 / Catapult v3 "Longs Peak" card.

| Item | Value |
|------|-------|
| Top-level entity | `hello_world` |
| Device | `10AXF40AA` (Arria 10) |
| Clock | 100 MHz, pin `AP20` |
| Outputs | `led[8:0]`, 1.8 V |
| Configuration | volatile `.sof` over JTAG |
| Status | **not yet built or programmed** — blocked by licence + JTAG chain (2026-11-17) |

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
| ALMs | not yet compiled (expected < 100 / 427,200) |
| Timing | not yet compiled |
| Bitstream | not yet produced |

## Blockers (2026-11-17)

- `quartus_syn` reports `No license for family Arria 10` on the Pro 25.1 installation.
- The on-board JTAG chain does not respond (`jtagconfig`: "JTAG chain broken"; independent
  MPSSE scan reads TDO stuck high).

No build output or bitstream has been committed for this project.

## Notes

- There is no reset: registers initialise to zero after configuration.
- The design intentionally does not instantiate any IP, so it compiles fast and cannot be
  broken by IP migrations.
- The `.sof` is not committed; rebuild it or take it from the lab log's checksum.
