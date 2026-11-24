-- Weapon sound test (test installs only; never part of the shipped mod). Why does a gun's sound get cut after the first shot (the
-- Jackhammer)? F9 "Weapon sound test" starts a capture, a second click (or 30 seconds) ends it and writes bridge/sound_test.txt.
-- In between, fire the gun in your hands: a few single shots, then a burst held down. Do the same with a gun that sounds right (the
-- Sten) for comparison.
--
-- What it writes, one line each (fields split by " | "), t = seconds since the capture started:
--   CFG    the held gun's sound set: FireSound, FireLoopSound, FireFinishSound, ShootSoundToUse, bLoopedFireSound, FireAC
--   T      t, gun, event, detail
--            SHOT         one shot of your gun (ServerMultiSimulateWeaponFire)
--            FIRESOUND    the weapon's OnFiringSound call and its arguments
--            START / STOP / HANDLE / BURST   ServerStartFire, ServerStopFire, ServerHandleFiring, BurstStartFireEvent
-- The hooks exist only while a capture runs (registered by the click, removed by the second click), and nothing scans the world.
local PROJECT = require("pveproject")
local M = {}

local OUT = PROJECT .. "bridge/sound_test.txt"
local MAX_SECONDS = 30

local C -- the capture: { t0, lines, voices = {name -> count}, lastSample, gun }

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end
local function say(text) print("[PvEDirector] sound test: " .. text .. "\n") end
local function nameOf(o)
    if o == nil then return "nil" end
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    if ok and s then return s end
    return tostring(o)
end
local function pawnGun()
    local pc = FindFirstOf("MainPlayerController_C")
    if not (pc and pc:IsValid() and valid(pc.Pawn)) then return nil end
    local g
    pcall(function() g = pc.Pawn.CurrentWeapon end)
    if valid(g) then return g end
    return nil
end
local function gunName(g)
    local ok, n = pcall(function() return g:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end
local function fmt(v)
    local t = type(v)
    if t == "number" then return ("%.3f"):format(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:GetFName():ToString() end)
        if ok and s then return s end
        local ok2, x = pcall(function() return ("(%.0f %.0f %.0f)"):format(v.X, v.Y, v.Z) end)
        if ok2 then return x end
    end
    return tostring(v)
end
local function arg(p)
    local ok, v = pcall(function() return p:get() end)
    return ok and fmt(v) or "?"
end

local function log(event, detail)
    if not C then return end
    local g = pawnGun()
    C.lines[#C.lines + 1] = ("T | %.3f | %s | %s | %s"):format(os.clock() - C.t0, g and gunName(g) or "-", event, detail or "")
end

-- The wall: the impact effects a shot makes (the game's pooled hit effect actors, with their own sound). Read the way bulletholes.lua
-- does: the player controller's PooledImpactActors, bInUse set while one is live. Read only, once per shot, only during a capture.
local function impactsNow()
    if not C then return "" end
    if not C.pool then
        C.pool = {}
        pcall(function()
            local pc = FindFirstOf("MainPlayerController_C")
            pc.PooledImpactActors:ForEach(function(_, el)
                local ok, a = pcall(function() return el:get() end)
                if ok and valid(a) then C.pool[#C.pool + 1] = a end
            end)
        end)
    end
    local n, what = 0, nil
    for _, a in ipairs(C.pool) do
        local ok, u = pcall(function() return a.bInUse end)
        if ok and u == true then
            n = n + 1
            if not what then pcall(function() what = a.EffectForHit:GetFullName():match("PS_BulletHit_(%w+)") end) end
        end
    end
    return (" impacts_live=%d%s"):format(n, what and (" first=" .. what) or "")
end

local ids = {} -- { { path, id1, id2 } } of the hooks this capture registered

local function mine(ctx)
    local ok, owner = pcall(function() return ctx:get().MyPawn end)
    return ok and valid(owner) and nameOf(owner:GetClass()) == "PlayerPawn_C"
end
local function hook(path, fn)
    local ok, id1, id2 = pcall(RegisterHook, path, fn)
    if ok and id1 then ids[#ids + 1] = { path, id1, id2 } else print("[PvEDirector] sound test: no hook for " .. path .. "\n") end
end
local function hookAll()
    hook("/Script/RaidGame.RaidWeapon:ServerMultiSimulateWeaponFire", function(ctx)
        if not (C and mine(ctx)) then return end
        local w = ctx:get()
        local ac, looped = "FireAC nil", "?"
        pcall(function() looped = tostring(w.bLoopedFireSound) end)
        pcall(function()
            local c = w.FireAC
            if valid(c) then ac = ("FireAC %s playing=%s sound=%s"):format(nameOf(c), tostring(c:IsPlaying()), nameOf(c.Sound)) end
        end)
        log("SHOT", ac .. " bLoopedFireSound=" .. looped .. impactsNow())
    end)
    hook("/Script/RaidGame.RaidWeapon:OnFiringSound", function(ctx, a, b, c, d, e)
        if C and mine(ctx) then log("FIRESOUND", table.concat({ arg(a), arg(b), arg(c), arg(d), arg(e) }, " ")) end
    end)
    for ev, fn in pairs({ START = "ServerStartFire", STOP = "ServerStopFire", HANDLE = "ServerHandleFiring", BURST = "BurstStartFireEvent" }) do
        hook("/Script/RaidGame.RaidWeapon:" .. fn, function(ctx) if C and mine(ctx) then log(ev) end end)
    end
end
local function unhookAll()
    for _, h in ipairs(ids) do pcall(UnregisterHook, h[1], h[2], h[3]) end
    ids = {}
end

local function snapshot(g)
    local parts = {}
    for _, n in ipairs({ "FireSound", "FireLoopSound", "FireFinishSound", "ShootSoundToUse", "FireAC" }) do
        local ok, v = pcall(function() return g[n] end)
        local s = ok and valid(v) and nameOf(v) or "nil"
        local dur
        if ok and valid(v) and n ~= "FireAC" then pcall(function() dur = v:GetDuration() end) end
        parts[#parts + 1] = n .. "=" .. s .. (dur and (" (" .. ("%.2f"):format(dur) .. " s)") or "")
    end
    local ok, lp = pcall(function() return g.bLoopedFireSound end)
    parts[#parts + 1] = "bLoopedFireSound=" .. tostring(ok and lp)
    return ("CFG | %s | %s"):format(gunName(g), table.concat(parts, " "))
end

-- Every frame in a raid: while capturing, note the held gun and its sound set when it changes (and stop after MAX_SECONDS).
local lastPlaying

function M.tick(now, pc)
    local g = C and pawnGun() or nil
    if not C then return end
    if now - C.t0 > MAX_SECONDS then return M.stop() end
    if g then
        local gn = gunName(g)
        if gn ~= C.gun then
            C.gun = gn
            C.lines[#C.lines + 1] = snapshot(g)
            lastPlaying = nil
        end
        local ok, playing = pcall(function()
            local c = g.FireAC
            if valid(c) then return tostring(c:IsPlaying()) end
            return "no FireAC"
        end)
        playing = ok and playing or "?"
        if playing ~= lastPlaying then lastPlaying = playing log("AC", "fire audio component: " .. playing) end
    end
end

function M.start()
    local g = pawnGun()
    if not g then return "In a raid, on foot, with a gun in your hands" end
    os.remove(OUT)
    C = { t0 = os.clock(), lines = {}, gun = nil }
    hookAll()
    say("started: fire a few single shots, then a burst, then click again")
    return "Sound test running: shoot, then click again to stop"
end

function M.stop()
    if not C then return "Sound test is not running" end
    unhookAll()
    local f = io.open(OUT, "w")
    if f then
        f:write(("RUN | sound test %s | %.1f s | %d lines\n"):format(os.date("%Y-%m-%d %H:%M:%S"), os.clock() - C.t0, #C.lines))
        for _, l in ipairs(C.lines) do f:write(l, "\n") end
        f:close()
    end
    say(("written: %d lines in bridge/sound_test.txt"):format(#C.lines))
    C = nil
    return "Sound test done: bridge/sound_test.txt"
end

function M.actions()
    local function inRaid() return pawnGun() ~= nil end
    return {
        { id = "soundtest", label = function() return C and "Weapon sound test: capturing (click to finish)" or "Weapon sound test" end,
          help = "Click, fire the gun in your hands, click again", when = inRaid, unusable = "In a raid, on foot, with a gun",
          run = function() if C then return M.stop() end return M.start() end },
    }
end

return M
