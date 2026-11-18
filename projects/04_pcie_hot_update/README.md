# 04 — PCIe hot update: replace FPGA logic over PCIe with partial reconfiguration

The host loads new logic into the FPGA **over PCIe**, without JTAG, while the PCIe link
stays up and BAR0 keeps its address. The design is the Gen3 x8 endpoint of
[03_pcie_gen3](../03_pcie_gen3/) plus an Arria 10 **partial reconfiguration (PR)** region
and the Partial Reconfiguration Controller IP on BAR0.

| Item | Value |
|------|-------|
| Top-level entity | `pcie_hot_update` |
| Revisions | `pcie_hot_update` (PR base, persona 1) and `pcie_hot_update_sub` (PR implementation, persona 2) |
| Device | `10AXF40AA` (Arria 10) |
| PCIe | #1, Gen3 (8.0 GT/s) x8, Avalon-MM with DMA HIP (DMA unused), same as project 03 |
| BAR0 | 64-bit prefetchable memory, 64 KB |
| Vendor / device ID | `0x1172` / `0xE003` (same Windows test driver as projects 02 and 03, unchanged) |
| Update method | PR bitstream (`.rbf`) written word by word into BAR0 + `0x100` |
| Configuration | base image: volatile `.sof` over JTAG; personas: PR over PCIe. Config flash untouched |
| Status | **verified on hardware 2026-11-18** (PCB `M1003380-005`, Windows host): persona 1 → 2 → 1 over PCIe, link Gen3 x8 and BAR0 unchanged, device OK throughout. Linux host backend: built, not tested on hardware |

## Why partial reconfiguration

Selection made on 2026-11-18 (evidence summarised here; status `reported` unless stated).

| Option | Verdict |
|--------|---------|
| **A. PR over PCIe** (chosen) | PCIe hard IP, register bank and PR controller stay in the static region; only the persona region is rewritten. The link and the config space are not touched by PR. No flash needed: the base image is a volatile `.sof`. Intel's Arria 10 PR-over-PCIe reference designs (AN 784, AN 813) use the same split. |
| B. CvP update mode | **Not available on Arria 10.** Arria 10 supports CvP *initialization* only; Intel directs later core updates to PR over PCIe ([KB 000074842](https://www.intel.com/content/www/us/en/support/programmable/articles/000074842.html)). CvP initialization would also need a periphery image in flash. The card's PCIe #1 does sit on the CvP-capable hard IP (`HSSIGEN3X8PCIEHIP_L0`, bottom left; `verified` from the fitter report of the project 03 build, 2026-11-18). |
| C. Write flash over PCIe, reconfigure | Drops the link (the hard IP is reset), needs a reboot for the 64-bit BAR on the lab host, and writes the flash. Rejected. |

Notes:

- Arria 10 PR is a **Quartus Prime Pro** feature; Quartus Prime Standard does not support
  it, so this project does not build with the Standard edition (AGENTS.md section 7
  "where possible").
- A persona `.rbf` is valid only for the base `.sof` from the **same** base compile. The PR
  controller's bitstream compatibility check is enabled and rejects others (status 3).

## Register map

BAR0, 64 KB. `0x00`–`0x50` are identical to project 03.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `A` | RW | Operand A |
| `0x10` | `B` | RW | Operand B |
| `0x20` | `SUM` | RO | Persona result: `A + B` (persona 1) or `A − B` (persona 2), 32-bit, wraps; `0` while the persona is frozen or in reset |
| `0x30` | `COUNTER` | RO | Free-running 100 MHz counter |
| `0x40` | `ID` | RO | `0x50434945` (the Windows driver only allows writes when it reads this) |
| `0x50` | `TEMP` | RO | Die temperature sensor, same format as project 03 |
| `0x60` | `PERSONA` | RO | `[15:0]` persona ID (`0x0001` add, `0x0002` sub, `0` when frozen); `[16]` PR freeze; `[17]` persona reset; `[18]` PR controller clock PLL locked |
| `0x100` | `PR_DATA` | WO | PR controller data port: one 32-bit word of the `.rbf` per write, little-endian |
| `0x104` | `PR_CSR` | RW | bit 0: write 1 to start PR; bits `[4:2]`: status, see below |
| `0x108` | `PR_VERSION` | RO | `0xAA500003` (PR controller version in Quartus Prime Pro 25.1) |
| `0x10C` | `PR_ID` | RO | PR bitstream ID that the compatibility check expects |
| `0x8000`–`0xFFFF` | scratch RAM | RW | 32 KB, not initialised; sizes BAR0 to 64 KB |

`PR_CSR` status (from the `alt_pr` RTL in Quartus Prime Pro 25.1, status `reported`):

| `[4:2]` | Meaning |
|---------|---------|
| 0 | idle (after reset) |
| 1 | PR error |
| 2 | CRC error |
| 3 | incompatible bitstream (built against another base) |
| 4 | PR in progress (freeze high) |
| 5 | PR succeeded |

## Design

```
                     static region                                       PR region
 PCIe #1 ── Arria 10 HIP (Gen3 x8) ── rxm_bar0 ──┬─ PIO A, B ─────────────────┬──> u_persona
                                                 ├─ PIO SUM <── freeze mux <──┴─── sum
                                                 ├─ PIO PERSONA <── freeze mux <── persona_id
                                                 ├─ PIO COUNTER, ID, TEMP
                                                 ├─ pr_ip (alt_pr, internal host) ── freeze ──> persona reset
                                                 └─ scratch RAM
```

- `pr_ip`: Partial Reconfiguration Controller IP, internal host, Avalon-MM slave, 32-bit
  input, plain data (`CDRATIO 1`), compatibility check on, JTAG debug off. Its `freeze`
  output is high for the whole PR operation.
- `pll_pr`: IOPLL, `clk_100` → **50 MHz** for `pr_ip` only. `alt_pr` launches PR data on
  the falling edge and the PR control block captures it on the next rising edge, a
  half-cycle path. With `pr_ip` on `clk_100` the first build (2026-11-18) missed setup on
  that path by 2.890 ns in the Slow 900mV 100C corner (skew −3.099 ns between the global
  clock and the PR block's gated clock). The PR load rate is limited by the host's
  one-write-per-word MMIO, not by this clock.
- While `freeze` is high and for 511 `clk_100` cycles (5.11 µs) after it falls, the persona is held
  in reset and the static region reads `0` instead of its outputs. Arria 10 PR region
  registers do not start in a known state after PR, so the persona resets every register.
- PR region: `u_persona`, partition `pr_partition`, reserved core-only LogicLock region
  `X120 Y120`–`X139 Y139`, route region `X118 Y118`–`X141 Y141`. The coordinates are a
  lab choice away from the hard IP; they are not a board fact.
- Both personas use only `clk_100`.

## Pins used

Same as project 03; all locations and I/O standards are in `pcie_hot_update.qsf` and,
identically, in `pcie_hot_update_sub.qsf`.

| Signal | Pin(s) | Notes |
|--------|--------|-------|
| `clk_100` | `AP20` | 100 MHz board oscillator: register bank, persona, reference of the 50 MHz PR controller PLL |
| `clk_pcie1` | `AN29` / `AN28` | 100 MHz PCIe #1 reference clock |
| `pcie1_perstn` | `AW16` | PCIe #1 PERST# |
| `pcie1_rx[7:0]`, `pcie1_tx[7:0]` | see `.qsf` | edge connector lanes 0–7 |

## Build

```powershell
. ..\..\scripts\env.ps1
Remove-Item -Recurse -Force ip\pcie_hot_update_sys, pcie_hot_update_sys -ErrorAction SilentlyContinue
& "$env:QUARTUS_ROOTDIR\..\qsys\bin\qsys-script.exe" --script=make_qsys.tcl --quartus-project=pcie_hot_update.qpf
.\build_pr.ps1            # base compile, export static region, implementation compile
```

`qsys-script --quartus-project` adds any new `IP_FILE` line to the project's *current*
revision only. Both `.qsf` files must list the same `IP_FILE`s; check with
`diff pcie_hot_update.qsf pcie_hot_update_sub.qsf` after regenerating.

`build_pr.ps1` stages (`-Stage base|export|impl|all`):

1. `quartus_sh --flow compile pcie_hot_update -c pcie_hot_update` — PR base revision
   (static region + persona 1).
2. `quartus_cdb ... --export_partition root_partition --snapshot final --file
   output_files/pcie_hot_update_static.qdb --include_sdc_entity_in_partition
   --exclude_pr_subblocks` — the placed and routed static region.
3. `quartus_sh --flow compile pcie_hot_update -c pcie_hot_update_sub` — PR implementation
   revision: imports the static region, rebinds `u_persona` to `persona_sub`.

Outputs in `output_files/`:

| File | Use |
|------|-----|
| `pcie_hot_update.sof` | full base image (persona 1), JTAG |
| `pcie_hot_update.pr_partition.rbf` | PR bitstream, persona 1 (`A + B`) |
| `pcie_hot_update_sub.pr_partition.rbf` | PR bitstream, persona 2 (`A − B`) |

Rebuilding the base invalidates every `.rbf` built before it.

## Host tool

The host tool, first written here as `host/pcie_hot_update`, moved on 2026-11-18 to the
shared [`host/`](../../host/) directory at the repository root and is now called
`fpga1768`. Its commands (`info`, `read`, `write`, `temp`, `persona`, `load-pr`,
`selftest`) are unchanged; build, backends and exit codes are in
[host/README.md](../../host/README.md). The hardware results below were obtained with the
tool before the move (Windows backend; Linux backend built, not tested on hardware).

## Program and test

Windows lab host:

```powershell
. ..\..\scripts\env.ps1
quartus_pgm -m jtag -o "p;output_files\pcie_hot_update.sof"   # do not run jtagconfig first
shutdown /r /t 0                                              # warm reboot: the 64-bit BAR is assigned at boot
# after the reboot:
$t = "..\..\host\build\fpga1768.exe"                            # build: ..\..\host\build.ps1
& $t temp                                                       # read the temperature first
& $t info
& $t persona                                                    # persona 1: SUM = A + B
& $t load-pr output_files\pcie_hot_update_sub.pr_partition.rbf  # persona 2: SUM = A - B
& $t load-pr output_files\pcie_hot_update.pr_partition.rbf      # back to persona 1
```

Linux:

```sh
make -C ../../host
sudo ../../host/fpga1768 info
sudo ../../host/fpga1768 load-pr output_files/pcie_hot_update_sub.pr_partition.rbf
```

This is a volatile JTAG load. **Do not write the configuration flash.** A power cycle
restores the factory Microsoft image (`1414:B204`).

## Expected observation

- `persona` after the reboot: `PERSONA id 0x0001`, `SUM 0x23456789` for
  `A = 0x12345678`, `B = 0x11111111`.
- `load-pr …sub…`: status 4 after start, 5 at the end; `Check: BAR0 unchanged, link
  unchanged`; then `PERSONA id 0x0002`, `SUM 0x01234567`.
- `load-pr` back to persona 1: `SUM 0x23456789` again.
- Throughout: no reboot, no JTAG; link stays Gen3 x8, BAR0 address unchanged, Windows
  device status OK (problem code 0).

## If it fails

| Symptom | Likely cause |
|---------|--------------|
| `No PR controller at BAR0 + 0x108` | another bitstream is loaded (project 02/03 or the factory image) |
| status 3 after loading | the `.rbf` was built against a different base compile; rebuild all with `build_pr.ps1` and reload the `.sof` |
| status 1 or 2 | corrupted or wrong-format `.rbf` (compressed/encrypted data with `CDRATIO 1`) |
| status stays 4 | not all words reached the controller; the persona stays frozen, the static region keeps working; reload the `.sof` over JTAG |
| card disappears 20–40 min after power-on | overheating, see the thermal warning in project 03 |

## Thermal warning

Same card, same heatsink as project 03: without a fan the die passed 100 °C 28.5 minutes
after power-on (2026-11-18). Read `TEMP` before and during every test and keep powered time
short until a fan is fitted.

## Resource usage

Base revision `pcie_hot_update`, Quartus Prime Pro 25.1.0 Build 129, 2026-11-18:

| Resource | Used |
|----------|------|
| Logic (ALMs) | 6,924 / 427,200 (2 %) |
| Registers | 14,097 |
| Block memory bits | 540,672 / 55,562,240 (< 1 %) |
| M20K blocks | 36 / 2,713 (1 %) |
| PLLs | 11 / 112 (transceiver PLLs of the hard IP + `pll_pr`) |
| HSSI RX / TX | 8 / 48 each |
| Pins | 36 / 826 |

## Results

### Build (2026-11-18)

| Item | `pcie_hot_update` (base) | `pcie_hot_update_sub` (implementation) |
|------|--------------------------|----------------------------------------|
| Compile | 0 errors, 21m37s | 0 errors, 11m41s (static region imported) |
| Timing | met | met |
| Worst setup slack | `CORE_CLK_OUT` +0.358 ns, `pld_clk` +1.800 ns, `clk_100` +2.987 ns, `pll_pr` 50 MHz +6.031 ns, PR block clock +16.268 ns | same as base |
| PR bitstream ID | `0x05D9EEAA` | `0x05D9EEAA` |

Critical warnings, all also present in the project 03 build and not new: `18326` (clock on
the CLKUSR pin `AP20`, which is the board's 100 MHz oscillator), `17951` / `18655` (40
unused RX / TX transceiver channels).

Bitstreams of this build (not committed; rebuild with `build_pr.ps1`):

| File | Size | SHA-256 |
|------|------|---------|
| `pcie_hot_update.sof` | 36,848,951 | `BD14CF3F8375C1605E98FEA61F26CA2C877E592FDF4B4EF4B19A98091652BED2` |
| `pcie_hot_update.pr_partition.rbf` (persona 1) | 13,120,468 | `E76C1D48AB79DE48916B6C187A2C0140D8F6E98861C440B73E60029DD71CBE8F` |
| `pcie_hot_update_sub.pr_partition.rbf` (persona 2) | 13,189,012 | `653AB52E40147BD9437EEA6524F252A599A916C1D8CDA71BFE82AD5EBEFEA488` |

The PR bitstreams are about 13 MB for a 20 × 20 LAB region. A narrower region would
probably give a smaller `.rbf` (`hypothesis`, not tried).

Build history of this day (failures are kept as data):

1. `pr_ip` on `clk_100`: setup failed by 2.890 ns on the PR controller's half-cycle path
   (see Design). Fixed with the 50 MHz `pll_pr`.
2. `pll_pr` reset tied to the constant system reset: synthesis error "RST_N port on the PLL
   is not properly connected". Fixed with a power-up reset pulse from `pcie_hot_update.sv`.
3. `pll_pr` reference from `AP20`: fitter error 18805 "No dedicated path available for
   refclk signal, clk_100" (`AP20` is the CLKUSR pin, not an IOPLL reference clock pin).
   Fixed with `GLOBAL_SIGNAL GLOBAL_CLOCK` on `clk_100`, so the PLL takes its reference
   from the global clock network.

### Hardware (2026-11-18, PCB `M1003380-005`)

Host: ASUS X99-E (BIOS 1801, Gen3, Above 4G Decoding), `PCIEX16_2`, Windows 10 19045,
`pcie_bar.sys` test driver. No fan. Base `.sof` loaded over JTAG (8m28s at 10 MHz TCK),
then warm reboot; everything below over PCIe only.

| Step | PR status | Load time | Persona | `SUM` for A = `0x12345678`, B = `0x11111111` | Link | BAR0 | Device |
|------|-----------|-----------|---------|------------------------------------------------|------|------|--------|
| after boot | 0 idle | — | `0x0001` | `0x23456789` (A + B) | Gen3 x8 | `0x383FFFE00000` | OK, problem 0 |
| load persona 2 | 4 → **5 SUCCESS** | 8.158 s (1.54 MB/s) | `0x0002` | `0x01234567` (A − B) | Gen3 x8 | unchanged | OK, problem 0 |
| load persona 1 | 4 → **5 SUCCESS** | 7.839 s (1.60 MB/s) | `0x0001` | `0x23456789` (A + B) | Gen3 x8 | unchanged | OK, problem 0 |

- The free-running counter in the static region advanced by exactly the elapsed time
  across both loads: the static region was not reset.
- Load time is set by the host (one driver IOCTL per 32-bit word, about 2.4 µs each).
- Die temperature 83.5–84.9 °C, 18 minutes after power-on, no fan; the loads caused no
  visible step.
- Not yet tested: rejection of an incompatible bitstream (status 3), the Linux backend,
  PR while the host is accessing the persona.

See [lab-log/2026-11-18-pcie-hot-update.md](../../lab-log/2026-11-18-pcie-hot-update.md).

## Attribution

PR flow and the controller protocol follow Intel's Arria 10 PR documentation and the
`alt_pr` IP shipped with Quartus Prime Pro 25.1; no Intel reference-design files are
copied. Board pin assignments come from `hardware/pinouts/csv/`.
