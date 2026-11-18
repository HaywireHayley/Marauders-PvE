-- Armour test (tools/armour_test, test installs only; never part of the shipped mod). Reads the game's own damage numbers by
-- shooting dummies and writes them to bridge/armour_test.txt (tools/armour_test/README.md says how to run it and read it).
-- One raider at a time stands 5 m in front of you (where you were looking when you clicked), wearing ONE piece through the game's kit
-- step (pve_roll_kit). Hold fire; the view is locked on the part under test every frame (before and after the game's own frame), so
-- recoil does not matter. Only hits whose hit zone (a line trace from your camera, the same one the shotgun pellets use) is the part
-- under test count. The dummy has 100000 health and is put back after every hit, so it never dies.
-- Order of the run:
--   1. a pass that does not shoot: every piece is put on a dummy in turn and the meshes it ends up wearing are logged
--      ("mesh | ..." lines), because the damage code finds a bot's armour by mesh. Then a banner says "OKAY, KILL THEM ALL".
--   2. the Liberator (slot 2), 5 shots per part: nothing worn (torso without the mod's pellets, torso and head with them), two
--      vests and two helmets (the mod's pellets are on for those dummies).
--   3. the STG44 (slot 1), 5 hits per part: nothing worn (torso, head, arm, leg), every vest (torso, arm, leg), every helmet (head,
--      arm, leg). A banner says which gun to hold whenever the dummy wants the other one.
-- Needs bottomless mags (so neither gun runs dry) and botdamage.lua's shotgun pellets. Every other AI on the map is killed when the
-- test starts and every 5 s.
--   vest:   rating = base - damage taken            (torso, zone multiplier 1)
--   helmet: rating = base - damage taken / 3.5      (head; the bare head dummy took 3.5 twice, 416.5, so it is not used)
-- Loaded by armourtest_hook.lua (installed by tools/armour_test/install.ps1), which gives it the tick, the bots list and the F9 button.
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local PROJECT = require("pveproject")
local D = {}

local OUT = PROJECT .. "bridge/armour_test.txt"
local ITEM_TABLE = "/SIGISPlugin/ExampleBlueprints/SIGIS_ExampleItemData.SIGIS_ExampleItemData"
local RAIDER = "/Game/AI/GOAPNodeBot_Raider"
local STG, LIB = "Rifle_STG44_Child_C", "Shotgun_Liberator_Child_C"
local GUN_SHORT = { [STG] = "stg44", [LIB] = "liberator" }
local GUN_PROMPT = { [STG] = "HOLD THE STG44 (PRESS 1)", [LIB] = "HOLD THE LIBERATOR (PRESS 2)" }
local BASE = 34 -- the STG44's damage per hit (the dummy wearing nothing measures it again)
local HEAD_MULT = 3.5
local HITS, SHOTS = 5, 5
local DISTANCE = 500 -- cm
local DUMMY_HEALTH = 100000
local rollKit = package.loadlib(PROJECT .. "native/pvepatch.dll", "pve_roll_kit")

-- Each part: the hit zones (AreaHitType) that count, the bones to aim at in turn (a bone whose line meets another zone first is
-- given up on after a few misses), and where to aim if no bone can be read (offset from the dummy's centre: forward, side, up).
local ZONES = {
    torso = { area = { [2] = true }, sockets = { "spine_03" }, off = { 0, 0, 35 } },
    head = { area = { [1] = true }, sockets = { "head" }, off = { 0, 0, 77 } },
    arm = { area = { [3] = true, [4] = true }, sockets = { "lowerarm_r", "lowerarm_l", "upperarm_r", "upperarm_l" }, off = { 0, 35, 30 } },
    leg = { area = { [5] = true, [6] = true }, sockets = { "calf_r", "calf_l", "thigh_r", "thigh_l" }, off = { 0, 15, -45 } },
}

local S -- the run: { plan, full, mode, i, prep, cur, loc, yaw, cls, tbl, results, fails, note, gunMsg }

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end

local function put(text)
    local f = io.open(OUT, "a")
    if f then f:write(text, "\n") f:close() end
end

local function say(text) print("[PvEDirector] armour test: " .. text .. "\n") end

local function controller()
    local pc = FindFirstOf("MainPlayerController_C")
    if not (pc and pc:IsValid()) then return nil end
    local pawn = pc.Pawn
    if not (pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return nil end
    return pc
end

-- Big text on the screen (the F9 menu is shut in a raid): a widget of its own on the debug host class. banner(nil) hides it.
local BANNER
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local function banner(text)
    pcall(function()
        if text == nil then
            if BANNER and valid(BANNER.host) then BANNER.host:SetVisibility(1) end -- Collapsed
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
            t.Font.Size = 40
            local s2 = root:AddChildToCanvas(t)
            s2:SetPosition({ X = 390, Y = 108 })
            s2:SetSize({ X = 1140, Y = 60 })
            host:AddToViewport(5020)
            BANNER = { host = host, text = t }
        end
        BANNER.text:SetText(FText(text))
        BANNER.host:SetVisibility(3) -- HitTestInvisible: never takes a click
    end)
end

-- The meshes the dummy wears on its helmet ("Helemt") and vest ("ChestSlot") slots, as botdamage.lua reads them.
local function wornMeshes(bot)
    local head, body = "none", "none"
    pcall(function()
        local comps = bot:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
        for i = 1, #comps do
            local c = comps[i]:get()
            if valid(c) then
                local name = c:GetFName():ToString()
                if (name == "Helemt" or name == "ChestSlot") and valid(c.SkeletalMesh) then
                    local mesh = c.SkeletalMesh:GetFName():ToString()
                    if name == "Helemt" then head = mesh else body = mesh end
                end
            end
        end
    end)
    return head, body
end

local function loadClass(path)
    local name = path:match("([^/]+)$")
    local full = path .. "." .. name .. "_C"
    local c = StaticFindObject(full)
    if not (c and c:IsValid()) then pcall(LoadAsset, path .. "." .. name) c = StaticFindObject(full) end
    return (c and c:IsValid()) and c or nil
end

local function median(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    if #c == 0 then return nil end
    return c[(#c + 1) // 2]
end

-- The dummies: { gun, row (nil = nothing worn), kind ("body" vest, "head" helmet), zones = { { z, reg } } }. reg = the dummy is
-- handed to the damage code as a bot (so the mod's shotgun pellets and refunds see it); false = the game alone.
local function plan()
    local f = io.open(PROJECT .. "assets/saves/items.json", "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    local chests, helmets, have = {}, {}, {}
    for name, body in text:gmatch('"([^"]+)"%s*:%s*(%b{})') do
        local ty = tonumber(body:match('"type"%s*:%s*(%-?%d+)'))
        if not name:find("Test", 1, true) then
            if ty == 7 then chests[#chests + 1] = name have[name] = true
            elseif ty == 4 then helmets[#helmets + 1] = name have[name] = true end
        end
    end
    table.sort(chests)
    table.sort(helmets)
    local list = {}
    local function add(gun, row, kind, zones)
        if row and not have[row] then return end
        list[#list + 1] = { gun = gun, row = row, kind = kind, zones = zones }
    end
    local function Z(...) local t = {} for _, z in ipairs({ ... }) do t[#t + 1] = { z = z } end return t end
    add(LIB, nil, "body", { { z = "torso", reg = false }, { z = "torso", reg = true }, { z = "head", reg = true } })
    add(LIB, "PouchRig", "body", { { z = "torso", reg = true } })
    add(LIB, "FullPanzerChest", "body", { { z = "torso", reg = true } })
    add(LIB, "LeatherCap", "head", { { z = "head", reg = true } })
    add(LIB, "HeavyStahlhelmHelmet", "head", { { z = "head", reg = true } })
    add(STG, nil, "body", Z("torso", "head", "arm", "leg"))
    for _, r in ipairs(chests) do add(STG, r, "body", Z("torso", "arm", "leg")) end
    for _, r in ipairs(helmets) do add(STG, r, "head", Z("head", "arm", "leg")) end
    return list
end

-- Every mesh on the dummy stops blocking the channels the capsules block, so a shot reaches the hit zone behind it.
local CHANNELS = { 3, 9, 10, 11, 12, 13, 14, 15 } -- what the hit capsules block (as botdamage.lua)
local function fixMeshes(bot)
    local comps = bot:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    for i = 1, #comps do
        local c = comps[i]:get()
        if valid(c) then
            local ok, class = pcall(function() return c:GetClass():GetFName():ToString() end)
            if ok and (class == "SkeletalMeshComponent" or class == "StaticMeshComponent") then
                for _, ch in ipairs(CHANNELS) do pcall(function() c:SetCollisionResponseToChannel(ch, 0) end) end
            end
        end
    end
end

local function gunName(pc)
    local name
    pcall(function()
        local g = pc.Pawn.CurrentWeapon
        if valid(g) then name = g:GetClass():GetFName():ToString() end
    end)
    return name
end

-- The hit zone (AreaHitType: 1 head, 2 body, 3 and 4 arms, 5 and 6 legs) a line from your camera meets on the dummy, or nil.
local function zoneOfShot(pc, bot)
    local pawn = pc.Pawn
    local cam = pc.PlayerCameraManager
    local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local dir = kml:GetForwardVector({ Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0 })
    local from = { X = loc.X + dir.X * 50, Y = loc.Y + dir.Y * 50, Z = loc.Z + dir.Z * 50 }
    local to = { X = loc.X + dir.X * 3000, Y = loc.Y + dir.Y * 3000, Z = loc.Z + dir.Z * 3000 }
    local out = {}
    local nocol = { R = 0, G = 0, B = 0, A = 0 }
    if not Out.call(ksl, "LineTraceSingle", pc, from, to, 0, false, { pawn }, 0, out, true, nocol, nocol, 0) then return nil end
    local actor, comp = out.Actor and out.Actor:Get(), out.Component and out.Component:Get()
    if not (valid(actor) and actor:GetAddress() == bot:GetAddress()) then return nil end
    if not valid(comp) then return nil end
    local ok, v = pcall(function() return comp.AreaHitType end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function killBot(bot)
    if valid(bot) then
        local ctrl
        pcall(function() ctrl = bot:GetController() end)
        if valid(ctrl) then pcall(function() ctrl:K2_DestroyActor() end) end
        pcall(function() bot:K2_DestroyActor() end)
    end
end

-- The key a measurement is stored under, and what its line in the file calls it.
local function keyOf(p, zs)
    return (p.gun == LIB and "lib|" or "") .. (p.row or "none") .. "|" .. zs.z .. (zs.reg == false and "|native" or "")
end

local function finishAll(why)
    killBot(S.cur and S.cur.bot)
    killBot(S.prep and S.prep.bot)
    banner(nil)
    if S.mode == "scan" then
        put("")
        put("stopped in the mesh pass (" .. why .. ")")
        say(why .. ", see bridge/armour_test.txt")
        S = nil
        return
    end
    local res = S.results
    local function med(k) return res[k] and res[k].med end
    local base = med("none|torso") or BASE
    put("")
    put(("SUMMARY (%s): base damage on a bare torso %.1f, head multiplier %.2f used for helmets"):format(why, base, HEAD_MULT))
    put(("bare dummy: head %s (x%s of base), arm %s, leg %s"):format(med("none|head") and ("%.1f"):format(med("none|head")) or "?",
        med("none|head") and ("%.2f"):format(med("none|head") / base) or "?", med("none|arm") and ("%.1f"):format(med("none|arm")) or "?",
        med("none|leg") and ("%.1f"):format(med("none|leg")) or "?"))
    put("rating | slot | row | torso or head | arm | leg | mesh")
    for _, p in ipairs(S.full) do
        if p.gun == STG and p.row then
            local main = med(p.row .. "|" .. (p.kind == "body" and "torso" or "head"))
            local rating
            if main then rating = p.kind == "body" and (base - main) or (base - main / HEAD_MULT) end
            local r = res[p.row .. "|" .. (p.kind == "body" and "torso" or "head")]
            put(("%s | %s | %s | %s | %s | %s | %s"):format(rating and ("%.1f"):format(rating) or "unknown", p.kind == "body" and "chest" or "helmet",
                p.row, main and ("%.1f"):format(main) or "none", med(p.row .. "|arm") and ("%.1f"):format(med(p.row .. "|arm")) or "none",
                med(p.row .. "|leg") and ("%.1f"):format(med(p.row .. "|leg")) or "none", r and r.mesh or "?"))
        end
    end
    put("")
    put("LIBERATOR (damage per shot, median of 5): row | zone | median")
    for _, p in ipairs(S.full) do
        if p.gun == LIB then
            for _, zs in ipairs(p.zones) do
                local m = med(keyOf(p, zs))
                put(("%s | %s%s | %s"):format(p.row or "nothing worn", zs.z, zs.reg == false and " (the game alone)" or " (with the mod's pellets)",
                    m and ("%.1f"):format(m) or "no shots counted"))
            end
        end
    end
    say(why .. ", see bridge/armour_test.txt")
    S = nil
end

-- A dummy that cannot be hurt until it is in place: 100000 health and no damage from the moment it exists.
local function shield(bot)
    pcall(function() bot.Health = DUMMY_HEALTH end)
    pcall(function() bot.bCanBeDamaged = false end)
end

-- The next dummy is made beside the one being shot (3 m to its right) while you shoot, and swapped in the moment the last one is done.
local function prepare(i)
    S.prep = { i = i, phase = "spawn", at = 0 }
end

local function prepStep(now, pc)
    local pr = S.prep
    local p = S.plan[pr.i]
    put(("  step %d %s %s"):format(pr.i, pr.phase, p.row or "bare")) -- (a crash leaves the last one written)
    if pr.phase == "spawn" then
        local side = math.rad(S.yaw + 90)
        local at = { X = S.loc.X + math.cos(side) * 300, Y = S.loc.Y + math.sin(side) * 300, Z = S.loc.Z }
        local bot = pc.Pawn:GetWorld():SpawnActor(S.cls, at, { Pitch = 0, Yaw = S.yaw + 180, Roll = 0 })
        if not valid(bot) then
            S.fails = S.fails + 1
            if S.fails >= 2 then return finishAll("stopped: the game stopped letting a dummy spawn") end
            pr.at = now + 1
            return
        end
        S.fails, pr.bot = 0, bot
        shield(bot)
        pr.phase, pr.at = "dress", now + 0.3
    elseif pr.phase == "dress" then
        local idx = p.row and FName(p.row):GetComparisonIndex() or 0
        local helmet, chest = 0, 0
        if p.kind == "head" then helmet = idx else chest = idx end
        local ok, err = pcall(rollKit, math.tointeger(pr.bot:GetAddress()), math.tointeger(S.tbl:GetAddress()), 0, 0, helmet, chest, 0)
        if not ok then put("  kit error on " .. tostring(p.row) .. ": " .. tostring(err)) end
        shield(pr.bot)
        pr.phase, pr.at = "fit", now + 0.8
    elseif pr.phase == "fit" then
        pcall(function() require("hitzones").ensure(pr.bot) end)
        pcall(fixMeshes, pr.bot)
        local ctrl
        pcall(function() ctrl = pr.bot:GetController() end)
        if valid(ctrl) then pcall(function() ctrl:SetActorTickEnabled(false) end) end
        pcall(function() pr.bot:SetActorTickEnabled(false) end)
        shield(pr.bot)
        pr.phase = "ready"
    end
end

local function zonesText(p)
    local t = {}
    for _, zs in ipairs(p.zones) do t[#t + 1] = zs.z end
    return table.concat(t, ", ")
end

-- A zone of the current dummy starts: its own count, its own first bone to aim at.
local function startZone(c, now)
    c.hits, c.ignored, c.miss, c.cand, c.tries, c.acc = {}, 0, 0, 1, 0, nil
    c.settle = now + 0.4
    c.last = nil
end

-- The prepared dummy takes the spot; the one after it starts to be made.
local function promote(now)
    local pr = S.prep
    pcall(function() pr.bot:K2_TeleportTo(S.loc, { Pitch = 0, Yaw = S.yaw + 180, Roll = 0 }) end)
    pcall(function() pr.bot.Health = DUMMY_HEALTH end)
    pcall(function() pr.bot.bCanBeDamaged = true end)
    local p = S.plan[pr.i]
    S.cur = { bot = pr.bot, i = pr.i, zi = 1, entry = { bot = pr.bot } }
    startZone(S.cur, now)
    say(("dummy %d of %d: %s, %s (%s: %s)"):format(pr.i, #S.plan, GUN_SHORT[p.gun], p.row or "nothing worn", p.gun == LIB and "5 shots each" or "5 hits each", zonesText(p)))
    S.prep = nil
    if pr.i < #S.plan then prepare(pr.i + 1) end
end

local AI_CLASSES = { "BotPawn_C", "BotPawnGuard_C", "BotPawnMilitary_C", "GOAPNodeBot_Raider_C", "GOAPNodeBot_Boss_C" }

-- Every AI on the map but the dummies dies, by damage so the director's own death handling runs.
local function killAI(pc)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local dtype = StaticFindObject("/Script/Engine.DamageType")
    local keep = {}
    for _, b in ipairs({ S.cur and S.cur.bot, S.prep and S.prep.bot }) do
        if valid(b) then keep[b:GetAddress()] = true end
    end
    local weapon
    pcall(function() weapon = pc.Pawn.CurrentWeapon end)
    local n = 0
    for _, cn in ipairs(AI_CLASSES) do
        for _, b in ipairs(FindAllOf(cn) or {}) do
            if valid(b) and not keep[b:GetAddress()] then
                local h
                pcall(function() h = b.Health end)
                if type(h) == "number" and h > 0 then
                    pcall(function() gs:ApplyDamage(b, 1000000, pc, weapon, dtype) end)
                    n = n + 1
                end
            end
        end
    end
    if n > 0 then say(("killed %d other AI"):format(n)) end
end

-- The view on the part under test (the bone's own position, or an offset from the dummy's centre if the bone can't be read).
local function aimAt(pc, bot, zone, cand)
    local Z = ZONES[zone]
    local target
    pcall(function() target = bot.Mesh:GetSocketLocation(FName(Z.sockets[(cand - 1) % #Z.sockets + 1])) end)
    if not target then
        local l = bot:K2_GetActorLocation()
        local yaw = math.rad(S.yaw + 180)
        local fwd, side = Z.off[1], Z.off[2] * (cand % 2 == 1 and 1 or -1)
        target = { X = l.X + math.cos(yaw) * fwd - math.sin(yaw) * side, Y = l.Y + math.sin(yaw) * fwd + math.cos(yaw) * side, Z = l.Z + Z.off[3] }
    end
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local rot = kml:FindLookAtRotation(pc.PlayerCameraManager:GetCameraLocation(), target)
    pc:SetControlRotation({ Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0 })
end

-- Which gun the dummy wants in your hands: say so on the screen while it is the other one.
local function gunPrompt(p, gun, first)
    if gun == p.gun then
        if S.gunMsg then S.gunMsg = nil if not S.bannerOff then banner(nil) end end
        return true
    end
    if S.gunMsg ~= p.gun then
        S.gunMsg = p.gun
        banner((first and "OKAY, KILL THEM ALL: " or "") .. GUN_PROMPT[p.gun])
    end
    return false
end

local function zoneDone(c, p, zs)
    local med = median(c.hits)
    local parts = {}
    for _, d in ipairs(c.hits) do parts[#parts + 1] = ("%.1f"):format(d) end
    local hm, bm = wornMeshes(c.bot)
    S.results[keyOf(p, zs)] = { med = med, mesh = p.kind == "body" and bm or hm }
    put(("%s | %s | %s | median %.1f | %s %s | %d other hits ignored | helmet mesh %s, vest mesh %s"):format(GUN_SHORT[p.gun], p.row or "nothing worn",
        zs.z .. (zs.reg == false and " (game alone)" or ""), med, p.gun == LIB and "shots" or "hits", table.concat(parts, " "), c.ignored, hm, bm))
end

local function shoot(now, pc)
    local c = S.cur
    local p = S.plan[c.i]
    local zs = p.zones[c.zi]
    if not valid(c.bot) then S.cur = nil return end
    c.reg = zs.reg ~= false and p.gun == LIB -- (only the shotgun parts are handed to the damage code as a bot)
    local zone = ZONES[zs.z]
    pcall(aimAt, pc, c.bot, zs.z, c.cand)
    local h = c.bot.Health
    if type(h) ~= "number" then return end
    local gun = gunName(pc)
    if not gunPrompt(p, gun, c.i == 1 and c.zi == 1 and S.bannerOff ~= nil) then c.last = h c.acc = nil return end
    if c.settle and now < c.settle then c.last = h return end
    c.settle = nil
    if not c.last then c.last = h return end
    if h < c.last - 0.001 then
        local delta = c.last - h
        pcall(function() c.bot.Health = DUMMY_HEALTH end)
        c.last = DUMMY_HEALTH
        local ok, area = pcall(zoneOfShot, pc, c.bot)
        if ok and area and zone.area[area] then
            if p.gun == LIB then
                c.acc = (c.acc or 0) + delta -- (a volley arrives as several health drops: added up until it goes quiet)
                c.accAt = now
            else
                c.hits[#c.hits + 1] = delta
            end
        else
            c.ignored = c.ignored + 1
            c.miss = c.miss + 1
            if #c.hits == 0 and c.miss >= 4 then -- the line meets another zone first: the next bone for this part
                c.miss, c.cand, c.tries = 0, c.cand + 1, c.tries + 1
            end
        end
    elseif h > c.last then
        c.last = h
    end
    if c.acc and now - c.accAt > 0.3 then
        c.hits[#c.hits + 1] = c.acc
        c.acc = nil
        if p.gun == LIB then -- (the volley's throw: back to the spot)
            pcall(function() c.bot:K2_TeleportTo(S.loc, { Pitch = 0, Yaw = S.yaw + 180, Roll = 0 }) end)
            pcall(function() c.bot:LaunchCharacter({ X = 0, Y = 0, Z = 0 }, true, true) end)
        end
    end
    local need = p.gun == LIB and SHOTS or HITS
    if #c.hits >= need or c.tries > 2 * #zone.sockets then
        if #c.hits > 0 then zoneDone(c, p, zs) else put(("%s | %s | %s | no hits counted (no bone of this part could be hit) ign=" .. c.ignored .. " tries=" .. c.tries):format(GUN_SHORT[p.gun], p.row or "nothing worn", zs.z)) end
        if c.zi < #p.zones then
            c.zi = c.zi + 1
            startZone(c, now)
        else
            killBot(c.bot)
            S.cur = nil
        end
    end
end

-- The no shooting pass: a ready dummy has its meshes read, is removed, and the next piece is made. After the last one the shooting
-- part starts over the full plan.
local function beginShooting(now)
    S.mode, S.plan, S.results = "shoot", S.full, {}
    put("")
    put("shooting part")
    banner("OKAY, KILL THEM ALL")
    say("okay, kill them all: hold fire at the dummy 5 m ahead (the banner says which gun)")
    S.bannerOff = now + 8
    prepare(1)
end

local function scanStep(now)
    local pr = S.prep
    local p = S.plan[pr.i]
    local head, body = wornMeshes(pr.bot)
    put(("mesh | %s | %s | helmet mesh %s | vest mesh %s"):format(p.kind == "body" and "vest" or "helmet", p.row or "nothing worn", head, body))
    killBot(pr.bot)
    local i = pr.i
    S.prep = nil
    if i < #S.plan then
        prepare(i + 1)
        banner(("ARMOUR TEST: reading the pieces, don't shoot yet (%d/%d)"):format(i + 1, #S.plan))
    else
        beginShooting(now)
    end
end

function D.tick(now, pc)
    if not S then return end
    if not (valid(pc) and valid(pc.Pawn)) then return end
    local ok, err = pcall(function()
        if now >= (S.nextKill or 0) then
            S.nextKill = now + 5
            killAI(pc)
        end
        if S.bannerOff and now >= S.bannerOff then S.bannerOff = nil if not S.gunMsg then banner(nil) end end
        if S.prep and S.prep.phase ~= "ready" and now >= S.prep.at then prepStep(now, pc) if not S then return end end
        if S.mode == "scan" then
            if S.prep and S.prep.phase == "ready" then scanStep(now) end
            return
        end
        if S.cur then
            shoot(now, pc)
        elseif S.prep and S.prep.phase == "ready" then
            promote(now)
        elseif not S.prep then
            finishAll("done, " .. #S.plan .. " dummies")
        end
    end)
    if not ok then
        put("ERROR " .. tostring(err))
        if S then finishAll("stopped by an error") end
    end
end

-- (after the game's own frame, so a recoil kick it just applied is undone before the next shot)
function D.afterFrame(pc)
    if not (S and S.mode == "shoot" and S.cur and valid(S.cur.bot)) then return end
    local p = S.plan[S.cur.i]
    local zs = p and p.zones[S.cur.zi]
    if zs then pcall(aimAt, pc, S.cur.bot, zs.z, S.cur.cand) end
end

-- The bots the damage code is to see besides the raid's own (botdamage.lua asks): the dummy, while a shotgun part is under way.
function D.entries()
    if S and S.mode == "shoot" and S.cur and S.cur.reg and valid(S.cur.bot) then return { S.cur.entry } end
    return nil
end

local function start()
    if S then
        finishAll("stopped by you")
        return "Armour test stopped"
    end
    local pc = controller()
    if not pc then return "In a raid, on foot" end
    local cls, tbl = loadClass(RAIDER), StaticFindObject(ITEM_TABLE)
    if not (tbl and tbl:IsValid()) then pcall(LoadAsset, (ITEM_TABLE:match("^[^.]+"))) tbl = StaticFindObject(ITEM_TABLE) end
    if not (cls and tbl and tbl:IsValid()) then return "Could not load the raider class or the item table" end
    if not rollKit then return "pvepatch.dll has no pve_roll_kit" end
    local list = plan()
    if not list then return "No assets/saves/items.json" end
    local l = pc.Pawn:K2_GetActorLocation()
    local yaw = pc.PlayerCameraManager:GetCameraRotation().Yaw
    local rad = math.rad(yaw)
    local scan = {} -- one dummy wearing nothing, then every piece once
    for _, p in ipairs(list) do if p.gun == STG then scan[#scan + 1] = p end end
    local f = io.open(OUT, "w")
    if f then
        f:write(("armour test %s: %d dummies (%d pieces to read first), 5 m ahead of (%.0f, %.0f) facing yaw %.0f\n"):format(os.date("%H:%M:%S"), #list, #scan, l.X, l.Y, yaw))
        f:close()
    end
    S = { plan = scan, full = list, mode = "scan", cls = cls, tbl = tbl, results = {}, fails = 0, yaw = yaw,
        loc = { X = l.X + math.cos(rad) * DISTANCE, Y = l.Y + math.sin(rad) * DISTANCE, Z = l.Z } }
    prepare(1)
    banner(("ARMOUR TEST: reading the pieces, don't shoot yet (1/%d)"):format(#scan))
    return ("Reading %d pieces first (about a minute, no shooting), then it says okay, kill them all"):format(#scan)
end

local function label()
    if not S then return "Armour test: start" end
    if S.mode == "scan" then return ("Armour test: reading the pieces, don't shoot (%d/%d, click stops)"):format(S.prep and S.prep.i or #S.plan, #S.plan) end
    local c = S.cur
    if not c then return "Armour test: getting the next dummy ready (click stops)" end
    local p = S.plan[c.i]
    local zs = p.zones[c.zi]
    return ("Armour test %d/%d, %s %s %s: %d/%d (click stops)"):format(c.i, #S.plan, GUN_SHORT[p.gun], p.row or "bare", zs.z, #c.hits,
        p.gun == LIB and SHOTS or HITS)
end

function D.actions()
    return { { id = "armourtest", label = label, help = "Bottomless mags on first; STG44 slot 1, Liberator slot 2",
        when = function() return controller() ~= nil end, unusable = "In a raid, on foot", run = start } }
end

return D
