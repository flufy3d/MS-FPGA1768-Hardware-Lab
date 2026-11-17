# On-board USB-Blaster (FT232H) for Quartus

> Status: verified on Quartus Prime Pro 25.1 / Windows 10 (2026-11-17)

## The problem

The card's programmer is an FTDI **FT232H** (`0403:6014`). Quartus' `jtagd` only knows
about Altera VID/PID devices, so without help `jtagconfig` prints:

```
1) <no cable found>
```

The fix is a **JTAG hardware plugin DLL**: `jtag_hw_*.dll` placed in `quartus\bin64`.
`jtagd` loads every `jtag_hw_*.dll` it finds and asks each one which cables it supports.

## Install (Windows)

1. Make sure the FTDI D2XX driver is installed. Windows 10 installs it automatically; if
   not, use the official CDM package from <https://ftdichip.com/drivers/d2xx-drivers/>.
   Device Manager should show **USB Serial Converter** under *Universal Serial Bus
   controllers* (not a COM port).
2. Copy the plugin from this repo:

```powershell
# elevated shell
.\scripts\install-usb-blaster-plugin.ps1 -QuartusRoot "D:\altera_pro\25.1\quartus"
```

which is equivalent to:

```powershell
Copy-Item .\hardware\tools\usb-blaster\jtag_hw_microsoft_catapult.dll `
          D:\altera_pro\25.1\quartus\bin64\
```

3. Restart the JTAG server (or reboot):

```powershell
Stop-Process -Name jtagd -ErrorAction SilentlyContinue
```

4. Verify:

```powershell
jtagconfig
```

Expected output:

```
1) Microsoft Catapult v3 (64) [USB-0]
 02E060DD   10AX115
```

The name comes from the plugin; the IDCODE should be `0x02E060DD`.

## If the plugin does not load

The DLL in `hardware/tools/usb-blaster/` was built for 64-bit Quartus and exports
`get_supported_hardware`. It was tested with Quartus 20.1/22.1 and works with 25.1 here.

| Symptom | Cause / fix |
|---------|-------------|
| `jtagconfig` shows no cable | DLL not in `bin64`, or 32-bit DLL in 64-bit Quartus |
| `jtagconfig` crashes | ABI mismatch; try the current [jtag-mpsse-blaster](https://github.com/tow3rs/jtag-mpsse-blaster) DLL instead |
| Cable listed twice | Old `jtag_hw_*.dll` also present; remove one |
| "unable to open FTDI device" | Another process (FTDI example, Python, serial terminal) owns it |
| No FTDI device in Device Manager | Bad USB cable/port, or card unpowered |

Alternative plugins that do the same thing:

- <https://github.com/tow3rs/jtag-mpsse-blaster> — clean-room, supports FT232H/FT2232H/FT4232H
- <https://github.com/j-marjanovic/jtag-quartus-ft232h> — Linux oriented
- <https://github.com/marsohod4you/jtag_hw_mbftdi_blaster> — Marsohod FTDI blaster

Any of them can be dropped into `bin64`. Do not install more than one at a time.

## Command-line use

Once `jtagconfig` sees the cable, `quartus_pgm` uses it by default:

```powershell
quartus_pgm -m jtag -o "p;hello_world.sof"
```

If several cables are present, select by name or by index:

```powershell
quartus_pgm -c "Microsoft Catapult v3" -m jtag -o "p;hello_world.sof"
quartus_pgm -c 1 -m jtag -o "p;hello_world.sof"
```

## Linux

Copy `hardware/tools/usb-blaster/libjtag_hw_microsoft_catapult.so` to
`<quartus>/linux64/`, `chmod 755`, unload `ftdi_sio`, and add a udev rule. Details in
[linux.md](linux.md).

## Why not OpenOCD?

OpenOCD can talk to the FT232H's MPSSE, but it has no Arria 10 flash-programming support and
cannot load `.sof` files. The plugin route keeps the whole flow inside Quartus, which is
the only tool that knows the Arria 10 configuration engine.
