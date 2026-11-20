`default_nettype none

// --------------------------------------------------------------------------
// dma — PCIe #1 Gen3 x8 DMA throughput test (07_dma)
//
// dma_sys (Platform Designer) holds the Arria 10 PCIe hard IP in
// "Avalon-MM with DMA" mode with an external descriptor controller, the
// BAR0 bridge and the temperature sensor. dma_port (one per hard IP) is the
// descriptor engine, data sources/sinks and BAR0 registers; see dma_port.sv
// for the register map and README.md for the host side.
//
// Everything runs on the hard IP core clock (250 MHz). The temperature
// sensor logic is the one of projects 03-06, moved from clk_100 to the core
// clock with a 4x longer conversion timer.
//
// A second hard IP (PCIe #2) would be one more add_dma_port in make_qsys.tcl
// and one more dma_port instance here with PORT_INDEX = 1.
// --------------------------------------------------------------------------
module dma (
    input  wire        clk_pcie1,      // AN29/AN28, 100 MHz PCIe #1 refclk
    input  wire        pcie1_perstn,   // AW16, PCIe #1 PERST#
    input  wire [7:0]  pcie1_rx,       // AN33/AN32 ... AH31/AH30
    output wire [7:0]  pcie1_tx        // AU37/AU36 ... AM39/AM38
);

    wire         clk;
    wire         app_nreset;

    // BAR0 bridge
    wire [15:0]  av_address;
    wire         av_read, av_write;
    wire [31:0]  av_writedata, av_readdata;
    wire         av_readdatavalid;

    // DMA interfaces of the hard IP
    wire         rd_desc_valid, rd_desc_ready, rd_st_valid;
    wire [159:0] rd_desc_data;
    wire [31:0]  rd_st_data;
    wire         wr_desc_valid, wr_desc_ready, wr_st_valid;
    wire [159:0] wr_desc_data;
    wire [31:0]  wr_st_data;
    wire [63:0]  rdm_address;
    wire         rdm_write, rdm_waitrequest;
    wire [255:0] rdm_writedata;
    wire [31:0]  rdm_byteenable;
    wire [4:0]   rdm_burstcount;
    wire [63:0]  wrm_address;
    wire         wrm_read, wrm_waitrequest, wrm_readdatavalid;
    wire [255:0] wrm_readdata;
    wire [4:0]   wrm_burstcount;
    wire [63:0]  txs_address;
    wire         txs_chipselect, txs_write, txs_read, txs_waitrequest;
    wire [31:0]  txs_writedata;
    wire [3:0]   txs_byteenable;
    wire [4:0]   txs_burstcount;

    // Reset: app_nreset_status from the hard IP (synchronous deassertion in
    // the reset bridge), re-registered once here.
    logic rst = 1'b1;
    always_ff @(posedge clk) rst <= !app_nreset;

    // ----------------------------------------------------------------------
    // Internal temperature sensor (as projects 03-06, on the core clock).
    // One conversion every 2^26 cycles (about 0.27 s at 250 MHz); the sensor
    // reset is held for the first 2^18 cycles (about 1 ms) of each period.
    // TEMP word: [9:0] code latched at end of conversion, [25:16] raw output,
    // [27] eoc, [31:28] conversion counter. degC = code * 693 / 1024 - 265.
    // ----------------------------------------------------------------------
    wire [9:0]  ts_tempout;
    wire        ts_eoc;
    logic [25:0] ts_timer = 26'd0;
    logic        ts_reset = 1'b1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) logic [2:0] ts_eoc_sync = 3'd0;
    logic [9:0]  ts_raw_m = 10'd0, ts_raw = 10'd0;
    logic [9:0]  ts_code = 10'd0;
    logic [3:0]  ts_count = 4'd0;
    logic [7:0]  ts_settle = 8'd0;

    always_ff @(posedge clk) begin
        ts_timer    <= ts_timer + 26'd1;
        ts_reset    <= (ts_timer[25:18] == 8'd0);
        ts_eoc_sync <= {ts_eoc_sync[1:0], ts_eoc};
        ts_raw_m    <= ts_tempout;
        ts_raw      <= ts_raw_m;
        // Latch the code 128 cycles after eoc rises, when tempout is stable.
        if (ts_eoc_sync[2:1] == 2'b01)
            ts_settle <= 8'd128;
        else if (ts_settle != 8'd0) begin
            ts_settle <= ts_settle - 8'd1;
            if (ts_settle == 8'd1) begin
                ts_code  <= ts_raw;
                ts_count <= ts_count + 4'd1;
            end
        end
    end

    wire [31:0] temp_word = {ts_count, ts_eoc_sync[2], 1'b0, ts_raw, 6'd0, ts_code};

    // ----------------------------------------------------------------------
    dma_sys u_sys (
        .p0_coreclk_clk                 (clk),
        .p0_app_nreset_reset_n          (app_nreset),

        .p0_pcie_refclk_clk             (clk_pcie1),
        .p0_pcie_npor_npor              (1'b1),
        .p0_pcie_npor_pin_perst         (pcie1_perstn),
        .p0_pcie_hip_serial_rx_in0      (pcie1_rx[0]),
        .p0_pcie_hip_serial_rx_in1      (pcie1_rx[1]),
        .p0_pcie_hip_serial_rx_in2      (pcie1_rx[2]),
        .p0_pcie_hip_serial_rx_in3      (pcie1_rx[3]),
        .p0_pcie_hip_serial_rx_in4      (pcie1_rx[4]),
        .p0_pcie_hip_serial_rx_in5      (pcie1_rx[5]),
        .p0_pcie_hip_serial_rx_in6      (pcie1_rx[6]),
        .p0_pcie_hip_serial_rx_in7      (pcie1_rx[7]),
        .p0_pcie_hip_serial_tx_out0     (pcie1_tx[0]),
        .p0_pcie_hip_serial_tx_out1     (pcie1_tx[1]),
        .p0_pcie_hip_serial_tx_out2     (pcie1_tx[2]),
        .p0_pcie_hip_serial_tx_out3     (pcie1_tx[3]),
        .p0_pcie_hip_serial_tx_out4     (pcie1_tx[4]),
        .p0_pcie_hip_serial_tx_out5     (pcie1_tx[5]),
        .p0_pcie_hip_serial_tx_out6     (pcie1_tx[6]),
        .p0_pcie_hip_serial_tx_out7     (pcie1_tx[7]),

        .p0_txs_address                 (txs_address),
        .p0_txs_chipselect              (txs_chipselect),
        .p0_txs_byteenable              (txs_byteenable),
        .p0_txs_readdata                (),
        .p0_txs_writedata               (txs_writedata),
        .p0_txs_read                    (txs_read),
        .p0_txs_write                   (txs_write),
        .p0_txs_readdatavalid           (),
        .p0_txs_waitrequest             (txs_waitrequest),

        .p0_rd_ast_rx_valid             (rd_desc_valid),
        .p0_rd_ast_rx_data              (rd_desc_data),
        .p0_rd_ast_rx_ready             (rd_desc_ready),
        .p0_rd_ast_tx_valid             (rd_st_valid),
        .p0_rd_ast_tx_data              (rd_st_data),
        .p0_wr_ast_rx_valid             (wr_desc_valid),
        .p0_wr_ast_rx_data              (wr_desc_data),
        .p0_wr_ast_rx_ready             (wr_desc_ready),
        .p0_wr_ast_tx_valid             (wr_st_valid),
        .p0_wr_ast_tx_data              (wr_st_data),

        .p0_dma_rd_master_address       (rdm_address),
        .p0_dma_rd_master_write         (rdm_write),
        .p0_dma_rd_master_writedata     (rdm_writedata),
        .p0_dma_rd_master_waitrequest   (rdm_waitrequest),
        .p0_dma_rd_master_burstcount    (rdm_burstcount),
        .p0_dma_rd_master_byteenable    (rdm_byteenable),
        .p0_dma_wr_master_address       (wrm_address),
        .p0_dma_wr_master_read          (wrm_read),
        .p0_dma_wr_master_readdata      (wrm_readdata),
        .p0_dma_wr_master_waitrequest   (wrm_waitrequest),
        .p0_dma_wr_master_burstcount    (wrm_burstcount),
        .p0_dma_wr_master_readdatavalid (wrm_readdatavalid),

        .p0_regs_waitrequest            (1'b0),
        .p0_regs_readdata               (av_readdata),
        .p0_regs_readdatavalid          (av_readdatavalid),
        .p0_regs_burstcount             (),
        .p0_regs_writedata              (av_writedata),
        .p0_regs_address                (av_address),
        .p0_regs_write                  (av_write),
        .p0_regs_read                   (av_read),
        .p0_regs_byteenable             (),
        .p0_regs_debugaccess            (),

        .temp_corectl_corectl           (1'b1),
        .temp_reset_reset               (ts_reset),
        .temp_tempout_tempout           (ts_tempout),
        .temp_eoc_eoc                   (ts_eoc)
    );

    dma_port #(
        .PORT_INDEX (0),
        .RAM_BANKS  (256)            // 4 MB
    ) u_port0 (
        .clk               (clk),
        .rst               (rst),
        .temp_word         (temp_word),
        .av_address        (av_address),
        .av_read           (av_read),
        .av_write          (av_write),
        .av_writedata      (av_writedata),
        .av_readdata       (av_readdata),
        .av_readdatavalid  (av_readdatavalid),
        .rd_desc_valid     (rd_desc_valid),
        .rd_desc_data      (rd_desc_data),
        .rd_desc_ready     (rd_desc_ready),
        .rd_st_valid       (rd_st_valid),
        .rd_st_data        (rd_st_data),
        .rdm_address       (rdm_address),
        .rdm_write         (rdm_write),
        .rdm_writedata     (rdm_writedata),
        .rdm_byteenable    (rdm_byteenable),
        .rdm_burstcount    (rdm_burstcount),
        .rdm_waitrequest   (rdm_waitrequest),
        .wr_desc_valid     (wr_desc_valid),
        .wr_desc_data      (wr_desc_data),
        .wr_desc_ready     (wr_desc_ready),
        .wr_st_valid       (wr_st_valid),
        .wr_st_data        (wr_st_data),
        .wrm_address       (wrm_address),
        .wrm_read          (wrm_read),
        .wrm_burstcount    (wrm_burstcount),
        .wrm_waitrequest   (wrm_waitrequest),
        .wrm_readdata      (wrm_readdata),
        .wrm_readdatavalid (wrm_readdatavalid),
        .txs_address       (txs_address),
        .txs_chipselect    (txs_chipselect),
        .txs_write         (txs_write),
        .txs_writedata     (txs_writedata),
        .txs_byteenable    (txs_byteenable),
        .txs_burstcount    (txs_burstcount),
        .txs_read          (txs_read),
        .txs_waitrequest   (txs_waitrequest)
    );

endmodule

`default_nettype wire
