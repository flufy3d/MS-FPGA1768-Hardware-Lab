// --------------------------------------------------------------------------
// tb_i2c — bar0_regs + i2c_master against behavioural I2C targets
//
// Bus 1: target 0x22 (paged, like the DS250DF810 retimer)
// Bus 2: target 0x4C (TMP411-like) and 0x42 (LM25066-like, stretches SCL 3 us)
//
// The host side is driven through the same Avalon-MM slave the PCIe bridge
// uses, with the register offsets from the README / host profile.
// SCL_DIV = 25 in simulation (1 MHz SCL) to keep the run short; one test
// uses the 100 kHz reset value.
// --------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_i2c;
    // ---- clock / reset ----
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;          // 100 MHz

    // ---- buses with pull-ups ----
    tri1 scl1, sda1, scl2, sda2;
    reg  hold_scl1 = 1'b0;         // simulate a target that never releases SCL
    assign scl1 = hold_scl1 ? 1'b0 : 1'bz;

    // ---- DUT ----
    reg  [7:0]  av_addr = 0;
    reg         av_read = 0, av_write = 0;
    reg  [31:0] av_wdata = 0;
    wire [31:0] av_rdata;
    wire        av_rvalid;

    wire        i2c_start, i2c_abort, i2c_bus, i2c_rw, i2c_no_reg, i2c_page_en;
    wire [6:0]  i2c_addr;
    wire [7:0]  i2c_reg, i2c_page;
    wire [5:0]  i2c_len;
    wire [15:0] i2c_div;
    wire [223:0] i2c_wbuf;
    wire        rbuf_we;
    wire [4:0]  rbuf_idx;
    wire [7:0]  rbuf_data, i2c_bytes;
    wire        busy, done, ack_error, timeout, aborted;
    wire        scl1_oe, sda1_oe, scl2_oe, sda2_oe;
    wire [31:0] pr_a, pr_b;           // persona operands (stand-in: SUM = A + B)

    reg [1:0] s_scl1, s_sda1, s_scl2, s_sda2;
    always @(posedge clk) begin
        s_scl1 <= {s_scl1[0], scl1 !== 1'b0};
        s_sda1 <= {s_sda1[0], sda1 !== 1'b0};
        s_scl2 <= {s_scl2[0], scl2 !== 1'b0};
        s_sda2 <= {s_sda2[0], sda2 !== 1'b0};
    end
    assign scl1 = scl1_oe ? 1'b0 : 1'bz;
    assign sda1 = sda1_oe ? 1'b0 : 1'bz;
    assign scl2 = scl2_oe ? 1'b0 : 1'bz;
    assign sda2 = sda2_oe ? 1'b0 : 1'bz;

    bar0_regs u_regs (
        .clk(clk), .rst(rst),
        .address(av_addr), .read(av_read), .write(av_write),
        .writedata(av_wdata), .readdata(av_rdata), .readdatavalid(av_rvalid),
        .counter(32'h12345678), .temp(32'h0000_0200),
        .persona(32'h0004_0001), .pr_a(pr_a), .pr_b(pr_b), .pr_sum(pr_a + pr_b),
        .i2c_start(i2c_start), .i2c_abort(i2c_abort), .i2c_bus(i2c_bus),
        .i2c_rw(i2c_rw), .i2c_no_reg(i2c_no_reg), .i2c_addr(i2c_addr),
        .i2c_reg(i2c_reg), .i2c_page_en(i2c_page_en), .i2c_page(i2c_page),
        .i2c_len(i2c_len), .i2c_div(i2c_div), .i2c_wbuf(i2c_wbuf),
        .i2c_rbuf_we(rbuf_we), .i2c_rbuf_idx(rbuf_idx), .i2c_rbuf_data(rbuf_data),
        .i2c_busy(busy), .i2c_done(done), .i2c_ack_error(ack_error),
        .i2c_timeout(timeout), .i2c_aborted(aborted), .i2c_bytes(i2c_bytes),
        .i2c_lines({s_sda2[1], s_scl2[1], s_sda1[1], s_scl1[1]})
    );

    i2c_master #(.TIMEOUT_CYCLES(20_000)) u_i2c (
        .clk(clk), .rst(rst),
        .start(i2c_start), .abort(i2c_abort), .bus(i2c_bus), .rw(i2c_rw),
        .no_reg(i2c_no_reg), .addr(i2c_addr), .reg_byte(i2c_reg),
        .page_en(i2c_page_en), .page(i2c_page), .len(i2c_len), .div(i2c_div),
        .wbuf(i2c_wbuf), .rbuf_we(rbuf_we), .rbuf_idx(rbuf_idx), .rbuf_data(rbuf_data),
        .busy(busy), .done(done), .ack_error(ack_error), .timeout(timeout),
        .aborted(aborted), .bytes(i2c_bytes),
        .scl1_in(s_scl1[1]), .sda1_in(s_sda1[1]),
        .scl2_in(s_scl2[1]), .sda2_in(s_sda2[1]),
        .scl1_oe(scl1_oe), .sda1_oe(sda1_oe),
        .scl2_oe(scl2_oe), .sda2_oe(sda2_oe)
    );

    // ---- targets ----
    i2c_slave_model #(.ADDR(7'h22))                    t_retimer (.scl(scl1), .sda(sda1));
    i2c_slave_model #(.ADDR(7'h4C))                    t_tmp411  (.scl(scl2), .sda(sda2));
    i2c_slave_model #(.ADDR(7'h42), .STRETCH_NS(3000)) t_lm25066 (.scl(scl2), .sda(sda2));

    // ---- bus isolation monitor: a bus must never be pulled while the
    //      other one is selected ----
    int iso_errors = 0;
    bit saw_clear = 0;
    always @(posedge clk) if (u_i2c.st == u_i2c.S_CLEAR) saw_clear = 1;
    always @(posedge clk) if (!rst && busy) begin
        if (u_i2c.bus_q == 1'b1 && (scl1_oe || sda1_oe)) iso_errors++;
        if (u_i2c.bus_q == 1'b0 && (scl2_oe || sda2_oe)) iso_errors++;
    end

    // ---- register offsets ----
    localparam [7:0] R_SHELL_ID = 8'h00, R_CAPS = 8'h04, R_CAPS2 = 8'h08,
                     R_COUNTER = 8'h30, R_ID = 8'h40, R_TEMP = 8'h50,
                     R_CTRL = 8'h60, R_ADDR = 8'h64, R_PAGE = 8'h68,
                     R_REG = 8'h6C, R_LEN = 8'h70, R_DATA = 8'h74,
                     R_STATUS = 8'h90, R_DIV = 8'h94;
    localparam [31:0] C_START = 32'h1, C_BUS2 = 32'h2, C_READ = 32'h4,
                      C_ABORT = 32'h8, C_NOREG = 32'h10;

    int failures = 0;

    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %s: got 0x%08h expected 0x%08h", what, got, exp);
            failures++;
        end else
            $display("ok   %s = 0x%08h", what, got);
    endtask

    task automatic wr(input [7:0] a, input [31:0] d);
        @(posedge clk);
        av_addr <= a; av_wdata <= d; av_write <= 1'b1;
        @(posedge clk);
        av_write <= 1'b0;
    endtask

    task automatic rd(input [7:0] a, output [31:0] d);
        @(posedge clk);
        av_addr <= a; av_read <= 1'b1;
        @(posedge clk);
        av_read <= 1'b0;
        while (!av_rvalid) @(posedge clk);
        d = av_rdata;
    endtask

    // Start a transaction and wait for done (or give up after max_us).
    task automatic run(input [31:0] ctrl, output [31:0] status, input int max_us = 2000);
        int t;
        wr(R_CTRL, ctrl | C_START);
        t = 0;
        do begin
            #1000; t++;
            rd(R_STATUS, status);
        end while (!status[2] && t < max_us);
    endtask

    task automatic setup(input [6:0] a, input [7:0] r, input [5:0] n, input [8:0] pg = 0);
        wr(R_ADDR, a); wr(R_REG, r); wr(R_LEN, n); wr(R_PAGE, pg);
    endtask

    // ---- tests ----
    initial begin
        logic [31:0] v, s;
        int n0;
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (10) @(posedge clk);

        // Identity and fixed registers
        rd(R_SHELL_ID, v); check("SHELL_ID", v, 32'h49323036);
        rd(R_CAPS, v);     check("CAPS (I2C | PR)", v, 32'h00000006);
        rd(R_CAPS2, v);    check("CAPS2", v, 32'h00000000);
        rd(R_ID, v);       check("ID", v, 32'h50434945);
        rd(R_COUNTER, v);  check("COUNTER", v, 32'h12345678);
        rd(R_DIV, v);      check("SCL_DIV reset (100 kHz)", v, 32'd250);
        rd(R_STATUS, v);   check("STATUS idle, lines high", v, 32'h000F0000);

        // Persona ABI (the persona itself is a stand-in here: SUM = A + B)
        wr(8'hA4, 32'h12345678); wr(8'hA8, 32'h11111111);
        rd(8'hA0, v);  check("PERSONA word", v, 32'h00040001);
        rd(8'hA4, v);  check("A readback", v, 32'h12345678);
        rd(8'hA8, v);  check("B readback", v, 32'h11111111);
        rd(8'hAC, v);  check("SUM", v, 32'h23456789);

        // 1. 100 kHz: TMP411-like read, bus 2, reg 0x00, 1 byte
        setup(7'h4C, 8'h00, 6'd1);
        run(C_BUS2 | C_READ, s, 4000);
        check("T1 status (done, 1 byte)", s & 32'hFFFF, 32'h0104);
        rd(R_DATA, v);  check("T1 TMP411 reg 0x00", v & 32'hFF, 32'h03);

        wr(R_DIV, 32'd25);  // 1 MHz for the rest

        // 2. Command byte + Sr + 2-byte read with clock stretching (LM25066-like)
        setup(7'h42, 8'h88, 6'd2);
        run(C_BUS2 | C_READ, s);
        check("T2 status (done, 2 bytes)", s & 32'hFFFF, 32'h0204);
        rd(R_DATA, v);  check("T2 READ_VIN bytes", v & 32'hFFFF,
                              {8'(8'h89 * 7 + 3), 8'(8'h88 * 7 + 3)});

        // 3. NACK: no device at 0x33
        setup(7'h33, 8'h00, 6'd1);
        run(C_BUS2 | C_READ, s);
        check("T3 NACK status (done + ack_error, 0 bytes)", s & 32'hFFFF, 32'h0006);
        rd(R_STATUS, v); check("T3 lines released", v[19:16], 4'hF);

        // 4. Scan-style probe: S addr+R byte P, writes nothing
        n0 = t_tmp411.n_ptr_writes + t_tmp411.n_data_writes;
        setup(7'h4C, 8'h00, 6'd1);
        run(C_BUS2 | C_READ | C_NOREG, s);
        check("T4 probe 0x4C ack", s & 32'hFFFF, 32'h0104);
        check("T4 probe wrote nothing", t_tmp411.n_ptr_writes + t_tmp411.n_data_writes, n0);
        setup(7'h4D, 8'h00, 6'd1);
        run(C_BUS2 | C_READ | C_NOREG, s);
        check("T4 probe 0x4D nack", s & 32'hFFFF, 32'h0006);

        // 5. Paged read on bus 1: write 0xFF = 5, then reg 0x01, 2 bytes
        setup(7'h22, 8'h01, 6'd2, {1'b1, 8'h05});
        run(C_READ, s);
        check("T5 paged status", s & 32'hFFFF, 32'h0204);
        check("T5 page register", t_retimer.page, 8'h05);
        rd(R_DATA, v);  check("T5 paged data", v & 32'hFFFF,
                              {8'(8'h02 * 7 + 3 + 5), 8'(8'h01 * 7 + 3 + 5)});

        // 6. Reads never write data bytes (pointer and page only)
        check("T6 TMP411 data writes", t_tmp411.n_data_writes, 0);
        check("T6 LM25066 data writes", t_lm25066.n_data_writes, 0);
        check("T6 retimer data writes", t_retimer.n_data_writes, 0);

        // 7. 28-byte read (maximum)
        setup(7'h4C, 8'h10, 6'd28);
        run(C_BUS2 | C_READ, s);
        check("T7 status (28 bytes)", s & 32'hFFFF, 32'h1C04);
        rd(R_DATA + 8'd24, v);
        check("T7 last word", v, {8'(8'h2B*7+3), 8'(8'h2A*7+3), 8'(8'h29*7+3), 8'(8'h28*7+3)});

        // 8. Write path (simulation target only; hardware tests do not write)
        wr(R_DATA, 32'h00C0FFEE);
        setup(7'h22, 8'h10, 6'd3);
        run(32'h0, s);
        check("T8 write status", s & 32'hFFFF, 32'h0304);
        check("T8 written bytes", {t_retimer.mem[8'h12], t_retimer.mem[8'h11], t_retimer.mem[8'h10]},
              24'hC0FFEE);

        // 9. Timeout: SCL 1 held low by a target
        hold_scl1 = 1'b1;
        setup(7'h22, 8'h00, 6'd1);
        run(C_READ, s);
        check("T9 timeout status (done + timeout)", s & 32'hFFFF, 32'h000C);
        check("T9 master released lines", {scl1_oe, sda1_oe}, 2'b00);
        hold_scl1 = 1'b0;
        #20000;

        // 10. Abort in the middle of a long read
        setup(7'h4C, 8'h00, 6'd28);
        wr(R_CTRL, C_BUS2 | C_READ | C_START);
        #50000;
        // abort while the target is driving a 0 data bit (worst case:
        // SDA stays low after the master releases it -> bus clear)
        wait (t_tmp411.sda_drv && u_i2c.st == u_i2c.S_RDATA);
        wr(R_CTRL, C_ABORT);
        do rd(R_STATUS, s); while (s[0]);
        check("T10 abort status (done + aborted)", s & 32'h1F, 32'h14);
        check("T10 lines released", {scl2_oe, sda2_oe}, 2'b00);
        check("T10 bus 2 idle high", s[19:18], 2'b11);
        check("T10 bus clear used", saw_clear, 1);

        // A clean transaction works after abort (bus clear + STOP) and timeout
        setup(7'h42, 8'h00, 6'd1);
        run(C_BUS2 | C_READ, s);
        check("T11 recovery read status", s & 32'hFFFF, 32'h0104);

        check("bus isolation violations", iso_errors, 0);

        if (failures == 0) $display("==== PASSED: 0 failure(s)");
        else               $display("==== FAILED: %0d failure(s)", failures);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("==== FAILED: global timeout");
        $finish;
    end
endmodule
