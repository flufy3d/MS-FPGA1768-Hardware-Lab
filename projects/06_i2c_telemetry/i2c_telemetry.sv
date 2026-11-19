`default_nettype none

// --------------------------------------------------------------------------
// i2c_telemetry — PCIe #1 Gen3 x8 endpoint with a BAR0 register block and an
// I2C master for the board management buses
//
// Copied from 03_pcie_gen3 (PCIe hard IP, 64-bit BAR0 64 KB, die temperature
// sensor). The A/B/SUM PIO bank is replaced by bar0_regs.sv behind one
// Avalon-MM bridge at BAR0 + 0x0000:
//
//   0x00 SHELL_ID 0x49323036 ("I206")    0x04 CAPS 0x00000002 (I2C)
//   0x08 CAPS2 0                         0x30 COUNTER
//   0x40 ID 0x50434945                   0x50 TEMP
//   0x60..0x94 I2C master (CTRL, ADDR, PAGE, REG, LEN, DATA, STATUS, SCL_DIV)
//   0x8000..0xFFFF 32 KB scratch RAM (sizes BAR0 to 64 KB)
//
// Full map: bar0_regs.sv and README.md.
//
// I2C pads are open drain: the FPGA drives 0 or releases the pin. The
// board's pull-ups define the high level. Bus 1: SDA L20 / SCL K20;
// bus 2: SDA K21 / SCL J23 (hardware/pinouts/csv/fpga_8_I2C.csv).
// --------------------------------------------------------------------------
module i2c_telemetry (
    input  wire        clk_100,        // AP20, 100 MHz board oscillator
    input  wire        clk_pcie1,      // AN29/AN28, 100 MHz PCIe #1 refclk
    input  wire        pcie1_perstn,   // AW16, PCIe #1 PERST#
    input  wire [7:0]  pcie1_rx,       // AN33/AN32 ... AH31/AH30
    output wire [7:0]  pcie1_tx,       // AU37/AU36 ... AM39/AM38

    inout  wire        i2c1_scl,       // K20, bus 1
    inout  wire        i2c1_sda,       // L20, bus 1
    inout  wire        i2c2_scl,       // J23, bus 2
    inout  wire        i2c2_sda        // K21, bus 2
);

    // ----------------------------------------------------------------------
    // Power-on reset for the register block (no external reset pin)
    // ----------------------------------------------------------------------
    reg [7:0] por_cnt = 8'd0;
    reg       rst     = 1'b1;
    always_ff @(posedge clk_100) begin
        if (por_cnt != 8'hFF) por_cnt <= por_cnt + 8'd1;
        rst <= (por_cnt != 8'hFF);
    end

    // Free-running counter: two host reads must return different values.
    reg [31:0] counter = 32'd0;
    always_ff @(posedge clk_100) counter <= counter + 32'd1;

    // ----------------------------------------------------------------------
    // Internal temperature sensor (unchanged from 03_pcie_gen3). The sensor
    // runs on its own 1 MHz clock; a conversion is started by pulsing its
    // reset while corectl is high and finishes when eoc rises. One conversion
    // every 2^24 clk_100 cycles (about 0.17 s).
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
    // I2C pads: open drain, inputs through two-stage synchronisers
    // ----------------------------------------------------------------------
    wire scl1_oe, sda1_oe, scl2_oe, sda2_oe;
    assign i2c1_scl = scl1_oe ? 1'b0 : 1'bz;
    assign i2c1_sda = sda1_oe ? 1'b0 : 1'bz;
    assign i2c2_scl = scl2_oe ? 1'b0 : 1'bz;
    assign i2c2_sda = sda2_oe ? 1'b0 : 1'bz;

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [3:0] i2c_in_meta = 4'hF;
    reg [3:0] i2c_in      = 4'hF;      // {sda2, scl2, sda1, scl1}
    always_ff @(posedge clk_100) begin
        i2c_in_meta <= {i2c2_sda, i2c2_scl, i2c1_sda, i2c1_scl};
        i2c_in      <= i2c_in_meta;
    end

    // ----------------------------------------------------------------------
    // BAR0 register block + I2C master
    // ----------------------------------------------------------------------
    wire [7:0]  av_addr;
    wire        av_read, av_write;
    wire [31:0] av_wdata, av_rdata;
    wire        av_rvalid;

    wire         i2c_start, i2c_abort, i2c_bus, i2c_rw, i2c_no_reg, i2c_page_en;
    wire [6:0]   i2c_addr;
    wire [7:0]   i2c_reg, i2c_page, i2c_bytes, rbuf_data;
    wire [5:0]   i2c_len;
    wire [15:0]  i2c_div;
    wire [223:0] i2c_wbuf;
    wire         rbuf_we;
    wire [4:0]   rbuf_idx;
    wire         i2c_busy, i2c_done, i2c_ack_error, i2c_timeout, i2c_aborted;

    bar0_regs u_regs (
        .clk           (clk_100),
        .rst           (rst),
        .address       (av_addr),
        .read          (av_read),
        .write         (av_write),
        .writedata     (av_wdata),
        .readdata      (av_rdata),
        .readdatavalid (av_rvalid),
        .counter       (counter),
        .temp          (temp_word),
        .i2c_start     (i2c_start),
        .i2c_abort     (i2c_abort),
        .i2c_bus       (i2c_bus),
        .i2c_rw        (i2c_rw),
        .i2c_no_reg    (i2c_no_reg),
        .i2c_addr      (i2c_addr),
        .i2c_reg       (i2c_reg),
        .i2c_page_en   (i2c_page_en),
        .i2c_page      (i2c_page),
        .i2c_len       (i2c_len),
        .i2c_div       (i2c_div),
        .i2c_wbuf      (i2c_wbuf),
        .i2c_rbuf_we   (rbuf_we),
        .i2c_rbuf_idx  (rbuf_idx),
        .i2c_rbuf_data (rbuf_data),
        .i2c_busy      (i2c_busy),
        .i2c_done      (i2c_done),
        .i2c_ack_error (i2c_ack_error),
        .i2c_timeout   (i2c_timeout),
        .i2c_aborted   (i2c_aborted),
        .i2c_bytes     (i2c_bytes),
        .i2c_lines     (i2c_in)
    );

    i2c_master u_i2c (
        .clk       (clk_100),
        .rst       (rst),
        .start     (i2c_start),
        .abort     (i2c_abort),
        .bus       (i2c_bus),
        .rw        (i2c_rw),
        .no_reg    (i2c_no_reg),
        .addr      (i2c_addr),
        .reg_byte  (i2c_reg),
        .page_en   (i2c_page_en),
        .page      (i2c_page),
        .len       (i2c_len),
        .div       (i2c_div),
        .wbuf      (i2c_wbuf),
        .rbuf_we   (rbuf_we),
        .rbuf_idx  (rbuf_idx),
        .rbuf_data (rbuf_data),
        .busy      (i2c_busy),
        .done      (i2c_done),
        .ack_error (i2c_ack_error),
        .timeout   (i2c_timeout),
        .aborted   (i2c_aborted),
        .bytes     (i2c_bytes),
        .scl1_in   (i2c_in[0]),
        .sda1_in   (i2c_in[1]),
        .scl2_in   (i2c_in[2]),
        .sda2_in   (i2c_in[3]),
        .scl1_oe   (scl1_oe),
        .sda1_oe   (sda1_oe),
        .scl2_oe   (scl2_oe),
        .sda2_oe   (sda2_oe)
    );

    // ----------------------------------------------------------------------
    // Qsys system: PCIe HIP, register bridge, scratch RAM, temperature sensor
    // ----------------------------------------------------------------------
    i2c_sys u0 (
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

        .regs_br_m0_waitrequest   (1'b0),
        .regs_br_m0_readdata      (av_rdata),
        .regs_br_m0_readdatavalid (av_rvalid),
        .regs_br_m0_burstcount    (),
        .regs_br_m0_writedata     (av_wdata),
        .regs_br_m0_address       (av_addr),
        .regs_br_m0_write         (av_write),
        .regs_br_m0_read          (av_read),
        .regs_br_m0_byteenable    (),
        .regs_br_m0_debugaccess   (),

        .temp_corectl_corectl     (1'b1),
        .temp_reset_reset         (ts_reset),
        .temp_tempout_tempout     (ts_tempout),
        .temp_eoc_eoc             (ts_eoc)
    );

endmodule

`default_nettype wire
