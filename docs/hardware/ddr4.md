# DDR4 memory

> Status: reported (pinout + calibration tested by prior art), not re-tested in this lab
> Source: [DDR4_Interface_*_Pinout sheets](../../hardware/pinouts/), BOM, OpenCL BSP

## Topology

Two independent memory channels, each **72 bits wide (64 data + 8 ECC)**:

| Channel | Designator in reference projects | Capacity | Devices |
|---------|----------------------------------|----------|---------|
| Top (`emif_top`) | U7-U11 | 2.25 GB | 5 × 4 Gb, one device contributes only 8 bits |
| Bottom (`emif_bot`) | U2-U6 | 2.25 GB | 5 × 4 Gb, one device contributes only 8 bits |

Total population is 9 × 4 Gb = 4.5 GB; the tenth device position is unpopulated. Only
4.5 GB of the nominal 5 GB is usable because one byte lane per channel is not wired — this
is intentional on the Microsoft board, not a fault.

- Part: `H5AN4G6NAFR-UHC` (SK hynix, DDR4-2400, 4 Gb, x16).
- Reference clock: Y4 (top) / Y3 (bottom), 266.667 MHz LVDS → DDR4-2133 (266.667 × 8).
- Aggregate theoretical bandwidth ≈ 34.1 GB/s (2 channels × 2133 MT/s × 8 B), which matches
  the `max_bandwidth="34128"` figure in the OpenCL `board_spec.xml`.
- On-die termination / OCT calibration resistor: 240 Ω on `L2` (top) and `AH7` (bottom).
- `mem_alert_n` is wired, ECC is supported by the FPGA hard controller.

## Pin groups

Only the first lines are shown; use the spreadsheets for the full list.

| Signal group | Top channel pins | Bottom channel pins |
|--------------|------------------|---------------------|
| Address `A[16:0]` | `L5 M5 L4 M4 M6 M7 K7 L7 K5 K6 N6 N7 L3 K1 K2 H3 H4` | `AN3 AM4 AL3 AL4 AL5 AK5 AK6 AJ6 AK3 AJ4 AJ5 AH6 AG7 AJ3 AH3 AF7 AE7` |
| Bank / BG | `J1 J4 J5` | `AF5 AH4 AG4` |
| Control | `N8 M9 P9 P8 P10 R11 P11 L9` (CK, CK_N, CKE, ODT, PAR, ACT_N, CS_N, RESET_N) | `AK1 AK2 AM1 AR1 AH2 AL2 AM2 AN2` |
| Data `DQ[71:0]` | `F5 C4 C3 D3 … W3` | `AB1 AA4 AB2 Y1 … AW4` |
| Strobe `DQS[8:0]` | `D4 B6 E3 G5 M10 N1 U5 V1 W9` | `AA2 AE5 AA7 AF8 AG9 AN7 AR5 AW6 AH1` |
| RZQ | `L2` | `AH7` |

Full machine-readable pinouts:

- [DDR4 top (CSV)](../../hardware/pinouts/csv/ddr4-top.csv)
- [DDR4 bottom (CSV)](../../hardware/pinouts/csv/ddr4-bottom.csv)

## Using the memory

The simplest path is the community EMIF design, which already contains a calibrated
`Qsys`/Platform Designer system for both channels:

- `reference/catapult-v3-smartnic-re/Projects/DDR4/DDR4_Top`
- `reference/catapult-v3-smartnic-re/Projects/DDR4/DDR4_Bot`
- `reference/catapult-v3-smartnic-re/Projects/DDR4/DDR4_Dual`

They were built with Quartus 20.1 and the Arria 10 EMIF IP. Regenerating the IP in
Quartus 25.1 is likely necessary; the pin assignments and the board timing parameters can
be reused.

Checklist when bringing up memory:

1. Confirm all rails are present (DDR4 VDD 1.2 V, VPP 2.5 V, VTT).
2. Confirm `oct_rzqin` is connected to the 240 Ω resistor pin, not left floating.
3. Use the EMIF "Example Design" first — it runs a built-in sweep and reports calibration
   pass/fail on LEDs.
4. Calibration success is visible on `led[0]`/`led[1]` in the GoldenTop reference design
   (top channel: `led[0]` success, `led[1]` fail; bottom: `led[3]`/`led[4]`).
5. Do not run a memory test with an unconstrained EMIF — the Arria 10 hard controller needs
   the correct board skew parameters from the reference `.qsf`.

## Known-good evidence

The upstream project reports both channels calibrated and tested on the PCIe variant.
The OpenCL BSP uses both channels as one 4 GiB interleaved global memory (two 2 GiB
windows at `0x0` and `0x1_0000_0000`), so the memory map is known to work with the
Microsoft base design.
