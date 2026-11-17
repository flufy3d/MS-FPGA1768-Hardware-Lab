# USB-Blaster plugin for the on-board FT232H

These binaries make Quartus' `jtagd` recognise the card's on-board FT232H programmer.
They are mirrored from [thinkoco/microsoft_fpga](https://github.com/thinkoco/microsoft_fpga)
(`usb_blaster/` folder). See `reference/thinkoco-microsoft-fpga/NOTICE.md`.

| File | Target | Destination |
|------|--------|-------------|
| `jtag_hw_microsoft_catapult.dll` | Windows x64 | `<quartus>\bin64\` |
| `libjtag_hw_microsoft_catapult.so` | Linux x86_64 | `<quartus>/linux64/` |
| `Microsoft Catapult v3  USB Blaster 安装.docx` | — | original install notes (Chinese, with screenshots) |

## Install (Windows)

Use the helper (elevated):

```powershell
.\scripts\install-usb-blaster-plugin.ps1 -QuartusRoot "D:\altera_pro\25.1\quartus"
```

Or manually copy the DLL into `<quartus>\bin64` and restart `jtagd`.

## Verify

```
> jtagconfig
1) Microsoft Catapult v3 (64) [USB-0]
 02E060DD   10AX115
```

## Notes

- The DLL exports a single function, `get_supported_hardware`, which is the contract for a
  Quartus `jtag_hw_*` plugin.
- It links against the FTDI D2XX driver (`ftd2xx.dll`); install the FTDI driver first.
- The upstream document is kept for reference. Its steps are reproduced in English in
  [../../docs/toolchain/onboard-usb-blaster.md](../../docs/toolchain/onboard-usb-blaster.md).
- Do not install more than one MPSSE plugin at a time — `jtagconfig` will list duplicate
  cables and may open the wrong one.
