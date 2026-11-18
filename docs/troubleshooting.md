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

## Host bugcheck after BAR0 access

Symptom: Windows bugchecks with `0x00000050 PAGE_FAULT_IN_NONPAGED_AREA` while a PCIe
BAR is accessed through a kernel driver. Observed in this lab with RWEverything
(2026-11-17) after the endpoint was hot-added and BAR0 had not been assigned.

Check the config space **before** writing:

- command register (`0x04`) must have memory space enable (bit 1) set;
- BAR0 (`0x10`/`0x14`) must contain a real base address, not `0x0000000C` with base 0.

An unassigned BAR0 means Windows/BIOS has not allocated a memory window. A write through
a kernel driver can land near physical address 0 and crash the host. Cold-start the card,
let the BIOS assign the BAR, and use Linux `pcimem` or another tool that validates the BAR
before writing. Do not repeat the write on an unassigned BAR.

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

0. **Power-cycle the whole machine at the PSU first.** On the lab card this was the actual
   fix: the FT232H latches after an aborted Quartus programmer run and stops passing TDO,
   while the FPGA keeps running normally. `FT_CyclePort` (`scripts/ftdi_cycle.py`) is *not*
   enough; VBUS must drop.

   > **Amendment 2026-11-18.** Two distinct states were seen this day, and only one of them
   > needed a power cycle. An aborted programmer run can leave the FT232H *unopenable*
   > (no TDO failure, `jtagconfig` still enumerates it); `pnputil /restart-device` on the
   > `VID_0403&PID_6014` instance cleared that. The stuck-TDO state above is the harder
   > one. Try the reset-device path first, see
   > "`quartus_pgm` cannot access the cable (209037) or the device looks in use (209042)".
1. **Cable / driver**: the FTDI device must be present and `jtagconfig` must list the cable.
   If not, fix that first.
2. **J5 pin 10**: must be open. Grounding it disables the on-board FT232H.
3. **External programmer**: try a USB-Blaster on J5. J5 goes to the FPGA JTAG pins through a
   different path than the FT232H; if it works, the on-board path is at fault.
4. **JTAG locked by the running bitstream**: not observed on this card — IDCODE reads fine
   with the Microsoft bitstream running.
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

Also observed after a host bugcheck during a BAR0 access (2026-11-17): the PCIe endpoint
and the FT232H both disappeared. The two `USB\VID_0403&PID_6014` nodes were
`Present=False` / `CM_PROB_PHANTOM`, and `jtagconfig` reported no hardware. A warm reboot
did not help; the card was unpowered or the FT232H latched. A full AC power cycle is
required.

Fix: **full shutdown and cold start** (not a restart). The FPGA reloads its bitstream from
the QSPI flash and the endpoint returns. If it still does not appear after a cold boot,
check the 12 V rails and the config flash (see [hardware/fpga.md](hardware/fpga.md)).

## `quartus_pgm` cannot access the cable (209037) or the device looks in use (209042)

Both were seen on the lab host on **2026-11-18**, and both look like a hang rather than an
error.

**209037, within a few seconds of starting:**

```
Info (213045): Using programming cable "Microsoft Catapult (64) [USB-0]"
Info (209060): Started Programmer operation
Error (209037): JTAG Server can't access selected programming hardware
```

Something enumerated the cable through the JTAG Server immediately before `quartus_pgm`,
and the exclusive open then fails. `scripts/program.ps1` calls `jtagconfig` to list the
cables, so running it after any other `jtagconfig` invocation reproduces this. Call
`quartus_pgm` directly instead.

**209042, after a long stall:**

```
Info (209060): Started Programmer operation at 13:15:47
Error (209042): Application Quartus Programmer on 127.0.0.1 is using the target device
Error (209012): Operation failed
Info (209061): Ended Programmer operation at 13:15:47
Error: Elapsed time: 00:08:41
```

`Started` and `Ended` in the same second, with most of the elapsed time before them, means
nothing was programmed. A previous `quartus_pgm` that was killed while holding the device
leaves it unopenable.

### Telling a slow program from a stuck one

`quartus_pgm` buffers its output when stdout is redirected, so the log stays at 0 bytes for
the whole run. Do not use an empty log as evidence of a hang. Watch the JTAG Server instead:

| `jtagserver` CPU | Device I/O counters | Meaning |
|------------------|---------------------|---------|
| ~0 % | flat | idle, no client |
| 100 % of one core | **rising** | programming, leave it alone |
| 100 % of one core | **flat** | open/retry loop, it will fail with 209042 |

```powershell
$j = Get-Process jtagserver
$ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($j.Id)"
$ci.OtherTransferCount   # DeviceIoControl bytes; must rise during a real program
```

A 36 MB `.sof` at 5 MHz takes about 10 minutes and pins one core for the whole time. That
is normal, not a deadlock. An aborted run costs another 10 minutes, so confirm the I/O
counters rise before deciding anything.

### Recovery

```powershell
Stop-Process -Name quartus_pgm -Force -ErrorAction SilentlyContinue
Stop-Process -Name jtagserver -Force -ErrorAction SilentlyContinue
sc.exe stop JTAGServer
# Reset the FT232H so the next open is clean:
pnputil /restart-device "USB\VID_0403&PID_6014\5&1CC0E58A&0&6"
sc.exe start JTAGServer
# then run quartus_pgm directly, with no jtagconfig in between
```

On 2026-11-18 `pnputil /restart-device` was enough to clear the state after an aborted
run; the full AC power cycle described under "JTAG chain broken" was not needed. Restarting
the JTAG Server alone was **not** enough, and neither was killing the client.

Get the instance id from `Get-PnpDevice -PresentOnly | Where-Object InstanceId -like
'*VID_0403*'`; it is stable for a given USB port.

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

## `qsys-generate` fails with ClassNotFoundException

```
Error: Could not find or load main class com.altera.qsys.generate.QsysGenerate
```

The `<install>\qsys` Platform Designer runtime is missing. The Quartus compiler still works
for pure RTL, which is why a hello-world build succeeds; projects that instantiate IP
(PCIe, DDR4, PLLs) fail. Re-run the Quartus installer and add/repair the Quartus
core/Platform Designer component, then verify `<install>\qsys\bin\qsys-generate.exe`.
See [toolchain/quartus-install.md](toolchain/quartus-install.md#2b-platform-designer-required-for-ip).

## Windows test driver will not load

The lab's KMDF BAR0 test driver is in
[`projects/02_pcie_pio/driver`](../projects/02_pcie_pio/driver/). It is
self-signed, so it only loads with **Secure Boot disabled** and **test signing
enabled**:

```powershell
Confirm-SecureBootUEFI      # must be False
bcdedit /enum {current}     # must show testsigning Yes
signtool verify /pa projects\02_pcie_pio\driver\build\pcie_bar.cat
```

If the device shows code 52 (`CM_PROB_UNSIGNED_DRIVER`), the signature or test
signing state is wrong. If it shows code 10/39, the driver started but failed;
check Event Viewer and the device's problem code.

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
