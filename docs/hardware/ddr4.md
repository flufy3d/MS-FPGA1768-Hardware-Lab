# DDR4 memory

> Status: verified — both channels calibrated and passed full-capacity traffic tests on
> this card on 2026-11-19. Pinout and EMIF clocking were verified with Quartus on
> 2026-11-18/19.
> Source: [DDR4 pinout CSVs](../../hardware/pinouts/csv/), [BOM](../../hardware/pinouts/csv/bom_0_BOM.csv),
> `H5AN4G6NAFR-UHC` datasheet, community DDR4_Dual project, Quartus Prime Pro 25.1, and
> [lab-log/2026-11-19-05-shell-ddr4.md](../../lab-log/2026-11-19-05-shell-ddr4.md)
> Last verified: 2026-11-19 (hardware, `projects/05_ddr4`, then named `05_shell`)

## Topology

Two independent memory channels. Each has five x16 devices; the fifth device has only
its lower byte wired, so a channel is **72 bits wide: 64 data + 8 ECC**.

| Channel | Devices | FPGA I/O banks | Reference clock | RZQ |
|---------|---------|----------------|-----------------|-----|
| Top | U7, U8, U9, U10 (x16) + U11 (lower byte only, `DQ64-71`) | 3E (`DQ0-31`), **3F** (address/command, `DQ64-71`, RZQ, refclk), 3G (`DQ32-63`, `ALERT_N`) | Y4, `J3` / `K3` | `L2` |
| Bottom | U2, U3, U4, U5 (x16) + U6 (lower byte only) | 3B, **3C** (address/command, `DQ64-71`, RZQ, refclk), 3D (`ALERT_N`) | Y3, `AG5` / `AG6` | `AH7` |

- Bank membership: `verified` 2026-11-18 from the Quartus pin report of project 04 (every
  DDR4 pin of both CSVs). Each interface uses three adjacent banks with address/command in
  the middle bank, which is the layout the Arria 10 EMIF IP expects.
- Device count: the BOM lists **ten** devices, `U2`–`U11`, and the two CSVs reference five
  devices each. An earlier version of this page said that nine devices were fitted and the
  tenth position was empty; that was wrong.
- Part: `H5AN4G6NAFR-UHC` (SK hynix, 4 Gb, x16, speed bin DDR4-2400 17-17-17).

## Capacity

| Quantity | Per channel | Both channels | Notes |
|----------|-------------|---------------|-------|
| Physical DRAM | 5 × 4 Gb = 2.5 GiB | 5 GiB | |
| Reachable (72-bit) | 2.25 GiB | 4.5 GiB | upper byte of U6/U11 not wired |
| Data (64-bit, with ECC) | 2 GiB | 4 GiB | matches the OpenCL BSP's 4 GiB global memory |

Address space per channel: 15 row + 10 column + 2 bank + 1 bank-group bits = 2²⁵ words of
576 bits (8 beats × 72 bits). The missing quarter of U6/U11 is a **data lane**, not an
address range: every address is usable, and no address range "at the top of the channel"
fails. (An earlier note said the opposite; it was wrong.)

## Speed

**DDR4-2133 (1066.667 MHz memory clock).** Evidence:

| Evidence | Status |
|----------|--------|
| Y3/Y4 are 266.667 MHz; 266.667 × 4 = 1066.667 MHz | reported (BOM) |
| The Arria 10 EMIF IP (Quartus Prime Pro 25.1), with a 266.667 MHz PLL reference clock and quarter-rate user clock, reports *"Valid memory frequencies … 1066.67"* — the only valid choice. DDR4-2400 is not reachable from these oscillators. | verified 2026-11-19 (IP generation, projects/05_ddr4) |
| Community DDR4_Dual project: `PHY_DDR4_MEM_CLK_FREQ_MHZ 1066.667`, `DDR4_SPEEDBIN_2133`, CL 15 | reported |
| OpenCL BSP `max_bandwidth="34128"` = 2 channels × 2133 MT/s × 8 bytes | reported |

The devices themselves are DDR4-2400 parts; "2400" in older notes referred to the parts,
not to the interface. Theoretical bandwidth: 17.1 GB/s per channel (64 data bits),
34.1 GB/s for both.

Speed-grade caution (`unknown`): Quartus models `10AXF40AA` as fabric speed grade 2
(`get_part_info`, 2026-11-18), while the community equates the part with
`10AX115N4F40E3SG` (grade 3). Per-speed-grade EMIF limits were not found in Intel
documentation; DDR4-2133 is the conservative choice either way.

## EMIF parameters

The community [DDR4_Dual](https://github.com/tow3rs/catapult-v3-smartnic-re) project
(Quartus 20.1) is the only source. What it contains:

| Item | Value | Confidence |
|------|-------|------------|
| Protocol, width, geometry | DDR4, discrete x16, 72 bit, 1 rank, 15/10/2/1 address bits | high (matches CSV and datasheet) |
| I/O | address/command and CK SSTL-12 with 40 Ω calibrated OCT; DQ POD-12, 34 Ω out / 120 Ω in calibrated; RZQ CMOS 1.2 V | reported (calibrated in that project) |
| DRAM settings | `RTT_NOM` RZQ/4, drive RZQ/7, read DBI on, write DBI off, DM on, CA parity + ALERT_N on | reported |
| Timing | DDR4-2133 bin, CL 15, CWL 12, tRCD/tRP 14.06 ns, tRFC 260 ns | reported |
| Board skews | 0.02 ns skews, 0.6 ns max CK/DQS delay, default ISI and slew rates | **low**: these are the EMIF IP's default values, not measurements |
| Controller | hard controller, ECC on with auto-correction, reordering on | design choice |

There is no published board-skew data for this card. If calibration margins are poor, the
board-skew parameters are the first suspect; measuring them would need the PCB layout.

`projects/05_ddr4/make_qsys.tcl` reproduces these values in a script (with ECC disabled
so that a memory test sees all 72 DQ lines). The upstream project files are not copied
into this repository.

## Pin groups

| Signal group | Top channel pins | Bottom channel pins |
|--------------|------------------|---------------------|
| Address `A[16:0]` | `L5 M5 L4 M4 M6 M7 K7 L7 K5 K6 N6 N7 L3 K1 K2 H3 H4` | `AN3 AM4 AL3 AL4 AL5 AK5 AK6 AJ6 AK3 AJ4 AJ5 AH6 AG7 AJ3 AH3 AF7 AE7` |
| Bank / BG | `J1 J4 J5` | `AF5 AH4 AG4` |
| Control | `N8 M9 P9 P8 P10 R11 P11 L9` (CK, CK_N, CKE, ODT, PAR, ACT_N, CS_N, RESET_N) | `AK1 AK2 AM1 AR1 AH2 AL2 AM2 AN2` |
| `ALERT_N` | `E5` | `Y3` |
| Data `DQ[71:0]` | `F5 C4 C3 D3 … W3`, `DQ64-71` on U11 | `AB1 AA4 AB2 Y1 … AW4`, `DQ64-71` on U6 |
| Strobe `DQS[8:0]` | `D4 B6 E3 G5 M10 N1 U5 V1 W9` | `AA2 AE5 AA7 AF8 AG9 AN7 AR5 AW6 AH1` |
| RZQ (240 Ω) | `L2` | `AH7` |

Full machine-readable pinouts (the CSVs agree pin for pin with the DDR4_Dual `.qsf`,
258/258 pins, checked 2026-11-18):

- [DDR4 top (CSV)](../../hardware/pinouts/csv/fpga_1_DDR4_Interface_1_Top_Pinout.csv)
- [DDR4 bottom (CSV)](../../hardware/pinouts/csv/fpga_2_DDR4_Interface_2_Bot_Pinout.csv)

## Using the memory

- Lab design: [projects/05_ddr4](../../projects/05_ddr4/) — both channels behind the PCIe
  shell, memory tests as PR personas. Bring-up procedure:
  [bringup/04-ddr4.md](../bringup/04-ddr4.md).
- The EMIF reference clock comes from Y3/Y4 (dedicated pins in the address/command bank);
  do not try to derive it from the 100 MHz `AP20` clock.
- The OCT calibration resistor pin (`L2` / `AH7`) must be connected to the EMIF's
  `oct_rzqin`.

## Known-good evidence

- The upstream project reports both channels calibrated (EMIF Toolkit screenshots) on the
  PCIe variant; it did not run a traffic test.
- The OpenCL BSP uses both channels as one 4 GiB interleaved global memory (two 2 GiB
  windows at `0x0` and `0x1_0000_0000`).
- In this lab, 2026-11-19 (`projects/05_ddr4` as `05_shell`, PCB `M1003380-005`): both channels
  `cal SUCCESS` at the first read after boot, and the full 2304 MiB of each channel passed
  a walking-one test with the address test enabled and a PRBS-31 test, 0 error words,
  18.2 GB/s per channel. The persona was replaced over PCIe in between without losing
  calibration. See [lab-log/2026-11-19-05-shell-ddr4.md](../../lab-log/2026-11-19-05-shell-ddr4.md).
