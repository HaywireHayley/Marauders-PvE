# Dumps /Game/Data/FrigData: for each row, the object pointers and FName-looking values in it that name a ship or an
# interior. frigdata.py <DataTable hex address>
import sys, struct, re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    if not 0 < ln < 200: raise OSError
    return m.read(e + 2, ln * (2 if h & 1 else 1)).decode('utf-16-le' if h & 1 else 'latin-1', errors='replace').encode('ascii', 'replace').decode()
def objname(o):
    return fname(struct.unpack('<I', m.read(o + 0x18, 4))[0])
dt = int(sys.argv[1], 16)
data, num, mx = m.q(dt + 0x30), *struct.unpack('<ii', m.read(dt + 0x38, 8))
print('rowmap', hex(data), num, mx)
# TMap<FName, uint8*> element: FName(8) + ptr(8) + hash next/index (8) = 24 bytes in the sparse array
WANT = re.compile(r'Inside|Interior|Frigate|Ship', re.I)
for i in range(mx):
    e = data + i * 24
    try:
        idx = struct.unpack('<I', m.read(e, 4))[0]; row = m.q(e + 8)
        name = fname(idx)
        raw = m.read(row, 0x180)
    except (OSError, struct.error):
        continue
    found = []
    for off in range(0, len(raw) - 8, 4):
        v = struct.unpack_from('<Q', raw, off)[0]
        if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
            try:
                n = objname(v)
                if WANT.search(n): found.append('%x:%s' % (off, n))
                continue
            except (OSError, struct.error):
                pass
        low = v & 0xffffffff
        if 0 < low < 0x4000000 and (v >> 32) == 0:
            try:
                n = fname(low)
                if '/' in n and WANT.search(n): found.append('%x:%s' % (off, n))
            except (OSError, struct.error):
                pass
    print(name, found)
