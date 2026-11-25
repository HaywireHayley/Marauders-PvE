# Reads the tagged property defaults of a cooked UE4.26 blueprint's Default__ object, from its .uasset + .uexp. Read only.
# usage: ueprops.py <path without extension> [more paths]
import struct, sys, os

def fstr(b, o):
    n = struct.unpack_from('<i', b, o)[0]; o += 4
    if n == 0: return '', o
    if n < 0:
        n = -n; s = b[o:o + 2 * n - 2].decode('utf-16-le'); return s, o + 2 * n
    return b[o:o + n - 1].decode('latin-1'), o + n

def load(path):
    ua = open(path + '.uasset', 'rb').read()
    ux = open(path + '.uexp', 'rb').read()
    o = 4
    legacy = struct.unpack_from('<i', ua, o)[0]; o += 4
    if legacy != -4: o += 4
    o += 4  # FileVersionUE4
    o += 4  # FileVersionLicenseeUE4
    n = struct.unpack_from('<i', ua, o)[0]; o += 4 + n * 20
    total = struct.unpack_from('<i', ua, o)[0]; o += 4
    _, o = fstr(ua, o)
    o += 4  # PackageFlags
    ncount, noff = struct.unpack_from('<ii', ua, o); o += 8
    o += 8  # gatherable text
    ecount, eoff = struct.unpack_from('<ii', ua, o)
    names = []
    p = noff
    for _ in range(ncount):
        s, p = fstr(ua, p); p += 4; names.append(s)
    exports = []
    for i in range(ecount):
        e = eoff + i * 104
        cls, sup, tmpl, outer = struct.unpack_from('<iiii', ua, e)
        ni, nn = struct.unpack_from('<ii', ua, e + 16)
        size, off = struct.unpack_from('<qq', ua, e + 32)
        exports.append((names[ni] + ('_%d' % (nn - 1) if nn else ''), size, off - total))
    return names, ux, exports

def fname(names, b, o):
    i, n = struct.unpack_from('<ii', b, o)
    return (names[i] if 0 <= i < len(names) else '?%d' % i), o + 8

NATIVE = {'Vector', 'Rotator', 'LinearColor', 'Color', 'Transform', 'Quat', 'Vector2D', 'Guid', 'Box', 'IntPoint'}

def props(names, b, o, end, depth=0):
    out = []
    while o + 8 <= end:
        name, o = fname(names, b, o)
        if name == 'None': break
        typ, o = fname(names, b, o)
        size, idx = struct.unpack_from('<ii', b, o); o += 8
        extra = None
        if typ == 'StructProperty':
            extra, o = fname(names, b, o); o += 16
        elif typ in ('ByteProperty', 'EnumProperty'):
            extra, o = fname(names, b, o)
        elif typ == 'ArrayProperty':
            extra, o = fname(names, b, o)
        elif typ == 'BoolProperty':
            bv = b[o]; o += 1
        elif typ in ('SetProperty', 'MapProperty'):
            extra, o = fname(names, b, o)
            if typ == 'MapProperty': _, o = fname(names, b, o)
        has = b[o]; o += 1
        if has: o += 16
        val = None
        v = b[o:o + size]
        if typ == 'FloatProperty': val = round(struct.unpack('<f', v)[0], 4)
        elif typ == 'DoubleProperty': val = struct.unpack('<d', v)[0]
        elif typ == 'IntProperty': val = struct.unpack('<i', v)[0]
        elif typ == 'Int64Property': val = struct.unpack('<q', v)[0]
        elif typ == 'UInt32Property': val = struct.unpack('<I', v)[0]
        elif typ == 'BoolProperty': val = bool(bv)
        elif typ == 'NameProperty': val = names[struct.unpack_from('<i', v)[0]]
        elif typ in ('ObjectProperty', 'ClassProperty', 'SoftObjectProperty'): val = 'obj%d' % struct.unpack_from('<i', v)[0] if size >= 4 else '?'
        elif typ == 'ByteProperty':
            val = v[0] if size == 1 else names[struct.unpack_from('<i', v)[0]]
        elif typ == 'EnumProperty': val = names[struct.unpack_from('<i', v)[0]]
        elif typ == 'StructProperty':
            if extra in NATIVE:
                fl = struct.unpack('<%df' % (size // 4), v[:size // 4 * 4]) if size % 4 == 0 else v.hex()
                val = [round(x, 3) for x in fl] if isinstance(fl, tuple) else fl
            else:
                try: val = props(names, b, o, o + size, depth + 1)
                except Exception as ex: val = 'struct?' + str(ex)
        elif typ == 'ArrayProperty':
            cnt = struct.unpack_from('<i', v)[0]
            if extra in ('FloatProperty', 'IntProperty') and cnt < 64:
                val = list(struct.unpack_from('<%d%s' % (cnt, 'f' if extra == 'FloatProperty' else 'i'), v, 4))
            else: val = '%s[%d]' % (extra, cnt)
        else: val = '<%s %d bytes>' % (typ, size)
        out.append((name + ('[%d]' % idx if idx else ''), typ, val))
        o += size
    return out

def show(items, ind='    '):
    for n, t, v in items:
        if isinstance(v, list) and v and isinstance(v[0], tuple):
            print(ind + n + ' (struct):'); show(v, ind + '    ')
        else:
            print(ind + '%s = %s' % (n, v))

for path in sys.argv[1:]:
    base = os.path.basename(path)
    names, ux, exports = load(path)
    print('=== ' + base)
    for nm, size, off in exports:
        if nm == 'Default__' + base + '_C' or nm.startswith('Default__' + base):
            try:
                items = props(names, ux, off, off + size)
                show(items)
            except Exception as ex:
                print('   parse error', nm, ex)
