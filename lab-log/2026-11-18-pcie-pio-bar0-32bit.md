# 2026-11-18 — PCIe BAR0 endpoint: 32-bit BAR0, A+B test passed

- **Date:** 2026-11-18
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99 (i7-5820K), Windows 10 Pro 19045, card in CPU slot at `02:00.0`
  (root port `PCI\VEN_8086&DEV_2F04`); Secure Boot off, test signing on
- **Toolchain:** Quartus Prime Pro 25.1.0.129, `jtag_hw_microsoft_catapult.dll`;
  `pcie_bar.sys` v1.0.0.2 (KMDF 1.31, `oem61.inf`)
- **Goal:** apply fix 2 from [2026-11-18-pcie-pio-bar0.md](2026-11-18-pcie-pio-bar0.md)
  (32-bit non-prefetchable BAR0) and finish the BAR0 `A + B` test.

## What was done

1. **Found the build broken.** The top-level `pcie_pio_sys/synth/pcie_pio_sys.v` (generated
   earlier in the day) instantiated `pcie_pio_sys_pcie_1`, `pcie_pio_sys_clk_102`, … for which
   no `.ip` files existed, so synthesis failed with 9 × `Error (16045)`. `qsys-script`'s
   `save_system` writes `_1` variants when an `.ip` of the same name already exists. The
   committed `.ip` files were unchanged (still `Avalon-MM with DMA`).
2. **Found why IP generation "only worked in the GUI".** `qsys-generate`, `qsys-script`,
   `quartus_ipgenerate` and the `qsys-edit` GUI all failed with
   `Error: Unknown device part 10AXF40AA` /
   `"Device family" "Arria 10" is out of range: "Cyclone 10 GX"` because `QUARTUS_ROOTDIR`
   was not set. After `. .\scripts\env.ps1` in the same session the command-line flow works;
   no GUI step is needed. Recorded in `AGENTS.md` §7 and `docs/troubleshooting.md`.
3. **Changed the HIP in `make_qsys.tcl`:** `interface_type_hwtcl = Avalon-MM`,
   `wrala_hwtcl = 7` (Gen2 x8, 128-bit, 250 MHz, same as the upstream PCIe1 reference),
   `bar0_type_hwtcl = 32-bit non-prefetchable memory`, BAR1/BAR2 disabled. Removed the
   derived `pf0_bar*` assignments and the non-existent `use_dynamic_design_example`.
4. **Found the BAR0 size is derived.** In plain Avalon-MM mode the HIP sizes BAR0 from the
   address span behind `rxm_bar0` (`slave_address_map_0_hwtcl`), not from
   `bar0_address_width_hwtcl`. With only the PIO bank (0x00–0x4F) the generated HIP had
   `bar0_address_width_mux_hwtcl = 7` (128 bytes). The Windows driver skips memory
   resources smaller than 0x1000, so a **32 KB scratch RAM at 0x8000** was added; the
   generated HIP then had `bar0_address_width_mux_hwtcl = 16` (64 KB) and
   `bar0_type = "bar0_32bit_non_prefetch_mem"`, `bar1_type`/`bar2_type` = disabled.
5. Regenerated: deleted `ip/pcie_pio_sys/` and `pcie_pio_sys/`, ran
   `qsys-script --script=make_qsys.tcl --quartus-project=pcie_pio.qpf` (exit 0), then
   `quartus_ipgenerate pcie_pio -c pcie_pio --run_default_mode_op` (0 errors).
6. Compiled with `scripts\build.ps1`: 0 errors, timing met, 17m09s.
7. First programming attempt failed with `Error (213013): Programming hardware cable not
   detected`; the FT232H was `Present=False`. An AC power cycle (> 15 s) restored it.
8. Programmed the `.sof` directly with `quartus_pgm -m jtag -o "p;…"` (no `jtagconfig`
   beforehand): `Configuration succeeded`, 8m38s (16:42:46 – 16:51:24).
9. Ran an elevated `pnputil /scan-devices` (hot scan, no `/remove-device` needed), then
   `pcie_bar_test.exe` and `pcie_bar_test.exe --write`.

## Observations

| Item | Before (Gen3 x8 256-bit DMA) | After (this build) |
|------|------------------------------|--------------------|
| Quartus checksum | `0x307522FB` | `0x3070E554` |
| `DEVPKEY_PciDevice_BarTypes` | `0x20000` | `0x100` |
| Windows problem code | 10 | 0 (status OK) |
| Allocated memory | none | `0xFAFF0000`–`0xFAFFFFFF` (64 KB), IRQ 16 |
| Link | Gen2 x8 | Gen2 x8 |

`pcie_bar_test.exe --write` output:

```
IDs:    1172:E003
BAR0:   0xFAFF0000 length 0x10000 mapped=1
ID:     0x50434945
A:      0x00000000
B:      0x00000000
SUM:    0x00000000
COUNTER:0x53E41EE4 then 0x53E42044 (changing)

Writing A=0x12345678, B=0x11111111 ...
SUM:    0x23456789 (expected 0x23456789)
COUNTER:0x53E4F382 then 0x53E4F4EA (changing)

A+B test PASSED.
```

- The same hot scan that never produced a BAR for the 64-bit prefetchable design assigned a
  32-bit window immediately. "Above 4G Decoding" (fix 1 in the previous log) was not tested.
- During programming, `Get-Process jtagserver` reports CPU = 0 from a non-elevated session
  because `jtagserver` runs as SYSTEM. `Win32_Process` (`KernelModeTime`, `UserModeTime`)
  does show it busy. Use that, not `Get-Process`, to judge whether programming is running.
- The scratch RAM at 0x8000 was not exercised by `pcie_bar_test.exe`.

## Result

**Success.** BAR0 is assigned, the driver maps it, and the FPGA computes `A + B`
correctly over PCIe MMIO. The root cause of problem code 10 was the 64-bit prefetchable
BAR0 (and BAR2) requested by the `Avalon-MM with DMA` HIP configuration.

## Artifacts

- `projects/02_pcie_pio/output_files/pcie_pio.sof` (not committed)
  - SHA-256 `AE896719379F8DB92BE0C1302F4704E80C32ED4B4134166A8593AD3D35EB81BD`
  - Quartus checksum `0x3070E554`, 36,812,070 bytes
- Build: 3,798 ALMs, 7,888 registers, 31 RAM blocks, 9 PLLs, 8/48 HSSI;
  worst-case setup slack +0.222 ns, hold +0.015 ns
