-- Your shots at the mod's bots: armour, shotguns and the mesh collision that lets a shot reach the hit zones (issue #123).
--
-- hitzones.lua gives every bot the player's hit capsules, so the game's damage function reads a zone (head x3.5, body, arms,
-- legs x0.5). Three things are still missing on a bot, and this file does them:
--   1. Armour. The function takes the victim's armour rating off each hit (flat, before the zone multiplier) from its armour
--      items, and a bot has none: its helmet and vest are meshes only, so every hit did the full damage. The game's own rifle
--      damage cannot be changed from Lua, so a hit that did exactly a known gun's base damage times a zone multiplier gets the
--      armour handed back afterwards (health up by the rating times that multiplier).
--   2. Shotguns. Offline a shotgun's own pellets never reach the damage function (Liberator: 8 shots, 0 hits). Each shot (the
--      clip dropping) fires its 10 pellets of 18 from here: a line trace each inside a spread cone, the hit dealt through
--      GameplayStatics.ApplyDamage with the armour and the zone multiplier worked out here. A volley also throws the bots it hits.
--   3. Meshes. A bot's helmet, vest and backpack are skeletal meshes of their own, and like its body they block the weapon traces,
--      so a bullet that meets one first never reaches the capsule behind it and does the flat damage (a guard in a Security
--      helmet took 34 and 136 from the same shot). Every mesh on a bot ignores the channels the capsules block.
-- Armour covers what the game's own function covers (tested with every vest and helmet, one dummy per piece): a vest the body and
-- the arms, a helmet the head, nothing the legs.
-- BotDamage.frame(pc) runs every frame from main.lua's tick (CFG.PLAYER_DAMAGE = false leaves the game's own damage alone).
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local B = {}

local X -- context from the director: log, valid, bots

-- The channels the hit capsules block (hit_capsule in pvepatch.c: Visibility 3, then 9 to 15).
local CAPSULE_CHANNELS = { 3, 9, 10, 11, 12, 13, 14, 15 }

local REFUND_WINDOW = 0.5 -- a health drop counts as your shot's only this long after the gun's clip dropped (seconds)
local PELLETS, PELLET_DAMAGE = 10, 18 -- a shotgun shot (the Guilds 1.0 notes)
local PUSH = 900 -- cm/s, the throw of a shotgun volley: a stand in for the knockback the game once applied (not read from the game)

local function valid(o) return X.valid(o) end
local function warn(key, text)
    B.warned = B.warned or {}
    if B.warned[key] then return end
    B.warned[key] = true
    X.log("bot damage: " .. text)
end

-- Armour ratings by the mesh the bot wears (the helmet is the component "Helemt", the vest "ChestSlot"), read off the game
-- itself: a dummy wearing one piece was shot with the STG44 (34 a hit) and the damage taken gave the flat armour subtracted
-- before the zone multiplier (vests: torso; helmets: head, divided by the 3.5 head multiplier). Every vest and helmet the game
-- has is here, named by the mesh it puts on (the row it comes from is the comment). A mesh not listed is matched by the longest
-- listed name inside it, else rated 0 and logged once.
local VESTS = {
    BA_Flak_Vest_Heavy_Skel_01 = 13, -- BAHeavyVest
    BA_Flak_Vest_Skel_01 = 8, -- BAFlakVest
    CE_Full_Plate_Rig_Skel_01 = 10, -- CEFullPlate
    CE_Plate_Skel_01 = 9, -- CEPlate
    Full_Panzer_Armour_Skel_01 = 13, -- FullPanzerChest
    Full_Panzer_Rig_Skel_01 = 13, -- FullPanzerRig
    Full_Plate_Skel_01_Full_Plate_Skel_01 = 10, -- FullPlateChest
    Full_Sherman_Plate_Skel_01 = 12, -- FullShermanPlate
    Full_Sherman_Rig_Skel_01 = 12, -- FullShermanRig
    Half_Plate_Skel_01_Half_Plate_Skel_01 = 9, -- HalfPlateChest
    Heavy_Pilot_Armour_Skel_01 = 12, -- HeavyPilotArmourChest
    Leather_Jerkin_Skel_01_Leather_Jerkin_Skel_01 = 6, -- LeatherJerkinChest
    M1_Flak_Rig_Skel_01 = 7, -- M1FlakRig
    M1_Flak_Vest_Skel_01_M1_Flak_Vest_Skel_01 = 7, -- M1FlakChest
    M2_Flak_Vest_Skel_01_M2_Flak_Vest_Skel_01 = 7, -- M2FlakChest
    M3_Flak_Rig_Skel_01 = 8, -- Mk3FlakRig
    M3_Flak_Vest_Skel_01 = 8, -- MK3FlakVest
    Panzer_Armour_Skel_01 = 11, -- PanzerChest
    Panzer_Rig_Skel_01 = 11, -- PanzerRig
    Pilot_Armour_Skel_01 = 10, -- PilotArmourChest
    Plate_Rig_Skel_01 = 9, -- PlateRig
    Pouch_Rig_Skel_01 = 5, -- PouchRig
    Sherman_Plate_Skel_01 = 11, -- ShermanPlate
    Sherman_Rig_Skel_01 = 11, -- ShermanRig
}
local HELMETS = {
    BA_Helmet_Heavy_Skel_01 = 12, -- BAHeavyHelmet
    BA_Helmet_Skel_01 = 8, -- BAHelmet
    Baron_Cap_Skel_01 = 4, -- BaronCap
    Brodie_Helmet_Skel_01_Brodie_Helmet_Skel_01 = 7, -- BrodieHelmet
    Civilian_Helmet_Skel_01_Civilian_Helmet_Skel_01 = 5, -- CivilianHelmet
    Cloth_Cap_Skel_01 = 3, -- ClothCap
    Commando_Cap_Skel_01 = 4, -- CommandoCap
    Custom_PSH_Helmet_Skel_01 = 13, -- CustomPSHHelmet
    Guild_Beret_Skel_01 = 4, -- GuildBeret
    Guild_Helmet_Skel_01 = 7, -- GuildHelmet
    HeavyM1_Helmet_Skel_01 = 9, -- HeavyM1Helmet
    Heavy_Pilot_Helmet_Skel_01 = 11, -- HeavyPilotHelmet
    Heavy_Riot_Helmet_Skel_01 = 11, -- HeavyRiotHelmet
    Heavy_Stahlhelm_Skel_01 = 12, -- HeavyStahlhelmHelmet
    LeatherCap_Skel_01 = 5, -- LeatherCap
    M1_Helmet_Skel_01_M1_Helmet_Skel_01 = 7, -- M1Helmet
    M5_Helmet_Skel_01_M5_Helmet_Skel_01 = 10, -- M5Helmet
    PSH_Helmet_Skel_01 = 11, -- PSHHelmet
    Pilot_Helmet_Skel_01 = 10, -- PilotHelmet
    Pirate_Helmet_B_Skel_01 = 6, -- PirateHelmetBlue
    Pirate_Helmet_Skel_01 = 6, -- PirateHelmet
    Red_Stahlhelm_Skel_01 = 9, -- RedStahlhelmHelmet
    Riot_Helmet_Skel_01 = 8, -- RiotHelmet
    SAS_Beret_Skel_01 = 4, -- SASBeret
    SAS_Beret_Skel_02 = 4, -- BABeret
    Safety_Helmet_Skel_01_Safety_Helmet_Skel_01 = 6, -- SafetyHelmet
    Security_Helmet_Skel_01 = 7, -- SecurityHelmet
    Stahlhelm_Skel_01_Stahlhelm_Skel_01 = 7, -- StahlhelmHelmet
    Warden_Riot_Helmet_Skel_01 = 14, -- WardenRiotHelmet
    Welder_Mask_Skel_01_Welder_Mask_Skel_01 = 9, -- WeldersMask
}

local function rate(list, mesh)
    local r = list[mesh]
    if r then return r end
    local best -- (a mesh named a little differently: the longest listed name inside it)
    for name, v in pairs(list) do
        if mesh:find(name, 1, true) and (not best or #name > #best) then best, r = name, v end
    end
    if r then return r end
    warn("rating " .. mesh, "no armour rating for " .. mesh .. ", counted as 0")
    return 0
end

-- { head = rating, body = rating }, read once per bot (kept on its entry in raid.bots).
local function armour(e)
    local a = e.armour
    if a then return a end
    a = { head = 0, body = 0 }
    pcall(function()
        local comps = e.bot:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SkeletalMeshComponent"))
        for i = 1, #comps do
            local c = comps[i]:get()
            local name = c:GetFName():ToString()
            if (name == "Helemt" or name == "ChestSlot") and valid(c.SkeletalMesh) then
                local mesh = c.SkeletalMesh:GetFName():ToString()
                if name == "Helemt" then a.head = rate(HELMETS, mesh) else a.body = rate(VESTS, mesh) end
            end
        end
    end)
    e.armour = a
    return a
end

-- Damage per hit before armour, by weapon class, read off the logged hits of testing (DeLisle 38, DP28 35, Johnson and Mosin 40
-- match the patch notes). The pistols lose damage with range, so theirs is the close range hit: SPP1 32 at 127 to 616 cm,
-- 22 at 1635 cm, and a far hit that did less than base gets no armour back.
local BASE_DAMAGE = {
    Pistol_1911_G_Child_C = 30, Pistol_Mosin_Child_C = 40, Pistol_P08_Child_C = 23, Pistol_Welrod_Child_C = 36,
    Rifle_AC14_Child_C = 35, Rifle_APS_Rifle_Child_C = 34, Rifle_BAR_Child_C = 37, Rifle_Bren_MKII_Child_C = 36,
    Rifle_CustomMat49_Child_C = 24, Rifle_DP28_Child_C = 35, Rifle_DaewooK1_Child_C = 32, Rifle_DeLisle_Child_C = 38,
    Rifle_EM2_Child_C = 30, Rifle_FAL_Child_C = 37, Rifle_GreaseGun_Child_C = 25, Rifle_Johnson_Child_C = 40,
    Rifle_Klobb_Child_C = 19, Rifle_Krasa_Child_C = 32, Rifle_M16_Child_C = 32, Rifle_M1_Para_Child_C = 28,
    Rifle_M45_Child_C = 23, Rifle_M712_Special_Child_C = 24, Rifle_MG42_Child_C = 38, Rifle_MP40_Child_C = 25,
    Rifle_Mac10_Child_C = 24, Rifle_Mas44_Child_C = 39, Rifle_Mat49_Child_C = 22, Rifle_PPSH_Child_C = 23,
    Rifle_STG44_Child_C = 34, Rifle_SVT40_Child_C = 37, Rifle_SVU_Special_Child_C = 40, Rifle_Sten_Child_C = 21,
    Rifle_SterlingMk4_Regular_Child_C = 22, Rifle_Stoner63A_Child_C = 28, Rifle_Thompson_Child_C = 26,
    Rifle_Uzi_Child_C = 20, Rifle_ViperMK1_Child_C = 21,
    -- the variants differ from their base guns by a point or two, so the family match below misses them
    Rifle_M50reising_Child_C = 32, Pistol_Webley_Child_C = 38, Pistol_SPP1_Child_C = 32, Rifle_Thompson_Special_Child_C = 28,
    Rifle_SterlingMk4_Short_Child_C = 21, Rifle_SterlingMk4_Suppressed_Child_C = 23, Pistol_1911_Child_C = 28,
    Pistol_M712_Child_C = 28,
}
-- A gun without its own entry is matched by family (Heavy Thompson with the Thompson, and so on). A wrong value here cannot
-- hurt: a refund only fires when a hit is exactly base x a zone multiplier, so a mismatch gives no armour, not a wrong one.
local BASE_FAMILY = { { "Thompson", 26 }, { "Sterling", 22 }, { "MG42", 38 }, { "1911", 30 }, { "M712", 24 } }

local function baseDamage(gun)
    local base = BASE_DAMAGE[gun]
    if base then return base end
    for _, f in ipairs(BASE_FAMILY) do
        if gun:find(f[1], 1, true) then return f[2] end
    end
    return nil
end

-- A hit of `delta` health from `gun`: the health to hand back (0 if it was not a full damage hit on a zone, or nothing is worn).
-- A hit that killed is not refunded: the death has already run.
local function refund(e, delta, gun)
    -- only the rifle path: shotguns are dealt in pellets below (armour already off), and launchers, flares and melee are not armoured here
    if not (gun:find("^Rifle_") or gun:find("^Pistol_")) then return 0 end
    local base = baseDamage(gun)
    if not base then
        warn("base " .. gun, ("no base damage for %s, its first hit took %.1f (armour is not handed back for it)"):format(gun, delta))
        return 0
    end
    local ratio, mult = delta / base, nil
    -- head (4.0 seen on guards, 3.5 on soldiers), body and arms. Not legs: tested with every vest and helmet, a leg hit takes the
    -- same damage whatever is worn, so the game gives legs no armour and none is handed back for them.
    for _, m in ipairs({ 4, 3.5, 1 }) do
        if math.abs(ratio - m) < 0.03 then mult = m end
    end
    if not mult then return 0 end
    local a = armour(e)
    local rating = (mult >= 3.5) and a.head or a.body
    if rating <= 0 then return 0 end
    local give = math.min(rating, base) * mult
    local h = e.bot.Health
    if type(h) ~= "number" or h <= 0 then return 0 end
    return pcall(function() e.bot.Health = h + give end) and give or 0
end

-- Shotguns. The cone half angle in degrees by gun: guesses, the weapon's own spread was never found.
local CONE = { Shotgun_TrenchGun_Child_C = 2.0, Shotgun_Liberator_Child_C = 3.0, Shotgun_SawedOffDouble_Child_C = 4.5,
    Shotgun_Jackhammer_Child_C = 3.0, Shotgun_LongDouble_Child_C = 1.5, Shotgun_Terminator_Child_C = 3.0 }
local ZONE = { [1] = 3.5, [2] = 1, [3] = 1, [4] = 1, [5] = 0.5, [6] = 0.5 } -- AreaHitType: multiplier against bots

local pushQ = {} -- { bot, v, at, left, nudged }: a volley's throw, applied over the next moments

-- One bot's share of a volley: damage ApplyDamage with the armour off and the zone multiplier on (area is nil for a hit on a mesh).
local function pelletHit(ctx, e, area)
    local a = armour(e)
    -- (the vest covers the body and the arms, the helmet the head, nothing covers the legs: measured with every piece)
    local rating = (area == 1) and a.head or ((area == 2 or area == 3 or area == 4) and a.body or 0)
    local dmg = math.max(0, PELLET_DAMAGE - rating) * (ZONE[area] or 1)
    return pcall(function() ctx.gs:ApplyDamage(e.bot, dmg, ctx.pc, ctx.weapon, ctx.dtype) end)
end

local function pellets(pc, pawn, gun, volleys, bots)
    local cone = CONE[gun] or 3.0
    local cam = pc.PlayerCameraManager
    local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local ctx = { gs = StaticFindObject("/Script/Engine.Default__GameplayStatics"), dtype = StaticFindObject("/Script/Engine.DamageType"),
        pc = pc, weapon = pawn.CurrentWeapon }
    local entry = {}
    for _, e in ipairs(bots) do if valid(e.bot) then entry[e.bot:GetAddress()] = e end end
    local nocol = { R = 0, G = 0, B = 0, A = 0 }
    local push = {}
    for _ = 1, volleys do
        for _ = 1, PELLETS do
            local r, th = cone * math.sqrt(math.random()), math.random() * 2 * math.pi
            local dir = kml:GetForwardVector({ Pitch = rot.Pitch + r * math.sin(th), Yaw = rot.Yaw + r * math.cos(th), Roll = 0 })
            local from = { X = loc.X + dir.X * 150, Y = loc.Y + dir.Y * 150, Z = loc.Z + dir.Z * 150 }
            local to = { X = loc.X + dir.X * 5000, Y = loc.Y + dir.Y * 5000, Z = loc.Z + dir.Z * 5000 }
            local out = {}
            if Out.call(ksl, "LineTraceSingle", pc, from, to, 0, false, { pawn }, 0, out, true, nocol, nocol, 0) then
                local actor, comp = out.Actor and out.Actor:Get(), out.Component and out.Component:Get()
                local e = valid(actor) and entry[actor:GetAddress()]
                if e then
                    local area
                    if valid(comp) then
                        local ok, v = pcall(function() return comp.AreaHitType end)
                        if ok and type(v) == "number" then area = v end
                    end
                    local ok, err = pelletHit(ctx, e, area)
                    if not ok then warn("pellet", "a shotgun pellet's damage failed: " .. tostring(err)) end
                    local p = push[e]
                    if not p then p = { n = 0, x = 0, y = 0, z = 0, d = 0 } push[e] = p end
                    p.n, p.x, p.y, p.z, p.d = p.n + 1, p.x + dir.X, p.y + dir.Y, p.z + dir.Z, p.d + (out.Distance or 0)
                end
            end
        end
    end
    -- The throw: more pellets and a shorter range hit harder; the sawed off and the Terminator throw further.
    local base = PUSH * (gun:find("SawedOff") and 1.25 or gun:find("Terminator") and 1.15 or 1)
    for e, p in pairs(push) do
        local len = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
        local fall = math.max(0, math.min(1, (1000 - p.d / p.n) / 800))
        local k = base * (p.n / PELLETS) * fall
        if k > 20 and len > 0 then
            pushQ[#pushQ + 1] = { bot = e.bot, at = 0, left = 14,
                v = { X = p.x / len * k, Y = p.y / len * k, Z = p.z / len * k * 0.3 + k * 0.25 } }
        end
    end
end

-- A dead or ragdolled bot gets the velocity on all its bodies, a live one a nudge (once). Every 0.12 s, 14 times.
local function pushStep(now)
    for i = #pushQ, 1, -1 do
        local q = pushQ[i]
        if now >= q.at then
            local bot = q.bot
            if not valid(bot) then
                table.remove(pushQ, i)
            else
                local mesh = bot.Mesh
                local okS, sim = pcall(function() return mesh:IsSimulatingPhysics(FName("None")) end)
                local hp = bot.Health
                if okS and sim then
                    local ok = pcall(function() mesh:AddImpulseToAllBodiesBelow(q.v, FName("pelvis"), true, false) end)
                    if not ok then pcall(function() mesh:AddImpulse(q.v, FName("None"), true) end) end
                    table.remove(pushQ, i)
                elseif type(hp) == "number" and hp > 0 and not q.nudged then
                    q.nudged = true
                    pcall(function() bot:LaunchCharacter({ X = q.v.X * 0.3, Y = q.v.Y * 0.3, Z = 120 }, true, true) end)
                end
                q.left = q.left - 1
                q.at = now + 0.12
                if q.left <= 0 and pushQ[i] == q then table.remove(pushQ, i) end
            end
        end
    end
end

-- Every mesh on a bot (the body, the helmet, the vest, the backpack) stops blocking the channels the capsules block, once the
-- bot has its capsules. A few bots a second, so a crowd at the start of a raid is not one hitch.
local function fixMeshes(bot)
    local comps = bot:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    local n = 0
    for i = 1, #comps do
        local c = comps[i]:get()
        if valid(c) then
            local ok, class = pcall(function() return c:GetClass():GetFName():ToString() end)
            if ok and (class == "SkeletalMeshComponent" or class == "StaticMeshComponent") then
                n = n + 1
                for _, ch in ipairs(CAPSULE_CHANNELS) do pcall(function() c:SetCollisionResponseToChannel(ch, 0) end) end
            end
        end
    end
    return n
end

local nextMeshes = 0
local function meshes(now, bots)
    nextMeshes = now + 1
    local capClass = StaticFindObject("/Script/RaidGame.RaidHitCapsuleComponent")
    if not valid(capClass) then return end
    local left = 3
    for _, e in ipairs(bots) do
        if left == 0 then return end
        local bot = e.bot
        if not e.meshFixed and valid(bot) then
            left = left - 1
            local ok, have = pcall(function() return bot:K2_GetComponentsByClass(capClass) end)
            if ok and have and #have > 0 then
                e.meshFixed = true
                local okF, n = pcall(fixMeshes, bot)
                if okF and not B.meshLogged then
                    B.meshLogged = true
                    X.log(("bot damage: %d meshes on %s now let player shots through to the hit zones"):format(n, bot:GetFName():ToString()))
                end
            else
                e.meshTries = (e.meshTries or 0) + 1 -- (a bot that never gets capsules is given up on)
                if e.meshTries >= 5 then e.meshFixed = true end
            end
        end
    end
end

local last = {} -- the gun and its clip as of the last frame, and when the clip last dropped

-- Every frame, from the director's tick, with the player's controller.
function B.frame(pc)
    local bots = X.bots()
    if not bots then return end
    local now = os.clock()
    local pawn = valid(pc) and pc.Pawn
    local gun, clip
    if valid(pawn) then
        local g = pawn.CurrentWeapon
        if valid(g) then gun, clip = g:GetClass():GetFName():ToString(), g.CurrentAmmoInClip end
    end
    if #pushQ > 0 then pushStep(now) end
    if clip and last.clip and gun == last.gun and clip < last.clip then
        last.shotAt = now
        if gun:find("^Shotgun_") then
            local ok, err = pcall(pellets, pc, pawn, gun, math.min(last.clip - clip, 2), bots)
            if not ok then warn("pellets", "the shotgun pellets failed: " .. tostring(err)) end
        end
    end
    last.gun, last.clip = gun, clip
    local shot = gun and last.shotAt and now - last.shotAt < REFUND_WINDOW
    for _, e in ipairs(bots) do
        local bot = e.bot
        if valid(bot) then
            local h = bot.Health
            if shot and type(h) == "number" and e.dmgH and h < e.dmgH - 0.001 then
                local ok, back = pcall(refund, e, e.dmgH - h, gun)
                if ok and back > 0 then h = h + back end
            end
            e.dmgH = h
        end
    end
    if now >= nextMeshes then meshes(now, bots) end
end

-- ctx: log(text), valid(object), bots() -> the raid's bot entries (each with .bot), or nil outside a raid.
function B.init(ctx) X = ctx end

return B
