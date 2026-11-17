# 03 — PCIe endpoint bring-up

> Status: reported (prior art), not yet reproduced in this lab

## Goal

Replace the Microsoft bitstream with a design that enumerates as a PCIe endpoint with a
BAR you control, then poke it from the host.

## Design

Start from the upstream `Projects/PCIe/PCIe1` project in
[tow3rs/catapult-v3-smartnic-re](https://github.com/tow3rs/catapult-v3-smartnic-re). It contains:

- `Qsys.qsys` — Arria 10 PCIe hard IP, Gen3 x8, BAR0 64 KB, PIO Avalon slave.
- `Catapult_v3_PCIe1.v` — top level wiring `pcie1_rx[7:0]`, `pcie1_tx[7:0]`,
  `pcie1_perstn`, `clk_pcie1`, and `leds[7:0]` driven by the PIO output.
- `Constraints.sdc` — 100 MHz `clk_u59`, PCIe refclk, pin locations in the `.qsf`.

Change the vendor/device ID to something unique (e.g. `0x1234:0x0001`) before installing a
driver, so it does not collide with the Altera dev-kit IDs.

## Steps

1. Clone the upstream repository next to this one and copy `Projects/PCIe/PCIe1` into
   `projects/02_pcie_pio/`.
2. Open Platform Designer and regenerate `Qsys.qsys` for Quartus 25.1 (the IP version
   changes; expect migration warnings).
3. Compile, program the `.sof`, then **cold boot or rescan PCI**:

```powershell
# Windows
Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'PCI\VEN_1234*'
```

```bash
# Linux
sudo lspci -nn | grep 1234
sudo setpci -s 02:00.0 COMMAND=0x6      # enable memory + bus master
```

4. Map BAR0 and write a pattern:

```bash
sudo apt install pcimem
sudo pcimem /sys/bus/pci/devices/0000:02:00.0/resource0 0x0 w 0x000000AA
```

The lower 8 bits of the PIO register drive the LEDs: you should see `10101010`.

## What success proves

- PCIe hard IP trains at the expected width/speed.
- The host can enumerate and access a BAR.
- The FPGA design is running (LEDs reflect host writes).

## Gotchas

- The HIP needs `npor=1'b1` and the dedicated 100 MHz refclk.
- After reprogramming, the host may cache the old config space. A reboot is the reliable
  way to re-enumerate.
- If the link trains at Gen1 only, check the refclk and the `LTSSM` state in the HIP debug
  registers.
- Windows requires a signed driver; use Linux VFIO or the Altera PCI API driver from the
  thinkoco repo for Windows.

## Next

Once BAR access works, the reference `AVMM_DMA_Windows_GUI.zip` (see
[thinkoco/microsoft_fpga](https://github.com/thinkoco/microsoft_fpga))
demonstrates DMA to DDR4.
