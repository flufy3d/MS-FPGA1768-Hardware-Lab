# Mellanox NIC ASIC

> Status: reported; exact variant on this card **unconfirmed** (see below)

## What it is

A Mellanox ConnectX ASIC (U12) provides the conventional Ethernet path of the SmartNIC.
It is an independent PCIe endpoint with its own firmware, and it is connected to the FPGA
through four 25 Gb/s transceiver lanes plus a handful of side-band signals.

| Item | PCIe variant (Longs Peak) | OCP variant (Dragontails Peak) |
|------|---------------------------|-------------------------------|
| Part (BOM) | `MT27524A1-FCCF-GE` | `MT27711A0-FDCF-GE` |
| Part (per upstream README) | ConnectX-4 Lx | ConnectX-3 Pro |
| NIC PCIe | OCuLink connector on the card | SAMTEC connector (second bifurcation) |
| FPGA ↔ NIC clock | Y6 = 644.53125 MHz | Y6 = 156.25 MHz |
| FPGA lanes | `H31/H30` … `B35/B34` (4 × TX/RX) | same |

**The two sources disagree.** The BOM notes label `MT27524A1` as "PCIe card" (which would
be a ConnectX-3 Pro part) while the upstream README says the PCIe card has a ConnectX-4 Lx.
The photo of the card in this repository shows a Mellanox package whose marking should be
read with a magnifier. Treat the exact model as an open question until confirmed.

## Why it matters

The NIC is **not** usable as a normal network card on this board: its PCIe lanes go to an
OCuLink connector that is normally not connected in a PC. It only becomes useful if you:

- cable the OCuLink port to a host (a second machine or a bifurcated slot), or
- ignore the NIC entirely and use the FPGA's own QSFP port.

The FPGA ↔ NIC transceiver link is also not documented; the community could not establish a
link between the two (see upstream README "Connectivity between the FPGA and the Mellanox
NIC"). Possible causes: unidentified enable/reset pins, or a dead ASIC on surplus cards.

## Side-band signals

- I2C bus #3 (through U32/J9 header and level shifters) reaches the NIC management bus;
  addresses `0x48` and `0x1F` were observed by the community.
- `U22` is an `SN74AVC4T774` level shifter between FPGA and NIC, with three direction pins
  and one output enable (`u22_io[3:0]`, `u22_dir[2:0]`, `u22_cs_n` on `AV27`).
  The default Microsoft bitstream drives `u22_io[3]` as an output and reads the others.
- Several GPIOs are routed to the NIC but their function is unknown.

## Practical advice

1. On a surplus card, first check whether the NIC heatsink gets warm — if the ASIC does not
   power up, the FPGA link work is pointless.
2. Do not drive `u22_dir` or the NIC reset lines before you know their polarity; the level
   shifter is between two powered domains and can be damaged by contention.
3. If you only want an Arria 10 dev board, you can ignore U12 completely. It does not
   interfere with the FPGA.

## Pin summary

| Signal | FPGA pins |
|--------|-----------|
| NIC XCVR RX | `H31/H30`, `G33/G32`, `F31/F30`, `E33/E32` |
| NIC XCVR TX | `C37/C36`, `B39/B38`, `A37/A38`, `B35/B34` |
| U22 I/O | `H21`, `H22`, `L19`, `AV24` |
| U22 direction | `J20`, `J18`, `J21` |
| U22 chip select | `AV27` |
