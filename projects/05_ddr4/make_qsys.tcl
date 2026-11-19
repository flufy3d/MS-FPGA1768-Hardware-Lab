# --------------------------------------------------------------------------
# make_qsys.tcl — build shell_sys.qsys for 05_ddr4
#
# Run from this directory:
#   . ..\..\scripts\env.ps1   (required, see AGENTS.md section 7)
#   Remove-Item -Recurse -Force ip\shell_sys, shell_sys
#   qsys-script --script=make_qsys.tcl --quartus-project=ddr4.qpf
#
# The static region ("shell") of a reusable PR design: everything below lives
# in the static region; the reconfigurable persona is instantiated in
# ddr4_top.sv, outside this system.
#
#   BAR0 (64-bit prefetchable, 64 KB)
#   0x0000  id_br      16 B   identity block implemented in ddr4_top.sv:
#                             0x00 SHELL_ID 0x53480501 ("SH", project 05, v1),
#                             0x04 CAPS 0x0000000D, 0x08 CAPS2 0 (reserved)
#   0x0030  COUNTER    PIO RO  free-running clk_100 counter
#   0x0040  ID         PIO RO  0x50434945 (the Windows test driver checks it)
#   0x0050  TEMP       PIO RO  die temperature sensor (as projects 03/04)
#   0x0060  PERSONA    PIO RO  persona ID and PR state (as project 04)
#   0x0100  pr_ip      PR controller (alt_pr), as project 04
#   0x0200  regs_br    256 B  shell registers implemented in ddr4_top.sv
#                             (DDR status, quiesce, flash page, DDR mailbox)
#   0x1000  persona_br 4 KB   persona register window (into the PR region)
#   0x4000  flash_br   16 KB  read-only window into the configuration flash
#                             (page register in the shell registers)
#   0x8000  scratch_ram 32 KB (sizes BAR0 to 64 KB, as projects 03/04)
#
# Two Arria 10 EMIF DDR4 controllers (top: banks 3E/3F/3G, refclk Y4;
# bottom: banks 3B/3C/3D, refclk Y3). Their Avalon-MM user ports are exported
# and connected in ddr4_top.sv to the persona through the static DDR port logic
# (ddr_port.sv).
#
# EMIF parameters are reproduced from the community DDR4_Dual project
# (github.com/tow3rs/catapult-v3-smartnic-re, Projects/DDR4/DDR4_Dual/Qsys.qsys,
# Quartus 20.1, commit dc125ea; status "reported": both channels calibrated on
# the PCIe card). Differences from that project:
#   - ECC disabled, 72-bit data interface (576-bit Avalon word), so that a
#     memory test sees every DQ line; DDR4_Dual enables ECC with correction.
#   - Calibration debug (EMIF toolkit) export disabled.
# The board skew values in DDR4_Dual are the IP's default values, not
# measurements; they are kept as they are (low confidence, see README).
# --------------------------------------------------------------------------

package require -exact qsys 25.1

create_system
set_project_property DEVICE_FAMILY "Arria 10"
set_project_property DEVICE 10AXF40AA

# 100 MHz board clock (AP20).
add_instance clk_100 clock_source
set_instance_parameter_value clk_100 clockFrequency 100000000
set_instance_parameter_value clk_100 clockFrequencyKnown true

# Arria 10 PCIe hard IP — identical to projects/03_pcie_gen3 and 04.
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

# 50 MHz clock for the PR controller and the flash controller. See project 04
# for why the PR controller cannot run at 100 MHz.
add_instance pll_pr altera_iopll
set_instance_parameter_value pll_pr gui_reference_clock_frequency 100.0
set_instance_parameter_value pll_pr gui_number_of_clocks 1
set_instance_parameter_value pll_pr gui_output_clock_frequency0 50.0
set_instance_parameter_value pll_pr gui_use_locked true

# Partial Reconfiguration Controller — identical to project 04.
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

# 32-bit Avalon PIO register bank (clk_100).
proc add_pio {name dir} {
    add_instance $name altera_avalon_pio
    set_instance_parameter_value $name direction $dir
    set_instance_parameter_value $name width 32
    set_instance_parameter_value $name clockRate 100000000
    set_instance_parameter_value $name resetValue 0
}

set PIOS {pio_counter pio_id pio_temp pio_persona}
set PIO_BASE {0x0030 0x0040 0x0050 0x0060}

foreach p $PIOS { add_pio $p Input }

# 32 KB scratch RAM at BAR0 + 0x8000 (sizes BAR0 to 64 KB).
add_instance scratch_ram altera_avalon_onchip_memory2
set_instance_parameter_value scratch_ram dataWidth 32
set_instance_parameter_value scratch_ram memorySize 32768
set_instance_parameter_value scratch_ram initMemContent false
set_instance_parameter_value scratch_ram dualPort false
set_instance_parameter_value scratch_ram singleClockOperation false
set_instance_parameter_value scratch_ram writable true

# Avalon-MM bridges whose master side is exported to ddr4_top.sv: the
# identity block (SHELL_ID, CAPS, CAPS2; the same 16-byte span as the
# SHELL_ID PIO it replaced), the shell register block, the persona register
# window and the flash window.
proc add_bridge {name addr_width} {
    add_instance $name altera_avalon_mm_bridge
    set_instance_parameter_value $name DATA_WIDTH 32
    set_instance_parameter_value $name SYMBOL_WIDTH 8
    set_instance_parameter_value $name ADDRESS_WIDTH $addr_width
    set_instance_parameter_value $name ADDRESS_UNITS SYMBOLS
    set_instance_parameter_value $name MAX_BURST_SIZE 1
    set_instance_parameter_value $name MAX_PENDING_RESPONSES 4
    set_instance_parameter_value $name PIPELINE_COMMAND 1
    set_instance_parameter_value $name PIPELINE_RESPONSE 1
    set_instance_parameter_value $name USE_RESPONSE 0
}
add_bridge id_br      4
add_bridge regs_br    8
add_bridge persona_br 12
add_bridge flash_br   14

# Configuration flash controller (ASMI Parallel II, dedicated AS pins).
# Its memory port is exported and connected in ddr4_top.sv with the write
# strobe tied low: the shell can only read the flash. (A write to the memory
# port of this IP issues WRITE ENABLE + PAGE PROGRAM by itself, see
# altera_asmi2_xip_controller in Quartus 25.1; the control/status port, which
# erases sectors, is exported and tied off as well.)
add_instance flash altera_asmi_parallel2_top
set_instance_parameter_value flash FLASH_TYPE "EPCQL1024"
set_instance_parameter_value flash DATA_WIDTH "STANDARD"
set_instance_parameter_value flash USE_ASMIBLOCK 0
set_instance_parameter_value flash USE_GPIO 0
set_instance_parameter_value flash NCS_NUM 1

# --------------------------------------------------------------------------
# DDR4 EMIF, one instance per channel. Values from DDR4_Dual (see header).
# --------------------------------------------------------------------------
proc add_emif {name} {
    add_instance $name altera_emif
    set p [list \
        PROTOCOL_ENUM                           PROTOCOL_DDR4 \
        PHY_DDR4_CONFIG_ENUM                    CONFIG_PHY_AND_HARD_CTRL \
        PHY_DDR4_MEM_CLK_FREQ_MHZ               1066.667 \
        PHY_DDR4_DEFAULT_REF_CLK_FREQ           false \
        PHY_DDR4_USER_REF_CLK_FREQ_MHZ          266.667 \
        PHY_DDR4_RATE_ENUM                      RATE_QUARTER \
        PHY_DDR4_IO_VOLTAGE                     1.2 \
        PHY_DDR4_DEFAULT_IO                     true \
        PHY_DDR4_USER_PING_PONG_EN              false \
        MEM_DDR4_FORMAT_ENUM                    MEM_FORMAT_DISCRETE \
        MEM_DDR4_DQ_WIDTH                       72 \
        MEM_DDR4_DQ_PER_DQS                     8 \
        MEM_DDR4_DISCRETE_CS_WIDTH              1 \
        MEM_DDR4_CK_WIDTH                       1 \
        MEM_DDR4_ROW_ADDR_WIDTH                 15 \
        MEM_DDR4_COL_ADDR_WIDTH                 10 \
        MEM_DDR4_BANK_ADDR_WIDTH                2 \
        MEM_DDR4_BANK_GROUP_WIDTH               1 \
        MEM_DDR4_DM_EN                          true \
        MEM_DDR4_READ_DBI                       true \
        MEM_DDR4_WRITE_DBI                      false \
        MEM_DDR4_ALERT_PAR_EN                   true \
        MEM_DDR4_ALERT_N_DQS_GROUP              0 \
        MEM_DDR4_DISCRETE_MIRROR_ADDRESSING_EN  false \
        MEM_DDR4_NUM_OF_DIMMS                   1 \
        MEM_DDR4_RANKS_PER_DIMM                 1 \
        MEM_DDR4_RTT_NOM_ENUM                   DDR4_RTT_NOM_RZQ_4 \
        MEM_DDR4_DRV_STR_ENUM                   DDR4_DRV_STR_RZQ_7 \
        MEM_DDR4_SPEEDBIN_ENUM                  DDR4_SPEEDBIN_2133 \
        MEM_DDR4_TCL                            15 \
        MEM_DDR4_WTCL                           12 \
        MEM_DDR4_TIS_PS                         60 \
        MEM_DDR4_TIS_AC_MV                      100 \
        MEM_DDR4_TIH_PS                         95 \
        MEM_DDR4_TIH_DC_MV                      75 \
        MEM_DDR4_TDQSQ_UI                       0.16 \
        MEM_DDR4_TQH_UI                         0.76 \
        MEM_DDR4_TDSS_CYC                       0.18 \
        MEM_DDR4_TDSH_CYC                       0.18 \
        MEM_DDR4_TRCD_NS                        14.06 \
        MEM_DDR4_TRP_NS                         14.06 \
        MEM_DDR4_TRAS_NS                        33.0 \
        MEM_DDR4_TWR_NS                         15.0 \
        MEM_DDR4_TRFC_NS                        260.0 \
        MEM_DDR4_TREFI_US                       7.8 \
        MEM_DDR4_TFAW_NS                        30.0 \
        MEM_DDR4_TRRD_S_CYC                     6 \
        MEM_DDR4_TRRD_L_CYC                     7 \
        MEM_DDR4_TCCD_S_CYC                     4 \
        MEM_DDR4_TCCD_L_CYC                     6 \
        PHY_DDR4_USER_AC_IO_STD_ENUM            IO_STD_SSTL_12 \
        PHY_DDR4_USER_AC_MODE_ENUM              OUT_OCT_40_CAL \
        PHY_DDR4_USER_CK_IO_STD_ENUM            IO_STD_SSTL_12 \
        PHY_DDR4_USER_CK_MODE_ENUM              OUT_OCT_40_CAL \
        PHY_DDR4_USER_DATA_IO_STD_ENUM          IO_STD_POD_12 \
        PHY_DDR4_USER_DATA_OUT_MODE_ENUM        OUT_OCT_34_CAL \
        PHY_DDR4_USER_DATA_IN_MODE_ENUM         IN_OCT_120_CAL \
        PHY_DDR4_USER_RZQ_IO_STD_ENUM           IO_STD_CMOS_12 \
        BOARD_DDR4_USE_DEFAULT_SLEW_RATES       true \
        BOARD_DDR4_USE_DEFAULT_ISI_VALUES       true \
        BOARD_DDR4_BRD_SKEW_WITHIN_DQS_NS       0.02 \
        BOARD_DDR4_PKG_BRD_SKEW_WITHIN_DQS_NS   0.02 \
        BOARD_DDR4_BRD_SKEW_WITHIN_AC_NS        0.02 \
        BOARD_DDR4_PKG_BRD_SKEW_WITHIN_AC_NS    0.02 \
        BOARD_DDR4_DQS_TO_CK_SKEW_NS            0.02 \
        BOARD_DDR4_SKEW_BETWEEN_DIMMS_NS        0.05 \
        BOARD_DDR4_SKEW_BETWEEN_DQS_NS          0.02 \
        BOARD_DDR4_AC_TO_CK_SKEW_NS             0.0 \
        BOARD_DDR4_MAX_CK_DELAY_NS              0.6 \
        BOARD_DDR4_MAX_DQS_DELAY_NS             0.6 \
        BOARD_DDR4_IS_SKEW_WITHIN_DQS_DESKEWED  true \
        BOARD_DDR4_IS_SKEW_WITHIN_AC_DESKEWED   false \
        CTRL_DDR4_ECC_EN                        false \
        CTRL_DDR4_ECC_AUTO_CORRECTION_EN        false \
        CTRL_DDR4_MMR_EN                        false \
        CTRL_DDR4_REORDER_EN                    true \
        CTRL_DDR4_STARVE_LIMIT                  10 \
        CTRL_DDR4_AUTO_PRECHARGE_EN             false \
        CTRL_DDR4_USER_REFRESH_EN               false \
        DIAG_DDR4_EXPORT_SEQ_AVALON_MASTER      false \
        DIAG_DDR4_CAL_FULL_CAL_ON_RESET         true \
    ]
    foreach {k v} $p {
        set_instance_parameter_value $name $k $v
    }
}
add_emif emif_top
add_emif emif_bot

# --------------------------------------------------------------------------
# BAR0 decode
# --------------------------------------------------------------------------
foreach p $PIOS b $PIO_BASE {
    add_connection pcie.rxm_bar0 $p.s1
    set_connection_parameter_value pcie.rxm_bar0/$p.s1 baseAddress $b
}

add_connection pcie.rxm_bar0 id_br.s0
set_connection_parameter_value pcie.rxm_bar0/id_br.s0 baseAddress 0x0000

add_connection pcie.rxm_bar0 pr_ip.avmm_slave
set_connection_parameter_value pcie.rxm_bar0/pr_ip.avmm_slave baseAddress 0x0100

add_connection pcie.rxm_bar0 regs_br.s0
set_connection_parameter_value pcie.rxm_bar0/regs_br.s0 baseAddress 0x0200

add_connection pcie.rxm_bar0 persona_br.s0
set_connection_parameter_value pcie.rxm_bar0/persona_br.s0 baseAddress 0x1000

add_connection pcie.rxm_bar0 flash_br.s0
set_connection_parameter_value pcie.rxm_bar0/flash_br.s0 baseAddress 0x4000

add_connection pcie.rxm_bar0 scratch_ram.s1
set_connection_parameter_value pcie.rxm_bar0/scratch_ram.s1 baseAddress 0x8000

# --------------------------------------------------------------------------
# Clocks and resets
# --------------------------------------------------------------------------
foreach p $PIOS {
    add_connection clk_100.clk       $p.clk
    add_connection clk_100.clk_reset $p.reset
}
foreach b {id_br regs_br persona_br} {
    add_connection clk_100.clk       $b.clk
    add_connection clk_100.clk_reset $b.reset
}
add_connection clk_100.clk       scratch_ram.clk1
add_connection clk_100.clk_reset scratch_ram.reset1
add_connection clk_100.clk       pll_pr.refclk
add_connection pll_pr.outclk0    pr_ip.clk
add_connection clk_100.clk_reset pr_ip.nreset
add_connection pll_pr.outclk0    flash_br.clk
add_connection clk_100.clk_reset flash_br.reset
add_connection pll_pr.outclk0    flash.clk
add_connection clk_100.clk_reset flash.reset

# --------------------------------------------------------------------------
# Exported interfaces
# --------------------------------------------------------------------------
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
# Driven by a power-up pulse in ddr4_top.sv (Quartus rejects a constant).
add_interface pll_pr_reset reset end
set_interface_property pll_pr_reset EXPORT_OF pll_pr.reset
# The 50 MHz clock is also needed in ddr4_top.sv (flash window glue logic).
add_instance clk_50_br altera_clock_bridge
set_instance_parameter_value clk_50_br EXPLICIT_CLOCK_RATE 50000000
add_connection pll_pr.outclk0 clk_50_br.in_clk
add_interface clk_50 clock start
set_interface_property clk_50 EXPORT_OF clk_50_br.out_clk

foreach b {id_br regs_br persona_br flash_br} {
    add_interface ${b}_m0 avalon start
    set_interface_property ${b}_m0 EXPORT_OF $b.m0
}

add_interface flash_mem avalon end
set_interface_property flash_mem EXPORT_OF flash.avl_mem
add_interface flash_csr avalon end
set_interface_property flash_csr EXPORT_OF flash.avl_csr

# EMIF: every interface except the clock/reset sinks is exported; ddr4_top.sv
# connects them (pins, refclk, OCT, status, user clock/reset, Avalon port).
proc export_all {inst} {
    foreach i [get_instance_interfaces $inst] {
        set cls [get_instance_interface_property $inst $i CLASS_NAME]
        switch -glob -- $cls {
            clock_sink     { set t {clock end} }
            clock_source   { set t {clock start} }
            reset_sink     { set t {reset end} }
            reset_source   { set t {reset start} }
            avalon_slave   { set t {avalon end} }
            avalon_master  { set t {avalon start} }
            default        { set t {conduit end} }
        }
        # qsys-script runs Jacl (no {*} expansion).
        add_interface ${inst}_$i [lindex $t 0] [lindex $t 1]
        set_interface_property ${inst}_$i EXPORT_OF $inst.$i
    }
}
export_all emif_top
export_all emif_bot

save_system shell_sys.qsys
