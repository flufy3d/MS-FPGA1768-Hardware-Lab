# Links

> Status: reported · Checked 2026-11-17

## Repositories

| Link | What |
|------|------|
| <https://github.com/tow3rs/catapult-v3-smartnic-re> | Catapult v3 pinouts, BOM, Quartus projects |
| <https://github.com/thinkoco/microsoft_fpga> | USB-Blaster plugin, PCIe/DDR4 demo, OpenCL BSP |
| <https://github.com/tow3rs/jtag-mpsse-blaster> | generic FTDI MPSSE → Quartus JTAG plugin |
| <https://github.com/j-marjanovic/jtag-quartus-ft232h> | FT232H JTAG for Quartus (Linux) |
| <https://github.com/wirebond/catapult_v2_pikes_peak> | Catapult v2 reverse engineering |
| <https://github.com/MorriganR/Microsoft-Catapult-DDR3L-pinout> | Catapult v2 DDR3 pinout |
| <https://github.com/j-marjanovic/otma-fpga-bringup> | Catapult v2 bring-up |

## Articles and blogs

| Link | What |
|------|------|
| <https://j-marjanovic.io/stratix-v-accelerator-card-from-ebay.html> | Bringing up a Catapult v2 card |
| <https://www.nextplatform.com/2020/02/03/vertical-integration-is-eating-the-datacenter-part-two/> | Photos of the OCP Catapult v3 board |
| <https://forums.servethehome.com/index.php?threads/microsoft-project-olympus-dual-epyc-7003-boards.52730/> | Where surplus cards are discussed |

## Papers

| Link | What |
|------|------|
| <https://www.microsoft.com/en-us/research/uploads/prod/2018/03/Azure_SmartNIC_NSDI_2018.pdf> | "A Cloud-Scale Acceleration Architecture" (NSDI 2018) |
| <https://indico.cern.ch/event/822126/contributions/3500184/attachments/1906428/3148591/Catapult_FastML_Fermilab_2019.pdf> | Catapult / FastML overview (Fermilab 2019) |
| <https://www.opencompute.org/wiki/Server/ProjectOlympus> | OCP Project Olympus |
| <https://www.opencompute.org/documents/microsoft-ocs-v2-tray-mezzanine> | Microsoft OCS v2 tray mezzanine spec |
| <http://files.opencompute.org/oc/public.php?service=files&t=5803e581b55e90e51669410559b91169&download&path=/SmartNIC%20OCP%202016.pdf> | Microsoft SmartNIC OCP 2016 slides |

## Vendor documents

| Link | What |
|------|------|
| <https://www.intel.com/content/www/us/en/docs/programmable/> | Arria 10 documentation |
| <https://www.altera.com/downloads/quartus> | Quartus Prime downloads |
| <https://ftdichip.com/drivers/d2xx-drivers/> | FTDI D2XX driver |
| <https://ftdichip.com/wp-content/uploads/2021/08/CDM212364_Setup.zip> | FTDI CDM driver package |
| <https://www.ti.com/product/DS250DF810> | Retimer product page |

## Tools that help

| Tool | Use |
|------|-----|
| [RWEverything](https://rweverything.com/) | Windows PCI config space / BAR peek and poke |
| [pcimem](https://github.com/billfarrow/pcimem) | Linux BAR access from userspace |
| [flashrom](https://www.flashrom.org/) | External SPI flash dump (with a clip) |
| [Saleae / sigrok](https://sigrok.org/) | Logic analysis of I2C/JTAG if you need it |
| `quartus_stp` | Signal Tap / in-system sources and probes |

## Datasheets in this repo

All under [hardware/datasheets/](../../hardware/datasheets/):

- Arria 10: `a10_datasheet`, `a10_overview`, `arria-10-product-table`, `ug_arria10_xcvr_phy`,
  `a10_registermap.xlsx`
- DDR4: `H5AN4G6NAFR-UHC`
- Flash: `25Q128FV`, `n25q_32mb_3v`, `n25q_1gb_1_8v`
- Clocking: `REN_XU-Family`, `REN_9DBV0241`, `REN_9DBV0441`
- Power: `lm25066`, `MP2953B`, `MP86905`, `csd17570q5b`
- Misc: `ds250df810` (retimer), `FT232H`, `TMP411`, `M24128`, `pca9535`,
  `sn74avc4t774` (level shifter), SEARAY connector
