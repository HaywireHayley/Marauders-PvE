# Scans the bytecode of every loaded Blueprint function for calls to authority / net-mode checks.
import sys
import struct
import re
import collections
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m
t = open(os.path.join(GAME, r'RaidGame/Binaries/Win64/UE4SS.log'), encoding='utf-8', errors='ignore').read()
GUO = int(re.findall(r'Found GUObjectArray: (0x[0-9a-f]+)', t)[-1], 16)
dn = {}
for line in open(os.path.join(ROOT, r'dumps/UE4SS_ObjectDump.txt'), encoding='utf-8', errors='ignore'):
    mt = re.match(r'\[[0-9A-F]+\] \w+ (\S+) .*?\[n: ([0-9A-F]+)\]', line)
    if mt: dn.setdefault(int(mt.group(2), 16), mt.group(1).split(':')[-1].split('.')[-1])
import gbase
POOL = gbase.base() + 0x1a63226 + 0x3e6b91a   # FNamePool (from FName::ToString's lea)
_nc = {}
def fname(i):
    if i in _nc: return _nc[i]
    blk = m.q(POOL + 0x10 + 8 * (i >> 16)); e = blk + 2 * (i & 0xffff)
    h = struct.unpack('<H', m.read(e, 2))[0]; ln = h >> 6
    s = m.read(e + 2, ln * (2 if h & 1 else 1)).decode('utf-16-le' if h & 1 else 'latin-1', errors='replace')
    _nc[i] = s; return s
def nm(o):
    i = struct.unpack('<I', m.read(o + 0x18, 4))[0]
    try: return fname(i)
    except OSError: return dn.get(i, '?%x' % i)
WANT = {('KismetSystemLibrary', 'IsServer'), ('KismetSystemLibrary', 'IsDedicatedServer'), ('KismetSystemLibrary', 'IsStandalone'),
        ('Actor', 'HasAuthority'), ('Actor', 'GetLocalRole'), ('Actor', 'GetRemoteRole'), ('Pawn', 'IsLocallyControlled'),
        ('Controller', 'IsLocalController'), ('Controller', 'IsLocalPlayerController'), ('KismetSystemLibrary', 'IsPackagedForDistribution'),
        ('ActorComponent', 'GetOwnerRole'), ('Pawn', 'IsPlayerControlled'), ('GameplayStatics', 'GetPlayerController')}
objs_ptr = m.q(GUO + 0x10); num = struct.unpack('<i', m.read(GUO + 0x24, 4))[0]
chunks = {}
targets = {}; bpclasses = []
cn = {}
for i in range(num):
    try:
        c = i // 65536
        if c not in chunks: chunks[c] = m.q(objs_ptr + 8 * c)
        o = m.q(chunks[c] + 0x18 * (i % 65536))
        if not o: continue
        k = m.q(o + 0x10)
        if k not in cn: cn[k] = nm(k)
        kn = cn[k]
        if kn == 'Function':
            key = (nm(m.q(o + 0x20)), nm(o))
            if key in WANT: targets[o] = key[1]
        elif kn in ('BlueprintGeneratedClass', 'WidgetBlueprintGeneratedClass', 'AnimBlueprintGeneratedClass'):
            if not nm(o).startswith('Default__'): bpclasses.append(o)
    except OSError: pass
print('targets', sorted(set(targets.values())), 'bp classes', len(bpclasses), file=sys.stderr)
res = []
for c in bpclasses:
    try:
        f = m.q(c + 0x48); n = 0
        while f and n < 3000:
            n += 1
            data, cnt = m.q(f + 0x60), struct.unpack('<i', m.read(f + 0x68, 4))[0]
            if data and 0 < cnt < 4000000:
                code = m.read(data, cnt); hits = collections.Counter()
                for a, tn in targets.items():
                    k = code.count(struct.pack('<Q', a))
                    if k: hits[tn] += k
                if hits: res.append((nm(c), nm(f), dict(hits)))
            f = m.q(f + 0x28)
    except OSError: pass
for r in sorted(res): print('%-45s %-45s %s' % r)
