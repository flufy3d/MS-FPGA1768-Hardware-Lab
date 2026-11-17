# 01 — JTAG scan

> Status: verified on this card (2026-11-17)

## Goal

Prove that the FPGA is powered, that the on-board programmer works, and that Quartus can
talk to the TAP. No design is modified.

## Steps

1. Power the PC with the card installed. The PC may boot normally — the card is an unknown
   PCI device and does not need a driver.
2. Connect the USB-B port on the card bracket to the host.
3. Check the device appears:

```powershell
Get-PnpDevice -PresentOnly | Where-Object InstanceId -like 'USB\VID_0403&PID_6014*'
# Status OK, Class USB, FriendlyName "USB Serial Converter"
```

4. Make sure the plugin is installed ([onboard-usb-blaster.md](../toolchain/onboard-usb-blaster.md)).
5. Scan:

```powershell
jtagconfig
```

## Expected output

```
1) Microsoft Catapult v3 (64) [USB-0]
 02E060DD   10AX115
```

The cable name is defined by the plugin DLL; the important part is the **IDCODE
`0x02E060DD`** and a single device in the chain.

`jtagconfig --enum` prints a more verbose list, and `jtagconfig --version` confirms the
server is alive.

## What success proves

- FPGA core and JTAG bank are powered.
- FT232H is enumerated and its MPSSE channel works.
- The JTAG chain (TCK/TMS/TDI/TDO) is intact, including the level shifters.
- Quartus' `jtagd` can use the plugin.

## If it fails

| Symptom | Check |
|---------|-------|
| No FTDI device at all | USB cable, port, card seated, 12 V present |
| FTDI present, no cable in `jtagconfig` | plugin DLL not in `bin64`, `jtagd` not restarted |
| Cable present, no device | FPGA unconfigured is normal — the TAP is still there, so this means a chain problem. Check J5 pin 10 is not grounded by an attached header |
| `Unable to lock` / timeouts | Another process owns the FTDI device; close it |
| Two devices in chain | An external programmer is still connected (J5) |
| Wrong IDCODE | Different board / different Arria 10 variant |

## Notes

- The scan works whether or not the FPGA is configured, because the TAP is in the always-on
  periphery.
- `nCONFIG` is driven by the programmer; a scan does not disturb the running design.
- The 10-pin header J5 can be used instead of the USB port (pin 10 to GND disables the
  on-board FT232H).
