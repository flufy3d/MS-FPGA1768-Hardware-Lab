# fpga1768 — shared host tool

> Status: Windows backend verified 2026-11-18 (PCB `M1003380-005`, ASUS X99-E, Windows 10,
> with `projects/04_pcie_hot_update`); Linux backend built, not tested on hardware
> Source: written for this repository

A portable C99 command-line tool for the lab's PCIe designs (vendor/device ID
`0x1172` / `0xE003`, projects 03 and up). It was written for
[04_pcie_hot_update](../projects/04_pcie_hot_update/) as `pcie_hot_update` and moved here
on 2026-11-18 so that later projects share one BAR0 access layer, one PR loader and one
temperature readout. The commands of the old tool are unchanged.

## Layout

| File | Purpose |
|------|---------|
| `bar_access.h` | BAR0 access interface (aligned 32-bit reads and writes, link info, timing helpers) |
| `bar_windows.c` | Windows backend: the KMDF test driver in [`../projects/02_pcie_pio/driver`](../projects/02_pcie_pio/driver/) (IOCTLs; definitions included from its `pcie_bar.h`); link speed/width from `DEVPKEY_PciDevice_CurrentLinkSpeed/Width` |
| `bar_linux.c` | Linux backend: `mmap` of `/sys/bus/pci/devices/<BDF>/resource0`, no kernel driver; link from `current_link_speed/width` |
| `fpga1768.c` | common commands (info, read/write, temp, PR loading, project 04 persona test) |
| `ddr.c` | project 05 shell commands (DDR4 status/tests/mailbox, flash dump) |
| `tool.h` | helpers shared by the command modules |
| `sha256.c`, `sha256.h` | SHA-256 of loaded bitstreams |

## Build

| OS | Build | Output |
|----|-------|--------|
| Windows | `host\build.ps1` (MinGW-w64 / MSYS2 `gcc`; the script puts the compiler's directory first on `PATH`, otherwise `cc1` can fail silently) | `host\build\fpga1768.exe` |
| Linux | `make -C host` | `host/fpga1768` |

On Linux run it as root, with the device not bound to another driver and memory decoding
enabled (`echo 1 | sudo tee /sys/bus/pci/devices/<BDF>/enable`). Whether a Linux host
assigns the 64-bit BAR0 after a hot rescan, or only at boot like the Windows lab host,
is `unknown`.

## Commands

```
fpga1768 [--bdf BDF] <command>
  info                 device, link, BAR0 and all registers
  read OFF / write OFF VAL
  temp [SEC [COUNT]]   die temperature, once or every SEC seconds
  persona              project 04: write A, B and check SUM against the loaded persona
  load-pr FILE         load a persona .rbf, check link/BAR0 unchanged, run persona test
                       (project 05: quiesce the DDR ports first, release after)
  ddr status|test|quiesce|peek|poke   project 05 DDR4 commands ('ddr help')
  flash-dump FILE [MB] project 05: read the configuration flash (read-only window)
  selftest             offline checks (SHA-256 test vector)
```

The project 05 shell is recognised by BAR0 + `0x00` = `0x53480501`. Register maps and
the DDR test options are in [projects/05_shell/README.md](../projects/05_shell/README.md);
the shell commands are built, not tested on hardware.

`write` is refused unless BAR0 + `0x40` reads `0x50434945` (same check as the Windows
driver). `load-pr` prints the file's SHA-256, the link, BAR0 and temperature before and
after, the load time and the PR status, and fails (non-zero exit) if the PR status is not
`SUCCESS` or if the link or BAR0 changed.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | device not found / cannot open BAR0 |
| 2 | usage error or unreadable file |
| 3 | wrong bitstream loaded (ID, PR controller or PLL check failed) |
| 4 | persona test or DDR test failed |
| 5 | BAR0 access error |
| 6 | PR did not start / already in progress; DDR ports did not quiesce; mailbox or abort timeout |
| 7 | PR status not `SUCCESS` |
| 8 | link, BAR0 or ID changed across a PR load |
