#!/usr/bin/env python3
"""Soft-reset the FT232H by cycling its USB port (D2XX FT_CyclePort).

The lab card's FT232H occasionally stops driving the JTAG TDO line after a
Quartus programmer session (the chip stays enumerated but the TAP reads
0xFFFFFFFF). FT_CyclePort makes Windows unload and reload the driver for this
device, which resets the chip without a physical unplug.

Usage:
    python ftdi_cycle.py [--wait SECONDS]
"""

import argparse
import ctypes as C
import time

DLL = r"C:\Windows\System32\ftd2xx.dll"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", type=float, default=5.0)
    args = parser.parse_args()

    lib = C.WinDLL(DLL)
    handle = C.c_void_p()
    lib.FT_Open.argtypes = [C.c_int, C.POINTER(C.c_void_p)]
    lib.FT_Open.restype = C.c_ulong
    lib.FT_CyclePort.argtypes = [C.c_void_p]
    lib.FT_CyclePort.restype = C.c_ulong
    lib.FT_Close.argtypes = [C.c_void_p]

    status = lib.FT_Open(0, C.byref(handle))
    if status != 0:
        print(f"FT_Open failed: {status}")
        return 1

    print("FT_CyclePort ...")
    status = lib.FT_CyclePort(handle)
    print(f"FT_CyclePort status = {status} (0 = OK)")

    # The handle is invalid after a successful cycle
    lib.FT_Close(handle)

    time.sleep(args.wait)

    handle = C.c_void_p()
    status = lib.FT_Open(0, C.byref(handle))
    print(f"FT_Open after cycle = {status} (0 = OK)")
    if status == 0:
        lib.FT_Close(handle)
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
