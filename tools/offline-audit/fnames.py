# Searches the running game's whole FName pool for text: every name it knows, including cooked asset names from the
# asset registry. fnames.py <text> [<text>...]
import sys
import struct
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
cur = struct.unpack('<i', m.read(POOL + 8, 4))[0]
print('blocks', cur + 1)
found = set()
for b in range(cur + 1):
    blk = m.q(POOL + 0x10 + 8 * b)
    if not blk: continue
    try:
        raw = m.read(blk, 0x20000)
    except OSError:
        continue
    i = 0
    while i < len(raw) - 2:
        h = struct.unpack_from('<H', raw, i)[0]
        wide, ln = h & 1, h >> 6
        if ln == 0: break
        size = ln * (2 if wide else 1)
        s = raw[i + 2:i + 2 + size]
        name = s.decode('utf-16-le' if wide else 'latin-1', errors='replace')
        if any(t.lower() in name.lower() for t in sys.argv[1:]):
            found.add(name.encode('ascii', 'replace').decode())
        i += 2 + size
        i = (i + 1) & ~1
print(len(found), 'names')
for n in sorted(found): print(n)
