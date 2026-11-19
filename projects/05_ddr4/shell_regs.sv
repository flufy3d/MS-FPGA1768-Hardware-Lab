`default_nettype none

// --------------------------------------------------------------------------
// shell_regs — shell register block at BAR0 + 0x200 (256 bytes), clk_100.
//
// Avalon-MM slave behind regs_br (Platform Designer bridge, exported):
// no wait states, read data valid one cycle after the read.
//
// Offset  Name            Access  Description
// 0x00    DDR_STATUS      RO      per channel (top [3:0], bottom [11:8]):
//                                 [0] cal success, [1] cal fail,
//                                 [2] EMIF user reset released, [3] quiesced;
//                                 [16] quiesce requested
// 0x04    QUIESCE         RW      [0] 1 = stop accepting persona DDR commands
// 0x08    FLASH_PAGE      RW      [12:0] 16 KB page of the flash window
// 0x0C    MBOX_CTRL       RW      [0] channel (0 top, 1 bottom), [1] 1 = write
// 0x10    MBOX_ADDR       RW      [24:0] 576-bit word address
// 0x14    MBOX_GO         WO      any write starts one mailbox access
// 0x18    MBOX_STATUS     RO      top [0] busy [1] refused; bottom [8] busy [9] refused
// 0x1C    DDR_INFO        RO      0x08551948: [7:0] 72 bytes per word,
//                                 [15:8] 25 word-address bits, [31:16] 2133 MT/s
// 0x20-   MBOX_WDATA[0:17] RW     write data, word 0 = bits [31:0]
// 0x80-   MBOX_RDATA[0:17] RO     read data of the selected channel
// 0xF0    REGS_VERSION    RO      0x00010000
// --------------------------------------------------------------------------
module shell_regs (
    input  wire          clk,
    input  wire [7:0]    address,
    input  wire          read,
    input  wire          write,
    input  wire [31:0]   writedata,
    output reg  [31:0]   readdata,
    output reg           readdatavalid,

    // DDR status (asynchronous)
    input  wire [1:0]    cal_success_a,
    input  wire [1:0]    cal_fail_a,
    input  wire [1:0]    usr_rst_n_a,
    input  wire [1:0]    quiesced_a,

    output reg           quiesce_req,
    output reg  [12:0]   flash_page,

    // Mailbox, one set of fields shared by both channels
    output reg  [1:0]    mb_go_tg,       // per channel
    output reg           mbx_wr,
    output reg  [24:0]   mbx_addr,
    output wire [575:0]  mbx_wdata,
    input  wire [1:0]    mb_done_tg_a,
    input  wire [1:0]    mb_err_a,
    input  wire [575:0]  mbres_top,
    input  wire [575:0]  mbres_bot
);
    wire [1:0] cal_s, fail_s, urst_s, qs_s, done_s, err_s;
    sync_bits #(.W(12)) u_sync (
        .clk (clk),
        .d   ({cal_success_a, cal_fail_a, usr_rst_n_a, quiesced_a, mb_done_tg_a, mb_err_a}),
        .q   ({cal_s, fail_s, urst_s, qs_s, done_s, err_s})
    );

    reg [31:0] mbx_w [18];
    reg        mbx_ch = 1'b0;

    genvar g;
    generate
        for (g = 0; g < 18; g++) begin : g_w
            assign mbx_wdata[32*g +: 32] = mbx_w[g];
        end
    endgenerate

    wire [575:0] mbres = mbx_ch ? mbres_bot : mbres_top;
    wire [1:0]   busy  = mb_go_tg ^ done_s;

    wire [5:0]   widx  = address[7:2];

    always_ff @(posedge clk) begin
        readdatavalid <= read;
        if (read) begin
            case (address)
                8'h00: readdata <= {15'd0, quiesce_req,
                                    4'd0, qs_s[1], urst_s[1], fail_s[1], cal_s[1],
                                    4'd0, qs_s[0], urst_s[0], fail_s[0], cal_s[0]};
                8'h04: readdata <= {31'd0, quiesce_req};
                8'h08: readdata <= {19'd0, flash_page};
                8'h0C: readdata <= {30'd0, mbx_wr, mbx_ch};
                8'h10: readdata <= {7'd0, mbx_addr};
                8'h18: readdata <= {22'd0, err_s[1], busy[1], 6'd0, err_s[0], busy[0]};
                8'h1C: readdata <= 32'h08551948;
                8'hF0: readdata <= 32'h00010000;
                default: begin
                    if (address >= 8'h20 && address < 8'h68)
                        readdata <= mbx_w[widx - 6'd8];
                    else if (address >= 8'h80 && address < 8'hC8)
                        readdata <= mbres[32*(widx - 6'd32) +: 32];
                    else
                        readdata <= 32'd0;
                end
            endcase
        end

        if (write) begin
            case (address)
                8'h04: quiesce_req <= writedata[0];
                8'h08: flash_page  <= writedata[12:0];
                8'h0C: begin
                    mbx_ch <= writedata[0];
                    mbx_wr <= writedata[1];
                end
                8'h10: mbx_addr <= writedata[24:0];
                8'h14: mb_go_tg[mbx_ch] <= ~mb_go_tg[mbx_ch];
                default: begin
                    if (address >= 8'h20 && address < 8'h68)
                        mbx_w[widx - 6'd8] <= writedata;
                end
            endcase
        end
    end

    initial begin
        readdata      = 32'd0;
        readdatavalid = 1'b0;
        quiesce_req   = 1'b0;
        flash_page    = 13'd0;
        mb_go_tg      = 2'b00;
        mbx_wr        = 1'b0;
        mbx_addr      = 25'd0;
        for (int i = 0; i < 18; i++) mbx_w[i] = 32'd0;
    end
endmodule

`default_nettype wire
