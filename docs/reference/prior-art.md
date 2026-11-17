# Prior art and what each project is good for

> Status: reported · Last reviewed: 2026-11-17

These cards have been recycled by several people since ~2020. This page summarises who did
what, so you do not repeat work.

## tow3rs — `catapult-v3-smartnic-re`

**The single most useful source.** Reverse-engineered both the PCIe ("Longs Peak") and OCP
("Dragontails Peak") variants.

- Full FPGA pinout (clocks, LEDs, DDR4, PCIe, QSFP, I2C, GPIO) — in
  [hardware/pinouts/](../../hardware/pinouts/).
- BOM with all identifiable ICs.
- Datasheets collected for every major part — in [hardware/datasheets/](../../hardware/datasheets/).
- Quartus projects: `LEDs`, `GoldenTop`, `I2C`, `DDR4_{Top,Bot,Dual}`, `PCIe{1,2,Dual}`,
  `Network/SuperliteII_V4_QSFP`.
- Notes on the DS250DF810 retimer programming and on the on-board FT232H.
- Upstream: <https://github.com/tow3rs/catapult-v3-smartnic-re>.

Status claimed upstream: both DDR4 channels and both PCIe interfaces tested; QSFP link
tested between two cards; FPGA↔Mellanox link **not** established.

## thinkoco — `microsoft_fpga`

Chinese engineer's work on the same card, focused on making it usable on Windows.

- **On-board USB-Blaster plugin** (`jtag_hw_microsoft_catapult.dll` / `.so`) — this is what
  makes the FT232H work with Quartus. The Windows DLL and Linux `.so` are kept in
  [hardware/tools/usb-blaster/](../../hardware/tools/usb-blaster/).
- PCIe + DDR4 demo (`Catapult_v3_PCIE1_DDR4_TEST`) with the Altera PCI API driver and a
  Windows DMA GUI.
- RISC-V E203 soft core demo (`Catapult_v3_RISCV`) — a nice "real design" example.
- **Microsoft Catapult V3 OpenCL BSP 18.1.2.277** — a complete OpenCL board package that
  runs `vector_add`, `sobel` and `mandelbrot` on the card (Windows 10, Quartus 18.1).
- Upstream: <https://github.com/thinkoco/microsoft_fpga>.

## Jan Marjanovič — Catapult v2 (previous generation)

Different board (Stratix V "Pikes Peak"/"Storey Peak"), but the best write-up of what it
takes to bring up one of these datacentre cards:

- <https://j-marjanovic.io/stratix-v-accelerator-card-from-ebay.html>
- <https://github.com/j-marjanovic/otma-fpga-bringup>
- <https://github.com/j-marjanovic/ocs-tray-mezzanine-adapter>
- <https://github.com/j-marjanovic/jtag-quartus-ft232h> — FT232H JTAG for Quartus on Linux

## wirebond / MorriganR / occamlab — Catapult v2 pinouts

- <https://github.com/wirebond/catapult_v2_pikes_peak>
- <https://github.com/MorriganR/Microsoft-Catapult-DDR3L-pinout>
- <http://virtlab.occamlab.com/home/zapisnik/microsoft-catapult-v2>

Useful for understanding Microsoft's board design conventions (I2C maps, power sequencing),
not directly applicable to v3.

## rombik_su — device identification

Twitter threads identifying `10AXF40GAA` as a 10AX115-class die:

- <https://twitter.com/rombik_su/status/1340975050665701378>
- <https://twitter.com/rombik_su/status/1341125492884332549>
- <https://twitter.com/rombik_su/status/1359232759823298564>
- <https://twitter.com/rombik_su/status/1413197085118287878>

## Microsoft / OCP documentation

- NSDI 2018 paper "A Cloud-Scale Acceleration Architecture" (Catapult v2/v3 background).
- OCP "Project Olympus" and "Microsoft SmartNIC" documents.
- Next Platform article with board photos.

Links in [links.md](links.md).

## What nobody has done yet (as of 2026)

- A public, complete register map for the DS250DF810 retimer programming guide.
- A working FPGA ↔ Mellanox XCVR link.
- A schematic (there is no public schematic for this board).
- A flash dump of the factory Microsoft bitstream (nobody published one).
- Mainline Linux driver for the card.

If you do one of these, please document it here.
