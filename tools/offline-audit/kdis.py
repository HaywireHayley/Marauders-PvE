# Kismet bytecode disassembler (UE 4.26, cooked): one line per statement, with offsets, jumps and names.
# kdis.py <UFunction hex> [from] [to]
import sys, struct
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a
def fname(i):
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    return m.read(e + 2, ln * (2 if h & 1 else 1)).decode('utf-16-le' if h & 1 else 'latin-1', errors='replace')
cache = {}
def name(p, field):  # UObject name at +0x18, FField name at +0x28
    if not p: return 'null'
    if p not in cache:
        try: cache[p] = fname(struct.unpack('<I', m.read(p + (0x28 if field else 0x18), 4))[0])
        except Exception: cache[p] = '?%x' % p
    return cache[p]

f = int(sys.argv[1], 16); d, n = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
c = m.read(d, n)

class P:
    def __init__(s, i): s.i = i
    def b(s): v = c[s.i]; s.i += 1; return v
    def u16(s): v = struct.unpack_from('<H', c, s.i)[0]; s.i += 2; return v
    def u32(s): v = struct.unpack_from('<I', c, s.i)[0]; s.i += 4; return v
    def f32(s): v = struct.unpack_from('<f', c, s.i)[0]; s.i += 4; return v
    def q(s): v = struct.unpack_from('<Q', c, s.i)[0]; s.i += 8; return v
    def fld(s): return name(s.q(), True)
    def obj(s): return name(s.q(), False)
    def args(s):
        out = []
        while c[s.i] != 0x16: out.append(s.e())
        s.i += 1
        return out
    def e(s):
        t = s.b()
        if t in (0x00, 0x01, 0x02, 0x48, 0x6C): return s.fld()
        if t == 0x04: return 'return ' + s.e()
        if t == 0x06: return 'jump %d' % s.u32()
        if t == 0x07: tgt = s.u32(); return 'if not %s jump %d' % (s.e(), tgt)
        if t == 0x09: s.u16(); s.b(); return 'assert ' + s.e()
        if t == 0x0B: return 'nothing'
        if t == 0x0F: s.q(); a = s.e(); return '%s = %s' % (a, s.e())
        if t in (0x12, 0x19, 0x1A):
            o = s.e(); s.u32(); s.q(); return '%s.%s' % (o, s.e())
        if t == 0x13: s.q(); return 'metacast(%s)' % s.e()
        if t == 0x14: a = s.e(); return '%s = %s' % (a, s.e())
        if t in (0x15, 0x16): return '<end>'
        if t == 0x17: return 'self'
        if t == 0x18: s.u32(); return s.e()
        if t == 0x1B:
            nm = fname(s.u32()); s.u32(); s.u32(); return '%s(%s)' % (nm, ', '.join(s.args()))
        if t in (0x1C, 0x46, 0x68): fn = s.obj(); return '%s(%s)' % (fn, ', '.join(s.args()))
        if t == 0x45: nm = fname(s.u32()); s.u32(); s.u32(); return '%s(%s)' % (nm, ', '.join(s.args()))
        if t == 0x1D: return str(struct.unpack('<i', struct.pack('<I', s.u32()))[0])
        if t == 0x1E: return '%g' % s.f32()
        if t == 0x1F:
            j = c.index(0, s.i); v = c[s.i:j].decode('latin-1'); s.i = j + 1; return repr(v)
        if t == 0x34:
            j = s.i
            while c[j] or c[j + 1]: j += 2
            v = c[s.i:j].decode('utf-16-le'); s.i = j + 2; return repr(v)
        if t == 0x20: return s.obj()
        if t == 0x21: nm = fname(s.u32()); s.u32(); s.u32(); return 'N"%s"' % nm
        if t in (0x22, 0x23): v = struct.unpack_from('<fff', c, s.i); s.i += 12; return str(v)
        if t == 0x24: return 'byte %d' % s.b()
        if t == 0x25: return '0'
        if t == 0x26: return '1'
        if t == 0x27: return 'true'
        if t == 0x28: return 'false'
        if t == 0x29:
            k = s.b()
            if k == 0: return 'text""'
            if k == 1: a = s.e(); s.e(); s.e(); return 'text(%s)' % a
            if k in (2, 3): return 'text(%s)' % s.e()
            if k == 4: s.q(); s.e(); return 'text(%s)' % s.e()
            return 'text?'
        if t in (0x2A, 0x2D): return 'none'
        if t == 0x2B: s.i += 40; return 'transform'
        if t == 0x2C: return str(s.b())
        if t == 0x2E: cl = s.obj(); return 'cast<%s>(%s)' % (cl, s.e())
        if t == 0x2F:
            st = s.obj(); s.u32(); out = []
            while c[s.i] != 0x30: out.append(s.e())
            s.i += 1; return '%s{%s}' % (st, ', '.join(out))
        if t == 0x31:
            a = s.e(); out = []
            while c[s.i] != 0x32: out.append(s.e())
            s.i += 1; return '%s = [%s]' % (a, ', '.join(out))
        if t in (0x39, 0x3B): # SetSet / SetMap: lvalue, count, elements (map: key, value...)
            a = s.e(); s.u32(); out = []
            while c[s.i] not in (0x3A, 0x3C): out.append(s.e())
            s.i += 1; return '%s = {%s}' % (a, ', '.join(out))
        if t in (0x3D, 0x3F, 0x65): # SetConst / MapConst / ArrayConst: property(ies), count, elements
            s.q()
            if t == 0x3F: s.q()
            s.u32(); out = []; end = {0x3D: 0x3E, 0x3F: 0x40, 0x65: 0x66}[t]
            while c[s.i] != end: out.append(s.e())
            s.i += 1; return '{%s}' % ', '.join(out)
        if t == 0x33: return s.fld()
        if t in (0x35, 0x36): return str(s.q())
        if t == 0x38: s.b(); return s.e()
        if t == 0x42: fl = s.fld(); return '%s.%s' % (s.e(), fl)
        if t in (0x43, 0x44, 0x5F, 0x60): a = s.e(); return '%s = %s' % (a, s.e())
        if t == 0x4B: return 'delegate %s' % fname(s.u32()) + ('' if s.u32() + s.u32() >= 0 else '')
        if t == 0x4C: return 'push %d' % s.u32()
        if t == 0x4D: return 'pop'
        if t == 0x4E: return 'computedjump ' + s.e()
        if t == 0x4F: return 'pop if not ' + s.e()
        if t == 0x51: return s.e()
        if t == 0x52: s.q(); return s.e()
        if t == 0x53: return 'end'
        if t in (0x5A, 0x5E, 0x50): return 'trace'
        if t == 0x5B: return 'skip %d' % s.u32()
        if t == 0x5C: a = s.e(); return '%s += %s' % (a, s.e())
        if t == 0x5D: return 'clear ' + s.e()
        if t == 0x61:
            nm = fname(s.u32()); s.u32(); s.u32(); d = s.e(); return '%s = bind(%s.%s)' % (d, s.e(), nm)
        if t == 0x62: a = s.e(); return '%s -= %s' % (a, s.e())
        if t == 0x63: fn = s.obj(); return 'broadcast %s(%s)' % (fn, ', '.join(s.args()))
        if t == 0x64: fl = s.fld(); return 'frame.%s = %s' % (fl, s.e())
        if t == 0x69:
            k = s.u16(); s.u32(); idx = s.e(); out = []
            for _ in range(k): v = s.e(); s.u32(); out.append('%s:%s' % (v, s.e()))
            return 'switch(%s){%s; default %s}' % (idx, ', '.join(out), s.e())
        if t == 0x6D: return s.fld()
        raise ValueError('token %02x at %d' % (t, s.i - 1))

a = int(sys.argv[2]) if len(sys.argv) > 2 else 0
b = int(sys.argv[3]) if len(sys.argv) > 3 else n
p = P(a)
while p.i < min(b, n):
    at = p.i
    try: txt = p.e()
    except Exception as ex: print('%6d  !! %s' % (at, ex)); break
    if len(txt) > 220: txt = txt[:220] + '...'
    print('%6d  %s' % (at, txt))
