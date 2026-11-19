# 06 — I2C telemetry over PCIe (Gen3 x8, board buses 1 and 2)

Reads the board's management devices (temperature sensor, hot-swap controller, retimer,
EEPROMs) from the host through an I2C master in the FPGA. Copied from
[03_pcie_gen3](../03_pcie_gen3/) (the *minimal* template): same PCIe hard IP, 64-bit BAR0
and die temperature register; the `A + B` PIO bank is replaced by one register block that
implements the host contract (SHELL_ID / CAPS) and the I2C master. The partial
reconfiguration controller and the `A + B` / `A − B` personas of
[04_pcie_hot_update](../04_pcie_hot_update/) are added on top, so the host can replace
the persona over PCIe with `fpga1768 load-pr`.

| Item | Value |
|------|-------|
| Top-level entity | `i2c_telemetry` |
| Revisions | `i2c_telemetry` (PR base, persona 1 `A + B`) and `i2c_telemetry_sub` (PR implementation, persona 2 `A − B`) |
| Device | `10AXF40AA` (Arria 10) |
| PCIe | #1, Gen3 (8.0 GT/s) x8, Avalon-MM with DMA (DMA unused), 256-bit |
| BAR0 | 64-bit prefetchable memory, 64 KB; BAR1–BAR5 disabled |
| Vendor / device ID | `0x1172` / `0xE003` (same Windows test driver as projects 02–05) |
| SHELL_ID / CAPS | `0x49323036` ("I206") / `0x00000006` (I2C, PR) |
| Host profile | [host/profiles/06_i2c_telemetry.ini](../../host/profiles/06_i2c_telemetry.ini) |
| PR | PR controller at BAR0 + `0x100`, persona region `u_persona` (as in project 04) |
| Configuration | base image: volatile `.sof` over JTAG; personas: PR over PCIe. Config flash untouched |
| Status | **built and simulated, not tested on hardware** (2026-11-19) |

## Purpose

1. Give the host read access to the board telemetry devices on I2C buses 1 and 2
   ([docs/hardware/i2c.md](../../docs/hardware/i2c.md)) without an external adapter.
2. Verify the reported I2C device map (addresses, which bus) on this card.
3. Compare the FPGA die sensor with the board's TMP411 and read the 12 V input through the
   LM25066 hot-swap controller.

## Register map (BAR0)

All registers are 32-bit, in `bar0_regs.sv`, clocked by `clk_100`.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `SHELL_ID` | RO | `0x49323036` ("I206") — host contract |
| `0x04` | `CAPS` | RO | `0x00000006`: bit 1 = I2C, bit 2 = PR (bit 0 DDR4 and bit 3 flash window absent) |
| `0x08` | `CAPS2` | RO | `0` (reserved) |
| `0x30` | `COUNTER` | RO | free-running 100 MHz counter |
| `0x40` | `ID` | RO | `0x50434945`; the Windows test driver allows writes only when this matches |
| `0x50` | `TEMP` | RO | die temperature sensor, same fields as project 03 |
| `0x60` | `CTRL` | RW | `[0]` start (write 1, self-clearing) `[1]` bus (0 = bus 1, 1 = bus 2) `[2]` rw (1 = read) `[3]` abort (write 1) `[4]` no_reg (no command byte) |
| `0x64` | `ADDR` | RW | `[6:0]` 7-bit device address |
| `0x68` | `PAGE` | RW | `[7:0]` page, `[8]` enable: write `PAGE` to device register `0xFF` first |
| `0x6C` | `REG` | RW | command / register byte |
| `0x70` | `LEN` | RW | `[5:0]` data bytes, 0–28 |
| `0x74`–`0x8F` | `DATA` | RW | 28 bytes, little endian (byte *i* at `0x74 + i`); write data before a write, read data after a read |
| `0x90` | `STATUS` | RO | `[0]` busy `[1]` ack_error (NACK) `[2]` done `[3]` timeout `[4]` aborted `[15:8]` data bytes transferred `[16]` bus 1 SCL `[17]` bus 1 SDA `[18]` bus 2 SCL `[19]` bus 2 SDA (live line levels) |
| `0x94` | `SCL_DIV` | RW | `[15:0]` quarter SCL period in `clk_100` cycles; reset `250` = 100 kHz; values below 25 act as 25 (1 MHz) |
| `0xA0` | `PERSONA` | RO | `[15:0]` persona ID (`0x0001` add, `0x0002` sub, `0` while frozen / in reset); `[16]` PR freeze; `[17]` persona reset; `[18]` PR controller PLL locked |
| `0xA4` | `A` | RW | persona operand A |
| `0xA8` | `B` | RW | persona operand B |
| `0xAC` | `SUM` | RO | persona result: `A + B` (persona 1) or `A − B` (persona 2); `0` while in reset |
| `0x100` | `PR_DATA` | WO | PR controller data port, one `.rbf` word per write |
| `0x104` | `PR_CSR` | RW | bit 0 start; `[4:2]` status (0 idle, 1 PR error, 2 CRC error, 3 incompatible bitstream, 4 in progress, 5 success) |
| `0x108` | `PR_VERSION` | RO | `0xAA500003` (alt_pr, Quartus Prime Pro 25.1) |
| `0x10C` | `PR_ID` | RO | PR bitstream ID expected by the compatibility check |
| `0x8000`–`0xFFFF` | scratch RAM | RW | 32 KB, sizes BAR0 to 64 KB |

Writes to `ADDR`, `PAGE`, `REG`, `LEN`, `DATA` and a start in `CTRL` are ignored while
`busy` is set. Starting a transaction clears `done`, `ack_error`, `timeout`, `aborted` and
the byte count.

`CTRL[4]` (no_reg) and `STATUS[4]`, `STATUS[19:16]` extend the register list of the
original plan: `no_reg` gives a scan that writes nothing; the line levels let the host check
that a bus is pulled up and idle before using it.

## I2C master

`i2c_master.sv`, one state machine shared by both buses; the bus is latched at start and
the other bus is never driven.

| `CTRL` | Sequence on the bus |
|--------|---------------------|
| read (`rw = 1`) | `S addr+W REG Sr addr+R data[0..LEN-1] P` (last byte NACKed) |
| read, `no_reg = 1` | `S addr+R data[0..LEN-1] P` — used by `i2c scan` with `LEN = 1` |
| write (`rw = 0`) | `S addr+W REG data[0..LEN-1] P` (`no_reg = 1`: no `REG` byte) |
| `PAGE[8] = 1` | `S addr+W 0xFF PAGE P` first, then one of the above |

- 7-bit addresses; reads transfer 1–28 bytes (`LEN = 0` is treated as 1).
- A NACK on the address or on any written byte sets `ack_error` and ends with STOP.
- Clock stretching: after releasing SCL the master waits until the line reads high. If SCL
  stays low for 10 ms (`TIMEOUT_CYCLES = 1_000_000`), the transaction ends with `timeout`
  and both lines released.
- Abort releases SDA; if a target still holds SDA low (it was sending a read byte), the
  master clocks one more byte with SDA released and NACKs it (bus clear), then sends STOP.
- Pads are open drain (`pin = oe ? 0 : Z`), inputs go through two-stage synchronisers. No
  internal pull-up is enabled; the board's pull-ups set the high level.

## Partial reconfiguration

Copied from [04_pcie_hot_update](../04_pcie_hot_update/) without functional changes; see
its README for the reasoning.

- `pr_ip` (alt_pr): internal host, Avalon-MM slave at `0x100`, 32-bit plain data
  (`CDRATIO 1`), bitstream compatibility check on, JTAG debug off. Clocked at 50 MHz by
  `pll_pr` (the half-cycle PR data path fails at 100 MHz, project 04).
- While `freeze` is high and for 511 `clk_100` cycles after it falls, `u_persona` is held in
  reset and `PERSONA[15:0]` and `SUM` read `0`.
- PR region: `u_persona`, partition `pr_partition`, reserved core-only LogicLock region
  `X120 Y120`–`X139 Y139`, route region `X118 Y118`–`X141 Y141` (lab choice).
- The persona ABI (`PERSONA`, `A`, `B`, `SUM`) sits at `0xA0`–`0xAC` instead of project
  04's `0x00`–`0x60`, because `0x00`–`0x08` belong to the host contract and `0x60` to the
  I2C master. The host tool reads the offsets from the profile, so `persona` and `load-pr`
  work unchanged.
- The I2C master is in the static region; a PR load does not interrupt it.
- A persona `.rbf` is valid only with the base `.sof` of the same `build_pr.ps1` run.

## Pins used

| Signal | Pin | I/O standard | Notes |
|--------|-----|--------------|-------|
| `clk_100` | `AP20` | 1.8 V | 100 MHz board oscillator |
| `clk_pcie1` | `AN29` / `AN28` | LVDS | PCIe #1 reference clock |
| `pcie1_perstn` | `AW16` | 1.8 V | PCIe #1 PERST# |
| `pcie1_rx[7:0]`, `pcie1_tx[7:0]` | see `.qsf` | HSSI | edge connector lanes 0–7 |
| `i2c1_sda` / `i2c1_scl` | `L20` / `K20` | 1.8 V, open drain | bus 1: retimer U17 `0x22`, QSFP `0x50`, header J10 |
| `i2c2_sda` / `i2c2_scl` | `K21` / `J23` | 1.8 V, open drain | bus 2: `0x40` VR, `0x42` LM25066, `0x4C` TMP411, `0x51` EEPROM, … header J2 |

I2C pins from `hardware/pinouts/csv/fpga_8_I2C.csv` (status `reported`). The CSV shows
level shifters (U44 on bus 1, U45/U39 on bus 2) between the FPGA and the 3.3 V devices; the
FPGA side is assumed to be 1.8 V (status `unknown` until measured — the `STATUS` line bits
show whether the pull-ups are present).

## Host tool

The shared tool in [host/](../../host/) selects the `06_i2c_telemetry` profile by
`SHELL_ID`:

```powershell
host\build.ps1
host\build\fpga1768.exe probe                 # SHELL_ID, CAPS, ID, counter, temp, I2C idle
host\build\fpga1768.exe i2c status            # line levels, SCL rate
host\build\fpga1768.exe i2c scan 2            # one-byte read probe 0x08-0x77, writes nothing
host\build\fpga1768.exe i2c sensors           # TMP411 + LM25066 readings (read only)
host\build\fpga1768.exe i2c read 2 4C 00      # TMP411 local temperature
host\build\fpga1768.exe i2c read 2 42 88 2    # LM25066 READ_VIN (word)
host\build\fpga1768.exe i2c read 1 22 EF 5    # DS250DF810 device ID registers 0xEF-0xF3
host\build\fpga1768.exe i2c read 1 22 FE      # DS250DF810 vendor ID (0x03)
```

The tool has **no generic I2C write command**. The only write it can issue is the page
select of `i2c preg` (register `0xFF`), and only to addresses in `i2c.preg_allow` of the
profile (`0x22`, the retimer). The DS250DF810 ID registers `0xEF`–`0xF3` and `0xFE` are
global registers (datasheet SNLS513C, "Programming"), readable without selecting a page.

## Build

```powershell
. ..\..\scripts\env.ps1
.\build_pr.ps1            # base compile, export static region, implementation compile
```

| File (`output_files/`) | Use |
|------------------------|-----|
| `i2c_telemetry.sof` | full base image (persona 1), JTAG |
| `i2c_telemetry.pr_partition.rbf` | PR bitstream, persona 1 (`A + B`) |
| `i2c_telemetry_sub.pr_partition.rbf` | PR bitstream, persona 2 (`A − B`) |

`qsys-script --quartus-project` adds new `IP_FILE` lines to the current revision only; keep
`i2c_telemetry.qsf` and `i2c_telemetry_sub.qsf` identical apart from the PR block and the
persona source (`diff` them after regenerating).

Regenerate the Platform Designer system (only after editing `make_qsys.tcl`):

```powershell
. ..\..\scripts\env.ps1
Remove-Item -Recurse -Force ip\i2c_sys, i2c_sys   # else save_system writes *_1.ip variants
& "$env:QUARTUS_ROOTDIR\..\qsys\bin\qsys-script.exe" --script=make_qsys.tcl --quartus-project=i2c_telemetry.qpf
quartus_ipgenerate i2c_telemetry -c i2c_telemetry --run_default_mode_op
```

## Simulation

```powershell
. ..\..\scripts\env.ps1
.\sim\run_sim.ps1
```

`sim/tb_i2c.sv` drives `bar0_regs` + `i2c_master` through the Avalon-MM interface (the
same offsets as the host) against behavioural targets (`sim/i2c_slave_model.sv`): a paged
target `0x22` on bus 1, a TMP411-like `0x4C` and an LM25066-like `0x42` that stretches SCL
by 3 µs on bus 2. Covered: identity registers; 100 kHz read; command byte + Sr + 2-byte
read with clock stretching; NACK on a missing address (lines released); scan probe with no
bytes written; paged read; 28-byte read; write path; SCL held low → timeout; abort while the
target drives SDA low → bus clear → next transaction succeeds; bus isolation (the
unselected bus is never driven); the persona ABI registers (`PERSONA`, `A`, `B`, `SUM`
with a stand-in persona). Questa 2024.1, 2026-11-19: `==== PASSED: 0 failure(s)`. The PR
controller and the personas themselves are not simulated (same IP and RTL as project 04,
verified there on hardware).

## Program and test

```powershell
. ..\..\scripts\env.ps1
quartus_pgm -m jtag -o "p;output_files\i2c_telemetry.sof"   # about 9 minutes at 5 MHz TCK
shutdown /r /t 0                                            # warm reboot: 64-bit BAR0 assignment
# after the reboot:
host\build\fpga1768.exe probe
host\build\fpga1768.exe i2c scan 2
host\build\fpga1768.exe i2c sensors
host\build\fpga1768.exe persona                                                     # A + B
host\build\fpga1768.exe load-pr output_files\i2c_telemetry_sub.pr_partition.rbf    # A - B
host\build\fpga1768.exe load-pr output_files\i2c_telemetry.pr_partition.rbf        # back to A + B
host\build\fpga1768.exe i2c sensors                                                 # I2C unaffected by PR
```

Volatile load only. **Do not write the configuration flash** (it holds the 05 image the
card boots from). A power cycle returns to that image.

## Expected observation

- `probe`: `SHELL_ID 0x49323036`, `CAPS 0x00000006 (I2C PR)`, profile `06_i2c_telemetry`,
  Gen3 x8, PR version `0xAA500003`, persona `0x0001` with the PR PLL locked, I2C idle with
  all four lines high.
- `persona`: `SUM 0x23456789`; after `load-pr …sub…`: status 5, link and BAR0 unchanged,
  persona `0x0002`, `SUM 0x01234567`.
- `i2c scan 2`: at least `0x40`, `0x42`, `0x4C`, `0x51` (reported map; `0x1F`/`0x48` NIC,
  `0x27` GPIO expander and `0x6D` clock buffer may also answer).
- `i2c scan 1`: `0x22` (retimer); `0x50` only with a QSFP module inserted.
- TMP411 local temperature plausible (below the FPGA die temperature, above ambient).
- LM25066 `READ_VIN` between 11 and 13 V.
- A read of an absent address returns NACK (exit code 4) and the next command still works.

## If it fails

| Symptom | Likely cause |
|---------|--------------|
| `probe` finds the `legacy` profile or another SHELL_ID | the `.sof` did not load, or no warm reboot after loading |
| `STATUS` line bits read 0 for a bus | no pull-up on the FPGA side, or a target holds the line; do not scan, measure first |
| every address NACKs | wrong bus, level shifter disabled, or pins wrong (status `reported` in the CSV) |
| `timeout` | a target stretches SCL > 10 ms or holds it low; try `i2c speed 50` then re-check lines |
| retimer `0x22` absent on bus 1 | the retimer may be held in reset or unpowered by the factory flow; record it |

## Thermal warning

Same as every PCIe design on this card: without airflow the die reached 130 °C and the card
lost power (project 05, 2026-11-19). Keep a fan on it; `fpga1768 temp 5` and
`i2c sensors` report the die and board temperatures.

## Results

PR build of 2026-11-19 (`build_pr.ps1`), Quartus Prime Pro 25.1.0 Build 129 patch 0.36:

| Metric | `i2c_telemetry` (base) | `i2c_telemetry_sub` (implementation) |
|--------|------------------------|--------------------------------------|
| Compile | 0 errors | 0 errors, 11m04s |
| Timing | **met** | **met** |
| Worst slack (all corners) | setup +0.365 ns, hold +0.014 ns | setup +0.365 ns, hold +0.014 ns |
| Logic | 6,954 ALMs (2 %), 13,378 registers | 9,445 ALMs (2 %) |

Fmax (base, Slow 900mV 100C): `clk_100` 157.26 MHz, PR controller clock (50 MHz) 117.07
MHz, PCIe core clock 275.1 MHz.

| File | Bytes | SHA-256 |
|------|-------|---------|
| `i2c_telemetry.sof` | 36,798,658 | `E71229EB8889136ED42EFE3BB2603322712C78CFCA7A37C9E551DFFD56821F98` |
| `i2c_telemetry.pr_partition.rbf` | 7,844,108 | `A2F016B875D7D6AE8C4F0DABF1D9F60C402423F29B7140C66249F24A70EF7A9F` |
| `i2c_telemetry_sub.pr_partition.rbf` | 7,844,208 | `B01F2FB69EBC7B0C293D9066779C51871F3A6E4F7877310B81C2835D0CB26F86` |

Critical warnings: `18326` (CLKUSR on `AP20`, as in every project) and `17951` / `18655`
(40 unused transceiver channels; PCIe uses 8 of 48), the same set as projects 04 and 05.
The first PR build failed with fitter error `18805` because the `.qsf` lacked
`GLOBAL_SIGNAL GLOBAL_CLOCK` on `clk_100` (needed once an IOPLL takes it as reference;
see project 04); added to both revisions.

Not tested on hardware.

First build of 2026-11-19 (I2C only, before PR was added; superseded by the PR build),
Quartus Prime Pro 25.1.0 Build 129 patch 0.36:

| Metric | Value |
|--------|-------|
| Compile | 0 errors, 18m43s on the lab machine |
| Timing | **met**; worst setup slack +0.410 ns, hold +0.016 ns (all corners) |
| `clk_100` | Fmax 172.15 MHz (Slow 900mV 100C), setup slack +4.191 ns |
| PCIe core clock | Fmax 278.55 MHz |
| Logic | 6,632 ALMs of 427,200 (2 %), 12,864 registers |
| Block memory | 540,928 bits (< 1 %) |
| I2C pads | four tri-state buffers converted to open drain by synthesis; `J23`, `K20`, `K21`, `L20`, 1.8 V, bank 2L |
| `.sof` SHA-256 | `97DD0CE79A50E70834B86D879583414B4D689F563E84A80CF91313CFD8F2619D` |
| Hardware | not tested |

Critical warnings: CLKUSR on `AP20` (as in every project here, `clk_100` is a 100 MHz
clock) and "Missing drive strength and slew rate" for the four I2C pins (fixed afterwards:
8 mA, slow slew).

## Open items

- Bus 3 (NIC management) is not wired to the FPGA in this design.
- The personas are the `A + B` / `A − B` demo of project 04; they do not use the I2C
  master.

## Attribution

Pin assignments come from `hardware/pinouts/csv/` in this repository. Device register
addresses come from the vendor datasheets under `hardware/datasheets/` (TMP411, LM25066
Table 41, DS250DF810). The PCIe HIP parameterisation is the one of project 03.
