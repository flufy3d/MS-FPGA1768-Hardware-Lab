"""Minimal FTDI D2XX MPSSE/bit-bang JTAG IDCODE reader.

Used only for diagnostics: proves whether the on-board FT232H can talk to the
Arria 10 JTAG TAP, independent of Quartus' jtagd plugin ABI.

Pin mapping assumed (FT232H default MPSSE channel A):
    ADBUS0 = TCK
    ADBUS1 = TDI
    ADBUS2 = TDO   (input)
    ADBUS3 = TMS
"""

import ctypes as C
import sys
import time

DLL = r"C:\Windows\System32\ftd2xx.dll"

TCK = 0x01
TDI = 0x02
TDO = 0x04
TMS = 0x08
OUT_MASK = TCK | TDI | TMS


def check(status, name):
    if status != 0:
        raise RuntimeError(f"{name} failed: status {status}")


def main():
    ftdi = C.WinDLL(DLL)
    handle = C.c_void_p()

    ftdi.FT_Open.argtypes = [C.c_int, C.POINTER(C.c_void_p)]
    ftdi.FT_Open.restype = C.c_ulong
    check(ftdi.FT_Open(0, C.byref(handle)), "FT_Open")

    ftdi.FT_ResetDevice.argtypes = [C.c_void_p]
    check(ftdi.FT_ResetDevice(handle), "FT_ResetDevice")
    time.sleep(0.1)

    ftdi.FT_SetTimeouts.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong]
    check(ftdi.FT_SetTimeouts(handle, 500, 500), "FT_SetTimeouts")

    ftdi.FT_Purge.argtypes = [C.c_void_p, C.c_ulong]
    check(ftdi.FT_Purge(handle, 1 | 2), "FT_Purge")

    ftdi.FT_SetBitMode.argtypes = [C.c_void_p, C.c_ubyte, C.c_ubyte]
    # reset, then async bit-bang with TCK/TDI/TMS as outputs, TDO as input
    check(ftdi.FT_SetBitMode(handle, 0x00, 0x00), "FT_SetBitMode reset")
    time.sleep(0.05)
    check(ftdi.FT_SetBitMode(handle, OUT_MASK, 0x01), "FT_SetBitMode bitbang")
    time.sleep(0.05)

    ftdi.FT_Write.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]
    ftdi.FT_Read.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]

    written = C.c_ulong()

    def write_byte(value):
        buf = C.create_string_buffer(bytes([value]))
        check(ftdi.FT_Write(handle, buf, 1, C.byref(written)), "FT_Write")

    def read_byte():
        buf = C.create_string_buffer(1)
        read = C.c_ulong()
        deadline = time.time() + 0.5
        while time.time() < deadline:
            st = ftdi.FT_Read(handle, buf, 1, C.byref(read))
            if st == 0 and read.value == 1:
                return buf.raw[0]
            time.sleep(0.001)
        raise RuntimeError("FT_Read timeout")

    def clock(tms, tdi=0, cycles=1):
        """Clock `cycles` TCK pulses with constant TMS/TDI, return TDO bits."""
        bits = []
        for _ in range(cycles):
            base = (TMS if tms else 0) | (TDI if tdi else 0)
            write_byte(base & ~TCK)      # TCK low
            write_byte(base | TCK)       # TCK high
            state = read_byte()
            bits.append(1 if (state & TDO) else 0)
            write_byte(base & ~TCK)      # back to low
        return bits

    # --- reset TAP ---
    clock(tms=1, cycles=5)
    # --- run-test/idle -> select DR -> capture DR -> shift DR ---
    clock(tms=0, cycles=1)      # Run-Test/Idle
    clock(tms=1, cycles=1)      # Select-DR
    clock(tms=0, cycles=1)      # Capture-DR
    clock(tms=0, cycles=1)      # Shift-DR

    bits = [0] * 32
    for i in range(32):
        b = clock(tms=0, cycles=1)[-1]
        bits[i] = b

    clock(tms=1, cycles=2)      # Exit1-DR -> Update-DR
    clock(tms=0, cycles=1)      # Run-Test/Idle

    idcode = sum(b << i for i, b in enumerate(bits))
    print(f"raw TDO bits (LSB first): {''.join(str(b) for b in bits)}")
    print(f"IDCODE = 0x{idcode:08X}")

    ftdi.FT_SetBitMode(handle, 0x00, 0x00)
    ftdi.FT_Close.argtypes = [C.c_void_p]
    ftdi.FT_Close(handle)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}")
        sys.exit(1)
