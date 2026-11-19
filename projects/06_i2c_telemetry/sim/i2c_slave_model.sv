// --------------------------------------------------------------------------
// i2c_slave_model — behavioural I2C target for tb_i2c (simulation only)
//
// - 7-bit address ADDR, 256-byte register file, auto-incrementing pointer.
// - Write: first byte after the address sets the pointer, further bytes are
//   stored (pointer 0xFF stores the page register instead).
// - Read: returns mem[ptr] + page, so a test can see that paging worked.
// - STRETCH_NS > 0 holds SCL low that long after every ACK it sends.
// - Counts data bytes written (n_data_writes) and pointer writes (n_ptr_writes),
//   so the testbench can prove that reads and scans write no data.
// --------------------------------------------------------------------------
`timescale 1ns/1ps
module i2c_slave_model #(
    parameter [6:0] ADDR       = 7'h4C,
    parameter int   STRETCH_NS = 0
) (
    inout tri1 scl,
    inout tri1 sda
);
    reg sda_drv = 1'b0, scl_drv = 1'b0;
    assign sda = sda_drv ? 1'b0 : 1'bz;
    assign scl = scl_drv ? 1'b0 : 1'bz;

    reg [7:0] mem [0:255];
    reg [7:0] ptr  = 8'h00;
    reg [7:0] page = 8'h00;
    int n_data_writes = 0;
    int n_ptr_writes  = 0;
    int n_page_writes = 0;
    int n_addressed   = 0;

    initial for (int i = 0; i < 256; i++) mem[i] = 8'(i * 7 + 3);

    event start_ev, stop_ev;
    always @(negedge sda) if (scl === 1'b1) -> start_ev;
    always @(posedge sda) if (scl === 1'b1) -> stop_ev;

    task automatic recv_byte(output [7:0] b);
        for (int i = 0; i < 8; i++) begin
            @(posedge scl);
            b = {b[6:0], (sda === 1'b0) ? 1'b0 : 1'b1};
        end
    endtask

    task automatic send_ack();
        @(negedge scl);
        sda_drv = 1'b1;
        @(negedge scl);
        sda_drv = 1'b0;
        if (STRETCH_NS > 0) begin
            scl_drv = 1'b1;
            #(STRETCH_NS);
            scl_drv = 1'b0;
        end
    endtask

    task automatic do_xfer();
        reg [7:0] b;
        bit first;
        recv_byte(b);
        if (b[7:1] != ADDR) return;
        n_addressed++;
        send_ack();
        if (!b[0]) begin
            first = 1;
            forever begin
                recv_byte(b);
                if (first) begin
                    ptr = b; first = 0; n_ptr_writes++;
                end else if (ptr == 8'hFF) begin
                    page = b; n_page_writes++;
                end else begin
                    mem[ptr] = b; ptr++; n_data_writes++;
                end
                send_ack();
            end
        end else begin
            // SCL is low here (after the ACK clock): drive the first bit now.
            forever begin
                reg [7:0] d;
                d = mem[ptr] + page;
                ptr++;
                for (int i = 7; i >= 0; i--) begin
                    sda_drv = !d[i];
                    @(posedge scl);
                    @(negedge scl);
                end
                sda_drv = 1'b0;
                @(posedge scl);
                if (sda !== 1'b0) return;        // master NACK: done
                @(negedge scl);
            end
        end
    endtask

    always begin
        bit got_stop;
        @(start_ev);
        forever begin
            got_stop = 0;
            fork
                begin do_xfer(); wait (0); end
                begin @(stop_ev);  got_stop = 1; end
                begin @(start_ev); end
            join_any
            disable fork;
            sda_drv = 1'b0;
            scl_drv = 1'b0;
            if (got_stop) break;
        end
    end
endmodule
