# Finds UTF-16 strings in the game module's readable memory, with the text around them.
# strs.py <text> [<text>...]
import sys
import re
import ctypes
import ctypes.wintypes as wt
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
base = gbase.base()
class MBI(ctypes.Structure):
    _fields_ = [('BaseAddress', ctypes.c_void_p), ('AllocationBase', ctypes.c_void_p), ('AllocationProtect', wt.DWORD), ('PartitionId', wt.WORD),
                ('RegionSize', ctypes.c_size_t), ('State', wt.DWORD), ('Protect', wt.DWORD), ('Type', wt.DWORD)]
vq = m.k32.VirtualQueryEx
vq.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.POINTER(MBI), ctypes.c_size_t]
vq.restype = ctypes.c_size_t
end = base + 0xf27c000
a = base
needles = [t.encode('utf-16-le') for t in sys.argv[1:]]
while a < end:
    i = MBI()
    if not vq(m.H, ctypes.c_void_p(a), ctypes.byref(i), ctypes.sizeof(i)):
        break
    size = i.RegionSize
    if i.State == 0x1000 and i.Protect in (2, 4, 0x20, 0x40):
        try:
            raw = m.read(a, size)
        except OSError:
            raw = b''
        for n in needles:
            for hit in re.finditer(re.escape(n), raw):
                s = hit.start() - (hit.start() % 2)
                ctx = raw[max(0, s - 90):s + 170].decode('utf-16-le', errors='replace')
                print(hex(a + s - base), repr(''.join(c if 32 <= ord(c) < 127 else '|' for c in ctx)))
    a += size
