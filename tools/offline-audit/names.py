# Builds rva -> name for every native: thunk, direct impl, and every vtable slot its thunk calls (via the class vtable).
import sys
import json
import re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
from capstone import *
base = gbase.base(); md = Cs(CS_ARCH_X86, CS_MODE_64)
d = json.load(open(sys.argv[1])); names = {}
for x in d:
    n = x['cls'] + '::' + x['fn']
    names.setdefault(x['thunk'], 'exec ' + n)
    if x['impl']: names[x['impl']] = n
    if x.get('vt'):
        slots = []
        for ins in md.disasm(m.read(base + x['thunk'], 0x500), base + x['thunk']):
            if ins.mnemonic in ('ret', 'int3'): break
            mt = re.match(r'qword ptr \[r.. \+ (0x[0-9a-f]+)\]', ins.op_str) if ins.mnemonic == 'call' else None
            if mt: slots.append(int(mt.group(1), 16))
        for i, s in enumerate(slots):
            try: t = m.q(base + x['vt'] + s) - base
            except OSError: continue
            if 0 < t < 0x10000000:
                suffix = '_Implementation' if i == len(slots) - 1 and len(slots) > 1 else ('_Validate' if len(slots) > 1 else '')
                names[t] = n + suffix
json.dump({hex(k): v for k, v in names.items()}, open(sys.argv[2], 'w'), indent=0)
print(len(names), 'named addresses')
