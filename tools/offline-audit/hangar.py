# Read-only: the lobby's active ship, from the InventoryMenuWidget's ActiveFrigate pointer (+0x7B0).
# hangar.py <widget hex> ...
import sys, struct
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]
    return m.read(e + 2, (h >> 6) * (2 if h & 1 else 1)).decode('utf-16-le' if h & 1 else 'latin-1', errors='replace')
for a in sys.argv[1:]:
    w = int(a, 16); p = m.q(w + 0x7b0)
    print(a, 'ActiveFrigate', hex(p), fname(struct.unpack('<I', m.read(p + 0x18, 4))[0]) if p else 'none')
