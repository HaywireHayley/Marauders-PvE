"""Makes a test copy of recoil.lua (test installs only, never committed to the mod).

    python make_test_recoil.py ../../mods/PvEDirector/Scripts/recoil.lua > recoil_test_copy.lua

The copy is the same file with three additions, so the recoil tests can compare it with the game's own recoil and try settings
without a restart:
  bridge/recoil_raw        if the file exists the shot hook does nothing (the game's own recoil, the baseline)
  bridge/recoil_cfg.txt    lines KEY=VALUE (RECOIL_MULT=0.5 ...) read again on every shot
  bridge/recoil_dbg.txt    one SHOT line for each shot the file added to (aimed, hip, measured)
Put the output over mods/PvEDirector/Scripts/recoil.lua of the install, and put the repo's file back when done.
"""
import sys

PRE = r'''-- TEST INSTALL ONLY: raw switch, settings from bridge/recoil_cfg.txt, one log line per shot in bridge/recoil_dbg.txt
local TESTROOT = require("pveproject") .. "bridge/"
local DBGPATH = TESTROOT .. "recoil_dbg.txt"
os.remove(DBGPATH)
local function DBG(t) local fh = io.open(DBGPATH, "a") if fh then fh:write(t, "\n") fh:close() end end
local function testControls(CFG)
    local fr = io.open(TESTROOT .. "recoil_raw", "r")
    if fr then fr:close() return true end
    local fc = io.open(TESTROOT .. "recoil_cfg.txt", "r")
    if fc then
        for line in fc:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*([%-%d%.]+)")
            if k and CFG[k] ~= nil and tonumber(v) then CFG[k] = tonumber(v) end
        end
        fc:close()
    end
    return false
end
'''

def main(path):
    s = PRE + open(path).read()
    steps = [
        ("local function onShot(w)\n    if CFG.RECOIL_FIX ~= 1 then return end\n",
         "local function onShot(w)\n    if testControls(CFG) then return end\n    if CFG.RECOIL_FIX ~= 1 then return end\n"),
        ("            pitchPending = pitchPending + (target - native)\n",
         "            pitchPending = pitchPending + (target - native)\n            DBG((\"SHOT aimed t=%.4f class=%s v=%.3f va=%.3f native=%.3f target=%.3f add=%.3f mult=%.3f\"):format(os.clock(), className(w), v, va, native, target, target - native, mult))\n"),
        ("        pitchPending = pitchPending + DEGREES * v * k\n",
         "        pitchPending = pitchPending + DEGREES * v * k\n        DBG((\"SHOT hip t=%.4f class=%s v=%.3f k=%.3f add=%.3f\"):format(os.clock(), className(w), v, k, DEGREES * v * k))\n"),
        ("            shots[#shots + 1] = { t = os.clock(), want = want, cap = DEGREES * v * 1.5 + 0.5 }\n",
         "            shots[#shots + 1] = { t = os.clock(), want = want, cap = DEGREES * v * 1.5 + 0.5 }\n            DBG((\"SHOT aimed MEASURED t=%.4f class=%s want=%.3f\"):format(os.clock(), className(w), want))\n"),
    ]
    for old, new in steps:
        if old not in s:
            sys.exit("recoil.lua no longer has: " + old.strip().splitlines()[0])
        s = s.replace(old, new, 1)
    sys.stdout.write(s)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
