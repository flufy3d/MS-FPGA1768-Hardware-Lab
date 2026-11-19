`default_nettype none

// --------------------------------------------------------------------------
// persona_walk — DDR4 test persona: walking one / walking zero data test plus address-line test.
//
// Reconfigurable partition u_persona of projects/05_ddr4. Every persona of
// the shell has exactly this port list (the persona ABI, see the README).
// Persona ID 16'h0101 (persona ABI version 1).
// --------------------------------------------------------------------------
module persona_walk (
    input  wire          clk_100,
    input  wire          rst_100,

    input  wire [9:0]    csr_addr,
    input  wire          csr_read,
    input  wire          csr_write,
    input  wire [31:0]   csr_wdata,
    output wire [31:0]   csr_rdata,

    output wire [15:0]   persona_id,
    output wire [4:0]    led,

    input  wire          t_clk,
    input  wire          t_rst,
    output wire [24:0]   t_addr,
    output wire          t_read,
    output wire          t_write,
    output wire [575:0]  t_wdata,
    output wire [71:0]   t_be,
    input  wire          t_ready,
    input  wire [575:0]  t_rdata,
    input  wire          t_rvalid,

    input  wire          b_clk,
    input  wire          b_rst,
    output wire [24:0]   b_addr,
    output wire          b_read,
    output wire          b_write,
    output wire [575:0]  b_wdata,
    output wire [71:0]   b_be,
    input  wire          b_ready,
    input  wire [575:0]  b_rdata,
    input  wire          b_rvalid
);
    ddr_test_csr #(.MODE(0), .ID(16'h0101)) u_body (.*);
endmodule

`default_nettype wire
