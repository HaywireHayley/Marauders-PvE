import sys
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
from capstone import *
base = gbase.base(); s = int(sys.argv[1], 16); n = int(sys.argv[2], 16)
md = Cs(CS_ARCH_X86, CS_MODE_64); md.skipdata = True
code = m.read(base + s, n)
ins = list(md.disasm(code, base + s))
for k, i in enumerate(ins):
    if '+ 0x60]' in i.op_str and i.mnemonic in ('lea', 'mov', 'cmp') and ('rbx' in i.op_str or 'rcx' in i.op_str or 'rdi' in i.op_str or 'rsi' in i.op_str or 'r14' in i.op_str or 'r15' in i.op_str):
        ctx = ' ; '.join('%s %s' % (x.mnemonic, x.op_str) for x in ins[max(0, k-3):k+6])
        print('%x' % (i.address - base), ctx[:170])
