# fpga1768 — shared host tool

> Status: Windows backend verified 2026-11-18 (PCB `M1003380-005`, ASUS X99-E, Windows 10,
> with `projects/04_pcie_hot_update`) and 2026-11-19 (with project 05, then `05_shell`).
> The core/capability/profile structure (2026-11-19) is built on Windows and Linux and
> tested offline only (`list`, `selftest`, `--help`, plus a mock BAR0 backend); not yet
> run against the card. The I2C module (`cap_i2c.c`, 2026-11-19) is tested offline against
> a mock of the project 06 register block only. The DMA module (`cap_dma.c`, 2026-11-19)
> and the driver 1.1 calls it uses are tested offline against a mock of the project 07
> engine only (`dma info`, `run`, `bench`, data-error and timeout paths); not yet run on
> the card. Linux backend built, not tested on hardware; it has no DMA support.
> Source: written for this repository

A portable C99 command-line tool for the lab's PCIe designs (vendor/device ID
`0x1172` / `0xE003`, projects 03 and up). It was written for
[04_pcie_hot_update](../projects/04_pcie_hot_update/) as `pcie_hot_update` and moved here
on 2026-11-18 so that later projects share one BAR0 access layer, one PR loader and one
temperature readout. There is **one host binary for the whole repository**; what it may do
on the card is decided at run time by the design's SHELL_ID, CAPS register and host
profile.

## Structure: core + capability modules + profiles

| Part | Files | Purpose |
|------|-------|---------|
| core | `fpga1768.c` | command line, dispatch, `list`, `probe`, `info`, `read`/`write`, `selftest` |
| | `core.c` | BAR0 access, profile selection by SHELL_ID, CAPS checks, built-in legacy profile |
| | `profile.c`, `profile.h` | INI parser, profile search path, CAPS bit names |
| | `bar_access.h`, `bar_windows.c`, `bar_linux.c` | enumerate `1172:E003`, map BAR0, link info, timing helpers |
| capability modules | `cap_temp.c` | die temperature (`temp`) |
| | `cap_pr.c` | partial reconfiguration over PCIe (`load-pr`) |
| | `cap_persona.c` | project 04 A + B persona test (`persona`) |
| | `cap_ddr.c` | DDR4 status, tests, quiesce, mailbox (`ddr ...`) |
| | `cap_flash.c` | read-only configuration flash window (`flash-dump`) |
| | `cap_i2c.c` | I2C master: scan, register reads, board sensors (`i2c ...`) |
| | `cap_retimer.c` | DS250DF810 retimer on I2C bus 1: status, CDR bypass (`retimer ...`) |
| | `cap_dma.c` | DMA throughput test: config-space MPS/MRRS, timed and verified transfers (`dma ...`) |
| profiles | `profiles/<project>.ini` | per-project SHELL_ID, CAPS and every BAR0 offset the modules use |
| | `sha256.c`, `sha256.h` | SHA-256 of loaded bitstreams and flash dumps |

Modules never hard-code a BAR0 offset; they look it up by name in the active profile
(`regs.temp`, `regs.ddr_status`, `ddr.word_bytes`, ...).

Backends: `bar_windows.c` uses the KMDF test driver in
[`../projects/02_pcie_pio/driver`](../projects/02_pcie_pio/driver/) (IOCTLs; definitions
included from its `pcie_bar.h`), link speed/width from
`DEVPKEY_PciDevice_CurrentLinkSpeed/Width`; `bar_linux.c` maps
`/sys/bus/pci/devices/<BDF>/resource0` with no kernel driver, link from
`current_link_speed/width`.

Configuration space reads (`bar_cfg_read32`) and DMA memory (`bar_dma_alloc`) need
driver interface **1.1** (2026-11-19) on Windows; a 1.0 driver answers them with
`ERROR_INVALID_FUNCTION` and the tool says to reinstall the driver. The other commands
work with either version. On Linux, configuration space comes from sysfs; DMA memory is
not implemented (it needs a kernel driver), so `dma run|bench` stop there.

## Minimal contract

Every project that ships a profile implements these three read-only registers at the start
of BAR0:

| Offset | Name | Value |
|--------|------|-------|
| `0x00` | `SHELL_ID` | identifies the project and its register-map version; must be unique per profile |
| `0x04` | `CAPS` | capability bits, below |
| `0x08` | `CAPS2` | reserved, reads `0` |

CAPS bits:

| Bit | Capability | Commands that need it |
|-----|------------|-----------------------|
| 0 | DDR4 | `ddr ...` |
| 1 | I2C | `i2c ...`, `retimer ...` |
| 2 | PR (partial reconfiguration controller) | `load-pr`, `persona` |
| 3 | flash window (read only) | `flash-dump` |
| 4 | DMA (descriptor engine, pattern generator/checker, loopback RAM) | `dma run`, `dma bench`, `dma info` |

A command whose capability bit is missing stops with exit code 3 and names the command,
the missing capability, the profile and the CAPS value, for example:

```
'flash-dump' needs flash window (CAPS bit 3), which the loaded design (profile 05_ddr4,
CAPS 0x00000005: DDR4 PR) does not have.
```

Projects 03 and 04 predate the contract (BAR0 + `0x00` is their `A` register). When no
profile matches, the core uses a **built-in legacy profile** with their register map:
`info`, `read`/`write`, `temp`, `persona` and `load-pr` behave as before (the PR commands
still check for the PR controller themselves); `ddr` and `flash-dump` are refused.

If CAPS reads `0` but the profile lists capabilities, the bitstream was built before the
CAPS register existed (the project 05 image written to the lab card's flash on
2026-11-19 is such a build); the core then uses the profile's CAPS and says so in
`info`/`probe`.

## Profiles

One INI file per project, named after the project directory:

| Profile | Project | SHELL_ID | CAPS |
|---------|---------|----------|------|
| [`profiles/05_ddr4.ini`](profiles/05_ddr4.ini) | [projects/05_ddr4](../projects/05_ddr4/) | `0x53480501` | `0x0D` DDR4, PR, flash window |
| [`profiles/06_i2c_telemetry.ini`](profiles/06_i2c_telemetry.ini) | [projects/06_i2c_telemetry](../projects/06_i2c_telemetry/) | `0x49323036` | `0x06` I2C, PR |
| [`profiles/07_dma.ini`](profiles/07_dma.ini) | [projects/07_dma](../projects/07_dma/) | `0x444D4137` | `0x10` DMA |

```ini
[profile]
name     = 05_ddr4
project  = projects/05_ddr4
shell_id = 0x53480501
caps     = 0x0000000D        ; DDR4 | PR | flash window
caps2    = 0x00000000

[regs]                       ; BAR0 offsets
shell_id = 0x0000
caps     = 0x0004
caps2    = 0x0008
temp     = 0x0050
...
[ddr]                        ; constants of one module
word_bytes = 72
...
```

Keys are looked up as `section.key`; `;` or `#` start a comment; numbers are C integers.
`probe` and `selftest` check that a profile has every key its CAPS require.

**Search path** (all directories are listed by `fpga1768 list`; the first profile with a
given name wins):

1. `FPGA1768_PROFILES` — one directory, or a list separated by `;` (Windows) or `:`
   (Linux);
2. `<exe dir>/profiles`;
3. `<exe dir>/../profiles` — this is how `host\build\fpga1768.exe` finds `host\profiles`;
4. `./profiles` and `./host/profiles` relative to the current directory.

If the tool is copied elsewhere, copy `profiles/` next to it or set `FPGA1768_PROFILES`.
`--profile NAME` (or a path to an `.ini`) forces a profile instead of matching SHELL_ID.

Adding a project: give it a unique SHELL_ID, implement CAPS/CAPS2 at `0x04`/`0x08`, copy
the closest profile to `profiles/<project>.ini`, update the offsets, then run
`fpga1768 selftest` (offline) and `fpga1768 probe` (on the card).

## Build

| OS | Build | Output |
|----|-------|--------|
| Windows | `host\build.ps1` (MinGW-w64 / MSYS2 `gcc`; the script puts the compiler's directory first on `PATH`, otherwise `cc1` can fail silently) | `host\build\fpga1768.exe` |
| Linux | `make -C host` | `host/fpga1768` |

`build.ps1` and `Makefile` list the same sources; keep them in sync when adding a module.
On Linux run it as root, with the device not bound to another driver and memory decoding
enabled (`echo 1 | sudo tee /sys/bus/pci/devices/<BDF>/enable`). Whether a Linux host
assigns the 64-bit BAR0 after a hot rescan, or only at boot like the Windows lab host,
is `unknown`.

## Commands

```
fpga1768 [--bdf BDF] [--profile NAME] <command>
  list                 list the profiles found and the search path (no device needed)
  probe                read only: SHELL_ID -> profile, CAPS/CAPS2 vs profile, profile
                       keys, and a sanity read of each capability's registers
  info                 device, link, BAR0, profile/CAPS and the common registers
  read OFF / write OFF VAL
  temp [SEC [COUNT]]   die temperature, once or every SEC seconds
  persona              [PR]    project 04: write A, B and check SUM against the persona
  load-pr FILE         [PR]    load a persona .rbf, check link/BAR0 unchanged, run persona test
  ddr status|test|quiesce|peek|poke   [DDR4]  ('ddr help')
  flash-dump FILE [MB] [FLASH] read the configuration flash (read-only window)
  i2c status|scan|read|preg|sensors|speed   [I2C]  ('i2c help')
  retimer status [CH] | bypass CH|all on|off [I2C]  ('retimer help')
  dma info | run [opts] | bench [opts]       [DMA]  ('dma help')
  selftest             offline checks (SHA-256 test vector, every profile file)
```

DMA (`dma ...`, project 07):

| Command | What it does |
|---------|--------------|
| `dma info` | driver DMA state, PCI command register, link and **MPS / MRRS / extended tags** read from the PCI Express capability in configuration space, engine constants and state |
| `dma run [--dir h2d\|d2h\|both] [--mode pattern\|ram] [--size N] [--desc N] [--loops N] [--repeat N] [--nominal-clock]` | one test point, timed and verified |
| `dma bench [--dir LIST] [--mode LIST] [--min N] [--max N] [--csv FILE]` | matrix: modes x directions x power-of-two sizes (default 4K..64M); prints die temperature before and after |

The tool allocates 4 MB common buffers from the driver, writes their bus addresses into
the engine's chunk table, starts both directions with one register write and polls the
16-byte status record the FPGA writes into host memory (no interrupts). It reports
`fpga` GB/s (first descriptor to last completion, counted by the FPGA core clock),
`app` GB/s (host `QueryPerformanceCounter` from the start write to the status record),
`data` GB/s (first to last Avalon data beat) and, for simultaneous transfers, the combined
H2D + D2H rate. GB/s = 10^9 bytes per second. The core clock is 2.5 × the PCIe reference
clock from the host board, so its real rate is measured against `QueryPerformanceCounter`
for 0.5 s at the start and used to convert cycles (`--nominal-clock` uses the 250 MHz
`CLK_HZ` register instead); on the lab host it measured 255.02 MHz (2026-11-20, see
[lab-log/2026-11-20-dma.md](../lab-log/2026-11-20-dma.md)). `pattern` mode streams to / from the
address-pattern checker and generator (any size, H2D checked in the FPGA, D2H checked in
host memory); `ram` mode uses the on-chip RAM and verifies by loopback. Details:
[projects/07_dma/README.md](../projects/07_dma/README.md).

Register maps and the DDR test options are in
[projects/05_ddr4/README.md](../projects/05_ddr4/README.md); the I2C register map in
[projects/06_i2c_telemetry/README.md](../projects/06_i2c_telemetry/README.md).

I2C commands (`BUS` is 1 or 2; addresses, registers and pages in hex; `LEN` decimal):

| Command | Bus traffic | Writes to a device |
|---------|-------------|--------------------|
| `i2c status` | none | no |
| `i2c scan BUS [FIRST LAST]` | `S addr+R byte P` per address (0x08–0x77); stops at the first timeout; refuses to start if a line reads low | no |
| `i2c read BUS ADDR REG [LEN]` | `S addr+W REG Sr addr+R data P` (1–28 bytes) | only the register pointer |
| `i2c sensors` | TMP411 `0x03 0x00 0x15 0x01 0x10`, LM25066 `0x88 0x8B 0x8D 0xD1 0xD2` | only the register pointer |
| `i2c preg BUS ADDR PAGE REG [LEN]` | `S addr+W 0xFF PAGE P`, then a read | **yes, register `0xFF`**; only for addresses in the profile's `i2c.preg_allow` |
| `i2c speed KHZ [CMD ...]` | none (sets `SCL_DIV`, kept until reload) | no |

`retimer` (profile section `[retimer]`: bus, address, channel count, `write_regs`):

| Command | Writes to the retimer |
|---------|-----------------------|
| `retimer status [CH]` | page registers only (`0xFC` channel select, `0xFF` page), restored afterwards. Prints IDs, per-quad EEPROM load status and `refclk_det`, and per channel `sigdet`, detected PRBS, `CDR_STATUS` (raw), `0x09`, `0x1E`, output selection, HEO/VEO, `0x2F` |
| `retimer bypass CH\|all on` | `0x1E[7:5]` ← `000` (raw data), then `0x09[5]` ← 1 (`REG_BYPASS_PFD_OV`); read back |
| `retimer bypass CH\|all off` | `0x09[5]` ← 0, then `0x1E[7:5]` ← `111` (register default `0xE9`); read back |

Only the registers listed in `retimer.write_regs` (`0xFC 0xFF 0x09 0x1E`) can be written;
settings are volatile in the retimer (power off restores the defaults). Register meanings:
TI datasheet SNLS513C, Tables 9–12 (checked against the PDF text, 2026-11-19). Verified on
the card 2026-11-19 (bypass on / off on all eight channels, read back).

There is deliberately no generic I2C write command: bus 2 carries the VR controller and the
hot-swap controller (AGENTS.md, section 12). `i2c sensors` converts LM25066 `READ_VIN`,
`READ_VOUT` and `READ_TEMPERATURE_1` with the DIRECT-format coefficients of the datasheet
(Table 41); `MFR_READ_IIN` (`0xD1`) and `MFR_READ_PIN` (`0xD2`) are printed raw because
their coefficients depend on the sense resistor, whose value on this card is `unknown`.
(The LM25066 NACKs the standard PMBus `READ_IIN` `0x89` and `READ_PIN` `0x97`; verified
2026-11-19.)

`write` is refused unless BAR0 + `regs.id` (`0x40`) reads `0x50434945` (same check as the
Windows driver). `load-pr` prints the file's SHA-256, the link, BAR0 and temperature before
and after, the load time and the PR status, and fails (non-zero exit) if the PR status is
not `SUCCESS` or if the link or BAR0 changed. `load-pr` does **not** quiesce the DDR ports
by itself; run `ddr quiesce on` first if a persona may have DDR traffic in flight.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | device not found / cannot open BAR0; `list`: no profile found |
| 2 | usage error, unreadable file, profile not found or missing a key |
| 3 | wrong bitstream loaded (ID, PR controller or PLL check failed), capability missing from CAPS, `probe` failed or no profile matches |
| 4 | persona test or DDR test failed (also: persona ID unknown, e.g. after `load-pr` on project 05); I2C NACK or timeout; DMA data error |
| 5 | BAR0 access error |
| 6 | PR did not start / already in progress; DDR ports did not quiesce; mailbox or abort timeout; DMA status record timeout (engine aborted) |
| 7 | PR status not `SUCCESS` |
| 8 | link, BAR0 or ID changed across a PR load |
