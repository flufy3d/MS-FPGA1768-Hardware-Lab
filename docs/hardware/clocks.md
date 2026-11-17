# Clocks

> Status: reported (frequencies + pins from prior art), `clk_u59` verified in hello world
> Source: [FPGA_Pinouts.xlsx](../../hardware/pinouts/FPGA_Pinouts.xlsx), BOM

All oscillators are soldered; there is no clock generator that needs software configuration
except the PCIe fanout buffer (straps only).

| Ref | Frequency | FPGA pin | Loads | Notes |
|-----|-----------|----------|-------|-------|
| Y3 | 266.667 MHz | `AG5` / `AG6` (LVDS) | DDR4 channel B ("bottom") PLL reference | 2400 MT/s capable; designs use it as EMIF refclk |
| Y4 | 266.667 MHz | `J3` / `K3` (LVDS) | DDR4 channel A ("top") PLL reference | |
| Y5 | 644.53125 MHz | `U29` / `U28` (LVDS) | QSFP+ / retimer reference | 25.78 Gb/s line rate × 4 lanes = 50G (64b/66b) |
| Y6 | 644.53125 MHz | `E29` / `E28` (LVDS) | FPGA ↔ Mellanox XCVR reference | **156.25 MHz on the OCP variant** |
| U59 | 100 MHz | `AP20` (LVCMOS 1.8 V) | `CLKUSR`, general logic | the "board clock" in examples (`clk_u59`) |
| U57 | 100 MHz | `AN29` / `AN28` (LVDS) | PCIe #1 reference | through U56 fanout |
| U56 | 100 MHz | `AE29` / `AE28` (LVDS) | PCIe #2 reference | same source, different output |
| Y2 | 12.000 MHz | — | FT232H | USB programmer only |
| Y1 | 100 MHz | — | Mellanox NIC reference | variant dependent |
| U54 | 25 MHz | — | DS250DF810 retimer | |

## Pin constraints

```tcl
# 100 MHz board clock (single-ended 1.8 V)
set_location_assignment PIN_AP20 -to clk_u59
set_instance_assignment -name IO_STANDARD "1.8 V" -to clk_u59

# LVDS reference clocks
set_location_assignment PIN_AG5  -to clk_y3
set_location_assignment PIN_AG6  -to "clk_y3(n)"
set_instance_assignment -name IO_STANDARD LVDS -to clk_y3
# ... same pattern for y4 (J3/K3), y5 (U29/U28), y6 (E29/E28),
#     pcie1 (AN29/AN28), pcie2 (AE29/AE28)
```

## Practical notes

- `clk_u59` is the only single-ended clock and the easiest to use for a first design.
  100 MHz is fast enough that a 26-bit divider gives a 1 Hz LED.
- The reference designs expose the LVDS clocks as **single-ended** ports in the top level
  (`clk_y3` etc.). Quartus infers the differential buffer from the `_n` assignment; if you
  use them as clocks you get a 266/644 MHz clock, which needs proper timing constraints.
- `clk_pcie1`/`clk_pcie2` must only be used by the PCIe hard IP; the HIP drives its own
  `coreclkout` for user logic.
- There is no on-board programmable clock synthesizer, so frequencies are fixed by the
  oscillators. If you need another frequency, use a PLL.

## Measuring

`clk_u59` can be routed to an LED or a counter and checked by eye. The transceiver
references cannot be observed without an instrument; they can be checked indirectly by
bringing up the PCIe link or the QSFP retimer.

For a quick sanity check of the 100 MHz clock, the hello-world design divides it down to
1 Hz and toggles `led[8]`: if the heartbeat is wrong by a large factor, the wrong clock pin
or oscillator is being used.
