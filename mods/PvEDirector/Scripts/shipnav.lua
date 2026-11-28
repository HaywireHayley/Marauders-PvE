-- Steering for the rivals' ships (rivals.lua flyTo). They fly by a direct MoveToLocation (space has no navmesh), which
-- took them straight into stations and rocks and left them pushing against them, some for good. Every move comes
-- through here first:
--   * a ship-sized sphere is swept along the way ahead; with something in it, the ship takes a detour along the
--     clear heading nearest the goal's (keeping to the side it chose last, so it doesn't dither left and right),
--   * a ship that stops getting anywhere backs off away from what it hit and comes at it again,
--   * one stuck over and over, far from you, is lifted clear (nobody sees it happen),
--   * one flying away from its goal for a while (its move went stale) has the move issued again.
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local N = {}
local X -- context from rivals.lua: log, valid, lib, dist

local CFG = {
    TRACE_CHANNEL = 0,          -- what blocks a sweep: the Visibility channel (stations, rocks, wrecks, ships' hulls)
    PROBE_RADIUS = 700,         -- the swept sphere when a ship's own size can't be read...
    PROBE_MIN = 400, PROBE_MAX = 1800, -- ...and the range its capsule radius is held to
    LOOK_AHEAD = 5000,          -- sweep this far ahead...
    LOOK_SECONDS = 2.5,         -- ...plus this many seconds at the ship's speed
    GOAL_CLEAR = 1200,          -- stop the sweep this short of the goal (a berth's approach point is near the station)
    CHECK_EVERY = 0.45,         -- seconds between sweeps per ship (the director updates every 0.5 s)
    DETOUR = 4500,              -- a detour waypoint this far along the clear heading...
    DETOUR_SECONDS = 5,         -- ...held this long, or until within DETOUR_REACHED of it, before looking again
    DETOUR_REACHED = 1200,
    STUCK_SPEED = 250,          -- slower than this...
    STUCK_SECONDS = 3.5,        -- ...for this long while not at the goal: stuck
    ARRIVED = 800,              -- within the move's acceptance radius plus this: there (holding still is fine)
    BACKOFF = 3500,             -- a stuck ship backs off this far, away from what it hit...
    BACKOFF_SECONDS = 4,        -- ...for at most this long
    NUDGE_AFTER = 3,            -- stuck this many times on the way to one goal: lifted clear...
    NUDGE = 2500,               -- ...this far...
    NUDGE_FAR = 25000,          -- ...if it's at least this far from your ship and from the camera
    NEW_GOAL = 6000,            -- a goal that jumps this far is a new one (the stuck count starts again)
    DRIFT_SECONDS = 6,          -- flying away from the goal this long (not detouring or backing off): move issued again
}
N.CFG = CFG

local stats = { detours = 0, stucks = 0, nudges = 0, drifts = 0 }

local function sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function along(a, v, s) return { X = a.X + v.X * s, Y = a.Y + v.Y * s, Z = a.Z + v.Z * s } end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function len(v) return math.sqrt(dot(v, v)) end
local function norm(v)
    local n = len(v)
    if n < 1e-6 then return nil end
    return { X = v.X / n, Y = v.Y / n, Z = v.Z / n }
end
local function cross(a, b)
    return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X }
end

-- Headings to try around the wanted one, as (yaw, pitch) degrees off it: nearest first, flat turns before climbs.
local AROUND = {}
for _, yp in ipairs({ { 30, 0 }, { -30, 0 }, { 0, 30 }, { 0, -30 }, { 30, 30 }, { -30, 30 }, { 30, -30 }, { -30, -30 },
    { 60, 0 }, { -60, 0 }, { 0, 60 }, { 0, -60 }, { 90, 0 }, { -90, 0 }, { 0, 90 }, { 0, -90 }, { 130, 0 }, { -130, 0 } }) do
    local y, p = math.rad(yp[1]), math.rad(yp[2])
    AROUND[#AROUND + 1] = { f = math.cos(y) * math.cos(p), r = math.sin(y) * math.cos(p), u = math.sin(p), side = yp[1] }
end

local SYS
local COLOR = { R = 1, G = 0, B = 0, A = 1 }
local sweepErr

-- Whether anything solid is in a ship-sized sphere swept between two points; the hit too, if so.
-- By trace channel: SphereTraceSingleForObjects with an object-type list from Lua never hit anything (the enum array
-- doesn't get through; cover.lua found the same), so until 2026-11-14 no sweep ever saw a station or a rock.
-- A sweep that starts already touching something (a ship along a hull) only counts as blocked heading into it, or
-- every heading would be blocked and the ship could never be steered off. The ignore list doesn't get through from Lua
-- either (only the ship itself, the world context, is left out): a hit on an ignored actor counts as clear.
local function blocked(ship, from, to, radius, ignore)
    if not (SYS and SYS:IsValid()) then SYS = X.lib("/Script/Engine.Default__KismetSystemLibrary") end
    local hit = {}
    local ok, r = pcall(function()
        return Out.call(SYS, "SphereTraceSingle", ship, from, to, radius, CFG.TRACE_CHANNEL, false, {}, 0, hit, true,
            COLOR, COLOR, 0)
    end)
    if not ok then
        if not sweepErr then sweepErr = true X.log("[shipnav] sweep failed: " .. tostring(r)) end
        return false
    end
    if r ~= true then return false end
    local ok2, a = pcall(function() return hit.Actor:Get() end)
    if ok2 and a and a:IsValid() then
        local addr = a:GetAddress()
        for _, i in ipairs(ignore or {}) do
            if X.valid(i) and i:GetAddress() == addr then return false end
        end
    end
    if hit.bStartPenetrating and hit.Normal then
        local d = { X = to.X - from.X, Y = to.Y - from.Y, Z = to.Z - from.Z }
        if d.X * hit.Normal.X + d.Y * hit.Normal.Y + d.Z * hit.Normal.Z >= 0 then return false end
    end
    return r == true, hit
end

local function radiusOf(ship)
    local r = CFG.PROBE_RADIUS
    pcall(function() r = ship.CapsuleComponent:GetScaledCapsuleRadius() end)
    return math.max(CFG.PROBE_MIN, math.min(CFG.PROBE_MAX, r))
end

-- The clear heading nearest `want` (a unit vector), sweeping `reach` along each; the side last chosen goes first.
local function clearHeading(n, ship, here, want, reach, ignore)
    local right = norm({ X = -want.Y, Y = want.X, Z = 0 }) or { X = 0, Y = 1, Z = 0 }
    local up = cross(right, want)
    local tries = {}
    for i, a in ipairs(AROUND) do tries[i] = a end
    if n.side then
        table.sort(tries, function(a, b)
            local sa, sb = a.f + ((a.side * n.side > 0) and 0.15 or 0), b.f + ((b.side * n.side > 0) and 0.15 or 0)
            return sa > sb
        end)
    end
    for _, a in ipairs(tries) do
        local d = { X = want.X * a.f + right.X * a.r + up.X * a.u, Y = want.Y * a.f + right.Y * a.r + up.Y * a.u,
            Z = want.Z * a.f + right.Z * a.r + up.Z * a.u }
        if not blocked(ship, here, along(here, d, reach), n.radius, ignore) then
            if a.side ~= 0 then n.side = a.side end
            return d
        end
    end
end

-- Where the ship should fly now on its way to `goal`: the goal itself, or a detour / back-off waypoint. Returns
-- (point, acceptance radius, reissue): reissue = the ship's current move is to be issued again even if unchanged.
-- ignore = actors the sweeps pass through (the ship's own, and its target's: attack runs pass close on purpose);
-- watchers = points it can be seen from (your ship, the camera): a ship is only lifted clear well away from all of them
-- (a trailer camera far from your ship once watched a ship blink 25 m up off a station).
function N.steer(c, ship, goal, accept, now, ignore, watchers)
    local n = c.nav
    if not n or n.ship ~= ship:GetAddress() then
        n = { ship = ship:GetAddress(), radius = radiusOf(ship), stucks = 0 }
        c.nav = n
    end
    local here = ship:K2_GetActorLocation()
    local v = ship:GetVelocity()
    local speed = len(v)
    local toGoal = sub(goal, here)
    local gd = len(toGoal)
    if n.goal and X.dist(n.goal, goal) > CFG.NEW_GOAL then n.stucks = 0 end
    n.goal = goal
    local there = gd <= accept + CFG.ARRIVED
    local reissue = false

    -- stuck: barely moving, not there
    if not there and speed < CFG.STUCK_SPEED then
        n.slowSince = n.slowSince or now
    else
        n.slowSince = nil
    end
    if n.slowSince and now - n.slowSince > CFG.STUCK_SECONDS then
        n.slowSince, n.detour = nil, nil
        n.stucks = n.stucks + 1
        stats.stucks = stats.stucks + 1
        local away = n.normal or norm(sub(here, goal)) or { X = 0, Y = 0, Z = 1 }
        away = norm({ X = away.X, Y = away.Y, Z = away.Z + 0.4 }) or away
        local dir = clearHeading(n, ship, here, away, CFG.BACKOFF, ignore) or away
        local unseen = true
        for _, w in ipairs(watchers or {}) do
            if X.dist(here, w) <= CFG.NUDGE_FAR then unseen = false end
        end
        if n.stucks >= CFG.NUDGE_AFTER and unseen then
            pcall(function() ship.CharacterMovement:StopMovementImmediately() end)
            Out.call(ship, "K2_SetActorLocation", along(here, dir, CFG.NUDGE), false, {}, true)
            stats.nudges = stats.nudges + 1
            n.stucks = 0
            X.log(("[shipnav] the %s was stuck again: lifted clear"):format(c.shipName or "?"))
        else
            X.log(("[shipnav] the %s is stuck (%d): backing off"):format(c.shipName or "?", n.stucks))
        end
        n.back = { at = along(here, dir, CFG.BACKOFF), untilT = now + CFG.BACKOFF_SECONDS }
        n.normal = nil
        return n.back.at, 600, true
    end
    if n.back then
        if now < n.back.untilT and X.dist(here, n.back.at) > CFG.DETOUR_REACHED then return n.back.at, 600, false end
        n.back = nil
        reissue = true
    end

    -- drifting: flying away from the goal for a while on a move that's ours
    if not n.detour and not there and speed > CFG.STUCK_SPEED and dot(v, toGoal) < -0.5 * speed * gd then
        n.awaySince = n.awaySince or now
        if now - n.awaySince > CFG.DRIFT_SECONDS then
            n.awaySince = nil
            stats.drifts = stats.drifts + 1
            reissue = true
            X.log(("[shipnav] the %s was flying away from where it's going: move issued again"):format(c.shipName or "?"))
        end
    else
        n.awaySince = nil
    end

    -- detour under way
    if n.detour then
        if now < n.detour.untilT and X.dist(here, n.detour.at) > CFG.DETOUR_REACHED then return n.detour.at, 600, false end
        n.detour = nil
        reissue = true
    end

    -- anything in the way?
    if gd > accept + CFG.GOAL_CLEAR and now >= (n.checkAt or 0) then
        n.checkAt = now + CFG.CHECK_EVERY
        local want = { X = toGoal.X / gd, Y = toGoal.Y / gd, Z = toGoal.Z / gd }
        local reach = math.min(CFG.LOOK_AHEAD + speed * CFG.LOOK_SECONDS, gd - CFG.GOAL_CLEAR)
        local hit, h = blocked(ship, here, along(here, want, reach), n.radius, ignore)
        if hit then
            local nn = h and h.ImpactNormal and norm(h.ImpactNormal)
            if nn then n.normal = nn end
            local dir = clearHeading(n, ship, here, want, CFG.DETOUR, ignore)
            if dir then
                n.detour = { at = along(here, dir, CFG.DETOUR), untilT = now + CFG.DETOUR_SECONDS }
                stats.detours = stats.detours + 1
                return n.detour.at, 600, true
            end
        else
            n.side = nil -- clear again: no side preferred next time
        end
    end
    return goal, accept, reissue
end

-- Whether a sphere of `radius` at `at` is empty (no rock, wreck or hull in it): where to spawn ships. `ctx` is any actor
-- in the world (the trace's world context; it is left out of the test itself).
function N.clearAt(ctx, at, radius)
    return not blocked(ctx, at, { X = at.X, Y = at.Y, Z = at.Z + 10 }, radius, {})
end

-- A ship that should hold still: its momentum gone too (StopMovement alone leaves it drifting on, in a straight line).
function N.halt(c)
    if c.nav then c.nav.detour, c.nav.back, c.nav.slowSince = nil, nil, nil end
    pcall(function() c.shipCtrl:StopMovement() end)
    pcall(function() c.ship.CharacterMovement:StopMovementImmediately() end)
end

function N.report()
    return ("detours %d, stuck %d, lifted %d, drift %d"):format(stats.detours, stats.stucks, stats.nudges, stats.drifts)
end

function N.reset() stats = { detours = 0, stucks = 0, nudges = 0, drifts = 0 } end

function N.init(ctx) X = ctx end

return N
