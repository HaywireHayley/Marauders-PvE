# Read-only: while the game loads, catches a thread inside the AES block routine (0x19fcb80-0x19fdde0) and looks for the
# decryption key schedule at its registers and on its stack. Checks each candidate against the pak index, prints the key.
#   keysample.py <seconds> <out file>
import ctypes as C, struct, subprocess, sys, time
from ctypes import wintypes as W
from Crypto.Cipher import AES
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import gbase

PAK = os.path.join(GAME, r'RaidGame/Content/Paks/pakchunk0-WindowsNoEditor.pak')
with open(PAK, 'rb') as f:
    f.seek(0, 2); n = f.tell(); f.seek(n - 300); tail = f.read()
    i = tail.rfind(struct.pack('<I', 0x5A6F12E1))
    _, off, _ = struct.unpack('<IQQ', tail[i + 4:i + 24])
    f.seek(off); block = f.read(16)


def good(key):
    p = AES.new(key, AES.MODE_ECB).decrypt(block)
    return 0 < struct.unpack('<i', p[:4])[0] < 256 and p[4:7] == b'../'


def xt(a): return ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else a << 1


def mix(col):
    a = list(col); o = bytearray(4)
    for i in range(4):
        o[i] = xt(a[i]) ^ (xt(a[(i + 1) % 4]) ^ a[(i + 1) % 4]) ^ a[(i + 2) % 4] ^ a[(i + 3) % 4]
    return bytes(o)


def candidates(buf):
    for p in range(0, len(buf) - 240, 4):
        for endian in ('<', '>'):
            w = struct.unpack_from(endian + '60I', buf, p)
            if len(set(w)) < 50: continue
            # stored as big-endian words: the bytes of a word, most significant first
            be = lambda x: struct.pack('>I', x)
            first = b''.join(be(x) for x in w[56:60])
            second = b''.join(mix(be(x)) for x in w[52:56])
            yield first + second                                  # decrypt schedule
            yield b''.join(be(x) for x in w[:8])                  # encrypt schedule


k = C.WinDLL('kernel32', use_last_error=True)
k.CreateToolhelp32Snapshot.restype = W.HANDLE; k.OpenThread.restype = W.HANDLE; k.OpenProcess.restype = W.HANDLE
k.ReadProcessMemory.argtypes = [W.HANDLE, C.c_uint64, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)]


class TE(C.Structure):
    _fields_ = [("dwSize", W.DWORD), ("u", W.DWORD), ("tid", W.DWORD), ("pid", W.DWORD), ("a", C.c_long), ("b", C.c_long), ("c", W.DWORD)]


pid = int(subprocess.check_output('tasklist /FI "IMAGENAME eq RaidGame-Win64-Shipping.exe" /FO CSV /NH', shell=True, text=True).split(',')[1].strip('"'))
hp = k.OpenProcess(0x0410, False, pid)
base = gbase.base(); lo, hi = base + 0x19fcb80, base + 0x19fdde0
s = k.CreateToolhelp32Snapshot(4, 0); te = TE(); te.dwSize = C.sizeof(TE); tids = []
ok = k.Thread32First(W.HANDLE(s), C.byref(te))
while ok:
    if te.pid == pid: tids.append(te.tid)
    ok = k.Thread32Next(W.HANDLE(s), C.byref(te))
hs = [h for h in (k.OpenThread(0x005A, False, t) for t in tids) if h]
print(len(hs), 'threads', flush=True)
raw = (C.c_ubyte * (0x4D0 + 16))(); addr = (C.addressof(raw) + 15) & ~15
buf = (C.c_ubyte * 0x4000)()


def read(a, n):
    got = C.c_size_t()
    return bytes(buf[:got.value]) if k.ReadProcessMemory(hp, a, buf, n, C.byref(got)) else b''


end = time.time() + float(sys.argv[1]); hits = 0; tried = set()
while time.time() < end:
    for h in hs:
        k.SuspendThread(W.HANDLE(h))
        C.cast(addr + 0x30, C.POINTER(W.DWORD))[0] = 0x100003
        r = k.GetThreadContext(W.HANDLE(h), C.c_void_p(addr))
        regs = struct.unpack_from('<16Q', bytes((C.c_ubyte * 0x100).from_address(addr)), 0x78)
        rip = struct.unpack_from('<Q', bytes((C.c_ubyte * 0x100).from_address(addr)), 0xF8)[0]
        inside = r and lo <= rip < hi
        blobs = []
        if inside:
            blobs = [read(regs[4], 0x4000)] + [read(x & ~3, 0x400) for x in regs]
        k.ResumeThread(W.HANDLE(h))
        if inside:
            hits += 1
            for b in blobs:
                if not b or hash(b) in tried: continue
                tried.add(hash(b))
                for c in candidates(b):
                    if good(c):
                        open(sys.argv[2], 'w').write(c.hex())
                        print('KEY FOUND, saved', flush=True)
                        sys.exit(0)
print('no key; samples inside the routine:', hits)
