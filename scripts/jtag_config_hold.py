#!/usr/bin/env python3
"""Hold a pattern on the FT232H ADBUS4-7 pins and watch the card's PCIe endpoint.

Used to find which spare FT232H pin drives FPGA nCONFIG (or power). While a
pattern is held, the script polls Windows for the card's PCIe device and prints
whether it appears.

Usage:
    python jtag_config_hold.py --pattern 15 --seconds 12
    python jtag_config_hold.py --sweep

The FT232H keeps the pins driven until the MPSSE session is closed, so the
script holds the handle open for the whole observation window.
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
        self.lib.FT_SetBitMode(self.h, 0x00, 0x00)
        time.sleep(0.02)
        self.lib.FT_SetBitMode(self.h, 0x00, 0x02)
        time.sleep(0.02)
        self.write([0x8A, 0x97, 0x8D])
        self.write([0x86, 59, 0])
        self.write([0x80, 0x00, JTAG_MASK])
        self.write([0x82, 0x00, 0x00])

    def close(self):
        self.lib.FT_SetBitMode(self.h, 0x00, 0x00)
        self.lib.FT_Close(self.h)

    def write(self, data):
        buf = C.create_string_buffer(bytes(data), len(data))
        if self.lib.FT_Write(self.h, buf, len(data), C.byref(self._w)) != 0:
            raise RuntimeError("FT_Write failed")

    def drive(self, pattern):
        self.write([0x80, (pattern << 4) & HI_MASK, JTAG_MASK | HI_MASK])

    def release(self):
        self.write([0x80, 0x00, JTAG_MASK])


def pcie_count():
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command", PS_QUERY],
        capture_output=True, text=True, timeout=30,
    )
    try:
        return int(out.stdout.strip() or "0")
    except ValueError:
        return -1


def hold_and_watch(ftdi, pattern, seconds):
    print(f"holding 0b{pattern:04b} for {seconds:.0f}s ...", flush=True)
    ftdi.drive(pattern)
    t0 = time.time()
    events = []
    while time.time() - t0 < seconds:
        n = pcie_count()
        events.append((round(time.time() - t0, 1), n))
        print(f"  t={events[-1][0]:>4}s  PCIe={n}", flush=True)
        time.sleep(1.0)
    ftdi.release()
    return events


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pattern", type=lambda s: int(s, 0), default=0xF)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--sweep", action="store_true")
    args = parser.parse_args()

    ftdi = Ftdi()
    ftdi.open()
    try:
        if args.sweep:
            for pattern in (0x1, 0x2, 0x4, 0x8, 0xF, 0x0):
                hold_and_watch(ftdi, pattern, min(args.seconds, 8))
        else:
            hold_and_watch(ftdi, args.pattern, args.seconds)
        print("---")
        print(f"final PCIe count: {pcie_count()}")
    finally:
        ftdi.close()


if __name__ == "__main__":
    raise SystemExit(main())
