# 2026-11-18 — PCIe BAR0 endpoint: programming and driver load

- **Date:** 2026-11-18
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99 (i7-5820K), Windows 10 Pro 19045, card in CPU slot at `02:00.0`
  (root port `PCI\VEN_8086&DEV_2F04`)
- **Toolchain:** Quartus Prime Pro 25.1.0.129, `jtag_hw_microsoft_catapult.dll`,
  `msftdi.cfg` channel 0 at 5 MHz; WDK 10.0.22621; VS 2022
- **Goal:** finish the BAR0 `A + B` compute test that was left pending on 2026-11-17.

## What was done

1. Confirmed Secure Boot off (`Confirm-SecureBootUEFI` = False) and enabled test
   signing with `driver\enable-testsigning.ps1`; `bcdedit` then reported
   `testsigning Yes`.
2. Found that the pre-built driver targeted **KMDF 1.33** while this host has
   **1.31** (`Wdf01000.sys` file version `1.31.19041.1`). Retargeted `build.ps1`
   and `pcie_bar.inf` to 1.31, rebuilt and re-signed. Commit `d292d8b`.
3. Two full AC power cycles were needed. After the 2026-11-17 host bugcheck the
   FT232H stayed `Present=False` and only an AC cycle restored it.
4. Programmed `pcie_pio.sof` over JTAG. The first two attempts failed for
   toolchain reasons (see below); the third succeeded:

   ```
   Info (209060): Started Programmer operation at 13:19:43
   Info (209017): Device 1 contains JTAG ID code 0x02E060DD
   Info (209007): Configuration succeeded -- 1 device(s) configured
   Elapsed time: 00:08:44
   ```

5. Staged the KMDF driver and let PnP bind it to `1172:E003`.
6. Bisected the driver when the device failed to start: reduced
   `EvtDeviceAdd` to a bare `WdfDeviceCreate` and made `PrepareHardware`
   unconditionally succeed. The device still failed to start.

## Observations

### Quartus JTAG failures, and two wrong diagnoses

Programming failed twice before succeeding, and both failures looked like a
hang rather than an error.

- `Error (209037): JTAG Server can't access selected programming hardware`
  appears within seconds when something enumerated the cable immediately
  before `quartus_pgm`. `scripts\program.ps1` itself calls `jtagconfig` to list
  cables, so it reproduces this on its own.
- The next attempts printed nothing for 8–14 minutes while `jtagserver` sat at
  100 % of one core. That was read as a deadlock and the process was killed
  twice. The third attempt showed the truth: `jtagserver` burns one core for the
  whole **8m44s** program, and `quartus_pgm` buffers its output, so the log stays
  at 0 bytes until it exits. A real program and a stuck one both look idle.
- The actual error was only obtained by letting the run finish:

  ```
  Error (209042): Application Quartus Programmer on 127.0.0.1 is using the target device
  Elapsed time: 00:08:41
  ```

  `Started` and `Ended` in the same second, with the elapsed time before them,
  means nothing was programmed: a previously killed programmer still held the
  device. Restarting the JTAG Server alone did **not** clear it; `pnputil
  /restart-device` on the FT232H did.

The counters that actually discriminate are `jtagserver` CPU together with its
`OtherTransferCount`. See `docs/troubleshooting.md`.

### Driver: KMDF version

The driver as committed on 2026-11-17 declared and linked KMDF 1.33 on a host
that only has 1.31. That would have failed `WdfDriverCreate` on load. Now 1.31
in both `build.ps1` and `pcie_bar.inf`, and the KMDF co-installer confirms it:

```
HKLM\SYSTEM\CurrentControlSet\Services\PCIEBAR\Parameters\Wdf
  WdfMajorVersion = 1
  WdfMinorVersion = 31
```

### Endpoint start failure

The endpoint enumerates correctly and the driver binds:

```
PCI\VEN_1172&DEV_E003&SUBSYS_00000000&REV_00\4&2A43D483&0&0010
  FriendlyName  PCIe BAR0 Test Endpoint (1172:E003)
  DriverInfPath oem61.inf   DriverVersion 1.0.0.2
  ProblemCode   10 (CM_PROB_FAILED_START)
  ProblemStatus 0xC0000001 (STATUS_UNSUCCESSFUL), sometimes 0xC000000D
```

The device has **no allocated resources at all**:

- `Win32_PnPAllocatedResource` returns no entry for the device;
- the devnode `LogConf` has no `Mem` value;
- `DEVPKEY_PciDevice_BarTypes` = `0x20000`.

`sc start PCIEBAR` succeeds and `Win32_SystemDriver` reports `State=Running`, so
`DriverEntry` and `WdfDriverCreate` are fine. Reducing `EvtDeviceAdd` to a bare
`WdfDeviceCreate` and forcing `PrepareHardware` to succeed did **not** change
problem code 10. The driver is therefore not the cause; Windows never gets far
enough to hand it a BAR.

Supporting evidence that the slot itself is fine: with the factory Microsoft
image the same function starts normally (problem 28, "no driver"), so the root
port does have working windows. What changed is the BAR the design requests.

### Root port

Only this card is on bus 2 behind `PCI\VEN_8086&DEV_2F04`. Restarting the root
port, and disabling plus re-enabling it, both re-enumerated the endpoint but did
not produce a BAR.

## Result

**Partial.** The endpoint is programmed and enumerating, and the driver now
loads. The BAR0 compute test is still blocked: Windows does not assign a memory
BAR to the hot-added endpoint, so `PrepareHardware` has nothing to map.

This is the same symptom recorded on 2026-11-17 ("BAR0 not assigned after the
hot scan"), now with the driver ruled out as a cause.

## Next

The design requests a **64-bit prefetchable** BAR0 (`make_qsys.tcl`:
`bar0_type_hwtcl "64-bit prefetchable memory"`, `pf0_bar0_prefetchable_hwtcl 1`).
Two candidate fixes, cheapest first:

1. Enable **Above 4G Decoding** in the BIOS (X99: Advanced → PCI Subsystem
   Settings), then AC power cycle and re-program the `.sof`. Gives the root
   port a large 64-bit prefetchable window.
2. Change BAR0 to **32-bit non-prefetchable** in `make_qsys.tcl`, regenerate the
   system, rebuild (about 24 min) and re-program (about 9 min). A 32-bit
   non-prefetchable window always exists, so this does not depend on the
   motherboard.

## Artifacts

- `projects/02_pcie_pio/output_files/pcie_pio.sof`
  - SHA-256 `E592CEC22FDE5B0190E6E285B4BC090C09E7FDB47447B8B287A1A5ABE6F02706`
  - Quartus checksum `0x307522FB`
  - programmed over JTAG in 8m44s at 5 MHz
- `projects/02_pcie_pio/driver/build/pcie_bar.sys` (KMDF 1.31, v1.0.0.2),
  test-signed, catalog verified with `signtool verify /pa`
  - SHA-256 `BBFEDAEC8D8830DB5A948B56F0BBE484544871DC7D1F89565ACBFB4110E3A8B1`
- Commits: `d292d8b`, `ba6841c`, `6485f80`

## Addendum — Defender

Windows Defender quarantined a rebuilt `pcie_bar.sys` during this session
(threat `2147890691`) and blocked `signtool`, `inf2cat` and `pnputil` from
reading it. Excluding the repository path and the driver file path cleared it.
`inf2cat` then failed with `Unable to retrieve the subject GUID` while the file
was blocked, which is worth remembering before blaming the INF.

## Correction — later the same day

The "Result" above is superseded. Fix 2 (32-bit non-prefetchable BAR0) was applied later
on 2026-11-18: Windows assigned a 64 KB window at `0xFAFF0000`, the device started (problem
code 0) and `pcie_bar_test.exe --write` passed (`SUM 0x23456789`). The root cause of problem
code 10 was the 64-bit prefetchable BAR0/BAR2 forced by the `Avalon-MM with DMA` HIP mode.
Fix 1 (Above 4G Decoding) was not tested. See
[2026-11-18-pcie-pio-bar0-32bit.md](2026-11-18-pcie-pio-bar0-32bit.md).
