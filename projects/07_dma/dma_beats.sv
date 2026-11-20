`default_nettype none

// --------------------------------------------------------------------------
// dma_beats — Avalon-MM burst front ends of 07_dma
//
// dma_wr_beats  turns the hard IP's read-DMA master (dma_rd_master: it WRITES
//               host data into the FPGA) into one registered beat per write
//               cycle: {address, data, byteenable}. Never asserts waitrequest.
//
// dma_rd_beats  turns the write-DMA master (dma_wr_master: it READS FPGA data
//               to send to the host) into a stream of beat addresses, one per
//               cycle, from a 4-deep burst command FIFO. The user returns the
//               data a fixed number of cycles later with readdatavalid.
//
// Avalon bursts: the address is given with the first beat only; following
// beats are at +32 bytes. burstcount is 1..16 (5 bits) on this hard IP.
// --------------------------------------------------------------------------
module dma_wr_beats (
    input  wire          clk,
    input  wire          rst,
    input  wire  [63:0]  address,
    input  wire          write,
    input  wire  [255:0] writedata,
    input  wire  [31:0]  byteenable,
    input  wire  [4:0]   burstcount,
    output logic         beat_valid,
    output logic [63:0]  beat_addr,
    output logic [255:0] beat_data,
    output logic [31:0]  beat_be
);
    logic [4:0]  rem;     // beats still to come in the current burst
    logic [63:0] nxt;

    always_ff @(posedge clk) begin
        beat_valid <= 1'b0;
        if (write) begin
            beat_valid <= 1'b1;
            beat_data  <= writedata;
            beat_be    <= byteenable;
            if (rem == 5'd0) begin
                beat_addr <= address;
                nxt       <= address + 64'd32;
                rem       <= burstcount - 5'd1;
            end else begin
                beat_addr <= nxt;
                nxt       <= nxt + 64'd32;
                rem       <= rem - 5'd1;
            end
        end
        if (rst) begin
            rem        <= 5'd0;
            beat_valid <= 1'b0;
        end
    end
endmodule

module dma_rd_beats (
    input  wire          clk,
    input  wire          rst,
    input  wire  [63:0]  address,
    input  wire          read,
    input  wire  [4:0]   burstcount,
    output wire          waitrequest,
    output logic         beat_valid,
    output logic [63:0]  beat_addr
);
    // Command FIFO, 4 entries, in registers (an MLAB FIFO here missed timing).
    // Only address bits [33:5] advance within a burst: the FPGA address map
    // uses bits [32:5], and a burst (at most 512 bytes) that crossed a 16 GB
    // boundary would be outside it anyway.
    (* ramstyle = "logic" *) logic [63:0] f_addr [0:3];
    (* ramstyle = "logic" *) logic [4:0]  f_cnt  [0:3];
    logic [1:0]  wp, rp;
    logic [2:0]  used;

    wire push  = read && !waitrequest;
    wire empty = (used == 3'd0);
    assign waitrequest = (used == 3'd4);

    logic [4:0]  rem;     // beats left in the current burst
    logic [63:0] cur;
    logic        pop;

    always_comb begin
        pop = 1'b0;
        if (!empty && (rem == 5'd0 || rem == 5'd1))
            pop = 1'b1;
    end

    function automatic logic [63:0] next_beat(input logic [63:0] a);
        return {a[63:34], a[33:5] + 29'd1, a[4:0]};
    endfunction

    always_ff @(posedge clk) begin
        if (push) begin
            f_addr[wp] <= address;
            f_cnt[wp]  <= burstcount;
            wp         <= wp + 2'd1;
        end
        if (pop)
            rp <= rp + 2'd1;
        used <= used + {2'd0, push} - {2'd0, pop};

        beat_valid <= 1'b0;
        if (rem != 5'd0) begin
            beat_valid <= 1'b1;
            beat_addr  <= cur;
            if (pop) begin
                cur <= f_addr[rp];
                rem <= f_cnt[rp];
            end else begin
                cur <= next_beat(cur);
                rem <= rem - 5'd1;
            end
        end else if (pop) begin
            beat_valid <= 1'b1;
            beat_addr  <= f_addr[rp];
            cur        <= next_beat(f_addr[rp]);
            rem        <= f_cnt[rp] - 5'd1;
        end

        if (rst) begin
            wp         <= 2'd0;
            rp         <= 2'd0;
            used       <= 3'd0;
            rem        <= 5'd0;
            beat_valid <= 1'b0;
        end
    end
endmodule

// --------------------------------------------------------------------------
// dma_checker — compares written beats with the address pattern (dma_pkg)
//
// Three pipeline stages. Counts mismatching dwords (only bytes with their
// byteenable set are compared; saturates at 2^32-1) and keeps the byte
// address, expected and received value of the first bad dword since clear.
// --------------------------------------------------------------------------
module dma_checker (
    input  wire          clk,
    input  wire          rst,
    input  wire          clear,
    input  wire  [31:0]  seed,
    input  wire          beat_valid,
    input  wire  [63:0]  beat_addr,
    input  wire  [255:0] beat_data,
    input  wire  [31:0]  beat_be,
    output logic [31:0]  err_count,
    output logic [63:0]  err_addr,
    output logic [31:0]  err_exp,
    output logic [31:0]  err_got,
    output logic [63:0]  beats
);
    import dma_pkg::*;

    logic         v1, v2;
    logic [63:0]  a1, a2;
    logic [255:0] d1, d2, e1, e2;
    logic [31:0]  be1;
    logic [7:0]   bad2;
    logic         captured;

    function automatic logic [31:0] mask32(input logic [3:0] be);
        return {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
    endfunction

    function automatic logic [3:0] popcount8(input logic [7:0] x);
        logic [3:0] n;
        n = '0;
        for (int i = 0; i < 8; i++)
            n = n + {3'd0, x[i]};
        return n;
    endfunction

    always_ff @(posedge clk) begin
        // stage 1: expected data
        v1  <= beat_valid;
        a1  <= beat_addr;
        d1  <= beat_data;
        be1 <= beat_be;
        e1  <= pat_beat(beat_addr, seed);

        // stage 2: per-dword compare
        v2 <= v1;
        a2 <= a1;
        d2 <= d1;
        e2 <= e1;
        for (int k = 0; k < 8; k++)
            bad2[k] <= |((e1[32*k +: 32] ^ d1[32*k +: 32]) & mask32(be1[4*k +: 4]));

        // stage 3: count and capture
        if (v2) begin
            beats <= beats + 64'd1;
            if (bad2 != 8'd0) begin
                if (err_count <= 32'hFFFF_FFF0)
                    err_count <= err_count + {28'd0, popcount8(bad2)};
                else
                    err_count <= 32'hFFFF_FFFF;
                if (!captured) begin
                    captured <= 1'b1;
                    for (int k = 7; k >= 0; k--) begin
                        if (bad2[k]) begin
                            err_addr <= a2 + 64'(4 * k);
                            err_exp  <= e2[32*k +: 32];
                            err_got  <= d2[32*k +: 32];
                        end
                    end
                end
            end
        end

        if (rst || clear) begin
            v1        <= 1'b0;
            v2        <= 1'b0;
            err_count <= '0;
            err_addr  <= '0;
            err_exp   <= '0;
            err_got   <= '0;
            beats     <= '0;
            captured  <= 1'b0;
        end
    end
endmodule

`default_nettype wire
