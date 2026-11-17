# Troubleshooting

> Symptoms seen on real cards, with the checks that actually help.

## Board does not appear on PCIe

1. Is the card seated? These cards are long and heavy; the edge connector can lift at the
   front.
2. Is auxiliary 12 V connected? An x8 slot provides 25 W; the FPGA alone can exceed that.
3. Does the host slot support x8/x8 bifurcation? Only PCIe #1 is on lanes 0-7.
4. `lspci`/Device Manager shows nothing at all → the FPGA is unconfigured (no bitstream) or
   the flash image is invalid. In that state the card is invisible by design; use JTAG.
5. Shows `1414:B204` → the Microsoft image is running, this is normal.

## PCIe link trains at Gen1/Gen2 only

- Check `LnkCap` vs `LnkSta`; a Gen2 result with a Gen3 card usually means the slot, the
  riser or the cable is Gen2.
- Riser cards and M.2 adapters often break Gen3.
- The Microsoft bitstream may be configured for Gen2.

## `jtagconfig` finds no cable

See [onboard-usb-blaster.md](toolchain/onboard-usb-blaster.md). The three usual causes:
plugin not installed, `jtagd` still running with the old plugin, another program owns the
FTDI device.

## `jtagconfig` finds the cable but no device

- FPGA not powered (check 12 V, hot-swap controller, `nSTATUS`).
- J5 pin 10 grounded with nothing attached → disables the on-board programmer.
- A second programmer on J5 fighting the FT232H.
- Damaged level shifter near U21 (check for 1.8 V on the JTAG bank).

## JTAG chain broken / TDO stuck high

Symptom:

```
jtagconfig
1) Microsoft Catapult (64) [USB-0]
   Unable to read device chain - JTAG chain broken
```

Confirm with the independent scanner (does not use Quartus):

```powershell
python scripts\jtag_mpsse_idcode.py --speed 500000
# TCK=500000 Hz divisor=59 raw=ffffffff
# IDCODE=0xFFFFFFFF
# NO RESPONSE: TDO stuck (no JTAG TAP driving the line)
```

If TDO is constant `1` at every speed and every pin permutation, the FPGA is not driving the
line. Work through this list:

1. **Cable / driver**: the FTDI device must be present and `jtagconfig` must list the cable.
   If not, fix that first.
2. **J5 pin 10**: must be open. Grounding it disables the on-board FT232H.
3. **External programmer**: try a USB-Blaster on J5. J5 goes to the FPGA JTAG pins through a
   different path than the FT232H; if it works, the on-board path is at fault.
4. **JTAG locked by the running bitstream**: the card in this lab arrived with a Microsoft
   production image. If the design sets JTAG secure mode, the TAP is only usable before the
   FPGA is configured. Catching that window requires holding `nCONFIG` low at power-up; a
   normal Windows boot is far too slow to catch it.
5. **Damaged level shifter**: measure 1.8 V on J5 pin 4 and check that TCK/TMS/TDI reach the
   FPGA. No public schematic exists, so this needs continuity probing.

The boot-time scan task (see `lab-log/2026-11-17-first-light.md`) logs every attempt during
Windows startup and is the cheapest way to test hypothesis 4.

> **Do not drive FT232H ADBUS4-7 as outputs.** On the lab card, pulling ADBUS4-7 low
> unconfigured the FPGA and the card dropped off the PCIe bus until a full power cycle.
> One of those pins is connected to an FPGA configuration/power signal.

## Card disappeared from PCIe and does not come back

Symptoms: the device node exists with `Present = False`, `pnputil /scan-devices` finds
nothing, and the machine still boots normally.

Cause observed in this lab: driving the FT232H ADBUS4-7 pins low (see warning above). The
FPGA is left unconfigured or powered down.

Fix: **full shutdown and cold start** (not a restart). The FPGA reloads its bitstream from
the QSPI flash and the endpoint returns. If it still does not appear after a cold boot,
check the 12 V rails and the config flash (see [hardware/fpga.md](hardware/fpga.md)).

## Programming succeeds but the design does nothing

- Wrong clock pin: `clk_u59` is `AP20`; a design built for another board will not blink.
- The design drives pins that are dual-purpose configuration pins and gets them wrong.
- LEDs are 1.8 V; a 3.3 V assignment still "works" in Quartus but the bank may be damaged.
- Check `sta.rpt`: an unconstrained design may not run at the intended frequency.
- Use Signal Tap to check the clock and reset (needs a JTAG connection, which you have).

## Design loads, then the card disappears from PCIe

- You loaded a bitstream that does not contain the PCIe HIP, or contains one with a
  different config space. Cold boot to rescan.
- If the design never re-enumerates after a reboot, the flash may have been overwritten with
  a non-PCIe image; recover over JTAG.

## Fan noise / thermal shutdown

- The card expects server airflow. Add a fan.
- `TMP411` at I2C `0x4C` reports local and remote temperatures; read it before long runs.
- Arria 10 throttles at high junction temperature; timing failures that appear after
  10 minutes of operation are usually thermal.

## I2C devices missing

- Bus #1 is powered from the board rail, bus #2 from PCIe 3.3 V. A card on the bench with
  only 12 V may not have bus #2 alive.
- Check the level shifters (U25/U39/U44/U45); they are enabled by `PCA9535` outputs on some
  revisions.
- Do not scan with a 5 V adapter.

## Licence errors

```
Error: ... license ...
```

Quartus Prime Pro requires a licence. This repository does not supply one. Options: use
your company licence, the evaluation period, or install the free Quartus Prime Standard
edition. A licence error is never a board fault.

## Card was working, now all LEDs are dark

- Power cycle. The FPGA reloads from flash.
- If it stays dark and JTAG still works, program a known-good `.sof` (hello world first).
- If JTAG is also gone, the card may have lost a rail; measure 12 V, 3.3 V and the core
  rail test points.
