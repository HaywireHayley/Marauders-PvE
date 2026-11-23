# For every native OnRep_*: does anything besides its exec thunk call its implementation? (offline nothing replicates,
# so an OnRep only runs if code calls it). Checks rel32 calls/jmps across the whole exe and pointer refs (vtables).
import sys
import json
import struct
import numpy as np
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
from capstone import *
base = gbase.base(); md = Cs(CS_ARCH_X86, CS_MODE_64)
d = json.load(open(sys.argv[1]))
reps = [x for x in d if x['fn'].startswith('OnRep_')]
impl = {}
for x in reps:
    t = x['impl']
    if not t and x.get('vslot') and x.get('vt'): t = m.q(base + x['vt'] + x['vslot']) - base
    impl[x['cls'] + '::' + x['fn']] = (t, x['thunk'])
hdr = m.read(base, 0x1000); pe = struct.unpack_from('<I', hdr, 0x3c)[0]; nsec = struct.unpack_from('<H', hdr, pe+6)[0]; opt = struct.unpack_from('<H', hdr, pe+20)[0]
targets = np.array(sorted({t for t, _ in impl.values() if t}), dtype=np.int64)
hits = {int(t): [] for t in targets}
for i in range(nsec):
    o = pe+24+opt+i*40; vs, va = struct.unpack_from('<II', hdr, o+8); ch = struct.unpack_from('<I', hdr, o+36)[0]
    buf = bytearray()
    for off in range(0, vs, 0x100000):
        try: buf += m.read(base+va+off, min(0x100000, vs-off))
        except OSError: buf += b'\0' * min(0x100000, vs-off)
    a = np.frombuffer(bytes(buf), dtype=np.uint8)
    if ch & 0x20000000:
        pos = np.nonzero((a[:-5] == 0xE8) | (a[:-5] == 0xE9))[0]
        rel = (a[pos+1].astype(np.int64) | (a[pos+2].astype(np.int64) << 8) | (a[pos+3].astype(np.int64) << 16) | (a[pos+4].astype(np.int64) << 24))
        rel = np.where(rel >= 1 << 31, rel - (1 << 32), rel); dest = va + pos + 5 + rel
        for p, dd in zip(pos[np.isin(dest, targets)], dest[np.isin(dest, targets)]): hits[int(dd)].append(('call', va + int(p)))
    # 8-byte pointers (vtable slots)
    if len(a) >= 8:
        q = np.frombuffer(bytes(buf[:len(buf) // 8 * 8]), dtype=np.uint64).astype(np.int64) - base
        for p in np.nonzero(np.isin(q, targets))[0]: hits[int(q[p])].append(('ptr', va + 8 * int(p)))
out = []
for n, (t, th) in sorted(impl.items()):
    if not t: out.append((n, 'impl unresolved (shared/empty thunk)', [])); continue
    hs = [h for h in hits.get(t, []) if not (h[0] == 'call' and th <= h[1] < th + 0x300)]
    calls = [h for h in hs if h[0] == 'call']; ptrs = [h for h in hs if h[0] == 'ptr']
    out.append((n, 'impl %x: %d direct callers, %d pointer refs' % (t, len(calls), len(ptrs)), [hex(c[1]) for c in calls[:5]]))
for n, s, c in out: print('%-60s %s %s' % (n, s, ' '.join(c)))
