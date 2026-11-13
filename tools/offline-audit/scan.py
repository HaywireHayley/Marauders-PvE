# Finds instructions using displacement(s) given on the command line inside the exe's code sections.
import sys, struct, re
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
from capstone import *
base = gbase.base() if hasattr(gbase,'base') else m.base()
hdr = m.read(base, 0x1000)
pe = struct.unpack_from('<I', hdr, 0x3c)[0]
nsec = struct.unpack_from('<H', hdr, pe+6)[0]; opt = struct.unpack_from('<H', hdr, pe+20)[0]
secs = []
for i in range(nsec):
    o = pe+24+opt+i*40
    name = hdr[o:o+8].rstrip(b'\0').decode(errors='ignore'); vs, va = struct.unpack_from('<II', hdr, o+8); ch = struct.unpack_from('<I', hdr, o+36)[0]
    secs.append((name, va, vs, ch))
disps = [int(x,16) for x in sys.argv[1].split(',')]
want = sys.argv[2] if len(sys.argv) > 2 else ''
md = Cs(CS_ARCH_X86, CS_MODE_64)
for name, va, vs, ch in secs:
    if not ch & 0x20000000: continue
    data = b''
    for off in range(0, vs, 0x100000):
        try: data += m.read(base+va+off, min(0x100000, vs-off))
        except OSError: data += b'\0'*min(0x100000, vs-off)
    for d in disps:
        pat = struct.pack('<I', d)
        for mt in re.finditer(re.escape(pat), data):
            p = mt.start()
            for back in range(2, 8):
                s = p-back
                ins = list(md.disasm(data[s:s+16], base+va+s, 1))
                if ins and ins[0].size >= back+4 and ('0x%x]' % d) in ins[0].op_str and (not want or re.search(want, ins[0].mnemonic+' '+ins[0].op_str)):
                    print('%s rva=%x  %s %s' % (name, va+s, ins[0].mnemonic, ins[0].op_str)); break
