-- The blowtorch opens a locked door's locks offline: the Spaceport vault's three metal pieces (top, middle, bottom), and the one
-- door bolt of the merchant ship and colony doors (Door_BlowTorchReq01).
-- Decompiled 2026-11-18 (tools/offline-audit/kdis.py): the torch's Blueprint (Base_BlowTorch_C) only plays the flame, light and
-- sound. Its damage is native (RaidWeapon_Tool), and the door (Door_BlowTorch_C, a RaidLockedDoor) has no damage code of its own:
-- three RaidLockVolumeComponent boxes (RaidLockVolume_Top / _Middle / _Bottom, Health 300) and one event,
-- LockDamaged(LockName, HealthPercent), that the native weapon code is meant to call. Offline that never happens: firing the torch
-- at a lock changed nothing, and the vault door stayed shut with "F requires blowtorch".
-- While the torch fires (its BurstCounter is above 0), every STEP seconds this finds the lock nearest your aim line, on each door
-- near you, and burns it: its volume loses health (DPS a second of 300), and the door is told with its own LockDamaged event, so the
-- glow, the falling latch (the door's own 10 s wait, then the animation) and the vault door opening are the game's. When all three of
-- a door's locks are down it also sets bIsUnlocked, which "F requires blowtorch" checks. Soldiers already take the torch's own damage.
-- Which locks a door has: every RaidLockVolumeComponent is named RaidLockVolume_<Part> and carries its own UniquePartName, the
-- name the door's LockDamaged switches on. Door_BlowTorch (Spaceport vault) has Top/Middle/Bottom (TopLock, MiddleLock, BottomLock,
-- Health 300 each); Door_BlowTorchReq01 (the two bolted doors on the merchant ship, the one inside the colony cruiser's vault) has
-- one, RaidLockVolume_DoorBolt (UniquePartName DoorBolt, Health 500). Found by reading the cooked Blueprints (2026-11-23).
-- Barrels and gas cans are left alone: their Blueprint only takes damage from a flamethrower or a fire grenade area (or an event the
-- game's bullet hits call), and it is not known that the real torch sets them off.
-- Ship repairs (#70, 2026-11-20): the same native torch code is meant to mend your ship, and offline it doesn't either (8 s of real
-- torch on a broken life-support pipe: nothing). A ship shot to 0 hull has its life-support pipe broken (the interior's
-- RaidUseableFrigatePartComponent "...LifeSupport...": Health 1 -> 0, LifeSupportDestroyed on hull and interior): that is a
-- disabled ship. So while the torch fires at a part of your own ship (the pipe, the helm gun, the engine's repair area), within
-- RANGE and REPAIR_REACH of your aim: a broken part comes back first (PART_SECONDS to full; the pipe then clears
-- LifeSupportDestroyed and tells the interior with its own OnLifeSupportDestroyed(JustFixed = true)), then the hull rises
-- HULL_PER_SECOND to the interior's Curr Max Health, each step told through ShipHullHealthChangeEvent(old, new), the event the
-- hull's OnRep would send.
local P = {}
local X -- log, valid
local raid -- the per-raid table (setRaid); the torch's state lives in raid.torch, so a new world starts clean

local RANGE = 300 -- cm: how far in front of you a lock can be burned
local REACH = 30 -- cm: how far your aim line may pass from a lock's middle (the three locks are about 60 cm apart, in a column)
-- Damage a second to a lock. Fuel (#374): the torch spends about 17 charge a second of firing (2026-11-20, a repair from 0
-- ran a 250-charge torch dry at 361 hull, 25 hull a second: 250 / 14.4 s = 17.3 a second; and at the old 50 DPS players
-- measured "over 100 a bolt", 6 s x 17.3 = 104). The live game cost about 90 for a whole vault, so three locks should
-- take about 90 / 17.3 = 5.2 s: 1.73 s a lock, 300 / 1.73 = 173. At 175: 1.71 s a lock, 5.1 s and about 89 charge a vault.
local DPS = 175 -- (#444 proposed 100, the vanilla rate; 175 is #374's fuel-based figure, and #444's burst fix now delivers it)
local STEP = 0.1 -- seconds between burns
local GRACE = 0.2 -- seconds the torch counts as firing after BurstCounter was last seen above 0 (it fires in bursts about 0.16 s apart, so a 0.1 s look often lands between two)
local FIND_EVERY = 10 -- seconds between looks for the doors' lock volumes while firing (a FindAllOf walks every object)
local NEAR = 1500 -- cm: lock volumes farther than this from you are not looked at
-- Part names by the volume's name suffix, for when UniquePartName can't be read (the volume's own property is preferred).
local LOCKS = { Top = "TopLock", Middle = "MiddleLock", Bottom = "BottomLock", DoorBolt = "DoorBolt" }
local REPAIR_REACH = 80 -- cm: a ship part is bigger than a lock
local PART_SECONDS = 4 -- seconds of torch to mend a broken part
local HULL_PER_SECOND = 25 -- hull points a second once the parts are whole (575 for a starter frigate: about 23 s from 0)

-- Tool charge (#438): the blowtorch and the fire extinguisher last TOOL_CHARGE times as long offline (a PvE ask: the
-- live game's tool modifiers are missing here, and a vault or a ship fire shouldn't take a whole torch). Each tick, what
-- the tool spent since the last one is partly put back, the way Bottomless mags (debuggive.lua) puts back a shot: on the
-- gun's own SIGIS item's StackAmount (what the player's charge really is) and on CurrentAmmoInClip, which follows it.
-- Fractions carry over, so the rate is exact. Untested in game for the extinguisher (its class name is a guess: anything
-- with "Extinguish" in it).
local TOOL_CHARGE = 3
local TOOLS = { "BlowTorch", "Extinguish" }

function P.init(ctx) X = ctx end
function P.setRaid(r) raid = r end

local function nameOf(o)
    local n = "?"
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

-- The name the door's LockDamaged expects for this lock volume: its own UniquePartName ("TopLock", "DoorBolt"), else by suffix.
local function partName(c, suffix)
    local ok, n = pcall(function() return c.UniquePartName:ToString() end)
    if ok and type(n) == "string" and n ~= "" and n ~= "None" then return n end
    return LOCKS[suffix]
end

-- Every lock volume in the level that belongs to a door: { c = volume, door = owner, name = "TopLock", key = address }.
-- All of them: burn() keeps only those within NEAR. It used to stop at 24 in FindAllOf's order, which on a map with
-- more than 8 lock doors could leave out the door in front of you (#374).
local function findVolumes(s, now)
    if s.vols and now < s.findAt then return end
    s.findAt = now + FIND_EVERY
    s.vols = {}
    for _, c in ipairs(FindAllOf("RaidLockVolumeComponent") or {}) do
        if X.valid(c) then
            local n = nameOf(c)
            local which = n:match("RaidLockVolume_(%a+)")
            local door = c:GetOwner()
            if X.valid(door) then
                -- a lock box not named Top/Middle/Bottom (a storage crate door was reported not to burn, #374; its names are
                -- not known) is still burned: its door gets LockDamaged with the box's own name, and bIsUnlocked when done
                local name = which and partName(c, which) -- the door's own UniquePartName (DoorBolt...), #407
                if not name then
                    name = n
                    s.odd = s.odd or {}
                    if not s.odd[n] then s.odd[n] = true X.log(("blowtorch: lock box %s on %s (not Top/Middle/Bottom)"):format(n, nameOf(door))) end
                end
                s.vols[#s.vols + 1] = { c = c, door = door, name = name, key = tostring(c:GetAddress()), doorKey = tostring(door:GetAddress()) }
            end
        end
    end
end

-- Locked doors for the minimap (#326): every RaidLockedDoor in the level (vault doors that take the torch, key card and hack
-- doors), still locked. One FindAllOf per DOORS_EVERY seconds (40-50 ms each on big maps), kept in raid.doors so a new world
-- starts clean; between looks each kept door is checked through valid() and dropped once bIsUnlocked (or bIsOpen) is set.
-- Returns { { at = copied vector, key = address }, ... }; positions are copies, the door itself never leaves this module.
local DOORS_EVERY = 30
local function flag(o, name)
    local v = false
    pcall(function() v = o[name] == true end)
    return v
end

function P.lockedDoors(now)
    if not raid then return {} end
    local d = raid.doors
    if not d or now >= d.findAt then
        d = { findAt = now + DOORS_EVERY, list = {} }
        raid.doors = d
        for _, door in ipairs(FindAllOf("RaidLockedDoor") or {}) do
            if X.valid(door) and not flag(door, "bIsUnlocked") then
                local ok, at = pcall(function() local l = door:K2_GetActorLocation() return { X = l.X, Y = l.Y, Z = l.Z } end)
                if ok and at then d.list[#d.list + 1] = { door = door, at = at, key = tostring(door:GetAddress()) } end
            end
        end
    end
    local out, keep = {}, {}
    for _, e in ipairs(d.list) do
        if X.valid(e.door) and not flag(e.door, "bIsUnlocked") and not flag(e.door, "bIsOpen") then
            keep[#keep + 1] = e
            out[#out + 1] = { at = e.at, key = e.key }
        end
    end
    d.list = keep
    return out
end

-- Burns one lock by dmg; tells its door; when the door's last lock goes, unlocks it (a door with one lock: that lock).
local function burnLock(s, v, dmg)
    local left = s.hp[v.key]
    if not left then
        local h = v.c.Health
        left = type(h) == "number" and h > 0 and h or 300
        s.max[v.key] = left
    end
    if left <= 0 then return end
    left = math.max(0, left - dmg)
    s.hp[v.key] = left
    v.c.Health = left
    -- the door's own event: the percent is 0 to 1 (the door stored 0.9667 for 290 of 300 in the 2026-11-18 test)
    pcall(function() v.door:LockDamaged(FName(v.name), left / s.max[v.key]) end)
    if left > 0 then return end
    for _, o in ipairs(s.vols) do
        if o.doorKey == v.doorKey and (s.hp[o.key] or 1) > 0 then return end
    end
    pcall(function() v.door.bIsUnlocked = true end)
    -- A bolted door (Door_BlowTorchReq01) shows its broken pieces from its own OnUnlocked event, which the game runs from the
    -- unlock's replication (never offline). The vault door has no such pieces and is left as it was verified.
    pcall(function()
        if v.door.SM_DoorBroken01 ~= nil and v.door.SM_DoorBroken01:IsValid() then v.door:OnUnlocked() end
    end)
    X.log(("blowtorch: every lock of %s is burned through, door unlocked"):format(nameOf(v.door)))
end

local function burn(s, now, dt, pc, pawn)
    findVolumes(s, now)
    local cam = pc.PlayerCameraManager
    local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local dx, dy, dz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
    local here = pawn:K2_GetActorLocation()
    local best = {} -- per door: the lock whose middle is nearest your aim line
    for _, v in ipairs(s.vols) do
        if X.valid(v.c) and X.valid(v.door) and (s.hp[v.key] or 1) > 0 then
            local c = v.c:K2_GetComponentLocation()
            if math.abs(c.X - here.X) < NEAR and math.abs(c.Y - here.Y) < NEAR then
                local rx, ry, rz = c.X - loc.X, c.Y - loc.Y, c.Z - loc.Z
                local t = math.max(0, math.min(RANGE, rx * dx + ry * dy + rz * dz))
                local ex, ey, ez = rx - dx * t, ry - dy * t, rz - dz * t
                local miss = math.sqrt(ex * ex + ey * ey + ez * ez)
                local b = best[v.doorKey]
                if miss <= REACH and (not b or miss < b.miss) then best[v.doorKey] = { v = v, miss = miss } end
            end
        end
    end
    for _, b in pairs(best) do burnLock(s, b.v, DPS * dt) end
end

-- Your ship's interior: the hull you fly (rivals.lua's playerShip: your own, or one you took), else the raid's home.
local function myInside()
    local ok, ship = pcall(function() return require("rivals").playerShip() end)
    local inside = ok and ship and X.valid(ship) and ship.MyShipInside
    if inside and X.valid(inside) then return inside, ship end
    inside = raid.home
    if inside and X.valid(inside) then
        local hull = inside.SpaceshipToPairTo
        return inside, hull and X.valid(hull) and hull or nil
    end
end

-- The parts of an interior the torch mends: { c = component, full = health when whole, life = the life-support pipe }.
-- The engine's repair area has no health of its own: torching it only raises the hull.
local function repairParts(inside)
    local out = {}
    pcall(function()
        local comps = inside:K2_GetComponentsByClass(X.lib("/Script/RaidGame.RaidUseableFrigatePartComponent"))
        for i = 1, #comps do
            local c = comps[i]:get()
            if X.valid(c) then
                local max = c.MaxHealth
                out[#out + 1] = { c = c, full = (type(max) == "number" and max > 0) and max or 1,
                    life = nameOf(c):find("LifeSupport", 1, true) ~= nil }
            end
        end
        local all = inside:K2_GetComponentsByClass(X.lib("/Script/Engine.SceneComponent"))
        for i = 1, #all do
            local c = all[i]:get()
            if X.valid(c) and nameOf(c) == "ShipEngineRepairInteractArea" then out[#out + 1] = { c = c, area = true } end
        end
    end)
    return out
end

local function mend(s, part, inside, ship, dt)
    if not part.area then
        local h = part.c.Health
        if type(h) == "number" and h < part.full then
            local now = math.min(part.full, h + part.full * dt / PART_SECONDS)
            part.c.Health = now
            pcall(function() part.c:Onrep_HealthChange() end)
            if now >= part.full and part.life then
                pcall(function() inside.LifeSupportDestroyed = false end)
                if ship then pcall(function() ship.bLifeSupportDestroyed = false end) end
                pcall(function() inside:OnLifeSupportDestroyed(true) end)
                X.log("blowtorch: your ship's life support is mended")
            end
            return
        end
    end
    if not ship then return end
    -- full is the larger of the interior's figure and the hull's own: a taken Heavy borrows a Capital interior, whose
    -- Curr Max Health need not match, and the hull's smoke and fire (rivals.lua hullDamageFx) count against the hull's
    local max = inside["Curr Max Health"]
    local ok, hullMax = pcall(function() return require("rivals").playerShipMaxHull() end)
    if ok and type(hullMax) == "number" and (type(max) ~= "number" or hullMax > max) then max = hullMax end
    local old = ship.MainHullHealth
    if type(max) ~= "number" or type(old) ~= "number" or old >= max then return end
    local new = math.min(max, old + HULL_PER_SECOND * dt)
    ship.MainHullHealth = new
    pcall(function() inside:ShipHullHealthChangeEvent(old, new) end)
    if new >= max then X.log("blowtorch: your ship's hull is back to full") end
    if old <= 0 and new > 0 then X.log("blowtorch: your ship's hull is patched, it can fly again") end
end

local function repair(s, now, pc, dt)
    local inside, ship = myInside()
    if not inside then return end
    local key = tostring(inside:GetAddress())
    if s.partsOf ~= key then s.parts, s.partsOf = repairParts(inside), key end
    local cam = pc.PlayerCameraManager
    local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local dx, dy, dz = math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)
    local best, bestMiss
    for _, part in ipairs(s.parts) do
        if X.valid(part.c) then
            local c = part.c:K2_GetComponentLocation()
            local rx, ry, rz = c.X - loc.X, c.Y - loc.Y, c.Z - loc.Z
            local t = math.max(0, math.min(RANGE, rx * dx + ry * dy + rz * dz))
            local ex, ey, ez = rx - dx * t, ry - dy * t, rz - dz * t
            local miss = math.sqrt(ex * ex + ey * ey + ez * ez)
            if miss <= REPAIR_REACH and (not bestMiss or miss < bestMiss) then best, bestMiss = part, miss end
        end
    end
    if best then mend(s, best, inside, ship, dt) end
end

-- From the director's frame, with the player controller. Cheap while the torch is not in your hands.
local function isTool(gun)
    local n = gun:GetClass():GetFName():ToString()
    for _, t in ipairs(TOOLS) do if n:find(t, 1, true) then return t end end
end

local function toolItem(gun)
    local guid = gun.UUIDSIGIS:ToString()
    for _, it in ipairs(FindAllOf("SIGISInventoryItem") or {}) do
        if X.valid(it) and it.UniqueItemGUID:ToString() == guid then return it end
    end
end

-- Puts back (1 - 1/TOOL_CHARGE) of what the tool in your hands spent since the last call.
local function stretch(s, gun)
    local addr = gun:GetAddress()
    local t = s.tool
    if not t or t.addr ~= addr then
        t = { addr = addr, item = toolItem(gun), carry = 0 }
        s.tool = t
    end
    local keep = 1 - 1 / TOOL_CHARGE
    local item = t.item
    local stack = X.valid(item) and item.StackAmount or nil
    if type(stack) == "number" and type(t.stack) == "number" and stack < t.stack then
        t.carry = t.carry + (t.stack - stack) * keep
        local back = math.floor(t.carry)
        t.carry = t.carry - back
        stack = stack + back
        item.StackAmount = stack
    end
    local clip = gun.CurrentAmmoInClip
    if type(clip) == "number" and type(stack) == "number" and clip ~= stack then
        gun.CurrentAmmoInClip = stack
        clip = stack
    end
    t.stack = stack
end

function P.frame(pc)
    if not raid then return end
    local now = os.clock()
    local s = raid.torch
    if not s then
        s = { nextAt = 0, lastBurn = now, hp = {}, max = {}, findAt = 0 }
        raid.torch = s
    end
    if now < s.nextAt then return end
    s.nextAt = now + STEP
    local pawn = pc.Pawn
    if not X.valid(pawn) then return end
    local gun = pawn.CurrentWeapon
    local tool = X.valid(gun) and isTool(gun)
    if tool then pcall(stretch, s, gun) end
    if tool ~= "BlowTorch" then
        s.lastBurn = now
        return
    end
    local firing = gun.BurstCounter
    if type(firing) == "number" and firing > 0 then s.fireAt = now end
    -- The torch fires in bursts with gaps between them, so BurstCounter is 0 on some looks even while the trigger is held.
    -- It counts as firing for GRACE seconds after the last burst seen, and the time between looks is credited in full,
    -- but never past that window (a tap does not burn on after you let go).
    if not s.fireAt or now - s.fireAt > GRACE then
        s.lastBurn = now
        return
    end
    local upto = math.min(now, s.fireAt + GRACE)
    local dt = math.max(0, math.min(upto - s.lastBurn, 0.25))
    s.lastBurn = upto
    burn(s, now, dt, pc, pawn)
    pcall(repair, s, now, pc, dt)
end

return P
