# Shows how an AnimNotify stub enters the ubergraph, and the named references just after that entry point.
# bpwin.py <stub UFunction hex> <ubergraph UFunction hex> [bytes after entry]
import sys
import struct
import re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT  # noqa: E402
import procmem as m
names = {}
for line in open(os.path.join(ROOT, r'dumps/UE4SS_ObjectDump.txt'), encoding='utf-8', errors='ignore'):
    mt = re.match(r'\[[0-9A-F]+\] (\w+) (\S+) .*?\[n: ([0-9A-F]+)\]', line)
    if mt: names.setdefault(int(mt.group(3), 16), mt.group(2).split(':')[-1].split('.')[-1])
def script(f):
    f = int(f, 16); d, n = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
    return m.read(d, n)
stub = script(sys.argv[1]); print('stub', stub.hex())
entry = struct.unpack_from('<I', stub, stub.find(0x1d) + 1)[0]  # EX_IntConst
print('entry', entry)
code = script(sys.argv[2]); print('ubergraph bytes', len(code))
end = min(len(code) - 8, entry + int(sys.argv[3]) if len(sys.argv) > 3 else entry + 700)
i = entry
while i < end:
    v = struct.unpack_from('<Q', code, i)[0]
    if 0x10000000000 < v < 0x7ff000000000 and v & 7 == 0:
        try:
            n = struct.unpack('<I', m.read(v + 0x18, 4))[0]
            nm = names.get(n)
            if nm: print('  %6d op=%02x %s' % (i, code[i - 1], nm))
            i += 8
            continue
        except OSError:
            pass
    if code[i] == 0x07:  # EX_JumpIfNot
        print('  %6d JumpIfNot -> %d' % (i, struct.unpack_from('<I', code, i + 1)[0]))
    i += 1
