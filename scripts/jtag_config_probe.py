#!/usr/bin/env python3
"""Map the FT232H ADBUS4-7 pins to on-board side effects.

Drives each 4-bit pattern on ADBUS4-7 (as 3.3 V outputs), waits, and reports
whether the card's PCIe endpoint (1414:B204) is visible. This identifies which
spare FT232H pin controls FPGA configuration or power on the Catapult v3 board.

The script always ends by releasing the pins (high-Z) and printing the final
state, so the card can reconfigure from flash.

Usage:
    python jtag_config_probe.py [--hold SECONDS]
"""

import argparse
import ctypes as C
import subprocess
import time

DLL = r"C:\Windows\System32\ftd2xx.dll"
TCK, TDI, TMS = 0x01, 0x02, 0x08
JTAG_MASK = TCK | TDI | TMS
HI_MASK = 0xF0

PS_QUERY = (
    "(Get-CimInstance Win32_PnPEntity | "
    "Where-Object { $_.PNPDeviceID -like 'PCI\\VEN_1414*' } | "
    "Measure-Object).Count"
)


class Ftdi:
    def __init__(self):
        self.lib = C.WinDLL(DLL)
        self.h = C.c_void_p()
        lib = self.lib
        lib.FT_Open.argtypes = [C.c_int, C.POINTER(C.c_void_p)]
        lib.FT_Open.restype = C.c_ulong
        lib.FT_ResetDevice.argtypes = [C.c_void_p]
        lib.FT_SetTimeouts.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong]
        lib.FT_Purge.argtypes = [C.c_void_p, C.c_ulong]
        lib.FT_SetBitMode.argtypes = [C.c_void_p, C.c_ubyte, C.c_ubyte]
        lib.FT_Write.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]
        lib.FT_Close.argtypes = [C.c_void_p]
        self._w = C.c_ulong()

    def open(self):
        if self.lib.FT_Open(0, C.byref(self.h)) != 0:
            raise RuntimeError("FT_Open failed")
        self.lib.FT_ResetDevice(self.h)
        time.sleep(0.05)
        self.lib.FT_SetTimeouts(self.h, 200, 200)
        self.lib.FT_Purge(self.h, 3)

    def close(self):
        self.lib.FT_SetBitMode(self.h, 0x00, 0x00)
        self.lib.FT_Close(self.h)

    def write(self, data):
        buf = C.create_string_buffer(bytes(data), len(data))
        if self.lib.FT_Write(self.h, buf, len(data), C.byref(self._w)) != 0:
            raise RuntimeError("FT_Write failed")


def pcie_present() -> int:
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command", PS_QUERY],
        capture_output=True, text=True, timeout=30,
    )
    try:
        return int(out.stdout.strip() or "0")
    except ValueError:
        return -1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hold", type=float, default=2.5)
    args = parser.parse_args()

    ftdi = Ftdi()
    ftdi.open()
    try:
        ftdi.lib.FT_SetBitMode(ftdi.h, 0x00, 0x00)
        time.sleep(0.02)
        ftdi.lib.FT_SetBitMode(ftdi.h, 0x00, 0x02)
        time.sleep(0.02)
        ftdi.write([0x8A, 0x97, 0x8D])
        ftdi.write([0x86, 59, 0])
        ftdi.write([0x80, 0x00, JTAG_MASK])
        ftdi.write([0x82, 0x00, 0x00])
        time.sleep(0.02)

        print("pattern  PCIe(1414:*)  effect")
        baseline = pcie_present()
        print(f"  (idle)        {baseline}      baseline")
        for pattern in range(16):
            value = (pattern << 4) & HI_MASK
            direction = JTAG_MASK | HI_MASK
            ftdi.write([0x80, value, direction])
            time.sleep(args.hold)
            count = pcie_present()
            effect = "" if count == baseline else ("CARD GONE" if count == 0 else "card back")
            print(f"  0b{pattern:04b}        {count}       {effect}", flush=True)

        # Release, then give the card time to reconfigure from flash
        ftdi.write([0x80, 0x00, JTAG_MASK])
        time.sleep(3.0)
        final = pcie_present()
        print("---")
        print(f"after release: PCIe count = {final} (baseline {baseline})")
        return 0
    finally:
        ftdi.close()


if __name__ == "__main__":
    raise SystemExit(main())
