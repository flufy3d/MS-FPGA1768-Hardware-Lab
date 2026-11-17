#!/usr/bin/env python3
"""Try to wake up the Arria 10 JTAG TAP by driving the FT232H's spare GPIO pins.

The Marsohod/thinkoco plugin only uses ADBUS0-3 (TCK/TDI/TDO/TMS). On this board
the remaining FT232H pins (ADBUS4-7) may be wired to FPGA configuration signals
(nCONFIG, nSTATUS, CONF_DONE, TRST#) or to buffer enables. If the TAP is held in
reset, or if the FPGA must stay unconfigured for JTAG to answer, one of those
pins is the reason.

For every 4-bit pattern the script drives ADBUS4-7 as outputs with that pattern,
then performs a full TAP reset and IDCODE read. Afterwards the pins are returned
to inputs, which lets the FPGA reconfigure from flash if a pattern asserted
nCONFIG.

Usage:
    python jtag_gpio_probe.py [--speed HZ]
"""

import argparse
import ctypes as C
import sys
import time

DLL = r"C:\Windows\System32\ftd2xx.dll"
TCK, TDI, TDO, TMS = 0x01, 0x02, 0x04, 0x08
JTAG_MASK = TCK | TDI | TMS
HI_MASK = 0xF0


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
        lib.FT_Read.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]
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

    def read(self, n, timeout=0.5):
        buf = C.create_string_buffer(n)
        out = b""
        deadline = time.time() + timeout
        while len(out) < n and time.time() < deadline:
            got = C.c_ulong()
            if self.lib.FT_Read(self.h, buf, n - len(out), C.byref(got)) == 0 and got.value:
                out += buf.raw[: got.value]
            else:
                time.sleep(0.001)
        return out


def rev(byte):
    return int(f"{byte:08b}"[::-1], 2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--speed", type=int, default=500_000)
    parser.add_argument(
        "--patterns",
        default="15",
        help="comma separated 4-bit patterns to drive on ADBUS4-7 (default: 15 = all high)",
    )
    args = parser.parse_args()
    patterns = [int(p, 0) for p in args.patterns.split(",")]

    ftdi = Ftdi()
    ftdi.open()
    state = {"hi": 0x00, "dir": JTAG_MASK}

    def apply_low(tms_level):
        value = (state["hi"] | (TMS if tms_level else 0)) & ~TCK & 0xFF
        ftdi.write([0x80, value, state["dir"]])

    def set_high_pattern(pattern):
        state["hi"] = (pattern << 4) & HI_MASK
        state["dir"] = JTAG_MASK | HI_MASK
        ftdi.write([0x80, state["hi"], state["dir"]])

    def release_high():
        state["hi"] = 0x00
        state["dir"] = JTAG_MASK
        ftdi.write([0x80, 0x00, state["dir"]])

    def tms_clock(level, cycles):
        apply_low(level)
        for _ in range(cycles):
            ftdi.write([0x13, 0x00, 0x00])

    def read_idcode():
        tms_clock(1, 5)     # Test-Logic-Reset
        tms_clock(0, 1)     # Run-Test/Idle
        tms_clock(1, 1)     # Select-DR
        tms_clock(0, 1)     # Capture-DR
        tms_clock(0, 1)     # Shift-DR
        ftdi.write([0x20, 0x03, 0x00])
        data = ftdi.read(4, 0.6)
        tms_clock(1, 2)
        tms_clock(0, 1)
        if len(data) != 4:
            return None
        return sum(rev(b) << (8 * i) for i, b in enumerate(data))

    try:
        ftdi.lib.FT_SetBitMode(ftdi.h, 0x00, 0x00)
        time.sleep(0.02)
        ftdi.lib.FT_SetBitMode(ftdi.h, 0x00, 0x02)
        time.sleep(0.02)
        ftdi.write([0x8A, 0x97, 0x8D])
        divisor = max(0, min(0xFFFF, int(60_000_000 / (2 * args.speed)) - 1))
        ftdi.write([0x86, divisor & 0xFF, divisor >> 8])
        ftdi.write([0x80, 0x00, JTAG_MASK])
        ftdi.write([0x82, 0x00, 0x00])
        time.sleep(0.02)
        ftdi.read(8, 0.05)

        print("ADBUS4-7 pattern -> IDCODE")
        good = []
        for pattern in patterns:
            set_high_pattern(pattern)
            time.sleep(0.02)
            idcode = read_idcode()
            shown = "short read" if idcode is None else f"0x{idcode:08X}"
            print(f"  0b{pattern:04b}  {shown}", flush=True)
            if idcode is not None and idcode not in (0xFFFFFFFF, 0x00000000):
                good.append((pattern, idcode))
                print("  ^^^ TAP responded")
                break
        release_high()
        print("---")
        print("TAP responses:", good if good else "none")
        return 0 if good else 3
    finally:
        ftdi.close()


if __name__ == "__main__":
    sys.exit(main())
