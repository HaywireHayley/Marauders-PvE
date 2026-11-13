# Lists /SIGISPlugin/.../SIGIS_ExampleItemData by item type: itemrows.py <DataTable hex address>
import sys, struct, collections, json
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
rows = collections.defaultdict(list)
for i in range(mx):
    e = data + i * 24
    try:
        idx = struct.unpack('<I', m.read(e, 4))[0]; row = m.q(e + 8); name = fname(idx)
        raw = m.read(row, 0x30)
    except (OSError, struct.error):
        continue
    t, rar = raw[8], raw[9]
    dur = struct.unpack_from('<i', raw, 0x10)[0]; price = struct.unpack_from('<i', raw, 0x24)[0]
    rows[t].append((name, rar, dur, price))
print('rows', num)
NAMES = {0:'Rifle',1:'Pistol',2:'Melee',4:'Helmet',5:'BackPack',6:'FoldedBackPack',7:'Rig',8:'FoldedRig',9:'ChestArmour',10:'Waist',11:'Legs',12:'Feet'}
for t in sorted(rows):
    if t in NAMES:
        print(NAMES[t], len(rows[t]))
        print('  ', ' '.join(f'{n}:{p}' for n, r, d, p in sorted(rows[t], key=lambda x: x[3])))
json.dump({NAMES[t]: rows[t] for t in rows if t in NAMES}, open(os.path.join(ROOT, r'tools/offline-audit/data/itemrows.json'), 'w'))
