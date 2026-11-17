# 100 MHz board oscillator U59 (AP20), used by the BAR0 register bank
create_clock -name clk_100 -period 10.000 [get_ports clk_100]

# 100 MHz PCIe #1 reference clock from U57/U56 (AN29/AN28)
create_clock -name clk_pcie1 -period 10.000 [get_ports clk_pcie1]

# The PCIe hard IP generates its own core clock, PLL clocks and transceiver
# constraints inside the IP's SDC file. Do not duplicate them here.

# PERST# is an asynchronous input to the HIP.
set_false_path -from [get_ports pcie1_perstn]

derive_clock_uncertainty
