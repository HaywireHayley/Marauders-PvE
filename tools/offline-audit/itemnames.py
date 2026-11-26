# Writes every item row's in-game name (the row's ItemName text): itemnames.py <DataTable hex> -> assets/saves/item_names.json
# The DataTable is /SIGISPlugin/ExampleBlueprints/SIGIS_ExampleItemData; its address from the bridge:
#   lua return string.format("%x", StaticFindObject("/SIGISPlugin/ExampleBlueprints/SIGIS_ExampleItemData.SIGIS_ExampleItemData"):GetAddress())
# Row struct FInventoryDatASIGISInventoryItemStruct: ItemName (FText) at +0x30 (ForEachProperty, 2026-11-26). The FText's
# data object holds the display string as an FString pointer at +8 (checked: SafetyHelmet "Hard Hat", SterlingRifle "Mk4").
import sys
import struct
import json
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT  # noqa: E402
import procmem as m
import gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a


def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    if not 0 < ln < 200: raise OSError
    return m.read(e + 2, ln).decode('latin-1')


def fstring(p):
    data, n = m.q(p), struct.unpack('<i', m.read(p + 8, 4))[0]
    if not data or not 0 < n < 200: return None
    s = m.read(data, n * 2).decode('utf-16-le', 'replace').rstrip('\0').strip()
    return s or None


dt = int(sys.argv[1], 16)
data, num, mx = m.q(dt + 0x30), *struct.unpack('<ii', m.read(dt + 0x38, 8))
out = {}
for i in range(mx):
    e = data + i * 24
    try:
        name = fname(struct.unpack('<I', m.read(e, 4))[0]); row = m.q(e + 8)
        text = fstring(m.q(m.q(row + 0x30) + 8))
    except (OSError, struct.error, UnicodeDecodeError):
        continue
    if text:
        out[name] = text
with open(os.path.join(ROOT, 'assets', 'saves', 'item_names.json'), 'w', encoding='utf-8') as f:
    json.dump(dict(sorted(out.items())), f, indent=0, ensure_ascii=False)
print(len(out), 'of', num, 'rows named')
for n in ('SafetyHelmet', 'SterlingRifle', 'SterlingRifle_Short', '9mmAmmo', 'BAFlakVest'):
    print(n, out.get(n))
