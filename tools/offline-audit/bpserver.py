# For each IsServer call in a ubergraph: what the branch is and what follows, with real names from the FName pool.
# bpserver.py <ubergraph hex>
import sys, struct, re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    return m.read(e + 2, ln * (2 if h & 1 else 1)).decode('utf-16-le' if h & 1 else 'latin-1', errors='replace')
def nm(o):
    return fname(struct.unpack('<I', m.read(o + 0x18, 4))[0]).encode('ascii', 'replace').decode()
f = int(sys.argv[1], 16); d, n = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
code = m.read(d, n)
isserver = None
sites = []
for i in range(n - 9):
    if code[i] == 0x68:
        v = struct.unpack_from('<Q', code, i + 1)[0]
        if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
            try:
                if nm(v) == 'IsServer': sites.append(i)
            except (OSError, struct.error): pass
def refs(a, b):
    out = []; i = a
    while i < min(b, n - 8):
        v = struct.unpack_from('<Q', code, i)[0]
        if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
            try:
                out.append(nm(v)); i += 8; continue
            except (OSError, struct.error, UnicodeError): pass
        i += 1
    return out
for s in sites:
    j = s + 11
    print('site %d: after call %s' % (s, code[s + 9:s + 30].hex(' ')))
    print('   before', refs(max(0, s - 60), s)[-4:])
    print('   after ', [x for x in refs(s + 9, s + 260) if not x.startswith('Temp') and not x.startswith('CallFunc') and not x.startswith('K2Node')][:12])
