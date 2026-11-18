# 2026-11-18 — Logic replaced over PCIe by partial reconfiguration (project 04)

- **Date:** 2026-11-18
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99-E, BIOS 1801, PCIe link speed **Gen3**, Above 4G Decoding enabled;
  card in `PCIEX16_2` (x8); Windows 10 Pro 19045, Secure Boot off, test signing on.
  Card cooling: passive server copper heatsink, **no fan**. Card power: PCIe slot only.
- **Toolchain:** Quartus Prime Pro 25.1.0 Build 129; JTAG plugin
  `jtag_hw_microsoft_catapult.dll`, `msftdi.cfg` **10 MHz** (first use); test driver
  `pcie_bar.sys` from `projects/02_pcie_pio/driver` (unchanged); host tool
  `projects/04_pcie_hot_update/host` (C, Windows backend, MSYS2 gcc 15.2.0)
- **Goal:** load new logic into the FPGA over PCIe, without JTAG, while the PCIe link stays
  up: persona 1 (`SUM = A + B`) → persona 2 (`SUM = A − B`) → persona 1, with the link
  speed, BAR0 address and Windows device state unchanged, and the die temperature logged.

## What was done

1. Selected Arria 10 partial reconfiguration (PR) over PCIe; CvP update does not exist on
   Arria 10 (see the project README, "Why partial reconfiguration").
2. Built `projects/04_pcie_hot_update` (PR base `pcie_hot_update` + PR implementation
   `pcie_hot_update_sub`). Three failed builds first, all kept in the project README:
   PR controller half-cycle path failing setup at 100 MHz (fixed with a 50 MHz PLL), PLL
   reset tied to a constant, PLL reference on the CLKUSR pin without a dedicated path
   (fixed with `GLOBAL_SIGNAL GLOBAL_CLOCK`). The fourth build: 0 errors, timing met.
3. 23:05:52 — AC power cycle; Windows booted (the card was absent before: FT232H not
   present at 21:14). Factory image `1414:B204` and the FT232H present.
4. 23:10:46–23:19:15 — programmed `pcie_hot_update.sof` with `quartus_pgm` directly (no
   `jtagconfig` before it): `rc=0`, **8m28s at 10 MHz TCK**.
5. Warm reboot by the script 15 s later; Windows up at 23:20:20.
6. 23:23:38–23:24:11 — `E:\Projects\fpga1768-hotupdate\2_hw_test.ps1`: temperature logger
   every 5 s; `temp`, `info`, `persona`; `load-pr` persona 2; `load-pr` persona 1; `info`.
   PnP state, link and BAR0 recorded before and after every load.
7. The card was left powered at the end of the test; powering it off was left to the
   operator.

## Observations

### Before any PR (persona 1 from the base `.sof`)

| Property | Value |
|----------|-------|
| PnP | `PCI\VEN_1172&DEV_E003...\4&2A43D483&0&0010`, status OK, problem 0 |
| Link | Gen3 x8 |
| BAR0 | `0x383FFFE00000`, length `0x10000` |
| `ID` | `0x50434945` |
| `PERSONA` | `0x00040001`: persona 1, freeze 0, reset 0, PR clock PLL locked |
| `PR_CSR` | `0x00000000` (status 0, idle) |
| `PR_VERSION` / `PR_ID` | `0xAA500003` / `0x05D9EEAA` (matches the assembler's "PR bitstream ID") |
| Persona test | `A = 0x12345678`, `B = 0x11111111` → `SUM 0x23456789` (A + B), passed |

### PR loads over PCIe

| Load | File (SHA-256) | Words | Status after start / at end | Data time | Rate | Persona after | `SUM` after | Test |
|------|----------------|-------|-----------------------------|-----------|------|---------------|-------------|------|
| 1 → 2 | `pcie_hot_update_sub.pr_partition.rbf` (`653AB52E…EFEA488`) | 3,297,253 | 4 / **5 SUCCESS** | 8.158 s | 1.54 MB/s | `0x0002` | `0x01234567` (A − B) | passed |
| 2 → 1 | `pcie_hot_update.pr_partition.rbf` (`E76C1D48…71CBE8F`) | 3,280,117 | 4 / **5 SUCCESS** | 7.839 s | 1.60 MB/s | `0x0001` | `0x23456789` (A + B) | passed |

After each load the tool compared the state before and after: `BAR0 unchanged, link
unchanged, ID 0x50434945`.

| PnP check | Status | Problem | Link | FT232H |
|-----------|--------|---------|------|--------|
| start | OK | 0 | Gen3 x8 | present |
| before PR 1 → 2 | OK | 0 | Gen3 x8 | present |
| after PR 1 → 2 | OK | 0 | Gen3 x8 | present |
| after PR 2 → 1 | OK | 0 | Gen3 x8 | present |

- `COUNTER` (static region, 100 MHz) read `0x68D5F451` at 23:23:49 and `0xE9F2FE06` at
  23:24:11: a difference of 2,166,163,893 cycles = 21.66 s, matching the ~22 s between
  the two reads. The static region was not reset by either load.
- The data rate is set by the host: one `IOCTL_PCIE_BAR_WRITE32` per 32-bit word, about
  2.4 µs per word. The status left `IN_PROGRESS` before the first status poll after the
  last word, so the PR controller consumed the data as fast as it arrived.
- `freeze` = 1 during a load was **not observed directly**; the tool reads `PERSONA` only
  before and after. The status sequence 0 → 4 → 5 matches the `alt_pr` RTL.

### Die temperature, no fan

Power-on 23:05:52 (Windows boot time, ±1 min). Vendor formula, status `reported`.

| Time | Minutes after power-on | Code | Die temperature |
|------|------------------------|------|-----------------|
| 23:23:49 | 18.0 | 515 | 83.5 °C |
| 23:23:59 (after load 1 → 2) | 18.1 | 516 | 84.2 °C |
| 23:24:09 (after load 2 → 1) | 18.3 | 516 | 84.2 °C |
| 23:24:11 | 18.3 | 517 | 84.9 °C |

Consistent with the 2026-11-18 curve of project 03 (86.2 °C at 19 min). The two loads
caused no visible step beyond the steady rise.

### JTAG programming at 10 MHz

`msftdi.cfg` `frequency=10000000`: 8m28s for the 36.8 MB `.sof`, against 8m59s at 5 MHz
earlier the same day. Doubling TCK saved only about 30 s, so TCK is not the main limit of
the on-board programmer. The earlier projection "~4–5 min at 10 MHz" in
`docs/toolchain/build-and-program.md` is superseded by this measurement.

## Result

**Success.** The FPGA logic was replaced over PCIe twice (A + B → A − B → A + B) by partial
reconfiguration, without JTAG and without a reboot. The PCIe link stayed Gen3 x8, BAR0
kept its address, and the Windows device stayed OK (problem code 0) throughout.

Not tested in this run:

- rejection of a bitstream built against another base (status 3);
- the Linux backend of the host tool;
- a PR load while the host accesses the persona registers.

## Artifacts

- Bitstreams (built 2026-11-18, not committed; SHA-256 also in the project README):
  - `pcie_hot_update.sof` `BD14CF3F8375C1605E98FEA61F26CA2C877E592FDF4B4EF4B19A98091652BED2`
  - `pcie_hot_update.pr_partition.rbf` `E76C1D48AB79DE48916B6C187A2C0140D8F6E98861C440B73E60029DD71CBE8F`
  - `pcie_hot_update_sub.pr_partition.rbf` `653AB52E40147BD9437EEA6524F252A599A916C1D8CDA71BFE82AD5EBEFEA488`
- Logs and test scripts (lab host, not committed): `E:\Projects\fpga1768-hotupdate\`
  `program_20261118_231001.log`, `hw_test_20261118_232338.log`,
  `temp_20261118_232338.log`, `1_program_and_reboot.ps1`, `2_hw_test.ps1`.

## Addendum (2026-11-19): the card dropped after the test

The card was left powered after the test (see step 7). At 23:59 on 2026-11-18, about
54 minutes after the 23:05:52 power-on, BAR0 reads returned `0xFFFFFFFF` (`TEMP` and `ID`)
and the FT232H (`USB\VID_0403&PID_6014`) was no longer present, while Windows still listed
`PCI\VEN_1172&DEV_E003` with status OK (a stale entry). The time of the drop between
23:24 and 23:59 is not known. This matches the thermal power-off seen on the same day
without a fan (36 minutes after power-on in an earlier run). Recovery needs an AC power
cycle. Lesson: do not leave the card powered without airflow after a test.
