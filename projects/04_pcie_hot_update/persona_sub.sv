`default_nettype none

// --------------------------------------------------------------------------
// persona_sub — persona 2 of the reconfigurable region in pcie_hot_update
//
//   sum        = a - b (32-bit, wraps), registered
//   persona_id = 0x0002
//
// Same ports as persona_add; see the notes there.
// --------------------------------------------------------------------------
module persona_sub (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] sum,
    output reg  [15:0] persona_id
);

    always_ff @(posedge clk) begin
        if (rst) begin
            sum        <= 32'd0;
            persona_id <= 16'd0;
        end else begin
            sum        <= a - b;
            persona_id <= 16'h0002;
        end
    end

endmodule

`default_nettype wire
