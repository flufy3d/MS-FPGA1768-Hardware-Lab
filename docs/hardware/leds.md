# LEDs

> Status: verified (hello world) / reported (numbering)
> Last verified: 2026-11-17

The card has **nine user LEDs** along the front edge (silkscreened `ALL LEDS AT EDGE`).
They are driven directly from the FPGA, 1.8 V bank, active high (a logic 1 lights the LED).

| Index | FPGA pin |
|-------|----------|
| `led[0]` | `AM17` |
| `led[1]` | `AH18` |
| `led[2]` | `AJ18` |
| `led[3]` | `AH17` |
| `led[4]` | `AJ16` |
| `led[5]` | `AK17` |
| `led[6]` | `AK16` |
| `led[7]` | `AK18` |
| `led[8]` | `AL18` |

The PCB designators (`D2`…`D14`) differ between the PCIe and OCP variants — the community
spreadsheet lists both, but the mapping is ambiguous, so it is not repeated here. The
electrical order is the pin list above; `led[0]` is the LED nearest the bracket on the
reference photographs (**visual check pending**).

## Constraints

```tcl
set_instance_assignment -name IO_STANDARD "1.8 V" -to leds[*]
set_location_assignment PIN_AM17 -to leds[0]
set_location_assignment PIN_AH18 -to leds[1]
set_location_assignment PIN_AJ18 -to leds[2]
set_location_assignment PIN_AH17 -to leds[3]
set_location_assignment PIN_AJ16 -to leds[4]
set_location_assignment PIN_AK17 -to leds[5]
set_location_assignment PIN_AK16 -to leds[6]
set_location_assignment PIN_AK18 -to leds[7]
set_location_assignment PIN_AL18 -to leds[8]
```

## Using them for bring-up

The LEDs are the only human-visible output on the board, which makes them the primary
bring-up instrument:

| Pattern | Meaning |
|---------|---------|
| `led[8]` toggling at 1 Hz, `led[7:0]` counting | hello world running (this repository) |
| all LEDs off | FPGA unconfigured, or design not driving the pins, or wrong bank voltage |
| all LEDs on | design drives all pins high at reset (check reset polarity) |
| one LED stuck | pin constraint typo or LED damaged |

A design that drives the LEDs from a free-running counter proves three things at once:
the clock is alive, configuration succeeded, and the pin constraints are correct.

## Electrical

- The LED bank is 1.8 V; do not assign 3.3 V LVCMOS to these pins.
- Current is limited on the board; no external resistors are needed.
- The same pins are used on the OCP variant with different LED designators, so the FPGA
  constraints are portable between variants.
