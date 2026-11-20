# --------------------------------------------------------------------------
# make_qsys.tcl — build dma_sys.qsys for the 07_dma project
#
# Run from this directory:
#   . ..\..\scripts\env.ps1   (required, see AGENTS.md section 7)
#   qsys-script --script=make_qsys.tcl --quartus-project=dma.qpf
#
# Copied from 03_pcie_gen3 (minimal template) and reworked for DMA. The
# system holds only what must live in Platform Designer; the DMA logic is
# RTL (dma_port.sv). Per hard IP port p (instances p<p>_*):
#   - Arria 10 PCIe hard IP, Gen3 x8 256-bit, "Avalon-MM with DMA", external
#     descriptor controller (internal_controller_hwtcl = 0, so rxm_bar0
#     exists), BAR0 64-bit prefetchable 64 KB, BAR2 disabled
#   - regs_br: Avalon-MM bridge on rxm_bar0 (64 KB, sizes BAR0), master side
#     exported to dma_port.sv
#   - the DMA descriptor sinks / status sources (rd_ast_*, wr_ast_*), both
#     DMA data masters and the TX slave (txs) exported to dma_port.sv
#   - the core clock and application reset exported through bridges
# Only port 0 (PCIe #1) is instantiated; add_dma_port 1 would add a second
# hard IP for PCIe #2 (not done: the lab host slot has 8 lanes).
# Plus the Arria 10 internal temperature sensor.
# --------------------------------------------------------------------------

package require -exact qsys 25.1

create_system
set_project_property DEVICE_FAMILY "Arria 10"
set_project_property DEVICE 10AXF40AA

proc add_dma_port {p} {
    set hip  p${p}_pcie
    set rbr  p${p}_regs_br
    set cbr  p${p}_clk_br
    set xbr  p${p}_rst_br

    # Arria 10 PCIe hard IP. Same base configuration as projects 03-06, plus:
    #   - maximum payload 256 bytes (the Avalon-MM interfaces allow 128 or 256)
    #   - TX slave address width 64 so the status record can go anywhere in
    #     host memory (64-bit DMA; the default is 22 bits)
    #   - receive buffer credits "Low" (as Intel's Gen3 x8 Avalon-MM DMA
    #     example ep_g3x8_avmm256: more space for read completions)
    add_instance $hip altera_pcie_a10_hip
    set_instance_parameter_value $hip device_family "Arria 10"
    set_instance_parameter_value $hip part_trait_device 10AXF40AA
    set_instance_parameter_value $hip targeted_devkit_hwtcl "Arria 10 GX FPGA Development Kit"
    set_instance_parameter_value $hip interface_type_hwtcl "Avalon-MM with DMA"
    set_instance_parameter_value $hip select_design_example_hwtcl "DMA"
    set_instance_parameter_value $hip internal_controller_hwtcl 0
    set_instance_parameter_value $hip enable_example_design_qii_hwtcl 0
    set_instance_parameter_value $hip enable_example_design_sim_hwtcl 0
    set_instance_parameter_value $hip enable_example_design_synth_hwtcl 0
    set_instance_parameter_value $hip enable_example_design_tb_hwtcl 0
    set_instance_parameter_value $hip wrala_hwtcl 0
    set_instance_parameter_value $hip vendor_id_hwtcl 4466
    set_instance_parameter_value $hip device_id_hwtcl 57347
    set_instance_parameter_value $hip class_code_hwtcl 16711680
    set_instance_parameter_value $hip bar0_type_hwtcl "64-bit prefetchable memory"
    set_instance_parameter_value $hip bar1_type_hwtcl "Disabled"
    set_instance_parameter_value $hip bar2_type_hwtcl "Disabled"
    set_instance_parameter_value $hip maximum_payload_size_hwtcl 256
    set_instance_parameter_value $hip avmm_addr_width_hwtcl 64
    set_instance_parameter_value $hip user_txs_addr_width_hwtcl 64
    set_instance_parameter_value $hip rx_buffer_credit_alloc_hwtcl "Low"
    set_instance_parameter_value $hip pcie_spec_version_hwtcl "3.0"

    # BAR0 register block: 64 KB Avalon-MM bridge on the core clock. The BAR0
    # size follows the address span behind rxm_bar0.
    add_instance $rbr altera_avalon_mm_bridge
    set_instance_parameter_value $rbr DATA_WIDTH 32
    set_instance_parameter_value $rbr SYMBOL_WIDTH 8
    set_instance_parameter_value $rbr ADDRESS_WIDTH 16
    set_instance_parameter_value $rbr ADDRESS_UNITS SYMBOLS
    set_instance_parameter_value $rbr MAX_BURST_SIZE 1
    set_instance_parameter_value $rbr MAX_PENDING_RESPONSES 4
    set_instance_parameter_value $rbr PIPELINE_COMMAND 1
    set_instance_parameter_value $rbr PIPELINE_RESPONSE 1
    set_instance_parameter_value $rbr USE_RESPONSE 0
    add_connection $hip.rxm_bar0 $rbr.s0
    set_connection_parameter_value $hip.rxm_bar0/$rbr.s0 baseAddress 0x0000
    add_connection $hip.coreclkout_hip    $rbr.clk
    add_connection $hip.app_nreset_status $rbr.reset

    # Core clock and application reset for the RTL (the HIP interfaces below
    # are synchronous to them).
    add_instance $cbr altera_clock_bridge
    set_instance_parameter_value $cbr EXPLICIT_CLOCK_RATE 250000000
    add_connection $hip.coreclkout_hip $cbr.in_clk

    add_instance $xbr altera_reset_bridge
    set_instance_parameter_value $xbr ACTIVE_LOW_RESET 1
    set_instance_parameter_value $xbr SYNCHRONOUS_EDGES "deassert"
    add_connection $hip.coreclkout_hip    $xbr.clk
    add_connection $hip.app_nreset_status $xbr.in_reset

    # Top-level interfaces.
    add_interface p${p}_pcie_refclk clock end
    set_interface_property p${p}_pcie_refclk EXPORT_OF $hip.refclk
    add_interface p${p}_pcie_npor conduit end
    set_interface_property p${p}_pcie_npor EXPORT_OF $hip.npor
    add_interface p${p}_pcie_hip_serial conduit end
    set_interface_property p${p}_pcie_hip_serial EXPORT_OF $hip.hip_serial

    add_interface p${p}_coreclk clock start
    set_interface_property p${p}_coreclk EXPORT_OF $cbr.out_clk
    add_interface p${p}_app_nreset reset start
    set_interface_property p${p}_app_nreset EXPORT_OF $xbr.out_reset

    add_interface p${p}_regs avalon start
    set_interface_property p${p}_regs EXPORT_OF $rbr.m0

    foreach i {rd_ast_rx wr_ast_rx} {
        add_interface p${p}_$i avalon_streaming end
        set_interface_property p${p}_$i EXPORT_OF $hip.$i
    }
    foreach i {rd_ast_tx wr_ast_tx} {
        add_interface p${p}_$i avalon_streaming start
        set_interface_property p${p}_$i EXPORT_OF $hip.$i
    }
    foreach i {dma_rd_master dma_wr_master} {
        add_interface p${p}_$i avalon start
        set_interface_property p${p}_$i EXPORT_OF $hip.$i
    }
    add_interface p${p}_txs avalon end
    set_interface_property p${p}_txs EXPORT_OF $hip.txs
}

add_dma_port 0

# Arria 10 internal temperature sensing diode (1 MHz internal clock).
add_instance temp altera_temp_sense
foreach i [get_instance_interfaces temp] {
    add_interface temp_$i conduit end
    set_interface_property temp_$i EXPORT_OF temp.$i
}

save_system dma_sys.qsys
