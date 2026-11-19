# 2026-11-19 — writing the configuration flash with project 05

> Status: verified
> Source: measured on this card
> Last verified: 2026-11-19

- **Date:** 2026-11-19
- **Board:** Microsoft FPGA 1768 (Catapult v3 Longs Peak), PCB `M1003380-005`
- **Host:** ASUS X99-E, BIOS 1801, Gen3, Above 4G Decoding on, card in `PCIEX16_2` (x8),
  Windows 10 Pro 19045. Small fan on the passive heatsink.
- **Toolchain:** Quartus Prime Pro 25.1.0 Build 129 patches 0.36, on-board FT232H at
  5 MHz TCK.
- **Goal:** make the card configure itself from flash with `projects/05_shell`, so a power
  cycle no longer needs an 8-minute JTAG load. The user accepted the loss of the
  Microsoft factory image; the only requirement was that JTAG recovery stays available.

## What was done

1. Read the flash twice beforehand: 128 MB each, identical SHA-256
   `4C727C311DD7FEDBF2B23522D1DCBF152A286645BE2B1D14680898962AA9326C` (49.8 % erased).
   Kept outside the repository as `flash_a.bin` / `flash_b.bin`.
2. Built the programming file offline:
   `quartus_cpf -c -d EPCQL1024 -s 10AXF40AA -m ASx4 shell.sof shell.jic` — 18 s,
   134 217 969 bytes, SHA-256
   `A355CA324DFAF45D5972A5CDB97E963C484624829E30D20711331463F6810A02`.
3. Loaded the serial flash loader over JTAG:
   `quartus_pgm -m jtag -o "p;firmware\prebuilt\Catapult_v3_sfl.sof"` — 08:08, 0 errors,
   `Configuration succeeded`.
4. Wrote the jic:
   `quartus_pgm -m jtag -o "p;...\t6\shell.jic"` — 07:49, 0 errors, 0 warnings:

   ```
   Info (213011): Using programming file ...shell.jic with checksum 0x9FB9EB07 for device 10AXF40AA@1
   Info (209018): Device 1 silicon ID is 0x21
   Info (209044): Erasing ASP configuration device(s)
   Info (209023): Programming device(s)
   Info (19845): End Serial Flash Loader programming
   ```

5. Full AC power cycle (smart plug off for more than 15 s), then booted without any JTAG
   operation.

## Observations

- At 16:11:27 the machine booted, and Windows enumerated `1172:E003`
  (`PCIe BAR0 Test Endpoint`) **on its own** — the FPGA configured itself from the new
  flash content.
- `fpga1768 info` at 16:15:10: BAR0 `0x383FFFE00000`, Gen3 x8, ID `0x50434945`, shell ID
  `0x53480501`, temperature 46.3 °C.
- `fpga1768 ddr status`: both channels `cal SUCCESS`, persona window `0x00010101`.
- Reading the flash back after the write gives 128 MB, 41.6 % erased, SHA-256
  `17AAF5044E3B4F94CFF3C2ECB8071F7EE0BCCDDC6F2525098C3A5172EB97B63B`. That is **not** the
  last 128 MB of the `.jic` (they differ from offset 13 onward): the `.jic` is a container
  for the programmer, not a raw image. The functional boot is the real proof that the write
  is good.
- Temperature stayed at 46–48 °C throughout, including the read-back (193.8 s).

## Result

**Success.** The card now boots `projects/05_shell` from its own configuration flash: no
JTAG load after a power cycle, PCIe at Gen3 x8, both DDR4 channels calibrated.

The Microsoft factory image (`1414:B204`) is gone from this card. The raw backup is kept
for reference only; Quartus cannot convert it back into a `.jic`, so recovering the
original image would need an external SPI programmer on U19.

## Recovery path (unchanged)

If a future flash write fails, the board is still recoverable: the FT232H is powered from
the card and JTAG configuration does not depend on the flash content. Load `shell.sof` over
JTAG (8–9 minutes) and everything works again, at the cost of a JTAG load per power-up.

## Artifacts

- `shell.jic`, SHA-256 `A355CA324DFAF45D5972A5CDB97E963C484624829E30D20711331463F6810A02`
- pre-write flash dump, SHA-256 `4C727C311DD7FEDBF2B23522D1DCBF152A286645BE2B1D14680898962AA9326C`
- post-write flash dump, SHA-256 `17AAF5044E3B4F94CFF3C2ECB8071F7EE0BCCDDC6F2525098C3A5172EB97B63B`
- all three kept outside the repository in `E:\Projects\MS-FPGA1768-Lab-T4`
