# 2026-11-18 — Gen3 x8 BAR0 test passed; die temperature without airflow

- **Date:** 2026-11-18
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99-E, BIOS 1801, PCIe link speed **Gen3**, Above 4G Decoding enabled;
  card in `PCIEX16_2` (x8); Windows 10 Pro 19045, Secure Boot off, test signing on.
  Card cooling: passive server copper heatsink, **no fan**. Card power: PCIe slot only.
- **Toolchain:** Quartus Prime Pro 25.1.0.129; `pcie_bar.sys` v1.0.0.2; `msftdi.cfg` 5 MHz
- **Goal:** (1) get the `A + B` test to pass at Gen3 x8, fixing the two defects found in
  [2026-11-18-pcie-gen3-dma-retest.md](2026-11-18-pcie-gen3-dma-retest.md); (2) read the
  FPGA die temperature to test the thermal-shutdown hypothesis.

## What was done

1. Built a new variant of the BAR0 design (now `projects/03_pcie_gen3`; at the time of the
   test it was built outside the repository under the name `pcie_pio`):
   - `Avalon-MM with DMA`, `wrala_hwtcl = 0` (Gen3 x8, 256-bit);
   - `internal_controller_hwtcl = 0`, which gives the HIP an `rxm_bar0` master again
     (`select_design_example_hwtcl "DMA"` is required for generation to succeed);
   - BAR2 disabled; BAR0 64-bit prefetchable, 64 KB (`bar0_address_width_mux_hwtcl = 16`);
   - Arria 10 temperature sensor IP (`altera_temp_sense`) read through a new PIO at
     BAR0 + `0x50`, one conversion about every 0.17 s.
2. Compile: 0 errors. The first timing analysis failed hold on 10 endpoints (the sensor's
   `tempout` bits, clocked by its internal 1 MHz `altera_ts_clk`, sampled in `clk_100`).
   Added `set_false_path` to the two synchroniser inputs and re-ran `quartus_sta` only:
   timing met, `.sof` unchanged.
3. AC power cycle; Windows booted at 19:18:26. Programmed the `.sof` directly with
   `quartus_pgm` 19:23–19:32 (`Configuration succeeded`, 8m59s at 5 MHz).
4. Warm reboot (`shutdown /r`) at 19:33 so the BIOS enumerates the 64-bit BAR; Windows up
   at 19:33:53. The FPGA kept its configuration.
5. 19:37: ran the test client with `--write`, then logged the temperature register every
   5 s (`--temp 5`).
6. 19:46: shut the PC down on purpose because of the temperature (the card had not dropped).

## Observations

### Gen3 x8 BAR0 test

| Property | Value |
|----------|-------|
| Link | Gen3 (8.0 GT/s) x8 |
| `DEVPKEY_PciDevice_BarTypes` | `0x10000` |
| Problem code | 0 (status OK) |
| BAR0 | `0x383FFFE00000`, length `0x10000`, mapped |

```
IDs:    1172:E003
BAR0:   0x383FFFE00000 length 0x10000 mapped=1
ID:     0x50434945
Writing A=0x12345678, B=0x11111111 ...
SUM:    0x23456789 (expected 0x23456789)
COUNTER:0xC2F9F12E then 0xC2F9F286 (changing)
A+B test PASSED.
```

- The host does assign a 64-bit prefetchable BAR above 4 GB when the device is present at
  boot (warm reboot after the JTAG load) and Above 4G Decoding is on. A hot
  `pnputil /scan-devices` alone did not (earlier log).
- With BAR2 disabled the device starts. This supports the earlier hypothesis that the
  unconnected BAR2 was what made Windows fail the start (problem 10,
  `STATUS_INVALID_PARAMETER`); it was not tested in isolation.

### Die temperature, no airflow

Sensor code converted with the vendor formula `degC = code * 693 / 1024 - 265`. The
formula and the conversion handshake were **not** cross-checked against another
thermometer on this card; treat absolute values as `reported`. The conversion counter in
the register advanced on every sample and the latched and raw codes agreed.

| Time | Minutes after power-on (19:18) | Code | Die temperature |
|------|-------------------------------|------|-----------------|
| 19:37 | 19 | 519 | 86.2 °C |
| 19:39 | 21 | 522 | 88.3 °C |
| 19:41 | 23 | 527 | 91.7 °C |
| 19:43 | 25 | 531 | 94.4 °C |
| 19:45 | 27 | 535 | 97.1 °C |
| 19:46:29 | 28 | 539 | 99.8 °C |
| 19:46:49 | 28.5 | 541 | 101.1 °C (last sample) |

- About **1.4 °C per minute**, still rising when the PC was shut down. 113 samples,
  no read errors.
- The design was running Gen3 x8 with the host idle; no FPGA workload beyond the HIP.
- On the previous run the card dropped 36 minutes after power-on. Extrapolating this
  slope gives roughly 110 °C at 36 minutes. That shutdown temperature is an
  **extrapolation**, not a measurement: this run was stopped before the card dropped.

## Result

**Success** for the Gen3 x8 BAR0 test: first lab bitstream to pass `A + B` at Gen3 x8 with
a 64-bit BAR.

**Thermal hypothesis strongly supported, not closed:** without airflow the die passes
100 °C within 29 minutes of power-on. The power losses seen earlier the same day
(20–40 minutes after power-on) fit a thermal shutdown. Do not power this card for more
than a few minutes without a fan.

## Artifacts

- Bitstream tested (built outside the repository, top-level `pcie_pio`):
  Quartus checksum `0x3072B911`,
  SHA-256 `AB429A71CBF2EC9BD2C2C7A57EC8187C9BEE0116BBDB46225AC45E9E4C96ECDA`.
  `projects/03_pcie_gen3` contains the same sources with the entity and system renamed;
  that project had not been compiled yet when this log was written.
- Temperature log and presence log (lab host, not committed):
  `E:\Projects\fpga1768-gen3v2\temp-nofan.log`, `card-uptime.log`.
