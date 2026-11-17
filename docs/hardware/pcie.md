# PCI Express interfaces

> Status: reported (prior art tested both interfaces), link state on this card verified
> Last verified: 2026-11-17

## Overview

The Longs Peak card exposes **two independent x8 Gen3 endpoints on one x16 edge connector**:

| Interface | Edge lanes | FPGA serial pins | PERST# | Reference clock |
|-----------|-----------|------------------|--------|-----------------|
| PCIe #1 | 0-7 | `AN33/AN32` … `AH31/AH30` | `AW16` | U57 → `AN29/AN28` (100 MHz) |
| PCIe #2 | 8-15 | `AE32/AE33` … `Y39/Y38` | `AV18` | U56 → `AE29/AE28` (100 MHz) |

Each interface is a full Arria 10 PCIe hard IP block (`pcie_a10_hip_1`, `pcie_a10_hip_2` in
the reference designs). They are **not** bifurcated by a switch: lanes 0-7 go to HIP #1 and
lanes 8-15 go to HIP #2 on the PCB.

Consequences:

- In an x8 slot only PCIe #1 can train.
- In an x16 slot both endpoints appear, provided the motherboard supports x8/x8
  bifurcation (most X99/X299 boards do for the CPU slots; check the manual).
- The two endpoints have separate device IDs in the reference designs but share the same
  vendor ID.

## Observed link on this card

```
$ lspci -nn  (equivalent)
02:00.0 Class ff00: Microsoft Corporation Device b204 (rev 00)
        Subsystem: Microsoft Corporation Device 0400
        LnkCap: Port #0, Speed 8GT/s, Width x8
        LnkSta: Speed 5GT/s (downgraded), Width x8
```

- The card trains at **Gen2 x8** with the Microsoft bitstream that was in flash.
- `MaxLinkSpeed` reports Gen3, `MaxLinkWidth` x8, so the endpoint itself is x8 Gen3.
- Windows has no driver for vendor `0x1414`, device `0xB204`, class `0xFF` — this is
  expected; it is not a standard class code.

## Reference design

`reference/catapult-v3-smartnic-re/Projects/PCIe/PCIe1` (and `PCIe2`, `PCIe_Dual`) contains
a minimal design:

- Arria 10 PCIe HIP configured as Gen3 x8, 256-byte payload, BAR0 64 KB.
- A PIO (parallel I/O) Avalon slave mapped into BAR0; the lower 8 bits drive the LEDs.
- Vendor/device ID `1172:E003` (Altera development kit IDs) by default — change them to
  something unique before installing a driver.

The `.qsys` file contains the HIP configuration; the top-level Verilog shows the exact pin
connections for `rx_in[7:0]`, `tx_out[7:0]`, `refclk`, `npor` and `pin_perst`.

## Host-side software

Two options:

1. **Altera PCI API driver** (Windows) — included in the thinkoco repo under
   `reference/thinkoco-microsoft-fpga/demos/.../2.0 Altera PCIE Driver/`. It exposes BARs
   through a `windrvr6`-style API. Works with the reference design's Altera vendor ID.
2. **Linux `uio_pci_generic` / VFIO** — bind the endpoint to `vfio-pci`, map BAR0 into
   user space, read/write the PIO registers. This is the recommended path for new work
   because it does not need a signed kernel driver.

There is a third option used by the OpenCL BSP: a custom DMA driver (`acl_boards_catapult_iii.inf`)
that only matches the BSP's own IDs. It is not useful outside OpenCL.

## Things that bite

- `npor` must be tied high (1'b1) in the design; only `pin_perst` comes from the slot.
- The HIP needs `refclk` at 100 MHz. Feeding it from `clk_u59` "works" for enumeration in
  some designs but violates the PCIe reference clock specification — use the dedicated
  `clk_pcie1/2` pins.
- Do not enable spread-spectrum clocking unless the slot provides it.
- The edge connector carries 12 V and 3.3 V; the card also has an auxiliary 6-pin 12 V
  input. An x8 slot alone may not supply enough current for the FPGA at full load.
- After loading a new bitstream that changes the PCIe configuration space, a **cold reboot**
  (or at least a PCI rescan) is needed before the host sees the new IDs.

## Debug aids

- `lspci -vv` / RWEverything: check link speed, width, BAR sizes.
- Arria 10 HIP has a built-in "HIP debug" Avalon master; the OpenCL BSP exposes a CRA
  window that can be read over BAR0 to verify the HIP is alive.
- If the link does not train at all, check `PERST#` polarity and that `npor` is released
  after the reference clock is stable.
