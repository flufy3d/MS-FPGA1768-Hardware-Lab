# Bring-up

Step-by-step procedures, in the order they should be attempted on a new card. Each page
ends with "what success looks like" and "if it fails".

| Step | Page | Time | Risk |
|------|------|------|------|
| 1 | [JTAG scan](01-jtag-scan.md) | 5 min | none |
| 2 | [Hello world (LEDs)](02-hello-world.md) | 30 min | none (volatile load) |
| 3 | [PCIe endpoint](03-pcie-endpoint.md) | 2-4 h | low (host driver risk during BAR access) |
| 4 | [DDR4](04-ddr4.md) | 2-4 h | low |

Do them in order: each step proves a layer that the next one relies on.

## Prerequisites

- Card installed in a slot with **12 V auxiliary power** connected.
- Airflow over the FPGA and retimer.
- Quartus installed with Arria 10 support.
- On-board USB programmer working (`jtagconfig` lists the cable).

## Golden rule

**Do not write the configuration flash until you have a backup of the original image.**
Everything in steps 1-4 uses volatile `.sof` downloads and is fully reversible with a power
cycle.
