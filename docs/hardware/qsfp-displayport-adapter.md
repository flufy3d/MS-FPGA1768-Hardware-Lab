# DisplayPort over the QSFP+ cage

> Status: unknown (design proposal — not built, not tested on hardware)
> Source: design study for this repository, 2026-11-18
> Last verified: not applicable (no prototype)

The card's QSFP+ port is documented as a 50G Ethernet port behind a
[TI DS250DF810 retimer](ethernet-qsfp.md). This page explores a different use of the same
hardware: a custom **active QSFP+ → DisplayPort adapter** that lets the Arria 10 drive a
standard DP 1.2/1.4 monitor through the cage.

> **This is a concept.** No adapter has been built. The register values, electrical values
> and mechanical dimensions below are hypotheses to be validated, not recipes. Treat the
> page as a design review checklist, not as a verified modification.

## Why the cage can carry DisplayPort

The QSFP+ connector (SFF-8662) provides four 25G-class differential pairs, a 3.3 V supply
and the SFF-8636 sideband. DisplayPort 1.4 HBR3 uses four lanes at 8.1 Gbps, well inside
the passive bandwidth of a 25G channel. The difficult parts are not the bit rate:

- making the DS250DF810 pass an arbitrary line rate instead of locking its CDR to an
  Ethernet rate,
- carrying the 1 Mbps Manchester AUX channel and HPD through the QSFP+ sideband,
- keeping the DP side electrically compliant (AC coupling, AUX bias, HPD levels,
  DP_PWR),
- fitting a full-size DP receptacle into the QSFP+ module envelope.

## Block diagram

```
Arria 10 (U1)                  card                        adapter
┌───────────────┐   ┌───────────────────────┐   ┌───────────────────────────┐
│ GXB TX 0..3   │──▶│ U17 DS250DF810        │──▶│ QSFP+ 38-pin              │
│ fPLL,         │   │ 4 channels,           │   │  4 × 100 Ω pairs          │
│ 1.62–8.1 Gb/s │   │ raw-data / CDR bypass │   │  ↓                        │
│               │   │ I2C 0x22              │   │ DP receptacle (16.1 mm)   │
│               │   └───────────────────────┘   │  4 × main link            │
│ I2C master ───┼── bus #1 (SCL K20/SDA L20) ─▶│ bridge MCU (I2C slave)    │
│ HPD input  ◀──┼── IntL ───────────────────────│  ├─ SN65MLVD201 → AUX±    │
│               │                               │  └─ HPD ───────── HPD     │
└───────────────┘                               │ 3.3 V from VccTx          │
                                                └───────────────────────────┘
```

The model assumes the card (host side) already provides the series AC-coupling
capacitors. Whether the retimer-to-cage links are also AC-coupled, and whether the adapter
must add capacitors, must be checked on the schematic and with a scope before layout.

## 1. Main link

- Four GXB TX channels operated as one link. The fPLL is reconfigured for each link rate;
  DisplayPort rates are 1.62, 2.7, 5.4 and 8.1 Gbps per lane.
- DP 1.2/1.4 uses 8b/10b coding at all four rates. The FPGA needs a DisplayPort TX IP core
  (Intel or third-party) or a custom framer; the GXB alone only provides the serialiser.
- The retimer must pass the DP stream without re-locking. The current working hypothesis
  is raw-data / CDR-bypass mode, with the output mux overridden and the CDR held in reset
  while the rate changes. Exact register names and bit positions must come from the
  DS250DF810 datasheet, not from this page.
- The QSFP+ `Tx1..Tx4` pairs are host outputs. Use the lane order that matches the
  board's FPGA → retimer → cage mapping; it is not sequential. See the QSFP sheet in
  [FPGA_Pinouts.xlsx](../../hardware/pinouts/FPGA_Pinouts.xlsx).

The proposal names three retimer controls. They are listed here so the idea can be
reviewed, not because their addresses or bit positions are known:

| Control | Proposed value | Intent |
|---------|----------------|--------|
| `OVRD_OUT_MUX` | `1` | override the normal output mux |
| `OUT_MUX_SEL` | Raw data | send the equalised input straight to the driver |
| `CDR_RESET` | `1` while changing rate | hold the CDR in reset during reconfiguration |

Confirm every name, address and bit position in the DS250DF810 datasheet before writing
them. The existing community notes for the Ethernet rates are in
[ethernet-qsfp.md](ethernet-qsfp.md).

## 2. AUX channel and HPD

DisplayPort AUX is a 1 Mbps Manchester-II, half-duplex, AC-coupled differential pair used
for EDID, DPCD and link training. The adapter carries a small bridge MCU (CH32V003F4U6 or
STM32G031 class) that:

- is an I2C slave on bus #1, at an address that does not collide with the retimer
  (`0x22`) or the cage EEPROM (`0x50`),
- receives AUX request bytes from the FPGA, encodes them as Manchester-II and drives the
  M-LVDS transceiver,
- decodes the monitor's reply and returns it over I2C,
- handles bus turnaround, timeouts and retries,
- monitors DP HPD and pulls QSFP+ `IntL` low (open-drain) to interrupt the FPGA.

The M-LVDS transceiver (SN65MLVD201) is a 3.3 V half-duplex driver/receiver. DP AUX is not
M-LVDS: the common-mode, differential swing, AC coupling and bias network differ. The
following must be verified with a scope at the DP connector:

- M-LVDS output swing and common mode against the DP AUX sink requirements,
- AC-coupling capacitor values and the 100 kΩ-class bias network,
- drive-enable and turnaround timing,
- receiver failsafe behaviour when the AUX bus is idle.

HPD is a 3.3 V signal from the monitor. QSFP+ `IntL` is an open-drain host input and may
be pulled to 1.8 V or 3.3 V on this card. Use an open-drain FET or a level shifter; do not
drive 3.3 V into the FPGA pin. Measure the actual pull-up rail before choosing the
circuit.

## 3. Power, presence and DP_PWR

- Adapter supply: QSFP+ `VccTx` / `Vcc1` 3.3 V. Budget for the MCU, M-LVDS and bias is
  well under 80 mW, far below the 1.5 W Class 1 limit.
- Tie `ModPrsL` to GND so the host detects a module. If the FPGA design reads the cage
  EEPROM at `0x50`, the adapter must fit an SFF-8636 EEPROM or emulate it in the MCU.
- `DP_PWR` (pin 20 of the DP connector) is supplied by the **source**, not by the monitor.
  Derive it from the adapter's 3.3 V rail through a fuse or current limit, and use it for
  the AUX bias network. Do not expect the monitor to power the adapter.
- Add soft-start, current limiting and ESD protection on the 3.3 V input. The cage is
  mechanically hot-pluggable, but this card is not designed for live insertion.

## 4. FPGA-side design sketch

1. GXB TX on four channels, with the DP TX IP core generating the main-link stream.
2. I2C master on bus #1, with a small command/reply FIFO for AUX bytes.
3. HPD interrupt on `IntL`; debounce it and re-read DPCD/link status after each event.
4. Retimer driver: enter raw mode and set VOD before link training; restore the settings
   after a hot-plug or rate change.
5. Link-training state machine: read EDID, read DPCD, select lane count and rate, run
   clock recovery and channel equalisation, then enable video.

## 5. Bring-up sequence

1. Insert the adapter with the card powered off. Confirm `ModPrsL` and 3.3 V at the cage.
2. Scan bus #1: expect `0x22` (retimer), `0x50` (cage EEPROM, if fitted) and the bridge
   address.
3. Put the retimer in raw mode at the lowest DP rate (1.62 Gbps). Check the output with a
   scope or eye monitor before connecting a monitor.
4. Connect a DP monitor. Confirm HPD and the `IntL` interrupt.
5. Read EDID over AUX. Start with one lane at RBR, then four lanes.
6. Run link training at RBR/HBR/HBR2. Try HBR3 only after the lower rates are stable.
7. Stream a test pattern and check for errors over time and temperature.

## 6. What must be validated before layout

| Risk | Why it matters | How to check |
|------|----------------|--------------|
| Retimer raw mode | The DS250DF810 may not pass rates below its Ethernet range, or may re-lock/squelch | Bench test at 1.62/2.7/5.4/8.1 Gbps; read status registers |
| AC coupling | DP requires source-side coupling; the retimer output may or may not be coupled | Inspect the board, measure, add capacitors if needed |
| AUX electrical | M-LVDS is not DP AUX: common mode, swing and bias differ | Scope AUX± at the DP connector; test several monitors |
| HPD / IntL levels | 3.3 V HPD into a 1.8 V input can damage the FPGA | Measure the pull-up rail; use a level shifter |
| Lane order and polarity | FPGA → retimer → cage mapping is non-obvious | Use the pinout spreadsheet; run a lane/polarity test |
| Signal integrity | 8.1 Gbps through two connectors and a retimer | Eye diagram at the DP connector; tune VOD/equaliser |
| Mechanical fit | 16.1 mm DP shell inside an 18.35 mm cage; latch and cable clearance | Print the TPU sleeve, dry-fit in an unpowered cage |
| Power / backfeed | `DP_PWR` and `VccTx` are separate 3.3 V sources | Verify no backfeed; add an ideal diode or soft-start |
| Firmware timing | AUX turnaround is tight at 1 Mbps; I2C adds latency | Measure request-to-reply latency; add a local timeout |

## 7. Mechanical envelope

The interactive model uses these nominal dimensions, all in millimetres:

| Item | Value |
|------|-------|
| QSFP+ PCB width × thickness | 18.35 × 1.0 |
| DP shell width | 16.1 |
| Side clearance | ≈1.125 per side |
| Mating tongue width | 16.42 |
| Projection beyond cage | 5.0 |
| PCB thickness | 1.0 |
| Sleeve material | TPU 95A |

The DP receptacle is a mid-mount HDGC DP-GD-119PWB (LCSC C7425332) in the model. Confirm
the recommended PCB thickness, cutout, mounting tabs and shell envelope for the exact part
before releasing a PCB or sleeve. Print the sleeve with the front face on the bed and check
the clip supports in the slicer.

## 8. Interactive demo

The 3D assembly study covers the mechanical envelope, connector routing, AUX bridge
placement, X-ray cage, dimension lines and the downloadable sleeve STL:

- **Live page:** <https://flufy3d.github.io/MS-FPGA1768-Hardware-Lab/qsfp-dp-adapter.html>
- **Source:** [`docs/demo/qsfp-dp-adapter.html`](../demo/qsfp-dp-adapter.html)
- **Landing page:** <https://flufy3d.github.io/MS-FPGA1768-Hardware-Lab/>

It is a nominal envelope study, not a manufacturable design. The page also states its own
assumptions (host-side AC coupling, no adapter capacitors, proposed I2C retimer settings).

## Sources

- SFF-8662 (QSFP+ 38-pin connector), SFF-8665 (QSFP+ 28G), SFF-8636 (management interface)
- TI [DS250DF810](https://www.ti.com/product/DS250DF810) datasheet and E2E forum notes
- TI [SN65MLVD201](https://www.ti.com/product/SN65MLVD201) datasheet
- WCH [CH32V003](https://www.wch-ic.com/products/CH32V003.html) datasheet
- VESA DisplayPort 1.2a / 1.4a specifications (AUX, HPD, link training)
- Existing board notes: [ethernet-qsfp.md](ethernet-qsfp.md), [i2c.md](i2c.md),
  [connectors.md](connectors.md)
