`default_nettype none

// --------------------------------------------------------------------------
// ddr4_top — DDR4 static region ("shell") for the Microsoft FPGA 1768 (project 05)
//
// Static region: PCIe #1 Gen3 x8 endpoint (BAR0), die temperature, PR
// controller, two DDR4 EMIF channels with their persona ports (ddr_port),
// shell registers, read-only configuration flash window, LEDs [3:0].
// Reconfigurable region: u_persona (persona_walk in the base revision,
// persona_prbs in the implementation revision). The persona ABI (ports of
// u_persona) is fixed for every persona built against this shell.
//
// BAR0 map: see make_qsys.tcl and the README.
// LEDs: [0] top calibrated, [1] bottom calibrated, [2] calibration failed
// (either channel), [3] 1 Hz heartbeat; [8:4] driven by the persona
// (off while the persona is frozen or in reset).
// --------------------------------------------------------------------------
module ddr4_top (
    input  wire         clk_100,        // AP20, 100 MHz board oscillator
    input  wire         clk_pcie1,      // AN29/AN28, 100 MHz PCIe #1 refclk
    input  wire         pcie1_perstn,   // AW16
    input  wire [7:0]   pcie1_rx,
    output wire [7:0]   pcie1_tx,

    output wire [8:0]   led,

    // DDR4 top channel (U7-U11), refclk Y4
    input  wire         top_refclk,
    input  wire         top_oct_rzqin,
    output wire [0:0]   top_mem_ck,
    output wire [0:0]   top_mem_ck_n,
    output wire [16:0]  top_mem_a,
    output wire [0:0]   top_mem_act_n,
    output wire [1:0]   top_mem_ba,
    output wire [0:0]   top_mem_bg,
    output wire [0:0]   top_mem_cke,
    output wire [0:0]   top_mem_cs_n,
    output wire [0:0]   top_mem_odt,
    output wire [0:0]   top_mem_reset_n,
    output wire [0:0]   top_mem_par,
    input  wire [0:0]   top_mem_alert_n,
    inout  wire [8:0]   top_mem_dqs,
    inout  wire [8:0]   top_mem_dqs_n,
    inout  wire [71:0]  top_mem_dq,
    inout  wire [8:0]   top_mem_dbi_n,

    // DDR4 bottom channel (U2-U6), refclk Y3
    input  wire         bot_refclk,
    input  wire         bot_oct_rzqin,
    output wire [0:0]   bot_mem_ck,
    output wire [0:0]   bot_mem_ck_n,
    output wire [16:0]  bot_mem_a,
    output wire [0:0]   bot_mem_act_n,
    output wire [1:0]   bot_mem_ba,
    output wire [0:0]   bot_mem_bg,
    output wire [0:0]   bot_mem_cke,
    output wire [0:0]   bot_mem_cs_n,
    output wire [0:0]   bot_mem_odt,
    output wire [0:0]   bot_mem_reset_n,
    output wire [0:0]   bot_mem_par,
    input  wire [0:0]   bot_mem_alert_n,
    inout  wire [8:0]   bot_mem_dqs,
    inout  wire [8:0]   bot_mem_dqs_n,
    inout  wire [71:0]  bot_mem_dq,
    inout  wire [8:0]   bot_mem_dbi_n
);
    // Identity block, BAR0 + 0x00 (the minimal contract of the host tool):
    //   0x00 SHELL_ID  "SH", project 05, shell v1
    //   0x04 CAPS      [0] DDR4, [1] I2C (not present), [2] PR, [3] flash window
    //   0x08 CAPS2     reserved, 0
    //   0x0C           reads 0
    localparam [31:0] SHELL_ID = 32'h53480501;
    localparam [31:0] CAPS     = 32'h0000000D;
    localparam [31:0] CAPS2    = 32'h00000000;

    // ----------------------------------------------------------------------
    // Power-up pulses: PR/flash clock PLL reset and EMIF global reset
    // (neither may be tied to a constant).
    // ----------------------------------------------------------------------
    reg [8:0]  pll_rst_cnt = 9'd0;
    reg [11:0] emif_rst_cnt = 12'd0;
    always_ff @(posedge clk_100) begin
        if (!pll_rst_cnt[8])   pll_rst_cnt  <= pll_rst_cnt + 9'd1;
        if (!emif_rst_cnt[11]) emif_rst_cnt <= emif_rst_cnt + 12'd1;
    end
    wire pll_pr_reset  = ~pll_rst_cnt[8];        // 2.56 us
    reg  emif_rst_n    = 1'b0;                    // released after 20.48 us
    always_ff @(posedge clk_100) emif_rst_n <= emif_rst_cnt[11];

    wire        pll_pr_locked;
    wire        clk_50;
    wire [1:0]  pll_locked_s;
    sync_bits #(.W(1)) u_sync_lock (.clk(clk_100), .d(pll_pr_locked), .q(pll_locked_s[0]));
    assign pll_locked_s[1] = 1'b0;

    reg [31:0] counter = 32'd0;
    always_ff @(posedge clk_100) counter <= counter + 32'd1;

    // ----------------------------------------------------------------------
    // Persona reset and freeze — as project 04. While freeze is high and
    // for 511 clk_100 cycles after it falls, the persona is in reset and
    // every persona output is ignored or replaced by zero.
    // ----------------------------------------------------------------------
    wire       pr_freeze;
    reg  [8:0] persona_hold = 9'h1FF;
    reg        persona_rst  = 1'b1;
    always_ff @(posedge clk_100) begin
        if (pr_freeze)
            persona_hold <= 9'h1FF;
        else if (persona_hold != 9'd0)
            persona_hold <= persona_hold - 9'd1;
        persona_rst <= pr_freeze | (persona_hold != 9'd0);
    end

    // ----------------------------------------------------------------------
    // Temperature sensor — unchanged from projects 03/04.
    // ----------------------------------------------------------------------
    wire [9:0] ts_tempout;
    wire       ts_eoc;
    reg  [23:0] ts_timer = 24'd0;
    reg         ts_reset = 1'b1;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [2:0] ts_eoc_sync = 3'd0;
    reg  [9:0]  ts_raw_m = 10'd0, ts_raw = 10'd0;
    reg  [9:0]  ts_code = 10'd0;
    reg  [3:0]  ts_count = 4'd0;
    reg  [7:0]  ts_settle = 8'd0;
    always_ff @(posedge clk_100) begin
        ts_timer    <= ts_timer + 24'd1;
        ts_reset    <= (ts_timer[23:16] == 8'd0);
        ts_eoc_sync <= {ts_eoc_sync[1:0], ts_eoc};
        ts_raw_m    <= ts_tempout;
        ts_raw      <= ts_raw_m;
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
    wire [31:0] pio_temp = {ts_count, ts_eoc_sync[2], 1'b0, ts_raw, 6'd0, ts_code};

    // ----------------------------------------------------------------------
    // EMIF signals
    // ----------------------------------------------------------------------
    wire         t_clk, b_clk, t_urst_n, b_urst_n;
    wire         t_cal_ok, t_cal_fail, b_cal_ok, b_cal_fail;
    wire         te_read, te_write, te_ready, te_rvalid;
    wire [24:0]  te_addr;
    wire [575:0] te_wdata, te_rdata;
    wire [71:0]  te_be;
    wire [6:0]   te_burst;
    wire         be_read, be_write, be_ready, be_rvalid;
    wire [24:0]  be_addr;
    wire [575:0] be_wdata, be_rdata;
    wire [71:0]  be_be;
    wire [6:0]   be_burst;

    // ----------------------------------------------------------------------
    // Identity block (BAR0 + 0x00, 16 bytes, read only; writes are ignored)
    // ----------------------------------------------------------------------
    wire [3:0]   id_addr;
    wire         id_read;
    reg  [31:0]  id_rdata  = 32'd0;
    reg          id_rvalid = 1'b0;
    always_ff @(posedge clk_100) begin
        id_rvalid <= id_read;
        if (id_read) begin
            case (id_addr[3:2])
                2'd0:    id_rdata <= SHELL_ID;
                2'd1:    id_rdata <= CAPS;
                2'd2:    id_rdata <= CAPS2;
                default: id_rdata <= 32'd0;
            endcase
        end
    end

    // ----------------------------------------------------------------------
    // Shell registers (BAR0 + 0x200)
    // ----------------------------------------------------------------------
    wire [7:0]   regs_addr;
    wire         regs_read, regs_write;
    wire [31:0]  regs_wdata, regs_rdata;
    wire         regs_rvalid;

    wire         quiesce_req;
    wire [12:0]  flash_page;
    wire [1:0]   mb_go_tg, mb_done_tg, mb_err, quiesced;
    wire         mbx_wr;
    wire [24:0]  mbx_addr;
    wire [575:0] mbx_wdata, mbres_top, mbres_bot;

    shell_regs u_regs (
        .clk            (clk_100),
        .address        (regs_addr),
        .read           (regs_read),
        .write          (regs_write),
        .writedata      (regs_wdata),
        .readdata       (regs_rdata),
        .readdatavalid  (regs_rvalid),
        .cal_success_a  ({b_cal_ok, t_cal_ok}),
        .cal_fail_a     ({b_cal_fail, t_cal_fail}),
        .usr_rst_n_a    ({b_urst_n, t_urst_n}),
        .quiesced_a     (quiesced),
        .quiesce_req    (quiesce_req),
        .flash_page     (flash_page),
        .mb_go_tg       (mb_go_tg),
        .mbx_wr         (mbx_wr),
        .mbx_addr       (mbx_addr),
        .mbx_wdata      (mbx_wdata),
        .mb_done_tg_a   (mb_done_tg),
        .mb_err_a       (mb_err),
        .mbres_top      (mbres_top),
        .mbres_bot      (mbres_bot)
    );

    // ----------------------------------------------------------------------
    // Persona and its DDR ports
    // ----------------------------------------------------------------------
    wire         tp_rst, bp_rst, tp_read, tp_write, tp_ready, tp_rvalid;
    wire         bp_read, bp_write, bp_ready, bp_rvalid;
    wire [24:0]  tp_addr, bp_addr;
    wire [575:0] tp_wdata, tp_rdata, bp_wdata, bp_rdata;
    wire [71:0]  tp_be, bp_be;

    ddr_port u_port_top (
        .clk (t_clk), .usr_rst_n (t_urst_n),
        .gate_a (quiesce_req), .prst_a (persona_rst),
        .p_rst (tp_rst), .p_addr (tp_addr), .p_read (tp_read), .p_write (tp_write),
        .p_wdata (tp_wdata), .p_be (tp_be), .p_ready (tp_ready),
        .p_rdata (tp_rdata), .p_rvalid (tp_rvalid),
        .mb_go_tg_a (mb_go_tg[0]), .mb_wr_a (mbx_wr), .mb_addr_a (mbx_addr),
        .mb_wdata_a (mbx_wdata), .mb_done_tg (mb_done_tg[0]), .mb_err (mb_err[0]),
        .mbres_rdata (mbres_top), .quiesced (quiesced[0]),
        .e_read (te_read), .e_write (te_write), .e_addr (te_addr), .e_wdata (te_wdata),
        .e_be (te_be), .e_burst (te_burst), .e_ready (te_ready),
        .e_rdata (te_rdata), .e_rvalid (te_rvalid)
    );

    ddr_port u_port_bot (
        .clk (b_clk), .usr_rst_n (b_urst_n),
        .gate_a (quiesce_req), .prst_a (persona_rst),
        .p_rst (bp_rst), .p_addr (bp_addr), .p_read (bp_read), .p_write (bp_write),
        .p_wdata (bp_wdata), .p_be (bp_be), .p_ready (bp_ready),
        .p_rdata (bp_rdata), .p_rvalid (bp_rvalid),
        .mb_go_tg_a (mb_go_tg[1]), .mb_wr_a (mbx_wr), .mb_addr_a (mbx_addr),
        .mb_wdata_a (mbx_wdata), .mb_done_tg (mb_done_tg[1]), .mb_err (mb_err[1]),
        .mbres_rdata (mbres_bot), .quiesced (quiesced[1]),
        .e_read (be_read), .e_write (be_write), .e_addr (be_addr), .e_wdata (be_wdata),
        .e_be (be_be), .e_burst (be_burst), .e_ready (be_ready),
        .e_rdata (be_rdata), .e_rvalid (be_rvalid)
    );

    // Persona register window (BAR0 + 0x1000): no wait states, read data one
    // cycle after the read; reads return 0 and writes are dropped while the
    // persona is frozen or in reset.
    wire [11:0] pbr_addr;
    wire        pbr_read, pbr_write;
    wire [31:0] pbr_wdata, p_csr_rdata;
    reg         pbr_rvalid = 1'b0;
    reg         pbr_rgate  = 1'b0;
    wire [15:0] p_id;
    wire [4:0]  p_led;

    always_ff @(posedge clk_100) begin
        pbr_rvalid <= pbr_read;
        pbr_rgate  <= persona_rst;
    end

    // Reconfigurable partition (pr_partition). Entity persona_walk in the
    // base revision; rebound to persona_prbs in ddr4_prbs.qsf.
    persona_walk u_persona (
        .clk_100    (clk_100),
        .rst_100    (persona_rst),
        .csr_addr   (pbr_addr[11:2]),
        .csr_read   (pbr_read & ~persona_rst),
        .csr_write  (pbr_write & ~persona_rst),
        .csr_wdata  (pbr_wdata),
        .csr_rdata  (p_csr_rdata),
        .persona_id (p_id),
        .led        (p_led),
        .t_clk (t_clk), .t_rst (tp_rst), .t_addr (tp_addr), .t_read (tp_read),
        .t_write (tp_write), .t_wdata (tp_wdata), .t_be (tp_be), .t_ready (tp_ready),
        .t_rdata (tp_rdata), .t_rvalid (tp_rvalid),
        .b_clk (b_clk), .b_rst (bp_rst), .b_addr (bp_addr), .b_read (bp_read),
        .b_write (bp_write), .b_wdata (bp_wdata), .b_be (bp_be), .b_ready (bp_ready),
        .b_rdata (bp_rdata), .b_rvalid (bp_rvalid)
    );

    wire [31:0] pbr_rdata = pbr_rgate ? 32'd0 : p_csr_rdata;

    wire [31:0] pio_persona = {13'd0, pll_locked_s[0], persona_rst, pr_freeze,
                               persona_rst ? 16'd0 : p_id};

    // ----------------------------------------------------------------------
    // Read-only flash window (50 MHz): BAR0 + 0x4000, 16 KB, page register
    // FLASH_PAGE. The write strobe to the flash controller is tied low here;
    // writes from the host complete without effect.
    // ----------------------------------------------------------------------
    wire [13:0] fbr_addr;
    wire        fbr_read, fbr_write;
    wire        fl_waitrequest, fl_rvalid;
    wire [31:0] fl_rdata;
    wire [12:0] flash_page_s;
    sync_bits #(.W(13)) u_sync_page (.clk(clk_50), .d(flash_page), .q(flash_page_s));

    // ----------------------------------------------------------------------
    // LEDs
    // ----------------------------------------------------------------------
    wire t_ok_s, b_ok_s, t_fail_s, b_fail_s;
    sync_bits #(.W(4)) u_sync_led (
        .clk (clk_100),
        .d   ({t_cal_ok, b_cal_ok, t_cal_fail, b_cal_fail}),
        .q   ({t_ok_s, b_ok_s, t_fail_s, b_fail_s})
    );
    reg [26:0] hb = 27'd0;
    always_ff @(posedge clk_100) hb <= (hb == 27'd99_999_999) ? 27'd0 : hb + 27'd1;
    reg [8:0] led_r = 9'd0;
    always_ff @(posedge clk_100)
        led_r <= {persona_rst ? 5'd0 : p_led, hb < 27'd50_000_000, t_fail_s | b_fail_s, b_ok_s, t_ok_s};
    assign led = led_r;

    // ----------------------------------------------------------------------
    // Platform Designer system
    // ----------------------------------------------------------------------
    shell_sys u0 (
        .clk_100_clk              (clk_100),
        .reset_reset_n            (1'b1),
        .clk_50_clk               (clk_50),

        .pcie_refclk_clk          (clk_pcie1),
        .pcie_npor_npor           (1'b1),
        .pcie_npor_pin_perst      (pcie1_perstn),
        .pcie_hip_serial_rx_in0   (pcie1_rx[0]),
        .pcie_hip_serial_rx_in1   (pcie1_rx[1]),
        .pcie_hip_serial_rx_in2   (pcie1_rx[2]),
        .pcie_hip_serial_rx_in3   (pcie1_rx[3]),
        .pcie_hip_serial_rx_in4   (pcie1_rx[4]),
        .pcie_hip_serial_rx_in5   (pcie1_rx[5]),
        .pcie_hip_serial_rx_in6   (pcie1_rx[6]),
        .pcie_hip_serial_rx_in7   (pcie1_rx[7]),
        .pcie_hip_serial_tx_out0  (pcie1_tx[0]),
        .pcie_hip_serial_tx_out1  (pcie1_tx[1]),
        .pcie_hip_serial_tx_out2  (pcie1_tx[2]),
        .pcie_hip_serial_tx_out3  (pcie1_tx[3]),
        .pcie_hip_serial_tx_out4  (pcie1_tx[4]),
        .pcie_hip_serial_tx_out5  (pcie1_tx[5]),
        .pcie_hip_serial_tx_out6  (pcie1_tx[6]),
        .pcie_hip_serial_tx_out7  (pcie1_tx[7]),

        .pio_counter_external_export (counter),
        .pio_id_external_export      (32'h50434945),
        .pio_temp_external_export    (pio_temp),
        .pio_persona_external_export (pio_persona),

        .temp_corectl_corectl        (1'b1),
        .temp_reset_reset            (ts_reset),
        .temp_tempout_tempout        (ts_tempout),
        .temp_eoc_eoc                (ts_eoc),

        .pr_freeze_freeze            (pr_freeze),
        .pll_pr_locked_export        (pll_pr_locked),
        .pll_pr_reset_reset          (pll_pr_reset),

        // Identity block
        .id_br_m0_waitrequest        (1'b0),
        .id_br_m0_readdata           (id_rdata),
        .id_br_m0_readdatavalid      (id_rvalid),
        .id_br_m0_burstcount         (),
        .id_br_m0_writedata          (),
        .id_br_m0_address            (id_addr),
        .id_br_m0_write              (),
        .id_br_m0_read               (id_read),
        .id_br_m0_byteenable         (),
        .id_br_m0_debugaccess        (),

        // Shell registers
        .regs_br_m0_waitrequest      (1'b0),
        .regs_br_m0_readdata         (regs_rdata),
        .regs_br_m0_readdatavalid    (regs_rvalid),
        .regs_br_m0_burstcount       (),
        .regs_br_m0_writedata        (regs_wdata),
        .regs_br_m0_address          (regs_addr),
        .regs_br_m0_write            (regs_write),
        .regs_br_m0_read             (regs_read),
        .regs_br_m0_byteenable       (),
        .regs_br_m0_debugaccess      (),

        // Persona window
        .persona_br_m0_waitrequest   (1'b0),
        .persona_br_m0_readdata      (pbr_rdata),
        .persona_br_m0_readdatavalid (pbr_rvalid),
        .persona_br_m0_burstcount    (),
        .persona_br_m0_writedata     (pbr_wdata),
        .persona_br_m0_address       (pbr_addr),
        .persona_br_m0_write         (pbr_write),
        .persona_br_m0_read          (pbr_read),
        .persona_br_m0_byteenable    (),
        .persona_br_m0_debugaccess   (),

        // Flash window -> flash memory port, read-only
        .flash_br_m0_waitrequest     (fbr_write ? 1'b0 : fl_waitrequest),
        .flash_br_m0_readdata        (fl_rdata),
        .flash_br_m0_readdatavalid   (fl_rvalid),
        .flash_br_m0_burstcount      (),
        .flash_br_m0_writedata       (),
        .flash_br_m0_address         (fbr_addr),
        .flash_br_m0_write           (fbr_write),
        .flash_br_m0_read            (fbr_read),
        .flash_br_m0_byteenable      (),
        .flash_br_m0_debugaccess     (),

        .flash_mem_write             (1'b0),            // read-only by construction
        .flash_mem_burstcount        (7'd1),
        .flash_mem_waitrequest       (fl_waitrequest),
        .flash_mem_read              (fbr_read),
        .flash_mem_address           ({flash_page_s, fbr_addr[13:2]}),
        .flash_mem_writedata         (32'd0),
        .flash_mem_readdata          (fl_rdata),
        .flash_mem_readdatavalid     (fl_rvalid),
        .flash_mem_byteenable        (4'hF),

        .flash_csr_address           (6'd0),            // control port unused
        .flash_csr_read              (1'b0),
        .flash_csr_readdata          (),
        .flash_csr_write             (1'b0),
        .flash_csr_writedata         (32'd0),
        .flash_csr_waitrequest       (),
        .flash_csr_readdatavalid     (),

        // EMIF top
        .emif_top_global_reset_reset_sink_reset_n       (emif_rst_n),
        .emif_top_pll_ref_clk_clock_sink_clk            (top_refclk),
        .emif_top_oct_conduit_end_oct_rzqin             (top_oct_rzqin),
        .emif_top_mem_conduit_end_mem_ck                (top_mem_ck),
        .emif_top_mem_conduit_end_mem_ck_n              (top_mem_ck_n),
        .emif_top_mem_conduit_end_mem_a                 (top_mem_a),
        .emif_top_mem_conduit_end_mem_act_n             (top_mem_act_n),
        .emif_top_mem_conduit_end_mem_ba                (top_mem_ba),
        .emif_top_mem_conduit_end_mem_bg                (top_mem_bg),
        .emif_top_mem_conduit_end_mem_cke               (top_mem_cke),
        .emif_top_mem_conduit_end_mem_cs_n              (top_mem_cs_n),
        .emif_top_mem_conduit_end_mem_odt               (top_mem_odt),
        .emif_top_mem_conduit_end_mem_reset_n           (top_mem_reset_n),
        .emif_top_mem_conduit_end_mem_par               (top_mem_par),
        .emif_top_mem_conduit_end_mem_alert_n           (top_mem_alert_n),
        .emif_top_mem_conduit_end_mem_dqs               (top_mem_dqs),
        .emif_top_mem_conduit_end_mem_dqs_n             (top_mem_dqs_n),
        .emif_top_mem_conduit_end_mem_dq                (top_mem_dq),
        .emif_top_mem_conduit_end_mem_dbi_n             (top_mem_dbi_n),
        .emif_top_status_conduit_end_local_cal_success  (t_cal_ok),
        .emif_top_status_conduit_end_local_cal_fail     (t_cal_fail),
        .emif_top_emif_usr_reset_reset_source_reset_n   (t_urst_n),
        .emif_top_emif_usr_clk_clock_source_clk         (t_clk),
        .emif_top_ctrl_amm_avalon_slave_0_waitrequest_n (te_ready),
        .emif_top_ctrl_amm_avalon_slave_0_read          (te_read),
        .emif_top_ctrl_amm_avalon_slave_0_write         (te_write),
        .emif_top_ctrl_amm_avalon_slave_0_address       (te_addr),
        .emif_top_ctrl_amm_avalon_slave_0_readdata      (te_rdata),
        .emif_top_ctrl_amm_avalon_slave_0_writedata     (te_wdata),
        .emif_top_ctrl_amm_avalon_slave_0_burstcount    (te_burst),
        .emif_top_ctrl_amm_avalon_slave_0_byteenable    (te_be),
        .emif_top_ctrl_amm_avalon_slave_0_readdatavalid (te_rvalid),

        // EMIF bottom
        .emif_bot_global_reset_reset_sink_reset_n       (emif_rst_n),
        .emif_bot_pll_ref_clk_clock_sink_clk            (bot_refclk),
        .emif_bot_oct_conduit_end_oct_rzqin             (bot_oct_rzqin),
        .emif_bot_mem_conduit_end_mem_ck                (bot_mem_ck),
        .emif_bot_mem_conduit_end_mem_ck_n              (bot_mem_ck_n),
        .emif_bot_mem_conduit_end_mem_a                 (bot_mem_a),
        .emif_bot_mem_conduit_end_mem_act_n             (bot_mem_act_n),
        .emif_bot_mem_conduit_end_mem_ba                (bot_mem_ba),
        .emif_bot_mem_conduit_end_mem_bg                (bot_mem_bg),
        .emif_bot_mem_conduit_end_mem_cke               (bot_mem_cke),
        .emif_bot_mem_conduit_end_mem_cs_n              (bot_mem_cs_n),
        .emif_bot_mem_conduit_end_mem_odt               (bot_mem_odt),
        .emif_bot_mem_conduit_end_mem_reset_n           (bot_mem_reset_n),
        .emif_bot_mem_conduit_end_mem_par               (bot_mem_par),
        .emif_bot_mem_conduit_end_mem_alert_n           (bot_mem_alert_n),
        .emif_bot_mem_conduit_end_mem_dqs               (bot_mem_dqs),
        .emif_bot_mem_conduit_end_mem_dqs_n             (bot_mem_dqs_n),
        .emif_bot_mem_conduit_end_mem_dq                (bot_mem_dq),
        .emif_bot_mem_conduit_end_mem_dbi_n             (bot_mem_dbi_n),
        .emif_bot_status_conduit_end_local_cal_success  (b_cal_ok),
        .emif_bot_status_conduit_end_local_cal_fail     (b_cal_fail),
        .emif_bot_emif_usr_reset_reset_source_reset_n   (b_urst_n),
        .emif_bot_emif_usr_clk_clock_source_clk         (b_clk),
        .emif_bot_ctrl_amm_avalon_slave_0_waitrequest_n (be_ready),
        .emif_bot_ctrl_amm_avalon_slave_0_read          (be_read),
        .emif_bot_ctrl_amm_avalon_slave_0_write         (be_write),
        .emif_bot_ctrl_amm_avalon_slave_0_address       (be_addr),
        .emif_bot_ctrl_amm_avalon_slave_0_readdata      (be_rdata),
        .emif_bot_ctrl_amm_avalon_slave_0_writedata     (be_wdata),
        .emif_bot_ctrl_amm_avalon_slave_0_burstcount    (be_burst),
        .emif_bot_ctrl_amm_avalon_slave_0_byteenable    (be_be),
        .emif_bot_ctrl_amm_avalon_slave_0_readdatavalid (be_rvalid)
    );

endmodule

`default_nettype wire
