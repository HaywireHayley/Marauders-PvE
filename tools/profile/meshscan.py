import sys
import struct
import re
d = open(sys.argv[1], 'rb').read()
print('size', len(d))
# FPositionVertexBuffer: Stride 12, NumVertices, then BulkSerialize: element size 12, count, floats
hits = []
for m in re.finditer(re.escape(struct.pack('<I', 12)), d):
    p = m.start()
    if p + 16 > len(d): continue
    a, b, c, e = struct.unpack_from('<IIII', d, p)
    if a == 12 and c == 12 and b == e and 100 < b < 500000:
        hits.append((p, b))
print(hits)
for p, n in hits:
    v = struct.unpack_from('<%df' % (n * 3), d, p + 16)
    xs, ys, zs = v[0::3], v[1::3], v[2::3]
    print(p, n, 'x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f' % (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)), 'end', p + 16 + n * 12)
