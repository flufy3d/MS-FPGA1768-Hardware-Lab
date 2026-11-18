`default_nettype none

// --------------------------------------------------------------------------
// persona_add — persona 1 of the reconfigurable region in pcie_hot_update
//
//   sum        = a + b (32-bit, wraps), registered
//   persona_id = 0x0001
//
// persona_add and persona_sub must keep identical ports: the PR region is
// the instance u_persona in pcie_hot_update.sv, and the implementation
// revision rebinds that instance to persona_sub (ENTITY_REBINDING).
//
// Registers in an Arria 10 PR region do not start in a known state after a
// partial reconfiguration, so everything here is reset by rst, which the
// static region holds high during and shortly after every PR operation.
// --------------------------------------------------------------------------
module persona_add (
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
            sum        <= a + b;
            persona_id <= 16'h0001;
        end
    end

endmodule

`default_nettype wire
