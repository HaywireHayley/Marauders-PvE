# Walks GUObjectArray (read-only) and writes every RaidGame/SIGIS UFunction: class, name, flags, thunk RVA, impl RVA.
import sys, struct, re, json
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
from capstone import *
LOG = os.path.join(GAME, r'RaidGame/Binaries/Win64/UE4SS.log')
t = open(LOG, encoding='utf-8', errors='ignore').read()
GUO = int(re.findall(r'Found GUObjectArray: (0x[0-9a-f]+)', t)[-1], 16)
base = gbase.base()
names = {}
for line in open(os.path.join(ROOT, r'dumps/UE4SS_ObjectDump.txt'), encoding='utf-8', errors='ignore'):
    mt = re.match(r'\[[0-9A-F]+\] \w+ (\S+) .*?\[n: ([0-9A-F]+)\]', line)
    if mt: names.setdefault(int(mt.group(2), 16), mt.group(1).split(':')[-1].split('.')[-1])
def nm(o):
    i = struct.unpack('<I', m.read(o + 0x18, 4))[0]; return names.get(i, '?%x' % i)
objs_ptr = m.q(GUO + 0x10); num = struct.unpack('<i', m.read(GUO + 0x10 + 0x14, 4))[0]
print('objects', num, file=sys.stderr)
chunks = {}
def item(i):
    c = i // 65536
    if c not in chunks: chunks[c] = m.q(objs_ptr + 8 * c)
    return m.q(chunks[c] + 0x18 * (i % 65536))
# class pointers for "Function" and "Class" found by name
fncls = None; out = []; classes = {}
allobj = []
for i in range(num):
    try:
        o = item(i)
        if not o: continue
        allobj.append(o)
    except OSError: pass
clsname = {}
def cname(c):
    if c not in clsname: clsname[c] = nm(c)
    return clsname[c]
md = Cs(CS_ARCH_X86, CS_MODE_64)
for o in allobj:
    try:
        c = m.q(o + 0x10)
        if cname(c) != 'Function': continue
        outer = m.q(o + 0x20); pkg = m.q(outer + 0x20)
        pn = nm(pkg)
        if pn not in ('/Script/RaidGame', '/Script/SIGISPlugin'): continue
        flags = struct.unpack('<I', m.read(o + 0xB0, 4))[0]
        if not flags & 0x400: continue   # FUNC_Native
        func = m.q(o + 0xD8); cls = outer
        cdo = m.q(cls + 0x118); vt = m.q(cdo) if cdo else 0
        # follow the exec thunk to the implementation: last call before the first ret
        code = m.read(func, 0x400); impl = None; via = ''
        for ins in md.disasm(code, func):
            if ins.mnemonic == 'ret': break
            if ins.mnemonic == 'call':
                if ins.op_str.startswith('0x'):
                    tgt = int(ins.op_str, 16)
                    if not (base + 0x1c00000 < tgt < base + 0x1d00000 or tgt - base in (0x1c38c20, 0x1c38bf0)):  # skip FFrame::Step helpers
                        impl, via = tgt, 'direct'
                else:
                    mt = re.match(r'qword ptr \[r.. \+ (0x[0-9a-f]+)\]', ins.op_str)
                    if mt and vt:
                        impl, via = m.q(vt + int(mt.group(1), 16)), 'vtable+' + mt.group(1)
        out.append(dict(cls=nm(cls), fn=nm(o), flags=flags, thunk=func - base, impl=(impl - base) if impl else None, via=via, vt=(vt - base) if vt else None))
    except OSError: pass
json.dump(out, open(sys.argv[1], 'w'), indent=0)
print('native functions', len(out), file=sys.stderr)
