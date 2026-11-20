# PCI Express interfaces

> Status: reported (prior art tested both interfaces); link state and PCIe #1 BAR0 MMIO
> verified on this card
> Last verified: 2026-11-20

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
- **Update (2026-11-18, verified):** the Gen2 limit was the host BIOS. On the lab's ASUS
  X99-E (BIOS 1801, card in `PCIEX16_2`, linked x8) the PCIe link speed **Auto** capped the
  CPU root ports at Gen2; with **Gen3** selected the factory image trains at **Gen3 x8**
  (`CurrentLinkSpeed` 3, `CurrentLinkWidth` 8). See
  [lab-log/2026-11-18-pcie-gen3-bios.md](../../lab-log/2026-11-18-pcie-gen3-bios.md).
- Windows has no driver for vendor `0x1414`, device `0xB204`, class `0xFF` — this is
  expected; it is not a standard class code.

### Lab endpoint (2026-11-17)

`projects/02_pcie_pio` enumerated as `1172:E003` at `02:00.0`:

| Property | Value |
|----------|-------|
| LnkCap | 8 GT/s, x8 |
| LnkSta | 5 GT/s (Gen2), x8 |
| Windows | problem code 28 (no driver) |
| BAR0 | 64 KB, 64-bit prefetchable, not assigned after a hot PnP scan (superseded, see below) |

The endpoint is Gen3-capable; this slot trained it at Gen2 x8, the same as the factory
image. A host bugcheck during the BAR0 attempt left the card unpowered. See
[lab-log/2026-11-17-pcie-pio.md](../../lab-log/2026-11-17-pcie-pio.md).

### Lab endpoint (2026-11-18) — verified

Status: verified 2026-11-18 on PCB `M1003380-005`, ASUS X99 host, Windows 10.

The 64-bit prefetchable BAR0 above was never assigned (Windows problem code 10). The
design was changed to a plain Avalon-MM HIP (Gen2 x8, 128-bit) with a 32-bit
non-prefetchable BAR0:

| Property | Value |
|----------|-------|
| LnkSta | 5 GT/s (Gen2), x8 |
| `DEVPKEY_PciDevice_BarTypes` | `0x100` (was `0x20000` for the 64-bit prefetchable BAR) |
| BAR0 | 32-bit non-prefetchable, 64 KB, assigned `0xFAFF0000`–`0xFAFFFFFF` |
| Interrupt | IRQ 16 |
| Windows | status OK (problem 0) with `pcie_bar.sys` |
| BAR0 test | `A + B` passed (`SUM 0x23456789`) |

"Above 4G Decoding" was not tested, so whether this host can assign a 64-bit
prefetchable BAR with that BIOS option is `unknown`. See
[lab-log/2026-11-18-pcie-pio-bar0-32bit.md](../../lab-log/2026-11-18-pcie-pio-bar0-32bit.md).

### Lab endpoint at Gen3 x8 (2026-11-18) — verified

Status: verified 2026-11-18 on PCB `M1003380-005`, ASUS X99-E (BIOS link speed Gen3,
Above 4G Decoding on), Windows 10.

`projects/03_pcie_gen3` sources (`Avalon-MM with DMA`, external descriptor controller,
BAR2 disabled):

| Property | Value |
|----------|-------|
| LnkSta | 8 GT/s (Gen3), x8 |
| `DEVPKEY_PciDevice_BarTypes` | `0x10000` |
| BAR0 | 64-bit prefetchable, 64 KB, assigned `0x383FFFE00000` |
| Windows | status OK (problem 0) with `pcie_bar.sys` |
| BAR0 test | `A + B` passed (`SUM 0x23456789`) |

Conditions that mattered on this host:

- The 64-bit BAR is assigned only when the device is present at boot: load the `.sof`,
  then **warm reboot**. A hot `pnputil /scan-devices` left the device at problem code 10.
- The 2026-11-17 DMA build failed for design reasons, not host reasons: with the internal
  DMA descriptor controller the HIP has no `rxm_bar0`, and its enabled but unconnected
  BAR2 is the probable cause of the failed start (hypothesis; fixed together with the
  controller change, not isolated).

See [lab-log/2026-11-18-pcie-gen3-bar0-temp.md](../../lab-log/2026-11-18-pcie-gen3-bar0-temp.md)
and [lab-log/2026-11-18-pcie-gen3-dma-retest.md](../../lab-log/2026-11-18-pcie-gen3-dma-retest.md).

### DMA throughput at Gen3 x8 (2026-11-20) — verified

Status: verified 2026-11-20 on PCB `M1003380-005`, same host as above, with
`projects/07_dma` (hard IP data movers, descriptor engine in the FPGA, driver 1.1
common buffers above 4 GB).

| Fact | Value | Status |
|------|-------|--------|
| Negotiated MPS / MRRS | 256 / 512 bytes (device supports MPS 256) | verified (configuration space) |
| Host → FPGA (read DMA), 64 MB | 7.105 GB/s | verified |
| FPGA → host (write DMA), 64 MB | 7.065 GB/s | verified |
| Both at once, 64 MB | 7.018 + 6.516 = 13.031 GB/s | verified |
| HIP core clock on this host | 255.02 MHz (2.5 × refclk), so the slot's refclk is about 102.0 MHz | verified (counter vs host timer); cause (BIOS BCLK) is a hypothesis |

See [lab-log/2026-11-20-dma.md](../../lab-log/2026-11-20-dma.md).

### Updating the logic over PCIe (2026-11-18) — verified

Status: verified 2026-11-18 on PCB `M1003380-005`, same host as above.

| Fact | Value | Status |
|------|-------|--------|
| Hard IP used by PCIe #1 | `HSSIGEN3X8PCIEHIP_L0` (bottom-left HIP, the CvP-capable one on flip-chip packages) | verified (fitter report) |
| CvP update mode | not available on Arria 10 (CvP initialization only) | reported ([Intel KB 000074842](https://www.intel.com/content/www/us/en/support/programmable/articles/000074842.html)) |
| Partial reconfiguration over PCIe | works: PR controller (`alt_pr`, internal host) on BAR0, 13 MB PR bitstream in about 8 s through the test driver; link, BAR0 and Windows device state unchanged | verified |

`projects/04_pcie_hot_update` replaced its compute persona `A + B` → `A − B` → `A + B`
without JTAG and without a reboot. Only the base image needs JTAG (volatile `.sof`); no
flash image is involved. See
[lab-log/2026-11-18-pcie-hot-update.md](../../lab-log/2026-11-18-pcie-hot-update.md).

## Reference design

The upstream [catapult-v3-smartnic-re](https://github.com/tow3rs/catapult-v3-smartnic-re)
repository has `Projects/PCIe/PCIe1` (and `PCIe2`, `PCIe_Dual`) with a minimal design:

- Arria 10 PCIe HIP configured as **Gen2 x8 (128-bit)** in the upstream Qsys
  (`wrala_hwtcl = 7`), 128-byte payload, BAR0 64 KB. The HIP is Gen3-capable; the
  reference design does not select Gen3.
- A PIO (parallel I/O) Avalon slave mapped into BAR0; the lower 8 bits drive the LEDs.
- Vendor/device ID `1172:E003` (Altera development kit IDs) by default — change them to
  something unique before installing a driver.

`projects/02_pcie_pio` in this repository uses `wrala_hwtcl = 0` (Gen3 x8, 256-bit) and
`interface_type_hwtcl = "Avalon-MM with DMA"`. Its BAR0 register bank returns `A + B`
instead of driving LEDs.

The `.qsys` file contains the HIP configuration; the top-level Verilog shows the exact pin
connections for `rx_in[7:0]`, `tx_out[7:0]`, `refclk`, `npor` and `pin_perst`.

## Host-side software

Two options:

1. **Altera PCI API driver** (Windows) — included in the thinkoco repo under
   in [thinkoco/microsoft_fpga](https://github.com/thinkoco/microsoft_fpga)
   (`demostrations/.../2.0 Altera PCIE Driver/`). It exposes BARs
   through a `windrvr6`-style API. Works with the reference design's Altera vendor ID.
2. **Linux `uio_pci_generic` / VFIO** — bind the endpoint to `vfio-pci`, map BAR0 into
   user space, read/write the PIO registers. This is the recommended path for new work
   because it does not need a signed kernel driver.

There is a third option used by the OpenCL BSP: a custom DMA driver (`acl_boards_catapult_iii.inf`)
that only matches the BSP's own IDs. It is not useful outside OpenCL.

## Things that bite

- `npor` must be tied high (1'b1) in the design; only `pin_perst` comes from the slot.
- The slot's refclk is not always exactly 100 MHz: on the lab's ASUS X99-E it measured
  about 102.0 MHz (2026-11-20), so the HIP core clock ran at 255 MHz instead of 250 MHz
  and the link at about 8.16 GT/s. Measure clock-derived rates against the host timer.
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
