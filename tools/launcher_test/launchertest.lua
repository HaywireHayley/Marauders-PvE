-- Launcher test (test installs only; never part of the shipped mod). Stand 5 to 10 m from a wall and look at it; the test does the
-- rest: it gives the China Lake and then the Mini Thumper, and for each one fires 3 shots from the hip and 3 aimed down sights by itself
-- (ServerStartFire, ServerStopFire on the gun in your hands, the way the rival crews fire), and writes bridge/launcher_test.txt.
--
-- What it checks: whether a 40mm round goes off in your hands (the bug of #360). Per shot it follows every Proj40mm_C the game has for
-- 2.5 s, and your own health, and writes
--   SHOT  gun, stance, shot number, how many rounds moved (1 is right, 2 is the twin of the old bug), your health before and after,
--         when the first health loss came, and for every round when it left, how far from you it was first seen, where it ended up and
--         when it exploded; then the verdict:
--           BARREL     a round exploded within 0.3 s of the shot, or within 1.5 m of you
--           SELF HIT   you lost health after the shot (not at the barrel): the splash of a close wall, a wall behind a window...
--           OK         one round, it flew away and exploded far from you, no health lost
--   ROUND one line per round (the position every 0.1 s: seconds since the shot, x y z, distance from you, exploded)
--   RUN, GUN, END  the start, the gun's own data, the finish
-- Standing close to a wall makes the SELF HIT lines come: run it once at 2 to 3 m and once at 6 m or more.
-- tools/launcher_test/README.md says how to run it.
local PROJECT = require("pveproject")
local M = {}

local OUT = PROJECT .. "bridge/launcher_test.txt"
local AUTO = PROJECT .. "bridge/launcher_autostart" -- its text is a label for the run ("near", "far"); the test starts by itself 10 s after you are on foot in a raid (once)
local autoChk, autoSince = 0, nil
local SHOTS = 3                -- shots per gun and stance
local WATCH = 2.5              -- seconds after a shot that the rounds and your health are followed
local WARM = 0.8               -- seconds between the stance being set and the shot
local EQUIP_SETTLE = 1.2       -- seconds after a new gun shows up in your hands before it is used
local SAMPLE = 0               -- seconds between looks at the rounds (every frame: a round is fast and a barrel burst is short)
local BARREL_TIME = 0.3
local BARREL_DIST = 150        -- cm
local STANCES = { "hip", "ads" }

-- row, name, kind (0 long gun, 1 pistol slot), magazine, class
local GUNS = {
    { "ChinaLake", "China Lake", 0, 3, "Launcher_ChinaLake_Child_C" },
    { "MiniThumper", "Mini Thumper", 1, 1, "Launcher_Thumper_Child_C" },
}

local S -- the run

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end
local function put(text)
    local f = io.open(OUT, "a")
    if f then f:write(text, "\n") f:close() end
end
local function say(text) print("[PvEDirector] launcher test: " .. text .. "\n") end

local function controller()
    local pc = FindFirstOf("MainPlayerController_C")
    if not (pc and pc:IsValid()) then return nil end
    local pawn = pc.Pawn
    if not (pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return nil end
    return pc
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
local function setAds(pc, want)
    pcall(function()
        local pawn = pc.Pawn
        if pawn:IsTargeting() ~= want then pawn:ServerSetTargeting(want) end
    end)
end
local function centre(pc)
    if not S.c then return end
    pcall(function() pc:SetControlRotation({ Pitch = S.c.Pitch, Yaw = S.c.Yaw, Roll = 0 }) end)
end
local function hp(pc)
    local ok, v = pcall(function() return pc.Pawn.Health end)
    return ok and type(v) == "number" and v or nil
end
local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function loc(o)
    local ok, v = pcall(function() local l = o:K2_GetActorLocation() return { X = l.X, Y = l.Y, Z = l.Z } end)
    return ok and v or nil
end

-- Big text on the screen (the same widget the other tests use). banner(nil) hides it.
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

local function finish(why)
    banner(why)
    S.doneAt = os.clock() + 12
    S.stage = "done"
    put(("END | %s | shots %d, at the barrel %d, self hits %d, ok %d"):format(why, S.n, S.barrel, S.selfhit, S.ok))
    say(why)
end

local function nextShot()
    S.shot = S.shot + 1
    if S.shot > SHOTS then
        S.shot, S.si = 1, S.si + 1
        if S.si > #STANCES then
            S.si, S.gi = 1, S.gi + 1
            if S.gi > #GUNS then return finish("LAUNCHER TEST DONE: bridge/launcher_test.txt") end
            S.stage, S.step, S.at = "swap", 1, os.clock()
            return
        end
    end
    S.stage, S.at = "ready", os.clock()
end

-- Every Proj40mm_C the game has (pooled, so most sit unused): its place.
local function rounds()
    local out = {}
    for _, p in ipairs(FindAllOf("Proj40mm_C") or {}) do
        if valid(p) then
            local l = loc(p)
            if l then
                local ex
                pcall(function() ex = p.bExploded end)
                out[p:GetAddress()] = { l = l, ex = ex and true or false }
            end
        end
    end
    return out
end

local function report(pc, gun)
    local B = S.fire
    local pawnAt = B.pawnAt
    local moved, lines, barrel, firstEx = 0, {}, false, nil
    local order = {}
    for addr in pairs(B.r) do order[#order + 1] = addr end
    table.sort(order, function(a, b) return B.r[a].t0 < B.r[b].t0 end)
    for _, addr in ipairs(order) do
        local r = B.r[addr]
        moved = moved + 1
        local startD = dist(r.start, pawnAt)
        local endD = dist(r.last, pawnAt)
        local exT = r.exT and ("%.2f"):format(r.exT) or "no"
        lines[#lines + 1] = ("ROUND | %s | %s | %d | %s | left +%.2f s, first seen %.0f cm from you, ended %.0f cm from you, exploded %s s"):format(
            gun[1], STANCES[S.si], S.shot, tostring(addr), r.t0, startD, endD, exT)
        if r.exT and (r.exT <= BARREL_TIME or endD <= BARREL_DIST) then barrel = true end
        if r.exT and (not firstEx or r.exT < firstEx) then firstEx = r.exT end
        for _, s in ipairs(r.track) do
            lines[#lines + 1] = ("  | %.2f | %.0f %.0f %.0f | %.0f cm | %s"):format(s.t, s.l.X, s.l.Y, s.l.Z, dist(s.l, pawnAt), tostring(s.ex))
        end
    end
    local lost = (B.hp0 and B.hpMin) and (B.hp0 - B.hpMin) or 0
    local verdict
    if barrel or (B.hpLossAt and B.hpLossAt <= BARREL_TIME) then verdict = "BARREL"; S.barrel = S.barrel + 1
    elseif lost > 0 then verdict = "SELF HIT"; S.selfhit = S.selfhit + 1
    else verdict = "OK"; S.ok = S.ok + 1 end
    if moved ~= 1 then verdict = verdict .. (", " .. moved .. " ROUNDS") end
    put(("SHOT | %s | %s | %d | rounds %d | health %s -> %s (lost %.0f, first loss %s) | %s"):format(gun[1], STANCES[S.si], S.shot, moved,
        tostring(B.hp0), tostring(B.hpMin), lost, B.hpLossAt and ("+%.2f s"):format(B.hpLossAt) or "none", verdict))
    for _, l in ipairs(lines) do put(l) end
    S.n = S.n + 1
    say(("%s %s shot %d: %s"):format(gun[2], STANCES[S.si], S.shot, verdict))
end

function M.tick(now, pc)
    if not S then
        if now - autoChk > 1 then
            autoChk = now
            local fa = io.open(AUTO, "r")
            if fa then
                local label = (fa:read("*a") or ""):match("%S+") or "run"
                fa:close()
                local p = pc.Pawn
                if valid(p) and p:GetClass():GetFName():ToString() == "PlayerPawn_C" then
                    autoSince = autoSince or now
                    if now - autoSince > 10 then
                        os.remove(AUTO)
                        autoSince = nil
                        M.start(label)
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
    local gun = GUNS[S.gi]
    local g = heldGun(pc)

    if S.stage == "swap" then
        banner(("LAUNCHER TEST: GETTING THE %s (%d of %d)"):format(gun[2]:upper(), S.gi, #GUNS))
        if S.step == 1 then
            if g and classOf(g) == gun[5] then S.step, S.at = 4, now return end
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
                S.shot, S.si = SHOTS, #STANCES
                return nextShot()
            end
            S.step, S.at = 4, now
        elseif S.step == 4 then
            if g and classOf(g) == gun[5] then
                S.sawAt = S.sawAt or now
                if now - S.sawAt >= EQUIP_SETTLE then
                    S.sawAt = nil
                    if not S.c then
                        local ok, r = pcall(function() return pc:GetControlRotation() end)
                        if ok and r then S.c = { Pitch = r.Pitch, Yaw = r.Yaw } end
                        if not S.c then return end
                        put(("RUN | centre pitch %.3f yaw %.3f, health %s"):format(S.c.Pitch, S.c.Yaw, tostring(hp(pc))))
                    end
                    local parts = {}
                    for _, f in ipairs({ "VerticalRecoil", "VerticalRecoilADS", "FireRate", "AccuracyMultiplier" }) do
                        local ok, v = pcall(function() return g.WeaponConfig[f] end)
                        parts[#parts + 1] = f .. "=" .. (ok and tostring(v) or "?")
                    end
                    pcall(function() parts[#parts + 1] = "clip=" .. tostring(g.CurrentAmmoInClip) end)
                    put(("GUN | %s | class=%s %s"):format(gun[1], tostring(classOf(g)), table.concat(parts, " ")))
                    S.shot, S.si = 0, 1
                    return nextShot()
                end
            else
                S.sawAt = nil
                if now - S.at > 10 then
                    put(("GUN | %s | skipped: it never showed up in your hands"):format(gun[1]))
                    S.shot, S.si = SHOTS, #STANCES
                    return nextShot()
                end
            end
        end
        S.prevClass = g and classOf(g) or S.prevClass
        return
    end

    if not g or classOf(g) ~= gun[5] then
        S.lostAt = S.lostAt or now
        if now - S.lostAt > 2 then S.stage, S.step, S.at = "swap", 1, now end
        return
    end
    S.lostAt = nil

    if S.stage == "ready" then
        banner(("%s, %s, shot %d of %d: DO NOT MOVE OR CLICK"):format(gun[2]:upper(), STANCES[S.si]:upper(), S.shot, SHOTS))
        centre(pc)
        setAds(pc, STANCES[S.si] == "ads")
        if now - S.at < WARM then return end
        local clip
        pcall(function() clip = g.CurrentAmmoInClip end)
        local reloading = false
        pcall(function() reloading = g:IsReloading() end)
        if (clip or 1) <= 0 or reloading then
            if now - S.at > 10 then
                put(("SHOT | %s | %s | %d | skipped: the gun would not be ready (clip %s)"):format(gun[1], STANCES[S.si], S.shot, tostring(clip)))
                return nextShot()
            end
            return
        end
        -- fire: health back to full, the rounds' places noted, then the trigger
        pcall(function() pawn.Health = pawn.MaxHealth end)
        local pre = rounds()
        S.fire = { t = now, hp0 = hp(pc), hpMin = hp(pc), pawnAt = loc(pawn) or { X = 0, Y = 0, Z = 0 }, pre = pre, r = {}, nextLook = now }
        S.base = nil
        local okF = pcall(function() g:ServerStartFire() end)
        S.stopAt = now + 0.1
        if not okF then put(("SHOT | %s | %s | %d | ServerStartFire failed"):format(gun[1], STANCES[S.si], S.shot)) end
        S.stage = "watch"
        return
    end

    if S.stage == "watch" then
        local B = S.fire
        local t = now - B.t
        banner(("%s, %s, shot %d of %d: WATCHING"):format(gun[2]:upper(), STANCES[S.si]:upper(), S.shot, SHOTS))
        if S.stopAt and now >= S.stopAt then
            pcall(function() g:ServerStopFire() end)
            S.stopAt = nil
        end
        local h = hp(pc)
        if h and B.hpMin and h < B.hpMin then
            B.hpMin = h
            B.hpLossAt = B.hpLossAt or t
        end
        if now >= B.nextLook then
            B.nextLook = now + SAMPLE
            local cur = rounds()
            for addr, c in pairs(cur) do
                local pre = B.pre[addr]
                local r = B.r[addr]
                if not r and (not pre or dist(c.l, pre.l) > 5) then
                    r = { t0 = t, start = c.l, last = c.l, track = {}, lastTrack = -1 }
                    B.r[addr] = r
                end
                if r then
                    r.last = c.l
                    if c.ex and not r.exT then r.exT = t end
                    if t - r.lastTrack >= 0.1 then
                        r.lastTrack = t
                        r.track[#r.track + 1] = { t = t, l = c.l, ex = c.ex }
                    end
                end
            end
        end
        if t >= WATCH then
            if S.stopAt then pcall(function() g:ServerStopFire() end) S.stopAt = nil end
            report(pc, gun)
            S.fire = nil
            nextShot()
            S.at = now + 1 -- a second more before the next shot
        end
    end
end

function M.start(label)
    local pc = controller()
    if not pc then return "In a raid, on foot" end
    if os.remove(OUT) then end
    put(("RUN | launcher test %s | %s | 2 launchers, %d shots each stance, hip then ads"):format(os.date("%Y-%m-%d %H:%M:%S"), label or "run", SHOTS))
    local b = bottomlessOn()
    S = { gi = 1, si = 1, shot = 0, stage = "swap", step = 1, at = os.clock(), n = 0, barrel = 0, selfhit = 0, ok = 0 }
    say("started (bottomless " .. tostring(b) .. ")")
    return "Launcher test: stand 5 to 10 m from a wall, look at it, and keep your hands off the mouse"
end

function M.stop()
    if S then
        put("END | stopped by hand")
        S = nil
        banner(nil)
    end
    return "Launcher test stopped"
end

function M.actions()
    local function inRaid() return controller() ~= nil end
    return {
        { id = "launchertest", label = function() return S and "Launcher test: running (click to stop)" or "Launcher test" end,
          help = "Face a wall 5 to 10 m away and let it run: it fires both launchers by itself", when = inRaid, unusable = "In a raid, on foot",
          run = function() if S then return M.stop() end return M.start("menu") end },
    }
end

return M
