`default_nettype none

// --------------------------------------------------------------------------
// pcie_hot_update — PCIe #1 Gen3 x8 endpoint whose compute logic can be
// replaced over PCIe by Arria 10 partial reconfiguration (PR)
//
// Static region: PCIe hard IP, BAR0 register bank, temperature sensor,
// Partial Reconfiguration Controller IP (pr_ip) and the freeze logic below.
// Reconfigurable region: the instance u_persona (persona_add in the base
// revision, persona_sub in the implementation revision).
//
// BAR0 register map (Avalon PIO slaves are 16 bytes apart):
//   0x00   A        RW   operand A
//   0x10   B        RW   operand B
//   0x20   SUM      RO   persona result: A + B (persona 1) or A - B (persona 2);
//                        0 while the persona is frozen or in reset
//   0x30   COUNTER  RO   free-running 100 MHz counter
//   0x40   ID       RO   0x50434945 (checked by the Windows test driver)
//   0x50   TEMP     RO   Arria 10 temperature sensor, same format as project 03
//   0x60   PERSONA  RO   [15:0]  persona ID (0x0001 add, 0x0002 sub; 0 when frozen)
//                        [16]    freeze output of the PR controller
//                        [17]    persona reset (freeze, or < 511 cycles after it)
//                        [18]    PR controller clock PLL locked (50 MHz)
//   0x100  PR data  WO   PR controller: write the PR bitstream here, 32 bits per write
//   0x104  PR CSR   RW   [0] write 1 to start, [4:2] status (see README)
//   0x108  PR ver   RO   PR controller version (0xAA500003 in Quartus Pro 25.1)
//   0x10C  PR ID    RO   PR bitstream ID expected by the compatibility check
// 0x8000-0xFFFF is a 32 KB scratch RAM (it sizes BAR0 to 64 KB).
// --------------------------------------------------------------------------
module pcie_hot_update (
    input  wire        clk_100,        // AP20, 100 MHz board oscillator
    input  wire        clk_pcie1,      // AN29/AN28, 100 MHz PCIe #1 refclk
    input  wire        pcie1_perstn,   // AW16, PCIe #1 PERST#
    input  wire [7:0]  pcie1_rx,       // AN33/AN32 ... AH31/AH30
    output wire [7:0]  pcie1_tx        // AU37/AU36 ... AM39/AM38
);

    wire [31:0] pio_a;
    wire [31:0] pio_b;
    wire [31:0] pio_sum;
    wire [31:0] pio_counter;
    wire [31:0] pio_id;
    wire [31:0] pio_temp;
    wire [31:0] pio_persona;
    wire        pr_freeze;     // from the PR controller (50 MHz domain, PLL-related to clk_100)
    wire        pll_pr_locked; // asynchronous

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] pll_locked_sync = 2'd0;
    always_ff @(posedge clk_100) begin
        pll_locked_sync <= {pll_locked_sync[0], pll_pr_locked};
    end

    // Power-up reset for the PR controller clock PLL: high for the first 256
    // clk_100 cycles (2.56 us) after configuration, then low.
    reg [8:0] pll_rst_cnt = 9'd0;
    always_ff @(posedge clk_100) begin
        if (!pll_rst_cnt[8])
            pll_rst_cnt <= pll_rst_cnt + 9'd1;
    end
    wire pll_pr_reset = ~pll_rst_cnt[8];

    reg [31:0] counter = 32'd0;
    always_ff @(posedge clk_100) begin
        counter <= counter + 32'd1;
    end

    assign pio_counter = counter;
    assign pio_id      = 32'h50434945;  // "PCIE" numeric ID

    // ----------------------------------------------------------------------
    // Persona reset and freeze.
    //
    // The PR controller raises freeze for the whole PR operation. While it is
    // high, and for 511 clk_100 cycles (5.11 us) after it falls, the persona is held in
    // reset and its outputs are replaced by zero, so the static region never
    // sees the undefined outputs of a region that is being reconfigured.
    // The same hold applies after power-up / configuration.
    // ----------------------------------------------------------------------
    reg  [8:0]  persona_hold = 9'h1FF;
    reg         persona_rst  = 1'b1;

    always_ff @(posedge clk_100) begin
        if (pr_freeze)
            persona_hold <= 9'h1FF;
        else if (persona_hold != 9'd0)
            persona_hold <= persona_hold - 9'd1;
        persona_rst <= pr_freeze | (persona_hold != 9'd0);
    end

    wire [31:0] persona_sum;
    wire [15:0] persona_id;

    // Reconfigurable partition (pr_partition). Entity persona_add in the base
    // revision; rebound to persona_sub in pcie_hot_update_sub.qsf.
    persona_add u_persona (
        .clk        (clk_100),
        .rst        (persona_rst),
        .a          (pio_a),
        .b          (pio_b),
        .sum        (persona_sum),
        .persona_id (persona_id)
    );

    assign pio_sum     = persona_rst ? 32'd0 : persona_sum;
    assign pio_persona = {13'd0, pll_locked_sync[1], persona_rst, pr_freeze,
                          persona_rst ? 16'd0 : persona_id};

    // ----------------------------------------------------------------------
    // Internal temperature sensor — unchanged from projects/03_pcie_gen3.
    // One conversion every 2^24 clk_100 cycles (about 0.17 s).
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

    assign pio_temp = {ts_count, ts_eoc_sync[2], 1'b0, ts_raw, 6'd0, ts_code};

    pcie_hot_update_sys u0 (
        .clk_100_clk              (clk_100),
        .reset_reset_n            (1'b1),

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

        .pio_a_external_export       (pio_a),
        .pio_b_external_export       (pio_b),
        .pio_sum_external_export     (pio_sum),
        .pio_counter_external_export (pio_counter),
        .pio_id_external_export      (pio_id),
        .pio_temp_external_export    (pio_temp),
        .pio_persona_external_export (pio_persona),

        .temp_corectl_corectl        (1'b1),
        .temp_reset_reset            (ts_reset),
        .temp_tempout_tempout        (ts_tempout),
        .temp_eoc_eoc                (ts_eoc),

        .pr_freeze_freeze            (pr_freeze),
        .pll_pr_locked_export        (pll_pr_locked),
        .pll_pr_reset_reset          (pll_pr_reset)
    );

endmodule

`default_nettype wire
