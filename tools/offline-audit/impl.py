# Re-resolves thunk -> implementation: ignores call targets shared by many thunks (frame/param helpers).
import sys, json, re, struct, collections
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
from capstone import *
base = gbase.base(); md = Cs(CS_ARCH_X86, CS_MODE_64)
d = json.load(open(sys.argv[1]))
calls = {}; freq = collections.Counter()
vts = {}
for x in d:
    code = m.read(base + x['thunk'], 0x500); cs = []
    for ins in md.disasm(code, base + x['thunk']):
        if ins.mnemonic in ('ret', 'int3'): break
        if ins.mnemonic in ('call', 'jmp') and ins.op_str.startswith('0x'):
            cs.append(('d', int(ins.op_str, 16) - base, ins.mnemonic))
        elif ins.mnemonic == 'call':
            mt = re.match(r'qword ptr \[r.. \+ (0x[0-9a-f]+)\]', ins.op_str)
            if mt: cs.append(('v', int(mt.group(1), 16), 'call'))
    calls[x['fn'] + '@' + x['cls']] = cs
    for c in set(t for k, t, _ in cs if k == 'd'): freq[c] += 1
helpers = {t for t, n in freq.items() if n >= 25}
print('helpers', [hex(h) for h in sorted(helpers)], file=sys.stderr)
for x in d:
    cs = [c for c in calls[x['fn'] + '@' + x['cls']] if not (c[0] == 'd' and c[1] in helpers)]
    x['impl'], x['via'] = None, ''
    if cs:
        k, t, mn = cs[-1]
        if k == 'd': x['impl'], x['via'] = t, mn
        else: x['via'] = 'vtable+0x%x' % t; x['vslot'] = t
json.dump(d, open(sys.argv[1], 'w'), indent=0)
