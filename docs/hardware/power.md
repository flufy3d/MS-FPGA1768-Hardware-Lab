# Power

> Status: partially reported · **Do not treat the rail map as complete**

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
- Current limits programmed into `LM25066`.

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
