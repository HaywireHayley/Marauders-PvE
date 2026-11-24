-- Rivals, part: fights in space: breaching pods, ship-to-ship combat, and you boarding a rival's ship.
-- Moved verbatim from rivals.lua (issue #149, sections: Breaching pods, Ship combat, You boarding a rival's ship); rivals.lua requires it and keeps the
-- public side. Its helpers and constants (and earlier modules' functions) come through require("rivalshared");
-- main's context (X) and the per-raid state (S) arrive through M.bind whenever rivals.lua changes them.
local H = require("rivalshared")
local M = {}
local X, S
function M.bind(x, s) X, S = x, s end
local CFG, Out, R, bodiesAlive, breachSpots = H.CFG, H.Out, H.R, H.bodiesAlive, H.breachSpots
local chooseStation, crewAlive, crewLabel = H.chooseStation, H.crewAlive, H.crewLabel
local dematerialize, dist, dropTurrets, entryPoints = H.dematerialize, H.dist, H.dropTurrets, H.entryPoints
local fireTurrets, helper, inBox, insideAnchor = H.fireTurrets, H.helper, H.inBox, H.insideAnchor
local joined, lib, loadClass, materialize, pick = H.joined, H.lib, H.loadClass, H.materialize, H.pick
local projected, reachableNear, rnd, say = H.projected, H.reachableNear, H.rnd, H.say
local setShipEnemy, shipOk, valid = H.setShipEnemy, H.shipOk, H.valid
-- Breaching pods -------------------------------------------------------------------------------------------------
-- Live, a boarder launches from their frigate in a drop pod (Ship_DropPod_Pawn_C), flies it into your hull, and the
-- breach ability drives it in and moves them inside. That pod only works with a player controller: spawned for an AI
-- it crashes (a timer, delayforLocalSPawnAbility = 0.5 s after spawn, casts its controller to a player controller and
-- calls through the result unchecked; with no controller at all it skips). So each pod is spawned, has its AI
-- controller removed at once, and is flown here frame by frame; on contact it's gone at once, as if it slammed through
-- the hull, and you get the game's breach alarm (SpaceshipInside:StartBreachedEvent) and notice (ClientBeenBreached).
-- Rival ships get the same pods, without the alarm.
local function holdOff(shipLoc, target)
    local dx, dy = shipLoc.X - target.X, shipLoc.Y - target.Y
    local n = math.max(1, math.sqrt(dx * dx + dy * dy))
    return { X = target.X + dx / n * CFG.HOLD_OFF, Y = target.Y + dy / n * CFG.HOLD_OFF, Z = target.Z + 300 }
end

-- A hull's size: its colliding bounds' larger flat half-extent (the frigates' capsules are only 50-100 across; the
-- hulls run 500-1200), read once per ship. o = a crew, or nil for your ship.
local function boundsRadius(ship)
    local r = 900
    pcall(function()
        local o, e = {}, {}
        Out.call(ship, "GetActorBounds", true, o, e, false)
        if e.X and e.Y then r = math.max(400, math.min(2000, math.max(e.X, e.Y) * 0.85)) end
    end)
    return r
end
local function hullRadius(o)
    if not o then
        if not S.playerRadius and valid(S.playerShip) then S.playerRadius = boundsRadius(S.playerShip) end
        return S.playerRadius or 1200
    end
    if o.hullR and o.hullFor == o.ship then return o.hullR end
    if o.ship and valid(o.ship) then o.hullR, o.hullFor = boundsRadius(o.ship), o.ship return o.hullR end
    return 900
end

-- Every flying ship's place, read once per director update (separation checks all of them for every fighter).
local function shipsFlying(now)
    if S.posAt == now and S.pos then return S.pos end
    local list = {}
    for _, o in ipairs(S.crews) do
        if o.state ~= "docked" and o.state ~= "gone" and o.state ~= "waiting" and shipOk(o) then
            list[#list + 1] = { c = o, ship = o.ship, at = o.ship:K2_GetActorLocation(), r = hullRadius(o) }
        end
    end
    if valid(S.playerShip) then list[#list + 1] = { ship = S.playerShip, at = S.playerShip:K2_GetActorLocation(), r = hullRadius(nil) } end
    S.pos, S.posAt = list, now
    return list
end

-- About to fly into another ship (closest approach in the next SEP_LOOK seconds, at the two ships' velocities, closer
-- than SEP_CLEAR between the hulls): a point to break away to, held SEP_HOLD seconds. Away from it, and off to the side
-- of our own heading so the two don't back apart and close again.
local function separation(c, here, now)
    if c.sep and now < c.sep.untilT then return c.sep.at end
    c.sep = nil
    local v = c.ship:GetVelocity()
    local myR = hullRadius(c)
    local worst, wgap
    for _, p in ipairs(shipsFlying(now)) do
        if p.c ~= c and valid(p.ship) then
            local rx, ry, rz = here.X - p.at.X, here.Y - p.at.Y, here.Z - p.at.Z
            local d = math.sqrt(rx * rx + ry * ry + rz * rz)
            if d - myR - p.r < CFG.SEP_CLEAR + 6000 then
                local ov = p.ship:GetVelocity()
                local wx, wy, wz = v.X - ov.X, v.Y - ov.Y, v.Z - ov.Z
                local ww = wx * wx + wy * wy + wz * wz
                local t = ww > 1 and math.max(0, math.min(CFG.SEP_LOOK, -(rx * wx + ry * wy + rz * wz) / ww)) or 0
                local cx, cy, cz = rx + wx * t, ry + wy * t, rz + wz * t
                local gap = math.sqrt(cx * cx + cy * cy + cz * cz) - myR - p.r
                if gap < CFG.SEP_CLEAR and (not wgap or gap < wgap) then worst, wgap = { x = rx, y = ry, z = rz, d = d }, gap end
            end
        end
    end
    if not worst then return nil end
    local n = math.max(1, worst.d)
    local ax, ay, az = worst.x / n, worst.y / n, worst.z / n
    local sp = math.max(1, math.sqrt(v.X * v.X + v.Y * v.Y))
    local sx, sy = -v.Y / sp, v.X / sp
    if sx * ax + sy * ay < 0 then sx, sy = -sx, -sy end
    local dx, dy, dz = ax + sx * 0.8, ay + sy * 0.8, az + (az >= 0 and 0.5 or -0.5)
    local m = math.max(1e-3, math.sqrt(dx * dx + dy * dy + dz * dz))
    c.sep = { at = { X = here.X + dx / m * 4000, Y = here.Y + dy / m * 4000, Z = here.Z + dz / m * 4000 }, untilT = now + CFG.SEP_HOLD }
    c.man = { kind = "break", untilT = now + CFG.SEP_HOLD, at = c.sep.at, phase = "out" }
    S.seps = (S.seps or 0) + 1
    return c.sep.at
end

local function weighted(w)
    local total = 0
    for _, v in pairs(w) do total = total + v end
    local r = math.random() * total
    for k, v in pairs(w) do
        r = r - v
        if r <= 0 then return k end
    end
    return next(w)
end

-- The next manoeuvre against the target: after a pass, out the far side (or a break); hit hard, maybe break away;
-- otherwise by the crew's style. Tailing only on a target flying away from us.
local function nextManoeuvre(c, tl, bx, by, now, last, tgt)
    c.style = c.style or weighted({ jouster = 1, brawler = 1, sniper = 1 })
    if last == "pass" then return math.random() < 0.75 and "extend" or "break" end
    if c.hurtAt and now - c.hurtAt < 1.5 and last ~= "break" and math.random() < CFG.BREAK_WHEN_HIT then return "break" end
    local w = {}
    for k, v in pairs(CFG.STYLES[c.style] or CFG.STYLES.jouster) do w[k] = v end
    local away = false
    pcall(function()
        local f = tgt:GetActorForwardVector()
        away = f.X * bx + f.Y * by > 0.3
    end)
    if not away then w.tail = nil end
    if last == "circle" or last == "standoff" then w[last] = (w[last] or 0) * 0.3 end
    return weighted(w)
end

-- Where a ship in a fight flies now, and whether its nose is on the target (fireControl aims and fires the bow gun
-- for phase "in"). The pass works as the old attack run, but keeps its side offset all the way in (re-aiming at the
-- target each update used to drop it and fly straight at the hull) and swings out on the far side (it used to come
-- back through the target).
local function manoeuvre(c, here, tgt, tl, now)
    local dx, dy, dz = tl.X - here.X, tl.Y - here.Y, tl.Z - here.Z
    local d = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
    local h = math.max(1, math.sqrt(dx * dx + dy * dy))
    local bx, by = dx / h, dy / h -- bearing to the target, flat
    local px, py = -by, bx        -- and square to it
    local myR, tR = hullRadius(c), hullRadius(c.target and c.target.crew)
    local m = c.man
    local done = not m or now > m.untilT or (m.at and m.fixed and dist(here, m.at) < 1200)
    if m and m.kind == "pass" and not done then
        -- past the target (it's behind us) and clear: the pass is over
        local f = c.ship:GetActorForwardVector()
        if (f.X * dx + f.Y * dy + f.Z * dz) / d < -0.2 and d > myR + tR + 800 then done = true end
    end
    if done then
        local kind = nextManoeuvre(c, tl, bx, by, now, m and m.kind, tgt)
        m = { kind = kind, t0 = now, sgn = math.random() < 0.5 and -1 or 1 }
        if kind == "pass" then
            m.side = m.sgn * math.max(CFG.RUN_OFFSET, myR + tR + CFG.PASS_CLEAR)
            m.lift = (math.random() * 2 - 1) * CFG.PASS_LIFT
            m.untilT, m.phase = now + 20, "in"
        elseif kind == "extend" then
            -- on out the side we're on now, swinging off the line
            local a = math.atan(-by, -bx) + math.rad(math.random(-60, 60))
            local r = rnd(CFG.RUN_EXTEND)
            m.at = { X = tl.X + math.cos(a) * r, Y = tl.Y + math.sin(a) * r, Z = tl.Z + math.random(-1200, 1200) }
            m.fixed, m.untilT, m.phase = true, now + 15, "out"
        elseif kind == "break" then
            local r = rnd(CFG.BREAK_DIST)
            local ux, uy, uz = px * m.sgn - bx * 0.4, py * m.sgn - by * 0.4, (math.random() < 0.5 and -0.6 or 0.6)
            local n = math.sqrt(ux * ux + uy * uy + uz * uz)
            m.at = { X = here.X + ux / n * r, Y = here.Y + uy / n * r, Z = here.Z + uz / n * r }
            m.fixed, m.untilT, m.phase = true, now + rnd(CFG.BREAK_SECONDS), "out"
        elseif kind == "circle" then
            m.r = rnd(CFG.CIRCLE_R) + myR + tR
            m.z = math.random(-400, 400)
            m.untilT, m.phase = now + rnd(CFG.CIRCLE_SECONDS), "in"
        elseif kind == "standoff" then
            m.r = rnd(CFG.STANDOFF_R) + myR + tR
            m.z = math.random(-300, 300)
            m.dur = rnd(CFG.STANDOFF_SECONDS)
            m.untilT, m.phase = now + m.dur, "in"
        else -- tail
            m.untilT, m.phase = now + rnd(CFG.TAIL_SECONDS), "in"
        end
        c.man = m
    end
    local at, accept = m.at, 600
    if m.kind == "pass" then
        if not m.locked and d < CFG.RUN_OVERSHOOT * 1.2 + myR + tR then
            m.locked = { X = tl.X + bx * CFG.RUN_OVERSHOOT + px * m.side, Y = tl.Y + by * CFG.RUN_OVERSHOOT + py * m.side,
                Z = tl.Z + m.lift }
        end
        at = m.locked or { X = tl.X + bx * CFG.RUN_OVERSHOOT + px * m.side, Y = tl.Y + by * CFG.RUN_OVERSHOOT + py * m.side,
            Z = tl.Z + m.lift }
        if m.locked and dist(here, m.locked) < 1200 then m.untilT = now end
    elseif m.kind == "circle" then
        local a = math.atan(here.Y - tl.Y, here.X - tl.X) + m.sgn * math.rad(CFG.CIRCLE_LEAD)
        at, accept = { X = tl.X + math.cos(a) * m.r, Y = tl.Y + math.sin(a) * m.r, Z = tl.Z + m.z }, 300
    elseif m.kind == "standoff" then
        -- close to short range on our side of it, nose on, and hold there drifting slowly sideways
        local drift = m.sgn * CFG.STANDOFF_DRIFT * math.min(1, (now - m.t0) / m.dur)
        at, accept = { X = tl.X - bx * m.r + px * drift, Y = tl.Y - by * m.r + py * drift, Z = tl.Z + m.z }, 400
    elseif m.kind == "tail" then
        local f = { X = bx, Y = by, Z = 0 }
        pcall(function() f = tgt:GetActorForwardVector() end)
        local back = CFG.TAIL_BACK + myR + tR
        at, accept = { X = tl.X - f.X * back - f.Y * 700 * m.sgn, Y = tl.Y - f.Y * back + f.X * 700 * m.sgn,
            Z = tl.Z - f.Z * back + 300 }, 300
    end
    local sep = separation(c, here, now)
    if sep then at, accept, m = sep, 600, c.man end
    c.runPhase = m.phase
    return at, accept
end

local function launchPods(c, party, ship)
    local cls = loadClass(CFG.POD)
    if not (cls and shipOk(c)) then return end
    local from = c.ship:K2_GetActorLocation()
    local n = 0
    for _, m in ipairs(party.members) do
        if m.alive then
            local at = { X = from.X + math.random(-200, 200), Y = from.Y + math.random(-200, 200), Z = from.Z - 250 }
            local pod = helper():SpawnAIFromClass(S.pc, cls, lib(CFG.SHIP_TREE), at, { Pitch = 0, Yaw = 0, Roll = 0 },
                true, S.pc)
            if valid(pod) then
                -- In the same call, before its 0.5 s timer: no controller, or the game crashes.
                local ctrl = pod.Controller
                if valid(ctrl) then ctrl:UnPossess() R.destroy(ctrl) end
                pod:SetActorHiddenInGame(false)
                pod:SetActorEnableCollision(false)
                pcall(function() pod:SetBoostingVisuals(true) end)
                table.insert(S.pods, { pod = pod, crew = party, member = m, ship = ship, launchedAt = os.clock(),
                    wobble = math.random() * 6.28, along = rnd(CFG.POD_ALONG) })
                n = n + 1
            end
        end
    end
    if party.victim then
        X.log(("[rivals] %s launched %d pod(s) at the %s"):format(crewLabel(c), n, party.victim.shipName))
    else
        say(S.pc, ("The %s launched %d breaching pod%s at you!"):format(c.shipName, n, n == 1 and "" or "s"))
    end
end

local function podHit(p, ship)
    local pod = p.pod
    p.hitAt = os.clock()
    local at = pod:K2_GetActorLocation()
    R.destroy(pod)
    if p.crew.victim then
        X.log(("[rivals] %s's pod hit the %s"):format(p.member.name, p.crew.victim.shipName))
        return
    end
    if not S.alarmAt or p.hitAt - S.alarmAt > 10 then
        S.alarmAt = p.hitAt
        pcall(function() S.homeInside:StartBreachedEvent() end)
        pcall(function() S.pc:ClientBeenBreached() end)
    end
    local loc, f, r = ship:K2_GetActorLocation(), ship:GetActorForwardVector(), ship:GetActorRightVector()
    local dx, dy, dz = at.X - loc.X, at.Y - loc.Y, at.Z - loc.Z
    X.log(("[rivals] %s's pod hit your hull, %.0f ahead of its centre, %.0f to the side"):format(p.member.name,
        dx * f.X + dy * f.Y + dz * f.Z, dx * r.X + dy * r.Y + dz * r.Z))
end

-- Where a pod is heading: the point on the hull's side nearest a spot out abeam, on whichever side the pod came from.
-- Aiming at the point nearest the pod itself put pods launched from behind into the engines.
local function podAim(p, ship, here)
    local loc, f, r = ship:K2_GetActorLocation(), ship:GetActorForwardVector(), ship:GetActorRightVector()
    p.side = p.side or ((here.X - loc.X) * r.X + (here.Y - loc.Y) * r.Y + (here.Z - loc.Z) * r.Z < 0 and -1 or 1)
    local out = CFG.POD_SIDE * p.side
    local hit = {}
    ship.Mesh:GetClosestPointOnCollision({ X = loc.X + f.X * p.along + r.X * out, Y = loc.Y + f.Y * p.along + r.Y * out,
        Z = loc.Z + f.Z * p.along + r.Z * out }, hit, FName("None"))
    return hit.X and hit or loc
end

-- Every frame: fly pods in flight. A pod that hit stays listed, with no actor, until its rider has cut through.
local function flyPods(dt)
    local now = os.clock()
    for i = #S.pods, 1, -1 do
        local p = S.pods[i]
        local pod = p.pod
        local ship = p.ship
        if p.hitAt then
            if p.boarded or now - p.hitAt > CFG.POD_TIMEOUT then table.remove(S.pods, i) end
        elseif not valid(pod) then
            table.remove(S.pods, i)
        elseif not valid(ship) then
            R.destroy(pod)
            table.remove(S.pods, i)
        else
            local here = pod:K2_GetActorLocation()
            local hit = podAim(p, ship, here)
            local dx, dy, dz = hit.X - here.X, hit.Y - here.Y, hit.Z - here.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            local age = now - p.launchedAt
            local speed = CFG.POD_SPEED[1] + (CFG.POD_SPEED[2] - CFG.POD_SPEED[1]) * math.min(1, age / CFG.POD_ACCEL)
            local step = speed * dt
            if d <= math.max(40, step) or age > CFG.POD_TIMEOUT then
                Out.call(pod, "K2_SetActorLocation", hit, false, {}, true)
                podHit(p, ship)
            else
                dx, dy, dz = dx / d, dy / d, dz / d
                -- A little corkscrew while far out, straight in for the last stretch, like a piloted pod.
                local w = math.min(1, d / 3000) * 0.25
                p.wobble = p.wobble + dt * 2.5
                local sw = math.sin(p.wobble) * w
                local at = { X = here.X + (dx - dy * sw) * step, Y = here.Y + (dy + dx * sw) * step,
                    Z = here.Z + (dz + math.cos(p.wobble) * w * 0.5) * step }
                local rot = { Pitch = math.deg(math.asin(math.max(-1, math.min(1, dz)))),
                    Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
                Out.call(pod, "K2_SetActorLocationAndRotation", at, rot, false, {}, true)
            end
        end
    end
end

-- Ship combat ----------------------------------------------------------------------------------------------------
-- A crew's target is your ship or another crew's ship (c.target = { player = true } or { crew = o }).
local function targetShip(t)
    if not t then return nil end
    if t.player then return valid(S.playerShip) and (S.playerShip.MainHullHealth or 0) > 0 and S.playerShip or nil end
    local o = t.crew
    if o.state ~= "gone" and shipOk(o) then return o.ship end
end

local function attackersOn(t)
    local n = 0
    for _, o in ipairs(S.crews) do
        if o.state == "attack" and o.target and ((t.player and o.target.player) or (t.crew and o.target.crew == t.crew)) then
            n = n + 1
        end
    end
    return n
end

-- Members still on the ship (flying and shooting it) vs off boarding someone.
local function crewOnShip(c)
    for _, m in ipairs(c.members) do if m.alive and not m.boarding then return true end end
    return false
end

local function engage(c, t, now, why)
    c.state, c.target, c.attackStart = "attack", t, now
    c.engageUntil = now + rnd(CFG.ENGAGE_MAX)
    c.orbitAngle, c.orbitDir = math.random() * 2 * math.pi, math.random() < 0.5 and -1 or 1
    c.orbitR = rnd(CFG.ORBIT)
    c.boardPlan, c.boardAt, c.boarded, c.man, c.sep = nil, now + rnd(CFG.BREACH_AFTER), nil, nil, nil
    local alive = 0
    for _, m in ipairs(c.members) do if m.alive then alive = alive + 1 end end
    local all, one = CFG.RIVAL_BOARD_ALL, CFG.RIVAL_BOARD_ONE
    if t.player then all, one = CFG.BOARD_ALL, CFG.BOARD_ONE end
    local r = math.random()
    if r < all then c.boardPlan = "all"
    elseif alive >= 2 and r < all + one then c.boardPlan = "one" end
    if t.player then say(S.pc, ("Contact: the %s is coming about to attack you"):format(c.shipName)) end
    X.log(("[rivals] %s%s engages %s (%s%s, gunnery %.2f)"):format(crewLabel(c), c.diehard and " (to the death)" or "",
        t.player and "your ship" or ("the " .. t.crew.shipName), why, c.boardPlan and (", boarding: " .. c.boardPlan) or "",
        c.gunnery or 0))
end

local function disengage(c, now, why)
    c.fireAt, c.target = nil, nil
    if shipOk(c) then setShipEnemy(c, nil) end
    c.state = "travel"
    c.station = c.station or chooseStation(c)
    X.log(("[rivals] %s breaks off (%s, %d bursts fired)"):format(crewLabel(c), why, c.bursts or 0))
    c.bursts = 0
end

-- Size up ships in sight; returns true if the crew starts a fight.
local function lookForFights(c, shipLoc, now, hurt)
    c.seen = c.seen or {}
    local cands = {}
    if valid(S.playerShip) and (S.playerShip.MainHullHealth or 0) > 0 then
        local d = dist(shipLoc, S.playerShip:K2_GetActorLocation())
        if d < CFG.SHIP_SIGHT then table.insert(cands, { key = "player", t = { player = true }, d = d }) end
    end
    for _, o in ipairs(S.crews) do
        if o ~= c and o.state ~= "docked" and o.state ~= "gone" and o.state ~= "waiting" and shipOk(o) then
            local d = dist(shipLoc, o.ship:K2_GetActorLocation())
            if d < CFG.SHIP_SIGHT then table.insert(cands, { key = o, t = { crew = o }, d = d }) end
        end
    end
    -- Shot at: fight back against whoever did it. A crew that fired at us is known (fireControl); anything else
    -- (you, mines) is taken to be the nearest ship in gun range that isn't docked, you or a rival alike.
    if hurt then
        if c.shotBy and now - (c.shotAt or 0) < 5 and c.shotBy.state ~= "gone" and shipOk(c.shotBy) then
            engage(c, { crew = c.shotBy }, now, "shot at")
            return true
        end
        local near
        for _, k in ipairs(cands) do
            if k.d < CFG.GUN_RANGE * 1.3 and (not near or k.d < near.d) then near = k end
        end
        if near then engage(c, near.t, now, "shot at") return true end
    end
    -- Rushers make for their station and dock; they only fight when shot at.
    if c.rusher then return false end
    for _, k in ipairs(cands) do
        if now >= (c.seen[k.key] or 0) then
            c.seen[k.key] = now + CFG.ATTACK_COOLDOWN
            if attackersOn(k.t) < CFG.MAX_ON_SHIP and math.random() < c.aggression ^ 2 * CFG.ATTACK_CHANCE then
                engage(c, k.t, now, "sighted")
                return true
            end
        end
    end
    return false
end

-- Every frame: guns. A crew in a fight fires bursts while its target is in range and within GUN_CONE of the nose
-- (ships keep facing their target while they circle it). The gun aims along the controller's view (focused on it).
local function fireControl(now, dt)
    for _, c in ipairs(S.crews) do
        c.frameDt = dt
        local want = false
        local tgt = c.fireAt
        if tgt and c.state == "attack" and c.gun and valid(c.gun) and shipOk(c) and valid(tgt) and crewOnShip(c) then
            local sl, tl = c.ship:K2_GetActorLocation(), tgt:K2_GetActorLocation()
            local d = dist(sl, tl)
            if c.runPhase == "in" and d < CFG.GUN_RANGE * 1.3 and d > CFG.RUN_OVERSHOOT * 0.5 then
                -- aim: slew the nose toward the target (flight path stays the movement's)
                local r = c.ship:K2_GetActorRotation()
                local wantYaw = math.deg(math.atan(tl.Y - sl.Y, tl.X - sl.X))
                local wantPitch = math.deg(math.atan(tl.Z - sl.Z, math.sqrt((tl.X - sl.X) ^ 2 + (tl.Y - sl.Y) ^ 2)))
                local dy = (wantYaw - r.Yaw + 180) % 360 - 180
                local dp = wantPitch - r.Pitch
                local step = CFG.NOSE_TURN * (c.frameDt or 0.016)
                if math.abs(dy) < 70 then
                    c.ship:K2_SetActorRotation({ Pitch = r.Pitch + math.max(-step, math.min(step, dp)),
                        Yaw = r.Yaw + math.max(-step, math.min(step, dy)), Roll = r.Roll }, true)
                end
            end
            if d < CFG.GUN_RANGE and d > 1 then
                local f = c.ship:GetActorForwardVector()
                local dot = (f.X * (tl.X - sl.X) + f.Y * (tl.Y - sl.Y) + f.Z * (tl.Z - sl.Z)) / d
                if dot > math.cos(math.rad(CFG.GUN_CONE)) then
                    if now >= (c.burstUntil or 0) then
                        c.burstOn = not c.burstOn
                        c.burstUntil = now + rnd(c.burstOn and CFG.BURST or CFG.BURST_PAUSE)
                    end
                    want = c.burstOn
                end
            end
        end
        if tgt and c.state == "attack" and shipOk(c) and valid(tgt) and crewOnShip(c) then
            local ok, fired = pcall(fireTurrets, c, tgt, now)
            if not ok and not S.turretErr then S.turretErr = true X.log("[rivals] turrets failed: " .. tostring(fired)) end
            if ok and fired then
                c.turretShots = (c.turretShots or 0) + 1
                if c.target and c.target.crew then c.target.crew.shotBy, c.target.crew.shotAt = c, now end
            end
        end
        if want and c.target and c.target.crew then c.target.crew.shotBy, c.target.crew.shotAt = c, now end
        if want ~= (c.firing or false) then
            c.firing = want
            if want then c.bursts = (c.bursts or 0) + 1 end
            pcall(function() if want then c.gun:ServerStartFire() else c.gun:ServerStopFire() end end)
        end
    end
end

-- Boarding parties: one member (or the whole crew) in pods; they materialize at your breach points while you're
-- aboard and hunt you; the ship carries on fighting with whoever stayed. Aboard a rival's ship (p.victim) there are no
-- bodies: the fight is rounds of one kill each, and boarders who clear the ship keep it.
local function launchParty(c, now)
    local members = {}
    for _, m in ipairs(c.members) do
        if m.alive then
            table.insert(members, m)
            if c.boardPlan == "one" then break end
        end
    end
    if #members == 0 then return end
    local p = { id = c.id, parent = c, members = members, captain = members[1].name, shipName = c.shipName,
        state = "pods", podsAt = now, victim = c.target.crew }
    for _, m in ipairs(members) do m.boarding = true end
    c.party = p
    launchPods(c, p, targetShip(c.target))
    if c.boardPlan == "all" and not p.victim then say(S.pc, ("The %s is pulling alongside to board you!"):format(c.shipName)) end
end

local function endParty(p, why)
    dematerialize(p)
    for _, m in ipairs(p.members) do
        m.boarding = nil
        -- Stranded with no ship to go back to: lost.
        if not shipOk(p.parent) then m.alive = false end
    end
    p.parent.party = nil
    X.log(("[rivals] %s's boarders %s"):format(p.parent.captain, why))
end

local function defenders(o)
    local list = {}
    for _, m in ipairs(o.members) do if m.alive and not m.boarding then table.insert(list, m) end end
    return list
end

-- The boarders cleared the ship: it's theirs now, under its old name, and they go on with its raid.
local function captureShip(p, now)
    local c, o = p.parent, p.victim
    local kept = {}
    for _, m in ipairs(c.members) do
        local boarded = false
        for _, b in ipairs(p.members) do if b == m then boarded = true end end
        if not boarded then table.insert(kept, m) end
    end
    local crew = {}
    for _, m in ipairs(p.members) do
        m.boarding = nil
        if m.alive then table.insert(crew, m) end
    end
    c.members, c.party = kept, nil
    o.members, o.captain, o.diehard, o.fleeHull = crew, p.captain, c.diehard, c.fleeHull
    o.fireAt, o.target, o.boardPlan, o.state = nil, nil, nil, "travel"
    setShipEnemy(o, nil)
    o.station = o.station or chooseStation(o)
    o.seen, c.seen = o.seen or {}, c.seen or {}
    o.seen[c], c.seen[o] = math.huge, math.huge
    X.log(("[rivals] %s took the %s from its crew"):format(p.captain, o.shipName))
    if crewAlive(c) then
        disengage(c, now, "took their ship")
    else
        c.fireAt, c.target = nil, nil
        if shipOk(c) then
            dropTurrets(c)
            R.destroy(c.ship)
        end
        c.ship, c.state = nil, "gone"
        X.log(("[rivals] %s left their own %s behind"):format(p.captain, c.shipName))
    end
end

local function fightAboard(p, now)
    local o = p.victim
    if o.state == "gone" or not shipOk(o) then
        for _, m in ipairs(p.members) do m.alive = false end
        p.parent.party = nil
        X.log(("[rivals] %s's boarders were lost with the %s"):format(p.captain, o.shipName))
        return
    end
    if o.bodies or now < p.roundAt then return end -- its crew are on foot in a station you're in: nothing to simulate
    p.roundAt = now + rnd(CFG.BOARD_ROUND)
    local foes, ours = defenders(o), {}
    for _, m in ipairs(p.members) do if m.alive then table.insert(ours, m) end end
    if #foes > 0 then
        local a, d = pick(ours), pick(foes)
        local attackerWins = math.random() < 0.5 + (a.skill - d.skill) * CFG.BOARD_SKILL
        local dead = attackerWins and d or a
        dead.alive = false
        X.log(("[rivals] %s was killed in the fight aboard the %s"):format(dead.name, o.shipName))
        if not attackerWins then return end
    end
    if #defenders(o) == 0 then captureShip(p, now) end
end

local function updateParty(p, now, place, ending)
    if p.bodies then bodiesAlive(p) end
    local alive = false
    for _, m in ipairs(p.members) do if m.alive then alive = true end end
    if not alive then dematerialize(p) p.parent.party = nil return end
    if p.state == "pods" then
        local waiting = false
        for _, pod in ipairs(S.pods) do
            if pod.crew == p and not pod.boarded then
                if (pod.hitAt and now - pod.hitAt >= CFG.BREACH_DELAY) or now - p.podsAt > CFG.POD_TIMEOUT + 5 then
                    pod.boarded = true
                else
                    waiting = true
                end
            end
        end
        if not waiting and p.victim then
            p.state, p.roundAt = "fight", now + rnd(CFG.BOARD_ROUND)
            X.log(("[rivals] %s %s aboard the %s"):format(p.captain, #p.members > 1 and "and crew are" or "is", p.victim.shipName))
        elseif not waiting then
            p.state, p.boardedAt = "aboard", now
            say(S.pc, ("%s %s cut through your hull"):format(p.captain, #p.members > 1 and "and crew have" or "has"))
        end
    elseif p.state == "fight" then
        fightAboard(p, now)
    elseif p.state == "aboard" then
        if place == "ship" then
            p.lastSeenAboard = now
            if not p.bodies and now >= (p.spotsAt or 0) then
                p.spotsAt = now + 1 -- (path queries: not every frame while there's nowhere yet)
                local pawn = S.pc.Pawn
                local spots = breachSpots(nil, valid(pawn) and pawn:K2_GetActorLocation() or nil)
                if #spots > 0 then materialize(p, spots, "boarding") end
            end
        elseif p.bodies and now - (p.lastSeenAboard or now) > CFG.DEMATERIALIZE_AFTER then
            dematerialize(p)
        end
        if ending then endParty(p, "went back to their ship (raid ending)")
        elseif now - (p.lastSeenAboard or p.boardedAt) > CFG.ABOARD_WAIT then endParty(p, "gave up waiting aboard your ship") end
    end
end

-- Simulated crews docked at the same station sometimes run into each other: someone may not come back.
local function simClashes(dt)
    local by = {}
    for _, c in ipairs(S.crews) do
        if c.state == "docked" and c.station and not c.bodies then
            by[c.station] = by[c.station] or {}
            table.insert(by[c.station], c)
        end
    end
    for st, list in pairs(by) do
        if #list >= 2 and math.random() < CFG.SIM_CLASH_PER_MIN * dt / 60 then
            local a = list[math.random(#list)]
            local b
            repeat b = list[math.random(#list)] until b ~= a
            local loser = math.random() < 0.5 and a or b
            for _, m in ipairs(loser.members) do
                if m.alive and not m.boarding then
                    m.alive = false
                    X.log(("[rivals] %s (%s) was killed by %s's crew in %s"):format(m.name, loser.shipName,
                        (loser == a and b or a).captain, st.name))
                    break
                end
            end
        end
    end
end

-- You boarding a rival's ship --------------------------------------------------------------------------------------
-- The free slots are listed once a raid (two object scans, ~45 ms each: a hitch per interior before), then handed out.
local function freeInteriorSlot()
    if not S.freeSlots then
        S.freeSlots = {}
        local insides = FindAllOf("RaidSpaceshipInside") or {}
        for _, s in ipairs(FindAllOf("RaidFrigateIntSpawn") or {}) do
            if valid(s) and not s.bForFrigateSpawning then
                local l, taken = s:K2_GetActorLocation(), false
                for _, i in ipairs(insides) do
                    if valid(i) and dist(i:K2_GetActorLocation(), l) < 1000 then taken = true end
                end
                if not taken then table.insert(S.freeSlots, { X = l.X, Y = l.Y, Z = l.Z }) end
            end
        end
    end
    return table.remove(S.freeSlots, 1)
end

local function makeInterior(c)
    local at = freeInteriorSlot()
    if not at then
        if not S.noSlotSaid then S.noSlotSaid = true X.log("[rivals] no free interior slot left on this map") end
        return
    end
    S.interiors = (S.interiors or 0) + 1
    local path = c.design and c.design.inside
    local parent = path and CFG.INSIDE_PARENTS[path:match("^(.-/)") or ""]
    if parent and not loadClass(CFG.INSIDES .. parent) then path = nil end  -- no parent: don't risk the child (#192)
    local cls = path and loadClass(CFG.INSIDES .. path)
    if not cls then
        X.log(("[rivals] no interior class for the %s: using yours"):format(c.shipName))
        cls = S.homeInside:GetClass()
    end
    local inside = S.pc:GetWorld():SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 })
    if valid(inside) then
        c.inside = inside
        X.log(("[rivals] interior for the %s (%s) loading: %s"):format(c.shipName, c.design and c.design.name or "?",
            inside:GetClass():GetFName():ToString()))
    end
end

-- The new interior spawns a hull of its own a moment later: the rival's takes its place.
local function pairInterior(c)
    local own = c.inside.SpaceshipToPairTo
    if not valid(own) then return end
    local ctrl = own.Controller
    c.inside.SpaceshipToPairTo = c.ship
    c.ship.MyShipInside = c.inside
    if valid(ctrl) then
        ctrl:UnPossess()
        R.destroy(ctrl)
    end
    R.destroy(own)
    local box = c.inside.InSideComp
    c.insideBox = { c = box:K2_GetComponentLocation(), e = box:GetScaledBoxExtent() }
    X.addInteriorNav(S.pc, c.inside)
    -- A hull already shot to 0 before its interior came: the interior is new, its life-support pipe whole, so the ship
    -- read "disabled" with nothing broken to mend (#70). Break it the way the game's own damage does (pipe Health 0,
    -- LifeSupportDestroyed on hull and interior): the blowtorch then mends it (blowtorch.lua) and the ship flies again.
    if (c.ship.MainHullHealth or 0) <= 0 then
        pcall(function()
            local comps = c.inside:K2_GetComponentsByClass(StaticFindObject("/Script/RaidGame.RaidUseableFrigatePartComponent"))
            for i = 1, #comps do
                local part = comps[i]:get()
                if valid(part) and part:GetFName():ToString():find("LifeSupport", 1, true) then part.Health = 0 end
            end
            c.inside.LifeSupportDestroyed = true
            c.ship.bLifeSupportDestroyed = true
        end)
    end
    X.log(("[rivals] interior for the %s ready"):format(c.shipName))
end

-- Out of the pod and through the hull, at one of the ship's breach points. No navmesh needed: the spots are the game's.
-- Where you stand after cutting in: walkable floor by a breach point that joins up with the inside of the ship. The
-- breach points themselves are in the hull wall, about 5 m up (the user came out inside a wall), and the floor nearest
-- one can be outside the walls (see joined). No breach point with such floor: the floor at the ship's dock starts.
-- nil while the interior's navmesh isn't built yet.
local function breachLanding(inside)
    local anchor = insideAnchor(inside, nil)
    if not anchor then return nil end
    for _, at in ipairs(entryPoints(inside)) do
        for try = 1, 4 do
            local p = try == 1 and projected(at, { X = 250, Y = 250, Z = 600 }) or reachableNear(at, 500)
            if p and not X.offLimits(p) and joined(anchor, p) then return { X = p.X, Y = p.Y, Z = p.Z + 100 } end
        end
    end
    return { X = anchor.X, Y = anchor.Y, Z = anchor.Z + 100 }
end

-- The camera back on your body after the void wait (see rescueFromVoid).
local function voidCamOff(pawn)
    if not S.voidCam then return end
    S.voidCam = nil
    pcall(function() S.pc:SetViewTargetWithBlend(pawn, 0, 0, 0, false) end)
end

-- Your body after a pod flight. The game parks it for the flight (hidden, movement component not ticking, no gravity,
-- not turned by the mouse) and its own breach ability undoes that; ours and the void rescue skip that ability, so you
-- could pitch and shoot but not turn or walk (2026-11-14, read off the body and fixed live from the bridge).
local function afterPod(foot)
    local cdo
    pcall(function() cdo = foot:GetClass():GetCDO() end)
    local cm = foot.CharacterMovement
    local grav = 1.0
    pcall(function() if valid(cdo.CharacterMovement) then grav = cdo.CharacterMovement.GravityScale end end)
    local was = ("yaw=%s tick=%s grav=%s"):format(tostring(foot.bUseControllerRotationYaw),
        tostring(valid(cm) and cm:IsComponentTickEnabled()), tostring(valid(cm) and cm.GravityScale))
    pcall(function() foot.bUseControllerRotationYaw = cdo and cdo.bUseControllerRotationYaw ~= false end)
    if valid(cm) then
        pcall(function() cm:SetComponentTickEnabled(true) end)
        pcall(function() cm.GravityScale = grav end)
        pcall(function() cm:SetMovementMode(1, 0) end)
    end
    pcall(function() foot:SetActorHiddenInGame(false) end)
    -- and the controller's input, which the body's fix alone didn't give back (all of these were needed live)
    pcall(function() S.pc:ResetIgnoreInputFlags() end)
    pcall(function() foot:EnableInput(S.pc) end)
    pcall(function() S.pc:EnableInput(S.pc) end)
    pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(S.pc) end)
    pcall(function() S.pc:SetCinematicMode(false, false, false, true, true) end)
    pcall(function() S.pc.bShowMouseCursor = false end)
    pcall(function() S.pc:FlushPressedKeys() end)
    S.voidCam = true
    voidCamOff(foot)
    X.log("[rivals] your body after the pod had " .. was .. ": walking again")
end

-- Traces for podExitCheck (the Visibility channel, your body ignored). Kept in R (not exported for use elsewhere):
-- rivals.lua is at Lua's 200-locals limit.
R.Ground = { NOCOL = { R = 0, G = 0, B = 0, A = 0 } }
function R.Ground.trace(foot, from, to)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = {}
    if Out.call(ksl, "LineTraceSingle", S.pc, from, to, 0, false, { foot }, 0, out, true, R.Ground.NOCOL, R.Ground.NOCOL, 0)
        and out.ImpactPoint then
        return { X = out.ImpactPoint.X, Y = out.ImpactPoint.Y, Z = out.ImpactPoint.Z }
    end
end
-- The first thing straight below `at`, within `depth`.
function R.Ground.below(foot, at, depth) return R.Ground.trace(foot, at, { X = at.X, Y = at.Y, Z = at.Z - depth }) end
-- Nothing between `at` and a body standing on `p` (aimed 60 above its floor point).
function R.Ground.inSight(foot, at, p) return R.Ground.trace(foot, at, { X = p.X, Y = p.Y, Z = p.Z + 60 }) == nil end

-- Just out of a pod that didn't bring you into a rival's ship (see POD_EXIT_CHECK). The game's station docking left the
-- body parked, in a sealed shaft at Fortress (2026-11-14: "stuck inside what looks to be a tube"), fixed live from the bridge.
local function podExitCheck(foot)
    local l = foot:K2_GetActorLocation()
    local cm = foot.CharacterMovement
    local parked = valid(cm) and not cm:IsComponentTickEnabled()
    local floor = projected({ X = l.X, Y = l.Y, Z = l.Z - 100 }, { X = 80, Y = 80, Z = 120 })
    if floor and not parked then return end
    if not floor then
        -- Straight down first: the real floor under you (a trace), and the navmesh right where it hit. At Fortress
        -- (Space_Alpha, 2026-11-16) the pod leaves you above a hatch whose room floor is ~590 below; stepping the
        -- navmesh search down 300 at a time (+-200) found a point 180 to the side first, behind a wall, and put the
        -- tester in it. Any other spot must be in sight from where you came out (nothing in the way of a line to it).
        local spot
        local down = R.Ground.below(foot, l, 1500)
        -- (navmesh is built around you as you arrive, so right out of the pod there may be none yet: then the floor
        -- point itself, which the trace reached with nothing in the way)
        if down then spot = projected(down, { X = 80, Y = 80, Z = 150 }) or down end
        for dz = 300, 1500, 300 do
            if spot then break end
            local p = projected({ X = l.X, Y = l.Y, Z = l.Z - dz }, { X = 200, Y = 200, Z = 200 })
            if p and R.Ground.inSight(foot, l, p) then spot = p end
        end
        if not spot then
            local p = projected(l)
            if p and R.Ground.inSight(foot, l, p) then spot = p end
        end
        if spot then
            Out.call(foot, "K2_SetActorLocation", { X = spot.X, Y = spot.Y, Z = spot.Z + 100 }, false, {}, true)
            X.log(("[rivals] out of the pod with no floor under you at %.0f,%.0f,%.0f: moved to the floor at %.0f,%.0f,%.0f")
                :format(l.X, l.Y, l.Z, spot.X, spot.Y, spot.Z))
        else
            X.log(("[rivals] out of the pod with no floor under you at %.0f,%.0f,%.0f, and no floor found near"):format(l.X, l.Y, l.Z))
        end
    end
    if parked then afterPod(foot) end
end

-- force: the pod is at the hull (or already gone), so with no navmesh yet you come in at a dock start (made to be stood
-- at) rather than not at all. Returns whether you're in.
local function breachInto(c, force)
    local ok, spot = pcall(breachLanding, c.inside)
    if not ok then spot = nil end
    if not spot then
        if not force then return false end
        pcall(function()
            local l = c.inside.ShipDockOnePlayerStart:K2_GetComponentLocation()
            spot = { X = l.X, Y = l.Y, Z = l.Z + 50 }
        end)
        spot = spot or entryPoints(c.inside)[1]
        X.log("[rivals] breach: the interior's navmesh isn't ready, coming in at a dock start")
    end
    local pod, foot = S.pc.Pawn, S.foot
    if not (spot and valid(foot)) then return false end
    local inPod = valid(pod) and pod:GetAddress() ~= foot:GetAddress()
    if inPod then S.pc:Possess(foot) end
    afterPod(foot)
    foot:SetActorHiddenInGame(false)
    foot:SetActorEnableCollision(true)
    Out.call(foot, "K2_SetActorLocation", spot, false, {}, true)
    pcall(function() foot.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
    -- facing into the ship
    S.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(c.insideBox.c.Y - spot.Y, c.insideBox.c.X - spot.X)), Roll = 0 })
    if inPod then R.destroy(pod) end
    S.podAt, S.voidSince = nil, nil
    -- crew.lua brings your crewmates in through the same hole, behind you
    S.breach = { at = { X = spot.X, Y = spot.Y, Z = spot.Z }, time = os.clock(), ship = c.shipName,
        spots = breachSpots(c.inside) }
    say(S.pc, ("You cut through the hull of the %s"):format(c.shipName))
    X.log(("[rivals] you boarded the %s at %.0f,%.0f,%.0f"):format(c.shipName, spot.X, spot.Y, spot.Z))
    return true
end

-- A wreck (hull shot to 0, crew dead with it) still floats where it died, and the user expects to board it like any
-- other ship: its hull only has to still exist (shipOk wants hull and controller).
local function hullThere(c)
    if c.state == "wreck" then
        if c.ship and not valid(c.ship) then c.ship = nil end
        return c.ship ~= nil
    end
    return shipOk(c)
end

local function boardable(c)
    return (c.state == "travel" or c.state == "attack" or c.state == "leaving" or c.state == "docked"
        or c.state == "derelict" or c.state == "wreck") and hullThere(c)
end

-- How far a point is from a hull's collision surface (its centre distance if that can't be read). Measured only when
-- the centre is near enough for the hull to matter. The user rammed a rival over and over without breaching: the hull
-- stopped the pod well outside PLAYER_BOARD_RANGE of the centre.
local function hullGap(ship, here, d)
    if d > CFG.PLAYER_BOARD_RANGE * 4 then return d end
    local hit = {}
    local ok = pcall(function() ship.Mesh:GetClosestPointOnCollision(here, hit, FName("None")) end)
    if not (ok and hit.X) then return d end
    local dx, dy, dz = hit.X - here.X, hit.Y - here.Y, hit.Z - here.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- A pod's breach (or anything else) that left you on foot in the dark at the map origin, where the game parks your body
-- during a pod flight. If the pod was last seen at a rival's hull, that's the ship you hit: you come out inside it, once
-- its interior is in (VOID_BOARD_*). Otherwise back into your own ship after VOID_RESCUE seconds.
-- While you wait in the void the camera looks at the hull you hit (or your own ship), not at the dark (user: "I was in a black
-- void for a moment while the interior loaded which doesn't look great"). Looked at every frame (R.frame) as well as
-- from the update, so the dark doesn't show for the half second between two updates.
local function rescueFromVoid(now)
    local pawn = S.pc.Pawn
    if not (valid(pawn) and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then S.voidSince = nil return end
    local l = pawn:K2_GetActorLocation()
    if math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) > CFG.VOID_NEAR then
        S.voidSince = nil
        voidCamOff(pawn)
        return
    end
    S.voidSince = S.voidSince or now
    local waited = now - S.voidSince
    local c = S.podShip
    if not S.voidCam then
        local look = (c and hullThere(c) and c.ship) or (valid(S.playerShip) and S.playerShip) or nil
        if look and pcall(function() S.pc:SetViewTargetWithBlend(look, 0, 0, 0, false) end) then S.voidCam = true end
    end
    if c and S.podSeen and S.voidSince - S.podSeen < CFG.VOID_BOARD_RECENT and waited < CFG.VOID_BOARD_WAIT
        and boardable(c) then
        if not c.inside and (S.interiors or 0) < CFG.PLAYER_BOARD_MAX then
            makeInterior(c)
            if c.inside then X.log(("[rivals] the pod hit the %s before its interior was in: loading it now"):format(c.shipName)) end
        end
        if c.inside then
            -- (two seconds for the interior's navmesh, then in at a dock start)
            if c.insideBox and breachInto(c, waited > 2) then return end
            return
        end
    end
    if waited < CFG.VOID_RESCUE or not valid(S.homeInside) then return end
    -- The game's own breach parks your body at 0,0,0 while it plays (~2.5 s, longer at some ships): while the controller
    -- still has a ship it is breaching into, that's not the void (#365: sent back to your cockpit mid-breach).
    -- (a plain property read on the controller; nil if the game doesn't have it)
    local breaching
    pcall(function() breaching = S.pc.ShipBreachingTo end)
    if breaching and valid(breaching) and waited < CFG.VOID_BOARD_WAIT then return end
    X.log(("[rivals] void rescue after %.1f s: pod last at %s, its ship %s, interiors %d/%d"):format(waited,
        S.podSeen and ("%.1f s before"):format(S.voidSince - S.podSeen) or "never", c and c.shipName or "none",
        S.interiors or 0, CFG.PLAYER_BOARD_MAX))
    S.voidSince, S.podShip = nil, nil
    local ok, spot = pcall(breachLanding, S.homeInside)
    if not (ok and spot) then
        spot = entryPoints(S.homeInside)[1]
        if not spot then return end
        spot = { X = spot.X, Y = spot.Y, Z = spot.Z + 100 }
    end
    Out.call(pawn, "K2_SetActorLocation", spot, false, {}, true)
    afterPod(pawn)
    say(S.pc, "That hull had no way in: you made it back to your ship")
    X.log("[rivals] you were left in the void after a breach: moved back into your ship")
end

-- Every frame while you fly a pod (a pod covers several metres a frame: looked at twice a second, it could go from out
-- of range to into the hull between two looks, and then the game's own impact left you in the void).
local function playerBoarding(now)
    local pawn = S.pc.Pawn
    if not valid(pawn) then return end
    if not pawn.bADropPod then
        -- Just out of a pod: if the game's breach put you inside a rival's ship, your crewmates follow you in (crew.lua)
        -- and your body gets the same check as after ours.
        if S.podSeen and now - S.podSeen < CFG.VOID_BOARD_RECENT then
            local l = pawn:K2_GetActorLocation()
            for _, c in ipairs(S.crews) do
                if c.insideBox and inBox(c.insideBox, l, 300) then
                    S.podSeen, S.podAt, S.voidSince = nil, nil, nil
                    afterPod(pawn)
                    S.breach = { at = { X = l.X, Y = l.Y, Z = l.Z }, time = os.clock(), ship = c.shipName,
                        spots = breachSpots(c.inside) }
                    X.log(("[rivals] the game's breach brought you into the %s at %.0f,%.0f,%.0f"):format(c.shipName, l.X, l.Y, l.Z))
                    break
                end
            end
        end
        local l = pawn:K2_GetActorLocation()
        if S.podSeen and now - S.podSeen >= CFG.POD_EXIT_CHECK and now - S.podSeen < CFG.VOID_BOARD_RECENT
            and math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) > CFG.VOID_NEAR then -- (in the void: rescueFromVoid's)
            S.podSeen, S.podAt = nil, nil
            local ok, err = pcall(podExitCheck, pawn)
            if not ok then X.log("[rivals] pod exit check: " .. tostring(err)) end
        end
        return
    end
    -- The breach prompt ("BREACH BOOST READY" when the pod's nose is on a hull in range, issue #77): the pod's BeginPlay
    -- starts its looping 0.1 s Timed_BreachCheck timer (BreachCheck -> SetAbleToBreach -> the HUD's
    -- SetUIAbleToPodBreach) only on the non-authority branch, which never runs offline. Started here once per pod;
    -- from then on the game runs it itself.
    local podAddr = pawn:GetAddress()
    if S.breachTimerPod ~= podAddr then
        S.breachTimerPod = podAddr
        local ok, err = pcall(function()
            lib("/Script/Engine.Default__KismetSystemLibrary"):K2_SetTimer(pawn, "Timed_BreachCheck", 0.1, true, 0, 0)
        end)
        if not ok then X.log("[rivals] pod breach prompt timer: " .. tostring(err)) end
    end
    local here = pawn:K2_GetActorLocation()
    -- the pod's course: its velocity, or its nose while it's barely moving
    local v = pawn:GetVelocity()
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
    if speed < 100 then v, speed = pawn:GetActorForwardVector(), 1 end
    local loading = false
    for _, c in ipairs(S.crews) do
        if c.inside and not c.insideBox and valid(c.inside) then loading = true end
    end
    local nearest, nd, want, wd
    for _, c in ipairs(S.crews) do
        -- Docked ships too (parked at a station while the crew raids it): before, a pod into one of those met a hull
        -- with no interior, and the game left you where your body waits during a pod flight, 0,0,0 in the dark.
        if boardable(c) then
            local at = c.ship:K2_GetActorLocation()
            local d = dist(here, at)
            local gap = hullGap(c.ship, here, d)
            if not nd or gap < nd then nearest, nd = c, gap end
            if c.insideBox then
                if not CFG.PLAYER_BOARD_GAME and (d < CFG.PLAYER_BOARD_RANGE or gap < CFG.PLAYER_BOARD_TOUCH) and breachInto(c, gap < CFG.PLAYER_BOARD_FORCE) then
                    return
                end
            elseif not c.inside and d < CFG.PLAYER_BOARD_PREP then
                local cos = ((at.X - here.X) * v.X + (at.Y - here.Y) * v.Y + (at.Z - here.Z) * v.Z) / (math.max(1, d) * speed)
                if (d < CFG.PLAYER_BOARD_CLOSE or cos > math.cos(math.rad(CFG.PLAYER_BOARD_AIM))) and (not wd or d < wd) then
                    want, wd = c, d
                end
            end
        end
    end
    S.podAt, S.podSeen = here, now
    S.podShip = nd and nd < CFG.VOID_BOARD_NEAR and nearest or nil
    -- one interior at a time (each is a level streaming in), and only for the ship you're flying at
    if want and not loading and (S.interiors or 0) < CFG.PLAYER_BOARD_MAX then makeInterior(want) end
end

-- Your hands on its helm: the game has handed you the rival's hull (Interact possesses it). It's your ship from now on,
-- and what's left of its crew carries on as bodies with nothing to fly.
local function checkStolen()
    local pawn = S.pc.Pawn
    if not valid(pawn) then return end
    for _, c in ipairs(S.crews) do
        if c.insideBox and valid(c.ship) and c.ship:GetAddress() == pawn:GetAddress() then
            X.log(("[rivals] you took the %s"):format(c.shipName))
            say(S.pc, ("The %s is yours"):format(c.shipName))
            -- What the game would save is the interior's row: the backend gets the hull's.
            local f = io.open(CFG.SHIP_STOLEN_FILE, "w")
            if f then
                f:write(c.design and c.design.row or "")
                f:close()
            end
            -- its key card, or a station airlock shuts you out once you step off (#311)
            local carded, err = pcall(require("space").cardForShip, c.inside, c.shipName, c.design and c.design.row)
            if not carded then X.log("key card for the taken ship: " .. tostring(err)) end
            S.playerShip, S.homeInside, S.playerShipMaxHull = c.ship, c.inside, c.maxHull
            S.home = { box = c.insideBox }
            -- Its turrets are the mod's (fitTurrets: the hull's own were destroyed), kept on the crew, not in the hull's
            -- SpawnedTurretArray: your gunner finds them here (#70: "mans 0 turret(s)" on a taken ship).
            S.stolenTurrets = { ship = c.ship:GetAddress(), list = c.turrets or {} }
            c.turrets = {}
            c.fireAt, c.target, c.ship, c.shipCtrl, c.insideBox, c.inside = nil, nil, nil, nil, nil, nil
            c.state = "gone"
            return
        end
    end
end

-- Within PROVOKE_CONE of where you're looking (the camera: your ship's guns or the turret you man aim along it). Its
-- foe's hits and yours land at the same time, so this is what tells the ship you shot from the one you didn't.
local function aimCos(at)
    local ship = S.playerShip
    local ok, r = pcall(function() return S.pc:GetControlRotation() end)
    if not (ok and r and valid(ship)) then return -1 end
    local from = ship:K2_GetActorLocation()
    local dx, dy, dz = at.X - from.X, at.Y - from.Y, at.Z - from.Z
    local n = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
    local yaw, pitch = math.rad(r.Yaw), math.rad(r.Pitch)
    local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
    return (dx * fx + dy * fy + dz * fz) / n
end

-- Two ships in a dogfight are often both inside the cone: only the one nearest your line of fire counts.
local function inYourSights(c, at)
    local mine = aimCos(at)
    if mine < math.cos(math.rad(CFG.PROVOKE_CONE)) then return false end
    for _, o in ipairs(S.crews) do
        if o ~= c and o.ambient and o.state == "attack" and shipOk(o) and aimCos(o.ship:K2_GetActorLocation()) > mine then
            return false
        end
    end
    return true
end


-- What rivals.lua and the later modules call
M.aimCos, M.attackersOn, M.checkStolen, M.crewOnShip = aimCos, attackersOn, checkStolen, crewOnShip
M.disengage, M.engage, M.fireControl, M.flyPods = disengage, engage, fireControl, flyPods
M.holdOff, M.hullThere, M.inYourSights, M.launchParty = holdOff, hullThere, inYourSights, launchParty
M.lookForFights, M.makeInterior, M.manoeuvre = lookForFights, makeInterior, manoeuvre
M.pairInterior, M.playerBoarding, M.rescueFromVoid = pairInterior, playerBoarding, rescueFromVoid
M.simClashes, M.targetShip, M.updateParty = simClashes, targetShip, updateParty

return M
