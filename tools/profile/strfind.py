# Finds UTF-16 and ASCII strings in the running game and the code that references them: strfind.py <text> [<text>...]
import sys, struct
import numpy as np
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
base = gbase.base(); hdr = m.read(base, 0x1000)
pe = struct.unpack_from('<I', hdr, 0x3c)[0]; nsec = struct.unpack_from('<H', hdr, pe+6)[0]; opt = struct.unpack_from('<H', hdr, pe+20)[0]
image = {}
for i in range(nsec):
    o = pe+24+opt+i*40; name = hdr[o:o+8].rstrip(b'\0').decode(errors='ignore'); vs, va = struct.unpack_from('<II', hdr, o+8)
    data = bytearray()
    for off in range(0, vs, 0x100000):
        try: data += m.read(base+va+off, min(0x100000, vs-off))
        except OSError: data += b'\0'*min(0x100000, vs-off)
    image[name] = (va, bytes(data))
code = {}
for sec in ('.xtext', '.data2', '.arch', '.xcode'):
    if sec not in image: continue
    va, data = image[sec]
    a = np.frombuffer(data, dtype=np.uint8)
    n = len(a) - 4
    d = a[:n].astype(np.int64) | (a[1:n+1].astype(np.int64) << 8) | (a[2:n+2].astype(np.int64) << 16) | (a[3:n+3].astype(np.int64) << 24)
    d = np.where(d >= 1 << 31, d - (1 << 32), d)
    code[sec] = va + np.arange(n) + 4 + d
for text in sys.argv[1:]:
    for enc in ('utf-16-le', 'ascii'):
        pat = text.encode(enc)
        for sec, (va, data) in image.items():
            p = 0
            while True:
                p = data.find(pat, p)
                if p < 0: break
                t = va + p
                # back up to the string's start
                refs = []
                for s in code:
                    hits = np.nonzero(code[s] == t)[0]
                    refs += [hex(image[s][0] + int(h) - 3) for h in hits[:8]]
                print(repr(text), enc[:3], sec, hex(t), refs)
                p += 2
