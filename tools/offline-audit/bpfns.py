# Lists every UFunction referenced by a BP function's bytecode, named via the object dump's FName indices.
import sys, struct, re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m
names = {}
for line in open(os.path.join(ROOT, r'dumps/UE4SS_ObjectDump.txt'), encoding='utf-8', errors='ignore'):
    mt = re.match(r'\[[0-9A-F]+\] (\w+) (\S+) \[n: ([0-9A-F]+)\]', line)
    if mt: names.setdefault(int(mt.group(3), 16), mt.group(2).split(':')[-1].split('.')[-1])
fnclass = m.q(int(sys.argv[1], 16) + 0x10)   # class of a known UFunction
for fa in sys.argv[2:]:
    f = int(fa, 16); data, num = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
    code = m.read(data, num); seen = {}
    for i in range(num - 8):
        v = struct.unpack_from('<Q', code, i)[0]
        if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
            try:
                if m.q(v + 0x10) != fnclass: continue
                n = struct.unpack('<I', m.read(v + 0x18, 4))[0]; outer = m.q(v + 0x20); on = struct.unpack('<I', m.read(outer + 0x18, 4))[0]
                k = names.get(on, '?%x' % on) + ':' + names.get(n, '?%x' % n); seen[k] = seen.get(k, 0) + 1
            except OSError: pass
    print('fn %x (%d bytes):' % (f, num)); [print('   ', k, c) for k, c in sorted(seen.items())]
