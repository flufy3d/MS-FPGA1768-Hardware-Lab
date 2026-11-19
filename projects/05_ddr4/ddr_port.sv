`default_nettype none

// --------------------------------------------------------------------------
// ddr_port — static-region glue between the persona (PR region) and one
// EMIF Avalon-MM user port, in the EMIF user clock domain (266.667 MHz).
//
// * The persona is an Avalon-MM master with burstcount fixed at 1 (one
//   576-bit word = one DDR4 BL8 burst). Without bursts a persona can never
//   leave a half-finished burst behind when it is frozen or replaced.
// * Commands are captured in a register stage at the PR boundary, then pass
//   through a 4-entry FIFO (flip-flops, not block RAM) and an output register
//   that drives the EMIF port directly: the EMIF's hard I/O tile inputs must
//   be fed by a register close to the I/O column (the first build,
//   2026-11-19, inferred the FIFO as M20K and missed setup by up to 1.2 ns on
//   M20K -> EMIF tile paths; the second build still missed 0.365 ns from the
//   persona to the FIFO across the PR boundary, hence the capture stage).
//   p_ready is registered and drops while the gate is closed (QUIESCE
//   requested by the host) or while the persona is in reset (PR freeze).
//   Commands already in the FIFO are always completed; nothing is ever
//   withdrawn from the EMIF.
// * quiesced = gate closed, FIFO empty and no read outstanding. The host
//   must see it before it starts a PR load (fpga1768 load-pr does this).
// * Mailbox: one 576-bit read or write issued by the host through the shell
//   registers, allowed only while quiesced (otherwise it is refused with
//   mb_err). Mailbox fields come from the clk_100 domain and are stable
//   before the go toggle arrives through the synchroniser (mbq_ captures).
// * Read data from the EMIF cannot be back-pressured; it is forwarded to the
//   persona (or the mailbox) one cycle later.
// --------------------------------------------------------------------------
module ddr_port (
    input  wire          clk,            // emif_usr_clk
    input  wire          usr_rst_n,      // emif_usr_reset_n (synchronous to clk)

    // From the clk_100 domain (asynchronous here)
    input  wire          gate_a,         // QUIESCE request
    input  wire          prst_a,         // persona reset (PR freeze + hold)

    // Persona side
    output wire          p_rst,          // persona reset, synchronous to clk
    input  wire [24:0]   p_addr,
    input  wire          p_read,
    input  wire          p_write,
    input  wire [575:0]  p_wdata,
    input  wire [71:0]   p_be,
    output reg           p_ready,
    output reg  [575:0]  p_rdata,
    output reg           p_rvalid,

    // Mailbox (fields quasi-static, from the clk_100 domain)
    input  wire          mb_go_tg_a,     // toggles once per request
    input  wire          mb_wr_a,
    input  wire [24:0]   mb_addr_a,
    input  wire [575:0]  mb_wdata_a,
    output reg           mb_done_tg,     // toggles when the request is finished
    output reg           mb_err,         // last request refused (not quiesced)
    output reg  [575:0]  mbres_rdata,    // read data of the last mailbox read

    // Status
    output reg           quiesced,

    // EMIF Avalon-MM user port
    output wire          e_read,
    output wire          e_write,
    output wire [24:0]   e_addr,
    output wire [575:0]  e_wdata,
    output wire [71:0]   e_be,
    output wire [6:0]    e_burst,
    input  wire          e_ready,        // waitrequest_n
    input  wire [575:0]  e_rdata,
    input  wire          e_rvalid
);
    // ----------------------------------------------------------------------
    // Synchronisers
    // ----------------------------------------------------------------------
    wire gate_s, prst_s, mb_go_s;
    sync_bits #(.W(3)) u_sync (
        .clk (clk),
        .d   ({gate_a, prst_a, mb_go_tg_a}),
        .q   ({gate_s, prst_s, mb_go_s})
    );

    reg prst_r = 1'b1;
    always_ff @(posedge clk)
        prst_r <= prst_s | ~usr_rst_n;
    assign p_rst = prst_r;

    // ----------------------------------------------------------------------
    // Command FIFO (4 entries)
    // ----------------------------------------------------------------------
    localparam int CW = 1 + 25 + 576 + 72;   // {is_write, addr, wdata, be}

    (* ramstyle = "logic" *) reg [CW-1:0] fifo [4];
    reg [1:0]    wr_ptr = 2'd0, rd_ptr = 2'd0;
    reg [2:0]    count  = 3'd0;

    // Mailbox state
    reg          mb_go_d   = 1'b0;
    reg          mb_pend   = 1'b0;   // request accepted, command not yet pushed
    reg          mb_wait   = 1'b0;   // read pushed, waiting for its data
    reg          mbq_wr    = 1'b0;
    reg [24:0]   mbq_addr  = '0;
    reg [575:0]  mbq_wdata = '0;

    reg [15:0]   outstanding = 16'd0;

    // Read-issue/return are registered before the outstanding counter: the
    // EMIF read-valid comes from the I/O tile (X~142) while the counter sits
    // near the PR boundary, and the direct path plus a 16-bit adder missed
    // setup by 0.128 ns (2026-11-19). Registering both makes the counter
    // arithmetic local; quiesce may see the count one cycle later, which is
    // harmless because it also waits for p_ready and the FIFO.
    reg          rd_issue_r = 1'b0;
    reg          rd_return_r = 1'b0;

    // Input capture stage. The PR region ends near X127 and the EMIF user
    // port sits next to the I/O column (X~151): a direct persona -> FIFO path
    // missed setup by 0.365 ns at 266.667 MHz (2026-11-19). One register
    // stage between the persona and the FIFO splits that route; in_v also
    // gives the queue one extra slot so the persona can still issue one
    // command per cycle.
    reg          in_v   = 1'b0;
    reg [CW-1:0] in_cmd;

    // Output register (drives the EMIF)
    reg          o_valid = 1'b0;
    reg [CW-1:0] o_cmd;

    wire         head_valid = (count != 3'd0);
    wire [CW-1:0] head      = fifo[rd_ptr];
    wire         o_take     = o_valid & e_ready;              // EMIF accepts o_cmd
    wire         pop        = head_valid & (~o_valid | o_take); // FIFO head -> o_cmd

    wire         p_capture = p_ready & (p_read | p_write) & ~prst_r;
    wire         in_push   = in_v & (count != 3'd4);
    wire         mb_push   = mb_pend & ~in_v & (count == 3'd0) &
                             ~o_valid & (outstanding == 16'd0);
    wire         push      = in_push | mb_push;
    wire [CW-1:0] push_d   = in_v ? in_cmd
                                  : {mbq_wr, mbq_addr, mbq_wdata, {72{1'b1}}};

    wire [2:0]   count_n = count + {2'd0, push} - {2'd0, pop};

    assign e_read  = o_valid & ~o_cmd[CW-1];
    assign e_write = o_valid &  o_cmd[CW-1];
    assign e_addr  = o_cmd[CW-2 -: 25];
    assign e_wdata = o_cmd[72 +: 576];
    assign e_be    = o_cmd[71:0];
    assign e_burst = 7'd1;

    wire rd_issue = e_read & e_ready;    always_ff @(posedge clk) begin
        if (p_capture) begin
            in_cmd <= {p_write, p_addr, p_wdata, p_be};
            in_v   <= 1'b1;
        end else if (in_push) begin
            in_v   <= 1'b0;
        end

        if (push) begin
            fifo[wr_ptr] <= push_d;
            wr_ptr       <= wr_ptr + 2'd1;
        end
        if (pop) begin
            rd_ptr  <= rd_ptr + 2'd1;
            o_cmd   <= head;
            o_valid <= 1'b1;
        end else if (o_take) begin
            o_valid <= 1'b0;
        end
        count <= count_n;

        if (rd_issue_r & ~rd_return_r)
            outstanding <= outstanding + 16'd1;
        else if (~rd_issue_r & rd_return_r & (outstanding != 16'd0))
            outstanding <= outstanding - 16'd1;
        rd_issue_r  <= rd_issue;
        rd_return_r <= e_rvalid;

        // Registered ready, computed from local FIFO state only: at most two
        // more pushes can follow a ready computed with count_n <= 1, so the
        // capture register and the 4-entry FIFO cannot overflow. Keeping
        // p_read/p_write out of this expression also keeps the persona ->
        // p_ready path short (it was the 2026-11-19 -0.242 ns path on the
        // bottom channel). The queue is deeper than this early-ready point:
        // the extra entries absorb EMIF stalls while the persona waits.
        p_ready <= ~gate_s & ~prst_r & (count_n <= 3'd1) & ~mb_pend & ~mb_wait;

        quiesced <= gate_s & (count_n == 3'd0) & ~o_valid & ~pop & (outstanding == 16'd0) &
                    ~mb_pend & ~mb_wait & ~push & ~in_v & ~p_capture;

        // Read data
        p_rdata  <= e_rdata;
        p_rvalid <= e_rvalid & ~mb_wait & ~prst_r;

        // Mailbox
        mb_go_d <= mb_go_s;
        if (mb_go_s != mb_go_d) begin
            if (quiesced) begin
                mbq_wr    <= mb_wr_a;
                mbq_addr  <= mb_addr_a;
                mbq_wdata <= mb_wdata_a;
                mb_pend   <= 1'b1;
                mb_err    <= 1'b0;
            end else begin
                mb_err     <= 1'b1;
                mb_done_tg <= ~mb_done_tg;
            end
        end
        if (mb_push) begin
            mb_pend <= 1'b0;
            if (mbq_wr)
                mb_done_tg <= ~mb_done_tg;   // posted write: done once issued
            else
                mb_wait <= 1'b1;
        end
        if (mb_wait & e_rvalid) begin
            mbres_rdata <= e_rdata;
            mb_wait     <= 1'b0;
            mb_done_tg  <= ~mb_done_tg;
        end

        if (!usr_rst_n) begin
            wr_ptr      <= 2'd0;
            rd_ptr      <= 2'd0;
            count       <= 3'd0;
            o_valid     <= 1'b0;
            outstanding <= 16'd0;
            rd_issue_r  <= 1'b0;
            rd_return_r <= 1'b0;
            p_ready     <= 1'b0;
            p_rvalid    <= 1'b0;
            quiesced    <= 1'b0;
            mb_pend     <= 1'b0;
            mb_wait     <= 1'b0;
            in_v        <= 1'b0;
            mb_done_tg  <= 1'b0;
            mb_err      <= 1'b0;
        end
    end
endmodule

`default_nettype wire
