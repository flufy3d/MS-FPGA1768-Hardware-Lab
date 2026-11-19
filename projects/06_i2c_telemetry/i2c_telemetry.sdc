# 100 MHz board oscillator U59 (AP20), clocks the BAR0 register block and the
# I2C master
create_clock -name clk_100 -period 10.000 [get_ports clk_100]

# 100 MHz PCIe #1 reference clock from U57/U56 (AN29/AN28)
create_clock -name clk_pcie1 -period 10.000 [get_ports clk_pcie1]

# The PCIe hard IP generates its own core clock, PLL clocks and transceiver
# constraints inside the IP's SDC file. Do not duplicate them here.

# PERST# is an asynchronous input to the HIP.
set_false_path -from [get_ports pcie1_perstn]

derive_clock_uncertainty

# The Arria 10 temperature sensor runs on its own internal 1 MHz clock
# (altera_ts_clk). tempout and eoc are sampled asynchronously through
# two-stage synchronisers in i2c_telemetry.sv, and the code is latched only
# after eoc has been stable for 128 clk_100 cycles.
set_false_path -to [get_registers {ts_raw_m[*]}]
set_false_path -to [get_registers {ts_eoc_sync[0]}]

# I2C (100 kHz, open drain). The pins are sampled through two-stage
# synchronisers (i2c_in_meta) and driven from registers that change at most
# once per quarter SCL period (>= 250 ns); board-level timing is set by the
# pull-ups, not by FPGA I/O timing.
set_false_path -from [get_ports {i2c1_scl i2c1_sda i2c2_scl i2c2_sda}]
set_false_path -to   [get_ports {i2c1_scl i2c1_sda i2c2_scl i2c2_sda}]

# The PR controller clock PLL's locked output is asynchronous; it is read
# through a two-stage synchroniser in i2c_telemetry.sv. The PLL and PR IPs
# add their own SDC for the 50 MHz clock.
set_false_path -to [get_registers {pll_locked_sync[0]}]
