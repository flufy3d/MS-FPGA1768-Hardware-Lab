# 100 MHz board oscillator U59 (AP20), used by the BAR0 register bank
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
# two-stage synchronisers in pcie_gen3.sv, and the code is latched only after
# eoc has been stable for 128 clk_100 cycles.
set_false_path -to [get_registers {ts_raw_m[*]}]
set_false_path -to [get_registers {ts_eoc_sync[0]}]
