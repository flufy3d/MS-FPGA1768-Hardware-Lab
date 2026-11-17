# Scripts

PowerShell helpers. They are intentionally small and readable; if a script grows complex,
move the logic into a documented tool under `docs/toolchain/` instead.

| Script | Purpose |
|--------|---------|
| `env.ps1` | Dot-source to locate Quartus and add `bin64` to `PATH` |
| `build.ps1` | Compile a `.qpf` with `quartus_sh --flow compile`, print timing + SHA-256 |
| `program.ps1` | Load a `.sof` over JTAG (default) or a `.jic` into flash (`-Flash`) |
| `jtag-scan.ps1` | Run `jtagconfig`, check for IDCODE `0x02E060DD` |
| `install-usb-blaster-plugin.ps1` | Copy the FT232H JTAG plugin into `<quartus>\bin64` (admin) |
| `board-status.ps1` | Show PCIe endpoint, link state, FTDI device and JTAG chain |
| `jtag_mpsse_idcode.py` | Read the JTAG IDCODE directly through FTDI D2XX/MPSSE (no Quartus) |
| `jtag_bitbang_idcode.py` | Early bit-bang experiment (kept for reference; FT232H readback is unreliable) |
| `jtag_probe_pins.py` | Pin/TDO probe (diagnostic, see troubleshooting) |

## Usage

```powershell
# once per shell
. .\scripts\env.ps1

# everyday
.\scripts\board-status.ps1
.\scripts\jtag-scan.ps1
.\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf
.\scripts\program.ps1 -Sof projects\01_hello_world\output_files\hello_world.sof
```

## Conventions

- Scripts must not require a specific Quartus install path; use `env.ps1`.
- Destructive operations require an explicit flag (`-Flash`) and print a warning.
- Exit with a non-zero code on failure (`throw` is enough).
- No interactive prompts except documented confirmations.
- Keep them compatible with Windows PowerShell 5.1 (the default on Windows 10).
