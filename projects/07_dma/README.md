# 07 — PCIe Gen3 x8 DMA throughput test

Measures the limit of host ↔ FPGA transfers over **PCIe #1 (Gen3 x8)** with the Arria 10
hard IP's DMA data movers, driven by a descriptor engine written for this project, an
address-pattern generator/checker that streams without limit, and a 4 MB on-chip RAM for
loopback checks. The host side is `fpga1768 dma` ([host/README.md](../../host/README.md))
with the lab's KMDF driver 1.1 ([../02_pcie_pio/driver](../02_pcie_pio/driver/)).

| Item | Value |
|------|-------|
| Top-level entity | `dma` |
| Device | `10AXF40AA` (Arria 10) |
| PCIe | #1, Gen3 (8.0 GT/s) x8; PCIe #2 not used |
| Hard IP | Arria 10 PCIe HIP, Avalon-MM with DMA, 256-bit, 250 MHz, **external** descriptor controller (`internal_controller_hwtcl 0`), max payload 256 bytes |
| BAR0 | 64-bit prefetchable memory, 64 KB; BAR1–BAR5 disabled |
| Vendor / device ID | `0x1172` / `0xE003` (same Windows driver as projects 02–06) |
| SHELL_ID / CAPS | `0x444D4137` ("DMA7") / `0x10` (bit 4 DMA) |
| Host profile | [host/profiles/07_dma.ini](../../host/profiles/07_dma.ini) |
| Configuration | volatile `.sof` over JTAG, config flash untouched |
| Status | see [Status](#status) |

Template: copied from [03_pcie_gen3](../03_pcie_gen3/) (minimal); the BAR0 map was
rebuilt for the host contract (03's `A` register sat at `0x00`).

## Purpose

1. Measure the highest host → FPGA (H2D, read DMA) and FPGA → host (D2H, write DMA)
   throughput of one Gen3 x8 link, each direction alone and both at once, for transfer
   sizes from 4 KB to 64 MB.
2. Separate link speed from software overhead: an FPGA-side cycle counter (first
   descriptor to last completion) and host-side `QueryPerformanceCounter` time.
3. Prove data integrity at full speed: pattern checked in the FPGA (H2D) and in host
   memory (D2H); RAM loopback compared byte for byte.
4. Report the negotiated Max Payload Size and Max Read Request Size from configuration
   space, because they bound the result.

Reference (the estimate made before the build): Gen3 x8 raw rate is
8 GT/s × 8 lanes × 128/130 = 7.877 GB/s per direction. After TLP and DLLP overhead,
writes (D2H) were expected around 6.8–7.0 GB/s and reads (H2D) around 5.5–6.5 GB/s,
depending on MPS, MRRS and the root complex. Measured: both about 7.1 GB/s (see
[Results](#results); the lab host's link runs at about 8.16 GT/s).

## Why the design looks like this

### Descriptor controller: written here, not Intel's example

With `internal_controller_hwtcl = 1` the hard IP has no `rxm_bar0` and BAR0 belongs to
Intel's descriptor controller (the 2026-11-17 failure, see
[lab-log/2026-11-18-pcie-gen3-dma-retest.md](../../lab-log/2026-11-18-pcie-gen3-dma-retest.md)).
With it off (as in projects 03–06), the descriptor sinks and status sources are external.
The only ready-made external controller in the Quartus 25.1 IP directory is `dma_control`
("Example : DMA Descriptor Controller for PCI Express", `ip/altera/altera_pcie/
altera_pcie_hip_256_avmm/dynamic_controller/`, used by Intel's example
`altera_pcie_a10_ed/example_design/a10/ep_g3x8_avmm256.qsys`; marked `INTERNAL`). It
fetches 128-entry descriptor tables from host memory, needs the host to manage a ring
index, writes a done word only for the "last pointer" descriptor, and its descriptor
streams stay inside Platform Designer behind a readyLatency adapter — so the FPGA could
not time "first request to last completion".

`dma_engine.sv` replaces it (decision 2026-11-19). The facts it relies on come from the
Quartus 25.1 data mover RTL (`altpcieav_dma_rd.sv`, `altpcieav_dma_wr_2.sv`) and the
example controller (`altpcie_dynamic_control.sv`); Intel's online user guide
(UG-01145, document 683425) could not be fetched on 2026-11-19, so they are `reported`
from RTL, not from the guide:

| Interface | Fact |
|-----------|------|
| descriptor (`rd_ast_rx`, `wr_ast_rx`, 160 bits) | `[63:0]` source, `[127:64]` destination, `[145:128]` length in dwords (18 bits), `[153:146]` ID, `[159:154]` 0 |
| descriptor sink | readyLatency 3; read mover FIFO 6 deep, `ready = count < 3` |
| status (`rd_ast_tx`, `wr_ast_tx`, 32 bits) | `[7:0]` ID, `[8]` done (read DMA: 0 = flushed/aborted); read status after the last Avalon write, write status after the last TLP is generated |
| `dma_rd_master` | writes host data into the FPGA: 64-bit address, 256-bit data, 32-bit byte enable, burstcount 1–16; bursts of one descriptor may arrive out of address order |
| `dma_wr_master` | reads FPGA data for the host: 64-bit address, 256-bit data, burstcount 1–16, pipelined |
| `txs` | 32-bit TX slave, address width set to 64 (`user_txs_addr_width_hwtcl`) so the status record can go anywhere in host memory |

The engine issues a descriptor only if the sink's ready was high three cycles earlier
and nothing was issued in the three cycles before (at most one descriptor in flight in
the ready-latency window), keeps up to 64 descriptors outstanding, and needs no
descriptor fetch from the host.

### Data sources and sinks

| FPGA address | H2D (written by `dma_rd_master`) | D2H (read by `dma_wr_master`) |
|--------------|----------------------------------|-------------------------------|
| `0x0_0000_0000` + RAM | 4 MB M20K RAM (aliases modulo 4 MB) | same RAM |
| `0x1_0000_0000` + any | pattern **checker** | pattern **generator** |

Pattern: the dword at FPGA byte address `A` is `xorshift32((A >> 2) XOR SEED)` (one step,
shifts 13/17/5; `dma_pkg.sv` and `host/cap_dma.c` implement the same function). It depends
only on the address, so out-of-order bursts check correctly and any length streams.

RAM: 256 banks of 512 × 256 bits (8 M20K each, 2048 M20K total). Write inputs pass
through 4 register copies, then 16 register groups (a write lands 2 cycles after the
beat); read data goes through a registered 4:1 mux tree with replicated selects and a
routing register before the last stage; read latency 8 cycles.

### Expansion to PCIe #2

Not built: the lab host (i7-5820K, 28 lanes) has the card in root port `8086:2F04`, which
is assumed to have only 8 lanes, so PCIe #2 cannot train in this slot. The design keeps
the second port cheap to add:

- `dma_port.sv` is everything behind one hard IP (its whole BAR0, both engines, TXS
  writer, generator, checker, RAM); `PORT_INDEX` reads back at BAR0 + `0x0C`.
- `make_qsys.tcl` builds each hard IP with `add_dma_port <p>` (instances `p<p>_*`).
- A second port = `add_dma_port 1` (with PCIe #2 pins `AE32/AE33`…, PERST# `AV18`,
  refclk `AE29/AE28`) and a second `dma_port #(.PORT_INDEX(1))` in `dma.sv`. Two 4 MB
  RAMs would not fit (2 × 2048 M20K > 2713); the second port would use
  `RAM_BANKS = 64` or less.

## Register map (BAR0)

Full list in [dma_port.sv](dma_port.sv); offsets are also in the host profile.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x000` | `SHELL_ID` | RO | `0x444D4137` |
| `0x004` | `CAPS` | RO | `0x00000010` (bit 4 DMA) |
| `0x008` | `CAPS2` | RO | `0` |
| `0x00C` | `PORT_INDEX` | RO | `0` (PCIe #1) |
| `0x010` | `SCRATCH` | RW | |
| `0x030` | `COUNTER` | RO | core clock cycles `[31:0]` |
| `0x040` | `ID` | RO | `0x50434945` (checked by the Windows driver) |
| `0x050` | `TEMP` | RO | die temperature word, as projects 03–06 |
| `0x060` | `VERSION` | RO | `0x00070001` |
| `0x064` | `CLK_HZ` | RO | `250000000` |
| `0x068` | `RAM_BYTES` | RO | `0x00400000` |
| `0x06C` / `0x070` | `CHUNK_SHIFT` / `CHUNK_COUNT` | RO | `22` (4 MB) / `64` |
| `0x074` / `0x078` | `TIME_LO` / `TIME_HI` | RO | 64-bit cycle counter (LO read latches HI) |
| `0x080` | `CTRL` | WO | `[0]` start H2D, `[1]` start D2H (both bits = simultaneous start), `[4]` abort, `[8]` clear checker (an H2D start also clears it) |
| `0x084` | `STATUS` | RO | `[0]` H2D busy, `[1]` D2H busy, `[2]`/`[3]` done, `[4]`/`[5]` aborted |
| `0x088` | `PAT_SEED` | RW | pattern seed |
| `0x08C` | `PAT_BASE_HI` | RO | `1` (pattern window at `0x1_0000_0000`) |
| `0x100` / `0x180` | H2D / D2H block | | below |
| `0x200` | checker | RO | `+0x00` bad dwords, `+0x04/08` first bad address, `+0x0C` expected, `+0x10` received, `+0x14/18` beats |
| `0x1000 + 8i` | chunk table entry `i` (0–63) | WO | host bus address of 4 MB chunk `i`; write LO (`+0`) then HI (`+4`, commits) |

Direction block (H2D at `0x100`, D2H at `0x180`):

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `+0x00` / `+0x04` | `FPGA_LO` / `FPGA_HI` | RW | FPGA (Avalon) start address |
| `+0x08` | `LENGTH` | RW | bytes per pass, multiple of 32 |
| `+0x0C` | `CHUNK0` | RW | first chunk-table entry; byte `off` is in entry `(CHUNK0 + off / 4 MB) mod 64` |
| `+0x10` | `DESC_SHIFT` | RW | log2 descriptor bytes, 8–19 (reset 19 = 512 KB) |
| `+0x14` | `LOOPS` | RW | passes over the same addresses (reset 1) |
| `+0x18` | `MAX_OUT` | RW | descriptors in flight, 1–64 (reset 64) |
| `+0x1C` | `SEQ` | RW | copied into status record DW0 |
| `+0x20` / `+0x24` | `STAT_LO` / `STAT_HI` | RW | host bus address of the 16-byte status record (0 = none) |
| `+0x40` / `+0x44` / `+0x48` | `DESC_ISSUED` / `DESC_DONE` / `DESC_ERR` | RO | |
| `+0x4C` | `STATE` | RO | `[0]` busy, `[1]` done, `[2]` aborted |
| `+0x50` … `+0x7C` | `T_FIRST`, `T_LAST`, `D_FIRST`, `D_LAST`, `BEATS`, `CYCLES` | RO | 64-bit each (LO, HI) |

Status record written through `txs` when a transfer ends (DW1–DW3 first, DW0 last):
DW0 = `SEQ`, DW1/DW2 = `CYCLES` (`T_LAST - T_FIRST`), DW3 = `[15:0]` descriptors done,
`[31:16]` descriptors with an error status.

## Pins used

Same PCIe #1 pins as project 03; all locations and I/O standards are in `dma.qsf`.
`clk_100` (`AP20`) is not used: everything runs on the hard IP core clock.

| Signal | Pin(s) | Notes |
|--------|--------|-------|
| `clk_pcie1` | `AN29` / `AN28` | 100 MHz PCIe #1 reference clock |
| `pcie1_perstn` | `AW16` | PCIe #1 PERST# |
| `pcie1_rx[7:0]`, `pcie1_tx[7:0]` | see `.qsf` | edge connector lanes 0–7 |

## Files

| File | Purpose |
|------|---------|
| `dma.sv` | top level: Platform Designer system, temperature sensor, one `dma_port` |
| `dma_port.sv` | per-hard-IP unit: BAR0 registers, engines, data path |
| `dma_engine.sv` | `dma_dir` (descriptor engine, one per direction), `dma_txs_writer` (status records) |
| `dma_beats.sv` | Avalon burst front ends, pattern checker |
| `dma_ram.sv` | 4 MB banked RAM |
| `dma_pkg.sv` | constants and the pattern function |
| `make_qsys.tcl` → `dma_sys.qsys`, `ip/dma_sys/*.ip` | hard IP, BAR0 bridge, clock/reset bridges, temperature sensor |
| `sim/tb_dma.sv`, `sim/run_sim.ps1` | simulation against a model of the hard IP data movers |

## Build

```powershell
. ..\..\scripts\env.ps1
Remove-Item -Recurse -Force ip\dma_sys, dma_sys -ErrorAction SilentlyContinue  # else *_1.ip variants
& "$env:QUARTUS_ROOTDIR\..\qsys\bin\qsys-script.exe" --script=make_qsys.tcl --quartus-project=dma.qpf
quartus_ipgenerate dma -c dma --run_default_mode_op
..\..\scripts\build.ps1 -Project dma.qpf
```

`qsys-script --quartus-project` added the five `IP_FILE` lines at the end of `dma.qsf`;
check them after regenerating.

## Simulate

```powershell
. ..\..\scripts\env.ps1
.\sim\run_sim.ps1
```

`tb_dma.sv` drives `dma_port` (RAM at full 4 MB size) with a behavioural model of the
hard IP: readyLatency-3 descriptor sinks with a 6-deep FIFO and `ready = count < 3`
(violations and overflows fail the test), read DMA bursts of random length in shuffled
order with random gaps, pipelined write DMA reads, a TX slave with random waitrequest,
and a sparse host memory with 64 scattered 4 MB chunks above 4 GB. Tests: contract
registers; H2D pattern (64 KB, 4 KB descriptors, 3 in flight); one corrupted dword
(counted, address and values captured); D2H pattern; RAM loopback (256 KB); H2D + D2H
started by one write; 4 MB + 64 KB across a chunk boundary with chunk-table wrap; three
loops of 8 KB + 32 bytes; no status record. The model's throughput figures are not
hardware numbers.

## Program and test

Needs driver **1.1** (rebuild, sign, reinstall: [../02_pcie_pio/driver](../02_pcie_pio/driver/)),
BIOS link speed Gen3 and Above 4G Decoding as for project 03, and a fan on the card.

```powershell
. ..\..\scripts\env.ps1
quartus_pgm -m jtag -o "p;output_files\dma.sof"   # about 9 minutes at 5 MHz TCK
shutdown /r /t 0                                  # warm reboot: the 64-bit BAR is assigned at boot only
# after the reboot:
..\..\host\build\fpga1768.exe probe               # BAR0 contract
..\..\host\build\fpga1768.exe dma info            # link, MPS, MRRS
..\..\host\build\fpga1768.exe dma run --mode ram --dir both --size 2M   # correctness
..\..\host\build\fpga1768.exe dma bench --csv dma_bench.csv             # full matrix
```

This is a volatile JTAG load. **Do not write the configuration flash.**

## Expected observation

- `probe`: SHELL_ID `0x444D4137` → profile `07_dma`, CAPS `0x10` (DMA), VERSION ok.
- `dma info`: link Gen3 x8, bus master on, MPS and MRRS as negotiated by the host.
- `dma run` / `bench`: every point `ok`; `fpga` GB/s grows with size and levels off for
  transfers of a few MB (about 7.1 GB/s each way on the lab host).
- The `Engine:` line shows the core clock measured against the host timer; it differs
  from 250 MHz when the host's PCIe reference clock is not exactly 100 MHz.

## Status

**Verified on hardware 2026-11-20** (PCB `M1003380-005`, ASUS X99-E): BAR0 contract,
data correct in every mode and direction, 7.105 GB/s H2D, 7.065 GB/s D2H, 13.03 GB/s
both at once. See [Results](#results) and
[lab-log/2026-11-20-dma.md](../../lab-log/2026-11-20-dma.md).

## Results

### Build (2026-11-20, Quartus Prime Pro 25.1, about 72 minutes)

| Item | Value |
|------|-------|
| `.sof` SHA-256 | `BECC4D324B2FB7985E616E543F8FE10BC4ECE12A25E10ADC226CFAB4359BE77E` |
| Logic | 35,469 / 427,200 ALMs (8 %), 58,790 registers |
| Block RAM | 2,080 / 2,713 M20K (77 %), 33,988,608 bits |
| DSP | 0 |
| Worst setup slack | +0.135 ns, core clock 250 MHz (Slow 900 mV 0 °C) |
| Worst hold slack | +0.019 ns (Fast 900 mV 0 °C) |

Three earlier compiles missed timing on the 250 MHz core clock (-0.211, -0.277,
-0.004 ns). Fixes, in order: a register FIFO in `dma_rd_beats` with a 29-bit beat
increment; an extra descriptor-build stage; replicated RAM mux selects per stage and
slice plus a routing register; registered hard-IP status inputs; a 4-copy write input
tree in front of the 16 RAM groups; a registered in-flight compare. Their bitstreams were
not loaded.

### Hardware (2026-11-20)

Host: ASUS X99-E, i7-5820K, Windows 10, driver 1.1. Negotiated: Gen3 x8, MPS 256 bytes,
MRRS 512 bytes; host buffers above 4 GB. All 104 bench points and a 62-second
bidirectional run (about 403 GB each way) verified with 0 bad dwords. Pattern mode,
`fpga` GB/s (10⁹ bytes/s, first descriptor to last completion):

| Size | H2D | D2H | both: H2D + D2H |
|------|-----|-----|-----------------|
| 4 KB | 3.146 | 4.927 | 2.775 + 4.836 = 5.549 |
| 64 KB | 6.584 | 6.832 | 6.421 + 6.406 = 12.783 |
| 1 MB | 7.068 | 7.035 | 7.008 + 6.507 = 13.014 |
| 64 MB | **7.105** | **7.065** | 7.018 + 6.516 = **13.031** |

RAM mode matches pattern mode within 0.03 GB/s. Die temperature 48.3 °C idle, 51.7 °C
after the 62-second run (fan on the heatsink).

**Core clock is not 250 MHz on this host.** The core clock is 2.5 × the PCIe reference
clock from the motherboard; on the lab host it measured 255.02 MHz against the host
timer (reference clock about 102.0 MHz, probably a BIOS BCLK setting; not checked). The
host tool converts cycles with the measured clock. With the 250 MHz timing constraint
the setup slack of +0.135 ns becomes about +0.056 ns at 3.921 ns.

Full table, interpretation and the clock measurement:
[lab-log/2026-11-20-dma.md](../../lab-log/2026-11-20-dma.md), raw data:
[lab-log/2026-11-20-dma-bench.csv](../../lab-log/2026-11-20-dma-bench.csv).

## Attribution

Board pin assignments come from `hardware/pinouts/csv/` in this repository. The hard IP
descriptor and status formats were read from the Arria 10 PCIe IP RTL shipped with
Quartus Prime Pro 25.1 (not copied). No third-party files are included.
