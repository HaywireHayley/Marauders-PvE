# Finds table-based AES in the running game: the Rijndael decrypt tables, then the code that references them.
import sys, struct
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
PATS = {'Td0': struct.pack('<4I', 0x51f4a750, 0x7e416553, 0x1a17a4c3, 0x3a275e96),
        'Td0be': struct.pack('>4I', 0x51f4a750, 0x7e416553, 0x1a17a4c3, 0x3a275e96),
        'Td0ror': struct.pack('<4I', 0x5150f4a7, 0x537e4165, 0xc31a17a4, 0x963a275e),
        'Te0': struct.pack('<4I', 0xc66363a5, 0xf87c7c84, 0xee777799, 0xf67b7b8d),
        'Te0ror': struct.pack('<4I', 0xa5c66363, 0x84f87c7c, 0x99ee7777, 0x8df67b7b),
        'Sbox': bytes.fromhex('637c777bf26b6fc5'), 'InvSbox': bytes.fromhex('52096ad53036a538'),
        'Rcon': struct.pack('<4I', 0x01000000, 0x02000000, 0x04000000, 0x08000000)}
found = {}
for sec, (va, d) in image.items():
    for nm, pat in PATS.items():
        p = 0
        while True:
            p = d.find(pat, p)
            if p < 0: break
            print(nm, sec, hex(va + p)); found.setdefault(nm, []).append(va + p); p += 4
want = [a for n in ('Td0', 'Td0ror', 'InvSbox', 'Td0be') for a in found.get(n, [])]
for sec, (va, d) in image.items():
    if sec not in ('.data2', '.xcode'): continue
    # rip-relative references: scan every position for a disp32 landing on a table
    import array
    b = d
    for t in want:
        for i in range(0, len(b) - 8):
            if b[i] == 0x8d and b[i-1] in (0x48, 0x4c):  # lea r64,[rip+disp]
                if b[i+1] & 0xc7 == 5:
                    disp = struct.unpack_from('<i', b, i+2)[0]
                    if va + i + 6 + disp == t:
                        print('lea', sec, hex(va + i - 1), '->', hex(t))
