`default_nettype none

// --------------------------------------------------------------------------
// dma_ram — on-chip loopback RAM of 07_dma (M20K), 256-bit words
//
// BANKS banks of 512 words x 256 bits (16 KB each, eight M20K blocks in
// 512 x 32 mode with byte enables). BANKS = 256 gives 4 MB (2048 M20K).
//
// One write port with byte enables, one read port, one clock. The inputs are
// registered into GROUPS replicated copies (each copy drives BANKS/GROUPS
// banks) so that no register fans out to all 2048 blocks; the read data goes
// through a registered 4:1 mux tree, two bank-select bits per stage.
//
// Read latency (input to rdata) = 4 + STAGES clock cycles, STAGES =
// ceil(log2(BANKS) / 2): 8 for 256 banks (dma_port.sv computes the same
// value as RAM_LAT). Needs BANKS >= 16 (STAGES >= 2).
//
// Write latency is 2 cycles longer than a plain register (input tree).
// Read-during-write to the same word returns either value (not used).
// --------------------------------------------------------------------------
module dma_ram_bank (
    input  wire          clk,
    input  wire          we,
    input  wire  [8:0]   waddr,
    input  wire  [255:0] wdata,
    input  wire  [31:0]  be,
    input  wire  [8:0]   raddr,
    output logic [255:0] q
);
    // Packed bytes: the Quartus template for a byte-enabled simple dual-port RAM.
    logic [31:0][7:0] mem [0:511];
    logic [255:0]     q0;

    always_ff @(posedge clk) begin
        if (we)
            for (int i = 0; i < 32; i++)
                if (be[i])
                    mem[waddr][i] <= wdata[8*i +: 8];
        q0 <= mem[raddr];
        q  <= q0;
    end
endmodule

module dma_ram #(
    parameter int BANKS  = 256,
    parameter int GROUPS = 16
) (
    input  wire                          clk,
    input  wire                          we,
    input  wire  [$clog2(BANKS)+8:0]     waddr,   // 256-bit word index
    input  wire  [255:0]                 wdata,
    input  wire  [31:0]                  be,
    input  wire  [$clog2(BANKS)+8:0]     raddr,   // 256-bit word index
    output wire  [255:0]                 rdata
);
    localparam int BW     = $clog2(BANKS);
    localparam int AW     = BW + 9;
    localparam int STAGES = (BW + 1) / 2;
    localparam int SW     = 2 * STAGES;
    localparam int NPAD   = 1 << SW;
    localparam int PER_G  = (BANKS + GROUPS - 1) / GROUPS;

    // ---------------------------------------------------------- inputs
    logic [SW-1:0] seld [1:STAGES+2];   // bank select, seld[k] valid k cycles after the input
    always_ff @(posedge clk) begin
        seld[1] <= SW'(raddr[AW-1:9]);
        for (int k = 2; k <= STAGES + 2; k++)
            seld[k] <= seld[k-1];
    end

    logic [255:0] q [0:BANKS-1];

    // Write inputs: one more register level (4 copies) in front of the
    // groups, so no single register drives all 16 groups across the device.
    // Writes land one cycle later; reads are not affected.
    (* dont_merge *) logic          wm_we [0:3];
    (* dont_merge *) logic [AW-1:0] wm_wa [0:3];
    (* dont_merge *) logic [255:0]  wm_wd [0:3];
    (* dont_merge *) logic [31:0]   wm_be [0:3];
    always_ff @(posedge clk) begin
        for (int m = 0; m < 4; m++) begin
            wm_we[m] <= we;
            wm_wa[m] <= waddr;
            wm_wd[m] <= wdata;
            wm_be[m] <= be;
        end
    end

    genvar g, b;
    generate
        for (g = 0; g < GROUPS; g++) begin : grp
            (* dont_merge *) logic          we_r;
            (* dont_merge *) logic [AW-1:0] wa_r;
            (* dont_merge *) logic [255:0]  wd_r;
            (* dont_merge *) logic [31:0]   be_r;
            (* dont_merge *) logic [8:0]    ra_r;
            always_ff @(posedge clk) begin
                we_r <= wm_we[g % 4];
                wa_r <= wm_wa[g % 4];
                wd_r <= wm_wd[g % 4];
                be_r <= wm_be[g % 4];
                ra_r <= raddr[8:0];
            end
            for (b = g * PER_G; b < (g + 1) * PER_G && b < BANKS; b++) begin : bank
                dma_ram_bank u_bank (
                    .clk   (clk),
                    .we    (we_r && (wa_r[AW-1:9] == BW'(b))),
                    .waddr (wa_r[8:0]),
                    .wdata (wd_r),
                    .be    (be_r),
                    .raddr (ra_r),
                    .q     (q[b])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------- read mux
    // Bank output q is valid 3 cycles after the input (group register, RAM
    // address register, output register). Stages 1 .. STAGES-1 each register
    // a 4:1 choice made with select bits [2s-1:2s-2]; the outputs of stage
    // STAGES-1 (four words, spread over the device) go through one extra
    // routing register before the last 4:1 stage. The select bits are
    // replicated per stage, output word and 32-bit slice to keep their
    // fan-out low and local.
    logic [255:0] qv [0:NPAD-1];
    generate
        for (b = 0; b < NPAD; b++) begin : pad
            if (b < BANKS) begin : used
                assign qv[b] = q[b];
            end else begin : unused
                assign qv[b] = '0;
            end
        end
    endgenerate

    // selr[s][j][r]: select of stage s for output word j, 32-bit slice r. One
    // copy per (j, r) keeps each copy local to the four inputs it chooses from.
    (* dont_merge *) logic [SW-1:0] selr [1:STAGES][0:NPAD/4-1][0:7];
    always_ff @(posedge clk) begin
        for (int s = 1; s <= STAGES; s++)
            for (int j = 0; j < (NPAD >> (2 * s)); j++)
                for (int r = 0; r < 8; r++)
                    selr[s][j][r] <= (s < STAGES) ? seld[s+1] : seld[s+2];
    end

    logic [255:0] st [1:STAGES][0:NPAD/4-1];
    logic [255:0] rr [0:3];
    always_ff @(posedge clk) begin
        for (int j = 0; j < 4; j++)
            rr[j] <= st[STAGES-1][j];
        for (int s = 1; s <= STAGES; s++) begin
            for (int j = 0; j < (NPAD >> (2 * s)); j++) begin
                for (int r = 0; r < 8; r++) begin
                    if (s == 1)
                        st[s][j][32*r +: 32] <= qv[4*j + selr[s][j][r][1:0]][32*r +: 32];
                    else if (s < STAGES)
                        st[s][j][32*r +: 32] <= st[s-1][4*j + selr[s][j][r][2*(s-1) +: 2]][32*r +: 32];
                    else
                        st[s][j][32*r +: 32] <= rr[4*j + selr[s][j][r][2*(s-1) +: 2]][32*r +: 32];
                end
            end
        end
    end

    assign rdata = st[STAGES][0];

endmodule

`default_nettype wire
