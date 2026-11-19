`timescale 1ns / 1ps
`default_nettype none

// --------------------------------------------------------------------------
// tb_shell_ddr — simulation of the DDR test persona body (ddr_test_csr +
// two ddr_test_engine) behind the shell's ddr_port, against a behavioural
// Avalon-MM memory model of the EMIF user port (random waitrequest, random
// read latency, in-order read data, optional bit-flip fault injection).
//
// Run: sim/run_sim.ps1 (Questa; scripts/env.ps1 locates it).
// Not a model of the EMIF itself; it checks the persona/port logic only.
// --------------------------------------------------------------------------
module mem_model #(parameter int SEED = 1) (
    input  wire          clk,
    input  wire          read,
    input  wire          write,
    input  wire [24:0]   addr,
    input  wire [575:0]  wdata,
    input  wire [71:0]   be,
    output reg           ready,
    output reg  [575:0]  rdata,
    output reg           rvalid,
    input  wire          fault_en,
    input  wire [24:0]   fault_addr,
    input  wire [9:0]    fault_bit
);
    reg [575:0] mem [bit [24:0]];
    typedef struct { reg [575:0] d; int t; } rsp_t;
    rsp_t q[$];
    int cyc = 0;
    int unsigned rnd = SEED;

    function automatic int unsigned rand_u();
        rnd = rnd * 1103515245 + 12345;
        return rnd >> 8;
    endfunction

    always @(posedge clk) begin
        cyc <= cyc + 1;
        // accept
        if (ready && write) begin
            reg [575:0] old;
            old = mem.exists(addr) ? mem[addr] : '0;
            for (int i = 0; i < 72; i++)
                if (be[i]) old[8*i +: 8] = wdata[8*i +: 8];
            mem[addr] = old;
        end
        if (ready && read) begin
            rsp_t r;
            r.d = mem.exists(addr) ? mem[addr] : {18{32'hDEADBEEF}};
            if (fault_en && addr == fault_addr)
                r.d[fault_bit] = ~r.d[fault_bit];
            r.t = cyc + 8 + (rand_u() % 20);
            q.push_back(r);
        end
        ready <= (rand_u() % 4) != 0;      // 25 % wait states
        rvalid <= 1'b0;
        if (q.size() > 0 && q[0].t <= cyc) begin
            rvalid <= 1'b1;
            rdata  <= q[0].d;
            void'(q.pop_front());
        end
    end
    initial begin ready = 0; rvalid = 0; end
endmodule

module tb_shell_ddr;
    parameter int MODE = 0;

    reg clk_100 = 0, t_clk = 0, b_clk = 0;
    always #5     clk_100 = ~clk_100;
    always #1.875 t_clk   = ~t_clk;
    always #1.9   b_clk   = ~b_clk;

    reg persona_rst = 1;
    reg quiesce = 0;
    reg t_urst_n = 0, b_urst_n = 0;

    // CSR bus
    reg  [9:0]  csr_addr = 0;
    reg         csr_read = 0, csr_write = 0;
    reg  [31:0] csr_wdata = 0;
    wire [31:0] csr_rdata;

    wire [15:0] pid;
    wire [4:0]  led;

    // persona <-> port
    wire         tp_rst, bp_rst, tp_read, tp_write, tp_ready, tp_rvalid, bp_read, bp_write, bp_ready, bp_rvalid;
    wire [24:0]  tp_addr, bp_addr;
    wire [575:0] tp_wdata, tp_rdata, bp_wdata, bp_rdata;
    wire [71:0]  tp_be, bp_be;
    // port <-> memory
    wire         te_read, te_write, te_ready, te_rvalid, be_read, be_write, be_ready, be_rvalid;
    wire [24:0]  te_addr, be_addr;
    wire [575:0] te_wdata, te_rdata, be_wdata, be_rdata;
    wire [71:0]  te_be, be_be;
    wire [6:0]   te_burst, be_burst;

    reg          mb_go = 0, mb_wr = 0;
    reg [24:0]   mb_addr = 0;
    reg [575:0]  mb_wdata = 0;
    wire         mb_done_t, mb_err_t, mb_done_b, mb_err_b, q_t, q_b;
    wire [575:0] mbres_t, mbres_b;

    reg          fault_en = 0;
    reg [24:0]   fault_addr = 0;
    reg [9:0]    fault_bit = 0;

    ddr_test_csr #(.MODE(MODE), .ID(MODE ? 16'h0102 : 16'h0101)) dut (
        .clk_100 (clk_100), .rst_100 (persona_rst),
        .csr_addr (csr_addr), .csr_read (csr_read), .csr_write (csr_write),
        .csr_wdata (csr_wdata), .csr_rdata (csr_rdata),
        .persona_id (pid), .led (led),
        .t_clk (t_clk), .t_rst (tp_rst), .t_addr (tp_addr), .t_read (tp_read), .t_write (tp_write),
        .t_wdata (tp_wdata), .t_be (tp_be), .t_ready (tp_ready), .t_rdata (tp_rdata), .t_rvalid (tp_rvalid),
        .b_clk (b_clk), .b_rst (bp_rst), .b_addr (bp_addr), .b_read (bp_read), .b_write (bp_write),
        .b_wdata (bp_wdata), .b_be (bp_be), .b_ready (bp_ready), .b_rdata (bp_rdata), .b_rvalid (bp_rvalid)
    );

    ddr_port u_pt (
        .clk (t_clk), .usr_rst_n (t_urst_n), .gate_a (quiesce), .prst_a (persona_rst),
        .p_rst (tp_rst), .p_addr (tp_addr), .p_read (tp_read), .p_write (tp_write),
        .p_wdata (tp_wdata), .p_be (tp_be), .p_ready (tp_ready), .p_rdata (tp_rdata), .p_rvalid (tp_rvalid),
        .mb_go_tg_a (mb_go), .mb_wr_a (mb_wr), .mb_addr_a (mb_addr), .mb_wdata_a (mb_wdata),
        .mb_done_tg (mb_done_t), .mb_err (mb_err_t), .mbres_rdata (mbres_t), .quiesced (q_t),
        .e_read (te_read), .e_write (te_write), .e_addr (te_addr), .e_wdata (te_wdata), .e_be (te_be),
        .e_burst (te_burst), .e_ready (te_ready), .e_rdata (te_rdata), .e_rvalid (te_rvalid)
    );
    ddr_port u_pb (
        .clk (b_clk), .usr_rst_n (b_urst_n), .gate_a (quiesce), .prst_a (persona_rst),
        .p_rst (bp_rst), .p_addr (bp_addr), .p_read (bp_read), .p_write (bp_write),
        .p_wdata (bp_wdata), .p_be (bp_be), .p_ready (bp_ready), .p_rdata (bp_rdata), .p_rvalid (bp_rvalid),
        .mb_go_tg_a (1'b0), .mb_wr_a (1'b0), .mb_addr_a (25'd0), .mb_wdata_a (576'd0),
        .mb_done_tg (mb_done_b), .mb_err (mb_err_b), .mbres_rdata (mbres_b), .quiesced (q_b),
        .e_read (be_read), .e_write (be_write), .e_addr (be_addr), .e_wdata (be_wdata), .e_be (be_be),
        .e_burst (be_burst), .e_ready (be_ready), .e_rdata (be_rdata), .e_rvalid (be_rvalid)
    );

    mem_model #(.SEED(7)) m_t (.clk (t_clk), .read (te_read), .write (te_write), .addr (te_addr),
        .wdata (te_wdata), .be (te_be), .ready (te_ready), .rdata (te_rdata), .rvalid (te_rvalid),
        .fault_en (fault_en), .fault_addr (fault_addr), .fault_bit (fault_bit));
    mem_model #(.SEED(11)) m_b (.clk (b_clk), .read (be_read), .write (be_write), .addr (be_addr),
        .wdata (be_wdata), .be (be_be), .ready (be_ready), .rdata (be_rdata), .rvalid (be_rvalid),
        .fault_en (1'b0), .fault_addr (25'd0), .fault_bit (10'd0));

    int fails = 0;

    task automatic csr_wr(input [11:0] byte_off, input [31:0] v);
        @(posedge clk_100);
        csr_addr <= byte_off[11:2]; csr_wdata <= v; csr_write <= 1;
        @(posedge clk_100);
        csr_write <= 0;
    endtask

    task automatic csr_rd(input [11:0] byte_off, output [31:0] v);
        @(posedge clk_100);
        csr_addr <= byte_off[11:2]; csr_read <= 1;
        @(posedge clk_100);
        csr_read <= 0;
        @(negedge clk_100);
        v = csr_rdata;
    endtask

    task automatic check(input string what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %s: got 0x%08X expected 0x%08X", what, got, exp);
            fails++;
        end else
            $display("ok   %s = 0x%08X", what, got);
    endtask

    // Run one test; ctrl_phases = CTRL[11:8], mask = CTRL[5:4]
    task automatic run(input [3:0] phases, input [1:0] mask, input [24:0] s, input [24:0] e, input [31:0] seed);
        reg [31:0] st;
        csr_wr(12'h008, s);
        csr_wr(12'h00C, e);
        csr_wr(12'h010, seed);
        csr_wr(12'h004, {20'd0, phases, 2'b00, mask, 3'b000, 1'b1});
        do begin
            repeat (50) @(posedge clk_100);
            csr_rd(12'h014, st);
        end while ((st[0] && mask[0]) || (st[8] && mask[1]));
    endtask

    reg [31:0] v;
    initial begin
        repeat (20) @(posedge clk_100);
        t_urst_n = 1; b_urst_n = 1;
        repeat (20) @(posedge clk_100);
        persona_rst = 0;
        repeat (20) @(posedge clk_100);

        csr_rd(12'h000, v); check("ID", v, {16'h0001, MODE ? 16'h0102 : 16'h0101});

        // 1: write + read (+ address test for MODE 0), both channels, 1024 words
        run(MODE ? 4'b0011 : 4'b1011, 2'b11, 25'd0, 25'd1023, 32'd5);
        csr_rd(12'h400, v); check("top err words", v, 0);
        csr_rd(12'h404, v); check("top words written", v, MODE ? 1024 : 1024 + 26);
        csr_rd(12'h408, v); check("top words read", v, MODE ? 1024 : 1024 + 26);
        csr_rd(12'h800, v); check("bot err words", v, 0);
        csr_rd(12'h804, v); check("bot words written", v, MODE ? 1024 : 1024 + 26);
        csr_rd(12'h41C, v); check("top runs", v, 1);

        // 2: verify only (no write) with the same seed -> still clean
        run(4'b0010, 2'b01, 25'd0, 25'd1023, 32'd5);
        csr_rd(12'h400, v); check("verify-only err words", v, 0);
        csr_rd(12'h404, v); check("verify-only words written", v, 0);

        // 3: verify with another seed -> every word differs
        run(4'b0010, 2'b01, 25'd0, 25'd1023, 32'd77);
        csr_rd(12'h400, v);
        if (v < 1000) begin $display("FAIL wrong-seed verify found only %0d errors", v); fails++; end
        else $display("ok   wrong-seed verify: %0d error words", v);

        // 4: fault injection on read of word 300, bit 77 (lane 5 of beat 1)
        fault_addr = 25'd300; fault_bit = 10'd77; fault_en = 1;
        run(4'b0011, 2'b01, 25'd0, 25'd1023, 32'd9);
        fault_en = 0;
        csr_rd(12'h400, v); check("fault err words", v, 1);
        csr_rd(12'h414, v); check("fault first addr", v, 300);
        csr_rd(12'h418, v); check("fault flags", v, 1);
        csr_rd(12'h420, v); check("fault lane mask [31:0]", v, 32'h00000020);
        begin
            reg [31:0] e2, a2;
            csr_rd(12'h508, e2);   // expected word 2 = bits [95:64]
            csr_rd(12'h608, a2);
            check("fault exp^act word 2", e2 ^ a2, 32'h00002000);
        end

        // 5: quiesce + mailbox write/read on top
        quiesce = 1;
        repeat (40) @(posedge t_clk);
        if (!q_t) begin $display("FAIL top not quiesced"); fails++; end else $display("ok   top quiesced");
        mb_wr = 1; mb_addr = 25'd12345; mb_wdata = {18{32'hCAFE0001}};
        repeat (4) @(posedge clk_100); mb_go = ~mb_go;
        wait (mb_done_t == mb_go); repeat (4) @(posedge clk_100);
        check("mailbox write refused", mb_err_t, 0);
        mb_wr = 0; repeat (4) @(posedge clk_100); mb_go = ~mb_go;
        wait (mb_done_t == mb_go); repeat (4) @(posedge clk_100);
        check("mailbox read word 0", mbres_t[31:0], 32'hCAFE0001);
        check("mailbox read word 17", mbres_t[575:544], 32'hCAFE0001);

        // 6: a run started while quiesced must not progress; release -> completes
        csr_wr(12'h008, 0); csr_wr(12'h00C, 255); csr_wr(12'h010, 3);
        csr_wr(12'h004, {20'd0, 4'b0011, 2'b00, 2'b01, 3'b000, 1'b1});
        repeat (2000) @(posedge clk_100);
        csr_rd(12'h404, v); check("words written while quiesced", v, 0);
        quiesce = 0;
        do begin repeat (50) @(posedge clk_100); csr_rd(12'h014, v); end while (v[0]);
        csr_rd(12'h400, v); check("after release err words", v, 0);
        csr_rd(12'h408, v); check("after release words read", v, 256);

        // 7: abort in the middle of a long run
        csr_wr(12'h008, 0); csr_wr(12'h00C, 25'h1FFFFFF);
        csr_wr(12'h004, {20'd0, 4'b0011, 2'b00, 2'b01, 3'b000, 1'b1});
        repeat (3000) @(posedge clk_100);
        csr_wr(12'h004, {20'd0, 4'b0011, 2'b00, 2'b01, 3'b000, 2'b10});
        do begin repeat (50) @(posedge clk_100); csr_rd(12'h014, v); end while (v[0]);
        csr_rd(12'h418, v); check("abort flags (aborted)", v & 32'h2, 2);
        csr_wr(12'h004, 0);

        // 8: persona reset in the middle of a run (as a PR freeze would do)
        csr_wr(12'h008, 0); csr_wr(12'h00C, 25'h1FFFFFF);
        csr_wr(12'h004, {20'd0, 4'b0011, 2'b00, 2'b01, 3'b000, 1'b1});
        repeat (1000) @(posedge clk_100);
        quiesce = 1;
        repeat (200) @(posedge t_clk);
        if (!q_t) begin $display("FAIL top not quiesced before reset"); fails++; end
        persona_rst = 1;
        repeat (600) @(posedge clk_100);
        persona_rst = 0; quiesce = 0;
        repeat (100) @(posedge clk_100);
        run(MODE ? 4'b0011 : 4'b1011, 2'b01, 25'd0, 25'd511, 32'd21);
        csr_rd(12'h400, v); check("after persona reset err words", v, 0);

        $display("==== %s: %0d failure(s), MODE %0d", fails ? "FAILED" : "PASSED", fails, MODE);
        $finish;
    end

    initial begin
        #20ms;
        $display("==== TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
