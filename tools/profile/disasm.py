import sys
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))   # noqa: E402
import procmem as m
import gbase
from capstone import *
base = gbase.base(); s = int(sys.argv[1],16); n = int(sys.argv[2],16)
md = Cs(CS_ARCH_X86, CS_MODE_64)
for i in md.disasm(m.read(base+s, n), base+s):
    t = i.op_str
    if i.mnemonic in ('call','jmp') or i.mnemonic.startswith('j'):
        try: t = 'rva %x' % (int(i.op_str,16)-base)
        except ValueError: pass
    print('%x  %-7s %s' % (i.address-base, i.mnemonic, t))
