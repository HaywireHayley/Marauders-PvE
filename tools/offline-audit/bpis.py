# Every IsServer call in a ubergraph, with the bytes around it, and the JumpIfNot right after. bpis.py <ubergraph hex>
import sys, struct
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m
f = int(sys.argv[1], 16); d, n = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
print('script at %x, %d bytes' % (d, n))
code = m.read(d, n)
ptrs = {}
for i in range(n - 8):
    if code[i] != 0x68: continue
    v = struct.unpack_from('<Q', code, i + 1)[0]
    if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
        ptrs.setdefault(v, []).append(i)
for v, sites in ptrs.items():
    try:
        nm = struct.unpack('<I', m.read(v + 0x18, 4))[0]
    except OSError:
        continue
    if len(sys.argv) > 2 and sites[0] != int(sys.argv[2]): continue
    if len(sites) < 3: continue
    print('fn %x name#%x sites %s' % (v, nm, sites[:12]))
