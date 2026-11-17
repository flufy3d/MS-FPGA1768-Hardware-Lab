# Windows BAR0 test driver

A minimal KMDF function driver for the `projects/02_pcie_pio` endpoint
(`PCI\VEN_1172&DEV_E003`). It maps BAR0, validates the design ID register, and
exposes three IOCTLs to a small user-mode test program.

This is a **test driver**. It is self-signed and only loads with Windows test
signing enabled and Secure Boot disabled. Do not distribute it.

## Why a custom driver

`inpoutx64` is open source and signed, but its `MapPhysToLin` is documented to
work only with physical addresses below 2 GB. The endpoint's BAR0 is a 64-bit
BAR and may be assigned above 4 GB. A kernel driver using `MmMapIoSpace` handles
the full 64-bit address, and the source stays in this repository for future PCIe
peripheral work.

## Prerequisites

- Visual Studio 2022 with the C++ desktop workload (installed).
- Windows Driver Kit 10.0.22621 (installed).
- Secure Boot **disabled** in the BIOS.
- Windows test signing enabled (`bcdedit /set testsigning on`) and a reboot.

## Files

| File | Purpose |
|------|---------|
| `pcie_bar.c` | KMDF driver: maps BAR0, validates ID, IOCTL read/write |
| `pcie_bar.h` | IOCTL codes, structs, device-interface GUID |
| `pcie_bar.inf` | binds `PCI\VEN_1172&DEV_E003`, installs the KMDF service |
| `build.ps1` | compiles and links `pcie_bar.sys` with VS 2022 + WDK |
| `sign.ps1` | creates a test certificate, signs `.sys`, runs `inf2cat`, signs `.cat` |
| `enable-testsigning.ps1` | checks Secure Boot, enables test signing |
| `disable-testsigning.ps1` | turns test signing off again |
| `install.ps1` | stages/installs the driver package |
| `uninstall.ps1` | removes the driver package and test certificate |
| `..\user\pcie_bar_test.cs` | user-mode client |
| `..\user\build.ps1` | compiles the client with the in-box C# compiler |

Build outputs live in `build\` and are git-ignored.

## Step 1 — disable Secure Boot

Enter the BIOS, disable Secure Boot, save, and boot Windows. Verify:

```powershell
Confirm-SecureBootUEFI
# False
```

## Step 2 — enable test signing

From an **Administrator** PowerShell:

```powershell
.\enable-testsigning.ps1
```

Reboot. Verify:

```powershell
bcdedit /enum {current}
# look for: testsigning             Yes
Confirm-SecureBootUEFI
# False
```

## Step 3 — build

```powershell
.\build.ps1
..\user\build.ps1
```

Expected output:

```
build\pcie_bar.sys
build\pcie_bar.inf
..\user\build\pcie_bar_test.exe
```

## Step 4 — sign

From an **Administrator** PowerShell:

```powershell
.\sign.ps1
```

The script:

1. creates a self-signed code-signing certificate
   (`CN=MS-FPGA1768 Lab Test Driver`),
2. installs it into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`,
3. signs `pcie_bar.sys`,
4. runs `inf2cat` to create `pcie_bar.cat`,
5. signs `pcie_bar.cat`.

The `.pfx` and its password stay in `build\` and are git-ignored.

## Step 5 — install

From an **Administrator** PowerShell:

```powershell
.\install.ps1
```

The script refuses to continue if Secure Boot is on or test signing is off. It
stages the driver package with `pnputil`. If the card is not present yet, the
driver binds when the endpoint appears.

## Step 6 — load the FPGA design

Program the volatile bitstream and confirm the endpoint:

```powershell
..\..\..\scripts\program.ps1 -Sof ..\output_files\pcie_pio.sof
Get-PnpDevice -PresentOnly |
    Where-Object InstanceId -like 'PCI\VEN_1172&DEV_E003*'
```

The factory Microsoft image is `1414:B204`; the driver does not match it. You
must load `pcie_pio.sof` to get `1172:E003`.

## Step 7 — run the test

Read-only first:

```powershell
..\user\build\pcie_bar_test.exe
```

Then the A+B test:

```powershell
..\user\build\pcie_bar_test.exe --write
```

Expected:

```
IDs:    1172:E003
BAR0:   0x... length 0x10000 mapped=1
ID:     0x50434945
A:      0x12345678
B:      0x11111111
SUM:    0x23456789
COUNTER:0x........ then 0x........ (changing)
A+B test PASSED.
```

The counter must change between the two reads. If it does not, the design is not
running or the read path is not reaching the FPGA.

## How it works

- The INF matches `PCI\VEN_1172&DEV_E003`.
- `EvtDevicePrepareHardware` walks the translated resource list, finds the first
  memory BAR (BAR0), and maps it with `MmMapIoSpace(..., MmNonCached)`.
- It reads BAR0 + `0x40`; only `0x50434945` sets `BarValid`.
- IOCTLs:
  - `IOCTL_PCIE_BAR_GET_INFO` (`0x00222000`) returns vendor/device, BAR physical
    address, length, and `Mapped`.
  - `IOCTL_PCIE_BAR_READ32` (`0x00222004`) reads one 32-bit word.
  - `IOCTL_PCIE_BAR_WRITE32` (`0x00222008`) writes one 32-bit word; refused unless
    `BarValid` is set.
- Offsets must be 4-byte aligned and inside the mapped BAR.
- No DMA, interrupts, power-management callbacks beyond the KMDF defaults, or
  flash access.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `pnputil` rejects the package | `signtool verify /pa build\pcie_bar.cat`; test signing on; Secure Boot off |
| Device shows code 28/10/39 | Driver did not bind/start; check `Get-PnpDevice`, `pnputil /enum-devices`, Event Viewer |
| No `1172:E003` device | Card unpowered, factory image running, or `pcie_pio.sof` not loaded |
| `pcie_bar_test.exe` says no interface | Driver not installed, or device not present |
| `mapped=0` | BAR0 mapped but ID mismatch; wrong design or wrong BAR |
| `A+B test FAILED` | Check `pcie_pio.sv`, the Qsys address map, and the BAR0 offset |
| `signtool` timestamp error | The script retries without a timestamp; offline is fine for test signing |

## Uninstall and revert

From an **Administrator** PowerShell:

```powershell
.\uninstall.ps1
.\disable-testsigning.ps1
```

Reboot, then re-enable Secure Boot in the BIOS.

## Security warning

Test signing disables driver signature enforcement for the machine. Keep it on
only while developing the lab driver. The test certificate and `.pfx` are local
secrets; they are not committed and must not be distributed.

## Attribution

The driver, INF and test client are original code for this repository (MIT).
The Visual Studio and WDK toolchains are not redistributed.
