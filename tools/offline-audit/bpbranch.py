# Which side of each Blueprint authority / net-mode branch never runs offline, and what that side does (issue #143).
#   bpbranch.py <out.json> [<out.txt>]     (game running offline; run it in the lobby and again in raids: only loaded
#                                           Blueprints are scanned, and results are added to an existing out.json)
# Offline every actor is the authority and IsServer() is true, so `if not HasAuthority() jump T` never takes T, and
# `if not Not_PreBool(HasAuthority()) jump T` never falls through. This decodes every loaded Blueprint function (kdis),
# finds those branches, walks the never-run side (straight-line, until a pop / return / jump) and lists the calls there,
# flagging the ones that usually matter: timers (the pod's breach prompt, #77, was a K2_SetTimer on the client side),
# HUD / widget calls, effects and sounds, spawns, OnRep calls. bpauth.py says where checks are; this says what they skip.
import json
import os
import re
import struct
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pvepaths import GAME  # noqa: E402
import procmem as m  # noqa: E402
import kdis  # noqa: E402

LOG = os.path.join(GAME, r'RaidGame/Binaries/Win64/UE4SS.log')
GUO = int(re.findall(r'Found GUObjectArray: (0x[0-9a-f]+)', open(LOG, encoding='utf-8', errors='ignore').read())[-1], 16)
# Checks that are true offline. IsLocallyControlled / IsLocalController are left out: true for your own pawn offline too.
TRUE_OFFLINE = r'(HasAuthority|IsServer|IsStandalone)'  # (IsDedicatedServer is false offline: standalone isn't one)
GATE = re.compile(r'^(\w+) = (?:[\w.]+\.)?' + TRUE_OFFLINE + r'\(')
NOT = re.compile(r'^(\w+) = Not_PreBool\((\w+)\)$')
IFNOT = re.compile(r'^if not (\w+) jump (\d+)$')
CALL = re.compile(r'([A-Za-z_]\w*)\(')
# Pure helpers: not worth listing as "what the skipped side does".
DULL = re.compile(r'^(Make|Break|Conv_|Multiply_|Add_|Subtract_|Divide_|Equal|NotEqual|Not_|Less|Greater|BooleanAND|'
                  r'BooleanOR|Select|Array_|Concat_|MapRange|FClamp|Clamp|Abs|Lerp|RandomFloat|RandomInteger|IsValid|'
                  r'cast|metacast|Get[A-Z]\w*|K2_Get\w*|Default__|Vector_|Normal|VSize|RInterp|FInterp|Percent_|'
                  r'IsLocallyControlled|HasAuthority|IsServer|Delay|text|switch)')
LOUD = re.compile(r'K2_SetTimer|SetTimer|OnRep_|HUD|Widget|Prompt|SetUI|Visibility|Spawn|Play|Sound|Audio|Niagara|'
                  r'Particle|Emitter|Effect|Montage|Anim|Camera|Material|Light|Decal|Show|Hide|Open|Close|Notify')
STOP = re.compile(r'^(pop|return\b|end$|jump \d+$|computedjump)')


def walk_objects():
    """(address, class name, object name) for every live UObject."""
    objs, num = m.q(GUO + 0x10), struct.unpack('<i', m.read(GUO + 0x24, 4))[0]
    chunks, names = {}, {}
    for i in range(num):
        try:
            c = i // 65536
            if c not in chunks:
                chunks[c] = m.q(objs + 8 * c)
            o = m.q(chunks[c] + 0x18 * (i % 65536))
            if not o:
                continue
            k = m.q(o + 0x10)
            if k not in names:
                names[k] = kdis.name(k, False)
            yield o, names[k], kdis.name(o, False)
        except OSError:
            pass


def reach(stmts, index, start, limit=3000):
    """Offsets of the statements the flow can reach from start: follows jumps, both sides of a conditional, and
    push / pop (a pop returns to the last push on that path; with none it ends the path)."""
    seen, todo = set(), [(start, ())]
    while todo and len(seen) < limit:
        at, stack = todo.pop()
        i = index.get(at)
        while i is not None and i < len(stmts) and at not in seen and len(seen) < limit:
            seen.add(at)
            txt = stmts[i][1]
            j = re.match(r'^jump (\d+)$', txt)
            c = re.match(r'^if not .* jump (\d+)$', txt)
            p = re.match(r'^push (\d+)$', txt)
            if j:
                at = int(j.group(1))
                i = index.get(at)
                continue
            if c:
                todo.append((int(c.group(1)), stack))
            elif p:
                stack = stack + (int(p.group(1)),)
            elif txt == 'pop' or txt.startswith('pop if not'):
                if txt.startswith('pop if not') and i + 1 < len(stmts):
                    todo.append((stmts[i + 1][0], stack))
                if not stack:
                    break
                at, stack = stack[-1], stack[:-1]
                i = index.get(at)
                continue
            elif STOP.match(txt):
                break
            i += 1
            at = stmts[i][0] if i < len(stmts) else None
    return seen


def skipped_side(stmts, index, start, other):
    """The statements only the never-run side reaches (in order), at most 200."""
    mine = reach(stmts, index, start)
    theirs = reach(stmts, index, other) if other is not None else set()
    return [(at, txt) for at, txt in stmts if at in mine and at not in theirs][:200]


def calls(seg):
    found = []
    for _, txt in seg:
        for tm in re.finditer(r"K2_SetTimer\(self, '(\w+)'", txt):
            found.append("K2_SetTimer:" + tm.group(1))
        for cm in CALL.finditer(txt):
            n = cm.group(1)
            if not DULL.match(n) and n not in found:
                found.append(n)
    return found


def scan_function(f):
    try:
        stmts = kdis.decode(kdis.code(f))
    except (OSError, ValueError):
        return []
    if not any(GATE.match(t) for _, t in stmts):
        return []
    index = {at: i for i, (at, _) in enumerate(stmts)}
    gates, negated, hits = {}, {}, []
    for i, (at, txt) in enumerate(stmts):
        g = GATE.match(txt)
        if g:
            gates[g.group(1)] = (at, txt.split(' = ', 1)[1].split('(')[0].split('.')[-1])
            continue
        n = NOT.match(txt)
        if n and n.group(2) in gates:
            negated[n.group(1)] = gates[n.group(2)]
            continue
        b = IFNOT.match(txt)
        if not b:
            continue
        var, target = b.group(1), int(b.group(2))
        nxt = stmts[i + 1][0] if i + 1 < len(stmts) else None
        if var in gates:  # if not <true> jump T: T never runs
            side, start, other, gate = "jump target", target, nxt, gates[var]
        elif var in negated:  # if not <false> jump T: the next statement never runs
            side, start, other, gate = "fall-through", nxt, target, negated[var]
        else:
            continue
        seg = skipped_side(stmts, index, start, other) if start is not None else []
        cl = calls(seg)
        hits.append({"at": at, "check": gate[1], "skipped": side, "from": start, "calls": cl,
                     "loud": [c for c in cl if LOUD.search(c)], "lines": ["%d  %s" % (a, t[:160]) for a, t in seg[:40]]})
    return hits


def main():
    out_json = sys.argv[1]
    out_txt = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(out_json)[0] + '.txt'
    data = {}
    if os.path.exists(out_json):
        data = json.load(open(out_json, encoding='utf-8'))
    classes = [(o, n) for o, k, n in walk_objects()
               if k in ('BlueprintGeneratedClass', 'WidgetBlueprintGeneratedClass', 'AnimBlueprintGeneratedClass')
               and not n.startswith('Default__')]
    print('%d Blueprint classes loaded' % len(classes), file=sys.stderr)
    new = 0
    for c, cname in classes:
        try:
            f, guard = m.q(c + 0x48), 0  # UStruct::Children: the class's own functions
            while f and guard < 3000:
                guard += 1
                fname = kdis.name(f, False)
                key = cname + ':' + fname
                if key not in data:
                    hits = scan_function(f)
                    if hits:
                        data[key] = hits
                        new += 1
                f = m.q(f + 0x28)  # UField::Next
        except OSError:
            pass
    json.dump(data, open(out_json, 'w', encoding='utf-8'), indent=1, sort_keys=True)
    with open(out_txt, 'w', encoding='utf-8') as t:
        loud = sum(1 for hits in data.values() for h in hits if h["loud"])
        t.write('%d functions with offline-true branches, %d branches skip something that looks visible\n\n'
                % (len(data), loud))
        for key in sorted(data, key=lambda k: (-sum(len(h["loud"]) for h in data[k]), k)):
            for h in data[key]:
                t.write('%s @%d: %s -> offline skips the %s (from %s)\n' % (key, h["at"], h["check"], h["skipped"], h["from"]))
                if h["calls"]:
                    t.write('    calls: %s\n' % ', '.join(h["calls"][:30]))
                if h["loud"]:
                    t.write('    LOOK: %s\n' % ', '.join(h["loud"][:20]))
            t.write('\n')
    print('%d new functions; %d total -> %s, %s' % (new, len(data), out_json, out_txt), file=sys.stderr)


if __name__ == '__main__':
    main()
