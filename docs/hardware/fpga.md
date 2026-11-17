# FPGA, configuration and JTAG identity

> Status: verified (IDCODE, device acceptance) / reported (part equivalence)
> Last verified: 2026-11-17

## The part number puzzle

The FPGA lid reads:

```
ALTERA  Arria 10
10AXF40GAA
P CFCAW1637A
KOREA
```

`10AXF40GAA` is **not** a catalogue part number. It is a Microsoft-specific ordering code.
Evidence collected by the community:

| Claim | Evidence |
|-------|----------|
| It is a 10AX115 class device (1.15 M logic elements) | Quartus device properties, resource utilisation of known designs, [@rombik_su thread](https://twitter.com/rombik_su/status/1341125492884332549) |
| It is equivalent to `10AX115N4F40E3SG` | same thread; same package (F40 = 40 mm FBGA) and speed/temperature grade |
| Quartus accepts `10AXF40AA` as a device name | all reference `.qsf` files use `set_global_assignment -name DEVICE 10AXF40AA` |
| OpenCL BSP uses `10ax115s2f45i1sg` as device model | `board_spec.xml` of the Microsoft Catapult V3 BSP (note F45, not F40) |

In this lab Quartus Prime Pro 25.1 with the Arria 10 device package compiles for
`10AXF40AA` (see the hello-world build log). If a future Quartus release drops the
non-standard name, use `10AX115N4F40E3SG` — the pinout is identical.

JTAG IDCODE is the reliable way to identify the silicon:

```
IDCODE 0x02E060DD   ← Arria 10 10AX115
```

`jtagconfig` prints this after a successful scan. Anything else (e.g. `0x02E0...` variants
or a second device in the chain) means you are looking at a different board or a damaged
chain.

## Configuration scheme

| Item | Setting |
|------|---------|
| Scheme | Active Serial x4 (ASx4) |
| Config clock | 100 MHz (`ACTIVE_SERIAL_CLOCK FREQ_100MHZ`) |
| Config device | `EPCQL1024` (1 Gb) — `quartus_cpf -c -d EPCQL1024 -s 10AXF40AA -m ASx4` |
| Flash part | Micron `N25Q00AA` (1 Gb, 128 MB), U19 |
| MSEL / config pins | hard-wired for ASx4; `DATA0..3` released as user I/O after configuration |

A `.sof` file configures the FPGA **volatilely** over JTAG: power-cycling the card loses
the design and the card returns to the image stored in flash. A `.jic` (or the OpenCL
`.bin` → `.jic` flow) writes the flash and survives power cycles.

The OpenCL BSP's `bringup.bat` documents the vendor flow:

```bat
quartus_cpf -c -d EPCQL1024 -s 10AXF40AA -m ASx4 top.sof top.jic
quartus_pgm -m jtag -c 1 -o "p;Catapult_v3_sfl.sof"   :: load Serial Flash Loader
quartus_pgm -m jtag -c 1 -o "p;top.jic"               :: write flash through the SFL
```

The SFL (Serial Flash Loader) is a small bitstream that turns the FPGA into a JTAG-to-QSPI
bridge so that `quartus_pgm` can erase and program the configuration flash. A copy is kept
in [../../firmware/prebuilt/Catapult_v3_sfl.sof](../../firmware/prebuilt/Catapult_v3_sfl.sof)
(344 KB, from the Microsoft OpenCL BSP).

> **Warning.** Writing the config flash destroys the only known-good image on a card that
> arrived with a Microsoft bitstream. Dump it first
> ([instructions](../toolchain/build-and-program.md#backing-up-the-configuration-flash)).

## Dedicated pins and dual-purpose pins

- `CLKUSR` is fed by the 100 MHz oscillator U59 and is usable as a normal clock input
  after configuration. Reference designs use it as the "board clock" (`clk_u59`, pin
  `AP20`).
- `CONF_DONE` is on `AT13` (not user-assignable).
- `nCONFIG`, `nSTATUS`, `CONF_DONE` are driven by the FT232H as well, which is how the
  on-board programmer can force a reconfiguration without a power cycle.
- After ASx4 configuration, `DATA0..3` become regular I/O. The reference QSF therefore
  contains:

```tcl
set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "ACTIVE SERIAL X4"
set_global_assignment -name USE_CONFIGURATION_DEVICE ON
set_global_assignment -name ACTIVE_SERIAL_CLOCK FREQ_100MHZ
set_global_assignment -name RESERVE_DATA0_AFTER_CONFIGURATION "USE AS REGULAR IO"
```

## Device resources (10AX115 class)

| Resource | Count |
|----------|-------|
| Logic elements | 1,150,000 |
| ALMs | 427,200 |
| M20K blocks | 2,713 |
| DSP blocks | 1,518 |
| Transceivers | 48 (24 per side) |
| Package | FBGA-1517, 40 mm |

Source: `arria-10-product-table.pdf` in [../../hardware/datasheets/](../../hardware/datasheets/).
Numbers are for the 10AX115 die; the exact binning of `10AXF40GAA` is unknown but the
OpenCL BSP fits a full 32770 ALM accelerator region, consistent with a full 115 die.

## Timing / speed grade

- Reference designs are constrained for 100 MHz system clock, 266.667 MHz DDR4 reference
  and 644.53125 MHz transceiver reference.
- The OpenCL BSP targets `10ax115s2f45i1sg` (speed grade 2). Community designs compile at
  speed grade 2 as well (`10AXF40AA` defaults to speed grade 2 in Quartus).
- Treat Fmax numbers from other boards with suspicion: thermal headroom on this passively
  cooled card is limited.
