-- Recoil test for single shot guns (test installs only; never part of the shipped mod). Face a wall and click the left mouse button
-- once per shot: it gives you every single shot gun by itself, twice, and writes everything to bridge/recoil_test_single.txt (or _pistols).
--
-- Two sets, two F9 buttons: "single shot guns" (semi automatic rifles and shotguns, the Reising and the rest; no launchers, blowtorch,
-- fire extinguisher or flamethrower) and "pistols". Round 1 is aim down sights for every gun, round 2 is the hip for every gun. Each
-- gun gets SHOTS shots, one per click, with the view left completely free, so the recoil builds up exactly as in play. When the last
-- shot is in, the gun is taken away, the view is put back on the wall (eye level) and the next gun is given.
--
-- Shots are counted by a hook on ServerMultiSimulateWeaponFire (once per shot of the player's gun), because the gun's own
-- lastFireTime stays 0.0 offline. The automatic guns' version of this test is in recoil_scratch/recoiltest.lua.automatic-guns.
--
-- What it writes (one line each, fields split by " | "):
--   RUN  the start, the centre (pitch and yaw of the wall, degrees), the round changes
--   CFG  gun, the live WeaponConfig of the held gun (every recoil and spread field)
--   F    gun, part ("ads free" or "hip free"), seconds since the first shot, pitch and yaw from the centre (degrees), aim down sights
--        as read, shots so far, clip, then the weapon's own currentRecoil (x, y) and currentBulletSpread. Rows are written for the
--        moment of each shot and the KICK_WINDOW seconds after it (the clicks are slow, so the frames in between say nothing).
--        A row with n shots so far is the view after the kick of shot n and before shot n + 1.
--   S    gun, part, shot number, how far the shot strayed from where the view pointed (yaw, pitch, total, degrees): the bloom. Shotguns
--        have a line per pellet.
--   GUN  gun, part, how long the gun took
--   END  the finish
-- tools/recoil_test/README.md says how to run it.
local PROJECT = require("pveproject")
local M = {}

local OUT = PROJECT .. "bridge/recoil_test.txt"
local SHOTS = 5                -- shots per gun and round
local KICK_WINDOW = 0.35       -- seconds after a shot that are written (the kick lands in about 40 ms; a slow blend takes longer)
local EQUIP_SETTLE = 1.2       -- seconds after a new gun shows up in your hands before it is used
local LOST_FOR = 1.5           -- the gun missing from your hands for this long sends the test back to getting it
local ROUND_NAME = { "AIM DOWN SIGHTS", "HIP FIRE" }
local PART = { "ads free", "hip free" }

-- row, name, kind (0 long gun, 1 pistol slot), magazine, rounds per minute (from the weapon data, 0 where it has none), class
local SINGLE = {
    { "M50ReisingRifle", "Reising", 0, 12, 360, "Rifle_M50reising_Child_C" }, { "JohnsonRifle", "Johnson", 0, 10, 350, "Rifle_Johnson_Child_C" },
    { "SVT40Rifle", "SVT-40", 0, 10, 350, "Rifle_SVT40_Child_C" }, { "M1ParaRifle", "M1 Carbine Para", 0, 15, 350, "Rifle_M1_Para_Child_C" },
    { "Mas44Rifle", "MAS 44", 0, 10, 300, "Rifle_Mas44_Child_C" }, { "DeLisleRifle", "De Lisle", 0, 11, 30, "Rifle_DeLisle_Child_C" },
    { "M16Rifle", "M16", 0, 20, 0, "Rifle_M16_Child_C" }, { "AC14Rifle", "AC14", 0, 30, 350, "Rifle_AC14_Child_C" },
    { "CustomMat49", "Custom Mat 49", 0, 30, 0, "Rifle_CustomMat49_Child_C" }, { "LiberatorShotgun", "Liberator", 0, 4, 225, "Shotgun_Liberator_Child_C" },
    { "HeavyLiberatorShotgun", "Heavy Liberator", 0, 4, 225, "Shotgun_HeavyLiberator_Child_C" }, { "TrenchShotgun", "Trench gun", 0, 5, 140, "Shotgun_TrenchGun_Child_C" },
    { "LongDoubleBarrel", "Double barrel", 0, 2, 975, "Shotgun_LongDouble_Child_C" }, { "TerminatorShotgun", "Terminator", 0, 1, 975, "Shotgun_Terminator_Child_C" },
}
local PISTOLS = {
    { "1911Pistol", "M1911", 1, 7, 350, "Pistol_1911_Child_C" }, { "1911GPistol", "M1911 G", 1, 8, 350, "Pistol_1911_G_Child_C" },
    { "P08Pistol", "Luger P08", 1, 8, 375, "Pistol_P08_Child_C" }, { "M712Pistol", "M712", 1, 10, 0, "Pistol_M712_Child_C" },
    { "WebleyPistol", "Webley", 1, 6, 320, "Pistol_Webley_Child_C" }, { "WelrodPistol", "Welrod", 1, 6, 40, "Pistol_Welrod_Child_C" },
    { "SPP1Pistol", "SPP-1", 1, 4, 200, "Pistol_SPP1_Child_C" }, { "MosinObrezPistol", "Obrez", 1, 5, 35, "Pistol_Mosin_Child_C" },
    { "SawedOffDouble", "Sawed-off", 1, 2, 975, "Shotgun_SawedOffDouble_Child_C" },
}
local SETS = { single = { SINGLE, "single shot guns" }, pistols = { PISTOLS, "pistols" } }
local CLASS = {}
for _, set in ipairs({ SINGLE, PISTOLS }) do for _, g in ipairs(set) do CLASS[g[1]] = g[6] end end
local CFG_FIELDS = { "VerticalRecoil", "VerticalRecoilADS", "HorizontalRecoilMin", "HorizontalRecoilMax", "HorizontalTolerance",
    "AngleMin", "AngleMax", "RecoilBlendSpeed", "RecoilRecoveryDelay", "RecoilRecoveryRate", "NoRecoilRecovery", "WeaponSpread",
    "FiringSpreadIncrement", "FiringSpreadMax", "FiringInAirSpreadMax", "AccuracyMultiplier", "CrouchAccuracyMultiplier", "FireRate" }

local S -- the run

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end
local function put(text)
    local f = io.open(OUT, "a")
    if f then f:write(text, "\n") f:close() end
end
local function say(text) print("[PvEDirector] recoil test: " .. text .. "\n") end
local function wrap(a) return (a + 180) % 360 - 180 end

-- The shots of the player's gun, counted by a hook (registered once per game, whatever the number of times this file is loaded).
local COUNT = package.loaded["recoiltest.shots"]
if not COUNT then
    COUNT = { n = 0, at = 0 }
    package.loaded["recoiltest.shots"] = COUNT
    local ok, err = pcall(RegisterHook, "/Script/RaidGame.RaidWeapon:ServerMultiSimulateWeaponFire", function(ctx)
        pcall(function()
            local owner = ctx:get().MyPawn
            if valid(owner) and owner:GetClass():GetFName():ToString() == "PlayerPawn_C" then
                COUNT.n = COUNT.n + 1
                COUNT.at = os.clock()
            end
        end)
    end)
    if not ok then print("[PvEDirector] recoil test: shot hook failed: " .. tostring(err) .. "\n") end
end

-- The direction of every shot of the player's gun against where the view points (the bloom: how far a shot strays), by a hook on the
-- trace the game does per shot (per pellet for a shotgun).
local DEV = package.loaded["recoiltest.dev"]
if not DEV then
    DEV = {}
    package.loaded["recoiltest.dev"] = DEV
    local ok, err = pcall(RegisterHook, "/Script/RaidGame.RaidWeapon:ServerTraceMultiFireProjectile", function(ctx, originP, dirP)
        pcall(function()
            local owner = ctx:get().MyPawn
            if not (valid(owner) and owner:GetClass():GetFName():ToString() == "PlayerPawn_C") then return end
            local d = dirP:get()
            local r = FindFirstOf("MainPlayerController_C"):GetControlRotation()
            local len = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
            DEV[#DEV + 1] = { at = os.clock(), dyaw = wrap(math.deg(math.atan(d.Y, d.X)) - r.Yaw),
                dpitch = wrap(math.deg(math.asin(d.Z / len)) - r.Pitch) }
            if #DEV > 600 then table.remove(DEV, 1) end
        end)
    end)
    if not ok then print("[PvEDirector] recoil test: spread hook failed: " .. tostring(err) .. "\n") end
end

local function controller()
    local pc = FindFirstOf("MainPlayerController_C")
    if not (pc and pc:IsValid()) then return nil end
    local pawn = pc.Pawn
    if not (pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return nil end
    return pc
end

-- Big text on the screen (the same widget the armour test uses). banner(nil) hides it.
local BANNER
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local shown
local function banner(text)
    if text == shown then return end
    shown = text
    pcall(function()
        if text == nil then
            if BANNER and valid(BANNER.host) then BANNER.host:SetVisibility(1) end
            return
        end
        if not (BANNER and valid(BANNER.host)) then
            local cls = StaticFindObject(HOST)
            if not valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = StaticFindObject(HOST) end
            local pc = controller()
            if not (valid(cls) and pc) then return end
            local host = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
            if not valid(host) then return end
            local tree = host.WidgetTree
            local root = tree.RootWidget
            root:ClearChildren()
            local bg = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree)
            bg:SetBrushColor({ R = 0.03, G = 0.03, B = 0.04, A = 0.85 })
            local s1 = root:AddChildToCanvas(bg)
            s1:SetPosition({ X = 360, Y = 90 })
            s1:SetSize({ X = 1200, Y = 90 })
            local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree)
            t.Font.Size = 36
            local s2 = root:AddChildToCanvas(t)
            s2:SetPosition({ X = 390, Y = 112 })
            s2:SetSize({ X = 1140, Y = 60 })
            host:AddToViewport(5020)
            BANNER = { host = host, text = t }
        end
        BANNER.text:SetText(FText(text))
        BANNER.host:SetVisibility(3)
    end)
end

local function heldGun(pc)
    local g
    pcall(function() g = pc.Pawn.CurrentWeapon end)
    if valid(g) then return g end
    return nil
end
local function classOf(g)
    local ok, n = pcall(function() return g:GetClass():GetFName():ToString() end)
    return ok and n or nil
end

-- The inventory item behind a gun (UniqueItemGUID == gun.UUIDSIGIS), to take it away again.
local function itemGuid(g)
    local guid
    pcall(function() guid = g.UUIDSIGIS:ToString() end)
    if not guid then return nil end
    for _, it in ipairs(FindAllOf("SIGISInventoryItem") or {}) do
        if valid(it) then
            local ok, id = pcall(function() return it.UniqueItemGUID:ToString() end)
            if ok and id == guid then return id end
        end
    end
    return nil
end

local function bottomlessOn()
    local ok, G = pcall(require, "debuggive")
    if not (ok and type(G) == "table") then return false end
    for _, a in ipairs(G.actions()) do
        if a.id == "bottomless" then
            local lab = type(a.label) == "function" and a.label() or a.label
            if not tostring(lab):find("ON") then a.run() end
            return true
        end
    end
    return false
end

local function snapshot(g, gun)
    local parts = { ("class=%s"):format(tostring(classOf(g))) }
    pcall(function() parts[#parts + 1] = "row=" .. g.WeaponDataTableName:ToString() end)
    for _, f in ipairs(CFG_FIELDS) do
        local ok, v = pcall(function() return g.WeaponConfig[f] end)
        parts[#parts + 1] = f .. "=" .. (ok and tostring(v) or "?")
    end
    pcall(function()
        local m = g.WeaponConfig.recoilModifier
        parts[#parts + 1] = ("recoilModifier Moving=%s Crouching=%s Aiming=%s InAir=%s"):format(tostring(m.Moving), tostring(m.Crouching), tostring(m.Aiming), tostring(m.InAir))
    end)
    pcall(function()
        local m = g.WeaponConfig.spreadModifier
        parts[#parts + 1] = ("spreadModifier Moving=%s Crouching=%s Aiming=%s InAir=%s"):format(tostring(m.Moving), tostring(m.Crouching), tostring(m.Aiming), tostring(m.InAir))
    end)
    put(("CFG | %s | rpm %d | %s"):format(gun[1], gun[5], table.concat(parts, " ")))
end

local function setAds(pc, want)
    pcall(function()
        local pawn = pc.Pawn
        if pawn:IsTargeting() ~= want then pawn:ServerSetTargeting(want) end
    end)
end
local function readAds(pc)
    local ok, v = pcall(function() return pc.Pawn:IsTargeting() end)
    return ok and tostring(v) or "?"
end
-- Eye level: the view back on the wall (the spot you looked at when the first gun showed up).
local function centre(pc)
    pcall(function() pc:SetControlRotation({ Pitch = S.c.Pitch, Yaw = S.c.Yaw, Roll = 0 }) end)
end

local function finish(why)
    banner(why)
    S.doneAt = os.clock() + 12
    S.stage = "done"
    put("END | " .. why)
    say(why)
end

local function nextGun()
    S.gi = S.gi + 1
    S.burst = nil
    if S.gi > #S.guns then
        if S.round == 1 then
            S.round, S.gi = 2, 1
            put("RUN | round 2: hip fire")
            say("round 1 (aim down sights) done, round 2 (hip fire) starts")
        else
            return finish("RECOIL TEST DONE: bridge/recoil_test.txt")
        end
    end
    S.stage, S.step, S.at = "swap", 1, os.clock()
end

local function endBurst(now)
    local B, gun = S.burst, S.guns[S.gi]
    for _, l in ipairs(B.rows) do put(l) end
    put(("GUN | %s | %s | %d shots, %.2f s from the first shot to the last row"):format(gun[1], PART[S.round], math.min(COUNT.n - B.base, SHOTS), now - B.first))
    local k = 0
    for _, e in ipairs(DEV) do
        if e.at >= B.first - 0.1 and e.at <= (B.lastAt or now) + 0.005 then
            k = k + 1
            put(("S | %s | %s | %d | %.3f | %.3f | %.3f"):format(gun[1], PART[S.round], k, e.dyaw, e.dpitch, math.sqrt(e.dyaw * e.dyaw + e.dpitch * e.dpitch)))
        end
    end
    for i = #DEV, 1, -1 do DEV[i] = nil end
    nextGun()
end

local function sample(now, pc)
    local B = S.burst
    if COUNT.n == B.base + (B.logged or 0) and now - COUNT.at > KICK_WINDOW then return end -- between shots, long after the kick: nothing to say
    B.logged = COUNT.n - B.base
    local ok, r = pcall(function() return pc:GetControlRotation() end)
    if not ok or not r then return end
    local n = math.min(COUNT.n - B.base, SHOTS)
    local clip, rx, ry, bs = "?", "?", "?", "?"
    pcall(function()
        local w = heldGun(pc)
        clip = tostring(w.CurrentAmmoInClip)
        local c = w.currentRecoil
        rx, ry = ("%.4f"):format(c.X), ("%.4f"):format(c.Y)
        bs = ("%.3f"):format(w.currentBulletSpread)
    end)
    B.rows[#B.rows + 1] = ("F | %s | %s | %.3f | %.3f | %.3f | %s | %d | %s | %s | %s | %s"):format(S.guns[S.gi][1], PART[S.round], now - B.first,
        r.Pitch - S.c.Pitch, wrap(r.Yaw - S.c.Yaw), readAds(pc), n, clip, rx, ry, bs)
end

-- Every frame in a raid, before the game's own frame.
function M.tick(now, pc)
    local st = package.loaded["soundtest"] -- (the weapon sound test rides on this tick)
    if st and st.tick then pcall(st.tick, now, pc) end
    if not S then return end
    if S.stage == "done" then
        if now > S.doneAt then banner(nil) S = nil end
        return
    end
    local pawn = pc.Pawn
    if not (valid(pawn) and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return end
    local gun = S.guns[S.gi]
    local want = CLASS[gun[1]]
    local g = heldGun(pc)

    if S.stage == "swap" then
        banner(("RECOIL TEST, %s: GETTING THE %s (%d of %d)"):format(ROUND_NAME[S.round], gun[2]:upper(), S.gi, #S.guns))
        if S.c then centre(pc) end -- no gun is being tested here: the view goes back to eye level
        setAds(pc, S.round == 1)
        if S.step == 1 then
            if g and classOf(g) == want then S.step, S.at = 4, now return end
            if g then
                local guid = itemGuid(g)
                if guid then pcall(function() FindFirstOf("SIGISInventoryComponent"):Server_RemoveItem(guid) end) end
            end
            S.step, S.at = 2, now
        elseif S.step == 2 then
            if not g or classOf(g) ~= S.prevClass or now - S.at > 3 then S.step, S.at = 3, now end
        elseif S.step == 3 then
            local ok, Give = pcall(require, "debuggive")
            local slot, msg
            if ok and type(Give) == "table" and Give.giveGun then slot, msg = Give.giveGun(gun[1], gun[2], gun[3], gun[4]) end
            if not slot then
                put(("GUN | %s | skipped: %s"):format(gun[1], tostring(msg or "no giveGun")))
                say(("%s skipped: %s"):format(gun[2], tostring(msg or "no giveGun")))
                return nextGun()
            end
            S.step, S.at = 4, now
        elseif S.step == 4 then
            if g and classOf(g) == want then
                if not S.sawAt then S.sawAt = now end
                if now - S.sawAt >= EQUIP_SETTLE then
                    S.sawAt = nil
                    if not S.c then -- the centre is where you were looking when the first gun showed up: the wall
                        local ok, r = pcall(function() return pc:GetControlRotation() end)
                        if ok and r then S.c = { Pitch = r.Pitch, Yaw = r.Yaw } end
                        if not S.c then return end
                        put(("RUN | centre pitch %.3f yaw %.3f"):format(S.c.Pitch, S.c.Yaw))
                    end
                    snapshot(g, gun)
                    centre(pc)
                    S.stage, S.lostAt = "ready", nil
                    S.base = COUNT.n -- shots fired while the gun was settling don't count
                    for i = #DEV, 1, -1 do DEV[i] = nil end
                end
            else
                S.sawAt = nil
                if now - S.at > 10 then
                    put(("GUN | %s | skipped: it never showed up in your hands"):format(gun[1]))
                    say(gun[2] .. " never equipped")
                    return nextGun()
                end
            end
        end
        S.prevClass = g and classOf(g) or S.prevClass
        return
    end

    -- ready and burst: a gun missing for a moment is no reason to start over, a gun that stays gone is
    if not g or classOf(g) ~= want then
        S.lostAt = S.lostAt or now
        if now - S.lostAt > LOST_FOR then S.stage, S.step, S.at, S.burst = "swap", 1, now, nil end
        return
    end
    S.lostAt = nil
    setAds(pc, S.round == 1)

    if S.stage == "ready" then
        banner(("%s, %s: CLICK THE LEFT MOUSE BUTTON ON THE WALL, %d SHOTS (gun %d of %d)"):format(gun[2]:upper(), ROUND_NAME[S.round], SHOTS, S.gi, #S.guns))
        if COUNT.n > S.base then -- the first shot: the view is still at eye level (the shot's own kick comes in this frame or the next)
            S.burst = { base = S.base, first = now, rows = {} }
            S.stage = "burst"
            sample(now, pc)
        end
        return
    end

    if S.stage == "burst" then
        local B = S.burst
        local n = COUNT.n - B.base
        banner(("%s: SHOT %d OF %d"):format(gun[2]:upper(), math.min(n, SHOTS), SHOTS))
        if n < SHOTS then
            sample(now, pc)
        else
            B.lastAt = B.lastAt or now
            sample(now, pc)
            -- a moment for the last shot's kick to show
            if now - B.lastAt >= KICK_WINDOW then endBurst(now) end
        end
    end
end

function M.afterFrame(pc) end -- (the view is never held now; the hook still calls this)

function M.start(setName)
    local pc = controller()
    if not pc then return "In a raid, on foot" end
    local set = SETS[setName or "single"]
    OUT = PROJECT .. "bridge/recoil_test_" .. (setName or "single") .. ".txt" -- one file per set, so the second set does not wipe the first
    local list = {}
    for _, gun in ipairs(set[1]) do list[#list + 1] = gun end
    if os.remove(OUT) then end
    put(("RUN | recoil test %s | %s | %d guns, %d shots each | round 1 aim down sights, then round 2 hip fire"):format(os.date("%Y-%m-%d %H:%M:%S"), set[2], #list, SHOTS))
    local b = bottomlessOn()
    S = { guns = list, gi = 1, round = 1, stage = "swap", step = 1, at = os.clock(), c = nil, base = COUNT.n }
    say("started (bottomless " .. tostring(b) .. ")")
    return "Recoil test: face a wall 3 to 5 m away and click the left mouse button once per shot"
end

function M.stop()
    if S then
        put("END | stopped by hand")
        S = nil
        banner(nil)
    end
    return "Recoil test stopped"
end

function M.actions()
    local function inRaid() return controller() ~= nil end
    local ok, st = pcall(require, "soundtest")
    local sound = ok and type(st) == "table" and st.actions() or {}
    local out = {
        { id = "recoiltest", label = function() return S and "Recoil test: running (click to stop)" or "Recoil test, single shot guns" end,
          help = "Face a wall, then click the left mouse button once per shot", when = inRaid, unusable = "In a raid, on foot",
          run = function() if S then return M.stop() end return M.start("single") end },
        { id = "recoiltestpistols", label = "Recoil test, pistols", when = inRaid, unusable = "In a raid, on foot",
          help = "The pistols, same way: click once per shot",
          run = function() if S then return M.stop() end return M.start("pistols") end },
    }
    for _, a in ipairs(sound) do out[#out + 1] = a end
    return out
end

return M
