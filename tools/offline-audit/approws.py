# Lists DT_PlayerAppearance rows (heads, bodies, voices) with their mesh, slot, cost and unlock stat, from memory.
#   python -I tools/offline-audit/approws.py <DataTable address, hex>
# The address: bridge `lua return ("%x"):format(StaticFindObject("/Game/Data/DT_PlayerAppearance.DT_PlayerAppearance"):GetAddress())`.
# Row struct UnlockCosmeticData offsets (read live 2026-11-20): ItemName 8, Cosmetic 24, CosmeticSlot 72, cost 100,
# UnlockRequirementStatName 80. Modelled on voicerows.py.
import sys
import struct
import os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'scripts')); sys.path.insert(0, HERE)
import procmem as m
import gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    return m.read(e + 2, ln).decode('latin-1')
def fstr(a):
    p, n = m.q(a), struct.unpack('<i', m.read(a + 8, 4))[0]
    if not p or n <= 0 or n > 300: return ''
    return m.read(p, n * 2).decode('utf-16-le', 'replace').rstrip('\0')
dt = int(sys.argv[1], 16)
data, num, mx = m.q(dt + 0x30), *struct.unpack('<ii', m.read(dt + 0x38, 8))
rows = []
for i in range(mx):
    e = data + i * 24
    try:
        name = fname(struct.unpack('<I', m.read(e, 4))[0]); row = m.q(e + 8)
        obj = m.q(row + 24)
        mesh = fname(struct.unpack('<I', m.read(obj + 0x18, 4))[0]) if obj else '-'
        slot = m.read(row + 72, 1)[0]; cost = struct.unpack('<i', m.read(row + 100, 4))[0]
        rows.append((name, fstr(row + 8), mesh, slot, cost, fstr(row + 80)))
    except (OSError, struct.error):
        continue
def key(r):
    return (0, int(r[0])) if r[0].isdigit() else (1, r[0])
for r in sorted(rows, key=key): print('\t'.join(map(str, r)))
