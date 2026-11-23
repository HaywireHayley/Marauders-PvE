"""Finds the pak AES key in the running game's memory.
Candidates: 8-byte aligned 32-byte windows in private RW memory whose four qwords all look random
(not pointers/small ints: top 16 bits non-zero, low 16 bits non-zero, all distinct). Each is checked
by decrypting the first block of the pak index (mount point "../../../")."""
import ctypes
import ctypes.wintypes as wt
import struct
import subprocess
import sys
import os; from pvepaths import GAME  # noqa: E402
import numpy as np
from Crypto.Cipher import AES

PAK = os.path.join(GAME, r'RaidGame/Content/Paks/pakchunk0-WindowsNoEditor.pak')
with open(PAK, 'rb') as f:
    f.seek(0, 2); n = f.tell(); f.seek(n - 300); tail = f.read()
    i = tail.rfind(struct.pack('<I', 0x5A6F12E1))
    _, off, _ = struct.unpack('<IQQ', tail[i + 4:i + 24])
    f.seek(off); block = f.read(16)

def ok(key):
    p = AES.new(key, AES.MODE_ECB).decrypt(block)
    return 0 < struct.unpack('<i', p[:4])[0] < 256 and p[4:7] == b'../'

pid = int(subprocess.check_output('tasklist /FI "IMAGENAME eq RaidGame-Win64-Shipping.exe" /FO CSV /NH').decode().split(',')[1].strip('"'))
k32 = ctypes.WinDLL('kernel32', use_last_error=True)
class MBI(ctypes.Structure):
    _fields_ = [('BaseAddress', ctypes.c_void_p), ('AllocationBase', ctypes.c_void_p), ('AllocationProtect', wt.DWORD),
                ('PartitionId', wt.WORD), ('RegionSize', ctypes.c_size_t), ('State', wt.DWORD), ('Protect', wt.DWORD), ('Type', wt.DWORD)]
k32.OpenProcess.restype = wt.HANDLE
k32.VirtualQueryEx.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.POINTER(MBI), ctypes.c_size_t]
k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
h = k32.OpenProcess(0x0410, False, pid)
if not h: sys.exit('OpenProcess failed %d' % ctypes.get_last_error())

addr, scanned, tried = 0, 0, 0
mbi = MBI()
while k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi)):
    base, size = mbi.BaseAddress or 0, mbi.RegionSize
    addr = base + size
    if mbi.State != 0x1000 or mbi.Protect not in (0x04, 0x40) or size > 512 << 20:  # committed RW/RWX
        continue
    buf = ctypes.create_string_buffer(size); got = ctypes.c_size_t()
    if not k32.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(got)) or got.value < 32:
        continue
    scanned += got.value
    print('region %x %d MB, scanned %d MB, tried %d' % (base, got.value >> 20, scanned >> 20, tried), flush=True)
    q = np.frombuffer(buf.raw[:got.value - got.value % 8], dtype='<u8')
    good = ((q >> np.uint64(48)) != 0) & ((q & np.uint64(0xFFFF)) != 0) & (q != np.uint64(0xFFFFFFFFFFFFFFFF))
    w = good[:-3] & good[1:-2] & good[2:-1] & good[3:]
    w &= (q[:-3] != q[1:-2]) & (q[1:-2] != q[2:-1]) & (q[:-3] != q[2:-1]) & (q[2:-1] != q[3:])
    raw = buf.raw
    for idx in np.nonzero(w)[0]:
        tried += 1
        key = raw[idx * 8: idx * 8 + 32]
        if ok(key):
            print('KEY 0x' + key.hex().upper(), 'at', hex(base + idx * 8)); sys.exit(0)
print('no key; scanned %d MB, tried %d' % (scanned >> 20, tried))
