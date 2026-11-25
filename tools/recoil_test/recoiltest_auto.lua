-- Recoil test (test installs only; never part of the shipped mod). Hold the left mouse button at a wall and let it run: it swaps
-- through every automatic gun by itself, twice, and writes everything to bridge/recoil_test.txt.
--
-- Round 1 is aim down sights for every gun, round 2 is the hip for every gun. Each gun fires SHOTS shots with the view left
-- completely free, so the recoil builds up exactly as in play. When the last shot is in, the gun is taken away, the view is put back
-- on the wall (eye level) and the next gun is given. Nothing holds the view while a gun fires.
--
-- Shots are counted by a hook on ServerMultiSimulateWeaponFire (once per shot of the player's gun), because the gun's own
-- lastFireTime stays 0.0 offline.
--
-- What it writes (one line each, fields split by " | "):
--   RUN  the start, the centre (pitch and yaw of the wall, degrees), the round changes
--   CFG  gun, the live WeaponConfig of the held gun (every recoil and spread field)
--   F    gun, part ("ads free" or "hip free"), seconds since the first shot, pitch and yaw from the centre (degrees), aim down sights
--        as read, shots so far, clip, then the weapon's own currentRecoil (x, y) and currentBulletSpread (the bloom). One row per frame from the first shot until just after the last one. A row with n shots so far
--        is the view after the kick of shot n and before shot n + 1.
--   S    gun, part, shot number, how far the shot strayed from where the view pointed (yaw, pitch, total, degrees): the bloom. Shotguns
--        have a line per pellet.
--   GUN  gun, part, how long the gun took
--   END  the finish
-- tools/recoil_test/README.md says how to run it.
local PROJECT = require("pveproject")
local M = {}

local OUT = PROJECT .. "bridge/recoil_test.txt"
local AUTO = PROJECT .. "bridge/recoil_autostart_auto"
local autoChk, autoSince = 0, nil
local SHOTS = 5                -- shots per gun and round
local EQUIP_SETTLE = 1.2       -- seconds after a new gun shows up in your hands before it is used
local LOST_FOR = 1.5           -- the gun missing from your hands for this long sends the test back to getting it
local ROUND_NAME = { "AIM DOWN SIGHTS", "HIP FIRE" }
local PART = { "ads free", "hip free" }

-- row, name, kind (0 long gun, 1 pistol slot), magazine, rounds per minute (from the weapon blueprints, the wiki where the blueprint has none)
local GUNS = {
    { "StenSMG", "Sten", 0, 32, 500 }, { "SterlingRifle", "Sterling", 0, 20, 550 }, { "Mat49Rifle", "Mat 49", 0, 36, 600 },
    { "MP40Rifle", "MP40", 0, 30, 450 }, { "UziSmg", "Uzi", 0, 20, 600 }, { "Mac10Rifle", "MAC-10", 0, 30, 700 },
    { "PPSHSmg", "PPSh", 0, 36, 700 }, { "ThompsonSMG", "Thompson", 0, 30, 550 }, { "HeavyThompsonSMG", "Heavy Thompson", 0, 30, 550 },
    { "M45CarlSMG", "Carl Gustav m/45", 0, 36, 500 }, { "GreaseGun", "Grease Gun", 0, 30, 450 }, { "KlobbSMG", "Klobb", 1, 20, 800 },
    { "M712SpecialSMG", "M712 Special", 0, 20, 600 }, { "ViperMk1", "Viper Mk1", 0, 32, 520 }, { "STG44Rifle", "STG44", 0, 30, 480 },
    { "StonerRifle", "Stoner", 0, 30, 585 }, { "KrasaRifle", "Krasa", 0, 20, 650 }, { "DaewooK1Rifle", "Daewoo K1", 0, 20, 480 },
    { "APSRifle", "APS", 0, 20, 380 }, { "EM2Rifle", "EM-2", 0, 20, 500 }, { "FALRifle", "FAL", 0, 20, 400 },
    { "BARRifle", "BAR", 0, 20, 425 }, { "SVURifle", "SVU", 0, 10, 360 }, { "BrenMk2Rifle", "Bren", 0, 20, 540 },
    { "DP28Rifle", "DP-28", 0, 47, 550 }, { "MG42Rifle", "MG42", 0, 50, 500 }, { "HeavyMG42Rifle", "Heavy MG42", 0, 50, 500 },
    { "Jackhammer", "Jackhammer", 0, 10, 280 },
}
local CLASS = {
    StenSMG = "Rifle_Sten_Child_C", SterlingRifle = "Rifle_SterlingMk4_Regular_Child_C", Mat49Rifle = "Rifle_Mat49_Child_C",
    MP40Rifle = "Rifle_MP40_Child_C", UziSmg = "Rifle_Uzi_Child_C", Mac10Rifle = "Rifle_Mac10_Child_C", PPSHSmg = "Rifle_PPSH_Child_C",
    ThompsonSMG = "Rifle_Thompson_Child_C", HeavyThompsonSMG = "Rifle_HeavyThompson_Child_C", M45CarlSMG = "Rifle_M45_Child_C",
    GreaseGun = "Rifle_GreaseGun_Child_C", KlobbSMG = "Rifle_Klobb_Child_C", M712SpecialSMG = "Rifle_M712_Special_Child_C",
    ViperMk1 = "Rifle_ViperMK1_Child_C", STG44Rifle = "Rifle_STG44_Child_C", StonerRifle = "Rifle_Stoner63A_Child_C",
    KrasaRifle = "Rifle_Krasa_Child_C", DaewooK1Rifle = "Rifle_DaewooK1_Child_C", APSRifle = "Rifle_APS_Rifle_Child_C",
    EM2Rifle = "Rifle_EM2_Child_C", FALRifle = "Rifle_FAL_Child_C", BARRifle = "Rifle_BAR_Child_C", SVURifle = "Rifle_SVU_Special_Child_C",
    BrenMk2Rifle = "Rifle_Bren_MKII_Child_C", DP28Rifle = "Rifle_DP28_Child_C", MG42Rifle = "Rifle_MG42_Child_C",
    HeavyMG42Rifle = "Rifle_HeavyMG42_Child_C", Jackhammer = "Shotgun_Jackhammer_Child_C",
}
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
    if not S then
        if now - autoChk > 1 then
            autoChk = now
            local fa = io.open(AUTO, "r")
            if fa then
                fa:close()
                local p = pc.Pawn
                if valid(p) and p:GetClass():GetFName():ToString() == "PlayerPawn_C" then
                    autoSince = autoSince or now
                    if now - autoSince > 10 then
                        os.remove(AUTO)
                        autoSince = nil
                        M.start()
                    end
                else
                    autoSince = nil
                end
            end
        end
        return
    end
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
        banner(("%s, %s: HOLD THE LEFT MOUSE BUTTON ON THE WALL (gun %d of %d)"):format(gun[2]:upper(), ROUND_NAME[S.round], S.gi, #S.guns))
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
            -- a moment for the last shot's kick to show, never as long as the gun's next shot would take
            if now - B.lastAt >= math.min(0.12, 0.6 * 60 / gun[5]) then endBurst(now) end
        end
    end
end

function M.afterFrame(pc) end -- (the view is never held now; the hook still calls this)

local SHORT = { StenSMG = true, Mat49Rifle = true, ViperMk1 = true, SVURifle = true, Jackhammer = true }

function M.start(short)
    local pc = controller()
    if not pc then return "In a raid, on foot" end
    local list = {}
    for _, gun in ipairs(GUNS) do if not short or SHORT[gun[1]] then list[#list + 1] = gun end end
    if os.remove(OUT) then end
    put(("RUN | recoil test %s | %d guns, %d shots each | round 1 aim down sights, then round 2 hip fire"):format(os.date("%Y-%m-%d %H:%M:%S"), #list, SHOTS))
    local b = bottomlessOn()
    S = { guns = list, gi = 1, round = 1, stage = "swap", step = 1, at = os.clock(), c = nil, base = COUNT.n }
    say("started (bottomless " .. tostring(b) .. ")")
    return "Recoil test: face a wall 3 to 5 m away and hold the left mouse button"
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
        { id = "recoiltest", label = function() return S and "Recoil test: running (click to stop)" or "Recoil test" end,
          help = "Face a wall, then hold the left mouse button", when = inRaid, unusable = "In a raid, on foot",
          run = function() if S then return M.stop() end return M.start() end },
        { id = "recoiltestshort", label = "Recoil test, 5 guns", when = inRaid, unusable = "In a raid, on foot",
          help = "Sten, Mat 49, Viper, SVU and Jackhammer only",
          run = function() if S then return M.stop() end return M.start(true) end },
    }
    for _, a in ipairs(sound) do out[#out + 1] = a end
    return out
end

return M
