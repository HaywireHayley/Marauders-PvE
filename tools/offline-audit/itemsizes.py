# Writes every item row's type, size, stack, durability and price: itemsizes.py <DataTable hex> -> assets/saves/items.json
import sys, struct, json, os
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    if not 0 < ln < 200: raise OSError
    return m.read(e + 2, ln).decode('latin-1')
dt = int(sys.argv[1], 16)
data, num, mx = m.q(dt + 0x30), *struct.unpack('<ii', m.read(dt + 0x38, 8))
out = {}
for i in range(mx):
    e = data + i * 24
    try:
        idx = struct.unpack('<I', m.read(e, 4))[0]; row = m.q(e + 8); name = fname(idx); raw = m.read(row, 0x30)
    except (OSError, struct.error):
        continue
    out[name] = dict(type=raw[8], stackable=raw[0xb], max=struct.unpack_from('<i', raw, 0xc)[0], dur=struct.unpack_from('<i', raw, 0x10)[0],
                     w=struct.unpack_from('<H', raw, 0x14)[0], h=struct.unpack_from('<H', raw, 0x16)[0], price=struct.unpack_from('<i', raw, 0x24)[0])
os.makedirs(os.path.join(ROOT, r'assets/saves'), exist_ok=True)
json.dump(out, open(os.path.join(ROOT, r'assets/saves/items.json'), 'w'), indent=0)
print(len(out))
for n in ('PPSHSmg', 'P08Pistol', 'BrenMk2Rifle', 'SackBag', 'FreebooterBag', 'PSHHelmet', 'FullPanzerChest', '10mmAmmo', 'BandageAid', 'LargeFirstAid', 'BAFlakVest'):
    print(n, out.get(n))
