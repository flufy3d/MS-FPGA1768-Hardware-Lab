`default_nettype none

// --------------------------------------------------------------------------
// bar0_regs — BAR0 register block of 06_i2c_telemetry (BAR0 + 0x000..0x0FF)
//
// Avalon-MM slave behind an mm_bridge (byte addresses, 32-bit data, no wait
// states, read data one cycle after the read). Writes to read-only or
// unmapped offsets are ignored; unmapped reads return 0.
//
//   0x00 SHELL_ID  RO  0x49323036 ("I206")
//   0x04 CAPS      RO  0x00000002 (bit1 I2C)
//   0x08 CAPS2     RO  0 (reserved)
//   0x30 COUNTER   RO  free-running clk counter
//   0x40 ID        RO  0x50434945 ("PCIE", checked by the Windows test driver)
//   0x50 TEMP      RO  die temperature sensor word (built in the top level)
//   0x60 CTRL      RW  [0] start (W1, self-clearing) [1] bus (0 = bus 1,
//                      1 = bus 2) [2] rw (1 = read) [3] abort (W1,
//                      self-clearing) [4] no_reg (skip the command byte)
//   0x64 ADDR      RW  [6:0] 7-bit device address
//   0x68 PAGE      RW  [7:0] page, [8] enable (write 0xFF = page first)
//   0x6C REG       RW  [7:0] command / register byte
//   0x70 LEN       RW  [5:0] data bytes, 0..28
//   0x74..0x8C DATA RW 28 bytes, little endian (byte i at 0x74 + i).
//                      Write data before a write; read data after a read.
//                      Host writes are ignored while busy.
//   0x90 STATUS    RO  [0] busy [1] ack_error [2] done [3] timeout
//                      [4] aborted [15:8] data bytes transferred
//                      [16] bus 1 SCL [17] bus 1 SDA [18] bus 2 SCL
//                      [19] bus 2 SDA (live, synchronised line levels)
//   0x94 SCL_DIV   RW  [15:0] quarter SCL period in clk cycles (reset 250 =
//                      100 kHz; values below 25 act as 25)
//
// CTRL writes with start = 1 while busy are ignored.
// --------------------------------------------------------------------------
module bar0_regs #(
    parameter [31:0] SHELL_ID = 32'h49323036,
    parameter [31:0] CAPS     = 32'h00000002,
    parameter [31:0] CAPS2    = 32'h00000000,
    parameter [31:0] ID       = 32'h50434945
) (
    input  wire        clk,
    input  wire        rst,

    // Avalon-MM slave
    input  wire [7:0]  address,
    input  wire        read,
    input  wire        write,
    input  wire [31:0] writedata,
    output reg  [31:0] readdata,
    output reg         readdatavalid,

    // Values built elsewhere
    input  wire [31:0] counter,
    input  wire [31:0] temp,

    // I2C master
    output reg          i2c_start,
    output reg          i2c_abort,
    output reg          i2c_bus,
    output reg          i2c_rw,
    output reg          i2c_no_reg,
    output reg  [6:0]   i2c_addr,
    output reg  [7:0]   i2c_reg,
    output reg          i2c_page_en,
    output reg  [7:0]   i2c_page,
    output reg  [5:0]   i2c_len,
    output reg  [15:0]  i2c_div,
    output wire [223:0] i2c_wbuf,
    input  wire         i2c_rbuf_we,
    input  wire [4:0]   i2c_rbuf_idx,
    input  wire [7:0]   i2c_rbuf_data,
    input  wire         i2c_busy,
    input  wire         i2c_done,
    input  wire         i2c_ack_error,
    input  wire         i2c_timeout,
    input  wire         i2c_aborted,
    input  wire [7:0]   i2c_bytes,
    input  wire [3:0]   i2c_lines      // {sda2, scl2, sda1, scl1}
);

    reg [7:0] data [0:27];

    genvar g;
    generate
        for (g = 0; g < 28; g++) begin : g_wbuf
            assign i2c_wbuf[8*g +: 8] = data[g];
        end
    endgenerate

    wire [5:0] word = address[7:2];
    localparam [5:0] W_DATA0 = 6'h1D;   // 0x74
    localparam [5:0] W_DATA6 = 6'h23;   // 0x8C
    wire       is_data = (word >= W_DATA0) && (word <= W_DATA6);
    wire [2:0] dword   = word - W_DATA0;  // 0..6

    integer i;

    always_ff @(posedge clk) begin
        i2c_start <= 1'b0;
        i2c_abort <= 1'b0;

        if (rst) begin
            i2c_bus <= 1'b0; i2c_rw <= 1'b0; i2c_no_reg <= 1'b0;
            i2c_addr <= 7'd0; i2c_reg <= 8'd0;
            i2c_page_en <= 1'b0; i2c_page <= 8'd0;
            i2c_len <= 6'd0; i2c_div <= 16'd250;
        end else begin
            // ---- host writes ----
            if (write) begin
                case (word)
                6'h18: begin                                  // 0x60 CTRL
                    if (!i2c_busy) begin
                        i2c_bus    <= writedata[1];
                        i2c_rw     <= writedata[2];
                        i2c_no_reg <= writedata[4];
                        i2c_start  <= writedata[0];
                    end
                    i2c_abort <= writedata[3];
                end
                6'h19: if (!i2c_busy) i2c_addr <= writedata[6:0];               // 0x64
                6'h1A: if (!i2c_busy) begin                                     // 0x68
                    i2c_page    <= writedata[7:0];
                    i2c_page_en <= writedata[8];
                end
                6'h1B: if (!i2c_busy) i2c_reg <= writedata[7:0];                // 0x6C
                6'h1C: if (!i2c_busy) i2c_len <= writedata[5:0];                // 0x70
                6'h25: i2c_div <= writedata[15:0];                              // 0x94
                default: ;
                endcase
                if (is_data && !i2c_busy)
                    for (i = 0; i < 4; i++)
                        if (dword * 4 + i < 28)
                            data[dword * 4 + i] <= writedata[8*i +: 8];
            end
            // ---- read data from the I2C master ----
            if (i2c_rbuf_we)
                data[i2c_rbuf_idx] <= i2c_rbuf_data;
        end
    end

    // ---- host reads (one cycle latency) ----
    always_ff @(posedge clk) begin
        readdatavalid <= read;
        if (read) begin
            case (word)
            6'h00: readdata <= SHELL_ID;
            6'h01: readdata <= CAPS;
            6'h02: readdata <= CAPS2;
            6'h0C: readdata <= counter;
            6'h10: readdata <= ID;
            6'h14: readdata <= temp;
            6'h18: readdata <= {27'd0, i2c_no_reg, 1'b0, i2c_rw, i2c_bus, 1'b0};
            6'h19: readdata <= {25'd0, i2c_addr};
            6'h1A: readdata <= {23'd0, i2c_page_en, i2c_page};
            6'h1B: readdata <= {24'd0, i2c_reg};
            6'h1C: readdata <= {26'd0, i2c_len};
            6'h24: readdata <= {12'd0, i2c_lines, i2c_bytes, 3'd0, i2c_aborted,
                                i2c_timeout, i2c_done, i2c_ack_error, i2c_busy};
            6'h25: readdata <= {16'd0, i2c_div};
            default:
                if (is_data)
                    readdata <= {data[dword*4 + 3], data[dword*4 + 2],
                                 data[dword*4 + 1], data[dword*4]};
                else
                    readdata <= 32'd0;
            endcase
        end
    end

endmodule

`default_nettype wire
