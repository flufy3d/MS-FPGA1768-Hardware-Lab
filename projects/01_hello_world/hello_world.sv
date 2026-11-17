// -----------------------------------------------------------------------------
// hello_world.sv
//
// Minimal bring-up design for the Microsoft FPGA 1768 / Catapult v3 "Longs Peak".
//
//   led[8]   : 1 Hz heartbeat (0.5 s on, 0.5 s off)
//   led[7:0] : 8-bit seconds counter (wraps every 256 s)
//
// Clock: 100 MHz on pin AP20 (oscillator U59 / CLKUSR).
// There is no reset: Arria 10 registers initialise to 0 after configuration.
//
// Volatile JTAG configuration only — this design does not touch the config flash.
// -----------------------------------------------------------------------------

`default_nettype none

module hello_world (
    input  logic       clk_100,
    output logic [8:0] led
);

    // 100 MHz / 50_000_000 = 2 Hz tick -> 1 Hz square wave
    localparam int TICKS_PER_HALF_SECOND = 50_000_000;

    logic [25:0] div_cnt;
    logic [7:0]  seconds;
    logic        heartbeat;

    always_ff @(posedge clk_100) begin
        if (div_cnt == TICKS_PER_HALF_SECOND - 1) begin
            div_cnt   <= '0;
            heartbeat <= ~heartbeat;
            seconds   <= seconds + 8'd1;
        end else begin
            div_cnt <= div_cnt + 26'd1;
        end
    end

    assign led[8]   = heartbeat;
    assign led[7:0] = seconds;

endmodule

`default_nettype wire
