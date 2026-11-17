# Mirrored upstream project — quick index

Upstream: <https://github.com/thinkoco/microsoft_fpga> · see [NOTICE.md](NOTICE.md)

## What is here

| Path | Content |
|------|---------|
| `Catapult_v3_RISCV/` | Complete Quartus project with a RISC-V E203 soft core, RAM/ROM IP and a PLL. A good "real" design to study. |
| `2.0 Altera PCIE Driver/` | Windows driver (`.inf`/`.sys`) for the Altera PCIe reference design, used by the DDR4 demo |
| `AVMM_DMA_Windows_GUI.zip` | Host GUI + source for the Avalon-MM DMA test |
| `0.0 工具和环境.txt` | Original tool/environment notes (Chinese) |

## What is upstream but not mirrored

| Path | Why not |
|------|---------|
| `Microsoft Catapult V3 OpenCL 18.1 BSP/` | ~436 MB, includes 36 MB bitstreams; still available upstream |
| `demostrations/Catapult_v3 PCIE1_DDR4_TEST/1.0 FPGA configuration/*.sof` | 36 MB prebuilt bitstreams |
| `demostrations/.../PCIE1_DDR4_FPGA.7z` | archived Quartus project, large |

To use the OpenCL BSP, clone upstream:

```bash
git clone --depth 1 https://github.com/thinkoco/microsoft_fpga
```

The BSP requires **Quartus 18.1** and the Intel FPGA SDK for OpenCL 18.1; it will not
compile with 25.1 without significant work. It is useful mainly as documentation of the
board's memory map and PCIe configuration.

## The RISC-V demo

`Catapult_v3_RISCV` is the most interesting artifact here for someone who wants to run code
on the FPGA without writing a lot of RTL:

- E203 (SiFive-style) RV32 core, ~10k LUTs.
- On-chip RAM (32/64 KB) and a clock divider.
- Debug via the LEDs / a memory-mapped register.
- Compiles for `10AXF40AA` and fits easily.

It has no UART: the program's output must be observed through the LEDs or by adding a
peripheral. Still, it proves the toolchain and gives you a CPU on the card.

## Driver notes

The Altera PCI API driver (`altera_pcie_win_driver`) is an old WDF driver signed for
Windows 7/10 x64. It only matches the Altera development-kit vendor/device IDs used by the
reference design. On modern Windows you may need to disable driver signature enforcement or
use Linux + VFIO instead.
