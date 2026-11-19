# 50G Ethernet: QSFP+ and the DS250DF810 retimer

> Status: reported (topology verified on photos, link not tested in this lab); retimer
> register access and CDR bypass verified 2026-11-19 (see "Retimer control from the FPGA")

## Topology

```
FPGA XCVR (4 lanes, 644.53125 MHz ref)
      │
      ▼
TI DS250DF810 8-channel retimer (U17, I2C 0x22)
      │
      ▼
QSFP+ cage (4 lanes, 40/50G, I2C 0x50 on bus #1)
```

The retimer sits **between the FPGA and the QSFP cage**. It is an 8-channel device; only
four channels are used for the network port. It performs equalisation and CDR and can be
programmed over I2C.

| Signal | FPGA pin (TX / RX) |
|--------|--------------------|
| Lane 1 | `V39/V38` (TX) ← `W33/W32` (RX) |
| Lane 2 | `U37/U36` ← `V35/V34` |
| Lane 3 | `T39/T38` ← `V31/V30` |
| Lane 4 | `R37/R36` ← `U33/U32` |
| `ModPrsL` (cable present, active low) | `AG15` |

Note the lane ordering: the FPGA's `TX_CH1..4` map to retimer channels in a non-obvious
order (see the QSFP sheet in [FPGA_Pinouts.xlsx](../../hardware/pinouts/FPGA_Pinouts.xlsx)).

## Retimer configuration (from the datasheet + TI forum)

The DS250DF810 powers up in 25 Gb/s per-lane mode. Arria 10 GX transceivers top out at
17.4 Gb/s (speed grade dependent), so for 10.3125 or 12.5 Gb/s operation the retimer must be
re-programmed or put into bypass:

| Register | Value | Effect |
|----------|-------|--------|
| `0xFF` | `0x03` | enable channel-register access, broadcast writes to all channels |
| `0x2F` (mask `0xF0`) | `0x00` | 10.3125 Gb/s per lane (41.25G aggregate) |
| | `0x10` | 10.9375 Gb/s per lane (43.75G aggregate) |
| | `0x20` | 12.5 Gb/s per lane (50G aggregate) |
| `0x1E` (mask `0xE0`) | `0x00` | CDR bypass (raw data) |
| | `0xE0` | CDR enabled (default) |

The full programming guide is not public. The values above come from TI E2E forum posts and
were used successfully by the community with an on-FPGA I2C master (status: reported).

**Correction (2026-11-19, from the datasheet SNLS513C, Table 12):** `0x1E[7:5]`
(`PFD_SEL_DATA_MUX`: `000` raw data, `001` retimed, `100` pattern generator, `111` mute)
only takes effect when channel register `0x09[5]` (`REG_BYPASS_PFD_OV`) is 1. Its default
is 0, so writing `0x1E` alone leaves the CDR's own selection (retimed) in place. The
`0x2F` rate codes are defined in the Programming Guide; the datasheet only names the field
`RATE[2:0]` (`0x2F[6:4]`, default `101`).

## Retimer control from the FPGA (verified 2026-11-19)

[projects/06_i2c_telemetry](../../projects/06_i2c_telemetry/) and `fpga1768 retimer`
([host/README.md](../../host/README.md)) on PCB `M1003380-005`, no QSFP module inserted;
[lab log](../../lab-log/2026-11-19-retimer-bypass.md).

| Item | Value on this card |
|------|--------------------|
| IDs `0xEF`–`0xF3` | `0C 31 10 00 00` (`0xF0` = `0x31`; the datasheet gives `0x32` — `unknown` why) |
| Vendor `0xFE` | `0x03` (TI) |
| Page `0xFF` / channel select `0xFC` at power-up | `0x00` / `0x00` |
| `refclk_det` (shared `0x0B[6]`) | 1 on both quads (25 MHz reference present) |
| EEPROM load (shared `0x05[4]`, `0x11`) | not attempted (`0x00`); SMBus slave mode assumed (`hypothesis`) |
| Channels 0–7, `0x09` / `0x1E` / `0x2F` | `0x00` / `0xE9` / `0x54` = datasheet power-up defaults (no configuration loaded) |
| Channels 0–7, signal detect | 0 (no module, FPGA QSFP transceivers not used by this design) |
| CDR bypass | `0x1E[7:5]` ← `000`, then `0x09[5]` ← 1: read back as raw data on all eight channels; reverted to `0x00` / `0xE9` |

The effect of bypass on a live data stream has not been observed yet: that needs a design
that drives the QSFP transceivers and a module or loopback in the cage.

Access path: I2C bus #1 (`SDA=L20`, `SCL=K20`), retimer address `0x22`. The same bus has
the QSFP cage EEPROM at `0x50` and is available on header **J10** (pin 1 = SCL,
pin 2 = SDA, pin 3 = GND), so an external USB-I2C adapter can be used without an FPGA
design.

## QSFP EEPROM

Standard SFF-8636 management interface at `0x50` on the same I2C bus. Reading bytes
`0..127` gives identifier, vendor, part number and the first page of capabilities. The
`ModPrsL` pin goes low when a module/cable is inserted.

## Reference design

`Projects/Network/SuperliteII_V4_QSFP` in
[tow3rs/catapult-v3-smartnic-re](https://github.com/tow3rs/catapult-v3-smartnic-re) is a port of the
Intel "High Speed Transceiver Demo" that:

- instantiates the Arria 10 transceiver + 64b/66b PCS for 4 lanes,
- generates PRBS and measures eye height,
- talks to a second card running the same design over a QSFP cable (proprietary
  "Superlite II" protocol, **not** Ethernet),
- lets you switch the line rate between 10.3125 / 10.9375 / 12.5 Gb/s,
- contains NIOS II software (`Software/app`) that programs the retimer over I2C.

It needs two cards and a QSFP cable to be useful. For single-card testing the retimer I2C
scan is the first step.

## DisplayPort over the cage (concept)

A separate design study proposes using the four QSFP+ lanes as a DisplayPort 1.2/1.4 main
link: the retimer is put into raw-data / CDR-bypass mode, a small bridge MCU converts the
FPGA's I2C commands to 1 Mbps Manchester AUX, and HPD is returned through `IntL`. The
adapter would use the 3.3 V `VccTx` rail and a full-size DP receptacle.

**Status: unknown — no prototype has been built.** The retimer settings, AUX electrical
compliance and mechanical fit all need validation. See:

- [qsfp-displayport-adapter.md](qsfp-displayport-adapter.md) — working principle, risks,
  validation checklist
- [Interactive 3D assembly](https://flufy3d.github.io/MS-FPGA1768-Hardware-Lab/qsfp-dp-adapter.html)
  — mechanical envelope, routing study, sleeve STL

## First steps for a new card

1. Check `ModPrsL` (`AG15`) with a QSFP loopback or cable inserted.
2. Scan I2C bus #1; expect `0x22` (retimer) and `0x50` (module EEPROM).
3. Read the retimer registers to confirm the part responds (`0x00`/`0x01` ID bytes).
4. Only then write rate registers.

> The QSFP cage is a **50G** port; 40G and 10G modules also work at the corresponding
> rates, but the retimer rate must match the line rate.

## Open questions

- Retimer firmware revision differences between card batches.
- Whether the second 4 channels of the retimer are wired anywhere (only 4 are traced).
- Thermal: the retimer runs warm; the card expects airflow from the server chassis.
