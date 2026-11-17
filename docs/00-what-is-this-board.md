# What is this board?

> Status: verified (identification) · Last verified: 2026-11-17

The card sold as **"Microsoft FPGA 1768"**, **"50G Accelerator Card"** or
**"MSIP-REM-MSK-1768"** is a decommissioned Microsoft datacentre accelerator from the
**Catapult v3** generation. It is the PCI Express version, codenamed **"Longs Peak"**;
the OCP mezzanine version is codenamed **"Dragontails Peak"**.

Microsoft never published a user manual for these cards. Everything below was recovered by
the community (see [prior art](reference/prior-art.md)) and, where marked, confirmed on the
card in this lab.

## Names and numbers found on the hardware

| Marking | Where | Meaning |
|---------|-------|---------|
| `Microsoft FPGA 1768` | reseller listings, eBay | marketing name used for surplus sales |
| `MSIP-REM-MSK-1768` | label | Japanese MIC radio-law marking ("REM" = removed?) |
| `M1003380-005` | PCB silkscreen, top right | Microsoft PCB / assembly number |
| `M1040125-001`, `M1037382-001`, `M1030299-001` | labels, reseller listings | Microsoft part numbers seen on the same product family |
| `NFCAA30079`, `392PA6R0D` | FPGA lid | Intel lot / date codes |
| `10AXF40GAA` | FPGA lid | non-standard Arria 10 part number (see [fpga.md](hardware/fpga.md)) |
| `MFG 2017` style date codes | various | cards were built around 2016-2018 |

The PCB also carries a jokey silkscreen `ALL LEDS AT EDGE` and the text
`AUTHORIZED ASSEMBLY` near the PCIe fingers.

## Which variant do I have?

| Feature | Longs Peak (PCIe card) — **this repo** | Dragontails Peak (OCP mezzanine) |
|---------|----------------------------------------|----------------------------------|
| Form factor | PCIe CEM x16 card | OCP 3.0 / "Project Olympus" mezzanine |
| Host PCIe | 2 × x8 on the edge connector | 2 × x8 through the SAMTEC connector |
| USB programming port | USB type-B on the bracket | micro-USB |
| Config flash | 128 MB (N25Q00AA) | 32 MB (N25Q032A) |
| NIC PCIe | OCuLink connector | SAMTEC connector, second bifurcation |
| Fan / GPIO headers | J8 fan, J11 GPIO | not populated |
| FPGA-to-NIC clock | 644.53125 MHz (Y6) | 156.25 MHz |
| FPGA variants seen | `10AXF40GAA` | `10AXF40GAA`, `10AX090N3F40E2SG`, `10AS066N3F40I2SGES` |

If your card has a PCIe edge connector, an RJ45-sized QSFP cage at the bracket and a USB-B
port, it is Longs Peak. The rest of this repository assumes that variant unless stated.

## What the card does (in the original design)

In Azure, these cards were SmartNICs: the FPGA sits between the host (PCIe) and the
network (QSFP+ 50G), with a Mellanox ASIC providing the "slow path" Ethernet and a large
DDR4 buffer for the FPGA. Microsoft's "Catapult v3" architecture used two FPGA halves per
server and a lightweight "Elastic Router" on the FPGA.

For a hobbyist the interesting parts are:

- a 10AX115-class Arria 10 FPGA with two independent PCIe Gen3 x8 hard IP blocks,
- 4.5 GB of DDR4-2133 across two 72-bit channels,
- a 50G QSFP+ port with a programmable retimer,
- a complete on-board JTAG debug path (FT232H) — no external programmer needed,
- QSPI configuration flash that can be rewritten from JTAG.

## As-found state of the card in this lab

Measured on 2026-11-17, before any modification:

```
PCI   1414:B204   subsystem 0400:1414   class 0xFF0000 (unclassified)   rev 00
      bus 2, device 0, function 0
      link: Gen2 x8 currently, Gen3 x8 capable, 128-byte payload
      BAR0: 64-bit prefetchable memory (BAR type bitmap 0x100)
      Windows: "PCI Device", problem code 28 (no driver) — expected
USB   0403:6014   FTDI FT232H, driver FTDIBUS (D2XX), location Port_#0005
```

Interpretation:

- The FPGA already contains a bitstream loaded from flash that answers PCIe with
  Microsoft's vendor ID `0x1414` and device ID `0xB204`. It is **not** the OpenCL BSP
  bitstream (which uses Altera IDs `1172:2494`) and not the community PCIe demo.
- The link only trained at Gen2 x8. This is normal for an x8 slot on an X99 board; the
  design can negotiate Gen3 when the slot and the bitstream allow it.
- The card was in a working, powered state when received. The flash was left untouched.

> **Do not assume the pre-programmed bitstream is safe to erase.** It is the only known
> "known-good" image on this particular card. Back it up over JTAG before writing flash
> (see [toolchain/build-and-program.md](toolchain/build-and-program.md#backing-up-the-configuration-flash)).

## Open questions

- Exact Microsoft part number ↔ build revision mapping (labels are often missing).
- Whether every Longs Peak carries a ConnectX-3 Pro or a ConnectX-4 Lx; BOM and README
  disagree (see [mellanox-nic.md](hardware/mellanox-nic.md)).
- Function of J12 and of the `U22` transceiver direction pins.
- Whether the second PCIe x8 interface is usable in the same slot through bifurcation.
