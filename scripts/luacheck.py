"""Syntax-check Lua files (Lua 5.4 grammar via lupa), and check each keeps room under Lua's limit of 200 local variables
in one function: python scripts/luacheck.py [--min-headroom N] <file.lua>...

Exit code 1 on a syntax error, or when a file's top level has fewer than N (default 20) locals to spare. main.lua once
sat at exactly 200 and new code had to become globals; it was split into modules (NOTES.md "main.lua and its
modules"). The room left is measured, not counted: as many extra locals as still compile are put in front of the file.
(load() returns nil + message on a syntax error; it doesn't raise.)"""
import sys
import lupa

L = lupa.LuaRuntime()
LOAD = L.eval('function(src, name) local f, e = load(src, "=" .. name) return e or "ok" end')
LIMIT = 200
# Files allowed under the minimum until they're split, each with the issue that splits it. Remove the line when it's done.
TIGHT = {"rivals.lua": "issue #149"}


def headroom(src, name):
    """How many more top-level locals the file could declare before Lua refuses it."""
    lo, hi = 0, LIMIT
    while lo < hi:  # the largest k that still compiles
        k = (lo + hi + 1) // 2
        pad = "local " + ",".join(f"_pad{i}" for i in range(k)) + "; "
        if LOAD(pad + src, name) == "ok":
            lo = k
        else:
            hi = k - 1
    return lo


def main(args):
    min_room = 20
    if args[:1] == ["--min-headroom"]:
        min_room, args = int(args[1]), args[2:]
    bad = 0
    for path in args:
        src = open(path, encoding="utf-8").read()
        msg = LOAD(src, path)
        if msg == "ok":
            room = headroom(src, path)
            exception = TIGHT.get(path.replace("\\", "/").rsplit("/", 1)[-1])
            if room < min_room and exception:
                msg = f"ok ({room} locals to spare: allowed until {exception} splits it)"
            elif room < min_room:
                msg = f"only {room} locals to spare at the top level (keep {min_room}: move code into a module)"
            else:
                msg = f"ok ({room} locals to spare)"
        print(path, msg)
        bad += not msg.startswith("ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
