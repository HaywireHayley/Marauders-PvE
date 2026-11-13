# Names Blueprint-event wrappers: a short native function that loads a global FName and calls FindFunctionChecked
# (0x1c312d0) then ProcessEvent. Reads the FName's index and resolves it via the object dump.
import sys, json, re, struct
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
from capstone import *
base = gbase.base(); md = Cs(CS_ARCH_X86, CS_MODE_64)
dn = {}
for line in open(os.path.join(ROOT, r'dumps/UE4SS_ObjectDump.txt'), encoding='utf-8', errors='ignore'):
    mt = re.match(r'\[[0-9A-F]+\] \w+ (\S+) .*?\[n: ([0-9A-F]+)\]', line)
    if mt: dn.setdefault(int(mt.group(2), 16), mt.group(1).split(':')[-1].split('.')[-1])
def event(rva):
    last = None
    for i in md.disasm(m.read(base + rva, 0x200), base + rva):
        mt = re.match(r'rdx, qword ptr \[rip \+ (0x[0-9a-f]+)\]', i.op_str) if i.mnemonic == 'mov' else None
        if mt: last = i.address + i.size + int(mt.group(1), 16)
        if i.mnemonic == 'call' and i.op_str.startswith('0x') and int(i.op_str, 16) - base == 0x1c312d0 and last:
            idx = struct.unpack('<I', m.read(last, 4))[0]; return dn.get(idx, '?%x' % idx)
        if i.mnemonic in ('ret', 'int3'): break
    return None
out = {}
for a in sys.argv[2:]:
    e = event(int(a, 16))
    if e: out[a] = e
json.dump(out, open(sys.argv[1], 'w'), indent=0)
for k, v in out.items(): print(k, v)
