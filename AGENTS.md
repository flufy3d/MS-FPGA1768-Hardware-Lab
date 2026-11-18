# AGENTS.md — maintenance rules for this repository

This file is the contract for anyone (human or AI agent) working on this project.
Read it before making changes. If a rule here conflicts with a habit, the rule wins.

---

## 1. Language

**All content in this repository is written in English.**

That includes documentation, code comments, commit messages, issue titles, file names,
README files and lab logs. Chinese (or any other language) may only appear when quoting an
original document verbatim — and then it must be followed by an English translation in the
same paragraph or table cell.

Rationale: the project is a hardware knowledge base that will be read by people who find
the board on eBay in any country. English keeps one canonical version.

## 2. Scope and non-goals

**Scope**

- Document the Microsoft FPGA 1768 / Catapult v3 "Longs Peak" card.
- Provide reproducible Quartus projects that bring the card up step by step.
- Preserve third-party research so it does not disappear.

**Non-goals**

- No support for the OCP "Dragontails Peak" variant beyond notes that help identify it.
- No attempt to run Microsoft's production workloads or Azure software.
- No redistribution of commercial tools, licence files or key generators.

## 3. Hard rules

1. **Never commit licence files, cracked binaries, key generators or patched vendor
   executables.** Toolchain problems are solved with proper licence.
2. **Never write the configuration flash without a backup and explicit user confirmation.**
   Volatile `.sof` loads only, by default. A flash write is destructive and irreversible on
   this card because the factory Microsoft image is not published.
3. **Mark what is verified.** Every hardware claim carries a status
   (`verified` / `reported` / `unknown`) and, for verified claims, the date and the board it
   was verified on.
4. **Do not invent pin numbers, addresses or part numbers.** If a value is a guess, write
   `unknown` or `hypothesis` and explain what would verify it.
5. **Keep third-party material attributed.** Vendor documents kept under `hardware/`
   name their source in the file README or NOTICE; other people's projects are linked
   from `docs/reference/links.md`, not copied into this repository.
6. **One change, one purpose.** Do not mix documentation fixes with RTL changes in a single
   commit.

## 4. Repository layout

```
README.md                  project overview, status, quick start
AGENTS.md                  this file
docs/                      written knowledge, organised by topic
  hardware/                board-level facts (clocks, power, buses, connectors)
  toolchain/               Quartus, drivers, build/program flows
  bringup/                 step-by-step procedures, numbered
  reference/               summaries of prior art and links
  demo/                    static pages published to GitHub Pages
  troubleshooting.md       symptom -> cause -> fix
hardware/                  physical artifacts
  pinouts/                 xlsx + generated csv + pinout guide
  datasheets/              vendor PDFs, named by part or reference designator
  photos/                  board and screenshots
  tools/usb-blaster/       Quartus JTAG plugin binaries (do not edit)
firmware/prebuilt/         small known-good bitstreams (SFL, recovery)
projects/NN_name/          Quartus projects maintained here
scripts/                   PowerShell helpers
lab-log/YYYY-MM-DD-*.md    dated record of physical experiments
```

Where does a new piece of information go?

| Information | Location |
|-------------|----------|
| A measured voltage, temperature, current | `lab-log/<date>-<topic>.md` + the relevant `docs/hardware/*.md` |
| A new pin or signal | `hardware/pinouts/README.md` + CSV + the relevant hardware page |
| A new Quartus design | `projects/NN_name/` with its own README |
| A fix for a tool problem | `docs/toolchain/` and, if it is a symptom, `docs/troubleshooting.md` |
| A link to someone else's work | `docs/reference/links.md` |
| An interactive model or demo | `docs/demo/` and `.github/workflows/pages.yml` |
| A failed experiment | `lab-log/` — failures are data, keep them |

## 5. Documentation conventions

Every page under `docs/` starts with a status block:

```markdown
> Status: verified | reported | unknown
> Source: <URL, spreadsheet or "measured on this card">
> Last verified: YYYY-MM-DD
```

Definitions:

- **verified** — reproduced on the physical card by a contributor, on the date given.
- **reported** — taken from prior art, a datasheet or a vendor document, not re-tested here.
- **unknown** — hypothesis or open question; must be phrased as such.

Other rules:

- Pin names: `PIN_AM17` when quoting Quartus, `AM17` in prose tables.
- Frequencies: always with units and enough digits (`644.53125 MHz`, not `644 MHz`).
- Addresses: `0x` prefix, two digits minimum (`0x22`).
- Dates: ISO 8601 (`2026-11-17`).
- Tables over prose for pin lists and address maps.
- Link to the spreadsheet instead of duplicating a 300-row table.
- Keep the "what this proves" and "if it fails" sections in bring-up pages; they are the
  most-read part.

## 6. Hardware facts registry

These are the anchors of the project. Change them only with evidence, and update every
place that references them.

| Fact | Value | Where |
|------|-------|-------|
| Board | Microsoft FPGA 1768, Catapult v3 Longs Peak | `docs/00-what-is-this-board.md` |
| FPGA | Arria 10 `10AXF40AA` (10AX115 class) | `docs/hardware/fpga.md` |
| JTAG IDCODE | `0x02E060DD` | `docs/hardware/jtag.md` |
| Board clock | 100 MHz, pin `AP20` | `docs/hardware/clocks.md` |
| LEDs | 9, pins `AM17 AH18 AJ18 AH17 AJ16 AK17 AK16 AK18 AL18`, 1.8 V | `docs/hardware/leds.md` |
| Config flash | N25Q00AA, 1 Gb, ASx4, `EPCQL1024` | `docs/hardware/fpga.md` |
| PCIe | 2 × x8 Gen3, PERST `AW16` / `AV18` | `docs/hardware/pcie.md` |
| Programmer | FT232H `0403:6014`, plugin DLL required | `docs/toolchain/onboard-usb-blaster.md` |
| Toolchain | Quartus Prime Pro 25.1 + Arria 10 package | `docs/toolchain/quartus-install.md` |

If a new measurement contradicts one of these, **do not silently overwrite it**. Add the
new measurement with its date, mark the old value as superseded, and note the discrepancy in
the lab log.

## 7. Toolchain rules

- **Version:** Quartus Prime Pro 25.1 is the reference toolchain. Projects must also compile
  with Quartus Prime Standard (Arria 10 support) where possible.
- **Paths:** never hard-code an absolute install path in a project file. Scripts discover
  Quartus via `scripts/env.ps1`.
- **Environment first:** dot-source `scripts/env.ps1` (`. .\scripts\env.ps1`) in the same
  PowerShell session before running *any* Quartus or Platform Designer tool, including
  `qsys-generate`, `qsys-script`, `qsys-edit` (GUI) and `quartus_ipgenerate`. Without
  `QUARTUS_ROOTDIR` these tools cannot resolve the `10AXF40AA` part trait and fail with
  `Error: Unknown device part 10AXF40AA` or `"Device family" "Arria 10" is out of range`.
  This is an environment problem, not a reason to switch to the GUI or to change the device.
- **Plugin:** the JTAG plugin DLL belongs in `<quartus>/bin64/`. Do not copy it into the
  repository's `bin/` or commit Quartus' own binaries.
- **Device:** use `10AXF40AA` in `.qsf`. If a tool version rejects it, fall back to
  `10AX115N4F40E3SG` and document the change in the project README.
- **IP:** commit the source `.qsys`/`.ip` file, never only the generated HDL. Regenerating IP
  in a newer Quartus is expected; record the migration in the project README.
- **No vendor installers** in git.

## 8. Build and test procedure

Before calling any change "done":

```powershell
. .\scripts\env.ps1
.\scripts\build.ps1 -Project projects\01_hello_world\hello_world.qpf
```

Checklist:

1. Compile finishes without errors.
2. `*.sta.rpt` says **"Timing requirements met"**.
3. No new critical warnings in `*.map.rpt` / `*.fit.rpt` that are not explained.
4. `jtagconfig` shows the cable and `0x02E060DD`.
5. `program.ps1` reports success.
6. The observable behaviour (LEDs, PCIe enumeration, I2C response) matches the project
   README.
7. The result is written to `lab-log/` with the date, the bitstream SHA-256 and what was
   observed.

If hardware is not available, say so explicitly in the commit message and in the README
(`Status: built, not tested on hardware`).

## 9. Project conventions

- Directory: `projects/NN_short_name/`.
- Files: `<name>.qpf`, `<name>.qsf`, `<name>.sv`, `<name>.sdc`, `README.md`.
- Top-level entity: `short_name`, lower-case with underscores.
- All user I/O explicit in the `.qsf` (location + I/O standard).
- Clocks in `.sdc` with `create_clock`; no timing constraints invented in the `.qsf`.
- `output_files/`, `db/`, `incremental_db/`, `*.qws`, `greybox_tmp/` are git-ignored.
- A project README states: purpose, pins used, how to build, how to program, expected
  observation, resource usage, and status.

## 10. Git conventions

- Commit messages: imperative mood, English, one line summary under 72 characters, optional
  body explaining *why*.
  - `Add DDR4 top-channel pinout CSV`
  - `Fix LED polarity in hello world`
- Prefixes are optional but useful: `docs:`, `hw:`, `tool:`, `project:`, `lab:`.
- Do not commit generated binaries except deliberate recovery bitstreams in
  `firmware/prebuilt/` (record SHA-256 in the README).
- Do not rewrite published history; this is a shared knowledge base.
- Large files (> 20 MB) need a reason. Prefer a link + checksum.

## 11. Lab log

Every physical experiment gets a file `lab-log/YYYY-MM-DD-<topic>.md` containing:

```markdown
# <topic>

- Date:
- Board: (serial/marking if known)
- Host: (motherboard, slot, OS)
- Toolchain: (Quartus version, plugin version)
- Goal:

## What was done
1. ...

## Observations
- ...

## Result
Success / partial / failed + explanation.

## Artifacts
- bitstream, SHA-256
- log files (paths)
```

Never delete an old lab log. If it was wrong, append a correction.

## 12. Safety

- Power off before inserting/removing the card or the auxiliary 12 V cable.
- Provide airflow whenever the card is powered for more than a few minutes.
- 1.8 V I/O: never connect 3.3 V or 5 V adapters directly to J11, the LEDs or the JTAG
  header.
- Do not probe the board with a grounded oscilloscope clip on a non-ground test point.
- The QSFP cage is not hot-swap friendly on this card; insert modules with the card off.
- Stop and ask before any action that writes flash, changes the `MP2953B` configuration, or
  drives the U22 direction pins.

## 13. Third-party material

- **Link, do not mirror.** Third-party projects (Quartus reference designs, demos, drivers)
  are listed in `docs/reference/links.md` and `docs/reference/prior-art.md` with their
  upstream URL; they are not copied into this repository.
- Vendor documents that are needed offline (datasheets, the FT232H JTAG plugin) may live
  under `hardware/`. Each folder has a `README.md` or `NOTICE.md` naming the source; do not
  relicense them. The repository's MIT licence covers only original content.
- Do not commit binaries copied from a vendor installer or a third-party release unless
  they are required for the toolchain and their origin is recorded.

## 14. Definition of done

A change is done when:

- [ ] It follows the language and status rules.
- [ ] The affected documents are updated (no orphan facts).
- [ ] Builds compile (or the untested state is stated).
- [ ] Hardware results are in `lab-log/`.
- [ ] New third-party files have attribution.
- [ ] `README.md` status table is updated if the card's state changed.
