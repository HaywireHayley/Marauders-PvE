# Finds image-relative table references ([reg+idx*4+RVA]) by searching code sections for the RVA as raw bytes.
import sys, struct
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
base = gbase.base(); hdr = m.read(base, 0x1000)
pe = struct.unpack_from('<I', hdr, 0x3c)[0]; nsec = struct.unpack_from('<H', hdr, pe+6)[0]; opt = struct.unpack_from('<H', hdr, pe+20)[0]
for i in range(nsec):
    o = pe+24+opt+i*40; name = hdr[o:o+8].rstrip(b'\0').decode(errors='ignore'); vs, va = struct.unpack_from('<II', hdr, o+8)
    if name not in ('.data2', '.xcode'): continue
    data = bytearray()
    for off in range(0, vs, 0x100000):
        try: data += m.read(base+va+off, min(0x100000, vs-off))
        except OSError: data += b'\0'*min(0x100000, vs-off)
    for t in sys.argv[1:]:
        pat = struct.pack('<I', int(t, 16)); p = 0; hits = []
        while True:
            p = data.find(pat, p)
            if p < 0: break
            hits.append(va + p); p += 1
        print(name, t, len(hits), [hex(h) for h in hits[:16]])
