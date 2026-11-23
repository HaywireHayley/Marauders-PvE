# Lists a voice set table (rows of S_VoiceSets: TArray<TSoftObjectPtr<USoundCue>>): voicerows.py <DataTable hex> [json out]
import sys
import struct
import json
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a


def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    if not 0 < ln < 400: raise OSError
    return m.read(e + 2, ln).decode('latin-1')


dt = int(sys.argv[1], 16)
data, num, mx = m.q(dt + 0x30), *struct.unpack('<ii', m.read(dt + 0x38, 8))
out = {}
for i in range(mx):
    e = data + i * 24
    try:
        idx = struct.unpack('<I', m.read(e, 4))[0]; row = m.q(e + 8); name = fname(idx)
        arr, n = m.q(row), struct.unpack('<i', m.read(row + 8, 4))[0]
        if not 0 <= n < 200: continue
    except (OSError, struct.error):
        continue
    lines = []
    for k in range(n):
        s = arr + k * 0x28
        try:
            lines.append(fname(struct.unpack('<I', m.read(s + 0x10, 4))[0]))
        except (OSError, struct.error):
            lines.append('?')
    out[name] = lines
print(num, 'rows')
for k, v in out.items():
    print(k, len(v), v[0] if v else '')
if len(sys.argv) > 2:
    json.dump(out, open(sys.argv[2], 'w'), indent=0)
