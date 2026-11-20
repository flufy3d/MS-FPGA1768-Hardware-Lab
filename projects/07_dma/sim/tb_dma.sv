`timescale 1ns / 1ps
`default_nettype none

// --------------------------------------------------------------------------
// tb_dma — simulation of dma_port (07_dma) against a behavioural model of
// the Arria 10 Avalon-MM DMA hard IP data movers.
//
// The model follows the Quartus 25.1 data mover RTL (altpcieav_dma_rd.sv,
// altpcieav_dma_wr_2.sv):
//   - descriptor sinks with readyLatency 3, 6-deep descriptor FIFO, ready =
//     (count < 3); a valid without ready three cycles earlier, or a FIFO
//     overflow, is an error
//   - read DMA: reads host memory and writes it to dma_rd_master in bursts of
//     1..16 beats, bursts of one descriptor shuffled (out of address order),
//     random gaps; status {8'h?, done = 1, ID} after the last write
//   - write DMA: read bursts on dma_wr_master (pipelined, waitrequest
//     honoured), data written to host memory, status after the last beat
//   - TX slave with random waitrequest, writes go to host memory
// Host memory is a sparse dword array indexed by bus address / 4.
// --------------------------------------------------------------------------
module tb_dma;
    import dma_pkg::*;

    logic clk = 1'b0;
    always #2 clk = ~clk;          // 250 MHz
    logic rst = 1'b1;

    // ---------------------------------------------------------- DUT ports
    logic [15:0]  av_address = '0;
    logic         av_read = 1'b0, av_write = 1'b0;
    logic [31:0]  av_writedata = '0;
    wire  [31:0]  av_readdata;
    wire          av_readdatavalid;

    wire          rd_desc_valid, wr_desc_valid;
    wire  [159:0] rd_desc_data, wr_desc_data;
    logic         rd_desc_ready = 1'b0, wr_desc_ready = 1'b0;
    logic         rd_st_valid = 1'b0, wr_st_valid = 1'b0;
    logic [31:0]  rd_st_data = '0, wr_st_data = '0;

    logic [63:0]  rdm_address = '0;
    logic         rdm_write = 1'b0;
    logic [255:0] rdm_writedata = '0;
    logic [31:0]  rdm_byteenable = '0;
    logic [4:0]   rdm_burstcount = '0;
    wire          rdm_waitrequest;

    logic [63:0]  wrm_address = '0;
    logic         wrm_read = 1'b0;
    logic [4:0]   wrm_burstcount = '0;
    wire          wrm_waitrequest;
    wire  [255:0] wrm_readdata;
    wire          wrm_readdatavalid;

    wire  [63:0]  txs_address;
    wire          txs_chipselect, txs_write, txs_read;
    wire  [31:0]  txs_writedata;
    wire  [3:0]   txs_byteenable;
    wire  [4:0]   txs_burstcount;
    logic         txs_waitrequest = 1'b1;

    dma_port #(.PORT_INDEX(0), .RAM_BANKS(256)) dut (
        .clk (clk), .rst (rst), .temp_word (32'h1000_0123),
        .av_address (av_address), .av_read (av_read), .av_write (av_write),
        .av_writedata (av_writedata), .av_readdata (av_readdata),
        .av_readdatavalid (av_readdatavalid),
        .rd_desc_valid (rd_desc_valid), .rd_desc_data (rd_desc_data), .rd_desc_ready (rd_desc_ready),
        .rd_st_valid (rd_st_valid), .rd_st_data (rd_st_data),
        .rdm_address (rdm_address), .rdm_write (rdm_write), .rdm_writedata (rdm_writedata),
        .rdm_byteenable (rdm_byteenable), .rdm_burstcount (rdm_burstcount),
        .rdm_waitrequest (rdm_waitrequest),
        .wr_desc_valid (wr_desc_valid), .wr_desc_data (wr_desc_data), .wr_desc_ready (wr_desc_ready),
        .wr_st_valid (wr_st_valid), .wr_st_data (wr_st_data),
        .wrm_address (wrm_address), .wrm_read (wrm_read), .wrm_burstcount (wrm_burstcount),
        .wrm_waitrequest (wrm_waitrequest), .wrm_readdata (wrm_readdata),
        .wrm_readdatavalid (wrm_readdatavalid),
        .txs_address (txs_address), .txs_chipselect (txs_chipselect), .txs_write (txs_write),
        .txs_writedata (txs_writedata), .txs_byteenable (txs_byteenable),
        .txs_burstcount (txs_burstcount), .txs_read (txs_read), .txs_waitrequest (txs_waitrequest)
    );

    // ---------------------------------------------------------- bookkeeping
    int errors = 0;
    task automatic fail(input string msg);
        errors++;
        $display("# FAIL %s (t=%0t)", msg, $time);
    endtask
    task automatic check(input bit cond, input string msg);
        if (cond) $display("# ok   %s", msg);
        else      fail(msg);
    endtask

    // ---------------------------------------------------------- host memory
    logic [31:0] hmem [longint unsigned];   // index = bus address / 4

    function automatic logic [31:0] hrd(input logic [63:0] a);
        if (hmem.exists(a >> 2)) return hmem[a >> 2];
        return 32'hDEAD_BEEF;
    endfunction

    // ---------------------------------------------------------- BAR0 access
    task automatic wr32(input logic [15:0] a, input logic [31:0] d);
        @(posedge clk);
        av_address   <= a;
        av_writedata <= d;
        av_write     <= 1'b1;
        @(posedge clk);
        av_write     <= 1'b0;
    endtask

    task automatic rd32(input logic [15:0] a, output logic [31:0] d);
        @(posedge clk);
        av_address <= a;
        av_read    <= 1'b1;
        @(posedge clk);
        av_read    <= 1'b0;
        while (!av_readdatavalid) @(posedge clk);
        d = av_readdata;
    endtask

    // ---------------------------------------------------------- descriptor sinks
    // ready history and FIFOs, one model per direction
    logic [159:0] rd_q [$], wr_q [$];
    logic [2:0]   rd_rdy_h = '0, wr_rdy_h = '0;

    always @(posedge clk) begin
        if (rd_desc_valid) begin
            if (!rd_rdy_h[2]) fail("read DMA descriptor valid without ready 3 cycles earlier");
            rd_q.push_back(rd_desc_data);
            if (rd_q.size() > 6) fail("read DMA descriptor FIFO overflow");
        end
        if (wr_desc_valid) begin
            if (!wr_rdy_h[2]) fail("write DMA descriptor valid without ready 3 cycles earlier");
            wr_q.push_back(wr_desc_data);
            if (wr_q.size() > 6) fail("write DMA descriptor FIFO overflow");
        end
        rd_rdy_h <= {rd_rdy_h[1:0], rd_desc_ready};
        wr_rdy_h <= {wr_rdy_h[1:0], wr_desc_ready};
        // ready computed from the count after this cycle's push/pop (as the RTL,
        // whose ready is a function of the registered count)
        rd_desc_ready <= (rd_q.size() < 3);
        wr_desc_ready <= (wr_q.size() < 3);
    end

    // ---------------------------------------------------------- read DMA model
    initial begin : read_mover
        logic [159:0] d;
        logic [63:0]  src, dst;
        int           ndw, nbeats, id;
        int           starts [$];
        forever begin
            @(posedge clk);
            if (rd_q.size() == 0) continue;
            d = rd_q[0];
            repeat ($urandom_range(2, 10)) @(posedge clk);
            void'(rd_q.pop_front());
            src = d[63:0];
            dst = d[127:64];
            ndw = d[145:128];
            id  = d[153:146];
            nbeats = ndw / 8;
            if (ndw % 8 != 0 || src[4:0] != 0 || dst[4:0] != 0)
                fail($sformatf("read descriptor not 32-byte aligned: src %h dst %h dw %0d", src, dst, ndw));
            // cut into bursts, then shuffle within groups of 8 bursts
            starts.delete();
            for (int b = 0; b < nbeats; ) begin
                automatic int n = $urandom_range(1, 16);
                if (b + n > nbeats) n = nbeats - b;
                starts.push_back((b << 8) | n);
                b += n;
            end
            for (int g = 0; g < starts.size(); g += 8) begin
                for (int i = g; i < g + 8 && i < starts.size(); i++) begin
                    automatic int j = $urandom_range(i, (g + 7 < starts.size() - 1) ? g + 7 : starts.size() - 1);
                    automatic int t = starts[i]; starts[i] = starts[j]; starts[j] = t;
                end
            end
            foreach (starts[k]) begin
                automatic int b0 = starts[k] >> 8, n = starts[k] & 8'hFF;
                for (int i = 0; i < n; i++) begin
                    logic [255:0] data;
                    for (int w = 0; w < 8; w++)
                        data[32*w +: 32] = hrd(src + 64'((b0 + i) * 32 + 4 * w));
                    if ($urandom_range(0, 7) == 0) begin
                        rdm_write <= 1'b0;
                        @(posedge clk);
                    end
                    rdm_write      <= 1'b1;
                    rdm_address    <= (i == 0) ? dst + 64'(b0 * 32) : 64'hX;
                    rdm_burstcount <= (i == 0) ? 5'(n) : 5'hX;
                    rdm_writedata  <= data;
                    rdm_byteenable <= 32'hFFFF_FFFF;
                    @(posedge clk);
                    while (rdm_waitrequest) @(posedge clk);
                end
                rdm_write <= 1'b0;
            end
            rdm_write <= 1'b0;
            @(posedge clk);
            rd_st_valid <= 1'b1;
            rd_st_data  <= {23'd0, 1'b1, 8'(id)};
            @(posedge clk);
            rd_st_valid <= 1'b0;
        end
    end

    // ---------------------------------------------------------- write DMA model
    logic [63:0] wr_expect [$];        // host address of each returned beat
    int          wr_beats_left [$];    // per descriptor in flight: beats still to come
    int          wr_ids [$];

    initial begin : write_mover_issue
        logic [159:0] d;
        logic [63:0]  src, dst;
        int           ndw, nbeats;
        forever begin
            @(posedge clk);
            if (wr_q.size() == 0 || wr_ids.size() >= 2) continue;
            d = wr_q.pop_front();
            src = d[63:0];
            dst = d[127:64];
            ndw = d[145:128];
            nbeats = ndw / 8;
            if (ndw % 8 != 0 || src[4:0] != 0 || dst[4:0] != 0)
                fail($sformatf("write descriptor not 32-byte aligned: src %h dst %h dw %0d", src, dst, ndw));
            wr_ids.push_back(d[153:146]);
            wr_beats_left.push_back(nbeats);
            for (int b = 0; b < nbeats; ) begin
                automatic int n = $urandom_range(1, 16);
                if (b + n > nbeats) n = nbeats - b;
                for (int i = 0; i < n; i++)
                    wr_expect.push_back(dst + 64'((b + i) * 32));
                wrm_read       <= 1'b1;
                wrm_address    <= src + 64'(b * 32);
                wrm_burstcount <= 5'(n);
                @(posedge clk);
                while (wrm_waitrequest) @(posedge clk);
                wrm_read <= 1'b0;
                if ($urandom_range(0, 3) == 0) @(posedge clk);
                b += n;
            end
            wrm_read <= 1'b0;
        end
    end

    always @(posedge clk) begin : write_mover_data
        wr_st_valid <= 1'b0;
        if (wrm_readdatavalid) begin
            if (wr_expect.size() == 0) begin
                fail("write DMA: unexpected readdatavalid");
            end else begin
                automatic logic [63:0] a = wr_expect.pop_front();
                for (int w = 0; w < 8; w++)
                    hmem[(a + 64'(4 * w)) >> 2] = wrm_readdata[32*w +: 32];
                wr_beats_left[0]--;
                if (wr_beats_left[0] == 0) begin
                    wr_st_valid <= 1'b1;
                    wr_st_data  <= {23'd0, 1'b1, 8'(wr_ids[0])};
                    void'(wr_beats_left.pop_front());
                    void'(wr_ids.pop_front());
                end
            end
        end
    end

    // ---------------------------------------------------------- TX slave
    always @(posedge clk) begin
        txs_waitrequest <= ($urandom_range(0, 2) == 0);
        if (txs_write && !txs_waitrequest) begin
            if (txs_byteenable != 4'hF || txs_burstcount != 5'd1 || !txs_chipselect)
                fail("txs write is not a single full dword");
            hmem[txs_address >> 2] = txs_writedata;
        end
        if (txs_read) fail("txs read");
    end

    // ---------------------------------------------------------- helpers
    localparam logic [15:0] H2D = 16'h0100, D2H = 16'h0180;
    localparam longint unsigned CHUNK = 64'h40_0000;
    logic [63:0] chunk_addr [64];
    localparam logic [63:0] PAT = 64'h1_0000_0000;
    localparam logic [63:0] STAT_BASE = 64'h0000_0007_0000_0000;

    task automatic setup_dir(input logic [15:0] blk, input logic [63:0] fpga, input int len,
                             input int chunk0, input int shift, input int loops, input int max_out,
                             input int seq, input logic [63:0] stat);
        wr32(blk + 16'h00, fpga[31:0]);
        wr32(blk + 16'h04, fpga[63:32]);
        wr32(blk + 16'h08, len);
        wr32(blk + 16'h0C, chunk0);
        wr32(blk + 16'h10, shift);
        wr32(blk + 16'h14, loops);
        wr32(blk + 16'h18, max_out);
        wr32(blk + 16'h1C, seq);
        wr32(blk + 16'h20, stat[31:0]);
        wr32(blk + 16'h24, stat[63:32]);
        hmem[stat >> 2] = 32'h0;
    endtask

    // Host bus address of byte `off` of a transfer starting at chunk c0.
    function automatic logic [63:0] haddr(input int c0, input longint unsigned off);
        return chunk_addr[(c0 + int'(off / CHUNK)) % 64] + (off % CHUNK);
    endfunction

    task automatic wait_status(input logic [63:0] stat, input int seq, input int timeout_us);
        int t = 0;
        while (hrd(stat) !== 32'(seq)) begin
            repeat (250) @(posedge clk);
            t++;
            if (t > timeout_us) begin
                fail($sformatf("timeout waiting for status record seq %0d", seq));
                return;
            end
        end
    endtask

    task automatic run_dir(input logic [15:0] blk, input string name, input int exp_desc,
                           input longint unsigned exp_beats, input logic [63:0] stat, input int seq);
        logic [31:0] v, lo, hi;
        wait_status(stat, seq, 20000);
        rd32(blk + 16'h4C, v);
        check(v[1] && !v[0] && !v[2], $sformatf("%s: STATE done (0x%0h)", name, v));
        rd32(blk + 16'h40, v);
        check(v == exp_desc, $sformatf("%s: %0d descriptors issued (expected %0d)", name, v, exp_desc));
        rd32(blk + 16'h44, v);
        check(v == exp_desc, $sformatf("%s: %0d descriptors done", name, v));
        rd32(blk + 16'h70, lo);
        check(lo == exp_beats, $sformatf("%s: %0d data beats (expected %0d)", name, lo, exp_beats));
        rd32(blk + 16'h78, lo);
        rd32(blk + 16'h7C, hi);
        check(hrd(stat + 4) == lo && hrd(stat + 8) == hi && hrd(stat + 12) == {16'd0, 16'(exp_desc)},
              $sformatf("%s: status record cycles %0d, DW3 0x%08h", name, {hi, lo}, hrd(stat + 12)));
        $display("#      %s: %0d bytes in %0d cycles = %.2f GB/s (model)", name, exp_beats * 32,
                 {hi, lo}, real'(exp_beats * 32) / (real'({hi, lo}) * 4.0));
    endtask

    // ---------------------------------------------------------- test
    initial begin
        logic [31:0] v, v2;
        int          mism;
        longint unsigned corrupt;

        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (10) @(posedge clk);

        $display("# ==== contract registers");
        rd32(16'h0000, v); check(v == 32'h444D4137, $sformatf("SHELL_ID 0x%08h", v));
        rd32(16'h0004, v); check(v == 32'h00000010, $sformatf("CAPS 0x%08h", v));
        rd32(16'h0008, v); check(v == 32'h0, "CAPS2 0");
        rd32(16'h000C, v); check(v == 32'h0, "PORT_INDEX 0");
        rd32(16'h0040, v); check(v == 32'h50434945, "ID");
        rd32(16'h0068, v); check(v == 32'h0040_0000, $sformatf("RAM_BYTES 0x%08h", v));
        wr32(16'h0010, 32'hCAFE_F00D);
        rd32(16'h0010, v); check(v == 32'hCAFE_F00D, "SCRATCH read back");
        rd32(16'h0030, v); rd32(16'h0030, v2); check(v != v2, "COUNTER changing");
        rd32(16'h0050, v); check(v == 32'h1000_0123, "TEMP passed through");
        rd32(16'h0110, v); check(v == 19, "H2D DESC_SHIFT reset 19");

        // chunk table: scattered 4 MB chunks above 4 GB
        for (int i = 0; i < 64; i++) begin
            chunk_addr[i] = 64'h0000_0010_0000_0000 + 64'(i) * 64'h0000_0001_0040_0000 +
                            ((i % 3) * 64'h0080_0000);
            wr32(16'h1000 + 16'(8 * i),     chunk_addr[i][31:0]);
            wr32(16'h1000 + 16'(8 * i) + 4, chunk_addr[i][63:32]);
        end
        wr32(16'h0088, 32'h1234_5678);     // seed

        // ---------------------------------------------------------- 1
        $display("# ==== 1: H2D pattern, 64 KB, 4 KB descriptors, max 3 in flight");
        for (longint unsigned o = 0; o < 65536; o += 4)
            hmem[haddr(1, o) >> 2] = pat_dw(32'((PAT + 64'h2000 + o) >> 2), 32'h1234_5678);
        setup_dir(H2D, PAT + 64'h2000, 65536, 1, 12, 1, 3, 101, STAT_BASE);
        wr32(16'h0080, 32'h1);
        run_dir(H2D, "H2D pattern", 16, 2048, STAT_BASE, 101);
        rd32(16'h0200, v); check(v == 0, $sformatf("checker: %0d errors", v));
        rd32(16'h0214, v); check(v == 2048, $sformatf("checker: %0d beats", v));

        // ---------------------------------------------------------- 2
        $display("# ==== 2: H2D pattern with one corrupted dword");
        corrupt = haddr(1, 64'h1234) >> 2;
        hmem[corrupt] = hmem[corrupt] ^ 32'h0000_0100;
        setup_dir(H2D, PAT + 64'h2000, 65536, 1, 12, 1, 64, 102, STAT_BASE);
        wr32(16'h0080, 32'h1);
        wait_status(STAT_BASE, 102, 20000);
        rd32(16'h0200, v); check(v == 1, $sformatf("checker: %0d error", v));
        rd32(16'h0204, v); check(v == 32'(PAT + 64'h2000 + 64'h1234), $sformatf("checker: first error address 0x%08h", v));
        rd32(16'h020C, v); rd32(16'h0210, v2);
        check((v ^ v2) == 32'h0000_0100, $sformatf("checker: expected 0x%08h got 0x%08h", v, v2));
        hmem[corrupt] = hmem[corrupt] ^ 32'h0000_0100;

        // ---------------------------------------------------------- 3
        $display("# ==== 3: D2H pattern, 64 KB to chunk 2, 512 KB descriptors");
        setup_dir(D2H, PAT + 64'h40, 65536, 2, 19, 1, 64, 201, STAT_BASE + 64'h20);
        wr32(16'h0080, 32'h2);
        run_dir(D2H, "D2H pattern", 1, 2048, STAT_BASE + 64'h20, 201);
        mism = 0;
        for (longint unsigned o = 0; o < 65536; o += 4)
            if (hrd(haddr(2, o)) !== pat_dw(32'((PAT + 64'h40 + o) >> 2), 32'h1234_5678)) mism++;
        check(mism == 0, $sformatf("D2H pattern in host memory: %0d bad dwords", mism));

        // ---------------------------------------------------------- 4
        $display("# ==== 4: RAM loopback, 256 KB: H2D into RAM 0x1000, D2H back to chunk 5");
        for (longint unsigned o = 0; o < 262144; o += 4)
            hmem[haddr(3, o) >> 2] = $urandom;
        setup_dir(H2D, 64'h1000, 262144, 3, 14, 1, 64, 103, STAT_BASE);
        wr32(16'h0080, 32'h1);
        run_dir(H2D, "H2D RAM", 16, 8192, STAT_BASE, 103);
        setup_dir(D2H, 64'h1000, 262144, 5, 13, 1, 64, 202, STAT_BASE + 64'h20);
        wr32(16'h0080, 32'h2);
        run_dir(D2H, "D2H RAM", 32, 8192, STAT_BASE + 64'h20, 202);
        mism = 0;
        for (longint unsigned o = 0; o < 262144; o += 4)
            if (hrd(haddr(5, o)) !== hrd(haddr(3, o))) mism++;
        check(mism == 0, $sformatf("RAM loopback: %0d bad dwords", mism));

        // ---------------------------------------------------------- 5
        $display("# ==== 5: simultaneous H2D pattern + D2H RAM, one CTRL write");
        for (longint unsigned o = 0; o < 131072; o += 4)
            hmem[haddr(8, o) >> 2] = pat_dw(32'((PAT + o) >> 2), 32'h1234_5678);
        setup_dir(H2D, PAT, 131072, 8, 15, 1, 64, 104, STAT_BASE);
        setup_dir(D2H, 64'h1000, 131072, 10, 15, 1, 64, 203, STAT_BASE + 64'h20);
        wr32(16'h0080, 32'h3);
        run_dir(H2D, "both: H2D", 4, 4096, STAT_BASE, 104);
        run_dir(D2H, "both: D2H", 4, 4096, STAT_BASE + 64'h20, 203);
        rd32(16'h0200, v); check(v == 0, $sformatf("checker: %0d errors", v));
        mism = 0;
        for (longint unsigned o = 0; o < 131072; o += 4)
            if (hrd(haddr(10, o)) !== hrd(haddr(3, o))) mism++;
        check(mism == 0, $sformatf("simultaneous D2H from RAM: %0d bad dwords", mism));

        // ---------------------------------------------------------- 6
        $display("# ==== 6: H2D pattern across a chunk boundary: 4 MB + 64 KB from chunk 63 (wraps to 0)");
        for (longint unsigned o = 0; o < 64'h41_0000; o += 4)
            hmem[haddr(63, o) >> 2] = pat_dw(32'((PAT + 64'h100_0000 + o) >> 2), 32'h1234_5678);
        setup_dir(H2D, PAT + 64'h100_0000, 32'h41_0000, 63, 19, 1, 64, 105, STAT_BASE);
        wr32(16'h0080, 32'h1);
        run_dir(H2D, "H2D 4 MB + 64 KB", 9, 64'h41_0000 / 32, STAT_BASE, 105);
        rd32(16'h0200, v); check(v == 0, $sformatf("checker: %0d errors", v));

        // ---------------------------------------------------------- 7
        $display("# ==== 7: D2H pattern, 3 loops of 8 KB + 32 B (4 KB descriptors)");
        setup_dir(D2H, PAT + 64'h800, 8224, 20, 12, 3, 64, 204, STAT_BASE + 64'h20);
        wr32(16'h0080, 32'h2);
        run_dir(D2H, "D2H loops", 9, 3 * 257, STAT_BASE + 64'h20, 204);
        mism = 0;
        for (longint unsigned o = 0; o < 8224; o += 4)
            if (hrd(haddr(20, o)) !== pat_dw(32'((PAT + 64'h800 + o) >> 2), 32'h1234_5678)) mism++;
        check(mism == 0, $sformatf("D2H loops: %0d bad dwords", mism));

        // ---------------------------------------------------------- 8
        $display("# ==== 8: no status record (STAT = 0), poll STATE");
        setup_dir(D2H, PAT, 4096, 21, 12, 1, 64, 205, 64'h0);
        wr32(16'h0080, 32'h2);
        v = 0;
        for (int i = 0; i < 2000 && !v[1]; i++) rd32(D2H + 16'h4C, v);
        check(v[1] == 1'b1, "D2H done without a status record");

        if (errors == 0) $display("# ==== PASSED");
        else             $display("# ==== FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50ms;
        $display("# FAIL global timeout");
        $display("# ==== FAILED");
        $finish;
    end
endmodule

`default_nettype wire
