# Lists a BP function's bytecode in order: every object pointer it references (functions, properties) with its offset,
# so a gate's position in the function can be read. bpseq.py <UFunction hex address> ...
import sys
import struct
import re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT  # noqa: E402
import procmem as m
names = {}
for line in open(os.path.join(ROOT, r'dumps/UE4SS_ObjectDump.txt'), encoding='utf-8', errors='ignore'):
    mt = re.match(r'\[[0-9A-F]+\] (\w+) (\S+) .*?\[n: ([0-9A-F]+)\]', line)
    if mt: names.setdefault(int(mt.group(3), 16), mt.group(2).split(':')[-1].split('.')[-1])
for fa in sys.argv[1:]:
    f = int(fa, 16); data, num = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
    print('fn %x: %d bytes' % (f, num))
    if not num: continue
    code = m.read(data, num)
    i = 0
    while i < num - 8:
        v = struct.unpack_from('<Q', code, i)[0]
        if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
            try:
                n = struct.unpack('<I', m.read(v + 0x18, 4))[0]
                print('  %5d op=%02x %s' % (i, code[i - 1], names.get(n, '?%x' % n)))
                i += 8
                continue
            except OSError:
                pass
        i += 1
