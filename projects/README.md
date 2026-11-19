# Projects

Quartus projects maintained in this repository. Each project is self-contained: `.qpf`,
`.qsf`, RTL, constraints, and a README describing what it proves.

| Project | What it does | Status |
|---------|--------------|--------|
| [01_hello_world](01_hello_world/) | 1 Hz heartbeat + 8-bit seconds counter on the LEDs | verified on hardware |
| [02_pcie_pio](02_pcie_pio/) | Gen2 x8 PCIe endpoint with a BAR0 compute register (`A + B`) | verified on hardware (2026-11-18): BAR0 assigned, `A + B` test passed |
| [03_pcie_gen3](03_pcie_gen3/) | Gen3 x8 PCIe endpoint (64-bit BAR0), `A + B` registers plus a die temperature register | sources verified on hardware (2026-11-18); renamed project not yet compiled or re-tested |
| [04_pcie_hot_update](04_pcie_hot_update/) | Gen3 x8 endpoint whose compute logic (`A + B` / `A − B` persona) is replaced over PCIe by partial reconfiguration, without JTAG and without dropping the link | verified on hardware (2026-11-18): persona `A + B` → `A − B` → `A + B` loaded over PCIe in ~8 s each, link Gen3 x8 and BAR0 unchanged |
| [05_shell](05_shell/) | Reusable static region: Gen3 x8 PCIe, PR controller, both DDR4 channels (DDR4-2133, 72 bit), read-only flash window; DDR4 memory tests (walking one + address test, PRBS-31) as PR personas | verified on hardware (2026-11-19): both channels calibrated, 2304 MiB each pass, persona swap over PCIe; needs airflow |

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
