"""Syntax-check Lua files (Lua 5.4 grammar via lupa): python scripts/luacheck.py <file.lua>...
Exit code 1 on any error. (load() returns nil + message on a syntax error; it doesn't raise.)"""
import sys
import lupa

L = lupa.LuaRuntime()
bad = 0
for path in sys.argv[1:]:
    msg = L.execute('local f, e = load(..., "=" .. select(2, ...)) return e or "ok"', open(path, encoding='utf-8').read(), path)
    print(path, msg)
    bad += msg != 'ok'
sys.exit(1 if bad else 0)
