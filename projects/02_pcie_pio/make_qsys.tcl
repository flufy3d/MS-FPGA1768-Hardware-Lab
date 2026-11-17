# --------------------------------------------------------------------------
# make_qsys.tcl — build pcie_pio_sys.qsys for the 02_pcie_pio project
#
# Run from this directory:
#   qsys-script --script=make_qsys.tcl --quartus-project=pcie_pio.qpf
#
# The system contains:
#   - Arria 10 PCIe hard IP, Gen3 x8, Avalon-MM with DMA, 64 KB BAR0
#   - Five 32-bit Avalon PIO instances mapped into BAR0:
#       0x00 A, 0x10 B, 0x20 SUM, 0x30 COUNTER, 0x40 ID
#   - 100 MHz clock source for the register bank
#
# The PIO slave address span is 16 bytes, hence the 0x10 register spacing.
# --------------------------------------------------------------------------

package require -exact qsys 25.1

create_system
set_project_property DEVICE_FAMILY "Arria 10"
set_project_property DEVICE 10AXF40AA

# 100 MHz board clock (AP20), used by the BAR0 register bank.
add_instance clk_100 clock_source
set_instance_parameter_value clk_100 clockFrequency 100000000
set_instance_parameter_value clk_100 clockFrequencyKnown true

# Arria 10 PCIe hard IP.
#
# "Avalon-MM with DMA" is required for the Gen3 x8 / 256-bit HIP mode.
# The DMA engine is unused; only the BAR0 Avalon-MM master (rxm_bar0) is
# connected, to the five PIO instances.
add_instance pcie altera_pcie_a10_hip
set_instance_parameter_value pcie device_family "Arria 10"
set_instance_parameter_value pcie part_trait_device 10AXF40AA
set_instance_parameter_value pcie targeted_devkit_hwtcl "Arria 10 GX FPGA Development Kit"
set_instance_parameter_value pcie interface_type_hwtcl "Avalon-MM with DMA"
set_instance_parameter_value pcie select_design_example_hwtcl "DMA"
set_instance_parameter_value pcie enable_example_design_qii_hwtcl 0
set_instance_parameter_value pcie enable_example_design_sim_hwtcl 0
set_instance_parameter_value pcie enable_example_design_synth_hwtcl 0
set_instance_parameter_value pcie enable_example_design_tb_hwtcl 0
set_instance_parameter_value pcie use_dynamic_design_example 0
set_instance_parameter_value pcie lane_rate_hwtcl "Gen3 (8.0 Gbps)"
set_instance_parameter_value pcie wrala_hwtcl 0
set_instance_parameter_value pcie vendor_id_hwtcl 4466
set_instance_parameter_value pcie device_id_hwtcl 57347
set_instance_parameter_value pcie class_code_hwtcl 16711680
set_instance_parameter_value pcie bar0_address_width_hwtcl 16
set_instance_parameter_value pcie bar0_type_hwtcl "64-bit prefetchable memory"
set_instance_parameter_value pcie pf0_bar0_present_hwtcl 1
set_instance_parameter_value pcie pf0_bar0_prefetchable_hwtcl 1
set_instance_parameter_value pcie pf0_bar0_type_hwtcl 1
set_instance_parameter_value pcie pf0_bar0_size_hwtcl 12
set_instance_parameter_value pcie maximum_payload_size_hwtcl 128
set_instance_parameter_value pcie pcie_spec_version_hwtcl "3.0"

# 32-bit Avalon PIO register bank.
proc add_pio {name dir} {
    add_instance $name altera_avalon_pio
    set_instance_parameter_value $name direction $dir
    set_instance_parameter_value $name width 32
    set_instance_parameter_value $name clockRate 100000000
    set_instance_parameter_value $name resetValue 0
}

add_pio pio_a       Output
add_pio pio_b       Output
add_pio pio_sum     Input
add_pio pio_counter Input
add_pio pio_id      Input

# BAR0 decode: one Avalon-MM slave per PIO, 16 bytes apart.
add_connection pcie.rxm_bar0 pio_a.s1
add_connection pcie.rxm_bar0 pio_b.s1
add_connection pcie.rxm_bar0 pio_sum.s1
add_connection pcie.rxm_bar0 pio_counter.s1
add_connection pcie.rxm_bar0 pio_id.s1

set_connection_parameter_value pcie.rxm_bar0/pio_a.s1       baseAddress 0x0000
set_connection_parameter_value pcie.rxm_bar0/pio_b.s1       baseAddress 0x0010
set_connection_parameter_value pcie.rxm_bar0/pio_sum.s1     baseAddress 0x0020
set_connection_parameter_value pcie.rxm_bar0/pio_counter.s1 baseAddress 0x0030
set_connection_parameter_value pcie.rxm_bar0/pio_id.s1      baseAddress 0x0040

# Register bank clock and reset.
foreach p {pio_a pio_b pio_sum pio_counter pio_id} {
    add_connection clk_100.clk       $p.clk
    add_connection clk_100.clk_reset $p.reset
}

# Top-level interfaces.
add_interface clk_100 clock end
set_interface_property clk_100 EXPORT_OF clk_100.clk_in

add_interface pcie_refclk clock end
set_interface_property pcie_refclk EXPORT_OF pcie.refclk

add_interface pcie_npor conduit end
set_interface_property pcie_npor EXPORT_OF pcie.npor

add_interface pcie_hip_serial conduit end
set_interface_property pcie_hip_serial EXPORT_OF pcie.hip_serial

foreach p {pio_a pio_b pio_sum pio_counter pio_id} {
    add_interface ${p}_external conduit end
    set_interface_property ${p}_external EXPORT_OF $p.external_connection
}

save_system pcie_pio_sys.qsys
