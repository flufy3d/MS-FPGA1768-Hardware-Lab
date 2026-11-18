# Projects

Quartus projects maintained in this repository. Each project is self-contained: `.qpf`,
`.qsf`, RTL, constraints, and a README describing what it proves.

| Project | What it does | Status |
|---------|--------------|--------|
| [01_hello_world](01_hello_world/) | 1 Hz heartbeat + 8-bit seconds counter on the LEDs | verified on hardware |
| [02_pcie_pio](02_pcie_pio/) | Gen2 x8 PCIe endpoint with a BAR0 compute register (`A + B`) | verified on hardware (2026-11-18): BAR0 assigned, `A + B` test passed |
| 03_ddr4_dual | both DDR4 channels with calibration status | planned (start from the upstream DDR4_Dual project) |

## Creating a new project

1. Copy `01_hello_world` to `projects/NN_name/`.
2. Rename the `.qpf`, `.qsf` and top-level entity.
3. Update the README with the purpose and the pins used.
4. Keep build outputs out of git (`db/`, `incremental_db/`, `output_files/`, `*.qws`).

## Conventions

- Top-level entity name = project name (`hello_world`).
- One clock per design where possible; use a PLL for derived clocks.
- All user I/O gets an explicit pin assignment and I/O standard in the `.qsf`.
- Timing constraints in `.sdc`, not in the `.qsf`.
- No generated IP without the source `.qsys`/`.ip` file committed alongside.

## Build outputs

`output_files/*.sof` is intentionally **not** committed — it is large and reproducible. If
you need a known-good bitstream for recovery, put it under `firmware/prebuilt/` and record
its SHA-256 in the README.
