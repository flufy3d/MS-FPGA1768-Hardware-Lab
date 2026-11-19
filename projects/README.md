# Projects

Quartus projects maintained in this repository. Each project is self-contained: `.qpf`,
`.qsf`, RTL, constraints, Platform Designer sources, its host profile
(`host/profiles/<project>.ini`, for PCIe designs with the SHELL_ID/CAPS contract) and a
README describing what it proves. There is no shared design library between projects:
reuse happens by copying the closest project as a template (see the *Template* column).

| Project | What it does | Template | Status |
|---------|--------------|----------|--------|
| [01_hello_world](01_hello_world/) | 1 Hz heartbeat + 8-bit seconds counter on the LEDs | bare (LEDs only, no PCIe) | verified on hardware |
| [02_pcie_pio](02_pcie_pio/) | Gen2 x8 PCIe endpoint with a BAR0 compute register (`A + B`) | — | verified on hardware (2026-11-18): BAR0 assigned, `A + B` test passed |
| [03_pcie_gen3](03_pcie_gen3/) | Gen3 x8 PCIe endpoint (64-bit BAR0), `A + B` registers plus a die temperature register | **minimal** (Gen3 x8 + BAR0 PIOs + temperature) | sources verified on hardware (2026-11-18); renamed project not yet compiled or re-tested |
| [04_pcie_hot_update](04_pcie_hot_update/) | Gen3 x8 endpoint whose compute logic (`A + B` / `A − B` persona) is replaced over PCIe by partial reconfiguration, without JTAG and without dropping the link | — | verified on hardware (2026-11-18): persona `A + B` → `A − B` → `A + B` loaded over PCIe in ~8 s each, link Gen3 x8 and BAR0 unchanged |
| [05_ddr4](05_ddr4/) | DDR4 static region: Gen3 x8 PCIe, PR controller, both DDR4 channels (DDR4-2133, 72 bit), read-only flash window, SHELL_ID/CAPS identity block; DDR4 memory tests (walking one + address test, PRBS-31) as PR personas. Named `05_shell` until 2026-11-19 | **full** (PCIe + PR + DDR4 + flash window + host profile) | verified on hardware (2026-11-19, as `05_shell`): both channels calibrated, 2304 MiB each pass, persona swap over PCIe; needs airflow. Renamed build with the CAPS register: built and simulated, not tested on hardware |
| [06_i2c_telemetry](06_i2c_telemetry/) | Gen3 x8 PCIe endpoint with SHELL_ID/CAPS and an I2C master for board buses 1 and 2 (TMP411, LM25066, retimer, EEPROMs), read from the host with `fpga1768 i2c`; PR with the `A + B` / `A − B` personas of 04 | copied from **minimal** (03), PR from 04 | built (both PR revisions, timing met) and simulated (2026-11-19), not tested on hardware |

## Creating a new project

1. Copy the closest template to `projects/NN_name/`: `01_hello_world` for logic without
   PCIe, `03_pcie_gen3` (minimal) for a small PCIe design, `05_ddr4` (full) for a design
   that needs DDR4, PR or the flash window. Do not reference files of another project.
2. Rename the `.qpf`, `.qsf` and top-level entity.
3. Update the README with the purpose and the pins used.
4. Keep build outputs out of git (`db/`, `incremental_db/`, `output_files/`, `*.qws`).
5. PCIe designs: implement the host contract at the start of BAR0 (`0x00` SHELL_ID, unique;
   `0x04` CAPS; `0x08` CAPS2 = 0; see [host/README.md](../host/README.md)) and add
   `host/profiles/NN_name.ini`. `03_pcie_gen3` predates the contract (its `A` register sits
   at `0x00`), so a copy of it must move that register first.

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
