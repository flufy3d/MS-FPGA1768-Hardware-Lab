# 05 — DDR4: PCIe + DDR4 static region, memory tests as PR personas

> Renamed from `05_shell` on 2026-11-19 (project files `ddr4.qpf` / `ddr4.qsf` /
> `ddr4_prbs.qsf`, top-level entity `ddr4_top`). Internal names such as `shell_sys`,
> `shell_regs` and the "shell" (static region) wording are unchanged. The hardware results
> below were obtained with the pre-rename build.

A reusable **static region ("shell")** for the card: the Gen3 x8 PCIe endpoint, the PR
controller and the temperature register of
[04_pcie_hot_update](../04_pcie_hot_update/), plus **both DDR4 channels**, a read-only
window into the configuration flash, and a fixed interface (the *persona ABI*) for the
reconfigurable region. Later demos are built as personas against this shell and loaded
over PCIe; the shell itself is loaded once per power-up over JTAG.

The first two personas are DDR4 memory tests; swapping between them over PCIe shows that
the test algorithm can be replaced without JTAG while the memory, its calibration and the
PCIe link stay up.

| Item | Value |
|------|-------|
| Top-level entity | `ddr4_top` |
| Revisions | `ddr4` (PR base, persona `persona_walk`) and `ddr4_prbs` (PR implementation, persona `persona_prbs`) |
| Host profile | [`host/profiles/05_ddr4.ini`](../../host/profiles/05_ddr4.ini): SHELL_ID `0x53480501`, CAPS `0x0000000D` (DDR4, PR, flash window; no I2C) |
| Device | `10AXF40AA` (Arria 10) |
| PCIe | #1, Gen3 x8, Avalon-MM with DMA HIP (DMA unused), 64-bit prefetchable BAR0, 64 KB, `0x1172` / `0xE003` (same driver as projects 02–04) |
| DDR4 | 2 × EMIF, DDR4-2133 (1066.667 MHz), 72 bit, ECC off, hard controller, quarter rate (user clock 266.667 MHz, 576-bit words) |
| Flash | ASMI Parallel II, **read only** (write strobe tied low in RTL) |
| Configuration | volatile `.sof` over JTAG; personas over PCIe; the configuration flash is not written by this design. Since 2026-11-19 the lab card's flash holds this shell, so it boots from flash at power-up |
| Status | **Built, not tested on hardware after rename** (2026-11-19): the renamed build with the CAPS register compiles with timing met and passes both simulation modes; it has not been loaded on the card. The pre-rename build (`05_shell`, `shell.sof`) is **verified on hardware** (2026-11-19): Gen3 x8, both DDR4 channels calibrated, full 2304 MiB per channel passes walking one and PRBS-31, persona swaps over PCIe; the lab card boots that build from its configuration flash. Needs airflow — see [Thermal warning](#thermal-warning) |

## Register map (BAR0)

`0x0000`–`0x000F` is the identity block of the host contract (SHELL_ID, CAPS, CAPS2; see
[host/README.md](../../host/README.md)): a 16-byte Avalon-MM bridge (`id_br`) answered by
read-only logic in `ddr4_top.sv`, writes ignored. It replaced the `pio_shell` input PIO
with the same span on 2026-11-19; in builds before that (including the image in the lab
card's flash) `0x04` and `0x08` were the PIO's unimplemented direction/interrupt-mask
registers and read `0`, so no register moved. The host tool treats a CAPS value of `0`
with a matching SHELL_ID as such an older build.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x0000` | `SHELL_ID` | RO | `0x53480501` ("SH", project 05, shell v1) |
| `0x0004` | `CAPS` | RO | `0x0000000D`: `[0]` DDR4, `[1]` I2C (0, not present), `[2]` PR, `[3]` flash window |
| `0x0008` | `CAPS2` | RO | `0x00000000` (reserved) |
| `0x000C` | — | RO | reads `0` |
| `0x0030` | `COUNTER` | RO | free-running 100 MHz counter |
| `0x0040` | `ID` | RO | `0x50434945` (the Windows driver allows writes only when it reads this) |
| `0x0050` | `TEMP` | RO | die temperature sensor, same format as projects 03/04 |
| `0x0060` | `PERSONA` | RO | `[15:0]` persona ID (`0` while frozen), `[16]` PR freeze, `[17]` persona reset, `[18]` 50 MHz PLL locked |
| `0x0100`–`0x010F` | PR controller | | same as project 04 (`PR_DATA`, `PR_CSR`, `PR_VERSION`, `PR_ID`) |
| `0x0200`–`0x02FF` | shell registers | | see below |
| `0x1000`–`0x1FFF` | persona window | | defined by the loaded persona; reads `0`, writes dropped while frozen |
| `0x4000`–`0x7FFF` | flash window | RO | 16 KB of the configuration flash, page selected by `FLASH_PAGE`; writes have no effect |
| `0x8000`–`0xFFFF` | scratch RAM | RW | 32 KB, sizes BAR0 to 64 KB |

Shell registers (`0x0200` + offset):

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `DDR_STATUS` | RO | per channel, top `[3:0]`, bottom `[11:8]`: `[0]` calibration success, `[1]` calibration fail, `[2]` EMIF user reset released, `[3]` quiesced; `[16]` quiesce requested |
| `0x04` | `QUIESCE` | RW | `[0]` = 1: the DDR ports stop accepting persona commands; `quiesced` = no command queued, no read outstanding |
| `0x08` | `FLASH_PAGE` | RW | `[12:0]`: 16 KB page shown in the flash window (8192 pages = 128 MB) |
| `0x0C` | `MBOX_CTRL` | RW | `[0]` channel (0 top, 1 bottom), `[1]` 1 = write |
| `0x10` | `MBOX_ADDR` | RW | `[24:0]` 576-bit word address |
| `0x14` | `MBOX_GO` | WO | start one mailbox access (only while quiesced, otherwise refused) |
| `0x18` | `MBOX_STATUS` | RO | top `[0]` busy, `[1]` refused; bottom `[8]`, `[9]` |
| `0x1C` | `DDR_INFO` | RO | `0x08551948`: 72 bytes per word, 25 word-address bits, 2133 MT/s |
| `0x20`–`0x64` | `MBOX_WDATA[0..17]` | RW | write data, word 0 = bits `[31:0]` |
| `0x80`–`0xC4` | `MBOX_RDATA[0..17]` | RO | read data of the selected channel |
| `0xF0` | `REGS_VERSION` | RO | `0x00010000` |

## Persona ABI (version 1)

Every persona is an entity with exactly the port list of
[`personas/persona_walk.sv`](personas/persona_walk.sv):

| Ports | Clock | Contract |
|-------|-------|----------|
| `clk_100`, `rst_100` | 100 MHz | `rst_100` is high after configuration, during PR and for 5.11 µs after it |
| `csr_addr[9:0]`, `csr_read`, `csr_write`, `csr_wdata`, `csr_rdata` | `clk_100` | BAR0 `0x1000`–`0x1FFF`, word addressed; `csr_rdata` valid the cycle after `csr_read` |
| `persona_id[15:0]` | — | shown in `PERSONA[15:0]` |
| `led[4:0]` | `clk_100` | LEDs `[8:4]` |
| `t_*` / `b_*` | `t_clk` / `b_clk` (EMIF user clocks, 266.667 MHz) | Avalon-MM master per channel: `addr[24:0]` (576-bit words), `read`, `write`, `wdata[575:0]`, `be[71:0]`, `ready` (= not waitrequest), `rdata`, `rvalid`; **burst length 1 only**; read data cannot be back-pressured; `t_rst`/`b_rst` = persona reset or EMIF user reset, synchronous |

No initial values in the PR region: every register that matters must be set by the
reset.

## Design

```
                       static region (shell)                                          PR region
PCIe #1 ─ Arria 10 HIP ─ rxm_bar0 ─┬─ id_br ─► identity block (SHELL_ID, CAPS, CAPS2); PIOs (ID, COUNTER, TEMP, PERSONA)
                                   ├─ pr_ip (alt_pr, 50 MHz) ── freeze ─► persona reset
                                   ├─ regs_br ─► shell_regs (DDR status, quiesce, mailbox, flash page)
                                   ├─ persona_br ─────────────── gate ──────────────────────► u_persona
                                   ├─ flash_br (50 MHz) ─► ASMI Parallel II (write tied low)       │
                                   └─ scratch RAM                                                  │
Y4 ─► EMIF top  (3E/3F/3G) ─ amm ─ ddr_port (FIFO, quiesce, mailbox) ◄── Avalon-MM, burst 1 ───────┤
Y3 ─► EMIF bot  (3B/3C/3D) ─ amm ─ ddr_port (FIFO, quiesce, mailbox) ◄── Avalon-MM, burst 1 ───────┘
```

- **No partial bursts across the PR boundary.** The Avalon-MM master freeze bridge in
  Quartus 25.1 (`altera_avlmm_mst_freeze_bridge`) only gates `read`/`write` unless traffic
  tracking is enabled, so a burst cut by a freeze would hang the EMIF. With burst length 1
  (one 576-bit word = one DDR4 BL8 burst) that cannot happen; `ddr_port` replaces the
  freeze bridge.
- **Quiesce before PR.** `QUIESCE` stops both ports and `quiesced` reports FIFO empty and
  no read outstanding. `fpga1768 load-pr` does **not** set it by itself (it never did; an
  earlier version of this README said so): run `fpga1768 ddr quiesce on` before
  `load-pr` and `ddr quiesce off` after it if a persona may have DDR traffic in flight.
  Independently, `ddr_port` stops accepting commands while the persona is in reset, and
  commands already queued always complete.
- **The DDR contents survive a persona swap**: the EMIFs (and their refresh) are in the
  static region.
- `ddr_port` is the PR boundary register stage: a capture register at the PR edge
  (splits the long persona → FIFO route), a 4-entry command FIFO with a registered ready,
  registered read-issue/return for the outstanding counter, and registered read data.
- Flash: the ASMI Parallel II memory port issues WRITE ENABLE + PAGE PROGRAM by itself on a
  write (`altera_asmi2_xip_controller`, Quartus 25.1), so the write strobe is tied low in
  `ddr4_top.sv` and the control port (erase) is tied off. The shell cannot modify the flash.
- PR region `X96 Y72`–`X127 Y151` (route region 2 columns/rows larger), between I/O column 2
  (bank 2A at X=78) and I/O column 3 (X=142; the DDR4 banks span Y≈26–181). Project 04's
  region (X120–139, Y120–139) touched the top channel's banks 3E/3F and was moved. The
  coordinates come from a probe fit (2026-11-18) and are a lab choice, not a board fact.
- EMIF parameters: reproduced in `make_qsys.tcl` from the community DDR4_Dual project,
  with ECC disabled; see [docs/hardware/ddr4.md](../../docs/hardware/ddr4.md) for the
  values and their confidence (board skews are IP defaults, not measurements).

## Personas

| Persona | ID | Revision | Test |
|---------|----|----------|------|
| `persona_walk` | `0x0101` | `shell` (base) | optional address-line test (word 0 and words 2^k, k = 0..24, unique tags), then walking one (or walking zero with `--invert`): a single 1 moving one bit per word, starting at bit `seed[9:0]` |
| `persona_prbs` | `0x0102` | `shell_prbs` | PRBS-31 (x³¹ + x²⁸ + 1), 576 sequence bits per word, seeded |

Both share [`personas/ddr_test_csr.sv`](personas/ddr_test_csr.sv) (registers) and
[`personas/ddr_test_engine.sv`](personas/ddr_test_engine.sv) (one engine per channel).
A run writes the range, then reads it back and compares every word. Per channel the
persona reports: words with errors, words written/read and the cycles each pass took
(bandwidth), the address and the expected/actual data of the first failing word, a sticky
mask of DQ lanes that saw errors, and whether the run was aborted.

Coverage: any word range up to the whole channel, 2²⁵ words × 72 bytes = 2.25 GiB per
channel, all 72 DQ lines (ECC off). The lane mask assumes that the 576-bit user word holds
the 8 beats beat-major (`[71:0]` = first beat); this is a `hypothesis` from the EMIF
documentation, not verified on the card.

Persona register map (`0x1000` + offset):

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x000` | `ID` | RO | `[15:0]` persona ID, `[31:16]` ABI version `1` |
| `0x004` | `CTRL` | RW | `[0]` write 1 = start on the channels in `[5:4]`; `[1]` abort; `[5:4]` channel mask (top, bottom); `[8]` write pass; `[9]` read pass; `[10]` invert; `[11]` address test |
| `0x008` / `0x00C` | `START_ADDR` / `END_ADDR` | RW | word range, inclusive |
| `0x010` | `SEED` | RW | pattern seed |
| `0x014` | `STATUS` | RO | top `[7:0]`, bottom `[15:8]`: `[0]` busy, `[1]` errors, `[2]` first error captured, `[3]` aborted |
| `0x018` | `CAPS` | RO | `[7:0]` pattern (1 walking, 2 PRBS), `[8]` address test |
| `0x400` / `0x800` | per channel (top / bottom) | RO | `+0x00` error words, `+0x04` words written, `+0x08` words read, `+0x0C` write cycles, `+0x10` read cycles, `+0x14` first error address, `+0x18` flags, `+0x1C` runs, `+0x20..0x28` lane mask, `+0x100..` first expected word (18 × 32 bit), `+0x200..` first actual word |

## Pins used

All locations and I/O standards are in `ddr4.qsf` (and, identically, `ddr4_prbs.qsf`).

| Signal | Pin(s) | Notes |
|--------|--------|-------|
| `clk_100` | `AP20` | 100 MHz board oscillator (CLKUSR pin), `GLOBAL_CLOCK` |
| `clk_pcie1`, `pcie1_perstn`, `pcie1_rx/tx[7:0]` | as project 04 | PCIe #1 |
| `led[8:0]` | `AM17 AH18 AJ18 AH17 AJ16 AK17 AK16 AK18 AL18` | `[0]` top calibrated, `[1]` bottom calibrated, `[2]` calibration failed, `[3]` 1 Hz heartbeat, `[8:4]` persona |
| `top_refclk` | `J3` / `K3` | Y4, 266.667 MHz LVDS |
| `bot_refclk` | `AG5` / `AG6` | Y3, 266.667 MHz LVDS |
| `top_mem_*`, `top_oct_rzqin` | banks 3E/3F/3G, RZQ `L2` | from `hardware/pinouts/csv/fpga_1_DDR4_Interface_1_Top_Pinout.csv` |
| `bot_mem_*`, `bot_oct_rzqin` | banks 3B/3C/3D, RZQ `AH7` | from `hardware/pinouts/csv/fpga_2_DDR4_Interface_2_Bot_Pinout.csv` |

The configuration flash uses the dedicated AS pins (no assignment).

## Build

```powershell
. ..\..\scripts\env.ps1
Remove-Item -Recurse -Force ip\shell_sys, shell_sys -ErrorAction SilentlyContinue
& "$env:QUARTUS_ROOTDIR\..\qsys\bin\qsys-script.exe" --script=make_qsys.tcl --quartus-project=ddr4.qpf
& "$env:QUARTUS_ROOTDIR\..\qsys\bin\qsys-generate.exe" shell_sys.qsys --quartus-project=ddr4.qpf `
    --rev=ddr4 --synthesis=VERILOG --parallel=off --family="Arria 10" --part=10AXF40AA
.\build_pr.ps1            # base compile, export static region, implementation compile
```

`qsys-script --quartus-project` adds new `IP_FILE` lines only to the current revision:
after regenerating, check that `ddr4.qsf` and `ddr4_prbs.qsf` list the same IP files
(`diff --strip-trailing-cr ddr4.qsf ddr4_prbs.qsf` shows only the persona file and the
PR block).

`--parallel=off` is a lab-host workaround: parallel IP generation starts several
`qsys-generate --server-mode` processes that hang here (2026-11-19), and the first attempt
can abort with the Quartus DDM assertion (`DDM_T::verify_token ... Cannot identify the
client`); a retry with serial generation succeeded. If generation still stops early,
check that `ip\shell_sys\shell_sys_emif_top\` and `...\shell_sys_emif_bot\` contain HDL.

## Simulation

The DDR port and both persona bodies have a logic test bench that does not need the card:

```powershell
. ..\..\scripts\env.ps1
.\sim\run_sim.ps1         # MODE 0 walking one, MODE 1 PRBS
```

`run_sim.ps1` writes `sim\sim_mode0.log` and `sim\sim_mode1.log`; both must end in
`==== PASSED`. Questa is a separate install: `scripts\env.ps1` finds it through
`QUESTA_ROOTDIR`, or `D:\questasim64_2024.1`, or the copies under the Quartus tree.

Outputs in `output_files/`: `ddr4.sof` (full image), `ddr4.pr_partition.rbf`
(`persona_walk`), `ddr4_prbs.pr_partition.rbf` (`persona_prbs`). Every `.rbf` is valid
only with the `.sof` of the same base compile.

## Host tool

The shared tool [`host/`](../../host/) (`fpga1768`, Windows and Linux backends) selects
the profile [`host/profiles/05_ddr4.ini`](../../host/profiles/05_ddr4.ini) from SHELL_ID
and allows the DDR4, PR and flash commands because CAPS has those bits:

```
fpga1768 probe                     read only: SHELL_ID, CAPS, profile offsets, sanity reads
fpga1768 info                      link, BAR0, profile/CAPS, temperature, PR state, persona
fpga1768 ddr status
fpga1768 ddr test [--ch top|bot|both] [--start W] [--end W] [--seed S] [--invert]
                  [--addr-test] [--no-write] [--no-read] [--timeout SEC] [--temp-every SEC]
fpga1768 ddr quiesce on|off
fpga1768 ddr peek top|bot ADDR     / ddr poke top|bot ADDR VALUE32   (mailbox)
fpga1768 load-pr FILE              load persona, check link/BAR0 (quiesce first, see Design)
fpga1768 flash-dump FILE [MB]      read the configuration flash, print SHA-256
```

## Program and test

Windows lab host:

```powershell
. ..\..\scripts\env.ps1
quartus_pgm -m jtag -o "p;output_files\ddr4.sof"     # do not run jtagconfig first
shutdown /r /t 0                                      # warm reboot: the 64-bit BAR is assigned at boot
# after the reboot:
$t = "..\..\host\build\fpga1768.exe"
& $t probe                                            # SHELL_ID, CAPS 0x0000000D, offsets
& $t temp
& $t ddr status                                       # both channels: cal SUCCESS
& $t ddr test --ch top --end 0xFFFF --addr-test       # short first test
& $t ddr test                                         # both channels, whole range
& $t ddr quiesce on
& $t load-pr output_files\ddr4_prbs.pr_partition.rbf
& $t ddr quiesce off
& $t ddr test --seed 0x1234
```

> On the lab card the JTAG load is no longer needed after a power cycle: the flash holds
> the pre-rename build (`shell.sof`, SHA-256 `48821F89…4D7E5B`) since 2026-11-19, so the
> card boots `1172:E003` by itself. That build has no CAPS register (CAPS reads `0`); the
> host tool falls back to the profile's CAPS. Only the persona `.rbf` files of that same
> build (`shell.pr_partition.rbf`, `shell_prbs.pr_partition.rbf`) match it — the `ddr4*`
> personas of the renamed build do not. Load `ddr4.sof` when you want the renamed build,
> and then use only its `ddr4*.pr_partition.rbf` files.

Flash backup (read only):

```powershell
& $t flash-dump flash_a.bin
& $t flash-dump flash_b.bin                           # the two SHA-256 must match
```

## Expected observation

- `ddr status`: both channels `cal SUCCESS`, user reset released; LEDs 0 and 1 on.
- `ddr test`: 0 error words; about 2²⁵ words written and read per channel and pass.
- `load-pr`: quiesce, status 4 → 5, link and BAR0 unchanged, persona `0x0102`.
- Throughout: no reboot after the first one, link Gen3 x8, BAR0 unchanged, Windows device
  OK.

## If it fails

| Symptom | Likely cause |
|---------|--------------|
| `cal FAIL` | see [bringup/04-ddr4.md](../../docs/bringup/04-ddr4.md) |
| `ddr test`: channel not ready | not calibrated, or the EMIF user reset is still asserted |
| `load-pr`: DDR ports did not quiesce | a persona keeps reads outstanding (hang in the EMIF); reload the `.sof` |
| errors in one lane only | that DQ line / device; the lane mask points at it |
| card disappears 20–40 min after power-on | overheating (no fan), see [Thermal warning](#thermal-warning) |
| `quartus_pgm` hangs with no progress, then `jtagconfig` says `Server error` | stale `jtagserver` from a killed session; kill the process (needs admin/SYSTEM) and retry |

## Thermal warning

Airflow is mandatory. Measured on 2026-11-19:

- **No fan:** the shell read 130.2 °C about 5 minutes after configuration and the card
  lost power 78 s later. No DDR test ran in that attempt.
- **Small fan over the heatsink:** 47.7 °C after the warm reboot, 48.3 °C flat over five
  minutes, 48.3–49.0 °C during the DDR tests, the persona load and two 128 MB flash dumps.

The Quartus Power Analyzer puts the design at 15.0 W (I/O 6.20 W, device static 5.33 W,
transceivers 2.47 W, core dynamic 1.01 W), so most of the heat is there even when no test
runs. Read `TEMP` with `--temp-every` and stop if it climbs past about 85 °C.

## Build warnings (reviewed)

Reviewed on the pre-rename build (`shell`, 2026-11-19) and re-checked on the renamed build
(`ddr4` / `ddr4_prbs`, fitter seed 2, 2026-11-19, Quartus Prime Pro 25.1 patch 0.36): the
same set of critical warnings appears (`19854`, the eight EMIF speed-grade messages,
`18326`, `17951`/`18655`), no new one, and the design MTBF is again `1e9` years. None is
left unexplained.

| Message | Where | Assessment |
|---------|-------|------------|
| `19854` explicit initial values in `pr_partition` | Analysis & Synthesis | The persona RTL contains no initial values (`ddr_test_csr.sv`, `ddr_test_engine.sv`, `persona_walk.sv`). Synthesis encodes the power-up state of the extracted FSM/registers inside the partition. Every persona load rewrites the whole PR region and holds it in reset until `rst_100` is released, so a power-up value cannot survive into an operating persona. **Judged harmless.** |
| EMIF "generated for a speed grade E1 device" | Fitter (EMIF report) | The target string is `10AXF40AA`, which carries no speed-grade suffix, so the EMIF IP compares against the family default E1. With the 266.667 MHz reference clocks the only valid memory frequency is 1066.667 MHz, which is legal for every Arria 10 speed grade; the EMIF timing report for this fit passes (Core, Read Capture, Write, DQS gating all positive). Regenerating against a speed-grade part (`10AX115N4F40E3SG`) would change the device, so the warning is accepted. |
| `19536` unsafe MTBF | Timing Analyzer | **Gone in the final build.** The earlier fit had a 0.821 ns chain; an intermediate fit put the persona `u_sync` start/abort synchroniser at 0.588 ns (22 years at the default 12.5 % toggle assumption). After the `ddr_port` capture/return registers fixed placement, the worst chain has 1.315 ns of settling time and the design MTBF is `1e9` years (the tool's reporting ceiling). If it returns, look at `u_persona|u_body|u_bot|u_sync`. |
| `15714` LED current strength | Fitter | Fixed by `CURRENT_STRENGTH_NEW 8MA` on `led[*]` in `ddr4.qsf`; no longer reported. |
| `17951` / `18655` unused HSSI channels | Fitter | PCIe uses 8 of the 48 transceiver channels; the rest are unconnected on this design. Expected. |
| `18326` CLKUSR pin `AP20` | Fitter | `clk_100` is the 100 MHz board oscillator on the dedicated CLKUSR pin. The auto-reserve is for transceiver calibration; 100 MHz is inside the 100–125 MHz range the warning names. Keep the assignment. |

`ddr4.sdc` cuts the first synchroniser stage (`*sync_s0*`) and the quasi-static
configuration buses; the remaining paths are timed normally.

**Fitter seed.** `ddr4.qsf` and `ddr4_prbs.qsf` set `SEED 2`. With the default seed the
renamed build (identity block added) missed the top EMIF user clock by 0.042 ns on two
endpoints: hard-controller ready (`tile_ctrl_inst~hmc_reg0/1`) → `u_port_top|rd_ptr[1]`
in `ddr_port`, 3.66 ns data delay against a 3.752 ns relationship. The RTL of `ddr_port` is
unchanged, so this is placement variation; seed 2 gives +0.154 ns. This path has the least
margin in the design; if a later change makes it fail again, try another seed before
changing `ddr_port`.

## Resource usage

Quartus Prime Pro 25.1, device `10AXF40AA`, renamed build with the identity block, fitter
seed 2, 2026-11-19 (pre-rename `shell` build in brackets):

| Resource | `ddr4` (PR base, `persona_walk`) | `ddr4_prbs` (PR implementation) |
|----------|-----------------------------------|----------------------------------|
| ALMs | 19,375 / 427,200 (5 %) [19,308] | 27,351 / 427,200 (6 %) [27,040] |
| Registers | 42,702 [42,709] | 41,749 [41,791] |
| Pins | 307 / 826 (37 %) | 307 / 826 (37 %) |
| Block memory bits | 672,770 / 55,562,240 (1 %) [672,514] | 672,770 / 55,562,240 (1 %) [672,514] |
| M20K blocks | 49 / 2,713 (2 %) [48] | 49 / 2,713 (2 %) [48] |
| DSP blocks | 0 / 1,518 | 0 / 1,518 |
| HSSI RX / TX | 8 / 48 each (17 %) | 8 / 48 each (17 %) |
| PLLs | 17 / 112 (15 %) | 17 / 112 (15 %) |

The two extra 674-bit capture registers (one per channel), the read-issue/return
registers, and the larger PRBS engine account for the difference between the revisions;
the FIFO itself is flip-flop based, not M20K.

## Bitstreams

Every `.rbf` is valid only with the `.sof` of the same base build (recorded here so a
later rebuild does not silently invalidate it). The rename and the identity block
regenerated the base image, so **the `shell*.rbf` personas below do not match `ddr4.sof`,
and the `ddr4*.rbf` personas do not match the `shell.sof` image in the lab card's
flash.**

Renamed build, 2026-11-19, Quartus Prime Pro 25.1 patch 0.36, fitter seed 2 — **built, not
tested on hardware**:

| File | Purpose | SHA-256 |
|------|---------|---------|
| `output_files/ddr4.sof` | full base image, load over JTAG | `1F5ECBE891996714E7C0CD6D1E8993008688DCCD2DF6DA1D51C1111A3DBA8FDD` |
| `output_files/ddr4.pr_partition.rbf` | PR bitstream, `persona_walk` | `5B269AF63E0646400F352F3746818D49D7D4B76E0E8844222B0C968BDFBEC72D` |
| `output_files/ddr4_prbs.pr_partition.rbf` | PR bitstream, `persona_prbs` | `1DAF004F312DADB20C05E8324A3D505FBB86A6D0D324D61313FD1D73B20B1222` |
| `output_files/ddr4_prbs.sof` | implementation build (for reference) | `643ADAFE0E41788926C0D591054A1839BEDC76A41B4B557F61D08B55409E9C27` |

Pre-rename build (`05_shell`), 2026-11-19 — verified on hardware; `shell.sof` is the image
written to the lab card's configuration flash:

| File | Purpose | SHA-256 |
|------|---------|---------|
| `output_files/shell.sof` | full base image, load over JTAG | `48821F89D294E9A1888286EFB147E8507BC18EFCED1E35822A726CE11A4D7E5B` |
| `output_files/shell.pr_partition.rbf` | PR bitstream, `persona_walk` | `7542584A04AC48ED92B3CDFD437EB5DB0576521A1022F3DB10E5A8AA33190666` |
| `output_files/shell_prbs.pr_partition.rbf` | PR bitstream, `persona_prbs` | `9300EAD3B2A1DBE14C5D8F511517D7B6F7BF28FBD954FD31092A8DB129FE4FE7` |
| `output_files/shell_prbs.sof` | implementation build (for reference; not loaded on the card) | `4B78FC565DE999CBB5876B388C535724A63EE4C2381DE3B128F8DAA92DFFB4FB` |

## Results

- **Logic simulation, 2026-11-19:** `sim/run_sim.ps1` passes both modes with Questa
  2024.1 — `==== PASSED: 0 failure(s), MODE 0` (walking one + address test) and
  `==== PASSED: 0 failure(s), MODE 1` (PRBS-31). No `-suppress 7061` is needed; the
  power-up values moved into the reset branch of `ddr_port.sv`. Re-run after the rename
  with the same result. The test bench covers `ddr_port` and the persona bodies, not the
  identity block (SHELL_ID/CAPS), which is constant read logic in `ddr4_top.sv`.
- **Timing, renamed build (seed 2), 2026-11-19:** both revisions — "Timing requirements
  were met". Worst setup slack: base `ddr4` +0.154 ns (top EMIF user clock; bottom
  +0.282 ns); implementation `ddr4_prbs` +0.121 ns (bottom; top +0.154 ns). Worst hold
  slack +0.016 ns in both. Base Fmax (slow 900 mV 100 °C): top / bottom EMIF user clock
  283.13 / 288.68 MHz (266.667 MHz required), `clk_100` 135.03 MHz, PR/flash 50 MHz clock
  106.16 MHz, PCIe core clock 283.29 MHz (restricted).
- **Timing, pre-rename build, 2026-11-19:** both revisions met timing. EMIF core user
  clocks: base `shell` +0.172 ns (top) / +0.183 ns (bottom); implementation `shell_prbs`
  +0.151 ns / +0.159 ns, all at the slow 900 mV 100 °C corner.
- **Hardware, 2026-11-19 (pre-rename build `shell.sof`):** passed end to end on the lab
  card — see
  [lab-log/2026-11-19-05-shell-ddr4.md](../../lab-log/2026-11-19-05-shell-ddr4.md).
  - `info`: `1172:E003`, BAR0 `0x383FFFE00000`, Gen3 x8, shell ID `0x53480501`.
  - `ddr status`: both channels `cal SUCCESS`, user reset released.
  - Walking one, top: 4.5 MiB with address test, 0 errors; inverted 36 MiB, 0 errors.
  - Walking one, full both channels: 33 554 458 words (2304.0 MiB) each, 0 errors,
    18.2 GB/s per channel.
  - `load-pr` of `shell_prbs`: status 5 SUCCESS in 30.5 s (1.60 MB/s), persona
    `0x0101` → `0x0102`, BAR0 and the Gen3 x8 link unchanged.
  - PRBS-31, full both channels, seed `0x1234`: 0 errors, 18.2 GB/s.
  - Two 128 MB `flash-dump` runs byte-identical
    (`4C727C31…9326C`), 49.8 % of the flash erased.
  - Die temperature held at 47.7–49.0 °C with a small fan; without one the card read
    130.2 °C and lost power 5 minutes after the shell was configured.

  > `fpga1768 load-pr` returns exit code 4 with `Unknown persona ID 0x0102` after a
  > successful load: that check is the project 03/04 `A+B` / `A-B` persona test and does
  > not recognise the project 05 DDR personas. Use `ddr status` / `ddr test` instead.

## Attribution

EMIF parameters follow the community DDR4_Dual project
([tow3rs/catapult-v3-smartnic-re](https://github.com/tow3rs/catapult-v3-smartnic-re),
`Projects/DDR4/DDR4_Dual`); no files of that project are copied. PR flow, EMIF, ASMI
Parallel II and PCIe IP are Intel/Altera IP shipped with Quartus Prime Pro 25.1. Board
pin assignments come from `hardware/pinouts/csv/`.
