# --------------------------------------------------------------------------
# make_qsys.tcl — build pcie_hot_update_sys.qsys for 04_pcie_hot_update
#
# Run from this directory:
#   . ..\..\scripts\env.ps1   (required, see AGENTS.md section 7)
#   Remove-Item -Recurse -Force ip\pcie_hot_update_sys, pcie_hot_update_sys
#   qsys-script --script=make_qsys.tcl --quartus-project=pcie_hot_update.qpf
#
# Same static system as projects/03_pcie_gen3 (Gen3 x8 Avalon-MM with DMA
# HIP, 64-bit BAR0, A/B/SUM/COUNTER/ID/TEMP registers, 32 KB scratch RAM)
# plus two additions for partial reconfiguration over PCIe:
#
#   0x0060  PERSONA  PIO, read-only: persona ID, freeze state, PR clock lock
#   0x0100  pr_ip    Partial Reconfiguration Controller (alt_pr), internal
#                    host, Avalon-MM slave, 16 words:
#                      0x0100  data   (write PR bitstream words here)
#                      0x0104  CSR    (bit 0 start, [4:2] status)
#                      0x0108  version
#                      0x010C  PR bitstream ID
#
# Everything in this system lives in the static region. The reconfigurable
# persona is instantiated in pcie_hot_update.sv, outside the Qsys system.
# --------------------------------------------------------------------------

package require -exact qsys 25.1

create_system
set_project_property DEVICE_FAMILY "Arria 10"
set_project_property DEVICE 10AXF40AA

# 100 MHz board clock (AP20): register bank, PR controller and persona clock.
add_instance clk_100 clock_source
set_instance_parameter_value clk_100 clockFrequency 100000000
set_instance_parameter_value clk_100 clockFrequencyKnown true

# Arria 10 PCIe hard IP — identical to projects/03_pcie_gen3/make_qsys.tcl.
add_instance pcie altera_pcie_a10_hip
set_instance_parameter_value pcie device_family "Arria 10"
set_instance_parameter_value pcie part_trait_device 10AXF40AA
set_instance_parameter_value pcie targeted_devkit_hwtcl "Arria 10 GX FPGA Development Kit"
set_instance_parameter_value pcie interface_type_hwtcl "Avalon-MM with DMA"
set_instance_parameter_value pcie select_design_example_hwtcl "DMA"
set_instance_parameter_value pcie internal_controller_hwtcl 0
set_instance_parameter_value pcie enable_example_design_qii_hwtcl 0
set_instance_parameter_value pcie enable_example_design_sim_hwtcl 0
set_instance_parameter_value pcie enable_example_design_synth_hwtcl 0
set_instance_parameter_value pcie enable_example_design_tb_hwtcl 0
set_instance_parameter_value pcie wrala_hwtcl 0
set_instance_parameter_value pcie vendor_id_hwtcl 4466
set_instance_parameter_value pcie device_id_hwtcl 57347
set_instance_parameter_value pcie class_code_hwtcl 16711680
set_instance_parameter_value pcie bar0_type_hwtcl "64-bit prefetchable memory"
set_instance_parameter_value pcie bar1_type_hwtcl "Disabled"
set_instance_parameter_value pcie bar2_type_hwtcl "Disabled"
set_instance_parameter_value pcie maximum_payload_size_hwtcl 128
set_instance_parameter_value pcie pcie_spec_version_hwtcl "3.0"

# Arria 10 internal temperature sensing diode (1 MHz internal clock).
add_instance temp altera_temp_sense

# 50 MHz clock for the PR controller.
#
# alt_pr launches PR data on the falling edge of its clock and the PR control
# block captures it on the next rising edge: a half-cycle path. At 100 MHz the
# first build (2026-11-18) failed setup on that path by 2.9 ns in the
# Slow 900mV 100C corner (global clock to the launching registers, local gated
# clock to the PR block, -3.1 ns skew). 50 MHz gives the path 10 ns. The PR
# load rate is limited by the host (one MMIO write per word), not by this clock.
add_instance pll_pr altera_iopll
set_instance_parameter_value pll_pr gui_reference_clock_frequency 100.0
set_instance_parameter_value pll_pr gui_number_of_clocks 1
set_instance_parameter_value pll_pr gui_output_clock_frequency0 50.0
set_instance_parameter_value pll_pr gui_use_locked true

# Partial Reconfiguration Controller, internal host, Avalon-MM slave.
#   - 32-bit input, plain (uncompressed, unencrypted) PR data: CDRATIO 1.
#   - Bitstream compatibility check on: a PR bitstream compiled against a
#     different base build is rejected with status 3'b011 instead of being
#     loaded.
#   - JTAG debug mode off: the PR bitstream comes only over PCIe.
#   - The freeze output is exported and used in pcie_hot_update.sv.
add_instance pr_ip alt_pr
set_instance_parameter_value pr_ip PR_INTERNAL_HOST 1
set_instance_parameter_value pr_ip ENABLE_JTAG 0
set_instance_parameter_value pr_ip ENABLE_AVMM_SLAVE 1
set_instance_parameter_value pr_ip ENABLE_INTERRUPT 0
set_instance_parameter_value pr_ip ENABLE_FREEZE 1
set_instance_parameter_value pr_ip ENABLE_HPR_UI 0
set_instance_parameter_value pr_ip ENABLE_PRPOF_ID_CHECK_UI 1
set_instance_parameter_value pr_ip DATA_WIDTH_INDEX 32
set_instance_parameter_value pr_ip CDRATIO 1
set_instance_parameter_value pr_ip ENABLE_ENHANCED_DECOMPRESSION 0

# 32-bit Avalon PIO register bank.
proc add_pio {name dir} {
    add_instance $name altera_avalon_pio
    set_instance_parameter_value $name direction $dir
    set_instance_parameter_value $name width 32
    set_instance_parameter_value $name clockRate 100000000
    set_instance_parameter_value $name resetValue 0
}

set PIOS {pio_a pio_b pio_sum pio_counter pio_id pio_temp pio_persona}

add_pio pio_a       Output
add_pio pio_b       Output
add_pio pio_sum     Input
add_pio pio_counter Input
add_pio pio_id      Input
add_pio pio_temp    Input
add_pio pio_persona Input

# 32 KB scratch RAM at BAR0 + 0x8000 (sizes BAR0 to 64 KB, see project 03).
add_instance scratch_ram altera_avalon_onchip_memory2
set_instance_parameter_value scratch_ram dataWidth 32
set_instance_parameter_value scratch_ram memorySize 32768
set_instance_parameter_value scratch_ram initMemContent false
set_instance_parameter_value scratch_ram dualPort false
set_instance_parameter_value scratch_ram singleClockOperation false
set_instance_parameter_value scratch_ram writable true

# BAR0 decode.
set base 0
foreach p $PIOS {
    add_connection pcie.rxm_bar0 $p.s1
    set_connection_parameter_value pcie.rxm_bar0/$p.s1 baseAddress [format 0x%04X $base]
    incr base 16
}

add_connection pcie.rxm_bar0 pr_ip.avmm_slave
set_connection_parameter_value pcie.rxm_bar0/pr_ip.avmm_slave baseAddress 0x0100

add_connection pcie.rxm_bar0 scratch_ram.s1
set_connection_parameter_value pcie.rxm_bar0/scratch_ram.s1 baseAddress 0x8000

# Clocks and resets (clk_100 domain).
foreach p $PIOS {
    add_connection clk_100.clk       $p.clk
    add_connection clk_100.clk_reset $p.reset
}
add_connection clk_100.clk       scratch_ram.clk1
add_connection clk_100.clk_reset scratch_ram.reset1
add_connection clk_100.clk       pll_pr.refclk
add_connection pll_pr.outclk0    pr_ip.clk
add_connection clk_100.clk_reset pr_ip.nreset

# Top-level interfaces.
add_interface clk_100 clock end
set_interface_property clk_100 EXPORT_OF clk_100.clk_in

add_interface reset reset end
set_interface_property reset EXPORT_OF clk_100.clk_in_reset

add_interface pcie_refclk clock end
set_interface_property pcie_refclk EXPORT_OF pcie.refclk

add_interface pcie_npor conduit end
set_interface_property pcie_npor EXPORT_OF pcie.npor

add_interface pcie_hip_serial conduit end
set_interface_property pcie_hip_serial EXPORT_OF pcie.hip_serial

foreach p $PIOS {
    add_interface ${p}_external conduit end
    set_interface_property ${p}_external EXPORT_OF $p.external_connection
}

foreach i [get_instance_interfaces temp] {
    add_interface temp_$i conduit end
    set_interface_property temp_$i EXPORT_OF temp.$i
}

add_interface pr_freeze conduit end
set_interface_property pr_freeze EXPORT_OF pr_ip.freeze

add_interface pll_pr_locked conduit end
set_interface_property pll_pr_locked EXPORT_OF pll_pr.locked

# The IOPLL reset must be driven by real logic (Quartus rejects a constant):
# pcie_hot_update.sv drives it with a power-up pulse.
add_interface pll_pr_reset reset end
set_interface_property pll_pr_reset EXPORT_OF pll_pr.reset

save_system pcie_hot_update_sys.qsys
