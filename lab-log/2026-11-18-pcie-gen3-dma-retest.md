# 2026-11-18 — Gen3 x8 DMA build retest

- **Date:** 2026-11-18
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99-E, BIOS 1801, PCIe link speed **Gen3**, Above 4G Decoding enabled;
  card in `PCIEX16_2` (x8). Card cooling: passive server copper heatsink, **no fan**.
  Card power: PCIe slot only, no auxiliary 12 V.
- **Toolchain:** Quartus Prime Pro 25.1.0.129
- **Goal:** with the BIOS now allowing Gen3, re-test the 2026-11-17 Gen3 x8
  `Avalon-MM with DMA` build: does it train Gen3 x8, and is its 64-bit prefetchable BAR
  assigned with Above 4G Decoding on?

## What was done

1. Rebuilt the design from commit `7f6f7b1` unchanged (except removing the
   non-existent `use_dynamic_design_example` parameter) in a scratch directory outside the
   repository, with `scripts\env.ps1` loaded.
2. Programming attempt at 17:58 failed: `Error (213013): Programming hardware cable not
   detected`. The FT232H, the PCI function and the factory image `1414:B204` were all
   `Present=False`.

## Observations

### The 2026-11-17 DMA design never connected the register bank

With the environment loaded, `qsys-script` reports for `make_qsys.tcl` at `7f6f7b1`:

```
Error: add_connection pcie.rxm_bar0 pio_a.s1: No interface named pcie.rxm_bar0.
... (same for pio_b, pio_sum, pio_counter, pio_id and the five baseAddress settings)
```

In `Avalon-MM with DMA` mode with the internal descriptor controller the HIP has no
`rxm_bar0` (`altera_pcie_a10_hip_interfaces.tcl` line 806: the port is removed when
`include_dma_hwtcl && internal_controller_hwtcl`). BAR0 belongs to the DMA controller
and is 512 bytes (`bar0_address_width_mux_hwtcl = 9`). The generated system still built:

| Item | Value |
|------|-------|
| Generated HIP | `bar0_type = bar0_64bit_prefetch_mem`, `bar2_type = bar2_64bit_prefetch_mem`, `lane_rate = gen3`, `link_width = x8` |
| Compile | 0 errors, timing met, 20m41s |
| Quartus checksum | `0x307522FB` — identical to the 2026-11-17 build |
| SHA-256 | `2F3429953FCC4B216C0DC7E318B33DB4E7C041D4FAAC4B6425FF96A9015787D1` |

The identical checksum means the 2026-11-17 bitstream had the same defect: even with a
BAR assigned, the `A + B` registers were unreachable, and the Windows driver would have
skipped the 512-byte BAR0 (it ignores memory resources smaller than 0x1000).

### Card power loss, twice in one day

| Last seen working | Found missing | Card state |
|-------------------|---------------|------------|
| about 16:17 | 16:40 | idle |
| 17:16 (factory image, Gen3 x8) | 17:58 | idle |

Both times the card had been powered and idle for roughly 20–40 minutes, and only an AC
power cycle brought the FT232H back. **Hypothesis:** thermal shutdown, because the passive
heatsink has no airflow in this desktop. Not yet verified (no temperature reading).

### Retest after the AC power cycle

Card powered at 18:15. Programmed the rebuilt `.sof` directly with `quartus_pgm`
(18:20–18:29, `Configuration succeeded`, 9m03s), then an elevated `pnputil /scan-devices`.

| Property | Value |
|----------|-------|
| `DEVPKEY_PciDevice_MaxLinkSpeed` / `MaxLinkWidth` | 3 / 8 |
| `DEVPKEY_PciDevice_CurrentLinkSpeed` / `CurrentLinkWidth` | **3 / 8 (Gen3 x8)** |
| `DEVPKEY_PciDevice_BarTypes` | `0x20000` |
| Problem code / status | 10 / `0xC000000D` |
| Allocated resources | none |

### Warm reboot with the bitstream loaded

`shutdown /r` at 18:33, Windows up at 18:34. The FPGA kept its configuration
(`1172:E003` present, FT232H present, no `1414:B204`).

| Property | Value |
|----------|-------|
| Link | Gen3 x8 |
| `DEVPKEY_PciDevice_BarTypes` | `0x20000` |
| Problem code / status | 10 / `0xC000000D` (`STATUS_INVALID_PARAMETER`) |
| Root port `8086:2F04` `LogConf\BootConfig` | memory window start `0x0000383FFFE00000`, length `0x100000` |
| Endpoint `LogConf\BasicConfigVector` | 1st memory requirement: length `0x200`, range `0x0000383FFFE00000`–`0x0000383FFFE001FF`; a further memory requirement has length `0` |

Reading of the raw registry data (decoded by hand, so treat the field decoding as
`reported`, not verified with a PCI tool):

- With Above 4G Decoding on, the BIOS gave the root port a 1 MB window above 4 GB and
  placed the 512-byte BAR0 at its start. Address space is therefore **not** what blocks
  the device after a boot-time enumeration.
- The device still fails to start with `STATUS_INVALID_PARAMETER`.
- **Hypothesis:** the second 64-bit prefetchable BAR (BAR2) is malformed. `rxm_bar2` is
  not connected in this system, so its Avalon address width is 0, and the requirement
  list shows a zero-length memory range. Verify by disabling BAR2
  (`bar2_type_hwtcl "Disabled"`) or connecting a slave to `rxm_bar2`, or by reading the
  config space with `lspci -vvv`.

## Result

**Partial.**

- **Gen3 x8 verified** with a lab-built bitstream (Arria 10 HIP, `wrala_hwtcl = 0`) on PCB
  `M1003380-005`, 2026-11-18, once the BIOS link speed is set to Gen3. The link stays
  Gen3 x8 across a warm reboot and the FPGA keeps its volatile configuration.
- The device does not start (problem code 10) after a hot scan or after a warm reboot.
  After the warm reboot the BIOS had assigned a 64-bit window, so the earlier conclusion
  "the host cannot assign a 64-bit prefetchable BAR" is not supported; a malformed BAR2
  in this design is the leading hypothesis.
- The `A + B` test was not attempted; the register bank is unreachable in this bitstream
  (see above).

## Artifacts

- Rebuilt `.sof`: `E:\Projects\fpga1768-gen3dma\projects\02_pcie_pio\output_files\pcie_pio.sof`
  (outside the repository), SHA-256 above.
