# --------------------------------------------------------------------------
# make_qsys.tcl — build i2c_sys.qsys for the 06_i2c_telemetry project
#
# Run from this directory:
#   . ..\..\scripts\env.ps1   (required, see AGENTS.md section 7)
#   qsys-script --script=make_qsys.tcl --quartus-project=i2c_telemetry.qpf
#
# Copied from 03_pcie_gen3 (PCIe part unchanged). The system contains:
#   - Arria 10 PCIe hard IP, Gen3 x8 256-bit, Avalon-MM with DMA (external
#     descriptor controller, DMA unused), BAR0 64-bit prefetchable 64 KB
#   - regs_br: a 256-byte Avalon-MM bridge at BAR0 + 0x0000 whose master side
#     is exported to bar0_regs.sv (SHELL_ID, CAPS, COUNTER, ID, TEMP and the
#     I2C master registers; map in bar0_regs.sv and README.md)
#   - Arria 10 internal temperature sensor (read through TEMP)
#   - 32 KB scratch RAM at 0x8000 (sets the BAR0 span to 64 KB)
#   - 100 MHz clock source for the register bank
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
# "Avalon-MM with DMA", Gen3 x8, 256-bit (wrala_hwtcl = 0). This mode forces
# BAR0 to 64-bit prefetchable memory. Two changes against the 2026-11-17
# variant:
#   - internal_controller_hwtcl = 0: with the internal DMA descriptor
#     controller the HIP has no rxm_bar0 and BAR0 belongs to the controller.
#     With it off, rxm_bar0 exists and drives the register bank. The DMA
#     descriptor streams and data masters are left unconnected (DMA unused).
#   - BAR2 disabled: nothing is connected to rxm_bar2.
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

# BAR0 register block: Avalon-MM bridge, master side exported to
# bar0_regs.sv (256 bytes at BAR0 + 0x0000, clk_100).
add_instance regs_br altera_avalon_mm_bridge
set_instance_parameter_value regs_br DATA_WIDTH 32
set_instance_parameter_value regs_br SYMBOL_WIDTH 8
set_instance_parameter_value regs_br ADDRESS_WIDTH 8
set_instance_parameter_value regs_br ADDRESS_UNITS SYMBOLS
set_instance_parameter_value regs_br MAX_BURST_SIZE 1
set_instance_parameter_value regs_br MAX_PENDING_RESPONSES 4
set_instance_parameter_value regs_br PIPELINE_COMMAND 1
set_instance_parameter_value regs_br PIPELINE_RESPONSE 1
set_instance_parameter_value regs_br USE_RESPONSE 0

# 32 KB scratch RAM at BAR0 + 0x8000.
#
# The BAR0 size is derived from the address span behind rxm_bar0
# (bar0_address_width_hwtcl is ignored). The register block alone
# spans 0x00-0xFF, which gives a 256-byte BAR0; the Windows test driver ignores
# memory resources smaller than 0x1000. The RAM extends the span to 64 KB and
# also gives the host a block it can read and write freely.
add_instance scratch_ram altera_avalon_onchip_memory2
set_instance_parameter_value scratch_ram dataWidth 32
set_instance_parameter_value scratch_ram memorySize 32768
set_instance_parameter_value scratch_ram initMemContent false
set_instance_parameter_value scratch_ram dualPort false
set_instance_parameter_value scratch_ram singleClockOperation false
set_instance_parameter_value scratch_ram writable true

# BAR0 decode.
add_connection pcie.rxm_bar0 regs_br.s0
set_connection_parameter_value pcie.rxm_bar0/regs_br.s0 baseAddress 0x0000

add_connection pcie.rxm_bar0 scratch_ram.s1
set_connection_parameter_value pcie.rxm_bar0/scratch_ram.s1 baseAddress 0x8000

# Register bank clock and reset.
add_connection clk_100.clk       regs_br.clk
add_connection clk_100.clk_reset regs_br.reset
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

add_interface regs_br_m0 avalon start
set_interface_property regs_br_m0 EXPORT_OF regs_br.m0

foreach i [get_instance_interfaces temp] {
    add_interface temp_$i conduit end
    set_interface_property temp_$i EXPORT_OF temp.$i
}

save_system i2c_sys.qsys
