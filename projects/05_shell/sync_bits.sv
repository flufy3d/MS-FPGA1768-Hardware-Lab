`default_nettype none

// --------------------------------------------------------------------------
// sync_bits — multi-stage synchroniser for asynchronous single-bit signals
// and for quasi-static buses (values that are stable long before they are
// used, so per-bit skew does not matter).
//
// The first stage is named sync_s0; shell.sdc cuts timing to it.
// No initial values: the module is also used inside the PR region, where
// initial values are not supported.
// --------------------------------------------------------------------------
module sync_bits #(
    parameter int W = 1,
    parameter int N = 3          // stages, >= 2
) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED; -name DONT_MERGE_REGISTER ON" *)
    reg [W-1:0] sync_s0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    reg [W-1:0] sync_sn [N-1];

    always_ff @(posedge clk) begin
        sync_s0    <= d;
        sync_sn[0] <= sync_s0;
        for (int i = 1; i < N - 1; i++)
            sync_sn[i] <= sync_sn[i-1];
    end

    assign q = sync_sn[N-2];
endmodule

`default_nettype wire
