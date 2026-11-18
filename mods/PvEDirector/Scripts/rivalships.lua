-- Rivals, part: the rivals' ships: station berths, docking routes, spawning, flying, turrets and leaving.
-- Moved verbatim from rivals.lua (issue #149, sections: Berths, Docking route, Ships); rivals.lua requires it and keeps the
-- public side. Its helpers and constants (and earlier modules' functions) come through require("rivalshared");
-- main's context (X) and the per-raid state (S) arrive through M.bind whenever rivals.lua changes them.
local H = require("rivalshared")
local M = {}
local X, S
function M.bind(x, s) X, S = x, s end
local CFG, Nav, Out, R, crewLabel, dist, gauss = H.CFG, H.Nav, H.Out, H.R, H.crewLabel, H.dist, H.gauss
local helper, inBox, lib, loadClass, pick, valid = H.helper, H.inBox, H.lib, H.loadClass, H.pick, H.valid
local weighted = H.weighted
-- Berths ---------------------------------------------------------------------------------------------------------
-- Where a docked ship sits. Station nodes say where a docking ship goes (ReturnAreaEntranceMoveToLocation, the
-- transform the docking ability flies your ship to: nose-in, deeper in the dock than the volume's middle). Nodes
-- that return nothing (Merchant, Fortress) dock in a bay: the volume itself, along its long axis, nose toward the
-- node's middle. Pitch/roll of the returned transform belong to a marker mesh and are ignored.
local function quatYaw(q)
    return math.deg(math.atan(2 * (q.W * q.Z + q.X * q.Y), 1 - 2 * (q.Y * q.Y + q.Z * q.Z)))
end

-- A dock volume's middle can lie in the hull (the Capital Ship's is 1.3 m off its side, by a rocket turret: a docked
-- frigate sat half inside it). Moved sideways, out of the station, till a ship-sized sphere fits; the height is kept.
-- Only for nodes with no berth transform: the game's own berths (Rebel Base, Spaceport) hold your ship in docking
-- clamps that any sphere overlaps on purpose. Run at the survey, before any rival ship is out: the sweep's ignore list
-- doesn't get through from Lua, only its world context (your ship, as `ctx`) is left out.
local CLEAR_COLOR = { R = 0, G = 0, B = 0, A = 0 }
local function clearOfHull(ctx, owner, at, yaw)
    local sys = lib("/Script/Engine.Default__KismetSystemLibrary")
    local moved, px, py, lane = 0, nil, nil, false
    while moved < CFG.BERTH_CLEAR_MAX do
        local h = {}
        local ok, r = pcall(function()
            return Out.call(sys, "SphereTraceSingle", ctx, at, { X = at.X, Y = at.Y, Z = at.Z + 1 }, CFG.BERTH_CLEAR, 0, false,
                {}, 0, h, true, CLEAR_COLOR, CLEAR_COLOR, 0)
        end)
        if not (ok and r and h.Normal) then break end
        local a = h.Actor and h.Actor:Get()
        -- the hull, its turrets, a rock; not a ship (an AI frigate passing by)
        if not (a and a:IsValid()) or a:GetClass():GetFName():ToString():find("^Ship_") then break end
        local nx, ny = h.Normal.X, h.Normal.Y
        local n = math.sqrt(nx * nx + ny * ny)
        if not lane and n < 0.3 then break end -- a floor or a roof
        nx, ny = nx / math.max(n, 1e-6), ny / math.max(n, 1e-6)
        -- pushed back the way it came (wedged between the hull and a turret): straight out along the lane instead
        if not lane and px and nx * px + ny * py < 0 then lane = true end
        if lane then nx, ny = -math.cos(math.rad(yaw)), -math.sin(math.rad(yaw)) end
        px, py = nx, ny
        local step = math.max(50, math.min(250, (h.PenetrationDepth or 200) + 50))
        at = { X = at.X + nx * step, Y = at.Y + ny * step, Z = at.Z }
        moved = moved + step
    end
    if moved > 0 then
        X.log(("[rivals]   berth at %s moved %.0f out of its hull"):format(owner:GetFName():ToString(), moved))
    end
    return at
end

local function stationBerth(comp, shipActor)
    local owner = comp:GetOwner()
    local loc = comp:K2_GetComponentLocation()
    local b = {}
    pcall(function()
        local t, cam, boom = {}, {}, {}
        owner:ReturnAreaEntranceMoveToLocation(shipActor, comp, t, cam, boom)
        local p = t.Translation
        if p and (p.X ~= 0 or p.Y ~= 0) then
            b.at, b.yaw = { X = p.X, Y = p.Y, Z = p.Z }, quatYaw(t.Rotation)
        end
    end)
    if not b.at then
        local e, r, o = comp:GetScaledBoxExtent(), comp:K2_GetComponentRotation(), owner:K2_GetActorLocation()
        local yaw = r.Yaw + (e.Y > e.X and 90 or 0)
        if (o.X - loc.X) * math.cos(math.rad(yaw)) + (o.Y - loc.Y) * math.sin(math.rad(yaw)) < 0 then yaw = yaw + 180 end
        b.at, b.yaw = clearOfHull(shipActor, owner, { X = loc.X, Y = loc.Y, Z = loc.Z }, yaw), yaw
    end
    -- The node's bounds (with the berth): docking ships stay outside them till they're on the approach lane.
    local o, x = {}, {}
    Out.call(owner, "GetActorBounds", false, o, x, false)
    local lo = { X = math.min(o.X - x.X, b.at.X), Y = math.min(o.Y - x.Y, b.at.Y), Z = math.min(o.Z - x.Z, b.at.Z) }
    local hi = { X = math.max(o.X + x.X, b.at.X), Y = math.max(o.Y + x.Y, b.at.Y), Z = math.max(o.Z + x.Z, b.at.Z) }
    b.hull = { c = { X = (lo.X + hi.X) / 2, Y = (lo.Y + hi.Y) / 2, Z = (lo.Z + hi.Z) / 2 },
        e = { X = (hi.X - lo.X) / 2, Y = (hi.Y - lo.Y) / 2, Z = (hi.Z - lo.Z) / 2 } }
    local rad = math.rad(b.yaw)
    b.approach = { X = b.at.X - math.cos(rad) * CFG.BERTH_APPROACH, Y = b.at.Y - math.sin(rad) * CFG.BERTH_APPROACH,
        Z = b.at.Z }
    return b
end

-- Berth pose now: at, yaw, approach. Berths at an AI frigate (b.side) follow the frigate as it flies.
local function berthPose(st, b)
    if not b.side then return b.at, b.yaw, b.approach end
    if not (st.frigate and valid(st.frigate)) then return nil end
    local f, yaw = st.frigate:K2_GetActorLocation(), st.frigate:K2_GetActorRotation().Yaw
    local rx, ry = math.cos(math.rad(yaw + 90)) * b.side, math.sin(math.rad(yaw + 90)) * b.side
    local at = { X = f.X + rx * CFG.ALONGSIDE, Y = f.Y + ry * CFG.ALONGSIDE, Z = f.Z }
    return at, yaw, { X = at.X + rx * CFG.BERTH_APPROACH, Y = at.Y + ry * CFG.BERTH_APPROACH, Z = at.Z }
end

-- Docking route --------------------------------------------------------------------------------------------------
-- A direct move knows nothing of the station: from its far side a ship flew into the hull and scraped along it to the
-- approach point. A docking ship stays outside the station's bounds (+ HULL_MARGIN) till it's on the berth's approach
-- lane, coming onto it at its entry (where the lane leaves the bounds), round the bounds' corners and edges if need be.
local function grow(box, m) return { c = box.c, e = { X = box.e.X + m, Y = box.e.Y + m, Z = box.e.Z + m } } end

-- Whether the segment a-b passes through an axis-aligned box (slab test).
local function crossesBox(a, b, box)
    local t0, t1 = 0, 1
    for _, k in ipairs({ "X", "Y", "Z" }) do
        local d, lo, hi = b[k] - a[k], box.c[k] - box.e[k], box.c[k] + box.e[k]
        if math.abs(d) < 1e-6 then
            if a[k] < lo or a[k] > hi then return false end
        else
            local u0, u1 = (lo - a[k]) / d, (hi - a[k]) / d
            if u0 > u1 then u0, u1 = u1, u0 end
            t0, t1 = math.max(t0, u0), math.min(t1, u1)
            if t0 > t1 then return false end
        end
    end
    return true
end

-- The station's bounds for this berth now (an AI frigate's move with it).
local function hullOf(st, b)
    if not b.side then return b.hull end
    if not (st.frigate and valid(st.frigate)) then return nil end
    local o, x = {}, {}
    Out.call(st.frigate, "GetActorBounds", true, o, x, false)
    return { c = { X = o.X, Y = o.Y, Z = o.Z }, e = { X = x.X, Y = x.Y, Z = x.Z } }
end

-- The lane out from a berth: its unit vector, and how far a point p is along it (t) and off its line (off).
local function laneOf(at, approach, p)
    local u = { X = approach.X - at.X, Y = approach.Y - at.Y, Z = approach.Z - at.Z }
    local n = math.max(1, math.sqrt(u.X * u.X + u.Y * u.Y + u.Z * u.Z))
    u = { X = u.X / n, Y = u.Y / n, Z = u.Z / n }
    local t = (p.X - at.X) * u.X + (p.Y - at.Y) * u.Y + (p.Z - at.Z) * u.Z
    return u, t, dist(p, { X = at.X + u.X * t, Y = at.Y + u.Y * t, Z = at.Z + u.Z * t })
end

-- Where a ship docking at berth b flies now: the approach point, the lane's entry, or a way round the station.
local function dockRoute(c, st, b, at, approach, here)
    local hull = hullOf(st, b)
    if not hull then return approach, 300 end
    local box, inner = grow(hull, CFG.HULL_MARGIN), grow(hull, CFG.HULL_MARGIN * 0.8)
    local u, t, off = laneOf(at, approach, here)
    -- the entry: out along the lane to where it first leaves the bounds
    local exitT = math.huge
    for _, k in ipairs({ "X", "Y", "Z" }) do
        if math.abs(u[k]) > 1e-6 then
            exitT = math.min(exitT, (box.c[k] + (u[k] > 0 and box.e[k] or -box.e[k]) - at[k]) / u[k])
        end
    end
    local out = math.max(CFG.BERTH_APPROACH, math.min(exitT + 500, 30000))
    local entry = { X = at.X + u.X * out, Y = at.Y + u.Y * out, Z = at.Z + u.Z * out }
    if t >= CFG.BERTH_APPROACH * 0.5 and t <= out + CFG.LANE_WIDTH and off < CFG.LANE_WIDTH then
        c.route = nil
        return approach, 300 -- on the lane: straight in
    end
    if not crossesBox(here, entry, inner) then
        c.route = nil
        return entry, 800
    end
    local r = c.route
    if r and r.berth == b and dist(here, r.at) > CFG.DOCK_ARRIVE and not crossesBox(here, r.at, inner) then
        return r.at, 800
    end
    local cands = {}
    if inBox(inner, here) then
        -- inside the bounds (under a hull, in a gap): straight out through the nearest face first
        local bd
        for _, k in ipairs({ "X", "Y", "Z" }) do
            for _, sgn in ipairs({ 1, -1 }) do
                local d = box.c[k] + sgn * box.e[k] - here[k]
                if not bd or math.abs(d) < bd then
                    bd = math.abs(d)
                    cands[1] = { X = here.X, Y = here.Y, Z = here.Z }
                    cands[1][k] = here[k] + d + sgn * 500
                end
            end
        end
    else
        -- the corners, edge middles and face middles of the bounds
        for _, i in ipairs({ -1, 0, 1 }) do
            for _, j in ipairs({ -1, 0, 1 }) do
                for _, k in ipairs({ -1, 0, 1 }) do
                    if i ~= 0 or j ~= 0 or k ~= 0 then
                        cands[#cands + 1] = { X = box.c.X + i * box.e.X, Y = box.c.Y + j * box.e.Y, Z = box.c.Z + k * box.e.Z }
                    end
                end
            end
        end
    end
    -- the shortest way on, a waypoint that can't see the entry counting double for the rest of the way
    local pickW, pickScore
    for _, w in ipairs(cands) do
        if #cands == 1 or not crossesBox(here, w, inner) then
            local score = dist(here, w) + dist(w, entry) * (crossesBox(w, entry, inner) and 2 or 1)
            if not pickScore or score < pickScore then pickW, pickScore = w, score end
        end
    end
    if not pickW then return entry, 800 end
    c.route = { at = pickW, berth = b }
    return pickW, 800
end

-- A berth is taken while its crew holds it (docking, docked, backing out) and their ship still exists.
local function berthFree(b)
    local h = b.taken
    return not h or (h.berth ~= b and h.undockBerth ~= b) or not (h.ship and valid(h.ship))
end

local function takeBerth(st, c)
    for _, b in ipairs(st.berths) do
        if berthFree(b) then b.taken, c.berth = c, b return b end
    end
end

-- Ships ----------------------------------------------------------------------------------------------------------
local function spawnShip(pc, c, at)
    local spots = {}
    for _, s in ipairs(S.shipSpawns) do
        if not S.playerShipLoc or dist(s, S.playerShipLoc) > 15000 then table.insert(spots, s) end
    end
    if #spots == 0 then spots = S.shipSpawns end
    if #spots == 0 and not at then return false end
    at = at or pick(spots)
    local design = c.baron and R.baron.design()
    if not design and c.hullRow then -- a raid condition's guaranteed hull (#78, rivalcrews.lua makeCrews)
        for _, d in ipairs(CFG.HULLS) do if d.row == c.hullRow then design = d end end
    end
    design = design or weighted(CFG.HULLS)
    local cls = loadClass("/Game/Blueprints/Ships/" .. design.pawn)
    local tree = lib(CFG.SHIP_TREE)
    if not (cls and valid(tree)) then return false end
    local off = { X = at.X + math.random(-1500, 1500), Y = at.Y + math.random(-1500, 1500), Z = at.Z }
    local ship = helper():SpawnAIFromClass(pc, cls, tree, off, { Pitch = 0, Yaw = math.random(0, 359), Roll = 0 },
        true, pc)
    if not valid(ship) then return false end
    c.ship, c.shipCtrl = ship, ship.Controller
    c.maxHull = ship.MainHullHealth
    c.design, c.turrets = design, {}
    -- the design's own hull: same skeleton as the base pawn's mesh
    local mpath = "/Game/Ships/" .. design.mesh
    if not mpath:find(".", 1, true) then mpath = mpath .. "." .. mpath:match("[^/]+$") end
    pcall(LoadAsset, mpath:match("^[^.]+"))
    local mesh = StaticFindObject(mpath)
    if valid(mesh) then pcall(function() ship.Mesh:SetSkeletalMesh(mesh, true) end) end
    -- turret slots: the design's types, now and then refitted with another
    c.turretPlan = {}
    local kinds = {}
    for k in pairs(CFG.TURRET_TYPES) do table.insert(kinds, k) end
    table.sort(kinds)
    for _, t in ipairs(design.turrets) do
        table.insert(c.turretPlan, not c.baron and math.random() < CFG.TURRET_SWAP and pick(kinds) or t)
    end
    c.turretKinds = { table.unpack(c.turretPlan) }
    -- The frigate's own behaviour tree picks the nearest ship it can see (usually yours) and steers at it, which made
    -- every crew swarm you. Rivals decide where to fly and whom to fight themselves.
    pcall(function() ship.Controller.BrainComponent:StopLogic("rivals") end)
    S.armPending = true
    return true
end

-- Ship guns: a bow gun is spawned for each ship that has none (two per second at most), also for your own ship, whose
-- bow gun is missing offline for the same reason. They used to be summoned by console command and then found with a
-- FindAllOf, ~45 ms each time: a hitch about every second while crews launched.
local function newGun(near)
    local cls = loadClass(CFG.GUN_PATH)
    if not cls then return nil end
    local g = near:GetWorld():SpawnActor(cls, near:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    return valid(g) and g or nil
end

local function equipGun(ship, g)
    g:SetOwner(ship)
    g.Instigator = ship
    g.MyPawn = ship
    pcall(function() g:OnRep_MyPawn() end)
    ship.Inventory[#ship.Inventory + 1] = g
    ship:ServerEquipWeapon(g)
end

-- Turret aim. A barrel follows its AnimBP's Yaw_Delayed / NewPitch (deg off the hull's nose), which the turret
-- actor's tick (its CameraRotation) works out every frame from whoever the game thinks aims it: on your hull that's
-- the pilot's view, so from the helm your mouse swung the turret your gunner was firing (TurretLocalRot moves
-- nothing). Turrets in AIMED have their actor tick off instead, and swingAimed writes both every frame: their gunners'
-- aim (wantYaw/wantPitch), swung at TURRET_SWING x the turret's own speed. fireTurrets shoots along that barrel.
-- This used to be a hook on every turret AnimBP's CameraRotation: it ran for all of them each frame, aimed or not
-- (~200 at a time late in a raid, wrecks included: 10k+ calls a second), and UE4SS makes garbage for every call:
-- ~18 MB a second, the collector 0.8 s per 10 s with 13 ms steps, a stutter that got worse the longer the raid ran
-- (profile.txt, 2026-11-15).
local AIMED = {} -- AnimBP address -> fireTurrets entry
function M.resetAimed() AIMED = {} end -- (each new raid starts with none)

local function swingStep(cur, want, speed, dt)
    local m = speed * CFG.TURRET_SWING * dt
    return cur + math.max(-m, math.min(m, want - cur))
end

-- Every frame, from R.frame: swing each aimed barrel toward its gunners' aim.
local function swingAimed(dt)
    if next(AIMED) == nil then return end
    local P = _G.PVE_PROF
    for addr, e in pairs(AIMED) do
        local a = e.anim
        if not (valid(e.actor) and valid(a)) then
            AIMED[addr] = nil
        else
            e.yaw = swingStep(e.yaw, e.wantYaw, e.yawSpeed, dt)
            e.pitch = swingStep(e.pitch, e.wantPitch, e.pitchSpeed, dt)
            a.Yaw_Delayed = e.yaw
            a.NewPitch = e.pitch
            if P then P.swing = (P.swing or 0) + 1 end
        end
    end
end

-- Puts a fireTurrets entry's barrel under its gunners (on) or gives it back to the game; it starts where it points now
-- and rests facing the nose until there's something to aim at.
local function aimTurret(e, on)
    local ok, ab = pcall(function() return e.actor.TurretBarrelMesh:GetAnimInstance() end)
    if not (ok and valid(ab)) then return end
    local addr = ab:GetAddress()
    if not on then
        AIMED[addr], e.aimed, e.anim = nil, nil, nil
        pcall(function() e.actor:SetActorTickEnabled(true) end)
        return
    end
    e.yaw, e.pitch = 0, 0
    pcall(function() e.yaw, e.pitch = ab.Yaw_Delayed, ab.NewPitch end)
    e.wantYaw, e.wantPitch = 0, 0
    e.yawSpeed, e.pitchSpeed = 20, 10
    pcall(function() e.yawSpeed, e.pitchSpeed = e.actor.TurretYawSpeed, e.actor.TurretPitchSpeed end)
    pcall(function() e.actor:SetActorTickEnabled(false) end)
    e.aimed, e.anim = true, ab
    AIMED[addr] = e
end

-- A wreck's turrets (its camera turrets too) stop ticking: nobody aims them again, and dozens of wrecks build up.
local function stillTurrets(c)
    for _, t in ipairs(c.turrets or {}) do
        if valid(t.actor) then
            aimTurret(t, false)
            pcall(function() t.actor:SetActorTickEnabled(false) end)
        end
    end
    if not valid(c.ship) then return end
    pcall(function()
        c.ship.SpawnedTurretArray:ForEach(function(_, e)
            local t = e:get()
            if valid(t) then t:SetActorTickEnabled(false) end
        end)
    end)
end

-- Turrets: the design's turret actors attached to the hull's Soc_Turret01/02, fired by fireTurrets (nobody mans them).
-- One ship is fitted per update (several spawns in one tick have crashed the game).
local function fitTurrets(c)
    c.turretPlan = c.turretPlan or {}
    -- the hull blueprint spawns its own default turret on Soc_Turret01 (camera turrets stay): replaced by the plan's
    local addr = c.ship:GetAddress()
    -- the hull's own list of what it spawned (a FindAllOf here cost ~45 ms per ship: a hitch while flying)
    local own = {}
    c.ship.SpawnedTurretArray:ForEach(function(_, e) own[#own + 1] = e:get() end)
    for _, t in ipairs(own) do
        if valid(t) and not t.bACameraTurret then
            local p = t:GetAttachParentActor()
            if valid(p) and p:GetAddress() == addr then R.destroy(t) end
        end
    end
    for slot, kind in ipairs(c.turretPlan) do
        local tt = CFG.TURRET_TYPES[kind]
        local path = "/Game/Blueprints/Ships_Extras/Turrets/" .. tt.cls
        local cls = loadClass(path)
        if cls then
            local t = c.ship:GetWorld():SpawnActor(cls, c.ship:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
            if valid(t) then
                t:K2_AttachToComponent(c.ship.Mesh, FName("Soc_Turret0" .. slot), 2, 2, 2, false)
                t:SetActorRelativeScale3D({ X = 1.25, Y = 1.25, Z = 1.25 })
                t.MyFrigateOwner = c.ship
                t:SetOwner(c.ship)
                local socks = {}
                t.FiringSockets:ForEach(function(_, e) socks[#socks + 1] = e:get():ToString() end)
                local e = { actor = t, kind = kind, socks = socks, si = 1, speed = tt.speed,
                    rate = t.FireRate, reload = t.ReloadTime, ammo = math.max(1, t.TotalAmmo), left = t.TotalAmmo,
                    range = tt.range, spread = tt.spread, next = 0 }
                table.insert(c.turrets, e)
                aimTurret(e, true)
            end
        end
    end
    c.turretPlan = nil
end

local function dropTurrets(c)
    for _, t in ipairs(c.turrets or {}) do
        if valid(t.actor) then
            aimTurret(t, false)
            pcall(function() t.actor:K2_DestroyActor() end)
        end
    end
    c.turrets = {}
end

-- A crew's gunners and their aim on the current target (c.aim): a new target starts them off by GUN_FIRST_MISS, with a
-- misjudged lead; each volley walks part of the error off (GUN_SETTLE), the target turning hard puts some back
-- (GUN_JINK), and a green gunner never quite holds still (GUN_WANDER). All of it shrinks with c.gunnery (0..1).
local function gunAim(c, tgt, tv)
    local skill = math.max(0, math.min(1, c.gunnery or 0.5))
    c.aim = c.aim or {}
    local a, addr = c.aim, tgt:GetAddress()
    local green = 1 - skill
    if a.tgt ~= addr then
        local miss = CFG.GUN_FIRST_MISS * (1 - 0.7 * skill)
        a.tgt, a.yaw, a.pitch = addr, gauss() * miss, gauss() * miss * 0.5
        a.lead = 1 + gauss() * CFG.GUN_LEAD_ERROR * green
    elseif a.vx then
        local s1, s2 = math.sqrt(a.vx * a.vx + a.vy * a.vy), math.sqrt(tv.X * tv.X + tv.Y * tv.Y)
        if s1 > 100 and s2 > 100 then
            local turn = math.deg(math.acos(math.max(-1, math.min(1, (a.vx * tv.X + a.vy * tv.Y) / (s1 * s2)))))
            local jink = turn / 10 * CFG.GUN_JINK * (1 - 0.5 * skill)
            a.yaw = a.yaw + (math.random() < 0.5 and -jink or jink) * math.random()
        end
    end
    a.vx, a.vy = tv.X, tv.Y
    a.spread = CFG.TURRET_SPREAD * (CFG.GUN_SPREAD_SKILL[1] + (CFG.GUN_SPREAD_SKILL[2] - CFG.GUN_SPREAD_SKILL[1]) * skill)
    return a, skill
end

-- After a volley: part of the error walked off, plus a green gunner's drift.
local function gunSettle(a, skill)
    local keep = 1 - CFG.GUN_SETTLE * (0.5 + 0.5 * skill)
    local wander = CFG.GUN_WANDER * (1 - skill)
    a.yaw = a.yaw * keep + gauss() * wander
    a.pitch = a.pitch * keep + gauss() * wander * 0.5
end

-- Swings each turret whose arc covers the target onto it (leading it by the shell's flight time, as well as the crew's
-- gunnery manages: gunAim) and fires the loaded ones whose barrel is there, along the barrel, through the turret's own
-- ServerFireProjectile: its shells, effects and damage. Called every frame while a crew engages.
-- For the status line: per turret-frame, why turrets held fire since the last report (range / arc / pitch / swing / reload).
local function turretWhy()
    local w = S.turretWhy
    S.turretWhy = nil
    if not w then return "" end
    local n, t = 0, {}
    for _, v in pairs(w) do n = n + v end
    for _, k in ipairs({ "range", "arc", "pitch", "swing", "reload" }) do
        if w[k] then t[#t + 1] = ("%s %d%%"):format(k, math.floor(w[k] * 100 / n + 0.5)) end
    end
    return " (held: " .. table.concat(t, ", ") .. ")"
end

local function fireTurrets(c, tgt, now)
    if not c.turrets or #c.turrets == 0 then c.held = nil return false end
    local sl, tl = c.ship:K2_GetActorLocation(), tgt:K2_GetActorLocation()
    local tv = tgt:GetVelocity()
    local r = c.ship:K2_GetActorRotation()
    local a, skill = gunAim(c, tgt, tv)
    local arc = c.arc or CFG.TURRET_ARC
    local fired, seen = false, {}
    for _, t in ipairs(c.turrets) do
        if valid(t.actor) and not t.aimed and now >= (t.aimTry or 0) then
            t.aimTry = now + 1 -- (a turret spawned this frame has no AnimBP yet)
            aimTurret(t, true)
        end
        local d = dist(sl, tl)
        local why = "range"
        if valid(t.actor) and d < math.max(t.range * (c.rangeScale or 1), c.reach or 0) then
            why = "arc"
            local tof = d / t.speed * a.lead
            local aim = { X = tl.X + tv.X * tof, Y = tl.Y + tv.Y * tof, Z = tl.Z + tv.Z * tof }
            local yaw = math.deg(math.atan(aim.Y - sl.Y, aim.X - sl.X))
            local rel = (yaw - r.Yaw + 180) % 360 - 180
            if math.abs(rel) <= arc then
                why = nil
                local sock = t.socks[t.si] or "Soc_Barrel01"
                local o = t.actor.TurretBarrelMesh:GetSocketLocation(FName(sock))
                local dx, dy, dz = aim.X - o.X, aim.Y - o.Y, aim.Z - o.Z
                -- the gunners' error, as yaw/pitch off the true lead (world deg), and that off the hull's nose
                local ay = math.deg(math.atan(dy, dx)) + a.yaw
                local ap = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))) + a.pitch
                local wy, wp = (ay - r.Yaw + 180) % 360 - 180, ap - r.Pitch
                t.wantYaw = math.max(-arc, math.min(arc, wy))
                t.wantPitch = math.max(CFG.TURRET_PITCH[1], math.min(CFG.TURRET_PITCH[2], wp))
                -- the barrel's own heading once it's ours and swinging (no AnimBP hook: straight along the aim)
                -- (the barrel is checked against where it can point: comparing it with an aim past its lift/dip limit
                -- used to hold every turret whose target was a little above or below)
                local past = math.abs(wp - t.wantPitch)
                local on = past <= (c.pitchSlack or CFG.TURRET_PITCH_SLACK)
                if not on then why = "pitch" end
                if on and t.aimed and t.swungAt and now - t.swungAt < 0.5 then
                    on = math.abs(t.yaw - t.wantYaw) <= CFG.TURRET_ON_AIM and math.abs(t.pitch - t.wantPitch) <= CFG.TURRET_ON_AIM
                    if not on then why = "swing" end
                    -- (your gunner, past the barrels' lift/dip: the shell keeps the true pitch, or it went off by up to
                    -- GUNNER_PITCH_SLACK deg)
                    ay = r.Yaw + t.yaw
                    if not (c.pitchSlack and past > 0) then ap = r.Pitch + t.pitch end
                end
                if on and now >= t.next then
                    -- then the gun's own spread
                    local sp = math.rad(t.spread * a.spread)
                    local ry, rp = math.rad(ay), math.rad(ap)
                    local dir = { X = math.cos(rp) * math.cos(ry) + (math.random() - 0.5) * sp,
                        Y = math.cos(rp) * math.sin(ry) + (math.random() - 0.5) * sp, Z = math.sin(rp) + (math.random() - 0.5) * sp }
                    local ok, err = pcall(function() t.actor:ServerFireProjectile(o, dir, t.si - 1) end)
                    if ok then S.turretShots = (S.turretShots or 0) + 1
                    elseif not S.turretErr then S.turretErr = true X.log("[rivals] turret fire failed: " .. tostring(err)) end
                    t.si = t.si % math.max(1, #t.socks) + 1
                    t.left = t.left - 1
                    if t.left <= 0 then t.left, t.next = t.ammo, now + t.reload else t.next = now + t.rate end
                    fired = true
                elseif on then why = "reload" end
            end
        end
        if why then S.turretWhy = S.turretWhy or {} S.turretWhy[why] = (S.turretWhy[why] or 0) + 1 end
        seen[why or "ok"] = true
    end
    -- c.held: "range", "arc" or "pitch" when no turret could bear on the target at all (your gunner says so, crew.lua)
    c.held = not (seen.ok or seen.reload or seen.swing) and (seen.range and "range" or seen.arc and "arc"
        or seen.pitch and "pitch") or nil
    if fired then gunSettle(a, skill) end
    return fired
end

local function armShips(pc, now)
    for _, c in ipairs(S.crews) do
        if c.turretPlan and c.ship and valid(c.ship) then
            local ok, err = xpcall(fitTurrets, function(e) return tostring(e) .. " | " .. debug.traceback() end, c)
            if not ok then c.turretPlan = nil X.log("[rivals] fitting turrets failed: " .. tostring(err)) end
            break
        end
    end
    if now < (S.nextArm or 0) then return end
    S.nextArm = now + 1
    local need = {}
    for _, c in ipairs(S.crews) do
        if c.ship and valid(c.ship) and not (c.gun and valid(c.gun)) then table.insert(need, c) end
    end
    local mine = valid(S.playerShip) and not valid(S.playerShip.CurrentWeapon)
    local fitting = false
    for _, c in ipairs(S.crews) do if c.turretPlan and c.ship then fitting = true end end
    if #need == 0 and not mine then S.armPending = fitting return end
    local spawned = 0
    if mine then
        local ok, err = pcall(function()
            local g = newGun(S.playerShip)
            if not g then error("no gun spawned") end
            equipGun(S.playerShip, g)
        end)
        spawned = spawned + 1
        X.log(ok and "[rivals] your ship's bow gun is fitted" or ("[rivals] arming your ship failed: " .. tostring(err)))
    end
    for _, c in ipairs(need) do
        if spawned >= CFG.GUNS_PER_STEP then break end
        spawned = spawned + 1
        local ok, err = pcall(function()
            local g = newGun(c.ship)
            if not g then error("no gun spawned") end
            equipGun(c.ship, g)
            c.gun = g
        end)
        if not ok then X.log("[rivals] arming failed: " .. tostring(err)) end
    end
    local short = 0
    for _, c in ipairs(need) do if not c.gun then short = short + 1 end end
    if mine and not valid(S.playerShip.CurrentWeapon) then short = short + 1 end
    for _, c in ipairs(S.crews) do if c.turretPlan and c.ship then short = short + 1 end end
    S.armPending = short > 0
end

-- References to actors the game may destroy (sunk ships) are dropped the moment they stop being valid, before the
-- garbage collector frees them.
local function shipOk(c)
    if c.ship and not valid(c.ship) then c.ship, c.shipCtrl = nil, nil dropTurrets(c) end
    if c.shipCtrl and not valid(c.shipCtrl) then c.shipCtrl = nil end
    return c.ship ~= nil and c.shipCtrl ~= nil and (c.ship.MainHullHealth or 0) > 0
end

-- What a ship's obstacle sweeps pass through: its own turrets and gun, and its target (attack runs pass close on
-- purpose: RUN_OFFSET keeps them off it) with the target's turrets.
local function navIgnore(c)
    local list = { c.ship }
    if valid(c.gun) then list[#list + 1] = c.gun end
    for _, t in ipairs(c.turrets or {}) do if valid(t.actor) then list[#list + 1] = t.actor end end
    local tgt = c.fireAt
    if valid(tgt) then
        list[#list + 1] = tgt
        pcall(function()
            tgt.SpawnedTurretArray:ForEach(function(_, e) local t = e:get() if valid(t) then list[#list + 1] = t end end)
        end)
        if valid(tgt.CurrentWeapon) then list[#list + 1] = tgt.CurrentWeapon end
    end
    return list
end

local function flyTo(c, at, accept)
    if c.glide then return end -- docking/undocking: R.frame moves the ship
    local ctrl = c.shipCtrl
    -- around anything in the way, and out again when stuck (shipnav.lua)
    local ok0, wp, acc, fresh = pcall(Nav.steer, c, c.ship, at, accept or 300, os.clock(), navIgnore(c), S.watchers)
    if ok0 then
        at, accept = wp, acc
    elseif not c.navErr then
        c.navErr = true
        X.log(("[rivals] %s steering failed: %s"):format(crewLabel(c), tostring(wp)))
    end
    -- The frigate's own AI keeps issuing patrol moves: re-issue ours whenever its destination isn't ours.
    local ok, dest = pcall(function() return ctrl:GetImmediateMoveDestination() end)
    local ours = ok and dest and dest.X and dist(dest, at) < 600
    if not fresh and c.flyTarget and dist(c.flyTarget, at) < 400 and ctrl:GetMoveStatus() == 3 and ours then return end
    c.flyTarget = at
    -- No navmesh in space: a direct move (no pathfinding), as the frigate AI flies.
    ctrl:MoveToLocation(at, accept or 300, false, false, false, true, nil, true)
end

local function setShipEnemy(c, target)
    -- The player hull designs fly under a plain AIController with no blackboard: only focus (aims the bow gun).
    local bb = c.shipCtrl.BlackboardComp
    if valid(target) then
        if valid(bb) then bb:SetValueAsObject(FName("Enemy"), target) end
        c.shipCtrl:K2_SetFocus(target)
    else
        if valid(bb) then bb:ClearValue(FName("Enemy")) end
        c.shipCtrl:K2_ClearFocus()
    end
end

-- How many crews a station holds before it counts as busy (its size), and how many it has: docked there or on the way.
-- Bodies awake around you: every live director bot that isn't parked (main.lua Aux.parked), your crew excepted.
function R.awakeCount()
    local n = 0
    for _, e in ipairs(X.raid().bots) do
        if not e.parked and not e.crewmate and valid(e.bot) and (e.bot.Health or 0) > 0 then n = n + 1 end
    end
    return n
end

local function insideCap(st) return math.max(CFG.INSIDE_MIN, math.floor((st.area or CFG.STATION_AREA_MID) / CFG.INSIDE_AREA_PER_CREW)) end
local function crewsInside(st)
    local n = 0
    for _, o in ipairs(S.crews) do
        if o.station == st and o.state == "docked" and o.bodies then
            for _, e in ipairs(o.bodies) do
                if valid(e.bot) and (e.bot.Health or 0) > 0 then n = n + 1 break end
            end
        end
    end
    return n
end
local function stationCapacity(st) return math.max(1, (st.area or CFG.STATION_AREA_MID) / CFG.STATION_AREA_PER_CREW) end
local function stationLoad(st, except)
    local n = 0
    for _, o in ipairs(S.crews) do
        if o ~= except and o.station == st and (o.state == "travel" or o.state == "docked" or o.state == "waiting") then
            n = n + 1
        end
    end
    return n
end

-- Somewhere new with a free berth if possible, picked by size: a big station draws more crews than a small one, and
-- each draws less the more crews it already has (so the small ones still see the odd crew, and the big ones fill
-- up first). An AI frigate that sank can't be reached any more.
local function chooseStation(c)
    local free, any = {}, {}
    for _, st in ipairs(S.stations) do
        if st.frigate ~= nil and not (st.frigate and valid(st.frigate)) then st.frigate = false end
        if st ~= c.lastStation and st.frigate ~= false then
            table.insert(any, st)
            for _, b in ipairs(st.berths) do if berthFree(b) then table.insert(free, st) break end end
        end
    end
    local options = #free > 0 and free or any
    if #options == 0 then return nil end
    local total, weights = 0, {}
    for i, st in ipairs(options) do
        local cap = stationCapacity(st)
        weights[i] = cap * CFG.STATION_CROWD ^ (stationLoad(st, c) / cap)
        total = total + weights[i]
    end
    local r = math.random() * total
    for i, st in ipairs(options) do
        r = r - weights[i]
        if r <= 0 then return st end
    end
    return options[#options]
end

-- Docking and undocking are a smooth glide between the approach point and the berth (R.frame), with the ship's
-- own movement stopped; docked ships are held in their berth.
local function startGlide(c, dir, beyond)
    local l, r = c.ship:K2_GetActorLocation(), c.ship:K2_GetActorRotation()
    c.ship.CharacterMovement:StopMovementImmediately()
    pcall(function() c.shipCtrl:StopMovement() c.shipCtrl:K2_ClearFocus() end)
    c.glide = { dir = dir, t0 = os.clock(), dur = beyond and CFG.DERELICT_GLIDE or dir == "in" and CFG.DOCK_GLIDE
            or CFG.UNDOCK_GLIDE, beyond = beyond,
        station = c.glide and c.glide.station or c.station, berth = c.berth or c.undockBerth,
        from = { X = l.X, Y = l.Y, Z = l.Z }, yaw = r.Yaw, pitch = r.Pitch, roll = r.Roll }
end

local function undock(c, beyond)
    if c.glide then c.berth = c.berth or c.glide.berth end
    c.undockBerth, c.berth, c.moored = c.berth, nil, nil
    if c.undockBerth and shipOk(c) then startGlide(c, "out", beyond) end
end

-- A docked crew wiped out (killed raiding the station, or by another crew in it) left their ship held in its berth for
-- the rest of the raid, shown again as a derelict and still holding the berth: nobody else could dock there (user
-- report 2026-11-15, the Rusty Mule at Spaceport). It drifts out, well past the approach lane, and waits there.
local function clearBerth(c)
    if c.moored or (c.glide and c.glide.dir == "in") then
        undock(c, CFG.DERELICT_CLEAR)
    else
        c.berth = nil -- only on its way in: the berth it had reserved is free again
    end
end

-- Docked ships are hidden (and don't collide): a ship held in its berth sat visibly wedged into the station's
-- airlock frame, and ships of crews that breached in (no free berth) idled in a clump beside a station that flies on,
-- like Colony Cruiser (2026-11-14). Shown again once they glide out, leave or you're aboard one. Their turrets too.
local function showShip(c, show)
    for _, a in ipairs({ c.ship }) do
        pcall(function() a:SetActorHiddenInGame(not show) a:SetActorEnableCollision(show) end)
    end
    for _, t in ipairs(c.turrets or {}) do
        if valid(t.actor) then pcall(function() t.actor:SetActorHiddenInGame(not show) end) end
    end
    c.hidden = not show
end

local function glideShips(now)
    for _, c in ipairs(S.crews) do
        if c.ship and valid(c.ship) then
            local hide = c.state == "docked" and not c.glide and S.aboard ~= c
            if hide ~= (c.hidden or false) then showShip(c, not hide) end
        end
        local g = c.glide
        if g and not (c.ship and valid(c.ship)) then
            c.glide, c.undockBerth = nil, nil
        elseif g then
            local at, yaw, approach = berthPose(g.station, g.berth)
            if not at then
                c.glide, c.undockBerth = nil, nil -- the AI frigate it was docked at is gone
            else
                local to = g.dir == "in" and at or approach
                if g.beyond then
                    local ox, oy, oz = approach.X - at.X, approach.Y - at.Y, approach.Z - at.Z
                    local on = math.max(1, math.sqrt(ox * ox + oy * oy + oz * oz))
                    to = { X = approach.X + ox / on * g.beyond, Y = approach.Y + oy / on * g.beyond,
                        Z = approach.Z + oz / on * g.beyond }
                end
                local t = math.min(1, (now - g.t0) / g.dur)
                local s = t * t * (3 - 2 * t)
                local dy = (yaw - g.yaw + 180) % 360 - 180
                local rot = { Pitch = g.pitch * (1 - s), Yaw = g.yaw + dy * s, Roll = g.roll * (1 - s) }
                Out.call(c.ship, "K2_SetActorLocationAndRotation", 
                    { X = g.from.X + (to.X - g.from.X) * s, Y = g.from.Y + (to.Y - g.from.Y) * s,
                        Z = g.from.Z + (to.Z - g.from.Z) * s }, rot, false, {}, true)
                if c.shipCtrl and valid(c.shipCtrl) then c.shipCtrl:SetControlRotation(rot) end
                if t >= 1 then
                    c.glide = nil
                    if g.dir == "in" then c.moored = g.station else c.undockBerth = nil end
                end
            end
        elseif c.moored and c.berth and c.ship and valid(c.ship) then
            -- Hold the berth (and keep up with an AI frigate that flies on). The ship's controller keeps turning it
            -- (it steers by control rotation), so hold that too.
            local at, yaw = berthPose(c.moored, c.berth)
            if at and (dist(c.ship:K2_GetActorLocation(), at) > 30
                    or math.abs((c.ship:K2_GetActorRotation().Yaw - yaw + 180) % 360 - 180) > 2) then
                local rot = { Pitch = 0, Yaw = yaw, Roll = 0 }
                Out.call(c.ship, "K2_SetActorLocationAndRotation", at, rot, false, {}, true)
                if c.shipCtrl and valid(c.shipCtrl) then c.shipCtrl:SetControlRotation(rot) end
            end
        end
    end
end

-- Where a leaving ship heads: a ship spawn point, but not the one your frigate sits at, and the one fewest other
-- leaving crews are heading for (nearest first). Leaving ships stalled 70-80 m off their exit, circling for minutes
-- (2026-11-15): a hull parked at the point (yours, or another leaver's) sat in shipnav's sweep, so every approach
-- turned into a detour away from it and back again.
-- (On R, not a local: the file sits at Lua's 200-local limit for its main chunk.)
function R.pickExit(c)
    local here = shipOk(c) and c.ship:K2_GetActorLocation() or nil
    local best, bn, bd
    for _, s in ipairs(S.shipSpawns) do
        if not S.playerShipLoc or dist(s, S.playerShipLoc) > 15000 or #S.shipSpawns == 1 then
            local n = 0
            for _, o in ipairs(S.crews) do
                if o ~= c and o.state == "leaving" and o.exitAt and dist(o.exitAt, s) < 1 then n = n + 1 end
            end
            local d = here and dist(here, s) or math.random()
            if not best or n < bn or (n == bn and d < bd) then best, bn, bd = s, n, d end
        end
    end
    return best or pick(S.shipSpawns)
end

local function startLeaving(c, why)
    c.state, c.station, c.target, c.fireAt = "leaving", nil, nil, nil
    c.exitAt = R.pickExit(c)
    c.exitBest, c.exitBestAt = nil, nil
    X.log(("[rivals] %s extracting (%s)"):format(crewLabel(c), why))
end


-- What rivals.lua and the later modules call
M.aimTurret, M.armShips, M.berthPose, M.chooseStation = aimTurret, armShips, berthPose, chooseStation
M.clearBerth, M.crewsInside, M.dockRoute, M.dropTurrets = clearBerth, crewsInside, dockRoute, dropTurrets
M.fireTurrets, M.flyTo, M.glideShips, M.insideCap = fireTurrets, flyTo, glideShips, insideCap
M.laneOf, M.setShipEnemy, M.shipOk, M.spawnShip = laneOf, setShipEnemy, shipOk, spawnShip
M.startGlide, M.startLeaving, M.stationBerth = startGlide, startLeaving, stationBerth
M.stillTurrets, M.swingAimed, M.takeBerth, M.turretWhy = stillTurrets, swingAimed, takeBerth, turretWhy
M.undock = undock

return M
