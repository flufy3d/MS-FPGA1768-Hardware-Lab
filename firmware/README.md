# Firmware

Known-good bitstreams that are small enough to keep in git.

| File | Size | Origin | Purpose |
|------|------|--------|---------|
| `prebuilt/Catapult_v3_sfl.sof` | 344 KB | Microsoft Catapult V3 OpenCL BSP 18.1 | Serial Flash Loader: turns the FPGA into a JTAG→QSPI bridge so `quartus_pgm` can write the configuration flash |

## Serial Flash Loader

The SFL is **not** a user design. It is loaded volatilely and then used as a bridge:

```powershell
quartus_pgm -m jtag -o "p;firmware\prebuilt\Catapult_v3_sfl.sof"
quartus_pgm -m jtag -o "p;my_design.jic"
```

Without it, `quartus_pgm` cannot address the N25Q00AA behind the FPGA.

## Not stored here

- The factory Microsoft bitstream (not published, and we do not have a dump).
- 36 MB OpenCL base `.sof` images (available in the upstream thinkoco repository).
- Any `.jic` built from user designs — regenerate with `quartus_cpf`.

## Policy

Only add a binary here if it is (a) small, (b) needed for recovery or toolchain operation,
and (c) accompanied by its origin and SHA-256 in this file. See
[../AGENTS.md](../AGENTS.md) section 10.
