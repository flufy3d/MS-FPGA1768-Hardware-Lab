# Static demos

> Status: unknown (design demo; the page renders, but the adapter is not built or tested)
> Source: design study for this repository, 2026-11-18
> Last verified: 2026-11-18 (page rendering only)

This folder is the artifact root for the repository's GitHub Pages site. Only static files
belong here; nothing is executed at build time.

| File | What |
|------|------|
| `index.html` | Landing page for the Pages site |
| `qsfp-dp-adapter.html` | Interactive 3D QSFP+ → DisplayPort adapter study |
| `README.md` | This note |

## The adapter demo

`qsfp-dp-adapter.html` is a self-contained page: three.js r160 and the sleeve STL are
embedded, so it works offline and needs no CDN. It is generated content from the design
study in [../hardware/qsfp-displayport-adapter.md](../hardware/qsfp-displayport-adapter.md).

The page is a **nominal envelope study**, not a manufacturable design. Its assumptions are
listed on the page itself; validate them before ordering a PCB or printing the sleeve.

## Third-party material

- **three.js r160** is bundled inside `qsfp-dp-adapter.html` under the MIT licence. The
  licence header is preserved in the file.
- The DisplayPort socket reference (HDGC DP-GD-119PWB, LCSC C7425332) is a sourcing
  candidate, not an endorsement. Vendor drawings remain under their original terms.

## Publishing

The site is deployed from this folder by `.github/workflows/pages.yml` on every push to
`main` that touches `docs/demo/`. The expected URL is:

<https://flufy3d.github.io/MS-FPGA1768-Hardware-Lab/>

To preview locally, open `index.html` in a browser; no server is required. If a browser
blocks WebGL on `file://`, serve the folder with any static HTTP server instead.
