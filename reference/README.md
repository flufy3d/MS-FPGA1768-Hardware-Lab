# Reference material (third-party mirrors)

Everything in this folder is **mirrored third-party work**, kept read-only for convenience
so that the information survives even if the original repositories disappear. Each
subfolder has a `NOTICE.md` with the original URL, author and licensing note.

| Folder | Origin | What it contains |
|--------|--------|------------------|
| `catapult-v3-smartnic-re/` | [tow3rs/catapult-v3-smartnic-re](https://github.com/tow3rs/catapult-v3-smartnic-re) | Quartus reference projects (LEDs, I2C, DDR4, PCIe, QSFP), upstream README |
| `thinkoco-microsoft-fpga/` | [thinkoco/microsoft_fpga](https://github.com/thinkoco/microsoft_fpga) | RISC-V E203 demo, PCIe/DDR4 demo driver, DMA GUI |

Deliberately **not** mirrored (too large, still available upstream):

- Microsoft Catapult V3 **OpenCL BSP 18.1** (436 MB) — see
  [docs/reference/links.md](../../docs/reference/links.md) for the URL and a summary.
- Prebuilt 36 MB OpenCL base `.sof` images.

## How to use these projects

The projects are Quartus 20.1-era. To use them with Quartus 25.1:

1. Copy the project to `projects/` first (do not edit the mirror in place).
2. Open the `.qpf` in Quartus, let it migrate the IP.
3. Regenerate any `.qsys` in Platform Designer.
4. Compile.

The pin assignments in the `.qsf` files are the valuable part and survive migration
unchanged.

## Don't edit here

Changes to files under `reference/` will be lost on the next refresh. If you improve a
reference design, copy it into `projects/` and note the origin in its README.
