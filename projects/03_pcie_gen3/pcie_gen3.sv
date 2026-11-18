`default_nettype none

// --------------------------------------------------------------------------
// pcie_gen3 — PCIe #1 Gen3 x8 endpoint with a BAR0 register bank and a
// die temperature register
//
// The host writes two 32-bit operands (A, B) into BAR0 and reads back A+B.
// A free-running counter and a constant ID register prove that the reads are
// real BAR0 transactions and not a host-side loopback.
//
// Register map (the Altera Avalon PIO slave occupies 16 bytes per instance):
//   0x00  A        RW   operand A
//   0x10  B        RW   operand B
//   0x20  SUM      RO   A + B (32-bit, wraps)
//   0x30  COUNTER  RO   free-running 100 MHz counter
//   0x40  ID       RO   0x50434945
//   0x50  TEMP     RO   Arria 10 internal temperature sensor
//                       [9:0]   code latched at end of conversion
//                       [25:16] raw sensor output (continuously sampled)
//                       [27]    eoc level
//                       [31:28] conversion counter (low 4 bits)
//                       degrees C = code * 693 / 1024 - 265 (vendor formula)
//
// 0x8000-0xFFFF is a 32 KB scratch RAM (it sizes BAR0 to 64 KB).
// No LEDs are used; project 01 already verified the LED pins.
// --------------------------------------------------------------------------
module pcie_gen3 (
    input  wire        clk_100,        // AP20, 100 MHz board oscillator
    input  wire        clk_pcie1,      // AN29/AN28, 100 MHz PCIe #1 refclk
    input  wire        pcie1_perstn,   // AW16, PCIe #1 PERST#
    input  wire [7:0]  pcie1_rx,       // AN33/AN32 ... AH31/AH30
    output wire [7:0]  pcie1_tx        // AU37/AU36 ... AM39/AM38
);

    // BAR0 register bank outputs/inputs (Qsys PIO instances)
    wire [31:0] pio_a;
    wire [31:0] pio_b;
    wire [31:0] pio_sum;
    wire [31:0] pio_counter;
    wire [31:0] pio_id;
    wire [31:0] pio_temp;

    // Free-running counter: two host reads must return different values.
    reg [31:0] counter;
    always_ff @(posedge clk_100) begin
        counter <= counter + 32'd1;
    end

    // The computation the host asks the FPGA to perform.
    assign pio_sum     = pio_a + pio_b;
    assign pio_counter = counter;
    assign pio_id      = 32'h50434945;  // "PCIE" numeric ID

    // ----------------------------------------------------------------------
    // Internal temperature sensor. The sensor runs on its own 1 MHz clock;
    // a conversion is started by pulsing its reset while corectl is high and
    // finishes when eoc rises. One conversion every 2^24 clk_100 cycles
    // (about 0.17 s); reset is held for the first 2^16 cycles (about 0.66 ms).
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

    assign pio_temp = {ts_count, ts_eoc_sync[2], 1'b0, ts_raw, 6'd0, ts_code};

    pcie_gen3_sys u0 (
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

        .temp_corectl_corectl        (1'b1),
        .temp_reset_reset            (ts_reset),
        .temp_tempout_tempout        (ts_tempout),
        .temp_eoc_eoc                (ts_eoc)
    );

endmodule

`default_nettype wire
