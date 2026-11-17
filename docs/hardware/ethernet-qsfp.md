# 50G Ethernet: QSFP+ and the DS250DF810 retimer

> Status: reported (topology verified on photos, link not tested in this lab)

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
were used successfully by the community with an on-FPGA I2C master.

Access path: I2C bus #1 (`SDA=L20`, `SCL=K20`), retimer address `0x22`. The same bus has
the QSFP cage EEPROM at `0x50` and is available on header **J10** (pin 1 = SCL,
pin 2 = SDA, pin 3 = GND), so an external USB-I2C adapter can be used without an FPGA
design.

## QSFP EEPROM

Standard SFF-8636 management interface at `0x50` on the same I2C bus. Reading bytes
`0..127` gives identifier, vendor, part number and the first page of capabilities. The
`ModPrsL` pin goes low when a module/cable is inserted.

## Reference design

`reference/catapult-v3-smartnic-re/Projects/Network/SuperliteII_V4_QSFP` is a port of the
Intel "High Speed Transceiver Demo" that:

- instantiates the Arria 10 transceiver + 64b/66b PCS for 4 lanes,
- generates PRBS and measures eye height,
- talks to a second card running the same design over a QSFP cable (proprietary
  "Superlite II" protocol, **not** Ethernet),
- lets you switch the line rate between 10.3125 / 10.9375 / 12.5 Gb/s,
- contains NIOS II software (`Software/app`) that programs the retimer over I2C.

It needs two cards and a QSFP cable to be useful. For single-card testing the retimer I2C
scan is the first step.

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
