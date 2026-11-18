# 2026-11-18 — PCIe Gen2 limit traced to the BIOS link-speed setting

- **Date:** 2026-11-18
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99-E (Rev 1.xx), BIOS 1801 (2017-08-11), i7-5820K, Windows 10 Pro 19045.
  FPGA card in `PCIEX16_2` (root port `8086:2F04`, bus 0 dev 2), RTX 3070 in `PCIEX16_1`
  (root port `8086:2F08`)
- **Toolchain:** none (host-side check only); card running the factory image from flash
- **Goal:** find out why the card trains at Gen2 x8 although it advertises Gen3 x8.

## What was done

1. Compared two different bitstreams already logged: the factory image (`1414:B204`) and
   the Gen3 x8 DMA build of `02_pcie_pio` both advertised 8 GT/s x8 and trained at
   5 GT/s x8. Same result with different designs pointed at the host.
2. Checked another device on another CPU root port. With the BIOS PCIe link speed at
   **Auto**, the RTX 3070 in `PCIEX16_1` reported (in performance state P0):

   ```
   nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.gen.max,pcie.link.gen.gpumax,pcie.link.gen.hostmax,pcie.link.width.current,pstate
   2, 2, 4, 2, 16, P0
   ```

   `hostmax = 2`: the root port itself advertised Gen2, so this was not a Gen3
   equalisation failure (that would leave the advertised maximum at Gen3).
3. In the BIOS the slots showed `PCIEX16_1 Linked as x16` and `PCIEX16_2 Linked as x8`.
   The PCIe link speed was **Auto**; it was changed to **Gen3**. Above 4G Decoding was
   enabled at the time of this check; whether it was already enabled during the earlier
   64-bit BAR test ([2026-11-18-pcie-pio-bar0.md](2026-11-18-pcie-pio-bar0.md)) is
   `unknown`. Saved, then AC power cycle.
4. Re-checked both devices. The FPGA card was running the factory image.

## Observations

| Device | BIOS Auto | BIOS Gen3 |
|--------|-----------|-----------|
| RTX 3070, `PCIEX16_1` | Gen2 x16, `hostmax` 2 | **Gen3 x16**, `hostmax` 3 |
| FPGA factory image `1414:B204`, `PCIEX16_2` | Gen2 x8 | **Gen3 x8** |

- Factory image after the change: `DEVPKEY_PciDevice_MaxLinkSpeed` 3,
  `CurrentLinkSpeed` 3, `CurrentLinkWidth` 8, `BarTypes` `0x100`; Windows problem
  `CM_PROB_FAILED_INSTALL` (no driver, expected).
- Windows does not expose link properties for the `8086:2F04`/`2F08` root ports
  (`DEVPKEY_PciDevice_*Link*` are empty), so the GPU's `hostmax` was the only
  non-elevated view of the root-port capability.

## Result

**Success.** On this ASUS X99-E with BIOS 1801, the PCIe link-speed setting **Auto**
limits the CPU slots to Gen2. Setting it to **Gen3** lets the card train at Gen3 x8 with the
factory image. Neither the card nor the board is Gen2-limited in hardware.

Not yet tested: a lab bitstream at Gen3. The current `02_pcie_pio` build is Gen2 x8 by
design (`wrala_hwtcl = 7`).

## Artifacts

- No bitstream (factory image).
- `nvidia-smi` and `Get-PnpDeviceProperty` output quoted above.
