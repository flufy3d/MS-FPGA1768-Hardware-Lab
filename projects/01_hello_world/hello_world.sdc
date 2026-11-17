# 100 MHz board oscillator (U59), single-ended 1.8 V, pin AP20
create_clock -name clk_100 -period 10.000 [get_ports clk_100]

# LEDs are asynchronous outputs; no timing requirement
set_false_path -from [get_clocks clk_100] -to [get_ports {led[*]}]

derive_clock_uncertainty
