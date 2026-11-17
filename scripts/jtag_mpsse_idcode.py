#!/usr/bin/env python3
"""Read the JTAG IDCODE of the on-board Arria 10 through the FT232H (MPSSE).

This bypasses Quartus and its jtagd plugin, so it can be used to prove whether
the FPGA JTAG TAP responds at all.

Usage:
    python jtag_mpsse_idcode.py [--speed HZ] [--raw]

Exit codes:
    0  valid IDCODE read
    1  FTDI error
    2  TAP responded, but the IDCODE is not a known Arria 10 value
    3  TDO stuck (all ones or all zeros) - no TAP response

FT232H MPSSE channel A pin assignment assumed:
    ADBUS0 TCK, ADBUS1 TDI, ADBUS2 TDO, ADBUS3 TMS
"""

import argparse
import ctypes as C
import sys
import time

DLL = r"C:\Windows\System32\ftd2xx.dll"

TCK = 0x01
TDI = 0x02
TMS = 0x08
MASK = TCK | TDI | TMS

KNOWN_IDCODES = {
    0x02E060DD: "Arria 10 10AX115",
    0x02E070DD: "Arria 10 10AX090",
    0x02E020DD: "Arria 10 10AX016/022/027",
    0x02E040DD: "Arria 10 10AX048/066",
}


def reverse_bits(byte: int) -> int:
    return int(f"{byte:08b}"[::-1], 2)


class Ftdi:
    def __init__(self):
        self.lib = C.WinDLL(DLL)
        self.handle = C.c_void_p()
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
        self._written = C.c_ulong()

    def open(self):
        status = self.lib.FT_Open(0, C.byref(self.handle))
        if status != 0:
            raise RuntimeError(f"FT_Open failed (status {status})")
        self.lib.FT_ResetDevice(self.handle)
        time.sleep(0.05)
        self.lib.FT_SetTimeouts(self.handle, 200, 200)
        self.lib.FT_Purge(self.handle, 3)

    def close(self):
        if self.handle:
            self.lib.FT_SetBitMode(self.handle, 0x00, 0x00)
            self.lib.FT_Close(self.handle)
            self.handle = C.c_void_p()

    def mpsse(self):
        self.lib.FT_SetBitMode(self.handle, 0x00, 0x00)
        time.sleep(0.02)
        self.lib.FT_SetBitMode(self.handle, 0x00, 0x02)
        time.sleep(0.02)

    def write(self, data: bytes):
        buf = C.create_string_buffer(data, len(data))
        status = self.lib.FT_Write(self.handle, buf, len(data), C.byref(self._written))
        if status != 0:
            raise RuntimeError(f"FT_Write failed (status {status})")

    def read(self, n: int, timeout: float = 0.5) -> bytes:
        buf = C.create_string_buffer(n)
        out = b""
        deadline = time.time() + timeout
        while len(out) < n and time.time() < deadline:
            got = C.c_ulong()
            status = self.lib.FT_Read(self.handle, buf, n - len(out), C.byref(got))
            if status == 0 and got.value:
                out += buf.raw[: got.value]
            else:
                time.sleep(0.001)
        return out


def scan(speed_hz: int) -> dict:
    ftdi = Ftdi()
    ftdi.open()
    try:
        ftdi.mpsse()

        # 60 MHz base clock, divisor = 60e6 / (2 * speed) - 1
        divisor = max(0, min(0xFFFF, int(60_000_000 / (2 * speed_hz)) - 1))
        ftdi.write(bytes([0x8A, 0x97, 0x8D]))                    # /5 off, adaptive off, 3-phase off
        ftdi.write(bytes([0x86, divisor & 0xFF, divisor >> 8]))  # TCK divisor
        ftdi.write(bytes([0x80, 0x00, MASK]))                    # TCK/TDI/TMS low, outputs
        ftdi.write(bytes([0x82, 0x00, 0x00]))                    # high byte all inputs
        time.sleep(0.02)
        ftdi.read(8, 0.05)                                        # drain echo

        def set_pins(value: int):
            ftdi.write(bytes([0x80, value & ~TCK & 0xFF, MASK]))

        def tms_clock(level: int, cycles: int):
            set_pins(TMS if level else 0)
            for _ in range(cycles):
                ftdi.write(bytes([0x13, 0x00, 0x00]))             # 1 bit out, -ve clock

        # TAP reset -> Run-Test/Idle -> Select-DR -> Capture-DR -> Shift-DR
        tms_clock(1, 5)
        tms_clock(0, 1)
        tms_clock(1, 1)
        tms_clock(0, 1)
        tms_clock(0, 1)

        ftdi.write(bytes([0x20, 0x03, 0x00]))                     # 4 bytes in, +ve clock
        data = ftdi.read(4, 1.0)

        tms_clock(1, 2)
        tms_clock(0, 1)

        if len(data) != 4:
            return {"error": f"short read ({len(data)} of 4 bytes)", "raw": data.hex()}

        value = sum(reverse_bits(b) << (8 * i) for i, b in enumerate(data))
        return {
            "idcode": value,
            "raw": data.hex(),
            "speed": speed_hz,
            "divisor": divisor,
        }
    finally:
        ftdi.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--speed", type=int, default=500_000, help="TCK frequency in Hz")
    parser.add_argument("--raw", action="store_true", help="print raw bytes")
    args = parser.parse_args()

    try:
        result = scan(args.speed)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}")
        return 1

    if "error" in result:
        print(f"ERROR: {result['error']} raw={result['raw']}")
        return 1

    idcode = result["idcode"]
    print(f"TCK={result['speed']} Hz divisor={result['divisor']} raw={result['raw']}")
    print(f"IDCODE=0x{idcode:08X}")

    if idcode in KNOWN_IDCODES:
        print(f"OK: {KNOWN_IDCODES[idcode]}")
        return 0
    if idcode in (0xFFFFFFFF, 0x00000000):
        print("NO RESPONSE: TDO stuck (no JTAG TAP driving the line)")
        return 3

    print("UNKNOWN IDCODE: TAP responded but the ID is not a known Arria 10")
    return 2


if __name__ == "__main__":
    sys.exit(main())
