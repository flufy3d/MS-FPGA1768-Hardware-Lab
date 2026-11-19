`default_nettype none

// --------------------------------------------------------------------------
// i2c_master — single-master I2C engine for two open-drain buses
//
// One state machine serves both buses; `bus` (latched at start) selects which
// pair of pins is driven. The other bus is always released. Lines are only
// ever pulled low (oe = 1) or released (oe = 0); the pads in the top level
// implement `pin = oe ? 1'b0 : 1'bz`.
//
// Transaction, started by a one-cycle `start` pulse while idle:
//
//   if page_en:  S addr+W 0xFF page P                    (page select write)
//   rw = 0:      S addr+W [reg] data[0..len-1] P
//   rw = 1:      S addr+W reg Sr addr+R data[0..len-1] P
//   rw = 1, no_reg = 1:  S addr+R data[0..len-1] P
//
//   no_reg = 1 skips the command byte. With rw = 1 and len = 1 this is a
//   one-byte read probe (used by `fpga1768 i2c scan`, so a scan never writes
//   a byte to any device). With rw = 0 and len = 0 it is a "quick write".
//   A read transfers at least one byte (len 0 is treated as 1) and at most
//   28; the last byte read is NACKed, the others ACKed.
//
// Any NACK on an address or on a written byte sets ack_error and ends the
// transaction with a STOP.
//
// Timing: every bit (and START / STOP) is four quarter periods of `div` clk
// cycles; div is clamped to >= 25 (SCL <= 1 MHz at 100 MHz). 100 kHz needs
// div = 250. In quarter 1 SCL is released and the engine waits until the line
// reads high (clock stretching). If it stays low for TIMEOUT_CYCLES the
// transaction ends with `timeout` set and both lines released.
//
//   quarter   START          STOP          data / ack bit
//   0         release SDA    pull SDA      SCL low, set SDA
//   1         release SCL    release SCL   release SCL (wait high)
//   2         pull SDA       release SDA   sample SDA
//   3         pull SCL       -             pull SCL
//
// `abort` stops the current op, releases SDA and sets `aborted`. If SDA is
// still held low by a target (it was sending a read byte), the engine clocks
// one byte with SDA released and NACKs it (bus clear), then sends STOP.
// Otherwise it sends STOP directly. busy stays set until that STOP is done.
// --------------------------------------------------------------------------
module i2c_master #(
    parameter int TIMEOUT_CYCLES = 1_000_000   // 10 ms at 100 MHz
) (
    input  wire         clk,
    input  wire         rst,

    // Control (from the register block)
    input  wire         start,         // one-cycle pulse
    input  wire         abort,         // one-cycle pulse
    input  wire         bus,           // 0 = bus 1, 1 = bus 2
    input  wire         rw,            // 0 = write, 1 = read
    input  wire         no_reg,        // skip the command byte
    input  wire [6:0]   addr,
    input  wire [7:0]   reg_byte,
    input  wire         page_en,
    input  wire [7:0]   page,
    input  wire [5:0]   len,           // bytes, clamped to 28
    input  wire [15:0]  div,           // quarter SCL period in clk cycles

    // Data buffer (owned by the register block)
    input  wire [223:0] wbuf,          // 28 bytes, byte i = wbuf[8*i +: 8]
    output reg          rbuf_we,       // store rbuf_data at rbuf_idx
    output reg  [4:0]   rbuf_idx,
    output reg  [7:0]   rbuf_data,

    // Status
    output reg          busy,
    output reg          done,          // sticky until next start
    output reg          ack_error,
    output reg          timeout,
    output reg          aborted,
    output reg  [7:0]   bytes,         // data bytes transferred

    // Pads (synchronised inputs, open-drain enables)
    input  wire         scl1_in, sda1_in,
    input  wire         scl2_in, sda2_in,
    output wire         scl1_oe, sda1_oe,
    output wire         scl2_oe, sda2_oe
);

    localparam [5:0] MAX_LEN = 6'd28;

    // ---------------------------------------------------------------------
    // Pad mux
    // ---------------------------------------------------------------------
    reg  scl_oe = 1'b0, sda_oe = 1'b0;
    reg  bus_q  = 1'b0;
    wire scl_in = bus_q ? scl2_in : scl1_in;
    wire sda_in = bus_q ? sda2_in : sda1_in;

    assign scl1_oe = !bus_q && scl_oe;
    assign sda1_oe = !bus_q && sda_oe;
    assign scl2_oe =  bus_q && scl_oe;
    assign sda2_oe =  bus_q && sda_oe;

    // ---------------------------------------------------------------------
    // Byte engine state
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] { OP_START, OP_STOP, OP_WBYTE, OP_RBYTE } op_t;

    op_t        op       = OP_START;
    reg         op_run   = 1'b0;
    reg         op_done  = 1'b0;       // one-cycle pulse
    reg  [1:0]  phase    = 2'd0;
    reg  [15:0] qcnt     = 16'd0;      // 0 = phase entry
    reg  [20:0] tcnt     = 21'd0;      // stretch timeout
    reg  [3:0]  bitn     = 4'd0;       // 0..7 data, 8 = ack slot
    reg  [7:0]  sh       = 8'd0;
    reg         rd_nack  = 1'b0;       // OP_RBYTE: NACK this byte
    reg         got_ack  = 1'b0;       // OP_WBYTE: slave ACKed

    wire [15:0] div_c = (div < 16'd25) ? 16'd25 : div;

    // ---------------------------------------------------------------------
    // Sequencer state
    // ---------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE, S_PG_START, S_PG_ADDR, S_PG_FF, S_PG_VAL, S_PG_STOP,
        S_START, S_ADDR_W, S_REG, S_WDATA, S_RSTART, S_ADDR_R, S_RDATA,
        S_STOP, S_FINISH, S_ABORT, S_CLEAR
    } st_t;

    st_t       st        = S_IDLE;
    reg        rw_q      = 1'b0;
    reg        no_reg_q  = 1'b0;
    reg [6:0]  addr_q    = 7'd0;
    reg [7:0]  reg_q     = 8'd0;
    reg [7:0]  page_q    = 8'd0;
    reg [5:0]  len_q     = 6'd0;
    reg [5:0]  idx       = 6'd0;       // current data byte
    reg        nack_seen = 1'b0;

    function automatic [7:0] wbyte(input [5:0] i);
        wbyte = wbuf[8*i[4:0] +: 8];
    endfunction

    // Hand an op to the byte engine.
    task automatic issue(input op_t o, input [7:0] b, input nack);
        op      <= o;
        sh      <= b;
        rd_nack <= nack;
        bitn    <= 4'd0;
        phase   <= 2'd0;
        qcnt    <= 16'd0;
        tcnt    <= 21'd0;
        op_run  <= 1'b1;
    endtask

    // NACK on an address or written byte: send STOP, then report.
    task automatic fail_stop();
        nack_seen <= 1'b1;
        issue(OP_STOP, 8'h00, 1'b0);
        st <= S_STOP;
    endtask

    always_ff @(posedge clk) begin
        op_done <= 1'b0;
        rbuf_we <= 1'b0;

        if (rst) begin
            st <= S_IDLE; op_run <= 1'b0;
            busy <= 1'b0; done <= 1'b0; ack_error <= 1'b0;
            timeout <= 1'b0; aborted <= 1'b0; bytes <= 8'd0;
            scl_oe <= 1'b0; sda_oe <= 1'b0;
        end else if (abort && busy && !aborted) begin
            // Stop the op, release SDA, keep SCL as it is; S_ABORT decides
            // between STOP and bus clear once the release is visible.
            st <= S_ABORT; op_run <= 1'b0;
            aborted <= 1'b1; sda_oe <= 1'b0;
            qcnt <= 16'd0;
        end else begin
            // =============================================================
            // Byte engine
            // =============================================================
            if (op_run) begin
                if (qcnt == 16'd0) begin
                    // ---- phase entry actions ----
                    qcnt <= 16'd1;
                    case (op)
                    OP_START: case (phase)
                        2'd0: sda_oe <= 1'b0;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: sda_oe <= 1'b1;
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    OP_STOP: case (phase)
                        2'd0: sda_oe <= 1'b1;
                        2'd1: scl_oe <= 1'b0;
                        2'd2: sda_oe <= 1'b0;
                        2'd3: ;
                    endcase
                    default: case (phase)
                        2'd0: begin
                            scl_oe <= 1'b1;
                            if (bitn == 4'd8)
                                sda_oe <= (op == OP_RBYTE) ? !rd_nack : 1'b0;
                            else
                                sda_oe <= (op == OP_WBYTE) ? !sh[7] : 1'b0;
                        end
                        2'd1: scl_oe <= 1'b0;
                        2'd2: begin
                            if (bitn == 4'd8)
                                got_ack <= !sda_in;
                            else
                                sh <= {sh[6:0], sda_in};   // write: shifts the sent bit out
                        end
                        2'd3: scl_oe <= 1'b1;
                    endcase
                    endcase
                end else if (phase == 2'd1 && !scl_in) begin
                    // ---- SCL released but still low: clock stretching ----
                    if (tcnt == TIMEOUT_CYCLES[20:0]) begin
                        op_run  <= 1'b0;
                        scl_oe  <= 1'b0;
                        sda_oe  <= 1'b0;
                        timeout <= 1'b1;
                        st      <= S_FINISH;
                    end else
                        tcnt <= tcnt + 21'd1;
                end else if (qcnt != div_c) begin
                    qcnt <= qcnt + 16'd1;
                end else begin
                    // ---- end of quarter ----
                    qcnt <= 16'd0;
                    tcnt <= 21'd0;
                    if (phase != 2'd3)
                        phase <= phase + 2'd1;
                    else if ((op == OP_WBYTE || op == OP_RBYTE) && bitn != 4'd8) begin
                        phase <= 2'd0;
                        bitn  <= bitn + 4'd1;
                    end else begin
                        op_run  <= 1'b0;
                        op_done <= 1'b1;
                    end
                end
            end

            // =============================================================
            // Sequencer
            // =============================================================
            case (st)
            S_IDLE: if (start) begin
                busy <= 1'b1; done <= 1'b0; ack_error <= 1'b0;
                timeout <= 1'b0; aborted <= 1'b0; bytes <= 8'd0;
                bus_q <= bus; rw_q <= rw; no_reg_q <= no_reg;
                addr_q <= addr; reg_q <= reg_byte; page_q <= page;
                if (len > MAX_LEN)          len_q <= MAX_LEN;
                else if (rw && len == 6'd0) len_q <= 6'd1;
                else                        len_q <= len;
                nack_seen <= 1'b0;
                idx <= 6'd0;
                st <= page_en ? S_PG_START : S_START;
                issue(OP_START, 8'h00, 1'b0);
            end

            // ---- page select: S addr+W 0xFF page P ------------------------
            S_PG_START: if (op_done) begin
                issue(OP_WBYTE, {addr_q, 1'b0}, 1'b0); st <= S_PG_ADDR;
            end
            S_PG_ADDR: if (op_done) begin
                if (!got_ack) fail_stop();
                else begin issue(OP_WBYTE, 8'hFF, 1'b0); st <= S_PG_FF; end
            end
            S_PG_FF: if (op_done) begin
                if (!got_ack) fail_stop();
                else begin issue(OP_WBYTE, page_q, 1'b0); st <= S_PG_VAL; end
            end
            S_PG_VAL: if (op_done) begin
                if (!got_ack) fail_stop();
                else begin issue(OP_STOP, 8'h00, 1'b0); st <= S_PG_STOP; end
            end
            S_PG_STOP: if (op_done) begin
                issue(OP_START, 8'h00, 1'b0); st <= S_START;
            end

            // ---- main transaction ----------------------------------------
            S_START: if (op_done) begin
                if (no_reg_q && rw_q) begin
                    issue(OP_WBYTE, {addr_q, 1'b1}, 1'b0); st <= S_ADDR_R;
                end else begin
                    issue(OP_WBYTE, {addr_q, 1'b0}, 1'b0); st <= S_ADDR_W;
                end
            end
            S_ADDR_W: if (op_done) begin
                if (!got_ack)            fail_stop();
                else if (!no_reg_q)      begin issue(OP_WBYTE, reg_q, 1'b0); st <= S_REG; end
                else if (len_q != 6'd0)  begin issue(OP_WBYTE, wbyte(6'd0), 1'b0); st <= S_WDATA; end
                else                     begin issue(OP_STOP, 8'h00, 1'b0); st <= S_STOP; end
            end
            S_REG: if (op_done) begin
                if (!got_ack)            fail_stop();
                else if (rw_q)           begin issue(OP_START, 8'h00, 1'b0); st <= S_RSTART; end
                else if (len_q != 6'd0)  begin issue(OP_WBYTE, wbyte(6'd0), 1'b0); st <= S_WDATA; end
                else                     begin issue(OP_STOP, 8'h00, 1'b0); st <= S_STOP; end
            end
            S_WDATA: if (op_done) begin
                if (!got_ack) fail_stop();
                else begin
                    bytes <= bytes + 8'd1;
                    if (idx + 6'd1 == len_q) begin
                        issue(OP_STOP, 8'h00, 1'b0); st <= S_STOP;
                    end else begin
                        idx <= idx + 6'd1;
                        issue(OP_WBYTE, wbyte(idx + 6'd1), 1'b0);
                    end
                end
            end
            S_RSTART: if (op_done) begin
                issue(OP_WBYTE, {addr_q, 1'b1}, 1'b0); st <= S_ADDR_R;
            end
            S_ADDR_R: if (op_done) begin
                if (!got_ack) fail_stop();
                else begin issue(OP_RBYTE, 8'h00, len_q == 6'd1); st <= S_RDATA; end
            end
            S_RDATA: if (op_done) begin
                rbuf_we   <= 1'b1;
                rbuf_idx  <= idx[4:0];
                rbuf_data <= sh;
                bytes     <= bytes + 8'd1;
                if (idx + 6'd1 == len_q) begin
                    issue(OP_STOP, 8'h00, 1'b0); st <= S_STOP;
                end else begin
                    idx <= idx + 6'd1;
                    issue(OP_RBYTE, 8'h00, idx + 6'd2 == len_q);
                end
            end
            S_STOP: if (op_done) st <= S_FINISH;
            S_ABORT: begin
                // wait one quarter period for the synchronised SDA level
                if (qcnt != div_c) qcnt <= qcnt + 16'd1;
                else if (sda_in) begin issue(OP_STOP, 8'h00, 1'b0); st <= S_STOP; end
                else begin issue(OP_RBYTE, 8'h00, 1'b1); st <= S_CLEAR; end
            end
            S_CLEAR: if (op_done) begin
                issue(OP_STOP, 8'h00, 1'b0); st <= S_STOP;
            end
            S_FINISH: begin
                busy <= 1'b0; done <= 1'b1;
                if (nack_seen) ack_error <= 1'b1;
                scl_oe <= 1'b0; sda_oe <= 1'b0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
