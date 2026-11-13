# Any rip-relative disp32 in the code sections that lands on the given RVAs: refs.py <rva> ...
import sys, struct
import numpy as np
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
base = gbase.base(); hdr = m.read(base, 0x1000)
pe = struct.unpack_from('<I', hdr, 0x3c)[0]; nsec = struct.unpack_from('<H', hdr, pe+6)[0]; opt = struct.unpack_from('<H', hdr, pe+20)[0]
T = [int(x, 16) for x in sys.argv[1:]]
for i in range(nsec):
    o = pe+24+opt+i*40; name = hdr[o:o+8].rstrip(b'\0').decode(errors='ignore'); vs, va = struct.unpack_from('<II', hdr, o+8)
    if name not in ('.data2', '.xcode'): continue
    data = bytearray()
    for off in range(0, vs, 0x100000):
        try: data += m.read(base+va+off, min(0x100000, vs-off))
        except OSError: data += b'\0'*min(0x100000, vs-off)
    a = np.frombuffer(bytes(data), dtype=np.uint8)
    n = len(a) - 4
    d = a[:n].astype(np.int64) | (a[1:n+1].astype(np.int64) << 8) | (a[2:n+2].astype(np.int64) << 16) | (a[3:n+3].astype(np.int64) << 24)
    d = np.where(d >= 1 << 31, d - (1 << 32), d)
    dest = va + np.arange(n) + 4 + d
    for t in T:
        hits = np.nonzero((dest >= t) & (dest < t + 16))[0]
        print(name, hex(t), [hex(va + int(h)) for h in hits[:20]], len(hits))
