-- Your crew: AI stand-ins for the teammates co-op would have brought. They are rival-style people (rivals.lua's members,
-- bodies and kits) on your team: they follow you on foot (ship interior, stations, land raids), fight whatever you fight
-- through the director's soldier AI (faction "player", your team number, so neither side can hurt the other), and one
-- of them, the gunner, works your ship's turrets while you fly it.
--
-- Who they are is hire.lua's: the crewmates you hired and paid for this raid (set looks, voices, levels). Each raid they
-- get a fresh kit of their level's tier; one who dies is gone for good. Bodies only exist while you're on foot somewhere
-- with a navmesh; the gunner has no body while you fly (it's at the turret), and is back at your side when you leave
-- the helm. Each wears a nametag (C.tags) so you can tell them from rivals.
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local C = {}
local X -- context from main.lua

-- Destroy an actor that may already be gone (killed, or its level unloaded mid-travel): a failed call no longer aborts
-- the rest of the update.
local function destroy(a)
    if a and X.valid(a) then pcall(function() a:K2_DestroyActor() end) end
end

local CFG = {
    FOLLOW_NEAR = 350,              -- a follower closer than this (+ SPACING per place in line) stays put
    SPACING = 150,
    RUN_AT = 1100,                  -- farther than this from you: they run
    REJOIN = 5000,                  -- farther than this (you docked, breached, dropped in): they catch up out of sight
    REJOIN_AWAY = 600,              -- ...arriving this close to you
    STUCK_SECONDS = 4,              -- a follower who hasn't moved STUCK_MOVE for this long while far behind you...
    STUCK_SEEN_SECONDS = 12,        -- ...catches up out of your sight (or after this long, seen or not)
    STUCK_MOVE = 150,
    STUCK_SLACK = 400,              -- "far behind" = this much past their follow distance
    TRANSIT_GRACE = 15,             -- seconds "nowhere" on foot (an airlock transfer) before their bodies are put away
    LOCK_BRING = 1500,              -- you're in a station airlock and they're this far off (still aboard): they come along
    LEASH = 2800,                   -- a fight this far from you is dropped and they come back
    SPAWN_DELAY = 3,                -- seconds on foot (or after arriving somewhere new) before they join you
    BREACH_RECENT = 15,             -- a pod breach this many seconds old: they follow you in through your hole...
    BREACH_FIRST = 1.5,             -- ...the first this long after you
    BREACH_STAGGER = 1.2,           -- ...and the rest one after another
    GUN_REACT = { 0.8, 1.8 },       -- the gunner's reaction to a new target
    -- The gunner's gunnery skill (0 = green, 1 = crack; what it does: rivals.lua GUN_* settings) by their level now, so
    -- a promotion shows on the guns: level 1 and level 5, straight line between. Plus their own talent: the lifelong
    -- aim roll (hire.lua aimRoll, -0.4..0.4, below 0 better) x GUN_TALENT.
    GUN_SKILL = { 0.2, 0.9 },
    GUN_TALENT = 0.25,
    GUN_LOOK = 0.4,                 -- seconds between target picks
    HELD_SAY = 3,                   -- seconds the gunner can't bear on a target (range / arc) before saying so
    -- Left click at the helm points the gunner at a ship (any crew, hostile or not) or a stationary turret: the one
    -- nearest the middle of your view within ORDER_CONE deg, else the nearest, within ORDER_RANGE. They keep on it until
    -- it's gone, docks, is a wreck, derelict or destroyed, or is beyond ORDER_RANGE; click with nothing in range and they
    -- go back to whatever's after you (ships attacking you, turrets aiming at you).
    ORDER_RANGE = 30000,
    ORDER_CONE = 25,
    FIRE_KEY = "LeftMouseButton",
    TAG_HEIGHT = 115,               -- nametag this far above a crewmate's middle
    TAG_FAR = 6000,                 -- not drawn beyond this (cm)
}
C.CFG = CFG

local roster = {}  -- this raid's crewmates (members in rivals.lua's form)
local people = {}  -- the same person's member table from raid to raid, by hire id (keeps their look meshes)
local S            -- this raid: { key, entries, building, ... }

local function valid(o) return X.valid(o) end
local function dist(a, b) return X.dist(a, b) end
local function rnd(r) return r[1] + math.random() * (r[2] - r[1]) end

local function say(msg)
    X.log("[crew] " .. msg)
    pcall(function() S.pc:ClientMessage(msg, FName("Event"), 5.0) end)
end

-- The paid crewmates as rivals.lua members: their own look, voice and personality; armour and kit rolled from their
-- level's tier; full health.
local function muster()
    roster = {}
    local RC = X.rivals.CFG
    for i, r in ipairs(X.hire.raidCrew()) do
        local m = people[r.id] or { look = {} }
        people[r.id] = m
        m.id, m.name, m.female, m.level, m.place = r.id, r.name, r.female, r.level, i
        m.voice = X.hire.voice(r)
        m.headPath, m.bodyPath, m.personality = r.head, r.body, r.personality
        -- their own kit, as they stand in the lobby (fresh ammo and meds each raid)
        local k = r.kit
        m.kit = { gun = k.gun, helmet = k.helmet, chest = k.chest, bag = k.bag,
            stacks = math.random(RC.AMMO_STACKS[1], RC.AMMO_STACKS[2]), meds = math.random(RC.MEDS[1], RC.MEDS[2]) }
        m.helmet, m.chest, m.backpack = k.helmet ~= nil, k.chest ~= nil, k.bag ~= nil
        m.tier = { name = r.kitTier or "?" }
        for _, t in ipairs(RC.TIERS) do if t.name == r.kitTier then m.tier = t end end
        m.maxHp = X.hire.maxHp(r.level)
        m.crew, m.hp, m.alive, m.entry, m.building = 0, m.maxHp, true, nil, false
        m.gunner, m.aimRoll = r.gunner, r.aimRoll
        roster[i] = m
    end
end

-- How well this crewmate works the guns, from their level and talent (CFG.GUN_SKILL, GUN_TALENT).
local function gunnery(m)
    local t = (math.max(1, math.min(5, m.level or 1)) - 1) / 4
    local skill = CFG.GUN_SKILL[1] + (CFG.GUN_SKILL[2] - CFG.GUN_SKILL[1]) * t - (m.aimRoll or 0) * CFG.GUN_TALENT
    return math.max(0, math.min(1, skill))
end
C.gunnery = gunnery

local function onFoot()
    local foot = X.raid().target
    if not valid(foot) then foot = X.raid().pawn end
    if not (valid(foot) and (foot.Health or 0) > 0) then return nil end
    return foot
end

local function flying()
    local ship = X.rivals.playerShip()
    local pawn = S.pc and S.pc.Pawn
    return ship and valid(pawn) and pawn:GetAddress() == ship:GetAddress()
end

local function reachable(near, radius, minD)
    local out = {}
    for _ = 1, 6 do
        if Out.call(X.navLib(), "K2_GetRandomReachablePointInRadius", S.pc, near, out, radius, X.navMesh(), X.queryFilter())
            and out.X and not X.offLimits(out) and dist(out, near) >= (minD or 0) then
            return { X = out.X, Y = out.Y, Z = out.Z }
        end
    end
end

-- Where a follower stands: behind you, staggered by their place in line.
local function slotFor(e, foot)
    local l, f = foot:K2_GetActorLocation(), foot:GetActorForwardVector()
    local back = CFG.FOLLOW_NEAR * 0.6 + CFG.SPACING * e.crewmate.place
    local side = (e.crewmate.place % 2 == 0 and 1 or -1) * 120
    local want = { X = l.X - f.X * back - f.Y * side, Y = l.Y - f.Y * back + f.X * side, Z = l.Z }
    local out = {}
    if Out.call(X.navLib(), "K2_ProjectPointToNavigation", S.pc, want, out, X.navMesh(), X.queryFilter(),
        { X = 200, Y = 200, Z = 400 }) and out.X then return out end
    return reachable(l, 300)
end

-- Called by the director's soldier AI instead of patrolling, whenever this crewmate isn't fighting.
local function follow(e)
    local foot = onFoot()
    if not foot then e.followRun = false return end
    if e.ctrl.BrainComponent:IsRunning() then e.ctrl.BrainComponent:StopLogic("follow") end
    local l, here = foot:K2_GetActorLocation(), e.bot:K2_GetActorLocation()
    local d = dist(l, here)
    local near = CFG.FOLLOW_NEAR + CFG.SPACING * e.crewmate.place
    local now = os.clock()
    if d < near then
        e.followRun = false
        if e.ctrl:GetMoveStatus() == 3 and dist(l, e.followTo or here) > near then e.ctrl:StopMovement() end
        -- face where you face, roughly, once stopped
        if e.ctrl:GetMoveStatus() ~= 3 then pcall(function() e.ctrl:K2_ClearFocus() end) end
        return
    end
    e.followRun = d > CFG.RUN_AT
    -- re-issue only when you've moved on from where they're headed, at most twice a second
    if now < (e.nextFollow or 0) then return end
    if e.ctrl:GetMoveStatus() == 3 and e.followTo and dist(e.followTo, l) < near then return end
    e.nextFollow = now + 0.5
    local to = slotFor(e, foot)
    if to then
        e.followTo = to
        e.ctrl:MoveToLocation(to, 60, false, true, false, true, X.queryFilter(), true)
    end
end

-- You and your crew walk through each other (testers: they body-blocked doorways and corridors). Each capsule ignores
-- the other when moving (PrimitiveComponent:IgnoreActorWhenMoving), both ways; enemies still bump into both of you,
-- and shots are unaffected (they don't use the capsule's movement sweep).
local function passThrough(e)
    local foot = onFoot()
    if not (foot and valid(e.bot)) then return end
    e.bot.CapsuleComponent:IgnoreActorWhenMoving(foot, true)
    foot.CapsuleComponent:IgnoreActorWhenMoving(e.bot, true)
end

local function startBody(m, at)
    local b = X.rivals.startBody(S.pc, m, at)
    if b then S.building[#S.building + 1] = b end
    m.building = b ~= nil
end

local function finishBuilding()
    for i = #S.building, 1, -1 do
        local b = S.building[i]
        local ok, e = pcall(X.rivals.finishBody, b)
        if not ok or e == false then
            if not ok then X.log("[crew] body failed: " .. tostring(e)) end
            table.remove(S.building, i)
            b.m.building = false
        elseif e then
            table.remove(S.building, i)
            local m = b.m
            m.building = false
            if S.wantBodies then
                e.ctrl.TeamNumber = X.playerTeam
                e.faction = "player"
                e.rival = nil -- rivals.lua and the mission counter must not take them for rivals
                e.crewmate = m
                e.follow = follow
                -- their level's senses, reaction and aim, and their own lifelong aim
                e.mind.profile = X.hire.profile(m.level)
                e.aimRoll = m.aimRoll
                X.AI.tuneBody(e)
                e.home = e.bot:K2_GetActorLocation()
                pcall(passThrough, e)
                m.entry = e
                table.insert(X.raid().bots, e)
                X.log(("[crew] %s (level %d, %s kit, %s, %d hp, %s) is with you"):format(m.name, m.level, m.tier.name,
                    m.gunName or "no gun", m.hp, m.personality or "?"))
                if not S.greeted then S.greeted = true pcall(X.voice.say, e, "HoldPosition") end
            else
                destroy(e.bot)
            end
        end
    end
end

local function bodyOf(m)
    local e = m.entry
    if e and valid(e.bot) and (e.bot.Health or 0) > 0 then return e end
    if e then
        m.entry = nil
        if m.alive and (e.dead or not valid(e.bot) or (e.bot.Health or 0) <= 0) then
            m.alive = false
            say(m.name .. " is down")
            pcall(X.hire.died, m.id)
        end
    end
    return nil
end

local function removeBody(m)
    local e = m.entry
    if not e then return end
    m.entry = nil
    local bots = X.raid().bots
    for i = #bots, 1, -1 do if bots[i] == e then table.remove(bots, i) end end
    if valid(e.bot) and (e.bot.Health or 0) > 0 then
        m.hp = e.bot.Health
        destroy(e.bot)
    end
    -- (out of the list, reapDead no longer drops these: a soldier fighting this crewmate still holds the entry)
    e.bot, e.ctrl, e.hand, e.mesh, e.move = nil, nil, nil, nil, nil
    e.fighting, e.inCombat, e.cover, e.investigate, e.foeEntry = false, false, nil, nil, nil
end

-- Anyone fighting you nearby (boarders come for you, not for them): the nearest is this crewmate's fight.
local function defend(e, foot)
    local here, l = e.bot:K2_GetActorLocation(), foot:K2_GetActorLocation()
    local best, bd
    for _, o in ipairs(X.raid().bots) do
        if o.faction ~= "player" and valid(o.bot) and (o.bot.Health or 0) > 0 and X.onPlayer(o) then
            local at = o.bot:K2_GetActorLocation()
            local d = dist(here, at)
            if dist(l, at) < CFG.LEASH and (not bd or d < bd) then best, bd = o, d end
        end
    end
    if not best then return end
    X.engage(e, best.bot, best)
    e.lastSeen = best.bot:K2_GetActorLocation()
    pcall(X.voice.say, e, "EnemySpotted")
    X.log(("[crew] %s goes for %s, who is fighting you"):format(e.crewmate.name,
        best.rival and best.rival.name or "a soldier"))
end

-- Where a crewmate comes in after your breach: the floor where you landed (breach points sit ~5 m up the hull wall, and
-- the floor nearest the hole itself can be the deck above yours), else by your hole, else by the nearest other breach
-- point (the interior's navmesh may not cover yours), else the hole itself.
local function breachSpot(foot)
    local at = reachable(foot:K2_GetActorLocation(), 300) or reachable(S.breachIn, 250) or reachable(S.breachIn, 800)
    if at then return at end
    local best, bd
    for _, p in ipairs(S.breach.spots or {}) do
        local d = dist(p, S.breachIn)
        if not bd or d < bd then best, bd = p, d end
    end
    return best and (reachable(best, 250) or best) or { X = S.breachIn.X, Y = S.breachIn.Y, Z = S.breachIn.Z }
end

-- Off somewhere you aren't (you docked, breached a ship, dropped in): they catch up out of sight.
local function rejoin(e, foot)
    local to = reachable(foot:K2_GetActorLocation(), CFG.REJOIN_AWAY, 200)
    if not to then return false end
    e.inCombat, e.foeEntry, e.cover, e.investigate = false, nil, nil, nil
    pcall(function() e.ctrl:StopMovement() end)
    e.bot:K2_TeleportTo({ X = to.X, Y = to.Y, Z = to.Z + 100 }, foot:K2_GetActorRotation())
    e.followTo = nil
    return true
end

-- Left behind: a follower who hasn't moved for a while although you're well ahead (an airlock cycled shut between you,
-- or any gap the navmesh doesn't bridge: airlock chambers aren't on it at all, so nobody can path through one) catches
-- up out of your sight. Not while you stand in a chamber yourself: the floor nearest you could then be on either side
-- of its doors. Once you step out, the one left behind comes through at once.
local function cutOff(e, foot, d, now)
    local here = e.bot:K2_GetActorLocation()
    if d > CFG.REJOIN then return end -- rejoin's case
    if d < CFG.FOLLOW_NEAR + CFG.SPACING * e.crewmate.place + CFG.STUCK_SLACK
        or not e.stuckPos or dist(here, e.stuckPos) > CFG.STUCK_MOVE then
        e.stuckPos, e.stuckSince = here, now
        return
    end
    local waited = now - e.stuckSince
    if waited < CFG.STUCK_SECONDS then return end
    if X.rivals.inAirlock(foot:K2_GetActorLocation(), 50) then return end
    local seen = S.pc:LineOfSightTo(e.bot, { X = 0, Y = 0, Z = 0 }, false)
    if seen and waited < CFG.STUCK_SEEN_SECONDS then return end
    e.stuckPos, e.stuckSince = nil, nil -- tried: wait the full time again before the next try
    if rejoin(e, foot) then
        X.log(("[crew] %s was left behind %.0f m back (%.0f s without getting anywhere): caught up"):format(
            e.crewmate.name, d / 100, waited))
    end
end

-- You went through an airlock and they're still on the other side (aboard your ship): they come through with you,
-- standing behind you in the chamber (the ship side, away from the station door's button), so they walk out with you.
local function bringIn(e, foot, lock)
    local b, l = lock.box, foot:K2_GetActorLocation()
    local dx, dy = lock.floor.X - lock.btn.X, lock.floor.Y - lock.btn.Y
    local n = math.max(1, math.sqrt(dx * dx + dy * dy))
    dx, dy = dx / n, dy / n
    local back = 90 + 70 * (e.crewmate.place - 1)
    local side = (e.crewmate.place % 2 == 0 and 1 or -1) * 45
    local x, y = l.X + dx * back - dy * side, l.Y + dy * back + dx * side
    if b then -- keep inside the chamber's box (it turns with the airlock)
        local r = math.rad(-(b.yaw or 0))
        local ox, oy = x - b.c.X, y - b.c.Y
        local lx, ly = ox * math.cos(r) - oy * math.sin(r), ox * math.sin(r) + oy * math.cos(r)
        local mx, my = math.max(0, b.e.X - 45), math.max(0, b.e.Y - 45)
        lx, ly = math.max(-mx, math.min(mx, lx)), math.max(-my, math.min(my, ly))
        local c, sn = math.cos(-r), math.sin(-r)
        x, y = b.c.X + lx * c - ly * sn, b.c.Y + lx * sn + ly * c
    end
    e.inCombat, e.foeEntry, e.cover, e.investigate = false, nil, nil, nil
    pcall(function() e.ctrl:StopMovement() end)
    e.bot:K2_TeleportTo({ X = x, Y = y, Z = lock.floor.Z + 100 }, foot:K2_GetActorRotation())
    e.followTo, e.stuckPos, e.stuckSince = nil, nil, nil
    return true
end

local function updateBodies(now)
    local foot = onFoot()
    local fly = flying()
    -- Bodies need you on foot (or at the helm: your character stands there) where there's a navmesh to walk.
    local where = X.raid().space and X.rivals.where() or "land"
    -- Between places on foot (mid airlock transfer): the bodies you have stay, they aren't put away and rebuilt.
    if where ~= nil then S.placeAt = now end
    -- Back aboard your ship from a station's airlock: whoever is still over there comes back with you.
    if where == "ship" and S.lastWhere ~= "ship" then S.boardedAt = now end
    S.lastWhere = where or S.lastWhere
    local transit = foot ~= nil and where == nil and S.placeAt ~= nil and now - S.placeAt < CFG.TRANSIT_GRACE
    local wantAny = foot ~= nil and (where ~= nil or transit)
    if wantAny and not S.wantBodies then S.wantBodies, S.joinAt, S.breachIn = true, now + CFG.SPAWN_DELAY, nil end
    if not wantAny then S.wantBodies = false end
    -- You just cut into a ship from a pod: they were in the pod with you, so they come in through your hole. Keyed on the
    -- breach itself: a short pod flight can start and end between two updates, so "you were nowhere" is never seen.
    local b = X.rivals.lastBreach()
    if wantAny and where == "rival" and b and b.time ~= S.breachSeen and now - b.time < CFG.BREACH_RECENT then
        S.breachSeen = b.time
        for _, m in ipairs(roster) do removeBody(m) end
        S.breachIn, S.breach, S.breachShip, S.joinAt = b.at, b, b.ship, b.time + CFG.BREACH_FIRST
    end
    for _, m in ipairs(roster) do
        local e = bodyOf(m)
        local want = S.wantBodies and m.alive and not (m.gunner and fly)
        local inAt = S.breachIn and S.joinAt + (m.place - 1) * CFG.BREACH_STAGGER
        if e and not want then
            removeBody(m)
            if m.gunner and fly and not S.gunnerSaid then
                S.gunnerSaid = true
                say(m.name .. " is on the guns")
            end
        elseif e then
            local d = dist(e.bot:K2_GetActorLocation(), foot:K2_GetActorLocation())
            local cycling = X.rivals.inAirlock(foot:K2_GetActorLocation(), 50) -- off the navmesh: wait till you're out
            if cycling and d > CFG.LOCK_BRING and not e.inCombat and cycling.box then
                if bringIn(e, foot, cycling) then
                    X.log(("[crew] %s came through the airlock with you (was %.0f m off)"):format(m.name, d / 100))
                end
            elseif where == "ship" and S.boardedAt and now - S.boardedAt < 3 and d > CFG.LOCK_BRING
                and not e.inCombat then
                if rejoin(e, foot) then
                    X.log(("[crew] %s came back aboard with you (was %.0f m off)"):format(m.name, d / 100))
                end
            elseif d > CFG.REJOIN then if not cycling then rejoin(e, foot) end
            elseif e.inCombat and d > CFG.LEASH then
                e.inCombat, e.foeEntry = false, nil -- too far from you: back to following
            elseif not e.inCombat and now >= (e.nextDefend or 0) then
                e.nextDefend = now + 0.5
                defend(e, foot)
            end
            if e.inCombat then e.stuckPos = nil else cutOff(e, foot, d, now) end
            -- out of sight in a fight: they still know where it is (you're calling it out), so they close in on it
            if e.inCombat and not e.los and e.foeEntry and e.foeEntry.bot and valid(e.foeEntry.bot)
                and now >= (e.nextTrack or 0) then
                e.nextTrack = now + 2
                e.lastSeen = e.foeEntry.bot:K2_GetActorLocation()
            end
            if valid(e.ctrl) and e.ctrl.TeamNumber ~= X.playerTeam then
                X.log(("[crew] %s was put on team %d, back on yours"):format(m.name, e.ctrl.TeamNumber))
                e.ctrl.TeamNumber = X.playerTeam
            end
            pcall(X.rivals.holdGun, e)
        elseif want and not m.building and now >= (inAt or S.joinAt or 0) then
            -- after a breach: through your hole, behind you; otherwise somewhere near you, out of the way
            local at = S.breachIn and breachSpot(foot)
                or reachable(foot:K2_GetActorLocation(), CFG.REJOIN_AWAY, 200)
            if at then
                startBody(m, at)
                if S.breachIn and m.place == 1 then say(("Your crew follows you into the %s"):format(S.breachShip or "ship")) end
            end
        end
    end
    finishBuilding()
    -- a body needed later (the gunner leaving a helm) joins you the usual way, not back at the hole
    if S.breachIn and now > S.joinAt + 4 * CFG.BREACH_STAGGER + 10 then S.breachIn = nil end
end

-- While the gunner works the turrets they are the gunner's, not yours. The helm's fire (RaidFrigate::ServerFireFrigate)
-- also fires the hull's first turret whenever its ControllerHere is empty, i.e. nobody sits at it; online the gunner's
-- seat filled it. So the gunner's turrets get your controller there (it only marks them manned: your view stays put),
-- and get it back off once the gunner stops, except a turret you're sitting at yourself (gunseat.lua). The helm also
-- swings the turrets to your view: the gunner takes their barrels too (rivals.aimTurrets), so they point where the
-- gunner aims and the shells leave along them.
local function holdTurrets()
    pcall(X.rivals.aimTurrets, S.turrets, true)
    S.aimed = S.turrets
    S.held = S.held or {}
    for _, e in ipairs(S.turrets) do
        local t = e.actor
        if valid(t) then
            local free = true
            pcall(function() free = not (t.ControllerHere and t.ControllerHere:IsValid()) end)
            if free then
                t.ControllerHere = S.pc
                table.insert(S.held, t)
            end
        end
    end
end

local function releaseTurrets()
    if S and S.aimed then
        pcall(X.rivals.aimTurrets, S.aimed, false)
        S.aimed = nil
    end
    if not S or not S.held then return end
    local seat = X.gunseat and X.gunseat.seated()
    for _, t in ipairs(S.held) do
        if valid(t) and not (seat and seat:GetAddress() == t:GetAddress()) then
            pcall(function()
                local c = t.ControllerHere
                if c and c:IsValid() and valid(S.pc) and c:GetAddress() == S.pc:GetAddress() then t.ControllerHere = nil end
            end)
        end
    end
    S.held = nil
end

-- Left click while you fly (no menu open): who the gunner should shoot. Bridge test: bridge/gunner_click = one click.
local TEST_CLICK = require("pveproject") .. "bridge/gunner_click"
local function clicked()
    local down = false
    pcall(function() down = not S.pc.bShowMouseCursor and S.pc:IsInputKeyDown({ KeyName = FName(CFG.FIRE_KEY) }) end)
    -- (the test file is looked for twice a second, not every frame: this runs each frame you fly with a gunner)
    local now = os.clock()
    if now >= (S.testClickAt or 0) then
        S.testClickAt = now + 0.5
        local f = io.open(TEST_CLICK, "r")
        if f then f:close() os.remove(TEST_CLICK) return true end
    end
    local was = S.fireDown
    S.fireDown = down
    return down and not was
end

local function orderTarget(m, now)
    local ok, pick = pcall(X.rivals.pickShip, CFG.ORDER_RANGE, CFG.ORDER_CONE)
    if not ok then X.log("[crew] gunner pick failed: " .. tostring(pick)) return end
    if not pick then
        if S.order then say(m.name .. ": back on whoever's after us") end
        S.order = nil
        S.nextLook = 0
        return
    end
    -- clicking again on the ship they're already shooting changes nothing (it restarted their reaction: no shots
    -- at all while you kept clicking)
    local same = valid(S.gunTarget) and S.gunTarget:GetAddress() == pick.ship:GetAddress()
    S.order = pick
    if same then return end
    S.gunTarget, S.gunReady, S.nextLook = pick.ship, now + rnd(CFG.GUN_REACT), now + CFG.GUN_LOOK
    if not S.calledTarget or now - S.calledTarget > 2 or S.calledShip ~= pick.ship:GetAddress() then
        say(("%s: on the %s"):format(m.name, pick.name))
    end
    S.calledTarget, S.calledShip = now, pick.ship:GetAddress()
    X.log(("[crew] gunner ordered onto %s (%.0f m, %s)"):format(pick.name, pick.d / 100,
        pick.centred and "in your sights" or "nearest"))
end

-- Out of range, or no turret can swing onto it: after HELD_SAY s on the same target, the gunner says so once (the
-- status line only counted it). gunnerFire leaves the reason in S.gun.held.
local HELD_LINES = { range = "%s: the %s is too far, close in", arc = "%s: can't swing onto the %s, turn us toward it" }
local function heldCall(m, now)
    local why = S.gun and S.gun.held
    if not (why and valid(S.gunTarget)) then S.heldWhy = nil return end
    local key = S.gunTarget:GetAddress()
    if S.heldKey ~= key or S.heldWhy ~= why then
        S.heldKey, S.heldWhy, S.heldSince = key, why, now
    elseif now - S.heldSince >= CFG.HELD_SAY and S.heldSaid ~= key .. why then
        S.heldSaid = key .. why
        local name = S.order and valid(S.order.ship) and S.order.ship:GetAddress() == key and S.order.name or S.autoName or "target"
        say(HELD_LINES[why]:format(m.name, name))
    end
end

-- The gunner: picks the nearest ship that's attacking you (or that you're shooting at) once in a while, and after a
-- moment's reaction fires every turret whose arc covers it. A ship you click on (orderTarget) comes first.
function C.frame()
    if not S or not X.raid().space then return end
    local m
    for _, o in ipairs(roster) do if o.gunner and o.alive then m = o end end
    if not m or not flying() then
        S.gunTarget, S.order, S.fireDown = nil, nil, nil
        releaseTurrets()
        return
    end
    local ship = X.rivals.playerShip()
    if not ship or (ship.MainHullHealth or 0) <= 0 then releaseTurrets() return end
    local now = os.clock()
    -- the turrets, found again for a new hull (ownHull swaps it) and retried while there are none yet
    if not S.turrets or S.turretShip ~= ship:GetAddress() or (S.turrets[1] and not valid(S.turrets[1].actor))
        or (#S.turrets == 0 and now >= (S.turretRetry or 0)) then
        releaseTurrets() -- the old hull's
        local ok, t = pcall(X.rivals.shipTurrets, ship)
        S.turrets, S.turretShip, S.turretRetry = ok and t or {}, ship:GetAddress(), now + 5
        if #S.turrets > 0 or not S.noTurretSaid then
            S.noTurretSaid = true
            X.log(("[crew] %s mans %d turret(s), gunnery %.2f%s"):format(m.name, #S.turrets, gunnery(m),
                ok and "" or (": " .. tostring(t))))
        end
    end
    if #S.turrets == 0 then return end
    holdTurrets()
    if clicked() then orderTarget(m, now) end
    if S.order and not X.rivals.shipInPlay(S.order, CFG.ORDER_RANGE) then
        X.log("[crew] gunner's ordered target out of play: " .. tostring(S.order.name))
        S.order, S.nextLook = nil, 0
    end
    if S.order then
        if not valid(S.gunTarget) or S.gunTarget:GetAddress() ~= S.order.ship:GetAddress() then
            S.gunTarget, S.gunReady = S.order.ship, now + rnd(CFG.GUN_REACT)
        end
    elseif now >= (S.nextLook or 0) then
        S.nextLook = now + CFG.GUN_LOOK
        local list = X.rivals.hostileShips()
        local pick = list[1] and list[1].ship
        if pick and (not valid(S.gunTarget) or S.gunTarget:GetAddress() ~= pick:GetAddress()) then
            S.gunTarget, S.gunReady, S.autoName = pick, now + rnd(CFG.GUN_REACT), list[1].name
            if not S.calledTarget or now - S.calledTarget > 20 then
                S.calledTarget = now
                say(("%s: engaging the %s"):format(m.name, list[1].name))
            end
        elseif not pick then
            S.gunTarget = nil
        end
    end
    if valid(S.gunTarget) and now >= (S.gunReady or 0) then
        -- their aim on the target lasts between volleys (S.gun.aim); the skill is read live (tuning menu, promotions)
        S.gun = S.gun or {}
        S.gun.gunnery = gunnery(m)
        local ok, err = pcall(X.rivals.gunnerFire, S.turrets, S.gunTarget, now, S.gun)
        if not ok and not S.gunErr then S.gunErr = true X.log("[crew] gunner failed: " .. tostring(err)) end
        if ok and err and S.order and S.orderFired ~= S.order then
            S.orderFired = S.order
            X.log("[crew] gunner firing on the ordered " .. tostring(S.order.name))
        end
        if ok then heldCall(m, now) end
    elseif not valid(S.gunTarget) then
        pcall(X.rivals.restTurrets, S.turrets)
    end
end

-- Nametags: a name, level and health bar over each crewmate, projected onto the screen every frame (plain widgets, like
-- the minimap's).
local TAG_HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local GREEN = { R = 0.55, G = 1, B = 0.6, A = 1 }
local function buildTags(pc)
    local lib = X.lib
    local cls = lib(TAG_HOST)
    if not valid(cls) then pcall(LoadAsset, (TAG_HOST:match("^[^.]+"))) cls = lib(TAG_HOST) end
    if not valid(cls) then return nil end
    local host = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(host) then return nil end
    local T = { host = host, root = host.WidgetTree.RootWidget, rows = {} }
    T.root:ClearChildren()
    local function make(c) return StaticConstructObject(lib("/Script/UMG." .. c), host.WidgetTree) end
    for i = 1, 4 do
        local t = make("TextBlock")
        t.Font.Size = 13
        -- (SetColorAndOpacity with a table left the text dark: the struct is written field by field instead)
        pcall(function()
            local c = t.ColorAndOpacity.SpecifiedColor
            c.R, c.G, c.B, c.A = GREEN.R, GREEN.G, GREEN.B, 1
            t.ColorAndOpacity.ColorUseRule = 0
        end)
        pcall(function() t:SetShadowOffset({ X = 1, Y = 1 }) end)
        pcall(function() t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 }) end)
        local ts = T.root:AddChildToCanvas(t)
        ts:SetAutoSize(true)
        ts:SetAlignment({ X = 0.5, Y = 1 })
        local back = make("Border")
        back:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.6 })
        local bs = T.root:AddChildToCanvas(back)
        local fill = make("Border")
        fill:SetBrushColor(GREEN)
        local fs = T.root:AddChildToCanvas(fill)
        for _, w in ipairs({ t, back, fill }) do w:SetVisibility(1) end
        T.rows[i] = { t = t, ts = ts, back = back, bs = bs, fill = fill, fs = fs, on = false }
    end
    host:AddToViewport(-2)
    return T
end

local function hideTag(row)
    if not row.on then return end
    row.on = false
    for _, w in ipairs({ row.t, row.back, row.fill }) do w:SetVisibility(1) end
end

-- Every frame in a raid.
function C.tags(pc)
    if not S or #roster == 0 then return end
    if not (S.tags and valid(S.tags.host)) then
        if os.clock() < (S.tagRetry or 0) then return end
        S.tagRetry = os.clock() + 5
        S.tags = buildTags(pc)
        if not S.tags then return end
    end
    -- The class default object lives as long as the game: looked up once, not every frame.
    if not valid(S.tags.wll) then S.tags.wll = X.lib("/Script/UMG.Default__WidgetLayoutLibrary") end
    local wll = S.tags.wll
    local cam = pc.PlayerCameraManager
    local eye = valid(cam) and cam:GetCameraLocation()
    for i, row in ipairs(S.tags.rows) do
        local m = roster[i]
        local e = m and m.entry
        local shown = false
        if e and valid(e.bot) and (e.bot.Health or 0) > 0 then
            local l = e.bot:K2_GetActorLocation()
            local at = { X = l.X, Y = l.Y, Z = l.Z + CFG.TAG_HEIGHT }
            local d = eye and dist(eye, at) or 0
            local out = {}
            -- ScreenPosition is an out param: through Out.call, or UE4SS keeps a registry ref to `out` every frame
            -- per crewmate (outref.lua).
            if d < CFG.TAG_FAR and Out.call(wll, "ProjectWorldLocationToWidgetPosition", pc, at, out, false) and out.X then
                shown = true
                if not row.on then
                    row.on = true
                    for _, w in ipairs({ row.t, row.back, row.fill }) do w:SetVisibility(4) end -- HitTestInvisible
                end
                if row.name ~= m.name then
                    row.name = m.name
                    row.t:SetText(FText(("%s  Lv %d"):format(m.name, m.level or 1)))
                end
                local hp = math.max(0, math.min(1, e.bot.Health / math.max(1, m.maxHp)))
                local fade = d < 1500 and 1 or math.max(0.45, 1 - (d - 1500) / 9000)
                row.t:SetRenderOpacity(fade)
                row.ts:SetPosition({ X = out.X, Y = out.Y - 6 })
                row.bs:SetPosition({ X = out.X - 30, Y = out.Y - 4 })
                row.bs:SetSize({ X = 60, Y = 4 })
                row.fs:SetPosition({ X = out.X - 30, Y = out.Y - 4 })
                row.fs:SetSize({ X = 60 * hp, Y = 4 })
                if row.hp ~= hp then
                    row.hp = hp
                    row.fill:SetBrushColor(hp > 0.5 and GREEN or hp > 0.25 and { R = 1, G = 0.75, B = 0.2, A = 1 }
                        or { R = 1, G = 0.3, B = 0.25, A = 1 })
                end
            end
        end
        if not shown then hideTag(row) end
    end
end

-- From the director's update (land raids and space maps alike, once the navmesh is ready).
function C.update(pc, worldKey)
    local now = os.clock()
    if not S or S.key ~= worldKey then
        S = { key = worldKey, building = {}, pc = pc }
        muster()
        local names = {}
        for _, m in ipairs(roster) do
            names[#names + 1] = ("%s (level %d%s)"):format(m.name, m.level, m.gunner and ", gunner" or "")
        end
        X.log("[crew] this raid: " .. (#names > 0 and table.concat(names, ", ")
            or "nobody (none hired, unpaid, or crew off)"))
        -- Crewmates you couldn't pay stayed home: said once you can see the screen (the user took it for a bug: crew
        -- alive, set to come along, and nobody there).
        S.unpaidNote, S.unpaidAt = X.hire.unpaidNote(), now + 6
    end
    S.pc = pc
    if S.unpaidNote and now >= S.unpaidAt then
        say(S.unpaidNote)
        S.unpaidNote = nil
    end
    local ok, err = pcall(updateBodies, now)
    if not ok then X.log("[crew] update failed: " .. tostring(err)) end
end

-- Roster for the debug menu / status lines.
function C.status()
    local parts = {}
    for _, m in ipairs(roster) do
        local e = m.entry
        local state = not m.alive and "down" or (m.gunner and S and flying()) and "on the guns"
            or e and (e.inCombat and "fighting" or "following") or "not here"
        parts[#parts + 1] = ("%s: %s"):format(m.name, state)
    end
    return #parts > 0 and table.concat(parts, ", ") or "no crew"
end

-- A new world: the last raid's crewmates, turrets and name tags went with it. C.frame and C.tags run every frame from the
-- first update on, but C.update only rebuilds this once the raid's navmesh is ready, so without this they touched the
-- freed name-tag widget and turrets (IsValid reads the object's memory: a crash on the next raid's load).
function C.reset() S, roster = nil, {} end

function C.init(ctx) X = ctx end

return C
