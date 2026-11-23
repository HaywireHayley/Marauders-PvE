# Finds direct E8/E9 rel32 calls/jumps to the given RVAs (numpy over the code sections).
import sys
import struct
import numpy as np
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
base = gbase.base(); hdr = m.read(base, 0x1000)
pe = struct.unpack_from('<I', hdr, 0x3c)[0]; nsec = struct.unpack_from('<H', hdr, pe+6)[0]; opt = struct.unpack_from('<H', hdr, pe+20)[0]
targets = np.array([int(x,16) for x in sys.argv[1:]], dtype=np.int64)
for i in range(nsec):
    o = pe+24+opt+i*40; name = hdr[o:o+8].rstrip(b'\0').decode(errors='ignore'); vs, va = struct.unpack_from('<II', hdr, o+8); ch = struct.unpack_from('<I', hdr, o+36)[0]
    if not ch & 0x20000000: continue
    data = bytearray()
    for off in range(0, vs, 0x100000):
        try: data += m.read(base+va+off, min(0x100000, vs-off))
        except OSError: data += b'\0'*min(0x100000, vs-off)
    a = np.frombuffer(bytes(data), dtype=np.uint8)
    pos = np.nonzero((a[:-5] == 0xE8) | (a[:-5] == 0xE9))[0]
    rel = (a[pos+1].astype(np.int64) | (a[pos+2].astype(np.int64) << 8) | (a[pos+3].astype(np.int64) << 16) | (a[pos+4].astype(np.int64) << 24))
    rel = np.where(rel >= 1 << 31, rel - (1 << 32), rel)
    dest = va + pos + 5 + rel
    for p in pos[np.isin(dest, targets)]:
        print('%s %s at rva %x -> %x' % (name, 'call' if a[p] == 0xE8 else 'jmp', va + p, va + p + 5 + int(rel[np.searchsorted(pos, p)])))
