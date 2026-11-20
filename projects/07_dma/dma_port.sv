`default_nettype none

// --------------------------------------------------------------------------
// dma_port — everything behind ONE PCIe hard IP in 07_dma
//
// This is the unit to copy for the second hard IP (PCIe #2): it owns the
// complete BAR0 of its endpoint (host contract, DMA registers, chunk table),
// both descriptor engines, the TXS status writer, the pattern generator and
// checker and its own loopback RAM. PORT_INDEX is readable at BAR0 + 0x0C.
// Everything runs on the hard IP core clock (coreclkout_hip, 250 MHz).
//
// FPGA (Avalon) address map seen by the DMA masters:
//   0x0_0000_0000 + [0, RAM)    loopback RAM (addresses alias modulo its size)
//   0x1_0000_0000 + any         pattern window: writes are checked, reads are
//                               generated (address bit 32 selects it)
//
// BAR0 register map (byte offsets; 32-bit registers; unmapped reads return 0)
//   0x000 SHELL_ID    RO  0x444D4137 ("DMA7")
//   0x004 CAPS        RO  0x00000010 (bit 4 DMA)
//   0x008 CAPS2       RO  0
//   0x00C PORT_INDEX  RO  hard IP this unit serves (0 = PCIe #1)
//   0x010 SCRATCH     RW
//   0x030 COUNTER     RO  core clock cycle counter [31:0]
//   0x040 ID          RO  0x50434945 (checked by the Windows test driver)
//   0x050 TEMP        RO  die temperature word (built in dma.sv)
//   0x060 VERSION     RO  0x00070001
//   0x064 CLK_HZ      RO  250000000
//   0x068 RAM_BYTES   RO
//   0x06C CHUNK_SHIFT RO  22 (4 MB chunks)
//   0x070 CHUNK_COUNT RO  64
//   0x074 TIME_LO     RO  core clock cycle counter [31:0]; a read latches TIME_HI
//   0x078 TIME_HI     RO  [63:32] latched by the TIME_LO read
//   0x080 CTRL        WO  [0] start H2D [1] start D2H (both in one write =
//                         simultaneous start) [4] abort both [8] clear checker
//   0x084 STATUS      RO  [0] H2D busy [1] D2H busy [2] H2D done [3] D2H done
//                         [4] H2D aborted [5] D2H aborted
//   0x088 PAT_SEED    RW  pattern seed
//   0x08C PAT_BASE_HI RO  1 (pattern window = 0x1_0000_0000)
//   0x100 H2D block, 0x180 D2H block (same layout, offsets within the block):
//     +0x00 FPGA_LO  +0x04 FPGA_HI   RW  Avalon start address
//     +0x08 LENGTH                   RW  bytes per pass, multiple of 32
//     +0x0C CHUNK0                   RW  [5:0] first chunk-table entry
//     +0x10 DESC_SHIFT               RW  log2 descriptor bytes, 8..19 (reset 19)
//     +0x14 LOOPS                    RW  [15:0] passes (reset 1)
//     +0x18 MAX_OUT                  RW  [7:0] descriptors in flight 1..64 (reset 64)
//     +0x1C SEQ                      RW  written to status record DW0
//     +0x20 STAT_LO  +0x24 STAT_HI   RW  host bus address of the 16-byte status
//                                        record (0 = none)
//     +0x40 DESC_ISSUED  +0x44 DESC_DONE  +0x48 DESC_ERR      RO
//     +0x4C STATE        RO  [0] busy [1] done [2] aborted
//     +0x50/54 T_FIRST   +0x58/5C T_LAST     RO  64-bit cycle stamps
//     +0x60/64 D_FIRST   +0x68/6C D_LAST     RO  first / last data beat
//     +0x70/74 BEATS                         RO  256-bit data beats
//     +0x78/7C CYCLES                        RO  T_LAST - T_FIRST
//   0x200 checker: +0x00 ERR_COUNT  +0x04/08 ERR_ADDR  +0x0C ERR_EXP
//                  +0x10 ERR_GOT    +0x14/18 BEATS            (all RO)
//   0x1000 + 8*i  chunk table entry i (i = 0..63), WO: write LO (+0) first,
//                 the HI write (+4) commits the 64-bit host bus address
// --------------------------------------------------------------------------
module dma_port #(
    parameter int        PORT_INDEX = 0,
    parameter int        RAM_BANKS  = 256,          // x 16 KB
    parameter bit [31:0] SHELL_ID   = 32'h444D4137,
    parameter bit [31:0] CAPS       = 32'h00000010
) (
    input  wire          clk,
    input  wire          rst,
    input  wire  [31:0]  temp_word,

    // BAR0 (Avalon-MM slave behind the mm_bridge, byte addresses)
    input  wire  [15:0]  av_address,
    input  wire          av_read,
    input  wire          av_write,
    input  wire  [31:0]  av_writedata,
    output logic [31:0]  av_readdata,
    output logic         av_readdatavalid,

    // read DMA (host -> FPGA)
    output wire          rd_desc_valid,
    output wire  [159:0] rd_desc_data,
    input  wire          rd_desc_ready,
    input  wire          rd_st_valid,
    input  wire  [31:0]  rd_st_data,
    input  wire  [63:0]  rdm_address,
    input  wire          rdm_write,
    input  wire  [255:0] rdm_writedata,
    input  wire  [31:0]  rdm_byteenable,
    input  wire  [4:0]   rdm_burstcount,
    output wire          rdm_waitrequest,

    // write DMA (FPGA -> host)
    output wire          wr_desc_valid,
    output wire  [159:0] wr_desc_data,
    input  wire          wr_desc_ready,
    input  wire          wr_st_valid,
    input  wire  [31:0]  wr_st_data,
    input  wire  [63:0]  wrm_address,
    input  wire          wrm_read,
    input  wire  [4:0]   wrm_burstcount,
    output wire          wrm_waitrequest,
    output logic [255:0] wrm_readdata,
    output logic         wrm_readdatavalid,

    // hard IP TX slave (status records)
    output wire  [63:0]  txs_address,
    output wire          txs_chipselect,
    output wire          txs_write,
    output wire  [31:0]  txs_writedata,
    output wire  [3:0]   txs_byteenable,
    output wire  [4:0]   txs_burstcount,
    output wire          txs_read,
    input  wire          txs_waitrequest
);
    import dma_pkg::*;

    localparam int RAM_BW  = $clog2(RAM_BANKS) + 9;          // word index bits
    localparam int RAM_LAT = 4 + ($clog2(RAM_BANKS) + 1) / 2; // see dma_ram.sv

    // ------------------------------------------------------------ time base
    logic [63:0] now;
    always_ff @(posedge clk) begin
        if (rst) now <= 64'd0;
        else     now <= now + 64'd1;
    end

    // ------------------------------------------------------------ registers
    logic [31:0] scratch, seed, time_hi_l;
    logic [31:0] cfg_fpga_lo [2], cfg_fpga_hi [2], cfg_len [2], cfg_seq [2];
    logic [31:0] cfg_stat_lo [2], cfg_stat_hi [2];
    logic [5:0]  cfg_chunk0 [2];
    logic [4:0]  cfg_shift [2];
    logic [15:0] cfg_loops [2];
    logic [7:0]  cfg_max_out [2];
    logic [31:0] tbl_lo;
    logic        tbl_we;
    logic [5:0]  tbl_idx;
    logic [63:0] tbl_data;
    logic [1:0]  start;
    logic        abort, chk_clear;

    // engine results
    logic         busy [2], done [2], aborted [2];
    logic [31:0]  issued [2], dcnt [2], derr [2];
    logic [63:0]  t_first [2], t_last [2], d_first [2], d_last [2], nbeats [2];
    logic [63:0]  rec_addr [2];
    logic [1:0]   rec_req, rec_ack;
    wire  [63:0]  cycles0 = t_last[0] - t_first[0];
    wire  [63:0]  cycles1 = t_last[1] - t_first[1];

    // checker results
    logic [31:0]  chk_err, chk_exp, chk_got;
    logic [63:0]  chk_addr, chk_beats;

    wire wsel_dir = av_address[7];        // 0x100 block -> 0, 0x180 block -> 1
    wire [6:0] woff = av_address[6:0];

    always_ff @(posedge clk) begin
        start     <= 2'b00;
        abort     <= 1'b0;
        chk_clear <= 1'b0;
        tbl_we    <= 1'b0;

        if (av_write) begin
            if (av_address[15:12] == 4'h1) begin
                // chunk table, 0x1000 + 8*i
                if (!av_address[2]) begin
                    tbl_lo <= av_writedata;
                end else begin
                    tbl_we   <= 1'b1;
                    tbl_idx  <= av_address[8:3];
                    tbl_data <= {av_writedata, tbl_lo};
                end
            end else if (av_address[15:8] == 8'h01) begin
                case (woff)
                7'h00: cfg_fpga_lo[wsel_dir] <= av_writedata;
                7'h04: cfg_fpga_hi[wsel_dir] <= av_writedata;
                7'h08: cfg_len[wsel_dir]     <= av_writedata;
                7'h0C: cfg_chunk0[wsel_dir]  <= av_writedata[5:0];
                7'h10: cfg_shift[wsel_dir]   <= av_writedata[4:0];
                7'h14: cfg_loops[wsel_dir]   <= av_writedata[15:0];
                7'h18: cfg_max_out[wsel_dir] <= av_writedata[7:0];
                7'h1C: cfg_seq[wsel_dir]     <= av_writedata;
                7'h20: cfg_stat_lo[wsel_dir] <= av_writedata;
                7'h24: cfg_stat_hi[wsel_dir] <= av_writedata;
                default: ;
                endcase
            end else begin
                case (av_address)
                16'h0010: scratch <= av_writedata;
                16'h0080: begin
                    start     <= av_writedata[1:0];
                    abort     <= av_writedata[4];
                    chk_clear <= av_writedata[8] | av_writedata[0];   // a H2D start clears too
                end
                16'h0088: seed <= av_writedata;
                default: ;
                endcase
            end
        end

        if (rst) begin
            scratch <= 32'd0;
            seed    <= 32'd0;
            for (int d = 0; d < 2; d++) begin
                cfg_fpga_lo[d] <= 32'd0;
                cfg_fpga_hi[d] <= 32'd0;
                cfg_len[d]     <= 32'd0;
                cfg_chunk0[d]  <= 6'd0;
                cfg_shift[d]   <= 5'(DESC_SHIFT_MAX);
                cfg_loops[d]   <= 16'd1;
                cfg_max_out[d] <= 8'd64;
                cfg_seq[d]     <= 32'd0;
                cfg_stat_lo[d] <= 32'd0;
                cfg_stat_hi[d] <= 32'd0;
            end
        end
    end

    // read path: registered, readdatavalid one cycle after read
    function automatic logic [31:0] dir_reg(input int d, input logic [6:0] o);
        case (o)
        7'h00: return cfg_fpga_lo[d];
        7'h04: return cfg_fpga_hi[d];
        7'h08: return cfg_len[d];
        7'h0C: return {26'd0, cfg_chunk0[d]};
        7'h10: return {27'd0, cfg_shift[d]};
        7'h14: return {16'd0, cfg_loops[d]};
        7'h18: return {24'd0, cfg_max_out[d]};
        7'h1C: return cfg_seq[d];
        7'h20: return cfg_stat_lo[d];
        7'h24: return cfg_stat_hi[d];
        7'h40: return issued[d];
        7'h44: return dcnt[d];
        7'h48: return derr[d];
        7'h4C: return {29'd0, aborted[d], done[d], busy[d]};
        7'h50: return t_first[d][31:0];
        7'h54: return t_first[d][63:32];
        7'h58: return t_last[d][31:0];
        7'h5C: return t_last[d][63:32];
        7'h60: return d_first[d][31:0];
        7'h64: return d_first[d][63:32];
        7'h68: return d_last[d][31:0];
        7'h6C: return d_last[d][63:32];
        7'h70: return nbeats[d][31:0];
        7'h74: return nbeats[d][63:32];
        7'h78: return (d == 0) ? cycles0[31:0]  : cycles1[31:0];
        7'h7C: return (d == 0) ? cycles0[63:32] : cycles1[63:32];
        default: return 32'd0;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        av_readdatavalid <= av_read;
        if (av_read) begin
            av_readdata <= 32'd0;
            if (av_address[15:8] == 8'h01) begin
                av_readdata <= dir_reg(wsel_dir ? 1 : 0, woff);
            end else begin
                case (av_address)
                16'h0000: av_readdata <= SHELL_ID;
                16'h0004: av_readdata <= CAPS;
                16'h0008: av_readdata <= 32'd0;
                16'h000C: av_readdata <= 32'(PORT_INDEX);
                16'h0010: av_readdata <= scratch;
                16'h0030: av_readdata <= now[31:0];
                16'h0040: av_readdata <= 32'h50434945;
                16'h0050: av_readdata <= temp_word;
                16'h0060: av_readdata <= 32'h00070001;
                16'h0064: av_readdata <= 32'(CLK_HZ);
                16'h0068: av_readdata <= 32'(RAM_BANKS * 16384);
                16'h006C: av_readdata <= 32'(CHUNK_SHIFT);
                16'h0070: av_readdata <= 32'(CHUNK_ENTRIES);
                16'h0074: begin
                    av_readdata <= now[31:0];
                    time_hi_l   <= now[63:32];
                end
                16'h0078: av_readdata <= time_hi_l;
                16'h0084: av_readdata <= {26'd0, aborted[1], aborted[0], done[1], done[0],
                                          busy[1], busy[0]};
                16'h0088: av_readdata <= seed;
                16'h008C: av_readdata <= 32'd1;
                16'h0200: av_readdata <= chk_err;
                16'h0204: av_readdata <= chk_addr[31:0];
                16'h0208: av_readdata <= chk_addr[63:32];
                16'h020C: av_readdata <= chk_exp;
                16'h0210: av_readdata <= chk_got;
                16'h0214: av_readdata <= chk_beats[31:0];
                16'h0218: av_readdata <= chk_beats[63:32];
                default: ;
                endcase
            end
        end
        if (rst)
            av_readdatavalid <= 1'b0;
    end

    // ------------------------------------------------------------ data path
    // Read DMA master (writes into the FPGA)
    logic         wb_valid;
    logic [63:0]  wb_addr;
    logic [255:0] wb_data;
    logic [31:0]  wb_be;

    assign rdm_waitrequest = 1'b0;

    dma_wr_beats u_wr_beats (
        .clk        (clk),
        .rst        (rst),
        .address    (rdm_address),
        .write      (rdm_write),
        .writedata  (rdm_writedata),
        .byteenable (rdm_byteenable),
        .burstcount (rdm_burstcount),
        .beat_valid (wb_valid),
        .beat_addr  (wb_addr),
        .beat_data  (wb_data),
        .beat_be    (wb_be)
    );

    dma_checker u_checker (
        .clk        (clk),
        .rst        (rst),
        .clear      (chk_clear),
        .seed       (seed),
        .beat_valid (wb_valid && wb_addr[32]),
        .beat_addr  (wb_addr),
        .beat_data  (wb_data),
        .beat_be    (wb_be),
        .err_count  (chk_err),
        .err_addr   (chk_addr),
        .err_exp    (chk_exp),
        .err_got    (chk_got),
        .beats      (chk_beats)
    );

    // Write DMA master (reads from the FPGA)
    logic         rb_valid;
    logic [63:0]  rb_addr;
    logic [255:0] ram_q;

    dma_rd_beats u_rd_beats (
        .clk         (clk),
        .rst         (rst),
        .address     (wrm_address),
        .read        (wrm_read),
        .burstcount  (wrm_burstcount),
        .waitrequest (wrm_waitrequest),
        .beat_valid  (rb_valid),
        .beat_addr   (rb_addr)
    );

    dma_ram #(.BANKS(RAM_BANKS)) u_ram (
        .clk   (clk),
        .we    (wb_valid && !wb_addr[32]),
        .waddr (wb_addr[RAM_BW+4:5]),
        .wdata (wb_data),
        .be    (wb_be),
        .raddr (rb_addr[RAM_BW+4:5]),
        .rdata (ram_q)
    );

    // Pattern generator, delayed to the RAM latency; then one output register.
    logic [255:0] gen_d [1:RAM_LAT];
    logic         sel_d [1:RAM_LAT];
    logic         val_d [1:RAM_LAT];
    always_ff @(posedge clk) begin
        gen_d[1] <= pat_beat(rb_addr, seed);
        sel_d[1] <= rb_addr[32];
        val_d[1] <= rb_valid;
        for (int k = 2; k <= RAM_LAT; k++) begin
            gen_d[k] <= gen_d[k-1];
            sel_d[k] <= sel_d[k-1];
            val_d[k] <= val_d[k-1];
        end
        wrm_readdata      <= sel_d[RAM_LAT] ? gen_d[RAM_LAT] : ram_q;
        wrm_readdatavalid <= val_d[RAM_LAT];
        if (rst) begin
            for (int k = 1; k <= RAM_LAT; k++)
                val_d[k] <= 1'b0;
            wrm_readdatavalid <= 1'b0;
        end
    end

    // ------------------------------------------------------------ engines
    logic [127:0] rec0, rec1;
    assign rec0 = {derr[0][15:0], dcnt[0][15:0], cycles0[63:32], cycles0[31:0], cfg_seq[0]};
    assign rec1 = {derr[1][15:0], dcnt[1][15:0], cycles1[63:32], cycles1[31:0], cfg_seq[1]};

    dma_dir #(.IS_WRITE(1'b0)) u_h2d (
        .clk            (clk),
        .rst            (rst),
        .now            (now),
        .cfg_fpga_addr  ({cfg_fpga_hi[0], cfg_fpga_lo[0]}),
        .cfg_length     (cfg_len[0]),
        .cfg_chunk0     (cfg_chunk0[0]),
        .cfg_desc_shift (cfg_shift[0]),
        .cfg_loops      (cfg_loops[0]),
        .cfg_max_out    (cfg_max_out[0]),
        .cfg_stat_addr  ({cfg_stat_hi[0], cfg_stat_lo[0]}),
        .start          (start[0]),
        .abort          (abort),
        .tbl_we         (tbl_we),
        .tbl_idx        (tbl_idx),
        .tbl_data       (tbl_data),
        .desc_valid     (rd_desc_valid),
        .desc_data      (rd_desc_data),
        .desc_ready     (rd_desc_ready),
        .st_valid       (rd_st_valid),
        .st_data        (rd_st_data),
        .beat           (wb_valid),
        .rec_req        (rec_req[0]),
        .rec_ack        (rec_ack[0]),
        .rec_addr       (rec_addr[0]),
        .busy           (busy[0]),
        .done           (done[0]),
        .aborted        (aborted[0]),
        .desc_issued    (issued[0]),
        .desc_done      (dcnt[0]),
        .desc_err       (derr[0]),
        .t_first        (t_first[0]),
        .t_last         (t_last[0]),
        .d_first        (d_first[0]),
        .d_last         (d_last[0]),
        .beats          (nbeats[0])
    );

    dma_dir #(.IS_WRITE(1'b1)) u_d2h (
        .clk            (clk),
        .rst            (rst),
        .now            (now),
        .cfg_fpga_addr  ({cfg_fpga_hi[1], cfg_fpga_lo[1]}),
        .cfg_length     (cfg_len[1]),
        .cfg_chunk0     (cfg_chunk0[1]),
        .cfg_desc_shift (cfg_shift[1]),
        .cfg_loops      (cfg_loops[1]),
        .cfg_max_out    (cfg_max_out[1]),
        .cfg_stat_addr  ({cfg_stat_hi[1], cfg_stat_lo[1]}),
        .start          (start[1]),
        .abort          (abort),
        .tbl_we         (tbl_we),
        .tbl_idx        (tbl_idx),
        .tbl_data       (tbl_data),
        .desc_valid     (wr_desc_valid),
        .desc_data      (wr_desc_data),
        .desc_ready     (wr_desc_ready),
        .st_valid       (wr_st_valid),
        .st_data        (wr_st_data),
        .beat           (wrm_readdatavalid),
        .rec_req        (rec_req[1]),
        .rec_ack        (rec_ack[1]),
        .rec_addr       (rec_addr[1]),
        .busy           (busy[1]),
        .done           (done[1]),
        .aborted        (aborted[1]),
        .desc_issued    (issued[1]),
        .desc_done      (dcnt[1]),
        .desc_err       (derr[1]),
        .t_first        (t_first[1]),
        .t_last         (t_last[1]),
        .d_first        (d_first[1]),
        .d_last         (d_last[1]),
        .beats          (nbeats[1])
    );

    dma_txs_writer u_txs (
        .clk             (clk),
        .rst             (rst),
        .req             (rec_req),
        .ack             (rec_ack),
        .addr0           (rec_addr[0]),
        .addr1           (rec_addr[1]),
        .rec0            (rec0),
        .rec1            (rec1),
        .txs_address     (txs_address),
        .txs_write       (txs_write),
        .txs_writedata   (txs_writedata),
        .txs_waitrequest (txs_waitrequest)
    );

    assign txs_chipselect = txs_write;
    assign txs_byteenable = 4'hF;
    assign txs_burstcount = 5'd1;
    assign txs_read       = 1'b0;

endmodule

`default_nettype wire
