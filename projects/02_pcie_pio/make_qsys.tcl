# --------------------------------------------------------------------------
# make_qsys.tcl — build pcie_pio_sys.qsys for the 02_pcie_pio project
#
# Run from this directory:
#   qsys-script --script=make_qsys.tcl --quartus-project=pcie_pio.qpf
#
# The system contains:
#   - Arria 10 PCIe hard IP, Gen2 x8 128-bit, Avalon-MM, BAR0 32-bit
#     non-prefetchable 64 KB
#   - Five 32-bit Avalon PIO instances mapped into BAR0:
#       0x00 A, 0x10 B, 0x20 SUM, 0x30 COUNTER, 0x40 ID
#   - 32 KB scratch RAM at 0x8000 (sets the BAR0 span to 64 KB)
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
# Plain "Avalon-MM", Gen2 x8, 128-bit, 250 MHz (wrala_hwtcl = 7), the same
# HIP mode as the upstream PCIe1 reference design.
#
# The earlier "Avalon-MM with DMA" / Gen3 x8 256-bit variant forces BAR0 to
# 64-bit prefetchable memory (hard-coded in altera_pcie_a10_hip_fileset.tcl)
# and also enables a 64-bit prefetchable BAR2. On the lab host Windows did not
# assign either BAR (problem code 10). BAR0 is now 32-bit non-prefetchable,
# 64 KB, and BAR1/BAR2 are disabled. The pf0_bar* parameters are derived by
# the IP from bar*_type_hwtcl and are not set here.
#
# Only the BAR0 Avalon-MM master (rxm_bar0) is connected, to the PIO bank.
add_instance pcie altera_pcie_a10_hip
set_instance_parameter_value pcie device_family "Arria 10"
set_instance_parameter_value pcie part_trait_device 10AXF40AA
set_instance_parameter_value pcie targeted_devkit_hwtcl "Arria 10 GX FPGA Development Kit"
set_instance_parameter_value pcie interface_type_hwtcl "Avalon-MM"
set_instance_parameter_value pcie enable_example_design_qii_hwtcl 0
set_instance_parameter_value pcie enable_example_design_sim_hwtcl 0
set_instance_parameter_value pcie enable_example_design_synth_hwtcl 0
set_instance_parameter_value pcie enable_example_design_tb_hwtcl 0
set_instance_parameter_value pcie wrala_hwtcl 7
set_instance_parameter_value pcie vendor_id_hwtcl 4466
set_instance_parameter_value pcie device_id_hwtcl 57347
set_instance_parameter_value pcie class_code_hwtcl 16711680
set_instance_parameter_value pcie bar0_type_hwtcl "32-bit non-prefetchable memory"
set_instance_parameter_value pcie bar0_address_width_hwtcl 16
set_instance_parameter_value pcie bar1_type_hwtcl "Disabled"
set_instance_parameter_value pcie bar2_type_hwtcl "Disabled"
set_instance_parameter_value pcie bar2_address_width_hwtcl 0
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

# 32 KB scratch RAM at BAR0 + 0x8000.
#
# With the plain Avalon-MM HIP, the BAR0 size is derived from the address span
# behind rxm_bar0 (bar0_address_width_hwtcl is ignored). The PIO bank alone
# spans 0x00-0x4F, which gives a 128-byte BAR0; the Windows test driver ignores
# memory resources smaller than 0x1000. The RAM extends the span to 64 KB and
# also gives the host a block it can read and write freely.
add_instance scratch_ram altera_avalon_onchip_memory2
set_instance_parameter_value scratch_ram dataWidth 32
set_instance_parameter_value scratch_ram memorySize 32768
set_instance_parameter_value scratch_ram initMemContent false
set_instance_parameter_value scratch_ram dualPort false
set_instance_parameter_value scratch_ram singleClockOperation false
set_instance_parameter_value scratch_ram writable true

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

add_connection pcie.rxm_bar0 scratch_ram.s1
set_connection_parameter_value pcie.rxm_bar0/scratch_ram.s1 baseAddress 0x8000

# Register bank clock and reset.
foreach p {pio_a pio_b pio_sum pio_counter pio_id} {
    add_connection clk_100.clk       $p.clk
    add_connection clk_100.clk_reset $p.reset
}
add_connection clk_100.clk       scratch_ram.clk1
add_connection clk_100.clk_reset scratch_ram.reset1

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
