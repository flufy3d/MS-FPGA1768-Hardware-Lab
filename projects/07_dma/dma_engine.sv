`default_nettype none

// --------------------------------------------------------------------------
// dma_engine — descriptor engine of 07_dma (replaces the Intel example
// descriptor controller; the hard IP runs with internal_controller_hwtcl = 0)
//
// dma_dir (one per direction) cuts a transfer into hard IP descriptors and
// feeds them to the data mover:
//   IS_WRITE = 0  read DMA  (host -> FPGA, "H2D"): rd_ast_rx / rd_ast_tx
//   IS_WRITE = 1  write DMA (FPGA -> host, "D2H"): wr_ast_rx / wr_ast_tx
//
// Hard IP descriptor (160 bits, from the Quartus 25.1 data mover RTL
// altpcieav_dma_rd.sv / altpcieav_dma_wr_2.sv and the example controller
// altpcie_dynamic_control.sv):
//   [63:0]    source address       (host bus address for read DMA, Avalon for write DMA)
//   [127:64]  destination address
//   [145:128] length in dwords (18 bits; 512 KB = 0x20000 is the largest power of two)
//   [153:146] descriptor ID (this engine uses 0..127)
//   [159:154] 0
// Descriptor sink: readyLatency 3. The read mover's descriptor FIFO is 6 deep
// and ready = (count < 3). This engine issues a descriptor only if ready was
// high 3 cycles earlier and nothing was issued in the 3 cycles before, so at
// most one descriptor is in flight inside the ready-latency window.
// Status source (32 bits, no ready): [7:0] descriptor ID, [8] completed
// (read DMA: 0 = flushed / aborted; write DMA: always 1).
//
// Host buffer: CHUNK_ENTRIES chunks of 2^CHUNK_SHIFT bytes (4 MB common
// buffers). The host writes their bus addresses into the chunk table once.
// A transfer of LENGTH bytes starts at chunk CHUNK0, offset 0; byte `off` of
// the transfer is at chunk (CHUNK0 + off / 4 MB) mod 64, and at FPGA address
// FPGA_ADDR + off. Descriptors are 2^DESC_SHIFT bytes (last one shorter) and
// never cross a chunk boundary because DESC_SHIFT <= CHUNK_SHIFT. The whole
// transfer is repeated LOOPS times over the same addresses.
//
// Timing (cycles of the 250 MHz core clock, free-running counter `now`):
//   t_first  cycle the first descriptor was handed to the hard IP
//   t_last   cycle the last status came back
//   d_first / d_last / beats   first / last Avalon data beat and beat count
// --------------------------------------------------------------------------
module dma_dir #(
    parameter bit IS_WRITE = 1'b0
) (
    input  wire          clk,
    input  wire          rst,
    input  wire  [63:0]  now,

    // configuration (latched at start)
    input  wire  [63:0]  cfg_fpga_addr,
    input  wire  [31:0]  cfg_length,       // bytes, multiple of 32
    input  wire  [5:0]   cfg_chunk0,
    input  wire  [4:0]   cfg_desc_shift,   // clamped to 8..19
    input  wire  [15:0]  cfg_loops,        // 0 acts as 1
    input  wire  [7:0]   cfg_max_out,      // descriptors in flight, clamped to 1..64
    input  wire  [63:0]  cfg_stat_addr,    // 0 = no status record
    input  wire          start,
    input  wire          abort,

    // chunk table write port
    input  wire          tbl_we,
    input  wire  [5:0]   tbl_idx,
    input  wire  [63:0]  tbl_data,

    // hard IP descriptor sink / status source
    output logic         desc_valid,
    output logic [159:0] desc_data,
    input  wire          desc_ready,
    input  wire          st_valid,
    input  wire  [31:0]  st_data,

    // one Avalon data beat of this direction
    input  wire          beat,

    // status record request (to dma_txs_writer): one-cycle pulse, then
    // wait for rec_ack
    output logic         rec_req,
    input  wire          rec_ack,
    output logic [63:0]  rec_addr,

    // results
    output logic         busy,
    output logic         done,
    output logic         aborted,
    output logic [31:0]  desc_issued,
    output logic [31:0]  desc_done,
    output logic [31:0]  desc_err,
    output logic [63:0]  t_first,
    output logic [63:0]  t_last,
    output logic [63:0]  d_first,
    output logic [63:0]  d_last,
    output logic [63:0]  beats
);
    import dma_pkg::*;

    // ---------------------------------------------------------- chunk table
    logic [63:0] tbl [0:CHUNK_ENTRIES-1];
    logic [5:0]  tbl_ridx;
    logic [63:0] tbl_q;
    always_ff @(posedge clk) begin
        if (tbl_we)
            tbl[tbl_idx] <= tbl_data;
        tbl_q <= tbl[tbl_ridx];
    end

    // ---------------------------------------------------------- state
    typedef enum logic [2:0] {S_IDLE, S_LOOK, S_LOOKW, S_PREP, S_PREP2, S_ISSUE, S_WAIT, S_REC} state_t;
    state_t state;

    logic [63:0] fpga_base;
    logic [31:0] length, off, dsz;
    logic [63:0] host_a, fpga_a;   // descriptor addresses (pipeline stage)
    logic [5:0]  chunk0;
    logic [4:0]  shift;
    logic [15:0] loops, pass;
    logic [7:0]  max_out;
    logic [2:0]  ready_q;     // ready_q[2] = desc_ready three cycles ago
    logic [1:0]  cool;        // cycles left before the next descriptor may be issued
    logic        first_beat;

    // Status from the hard IP, registered once: the write mover's status valid
    // is combinational from its data alignment buffer (failed timing into the
    // 32-bit counters below, 2026-11-20).
    logic        st_v;
    logic [31:0] st_d;
    always_ff @(posedge clk) begin
        st_v <= st_valid && !rst;
        st_d <= st_data;
    end

    wire [31:0] remain   = length - off;
    wire [31:0] dmax     = 32'd1 << shift;
    wire [31:0] dsz_n    = (remain < dmax) ? remain : dmax;
    wire [31:0] in_fly   = desc_issued - desc_done;
    // in_fly_ok is registered (timing); it is one cycle old, which is safe
    // because issues are at least 4 cycles apart (cool).
    logic       in_fly_ok;
    wire        can_issue = ready_q[2] && (cool == 2'd0) && in_fly_ok;

    always_comb begin
        desc_valid = (state == S_ISSUE) && can_issue;
    end

    always_ff @(posedge clk) begin
        ready_q   <= {ready_q[1:0], desc_ready};
        in_fly_ok <= (in_fly < {24'd0, max_out});
        if (cool != 2'd0)
            cool <= cool - 2'd1;
        rec_req <= 1'b0;

        // status returned by the hard IP (counted in every state)
        if (st_v) begin
            desc_done <= desc_done + 32'd1;
            t_last    <= now;
            if (!IS_WRITE && !st_d[8])
                desc_err <= desc_err + 32'd1;
        end

        // data beats while a transfer runs
        if (beat && busy) begin
            if (first_beat)
                d_first <= now;
            first_beat <= 1'b0;
            d_last     <= now;
            beats      <= beats + 64'd1;
        end

        case (state)
        S_IDLE: begin
            if (start) begin
                fpga_base   <= cfg_fpga_addr;
                length      <= cfg_length;
                chunk0      <= cfg_chunk0;
                shift       <= (cfg_desc_shift < 5'(DESC_SHIFT_MIN)) ? 5'(DESC_SHIFT_MIN) :
                               (cfg_desc_shift > 5'(DESC_SHIFT_MAX)) ? 5'(DESC_SHIFT_MAX) : cfg_desc_shift;
                loops       <= (cfg_loops == 16'd0) ? 16'd1 : cfg_loops;
                max_out     <= (cfg_max_out == 8'd0) ? 8'd1 : (cfg_max_out > 8'd64) ? 8'd64 : cfg_max_out;
                rec_addr    <= cfg_stat_addr;
                off         <= 32'd0;
                pass        <= 16'd0;
                desc_issued <= 32'd0;
                desc_done   <= 32'd0;
                desc_err    <= 32'd0;
                t_first     <= 64'd0;
                t_last      <= 64'd0;
                d_first     <= 64'd0;
                d_last      <= 64'd0;
                beats       <= 64'd0;
                first_beat  <= 1'b1;
                busy        <= 1'b1;
                done        <= 1'b0;
                aborted     <= 1'b0;
                state       <= (cfg_length == 32'd0) ? S_WAIT : S_LOOK;
            end
        end
        S_LOOK: begin
            tbl_ridx <= chunk0 + off[CHUNK_SHIFT+5:CHUNK_SHIFT];
            state    <= S_LOOKW;
        end
        S_LOOKW: begin
            state <= S_PREP;      // tbl_q valid next cycle
        end
        S_PREP: begin             // two stages: 64-bit adds, then the descriptor
            dsz    <= dsz_n;
            host_a <= tbl_q + {42'd0, off[CHUNK_SHIFT-1:0]};
            fpga_a <= fpga_base + {32'd0, off};
            state  <= S_PREP2;
        end
        S_PREP2: begin
            if (!IS_WRITE)        // read DMA: host -> FPGA
                desc_data <= {6'd0, 1'b0, desc_issued[6:0], 18'(dsz >> 2), fpga_a, host_a};
            else                  // write DMA: FPGA -> host
                desc_data <= {6'd0, 1'b0, desc_issued[6:0], 18'(dsz >> 2), host_a, fpga_a};
            state <= S_ISSUE;
        end
        S_ISSUE: begin
            if (can_issue) begin
                desc_issued <= desc_issued + 32'd1;
                cool        <= 2'd3;
                if (desc_issued == 32'd0)
                    t_first <= now;
                if (off + dsz >= length) begin
                    if (pass + 16'd1 < loops) begin
                        pass  <= pass + 16'd1;
                        off   <= 32'd0;
                        state <= S_LOOK;
                    end else begin
                        off   <= length;
                        state <= S_WAIT;
                    end
                end else begin
                    off   <= off + dsz;
                    state <= S_LOOK;
                end
            end
        end
        S_WAIT: begin
            if (desc_done == desc_issued) begin   // t_last updates with desc_done
                if (rec_addr != 64'd0) begin
                    rec_req <= 1'b1;
                    state   <= S_REC;
                end else begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            end
        end
        S_REC: begin              // rec_req was a one-cycle pulse
            if (rec_ack) begin
                busy    <= 1'b0;
                done    <= 1'b1;
                state   <= S_IDLE;
            end
        end
        default: state <= S_IDLE;
        endcase

        if (abort && state != S_IDLE) begin
            busy    <= 1'b0;
            aborted <= 1'b1;
            rec_req <= 1'b0;
            state   <= S_IDLE;
        end

        if (rst) begin
            state       <= S_IDLE;
            ready_q     <= 3'd0;
            cool        <= 2'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
            aborted     <= 1'b0;
            rec_req     <= 1'b0;
            desc_issued <= 32'd0;
            desc_done   <= 32'd0;
            desc_err    <= 32'd0;
            beats       <= 64'd0;
            rec_addr    <= 64'd0;
            first_beat  <= 1'b1;
        end
    end
endmodule

// --------------------------------------------------------------------------
// dma_txs_writer — writes the 16-byte status record of a finished transfer
// into host memory through the hard IP's TX slave (txs, 32-bit, single
// writes). Order: DW1, DW2, DW3, then DW0 last, so a host that sees DW0 ==
// SEQ also sees the other fields (posted writes stay in order; the record
// follows the transfer's own write TLPs on the same link).
//
//   DW0  SEQ (the value the host wrote to the direction's SEQ register)
//   DW1  cycles[31:0]   t_last - t_first, 250 MHz core clock
//   DW2  cycles[63:32]
//   DW3  [15:0] descriptors completed, [31:16] descriptors with an error status
// --------------------------------------------------------------------------
module dma_txs_writer (
    input  wire          clk,
    input  wire          rst,

    input  wire  [1:0]   req,          // one-cycle pulses, [0] H2D, [1] D2H
    output logic [1:0]   ack,
    input  wire  [63:0]  addr0, addr1,
    input  wire  [127:0] rec0,  rec1,  // {DW3, DW2, DW1, DW0}

    output logic [63:0]  txs_address,
    output logic         txs_write,
    output logic [31:0]  txs_writedata,
    input  wire          txs_waitrequest
);
    logic         active, who;
    logic [1:0]   pend;
    logic [1:0]   k;          // 0..3 -> DW1, DW2, DW3, DW0
    logic [63:0]  base;
    logic [127:0] rec;

    wire [1:0] dw = k + 2'd1;  // DW index written in step k

    always_ff @(posedge clk) begin
        ack  <= 2'b00;
        pend <= pend | req;
        if (!active) begin
            txs_write <= 1'b0;
            if (pend[0] || pend[1]) begin
                who    <= !pend[0];
                base   <= pend[0] ? addr0 : addr1;
                rec    <= pend[0] ? rec0 : rec1;
                pend   <= (pend | req) & (pend[0] ? 2'b10 : 2'b01);
                active <= 1'b1;
                k      <= 2'd0;
            end
        end else if (!txs_write) begin
            txs_write     <= 1'b1;
            txs_address   <= base + {60'd0, dw, 2'b00};
            txs_writedata <= rec[32*dw +: 32];
        end else if (!txs_waitrequest) begin
            txs_write <= 1'b0;
            if (k == 2'd3) begin
                active   <= 1'b0;
                ack[who] <= 1'b1;
            end
            k <= k + 2'd1;
        end
        if (rst) begin
            active    <= 1'b0;
            txs_write <= 1'b0;
            ack       <= 2'b00;
            pend      <= 2'b00;
        end
    end
endmodule

`default_nettype wire
