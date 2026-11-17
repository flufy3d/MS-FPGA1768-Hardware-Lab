"""Probe the FT232H pin behaviour to locate the JTAG TDO input.

Bit-bang mode: drives ADBUS0/1/3 (TCK/TDI/TMS), reads all pins.
Prints which input bits move while clocking and while shifting DR.
"""

import ctypes as C
import time

DLL = r"C:\Windows\System32\ftd2xx.dll"
TCK = 0x01
TDI = 0x02
TDO = 0x04
TMS = 0x08
OUT_MASK = TCK | TDI | TMS


def check(status, name):
    if status != 0:
        raise RuntimeError(f"{name} failed: {status}")


ftdi = C.WinDLL(DLL)
handle = C.c_void_p()

ftdi.FT_Open.argtypes = [C.c_int, C.POINTER(C.c_void_p)]
ftdi.FT_Open.restype = C.c_ulong
check(ftdi.FT_Open(0, C.byref(handle)), "FT_Open")

# device info
class FT_DEVICE_LIST_INFO_NODE(C.Structure):
    _fields_ = [
        ("Flags", C.c_ulong),
        ("Type", C.c_ulong),
        ("ID", C.c_ulong),
        ("LocId", C.c_ulong),
        ("SerialNumber", C.c_char * 16),
        ("Description", C.c_char * 64),
        ("ftHandle", C.c_void_p),
    ]

node = FT_DEVICE_LIST_INFO_NODE()
ftdi.FT_GetDeviceInfo.argtypes = [C.c_void_p, C.POINTER(FT_DEVICE_LIST_INFO_NODE)]
ftdi.FT_GetDeviceInfo(handle, C.byref(node))
print("Type      :", node.Type, "(5=FT232H)")
print("ID        :", hex(node.ID))
print("Serial    :", node.SerialNumber.decode(errors="replace"))
print("Desc      :", node.Description.decode(errors="replace"))

ftdi.FT_ResetDevice.argtypes = [C.c_void_p]
check(ftdi.FT_ResetDevice(handle), "FT_ResetDevice")
time.sleep(0.1)
ftdi.FT_SetTimeouts.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong]
check(ftdi.FT_SetTimeouts(handle, 200, 200), "FT_SetTimeouts")
ftdi.FT_Purge.argtypes = [C.c_void_p, C.c_ulong]
check(ftdi.FT_Purge(handle, 3), "FT_Purge")

ftdi.FT_SetBitMode.argtypes = [C.c_void_p, C.c_ubyte, C.c_ubyte]
check(ftdi.FT_SetBitMode(handle, 0x00, 0x00), "bitmode reset")
time.sleep(0.05)
check(ftdi.FT_SetBitMode(handle, OUT_MASK, 0x01), "bitmode bb")
time.sleep(0.05)

ftdi.FT_Write.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]
ftdi.FT_Read.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong)]
written = C.c_ulong()

def wr(v):
    b = C.create_string_buffer(bytes([v]))
    check(ftdi.FT_Write(handle, b, 1, C.byref(written)), "write")

def rd():
    b = C.create_string_buffer(1)
    n = C.c_ulong()
    for _ in range(200):
        st = ftdi.FT_Read(handle, b, 1, C.byref(n))
        if st == 0 and n.value == 1:
            return b.raw[0]
        time.sleep(0.002)
    return None

# idle: all low
wr(0x00)
time.sleep(0.05)
print("idle read      : 0x%02X" % (rd() or 0))
wr(0x00 | TMS)
time.sleep(0.05)
print("TMS high read  : 0x%02X" % (rd() or 0))
wr(0x00 | TDI)
time.sleep(0.05)
print("TDI high read  : 0x%02X" % (rd() or 0))

observed = set()
for i in range(64):
    wr(TMS if i % 4 == 0 else 0)
    wr((TMS if i % 4 == 0 else 0) | TCK)
    v = rd()
    if v is not None:
        observed.add(v)
    wr(0x00)
print("values while toggling TCK:", sorted(hex(v) for v in observed))

ftdi.FT_SetBitMode(handle, 0x00, 0x00)
ftdi.FT_Close.argtypes = [C.c_void_p]
ftdi.FT_Close(handle)
