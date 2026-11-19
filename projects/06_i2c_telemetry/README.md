# 06 — I2C telemetry over PCIe (Gen3 x8, board buses 1 and 2)

Reads the board's management devices (temperature sensor, hot-swap controller, retimer,
EEPROMs) from the host through an I2C master in the FPGA. Copied from
[03_pcie_gen3](../03_pcie_gen3/) (the *minimal* template): same PCIe hard IP, 64-bit BAR0
and die temperature register; the `A + B` PIO bank is replaced by one register block that
implements the host contract (SHELL_ID / CAPS) and the I2C master.

| Item | Value |
|------|-------|
| Top-level entity | `i2c_telemetry` |
| Device | `10AXF40AA` (Arria 10) |
| PCIe | #1, Gen3 (8.0 GT/s) x8, Avalon-MM with DMA (DMA unused), 256-bit |
| BAR0 | 64-bit prefetchable memory, 64 KB; BAR1–BAR5 disabled |
| Vendor / device ID | `0x1172` / `0xE003` (same Windows test driver as projects 02–05) |
| SHELL_ID / CAPS | `0x49323036` ("I206") / `0x00000002` (I2C) |
| Host profile | [host/profiles/06_i2c_telemetry.ini](../../host/profiles/06_i2c_telemetry.ini) |
| PR | **not included yet** (no PR controller, no persona); see "Open items" |
| Configuration | volatile `.sof` over JTAG, config flash untouched |
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
| `0x04` | `CAPS` | RO | `0x00000002`: bit 1 = I2C (bit 0 DDR4, bit 2 PR, bit 3 flash window absent) |
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
..\..\scripts\build.ps1 -Project i2c_telemetry.qpf
```

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
unselected bus is never driven). Questa 2024.1, 2026-11-19: `==== PASSED: 0 failure(s)`.

## Program and test

```powershell
. ..\..\scripts\env.ps1
quartus_pgm -m jtag -o "p;output_files\i2c_telemetry.sof"   # about 9 minutes at 5 MHz TCK
shutdown /r /t 0                                            # warm reboot: 64-bit BAR0 assignment
# after the reboot:
host\build\fpga1768.exe probe
host\build\fpga1768.exe i2c scan 2
host\build\fpga1768.exe i2c sensors
```

Volatile load only. **Do not write the configuration flash** (it holds the 05 image the
card boots from). A power cycle returns to that image.

## Expected observation

- `probe`: `SHELL_ID 0x49323036`, `CAPS 0x00000002 (I2C)`, profile `06_i2c_telemetry`,
  Gen3 x8, I2C idle with all four lines high.
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

Build of 2026-11-19 (I2C only, no PR), Quartus Prime Pro 25.1.0 Build 129 patch 0.36:

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
clock) and "Missing drive strength and slew rate" for the four I2C pins (the `.qsf` sets
only location and I/O standard).

## Open items

- **PR not included yet.** The project rules ask every new project to carry a PR controller,
  a persona ABI and a host `load-pr` path; this first version is the I2C bring-up only.
  Adding them means copying the PR controller and persona region from `05_ddr4`, setting
  CAPS bit 2 and adding the PR keys to the profile.
- Bus 3 (NIC management) is not wired to the FPGA in this design.

## Attribution

Pin assignments come from `hardware/pinouts/csv/` in this repository. Device register
addresses come from the vendor datasheets under `hardware/datasheets/` (TMP411, LM25066
Table 41, DS250DF810). The PCIe HIP parameterisation is the one of project 03.
