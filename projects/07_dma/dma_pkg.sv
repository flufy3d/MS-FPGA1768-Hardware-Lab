// --------------------------------------------------------------------------
// dma_pkg — constants and the test pattern of 07_dma
//
// Test pattern: the 32-bit dword at FPGA byte address A (dword aligned) is
//
//     pat_dw((A >> 2) mod 2^32, SEED)
//
// where pat_dw is one xorshift32 step (shifts 13, 17, 5) applied to
// (index XOR SEED). The value depends only on the address, never on the order
// in which beats arrive: the read DMA of the hard IP may write completions to
// Avalon out of address order. The host computes the same function
// (host/cap_dma.c, pat_dw()); keep the two identical.
//
// Avalon data is little endian: dword k of a 256-bit beat (bits 32k+31:32k)
// is at byte address (beat address + 4k).
// --------------------------------------------------------------------------
package dma_pkg;

    // Hard IP core clock for Gen3 x8, 256-bit interface (coreclkout_hip).
    localparam int unsigned CLK_HZ = 250_000_000;

    // Host common-buffer chunk size (log2 bytes): 4 MB.
    localparam int unsigned CHUNK_SHIFT = 22;
    // Entries in the chunk table (64 x 4 MB = 256 MB of host buffer).
    localparam int unsigned CHUNK_ENTRIES = 64;

    // Descriptor size limits (log2 bytes). The descriptor length field is
    // 18 bits of dwords, so 2^20 bytes does not fit; 512 KB is the largest
    // power of two that does.
    localparam int unsigned DESC_SHIFT_MIN = 8;    // 256 bytes
    localparam int unsigned DESC_SHIFT_MAX = 19;   // 512 KB

    function automatic logic [31:0] pat_dw(input logic [31:0] idx, input logic [31:0] seed);
        logic [31:0] x;
        x = idx ^ seed;
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        return x;
    endfunction

    // 256-bit beat at byte address a (32-byte aligned).
    function automatic logic [255:0] pat_beat(input logic [63:0] a, input logic [31:0] seed);
        logic [255:0] b;
        for (int k = 0; k < 8; k++)
            b[32*k +: 32] = pat_dw({a[33:5], 3'(k)}, seed);
        return b;
    endfunction

endpackage
