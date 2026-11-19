`default_nettype none

// --------------------------------------------------------------------------
// ddr_test_engine — memory test engine for one DDR4 channel (PR region).
//
// Runs in the EMIF user clock domain (266.667 MHz). Avalon-MM master with
// burstcount 1, as the shell's ddr_port requires. One run, started by a
// toggle from the persona CSR block, does in this order, as selected:
//
//   address test  (MODE 0 only) write a unique tag to word 0 and to every
//                 word 2^k (k = 0..24), then read the 26 words back. A stuck
//                 or shorted address line makes two of them alias.
//   write pass    write every word from start to end (inclusive) with the
//                 pattern sequence.
//   read pass     read the same words back and compare with the regenerated
//                 sequence.
//
// Patterns (576-bit word = 8 DDR4 beats x 72 DQ lines, ECC disabled):
//   MODE 0  walking one: a single 1 that moves up by one bit position per
//           word, starting at bit seed[9:0] (values 576..1023 wrap to
//           seed[9:0] - 576); invert = walking zero.
//   MODE 1  PRBS-31 (x^31 + x^28 + 1): 576 consecutive sequence bits per word,
//           LFSR seeded with seed[30:0] (0 -> 1); invert = complement.
//
// The xres_ registers change only while a run is in progress; the CSR block
// reads them in the clk_100 domain after the run (timing cut in ddr4.sdc).
// The persona is held in reset after configuration and after every PR.
// --------------------------------------------------------------------------
module ddr_test_engine #(
    parameter int MODE = 0
) (
    input  wire          clk,
    input  wire          rst,            // synchronous to clk

    // Control, from the clk_100 domain; cfgx_ fields are stable before
    // start_tg_a toggles and are captured into cfgq_ registers.
    input  wire          start_tg_a,
    input  wire          abort_a,
    input  wire [3:0]    cfgx_phases,    // [0] write [1] read [2] invert [3] address test
    input  wire [24:0]   cfgx_start,
    input  wire [24:0]   cfgx_end,
    input  wire [31:0]   cfgx_seed,

    // Status and results
    output reg           done_tg,
    output reg           busy,
    output reg  [31:0]   xres_err_words,
    output reg  [31:0]   xres_wr_beats,
    output reg  [31:0]   xres_rd_beats,
    output reg  [31:0]   xres_wr_cycles,
    output reg  [31:0]   xres_rd_cycles,
    output reg  [24:0]   xres_first_addr,
    output reg           xres_first_valid,
    output reg           xres_aborted,
    output reg  [71:0]   xres_lane_mask,
    output reg  [575:0]  xres_first_exp,
    output reg  [575:0]  xres_first_act,
    output reg  [15:0]   xres_runs,

    // Avalon-MM master to the shell
    output reg  [24:0]   m_addr,
    output reg           m_read,
    output reg           m_write,
    output reg  [575:0]  m_wdata,
    output wire [71:0]   m_be,
    input  wire          m_ready,
    input  wire [575:0]  m_rdata,
    input  wire          m_rvalid
);
    assign m_be = {72{1'b1}};

    // ----------------------------------------------------------------------
    // Pattern functions
    // ----------------------------------------------------------------------
    // One-hot decode of a bit position (0..575).
    function automatic [575:0] walk_init(input [9:0] pos);
        for (int i = 0; i < 576; i++)
            walk_init[i] = (pos == i[9:0]);
    endfunction

    function automatic [575:0] walk_next(input [575:0] v);
        walk_next = {v[574:0], v[575]};
    endfunction

    // PRBS-31, 576 steps: {next_state[30:0], data[575:0]}
    function automatic [606:0] prbs_step(input [30:0] s_in);
        reg [30:0]  s;
        reg [575:0] d;
        reg         b;
        s = s_in;
        for (int i = 0; i < 576; i++) begin
            b    = s[30] ^ s[27];
            s    = {s[29:0], b};
            d[i] = b;
        end
        prbs_step = {s, d};
    endfunction

    function automatic [30:0] prbs_seed(input [31:0] seed);
        prbs_seed = (seed[30:0] == 31'd0) ? 31'd1 : seed[30:0];
    endfunction

    function automatic [24:0] at_addr(input [4:0] i);
        at_addr = (i == 5'd0) ? 25'd0 : (25'd1 << (i - 5'd1));
    endfunction

    function automatic [575:0] at_data(input [4:0] i, input inv);
        at_data = {18{32'hA5C30000 | {27'd0, i}}} ^ {576{inv}};
    endfunction

    localparam [4:0] AT_LAST = 5'd25;

    // ----------------------------------------------------------------------
    // Control synchronisation and configuration capture
    // ----------------------------------------------------------------------
    wire start_s, abort_s;
    sync_bits #(.W(2)) u_sync (
        .clk (clk),
        .d   ({start_tg_a, abort_a}),
        .q   ({start_s, abort_s})
    );

    reg         start_d;
    reg [3:0]   cfgq_phases;
    reg [24:0]  cfgq_start;
    reg [24:0]  cfgq_end;
    reg [31:0]  cfgq_seed;
    wire        inv = cfgq_phases[2];
    reg  [9:0]  wpos;                     // walking-one start position

    // ----------------------------------------------------------------------
    // Generators: w = data being written, r = data expected on reads.
    // gX_data is the pattern of the current word; gX_lfsr the PRBS state
    // that produces the next word.
    // ----------------------------------------------------------------------
    reg [575:0] gw_data, gr_data;
    reg [30:0]  gw_lfsr, gr_lfsr;

    wire [606:0] gw_step   = prbs_step(gw_lfsr);
    wire [606:0] gr_step   = prbs_step(gr_lfsr);
    wire [606:0] seed_step = prbs_step(prbs_seed(cfgq_seed));

    wire [575:0] gw_next = (MODE == 0) ? walk_next(gw_data) : gw_step[575:0];
    wire [575:0] gr_next = (MODE == 0) ? walk_next(gr_data) : gr_step[575:0];
    wire [575:0] g_first = (MODE == 0) ? walk_init(wpos) : seed_step[575:0];

    // ----------------------------------------------------------------------
    // Sequencer
    // ----------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE, S_INIT0, S_INIT, S_AT_WR, S_AT_RD, S_WR, S_RD, S_WAIT_RD, S_DONE
    } state_t;
    state_t state;

    reg [24:0]  n_left;           // commands still to present after the current one
    reg [4:0]   at_idx;           // address-test index of the presented command
    reg         chk_at;           // read data belongs to the address test
    reg [4:0]   at_ridx;          // address-test index of the next read data
    reg [24:0]  rd_addr;          // address of the next read data
    reg [31:0]  rd_issued;        // reads accepted in this run
    reg [31:0]  rd_recv;          // read data received in this run
    reg [2:0]   drain;            // compare pipeline drain counter

    wire        accept    = m_ready & (m_read | m_write);
    wire        reads_out = (rd_issued != rd_recv);
    wire        stop      = abort_s;

    // Compare pipeline
    reg         c1_v, c2_v, c3_v;
    reg [575:0] c1_act, c1_exp, c2_act, c2_exp, c2_x, c3_act, c3_exp;
    reg [24:0]  c1_a, c2_a, c3_a;
    reg [15:0]  c3_or;
    reg [71:0]  c3_lane;

    wire [24:0] range_words = cfgq_end - cfgq_start;   // count - 1

    // Next phase after the address test / write pass.
    function automatic state_t after_at(input [3:0] ph);
        after_at = ph[0] ? S_WR : (ph[1] ? S_RD : S_DONE);
    endfunction

    always_ff @(posedge clk) begin
        start_d <= start_s;

        // ---------------- read data: expected value, compare ---------------
        c1_v <= 1'b0;
        if (m_rvalid && busy) begin
            c1_v    <= 1'b1;
            c1_act  <= m_rdata;
            rd_recv <= rd_recv + 32'd1;
            xres_rd_beats <= xres_rd_beats + 32'd1;
            if (chk_at) begin
                c1_exp  <= at_data(at_ridx, inv);
                c1_a    <= at_addr(at_ridx);
                at_ridx <= at_ridx + 5'd1;
            end else begin
                c1_exp  <= gr_data ^ {576{inv}};
                c1_a    <= rd_addr;
                rd_addr <= rd_addr + 25'd1;
                gr_data <= gr_next;
                gr_lfsr <= gr_step[606:576];
            end
        end

        c2_v   <= c1_v;
        c2_act <= c1_act;
        c2_exp <= c1_exp;
        c2_a   <= c1_a;
        c2_x   <= c1_act ^ c1_exp;

        c3_v   <= c2_v;
        c3_act <= c2_act;
        c3_exp <= c2_exp;
        c3_a   <= c2_a;
        for (int i = 0; i < 16; i++)
            c3_or[i] <= |c2_x[36*i +: 36];
        // Fold the 8 beats of a word onto the 72 DQ lanes (beat-major layout
        // of the EMIF user word is a hypothesis, see the README).
        for (int l = 0; l < 72; l++)
            c3_lane[l] <= c2_x[l]     | c2_x[72+l]  | c2_x[144+l] | c2_x[216+l] |
                          c2_x[288+l] | c2_x[360+l] | c2_x[432+l] | c2_x[504+l];

        if (c3_v) begin
            xres_lane_mask <= xres_lane_mask | c3_lane;
            if (|c3_or) begin
                xres_err_words <= xres_err_words + 32'd1;
                if (!xres_first_valid) begin
                    xres_first_valid <= 1'b1;
                    xres_first_addr  <= c3_a;
                    xres_first_exp   <= c3_exp;
                    xres_first_act   <= c3_act;
                end
            end
        end

        // ---------------- command side --------------------------------------
        if (accept) begin
            if (m_write) xres_wr_beats <= xres_wr_beats + 32'd1;
            if (m_read)  rd_issued     <= rd_issued + 32'd1;
        end

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start_s != start_d) begin
                    cfgq_phases <= cfgx_phases;
                    cfgq_start  <= cfgx_start;
                    cfgq_end    <= cfgx_end;
                    cfgq_seed   <= cfgx_seed;
                    busy        <= 1'b1;
                    xres_err_words   <= 32'd0;
                    xres_wr_beats    <= 32'd0;
                    xres_rd_beats    <= 32'd0;
                    xres_wr_cycles   <= 32'd0;
                    xres_rd_cycles   <= 32'd0;
                    xres_first_valid <= 1'b0;
                    xres_first_addr  <= 25'd0;
                    xres_aborted     <= 1'b0;
                    xres_lane_mask   <= 72'd0;
                    rd_issued        <= 32'd0;
                    rd_recv          <= 32'd0;
                    state            <= S_INIT0;
                end
            end

            // cfgq_ is valid from here on.
            S_INIT0: begin
                wpos  <= (cfgq_seed[9:0] >= 10'd576) ? cfgq_seed[9:0] - 10'd576 : cfgq_seed[9:0];
                state <= S_INIT;
            end

            S_INIT: begin
                at_ridx <= 5'd0;
                chk_at  <= 1'b0;
                if (MODE == 0 && cfgq_phases[3]) begin
                    at_idx  <= 5'd0;
                    m_addr  <= at_addr(5'd0);
                    m_wdata <= at_data(5'd0, inv);
                    m_write <= 1'b1;
                    state   <= S_AT_WR;
                end else if (cfgq_phases[0]) begin
                    gw_data <= g_first;
                    gw_lfsr <= seed_step[606:576];
                    m_addr  <= cfgq_start;
                    m_wdata <= g_first ^ {576{inv}};
                    n_left  <= range_words;
                    m_write <= 1'b1;
                    state   <= S_WR;
                end else if (cfgq_phases[1]) begin
                    gr_data <= g_first;
                    gr_lfsr <= seed_step[606:576];
                    rd_addr <= cfgq_start;
                    m_addr  <= cfgq_start;
                    n_left  <= range_words;
                    m_read  <= 1'b1;
                    state   <= S_RD;
                end else begin
                    state <= S_DONE;
                end
            end

            S_AT_WR: begin
                if (accept) begin
                    if (at_idx == AT_LAST) begin
                        m_write <= 1'b0;
                        at_idx  <= 5'd0;
                        m_addr  <= at_addr(5'd0);
                        m_read  <= 1'b1;
                        chk_at  <= 1'b1;
                        state   <= S_AT_RD;
                    end else begin
                        at_idx  <= at_idx + 5'd1;
                        m_addr  <= at_addr(at_idx + 5'd1);
                        m_wdata <= at_data(at_idx + 5'd1, inv);
                    end
                end
                if (stop && !(m_write && !m_ready)) begin
                    m_write <= 1'b0;
                    state   <= S_WAIT_RD;
                end
            end

            S_AT_RD: begin
                if (accept) begin
                    if (at_idx == AT_LAST) begin
                        m_read <= 1'b0;
                    end else begin
                        at_idx <= at_idx + 5'd1;
                        m_addr <= at_addr(at_idx + 5'd1);
                    end
                end
                // All 26 words received and compared: next phase.
                if (!m_read && !reads_out && !c1_v && !c2_v && !c3_v && rd_recv != 32'd0) begin
                    chk_at <= 1'b0;
                    case (after_at(cfgq_phases))
                        S_WR: begin
                            gw_data <= g_first;
                            gw_lfsr <= seed_step[606:576];
                            m_addr  <= cfgq_start;
                            m_wdata <= g_first ^ {576{inv}};
                            n_left  <= range_words;
                            m_write <= 1'b1;
                            state   <= S_WR;
                        end
                        S_RD: begin
                            gr_data <= g_first;
                            gr_lfsr <= seed_step[606:576];
                            rd_addr <= cfgq_start;
                            m_addr  <= cfgq_start;
                            n_left  <= range_words;
                            m_read  <= 1'b1;
                            state   <= S_RD;
                        end
                        default: state <= S_DONE;
                    endcase
                end
                if (stop && !(m_read && !m_ready)) begin
                    m_read <= 1'b0;
                    state  <= S_WAIT_RD;
                end
            end

            S_WR: begin
                xres_wr_cycles <= xres_wr_cycles + 32'd1;
                if (accept) begin
                    if (n_left == 25'd0) begin
                        m_write <= 1'b0;
                        if (cfgq_phases[1]) begin
                            gr_data <= g_first;
                            gr_lfsr <= seed_step[606:576];
                            rd_addr <= cfgq_start;
                            m_addr  <= cfgq_start;
                            n_left  <= range_words;
                            m_read  <= 1'b1;
                            state   <= S_RD;
                        end else begin
                            state <= S_DONE;
                        end
                    end else begin
                        n_left  <= n_left - 25'd1;
                        m_addr  <= m_addr + 25'd1;
                        m_wdata <= gw_next ^ {576{inv}};
                        gw_data <= gw_next;
                        gw_lfsr <= gw_step[606:576];
                    end
                end
                if (stop && !(m_write && !m_ready)) begin
                    m_write <= 1'b0;
                    state   <= S_WAIT_RD;
                end
            end

            S_RD: begin
                xres_rd_cycles <= xres_rd_cycles + 32'd1;
                if (accept) begin
                    if (n_left == 25'd0) begin
                        m_read <= 1'b0;
                        state  <= S_WAIT_RD;
                    end else begin
                        n_left <= n_left - 25'd1;
                        m_addr <= m_addr + 25'd1;
                    end
                end
                if (stop && !(m_read && !m_ready)) begin
                    m_read <= 1'b0;
                    state  <= S_WAIT_RD;
                end
            end

            // Wait for every outstanding read and drain the compare pipeline.
            S_WAIT_RD: begin
                if (reads_out)
                    xres_rd_cycles <= xres_rd_cycles + 32'd1;
                if (!reads_out && !c1_v && !c2_v && !c3_v) begin
                    xres_aborted <= stop;
                    state        <= S_DONE;
                end
            end

            S_DONE: begin
                if (!reads_out && !c1_v && !c2_v && !c3_v) begin
                    busy      <= 1'b0;
                    done_tg   <= ~done_tg;
                    xres_runs <= xres_runs + 16'd1;
                    state     <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase

        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            m_read  <= 1'b0;
            m_write <= 1'b0;
            c1_v    <= 1'b0;
            c2_v    <= 1'b0;
            c3_v    <= 1'b0;
            chk_at  <= 1'b0;
            start_d <= start_s;   // a toggle seen during reset does not start a run
            done_tg <= 1'b0;
            xres_runs        <= 16'd0;
            xres_first_valid <= 1'b0;
            xres_aborted     <= 1'b0;
            xres_err_words   <= 32'd0;
            rd_issued        <= 32'd0;
            rd_recv          <= 32'd0;
        end
    end

    // No initial values: PR region registers are undefined after PR; every
    // register that matters is set by rst (the shell holds the persona in
    // reset during and after PR, and after configuration).
endmodule

`default_nettype wire
