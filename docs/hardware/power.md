# Power

> Status: partially reported; 12 V input telemetry verified 2026-11-19 · **Do not treat the rail map as complete**

## Inputs

| Input | Voltage | Notes |
|-------|---------|-------|
| PCIe edge (J1) | 12 V, 3.3 V | 12 V is the main source; 3.3 V for PCIe sideband |
| Auxiliary 6-pin | 12 V | near the top-left corner; required for high FPGA utilisation |

The card is a ~75 W class PCIe device. A x8 slot supplies 25 W; the auxiliary connector
makes up the difference. Without it, the FPGA may configure but fail under load, and the
QSFP retimer may not lock.

## Regulators

| Device | Type | Rail(s) |
|--------|------|---------|
| U13 `LM25066` | hot-swap controller + PMBus monitor | 12 V input, current/voltage telemetry at I2C 0x42 |
| U26 `MP2953B` | multiphase digital VR controller | FPGA VCC core (0.9 V) and related rails |
| U35/U36 `MP86905` | power stages | phases for the core rail |
| U23, U58 | unmarked | DDR4 VDD / VTT, no public datasheet |
| U38 `CSD17570Q5B` | MOSFET | load switch / OR-ing |

## Measured telemetry

Read over I2C bus #2 from the FPGA with
[projects/06_i2c_telemetry](../../projects/06_i2c_telemetry/) (`fpga1768 i2c sensors`),
2026-11-19, PCB `M1003380-005`, card in a desktop slot with a fan on the heatsink, running
only the project 06 endpoint (die 40.9–41.6 °C). Status: verified; details in the
[lab log](../../lab-log/2026-11-19-06-i2c.md) and [i2c.md](i2c.md).

| Quantity | Source | Value |
|----------|--------|-------|
| 12 V input (`READ_VIN`) | LM25066 `0x42`, `0x88` | 12.179–12.188 V |
| Output after the hot-swap FET (`READ_VOUT`) | LM25066 `0x42`, `0x8B` | 12.143–12.157 V (about 30–40 mV drop) |
| LM25066 temperature (`READ_TEMPERATURE_1`) | LM25066 `0x42`, `0x8D` | 40.4–40.8 °C |
| Input current (`MFR_READ_IIN`) | LM25066 `0x42`, `0xD1` | raw `0x0285`–`0x0296`; amps `unknown` (sense resistor value not known) |
| Input power (`MFR_READ_PIN`) | LM25066 `0x42`, `0xD2` | raw `0x01A2`–`0x01A5`; watts `unknown` (same reason) |
| Board temperature | TMP411 `0x4C` local | 40.00 °C |

Converting current and power needs the LM25066 sense resistor RS and the CL pin setting
(datasheet Table 41: `m = 13661 × RS` or `6854 × RS` for current). Reading RS from the board,
or fitting the raw value against a known load, would make these verified numbers.

Rail test points are not silkscreened with voltages; measure before probing. The board
photo shows the inductor/capacitor bank around the FPGA and near the PCIe fingers.

## Power-up sequence (observed behaviour)

1. 12 V present → hot-swap controller releases the input rail.
2. `MP2953B` brings up VCC core and I/O rails; telemetry is available on I2C bus #2.
3. FPGA releases `nSTATUS`/`CONF_DONE`; the FT232H (or the ASx4 flash) configures the FPGA.
4. PCIe reference clock buffer `9DBV0441` enables the 100 MHz outputs.
5. The FPGA design trains PCIe and (optionally) brings up DDR4, QSFP.

## What we do **not** know

- Exact rail voltages and sequencing delays. The `MP2953B` configuration is stored in its
  internal NVM; read it over I2C before touching it.
- Whether the card tolerates hot-plug (it is not designed for it — always power off before
  inserting).
- Current limits programmed into `LM25066`, and its sense resistor value (needed to turn
  the raw current/power readings into amps and watts).

## Safety

- Never insert or remove the card while the system is powered.
- The auxiliary 12 V connector is not keyed like a PCIe 8-pin; verify polarity.
- The FPGA die can reach 100 °C junction. Provide airflow.
  **Measured 2026-11-18 (PCB `M1003380-005`, desktop slot, passive heatsink, no fan):**
  the die temperature read 86 °C 19 minutes after power-on and 101 °C after 28.5 minutes
  (about 1.4 °C per minute) with only a Gen3 x8 PCIe endpoint running, and the card lost
  power 36 minutes after power-on in an earlier run. Values use the vendor sensor formula
  and were not cross-checked. See
  [lab-log/2026-11-18-pcie-gen3-bar0-temp.md](../../lab-log/2026-11-18-pcie-gen3-bar0-temp.md).
  **Measured 2026-11-19 (`projects/05_ddr4`, then `05_shell`, both DDR4 channels):** the Quartus Power
  Analyzer puts the design at 15.0 W (I/O 6.20 W, device static 5.33 W, transceivers
  2.47 W, core dynamic 1.01 W). Without a fan the die read 130.2 °C five minutes after
  configuration and the card lost power 78 s later; with a small fan over the passive
  heatsink it held 47.7–49.0 °C through the DDR tests and two 128 MB flash dumps. See
  [lab-log/2026-11-19-05-shell-ddr4.md](../../lab-log/2026-11-19-05-shell-ddr4.md).
- The QSFP cage and retimer are on the 3.3 V rail and can be damaged by a shorted module;
  insert modules only when the card is off.
