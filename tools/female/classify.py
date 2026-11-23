# Lists every cooked skeletal mesh under an unpacked Characters folder with its skeleton and vertex bounds, to pick outfits.
#   classify.py <unpacked root>
import collections
import os
import re
import struct
import sys

root = sys.argv[1]


def lods(d):
    out, p = [], 0
    tag = struct.pack('<I', 12)
    while True:
        p = d.find(tag, p)
        if p < 0 or p + 16 > len(d): return out
        a, n, c, e = struct.unpack_from('<IIII', d, p)
        if c == 12 and n == e and 100 < n < 1000000 and p + 16 + n * 12 <= len(d):
            out.append((p + 16, n)); p += 16 + n * 12
        else:
            p += 1


rows = []
for folder, _, files in os.walk(root):
    for f in files:
        if not f.endswith('.uasset'): continue
        path = os.path.join(folder, f)
        head = open(path, 'rb').read()
        if b'\x00SkeletalMesh' not in head and b'SkeletalMesh\x00' not in head: continue
        if f.endswith('_PhysicsAsset.uasset') or f.endswith('_Skeleton.uasset'): continue
        exp = path[:-7] + '.uexp'
        if not os.path.exists(exp): continue
        d = open(exp, 'rb').read()
        found = lods(d)
        if not found: continue
        at, n = found[0]
        v = struct.unpack_from('<%df' % (n * 3), d, at)
        xs, ys, zs = v[0::3], v[1::3], v[2::3]
        sk = re.findall(rb'/Game/[A-Za-z0-9_/]*/([A-Za-z0-9_]*Skeleton)\x00', head)
        rel = os.path.relpath(path, root).replace(os.sep, '/')[:-7]
        rows.append((rel, sk[0].decode() if sk else '?', n, len(found), min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
rows.sort()
count = collections.Counter(r[1] for r in rows)
print(count.most_common())
for r in rows:
    tail = r[0].split('Characters/')[-1].replace('MainPlayer/Meshes/', '')
    if tail.startswith(('Bodies/', 'Heads/')) and r[1] == 'RaiderChar01_Skeleton' and 'Dev_' not in tail and 'Steam' not in tail: continue
    print('%-58s %-24s v%6d lod%d x%6.1f..%6.1f y%6.1f..%6.1f z%6.1f..%6.1f' % (tail[:58], r[1][:24], *r[2:]))
