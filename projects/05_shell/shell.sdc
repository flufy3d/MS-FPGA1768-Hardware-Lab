# shell.sdc — timing constraints of projects/05_shell (both revisions)

# 100 MHz board oscillator U59 (AP20): BAR0 register bank, persona registers,
# reference of the 50 MHz PR/flash PLL.
create_clock -name clk_100 -period 10.000 [get_ports clk_100]

# 100 MHz PCIe #1 reference clock from U57/U56 (AN29/AN28)
create_clock -name clk_pcie1 -period 10.000 [get_ports clk_pcie1]

# The DDR4 reference clocks (top_refclk Y4, bot_refclk Y3, 266.667 MHz) and
# all EMIF clocks are created by the EMIF IP's own SDC. The PCIe hard IP, the
# IOPLL and the PR controller also add their own constraints.

# PERST# is an asynchronous input to the HIP.
set_false_path -from [get_ports pcie1_perstn]

# LEDs are static indicators.
set_false_path -to [get_ports {led[*]}]

derive_clock_uncertainty

# --------------------------------------------------------------------------
# Clock-domain crossings. Every crossing between clk_100 (and the 50 MHz
# PLL clock) and the two EMIF user clocks goes through one of:
#   - sync_bits (first stage sync_s0): single bits, toggles, quasi-static buses
#   - configuration captured on a synchronised toggle (cfgx_ -> cfgq_,
#     mbx_ -> mbq_), stable for several destination cycles before capture
#   - results read only after the producing engine has finished
#     (xres_ -> csr_rdata, mbres_ -> shell_regs readdata)
# --------------------------------------------------------------------------
set_false_path -to   [get_registers {*sync_s0*}]
set_false_path -from [get_registers {*cfgx_*}] -to [get_registers {*cfgq_*}]
set_false_path -from [get_registers {*mbx_*}]  -to [get_registers {*mbq_*}]
set_false_path -from [get_registers {*xres_*}] -to [get_registers {*csr_rdata*}]
set_false_path -from [get_registers {*mbres_rdata*}] -to [get_registers {*u_regs|readdata*}]

# Temperature sensor (internal 1 MHz clock), as projects 03/04.
set_false_path -to [get_registers {ts_raw_m[*]}]
set_false_path -to [get_registers {ts_eoc_sync[0]}]
