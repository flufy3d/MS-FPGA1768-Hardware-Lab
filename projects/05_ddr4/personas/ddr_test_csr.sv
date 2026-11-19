`default_nettype none

// --------------------------------------------------------------------------
// ddr_test_csr — common body of the DDR test personas: the persona register
// window (BAR0 + 0x1000, 4 KB, clk_100) and one ddr_test_engine per channel.
//
// Persona register map (byte offsets from BAR0 + 0x1000):
//
// 0x000  ID          RO  [15:0] persona ID, [31:16] persona ABI version (1)
// 0x004  CTRL        RW  [0] write 1: start a run on the channels in [5:4]
//                        [1] abort (level)
//                        [5:4] channel mask (bit 4 top, bit 5 bottom)
//                        [8] write pass  [9] read pass  [10] invert
//                        [11] address test (walking persona only)
// 0x008  START_ADDR  RW  first 576-bit word (25 bits)
// 0x00C  END_ADDR    RW  last 576-bit word, inclusive
// 0x010  SEED        RW  pattern seed
// 0x014  STATUS      RO  top [7:0], bottom [15:8]:
//                        [0] busy, [1] errors in the last run,
//                        [2] first error captured, [3] last run aborted
// 0x018  CAPS        RO  [7:0] pattern (1 walking, 2 PRBS-31), [8] address test
//
// Per channel: top at 0x400, bottom at 0x800 (offsets below):
// +0x00 ERR_WORDS  +0x04 WR_BEATS   +0x08 RD_BEATS   +0x0C WR_CYCLES
// +0x10 RD_CYCLES  +0x14 FIRST_ERR_ADDR              +0x18 FLAGS ([0] first
// error valid, [1] aborted)        +0x1C RUNS (completed runs, 16 bits)
// +0x20/+0x24/+0x28 LANE_MASK bits [31:0], [63:32], [71:64]
// +0x100..+0x144 FIRST_EXPECTED[0..17]  (word 0 = bits [31:0])
// +0x200..+0x244 FIRST_ACTUAL[0..17]
//
// Results are read asynchronously from the engines' clock domains; read
// them only when the channel is not busy.
// --------------------------------------------------------------------------
module ddr_test_csr #(
    parameter int        MODE = 0,
    parameter bit [15:0] ID   = 16'h0101
) (
    input  wire          clk_100,
    input  wire          rst_100,

    input  wire [9:0]    csr_addr,       // word address
    input  wire          csr_read,
    input  wire          csr_write,
    input  wire [31:0]   csr_wdata,
    output reg  [31:0]   csr_rdata,      // valid the cycle after csr_read

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
    assign persona_id = ID;

    // ----------------------------------------------------------------------
    // Configuration registers (clk_100), captured by the engines at start
    // ----------------------------------------------------------------------
    // Reset values (rst_100): phases = write + read, whole channel, seed 1,
    // both channels. No initial values in the PR region.
    reg [3:0]  cfgx_phases;
    reg [24:0] cfgx_start;
    reg [24:0] cfgx_end;
    reg [31:0] cfgx_seed;
    reg        abort;
    reg [1:0]  mask;
    reg [1:0]  start_tg;

    // ----------------------------------------------------------------------
    // Engines
    // ----------------------------------------------------------------------
    wire [1:0]   done_tg, busy;
    wire [31:0]  err_w [2], wr_b [2], rd_b [2], wr_c [2], rd_c [2];
    wire [24:0]  f_addr [2];
    wire [1:0]   f_valid, aborted;
    wire [71:0]  lane [2];
    wire [575:0] f_exp [2], f_act [2];
    wire [15:0]  runs [2];

    ddr_test_engine #(.MODE(MODE)) u_top (
        .clk (t_clk), .rst (t_rst),
        .start_tg_a (start_tg[0]), .abort_a (abort),
        .cfgx_phases (cfgx_phases), .cfgx_start (cfgx_start),
        .cfgx_end (cfgx_end), .cfgx_seed (cfgx_seed),
        .done_tg (done_tg[0]), .busy (busy[0]),
        .xres_err_words (err_w[0]), .xres_wr_beats (wr_b[0]), .xres_rd_beats (rd_b[0]),
        .xres_wr_cycles (wr_c[0]), .xres_rd_cycles (rd_c[0]),
        .xres_first_addr (f_addr[0]), .xres_first_valid (f_valid[0]),
        .xres_aborted (aborted[0]), .xres_lane_mask (lane[0]),
        .xres_first_exp (f_exp[0]), .xres_first_act (f_act[0]), .xres_runs (runs[0]),
        .m_addr (t_addr), .m_read (t_read), .m_write (t_write), .m_wdata (t_wdata),
        .m_be (t_be), .m_ready (t_ready), .m_rdata (t_rdata), .m_rvalid (t_rvalid)
    );

    ddr_test_engine #(.MODE(MODE)) u_bot (
        .clk (b_clk), .rst (b_rst),
        .start_tg_a (start_tg[1]), .abort_a (abort),
        .cfgx_phases (cfgx_phases), .cfgx_start (cfgx_start),
        .cfgx_end (cfgx_end), .cfgx_seed (cfgx_seed),
        .done_tg (done_tg[1]), .busy (busy[1]),
        .xres_err_words (err_w[1]), .xres_wr_beats (wr_b[1]), .xres_rd_beats (rd_b[1]),
        .xres_wr_cycles (wr_c[1]), .xres_rd_cycles (rd_c[1]),
        .xres_first_addr (f_addr[1]), .xres_first_valid (f_valid[1]),
        .xres_aborted (aborted[1]), .xres_lane_mask (lane[1]),
        .xres_first_exp (f_exp[1]), .xres_first_act (f_act[1]), .xres_runs (runs[1]),
        .m_addr (b_addr), .m_read (b_read), .m_write (b_write), .m_wdata (b_wdata),
        .m_be (b_be), .m_ready (b_ready), .m_rdata (b_rdata), .m_rvalid (b_rvalid)
    );

    // ----------------------------------------------------------------------
    // Status (synchronised)
    // ----------------------------------------------------------------------
    wire [1:0] done_s, busy_s, fv_s, ab_s, err_s;
    sync_bits #(.W(10)) u_sync (
        .clk (clk_100),
        .d   ({done_tg, busy, f_valid, aborted, (err_w[1] != 32'd0), (err_w[0] != 32'd0)}),
        .q   ({done_s, busy_s, fv_s, ab_s, err_s})
    );
    // A channel is busy from the start command until its engine reports the
    // run finished.
    wire [1:0] run_busy = (start_tg ^ done_s) | busy_s;

    // LEDs: [0] top busy, [1] bottom busy, [2] top errors, [3] bottom errors,
    //       [4] slow blink = persona alive
    reg [25:0] blink;
    always_ff @(posedge clk_100) blink <= rst_100 ? 26'd0 : blink + 26'd1;
    assign led = {blink[25], err_s[1], err_s[0], run_busy[1], run_busy[0]};

    // ----------------------------------------------------------------------
    // Register access
    // ----------------------------------------------------------------------
    wire        ch  = csr_addr[9];          // 0x800 -> bottom
    wire        chs = csr_addr[8] | csr_addr[9];   // per-channel space

    function automatic [31:0] slice(input [575:0] v, input [7:0] i);
        slice = (i < 8'd18) ? v[32*i +: 32] : 32'd0;
    endfunction

    always_ff @(posedge clk_100) begin
        if (csr_read) begin
            if (!chs) begin
                case (csr_addr[7:0])
                    8'd0:    csr_rdata <= {16'h0001, ID};
                    8'd1:    csr_rdata <= {20'd0, cfgx_phases, 2'b00, mask, 2'b00, abort, 1'b0};
                    8'd2:    csr_rdata <= {7'd0, cfgx_start};
                    8'd3:    csr_rdata <= {7'd0, cfgx_end};
                    8'd4:    csr_rdata <= cfgx_seed;
                    8'd5:    csr_rdata <= {16'd0,
                                           4'd0, ab_s[1], fv_s[1], err_s[1], run_busy[1],
                                           4'd0, ab_s[0], fv_s[0], err_s[0], run_busy[0]};
                    8'd6:    csr_rdata <= {23'd0, (MODE == 0), (MODE == 0) ? 8'd1 : 8'd2};
                    default: csr_rdata <= 32'd0;
                endcase
            end else begin
                // per-channel block: word offset within 0x400 = {csr_addr[7:0]}
                // with sub-blocks selected by csr_addr[7:6] for 0x000-0x0FF and
                // csr_addr[8]... see map above.
                csr_rdata <= 32'd0;
                case (csr_addr[7:6])
                    2'd0: case (csr_addr[5:0])
                        6'd0:  csr_rdata <= err_w[ch];
                        6'd1:  csr_rdata <= wr_b[ch];
                        6'd2:  csr_rdata <= rd_b[ch];
                        6'd3:  csr_rdata <= wr_c[ch];
                        6'd4:  csr_rdata <= rd_c[ch];
                        6'd5:  csr_rdata <= {7'd0, f_addr[ch]};
                        6'd6:  csr_rdata <= {30'd0, aborted[ch], f_valid[ch]};
                        6'd7:  csr_rdata <= {16'd0, runs[ch]};
                        6'd8:  csr_rdata <= lane[ch][31:0];
                        6'd9:  csr_rdata <= lane[ch][63:32];
                        6'd10: csr_rdata <= {24'd0, lane[ch][71:64]};
                        default: csr_rdata <= 32'd0;
                    endcase
                    2'd1: csr_rdata <= slice(f_exp[ch], {2'b00, csr_addr[5:0]});
                    2'd2: csr_rdata <= slice(f_act[ch], {2'b00, csr_addr[5:0]});
                    default: csr_rdata <= 32'd0;
                endcase
            end
        end

        if (csr_write && !chs) begin
            case (csr_addr[7:0])
                8'd1: begin
                    abort       <= csr_wdata[1];
                    mask        <= csr_wdata[5:4];
                    cfgx_phases <= csr_wdata[11:8];
                    if (csr_wdata[0] && !csr_wdata[1]) begin
                        if (csr_wdata[4] && !run_busy[0]) start_tg[0] <= ~start_tg[0];
                        if (csr_wdata[5] && !run_busy[1]) start_tg[1] <= ~start_tg[1];
                    end
                end
                8'd2: cfgx_start <= csr_wdata[24:0];
                8'd3: cfgx_end   <= csr_wdata[24:0];
                8'd4: cfgx_seed  <= csr_wdata;
                default: ;
            endcase
        end

        if (rst_100) begin
            cfgx_phases <= 4'b0011;
            cfgx_start  <= 25'd0;
            cfgx_end    <= 25'h1FFFFFF;
            cfgx_seed   <= 32'd1;
            abort       <= 1'b0;
            mask        <= 2'b11;
            start_tg    <= done_s;   // nothing pending after a persona reset
        end
    end
endmodule

`default_nettype wire
