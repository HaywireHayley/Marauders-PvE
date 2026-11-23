"""Tiny helper to read the running game's memory (read-only)."""
import ctypes
import ctypes.wintypes as wt
import struct
import subprocess

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.OpenProcess.restype = wt.HANDLE
k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]

def pid():
    out = subprocess.check_output('tasklist /FI "IMAGENAME eq RaidGame-Win64-Shipping.exe" /FO CSV /NH').decode()
    return int(out.split(',')[1].strip('"'))

H = k32.OpenProcess(0x0410, False, pid())

def read(addr, n):
    buf = ctypes.create_string_buffer(n); got = ctypes.c_size_t()
    if not k32.ReadProcessMemory(H, ctypes.c_void_p(addr), buf, n, ctypes.byref(got)):
        raise OSError('read failed at %x' % addr)
    return buf.raw[:got.value]

def q(addr):
    return struct.unpack('<Q', read(addr, 8))[0]

BASE = 0x7ff654b20000  # module base from UE4SS.log (MainExe @ ...); check after each launch
