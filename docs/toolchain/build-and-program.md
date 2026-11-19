# Building and programming

> Status: verified for the hello-world project (2026-11-17)

## Build

```powershell
. .\scripts\env.ps1
quartus_sh --flow compile projects\01_hello_world\hello_world -c hello_world
```

or with the wrapper:

```powershell
.\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf
```

Outputs land in `projects\01_hello_world\output_files\`:

| File | Meaning |
|------|---------|
| `hello_world.sof` | SRAM object file — volatile JTAG configuration |
| `hello_world.fit.rpt` | fitter report: pin assignments, resource use |
| `hello_world.sta.rpt` | timing report (should be "Timing requirements met") |
| `hello_world.map.rpt` | synthesis report |

The first compile of an Arria 10 design takes several minutes; later compiles reuse the
database in `db/`.

## Program (volatile)

```powershell
quartus_pgm -m jtag -o "p;projects\01_hello_world\output_files\hello_world.sof"
```

`p` = program, `;` separates operation from file. The design is lost on power cycle; the
card returns to whatever is in its configuration flash.

Verify the JTAG chain first:

```powershell
jtagconfig
# 1) Microsoft Catapult v3 (64) [USB-0]
#  02E060DD   10AX115
```

## Measured timings (lab card, 2026-11-17)

| Step | Time |
|------|------|
| Full compile, hello world (23 ALMs) | 6m00s |
| `.sof` size | 35,860 KB (fixed by the 10AX115 die, not by the design) |
| JTAG download at 5 MHz TCK | 8m58s |
| JTAG download at 10 MHz TCK (projected) | ~4-5 min — **superseded**, see below |
| JTAG download at 10 MHz TCK, 36.8 MB `.sof` (measured 2026-11-18, PCB `M1003380-005`) | 8m28s |

Doubling TCK to 10 MHz saved only about 30 s against 8m59s at 5 MHz the same day, so TCK
is not the main limit of the on-board programmer. See
[lab-log/2026-11-18-pcie-hot-update.md](../../lab-log/2026-11-18-pcie-hot-update.md).

The JTAG clock is set by the plugin config file `<quartus>\bin64\msftdi.cfg`:

```
channel=0
frequency=5000000
```

Delete the file to use the plugin default (10 MHz).

## Program the configuration flash (persistent) — read this first

Writing flash is a one-way trip unless you have a backup. The procedure uses a **Serial
Flash Loader** (SFL) bitstream, which makes the FPGA act as a JTAG-to-QSPI bridge:

```powershell
# 1. generate a .jic for the on-board 1 Gb flash
quartus_cpf -c -d EPCQL1024 -s 10AXF40AA -m ASx4 hello_world.sof hello_world.jic

# 2. load the Serial Flash Loader (volatile)
quartus_pgm -m jtag -o "p;firmware\prebuilt\Catapult_v3_sfl.sof"

# 3. write the flash through the SFL
quartus_pgm -m jtag -o "p;hello_world.jic"
```

After a power cycle the FPGA configures itself from flash and the design survives.

### Offline conversion check (2026-11-19, no flash write)

Before writing anything, the conversion itself was validated on the lab host with Quartus
Prime Pro 25.1 patch 0.36, without touching the card:

| Input | Output | Result |
|-------|--------|--------|
| `shell.sof` (37 MB) | `.jic` | **OK**, 134 217 969 bytes, 18 s |
| `shell.sof` | `.pof` | OK, 134 217 946 bytes, 15 s |
| `.hex` (raw dump, 1 MB slice) | `.jic` | `Error (213023): Input file … is incompatible with selected output programming file type` |
| `.hex` | `.pof` | failed, exit 3 |
| `.pof` | `.jic` | failed, exit 3 |

The `.jic` header names `10AXF40AA` and `EPCQL1024`, and the file is exactly 128 MiB plus
241 bytes of header, i.e. the whole 1 Gb flash. SHA-256 of that file:
`A355CA324DFAF45D5972A5CDB97E963C484624829E30D20711331463F6810A02`.

**Consequence: there is no `.hex → .jic` flow.** `quartus_cpf` accepts only a `.sof` as
input for `.jic`/`.pof`, so the raw flash backup (`flash_a.bin`, 128 MB) cannot be turned
back into a programming file with Quartus. Restoring the factory image after a flash write
would need an external SPI programmer on U19, or a design that writes raw bytes through
the serial flash loader. Until one of those exists, treat a flash write as irreversible:
the backup protects against losing the data, not against losing the card's ability to boot
the Microsoft image.

### Verified write (2026-11-19, lab card)

The write itself was then performed and validated end to end — see
[lab-log/2026-11-19-flash-program.md](../../lab-log/2026-11-19-flash-program.md):

| Step | Command | Result |
|------|---------|--------|
| 1 | `quartus_pgm -m jtag -o "p;firmware\prebuilt\Catapult_v3_sfl.sof"` | 08:08, `Configuration succeeded` |
| 2 | `quartus_pgm -m jtag -o "p;...\shell.jic"` | 07:49, silicon ID `0x21`, erase + program, 0 errors |
| 3 | full AC power cycle, no JTAG | Windows enumerated `1172:E003` by itself |

So the sequence above works on this board with one extra detail: the `.jic` write also
accepts the SFL loaded beforehand, and the resulting flash boots the shell at power-up with
both DDR4 channels calibrated. Note that the `.jic` is a container, not a raw image — a
`flash-dump` afterwards does not reproduce the last 128 MB of the `.jic` byte for byte,
even though the design boots correctly.



### Backing up the configuration flash

**Do this before writing anything.** The card shipped with a Microsoft bitstream that is
not published anywhere; lose it and you cannot get it back.

`quartus_pgm` cannot read flash directly, but the SFL exposes the QSPI device and Quartus
can dump it in the programmer GUI (*Tools → Programmer → Examine/Blank check* is not a
read-back). The practical options are:

1. **Read the flash with an external programmer** (clip or desolder U19). Most reliable.
2. **Use the SFL + a custom TCL/script** to issue QSPI read commands through the Arria 10
   remote update IP. Requires a design that instantiates the `altera_serial_flash_loader`
   in "read" mode — not provided out of the box.
3. **Keep the original `.sof`**: if you only need a working design, save the current
   bitstream by reading the flash with method 1 and keep the dump in a safe place.

A fourth option now exists in this lab: `projects/05_shell` exposes a read-only window into
the flash, and `fpga1768 flash-dump FILE` reads all 128 MB (about 3 minutes). Two runs on
2026-11-19 produced identical dumps (SHA-256 `4C727C31…9326C`). That gives a verified
backup of the data, but see the conversion table above: Quartus cannot turn that dump back
into a `.jic`, so the dump alone does not make a flash write reversible.

This repository keeps `firmware/prebuilt/Catapult_v3_sfl.sof` (from the Microsoft OpenCL
BSP) and links to the OpenCL base `.sof`, but **not** a dump of this specific card's flash.

## Reading back the JTAG IDCODE

```powershell
jtagconfig --enum
```

or, from the Quartus TCL console:

```tcl
set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
puts $dev
```

## Common failures

| Message | Meaning |
|---------|---------|
| `Error (209015): Can't configure device. Expected JTAG ID code 0x...` | Wrong device in project (F40 vs F45) or chain problem |
| `Error: Device 1 is not responding` | FT232H present but FPGA unpowered / nCONFIG held low |
| `Error (213005): File is not a valid SOF` | Corrupt or wrong-family `.sof` |
| `Warning: The device is already configured` | Harmless; the programmer reconfigures it |
| Design loads but nothing happens | Wrong pin constraints, or the design relies on a clock that is not present |

## Timing sign-off

For anything beyond a blinking LED, check `sta.rpt`. The reference designs close timing at
100 MHz easily; the DDR4 and transceiver interfaces have their own constraints generated by
the IP. Never ship a design with "Timing requirements not met" to the card and then blame
the hardware.
