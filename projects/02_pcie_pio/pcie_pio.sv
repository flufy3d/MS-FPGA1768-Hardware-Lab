`default_nettype none

// --------------------------------------------------------------------------
// pcie_pio — PCIe #1 x8 endpoint with a BAR0 register bank
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
//
// No LEDs are used; project 01 already verified the LED pins.
// --------------------------------------------------------------------------
module pcie_pio (
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

    // Free-running counter: two host reads must return different values.
    reg [31:0] counter;
    always_ff @(posedge clk_100) begin
        counter <= counter + 32'd1;
    end

    // The computation the host asks the FPGA to perform.
    assign pio_sum     = pio_a + pio_b;
    assign pio_counter = counter;
    assign pio_id      = 32'h50434945;  // "PCIE" numeric ID

    pcie_pio_sys u0 (
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
        .pio_id_external_export      (pio_id)
    );

endmodule

`default_nettype wire
