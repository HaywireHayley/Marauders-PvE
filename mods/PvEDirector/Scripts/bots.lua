-- Soldiers (moved out of main.lua, its sections 2-6): spawning, waking and arming them, factions and foes, parking
-- far-off ones, patrols, noises, cover, combat hints, aim and animation, and station garrisons. main.lua's update()
-- calls updateBots every UPDATE_SECONDS; its onTick calls trackTargets every frame.
local PROJECT = require("pveproject")
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local AI = require("ai")
local Cover = require("cover")
local Voice = require("voice")
local Banter = require("banter") -- begging and taunts (#316)
local Female = require("female")
local M = {}

-- from main.lua (M.init): its settings (the CFG table itself: the tuning menu changes it), helpers and navmesh lookups
local CFG, log, valid, dist, dist2d, rnd, lib, navLib, navMesh, queryFilter, TREE, BOT_TEAM, Aux, Rivals, offLimits
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)

function M.init(ctx)
    CFG, log, valid, dist, dist2d, rnd = ctx.CFG, ctx.log, ctx.valid, ctx.dist, ctx.dist2d, ctx.rnd
    lib, navLib, navMesh, queryFilter = ctx.lib, ctx.navLib, ctx.navMesh, ctx.queryFilter
    TREE, BOT_TEAM, Aux, Rivals, offLimits = ctx.TREE, ctx.BOT_TEAM, ctx.aux, ctx.rivals, ctx.offLimits
    Banter.init({ CFG = CFG, log = log, valid = valid, dist = dist, rivals = Rivals, queryFilter = queryFilter })
end
function M.setRaid(r) raid = r end

-- profile: ai.lua difficulty profile; power: gear power bonus over a scav's for picking a personality
local KINDS = {
    { path = "/Game/Blueprints/Pawns/BotPawn.BotPawn_C", weight = 5, profile = "soldier", power = 0 },
    { path = "/Game/Blueprints/Pawns/BotPawnGuard.BotPawnGuard_C", weight = 2, profile = "guard", power = 45 },
    { path = "/Game/Blueprints/Pawns/BotPawnMilitary.BotPawnMilitary_C", weight = 1, profile = "guard", power = 90 },
}

-- 2. Bots -------------------------------------------------------------------------------------------
local function pickKind()
    local total = 0
    for _, k in ipairs(KINDS) do total = total + k.weight end
    local r = math.random() * total
    for _, k in ipairs(KINDS) do
        r = r - k.weight
        if r <= 0 then return k end
    end
    return KINDS[1]
end

-- Bots spawn asleep; this undoes every part of it. Re-possessing refreshes the controller's
-- PathFollowingComponent, which cached "no movement component" while the bot was asleep.
local function wake(bot, ctrl)
    local P = _G.PVE_PROF
    if P then P.wakes = (P.wakes or 0) + 1 end
    bot.CustomTimeDilation = 1.0
    ctrl.CustomTimeDilation = 1.0
    local move = bot.CharacterMovement
    move:SetComponentTickEnabled(true)
    move:SetComponentTickInterval(0)
    move:SetMovementMode(1, 0) -- walking
    move.MaxWalkSpeedCrouched = 132 -- was 220, the full walk speed: crouch-walking slid
    -- Asleep, the skeleton doesn't update either (tick off, 1 s interval, bNoSkeletonUpdate): the bot can
    -- still deal damage but never visibly turns, aims or animates.
    local mesh = bot.Mesh
    mesh:SetComponentTickEnabled(true)
    mesh:SetComponentTickInterval(0)
    mesh.bNoSkeletonUpdate = false
    mesh.VisibilityBasedAnimTickOption = 1 -- AlwaysTickPose
    mesh.bEnableUpdateRateOptimizations = false -- URO skipped animation frames: choppy, sluggish-looking bots
    mesh:SetVisibility(true, true)
    -- Helmet / backpack / chest gear are separate skeletal meshes on the body. They follow its animation
    -- through the master pose, but are asleep like the body (tick off, bNoSkeletonUpdate), so their drawn
    -- pose never refreshed and helmets floated in the rest pose.
    local gear = bot:K2_GetComponentsByClass(lib("/Script/Engine.SkeletalMeshComponent"))
    for i = 1, #gear do
        local c = gear[i]:get()
        local parent = c:GetAttachParent()
        if c:GetFName():ToString():find("^DecalMesh") then
            -- A hidden second head (always Raider_Head_Skel_01, whatever the bot's real head) for blood decals. The
            -- SetVisibility(true, true) above showed it too: on entering a station every adopted guard grew it over
            -- its own head, poking through helmets (testers: "head meshes messed up when entering a POI").
            -- Hidden in game as well: something later shows the body with propagation again (3 of 12 awake bots had
            -- it back, men and women), and that only sets bVisible, never bHiddenInGame.
            c:SetVisibility(false, false)
            c:SetHiddenInGame(true, false)
        elseif valid(parent) and parent:GetFullName() == mesh:GetFullName() then
            c:SetComponentTickEnabled(true)
            c:SetComponentTickInterval(0)
            c.bNoSkeletonUpdate = false
            c.VisibilityBasedAnimTickOption = 1
            c.bEnableUpdateRateOptimizations = false
            c:SetMasterPoseComponent(mesh, true)
        end
    end
    bot:SetActorHiddenInGame(false)
    bot.bActiveated = true
    ctrl.bActiveated = true
end

-- Shortly after spawning, the bot's own deactivation also unpossesses it and stops its behaviour tree,
-- so arm() runs again from updateBots whenever that has happened (with the controller we kept).
local function arm(bot, ctrl)
    ctrl = ctrl or bot.Controller
    if not valid(ctrl) then return nil end
    wake(bot, ctrl)
    if valid(bot.Controller) then ctrl:UnPossess() end
    ctrl:Possess(bot)
    ctrl.TeamNumber = BOT_TEAM
    -- A bot that spawned asleep never equipped its gun: ShootEnemy then applies damage straight from the
    -- controller with no muzzle flash, sound or tracer. Equipping makes it go through the weapon's fire effects.
    if valid(bot.CurrentWeapon) then bot:ServerEquipWeapon(bot.CurrentWeapon) end
    ctrl:RunBehaviorTree(lib(TREE))
    ctrl.BlackboardComp:SetValueAsBool(FName("IsDeactivated"), false)
    return ctrl
end

local function spawnBot(pc, at, yaw)
    local kind = pickKind()
    local cls = lib(kind.path)
    if not valid(cls) then kind = KINDS[1] cls = lib(kind.path) end
    local bot = lib("/Script/AIModule.Default__AIBlueprintHelperLibrary"):SpawnAIFromClass(pc, cls, lib(TREE),
        { X = at.X, Y = at.Y, Z = at.Z + 100 }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 }, true, pc)
    if not valid(bot) then return nil end
    local ctrl = arm(bot)
    if not ctrl then return nil end
    local personality = AI.pickPersonality(AI.power({}) + kind.power)
    local e = { bot = bot, ctrl = ctrl, home = bot:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(2, 8),
        mind = AI.mind(kind.profile, personality) }
    AI.tuneBody(e)
    local female = math.random() < Rivals.CFG.FEMALE
    e.voice = Voice.pick(female)
    if female then pcall(Female.dress, bot, true) end
    table.insert(raid.bots, e)
    return bot
end

local function botCount()
    if CFG.BOTS > 0 then return CFG.BOTS end
    local gm = FindFirstOf("GameModeBase")
    local n = (gm.NumberNormalAI or 0) + (gm.NumberGuardAI or 0) + (gm.NumberMilitaryAI or 0)
    return n > 0 and n or 8
end

local function spawnRaidBots(pc)
    local player = pc.Pawn:K2_GetActorLocation()
    local nodes = {}
    for _, n in ipairs(FindAllOf("RaidAINodeStart") or {}) do
        local l = n:K2_GetActorLocation()
        if dist(l, player) >= CFG.MIN_SPAWN_DIST then table.insert(nodes, l) end
    end
    if #nodes == 0 then log("no AI nodes far enough from the player") return end
    local want = botCount()
    for i = 1, want do
        local base = nodes[(i - 1) % #nodes + 1]
        -- Several bots per node get spread out a little.
        local a = math.random() * 2 * math.pi
        local at = { X = base.X + math.cos(a) * 150 * math.floor((i - 1) / #nodes),
                     Y = base.Y + math.sin(a) * 150 * math.floor((i - 1) / #nodes), Z = base.Z }
        spawnBot(pc, at, math.random(0, 359))
    end
    log(("spawned %d soldiers at %d AI nodes"):format(#raid.bots, #nodes))
end

-- 3. Awareness --------------------------------------------------------------------------------------
-- The player's character: on space maps the on-foot pawn, which stays at the helm while you fly the ship.
local function targetPawn() return valid(raid.target) and raid.target or raid.pawn end

-- Factions: the station's soldiers, each rival crew (e.faction = "crewN", set by rivals.lua), and you. Every faction
-- is hostile to every other one. A bot's foe is kept as an entry (PLAYER or another bot's entry), never as a pawn:
-- reapDead clears a dead bot's entry.bot, so a foe that died reads as gone instead of a freed object.
local PLAYER = { player = true }
local function factionOf(e) return e.faction or "station" end
-- The rivals' edge over station guards (CFG.EDGE_*): which side of it `mine` is on against `theirs`.
local function edge(mine, theirs)
    if mine == "station" and theirs:sub(1, 4) == "crew" then return "guard" end
    if theirs == "station" and mine:sub(1, 4) == "crew" then return "rival" end
end
local function foeOf(e)
    local f = e.foeEntry
    if f == PLAYER then
        local p = targetPawn()
        return (valid(p) and (p.Health or 0) > 0) and p or nil
    end
    if f and f.bot and not f.dead then return f.bot end
    return nil
end

-- A dead bot's pawn is destroyed ~3 s after its death (pve_bodies) and freed by the next garbage collection, up to
-- a minute later. Its entry used to stay in raid.bots with fighting/cover set from its last fight, and the per-frame
-- peek/hide code kept reading the pawn: once freed, that read crashed inside UE4SS (AV at 0xffffffffffffffff in the
-- UObject __index, walking a garbage class chain; even IsValid reads the object's memory). So each frame, before
-- anything else touches the bots, a dead or destroyed bot's entry drops its object references (other modules see
-- valid(e.bot) == false: rivals marks the member killed) and leaves the list.
local function reapDead()
    for i = #raid.bots, 1, -1 do
        local e = raid.bots[i]
        if not valid(e.bot) or (e.bot.Health or 0) <= 0 then
            e.dead, e.bot, e.ctrl, e.hand, e.mesh, e.move = true, nil, nil, nil, nil, nil
            e.fighting, e.inCombat, e.cover, e.investigate, e.holdUntil = false, false, nil, nil, nil
            table.remove(raid.bots, i)
        elseif e.ctrl and not valid(e.ctrl) then
            e.ctrl = valid(e.bot.Controller) and e.bot.Controller or nil
        end
    end
end


-- Parking far-off bots. Every station you enter adds its guards to raid.bots, and nothing put them back to sleep: after
-- three or four stations, dozens of guards kilometres away still ran their AI every update, sized each other up, and
-- ticked their skeletons and movement every frame (the frame rate fell the longer a raid went on). A guard or soldier
-- at peace (not a rival, not your crew, not fighting, alerted or investigating) farther than CFG.PARK_RANGE from you is
-- frozen: time dilation 0 on body and controller, movement and pose ticks off, and every loop skips it. Back within
-- 85% of that, or hurt, it's unparked: updateBots' own wake() branch (dilation below 1) brings it back as it does a
-- bot the game put to sleep. Returns true while e is parked.
function M.parked(e, at)
    local busy = e.rival or e.crewmate or e.fighting or e.inCombat or e.alert or e.investigate
    local here = e.updAt or e.bot:K2_GetActorLocation()
    if e.parked then
        local hurt = e.hp ~= nil and (e.bot.Health or 0) < e.hp
        if busy or hurt or (CFG.PARK_RANGE or 0) <= 0 or (at and dist(here, at) < CFG.PARK_RANGE * 0.85) then
            e.parked = nil
            raid.unparks = (raid.unparks or 0) + 1
            return false
        end
        return true
    end
    if busy or not at or (CFG.PARK_RANGE or 0) <= 0 or dist(here, at) <= CFG.PARK_RANGE then return false end
    e.parked = true
    e.lastAt = here
    raid.parks = (raid.parks or 0) + 1
    pcall(function()
        e.bot.CustomTimeDilation = 0
        e.ctrl.CustomTimeDilation = 0
        e.bot.CharacterMovement:SetComponentTickEnabled(false)
        e.bot.Mesh:SetComponentTickEnabled(false)
    end)
    return true
end

local function setEnemy(e, pawn)
    local ctrl = e.ctrl
    -- The controller snaps its rotation (and the body, bUseControllerRotationYaw) to its focal point every
    -- tick. Without a gameplay focus it keeps facing a stale point left by the last patrol move.
    ctrl:K2_SetFocus(pawn)
    -- Reaction time (ai.lua profile): facing the target already, but no shooting until it's over
    -- (trackTargets sets the enemy then).
    if e.holdUntil and os.clock() < e.holdUntil then return end
    if e.reloadUntil and os.clock() < e.reloadUntil then return end -- (reloading: no new reaction time cuts it short)
    -- A knife or truncheon only swings once it's in reach (M.meleeHints): with an enemy set the tree swings at any range.
    if M.isMelee(e) and not e.meleeClose then return end
    ctrl.BlackboardComp:SetValueAsObject(FName("Enemy"), pawn)
    ctrl.MyEnemy = pawn
end

-- 4. Patrols ----------------------------------------------------------------------------------------
-- The behaviour tree only acts once it has an Enemy (it ignores the "destination" key and cancels other
-- moves), so idle soldiers have their tree paused and walk between reachable points around home instead.
local releaseCover -- forward (section 6)

local function patrol(e)
    local now = os.clock()
    if e.cover then releaseCover(e) end
    if e.ctrl.BrainComponent:IsRunning() then e.ctrl.BrainComponent:StopLogic("patrol") end
    if now < e.nextPatrol or e.ctrl:GetMoveStatus() == 3 then return end -- 3 = Moving
    local dest = {}
    Out.call(navLib(), "K2_GetRandomReachablePointInRadius", e.ctrl, e.home, dest, e.patrolRadius or CFG.PATROL_RADIUS,
        navMesh(), queryFilter())
    if dest.X and not offLimits(dest) then
        e.ctrl:MoveToLocation(dest, 60, false, true, false, true, queryFilter(), true)
    end
    e.nextPatrol = now + math.random(CFG.PATROL_PAUSE[1], CFG.PATROL_PAUSE[2])
end

local function engage(e, pawn, entry)
    e.foeEntry = entry or PLAYER
    e.inCombat = true
    e.investigate = nil
    e.holdUntil = os.clock() + AI.reactionTime(e)
    e.ctrl:StopMovement()
    if not e.ctrl.BrainComponent:IsRunning() then
        e.ctrl:RunBehaviorTree(lib(TREE))
        e.ctrl.BlackboardComp:SetValueAsBool(FName("IsDeactivated"), false)
    end
    setEnemy(e, pawn)
end

-- In combat is tracked here, not by the blackboard: hiding soldiers have their Enemy key cleared so the
-- tree stops shooting into their cover.
local function engaged(e)
    return e.inCombat == true
end

local function reachableNear(e, origin, radius)
    local out = {}
    if Out.call(navLib(), "K2_GetRandomReachablePointInRadius", e.ctrl, origin, out, radius, navMesh(),
        queryFilter()) and not offLimits(out) then return out end
    return nil
end

-- 4b. Noises -----------------------------------------------------------------------------------------
-- A noise heard at peace (footsteps, gunfire; ai.lua gives a position that's off by more the farther it was).
-- The personality decides the heard-from-peace reaction: charge (fight now), or freeze and watch where it came
-- from for a while, then go and look (if it's the kind that looks), look around there, and go back to patrolling.
local function hearNoise(e, pawn, at, kind, now)
    local p = e.mind.personality
    if p.heard == "charge" then
        engage(e, pawn, e.heardEntry)
        e.lastSeen = at
        log(("%s (%s) heard %s and charges"):format(e.bot:GetFName():ToString(), AI.describe(e), kind))
        return
    end
    local inv = e.investigate
    if inv and inv.state ~= "look" then inv.at = at return end -- a newer noise updates where to go
    e.investigate = { at = at, state = "freeze", ["until"] = now + (p.heard == "freeze" and AI.freezeTime(e) or 0) }
    e.ctrl:StopMovement()
    log(("%s (%s) heard %s"):format(e.bot:GetFName():ToString(), AI.describe(e), kind))
end

local function endInvestigation(e)
    e.investigate = nil
    if e.bot.bIsCrouched then e.bot:UnCrouch(false) end
    e.ctrl:K2_ClearFocus()
    e.nextPatrol = os.clock() + math.random(1, 4)
end

local function investigate(e, now)
    local inv, p = e.investigate, e.mind.personality
    if e.cover then releaseCover(e) end
    if e.ctrl.BrainComponent:IsRunning() then e.ctrl.BrainComponent:StopLogic("investigate") end
    if inv.state == "freeze" then
        e.ctrl:K2_SetFocalPoint({ X = inv.at.X, Y = inv.at.Y, Z = inv.at.Z + CFG.EYE_STAND })
        if p.sneaky and not e.bot.bIsCrouched then e.bot:Crouch(false) end
        if now < inv["until"] then return end
        if not p.search then return endInvestigation(e) end
        local dest = reachableNear(e, inv.at, 250)
        if not dest then return endInvestigation(e) end
        inv.state, inv.dest, inv.run = "go", dest, math.random() < p.sprintSearch
        if e.bot.bIsCrouched and not p.sneaky then e.bot:UnCrouch(false) end
        e.ctrl:K2_ClearFocus()
        e.ctrl:MoveToLocation(dest, 80, false, true, false, true, queryFilter(), true)
    elseif inv.state == "go" then
        local d = dist2d(e.bot:K2_GetActorLocation(), inv.dest)
        -- sneaky personalities crouch-walk the last stretch, everyone else walks or runs
        if p.sneaky then
            local want = d < 1200
            if want ~= e.bot.bIsCrouched then if want then e.bot:Crouch(false) else e.bot:UnCrouch(false) end end
        end
        if e.ctrl:GetMoveStatus() ~= 3 then
            inv.state, inv["until"], inv.nextLook = "look", now + rnd(CFG.LOOK_AROUND), 0
        end
    else -- look around where it came from
        if now >= inv.nextLook then
            local here, a = e.bot:K2_GetActorLocation(), math.random() * 2 * math.pi
            e.ctrl:K2_SetFocalPoint({ X = here.X + math.cos(a) * 800, Y = here.Y + math.sin(a) * 800,
                Z = here.Z + CFG.EYE_STAND - 90 })
            inv.nextLook = now + 1 + math.random() * 1.5
        end
        if now >= inv["until"] then endInvestigation(e) end
    end
end

-- The tree's own LoS service, "find point near enemy" and cover EQS all come back empty offline
-- (destination/CoverEQsResult stay at FLT_MAX, HasLosToEnemy false), so it retries a move to nowhere every
-- frame: crouching and walking on the spot. Feed it what it expects.
-- 6. Cover ------------------------------------------------------------------------------------------
-- The game's cover system (CoverGenerator, cover EQS) is server-side content that doesn't exist offline, and a
-- spawned CoverGenerator generates nothing. So cover is found with line-of-sight probes from candidate spots,
-- and soldiers cycle hide → lean out and shoot → hide. ARaidCharacter:ServerLean: 1 = left (-40), 2 = right (+40).
local LEAN_NONE, LEAN_LEFT, LEAN_RIGHT = 0, 1, 2


local function sees(ctrl, pawn, from) return ctrl:LineOfSightTo(pawn, from, false) end

local function claimed(e, at)
    if e.avoidCover and dist2d(e.avoidCover, at) < CFG.COVER_MOVE_MIN then return true end
    for _, o in ipairs(raid.bots) do
        if o ~= e and o.cover and dist2d(o.cover.pos, at) < 150 then return true end
    end
    return false
end

-- Nearest navmesh point to a spot, or nil (a firing point off the walkable area is no use).
local function walkable(e, at)
    local out = {}
    if Out.call(navLib(), "K2_ProjectPointToNavigation", e.ctrl, at, out, navMesh(), queryFilter(),
        { X = 30, Y = 30, Z = 150 }) then return out end
    return nil
end

-- Probes one floor spot; returns a cover description or nil.
local function probeCover(e, pawn, playerLoc, p)
    local d = dist2d(p, playerLoc)
    if d < CFG.COVER_PLAYER_DIST[1] or d > CFG.COVER_PLAYER_DIST[2] or claimed(e, p) then return nil end
    local fx, fy = (playerLoc.X - p.X) / d, (playerLoc.Y - p.Y) / d
    local rx, ry = -fy, fx -- right of "facing the player" (UE: X forward, Y right)
    local stand = { X = p.X, Y = p.Y, Z = p.Z + CFG.EYE_STAND }
    local why = "exposed"
    if not sees(e.ctrl, pawn, stand) then
        local options = {}
        -- The shortest step out on each side that sees the player (the wall's edge is rarely exactly 60 away).
        for _, side in ipairs({ LEAN_LEFT, LEAN_RIGHT }) do
            for _, step in ipairs(CFG.PEEK_STEPS) do
                local o = (side == LEAN_LEFT) and -step or step
                local spot = walkable(e, { X = p.X + rx * o, Y = p.Y + ry * o, Z = p.Z })
                if spot and dist2d(spot, p) > step * 0.6
                    and sees(e.ctrl, pawn, { X = spot.X, Y = spot.Y, Z = spot.Z + CFG.EYE_STAND }) then
                    table.insert(options, { side = side, peekPos = spot })
                    break
                end
            end
        end
        if #options == 0 then return nil, "no peek" end
        local pick = options[math.random(1, #options)]
        return { pos = p, low = false, side = pick.side, peekPos = pick.peekPos }
    end
    if not sees(e.ctrl, pawn, { X = p.X, Y = p.Y, Z = p.Z + CFG.EYE_CROUCH }) then
        return { pos = p, low = true, side = LEAN_NONE }
    end
    return nil, why
end

-- Baked cover spots (cover.lua) that block towards the player come first, nearest (plus personality) first; only a few
-- get the real line-of-sight probe. Random reachable points are the fallback while the cells around are still baking.
-- Bold personalities favour spots nearer the player, timid ones spots farther back.
local function findCover(e, pawn, playerLoc, radius, tries)
    local here = e.bot:K2_GetActorLocation()
    local aggr = e.mind and e.mind.personality.aggression or 1
    local function score(p, low)
        return dist2d(here, p) + (low and CFG.LOW_COVER_PENALTY or 0)
            + (aggr - 1) * CFG.COVER_AGGRESSION_PULL * dist2d(p, playerLoc)
    end
    local list = {}
    -- what the search turned down, for the log when it finds nothing (coverCycle's M.openLog)
    local st = { baked = 0, off = 0, ["out of range"] = 0, random = 0 }
    -- offLimits keeps soldiers off roofs and hull shells, but it judges by loot and AI nodes nearby on the same level,
    -- and some played floors have none within reach (Penal Colony, 2026-11-14: the nearest 12 m up). A soldier
    -- already standing somewhere it calls off limits is on such a floor: don't filter the spots around it.
    local filter = not offLimits(here)
    for _, c in ipairs(raid.coverNoBake and {} or Cover.candidates(here, playerLoc, radius, CFG.COVER_BAKED_POOL)) do
        st.baked = st.baked + 1
        if not (filter and offLimits(c.pos)) then
            c.score = score(c.pos, c.low)
            list[#list + 1] = c
        else
            st.off = st.off + 1
        end
    end
    table.sort(list, function(a, b) return a.score < b.score end)
    local probes = 0
    for _, c in ipairs(list) do
        if probes >= CFG.COVER_BAKED_PROBES then break end
        local d = dist2d(playerLoc, c.pos)
        if d >= CFG.COVER_PLAYER_DIST[1] and d <= CFG.COVER_PLAYER_DIST[2] and not claimed(e, c.pos) then
            probes = probes + 1
            local got, why = probeCover(e, pawn, playerLoc, c.pos)
            if got and M.longWay(e, here, c.pos) then got, why = nil, "long way round" end
            local pr = raid.coverProbe or {}
            raid.coverProbe = pr
            local k = got and "ok" or why or "?"
            pr[k] = (pr[k] or 0) + 1
            st[k] = (st[k] or 0) + 1
            if got then got.baked = true return got end
        else
            st["out of range"] = st["out of range"] + 1
        end
    end
    local best, bestD
    for _ = 1, math.max(1, math.floor(tries * (#list > 0 and CFG.COVER_RANDOM_SHARE or 1))) do
        local p = reachableNear(e, here, radius)
        if p then
            st.random = st.random + 1
            local c, why = probeCover(e, pawn, playerLoc, p)
            local d = c and score(p, c.low)
            if c and (not best or d < bestD) then best, bestD = c, d end
            if not c then
                local k = "random " .. (why or "out of range")
                st[k] = (st[k] or 0) + 1
            end
        end
    end
    if best and M.longWay(e, here, best.pos) then
        best = nil
        st["random long way round"] = (st["random long way round"] or 0) + 1
    end
    return best, st
end

-- Why a fighting soldier is in the open: tallied for the status line, and logged per soldier at most every
-- CFG.OPEN_LOG_SECONDS (st: findCover's counts, nil when it chose not to look).
function M.openLog(e, now, why, st)
    raid.openWhy = raid.openWhy or {}
    raid.openWhy[why] = (raid.openWhy[why] or 0) + 1
    if now < (e.openLogAt or 0) then return end
    e.openLogAt = now + CFG.OPEN_LOG_SECONDS
    local parts = {}
    for k, v in pairs(st or {}) do if v > 0 then parts[#parts + 1] = k .. " " .. v end end
    table.sort(parts)
    log(("%s fighting in the open: %s, %s%s"):format(e.bot:GetFName():ToString(), why,
        e.los and "in sight" or "target unseen", #parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""))
end

-- Is the soldier at its cover spot exposed while it should be hidden (the player flanked it)?
local function exposed(e, pawn, c)
    local h = c.low and CFG.EYE_CROUCH or CFG.EYE_STAND
    return sees(e.ctrl, pawn, { X = c.pos.X, Y = c.pos.Y, Z = c.pos.Z + h })
end

releaseCover = function(e, why)
    e.nextCover = nil
    if e.cover then
        e.bot:ServerLean(LEAN_NONE)
        if e.inCombat and foeOf(e) then setEnemy(e, foeOf(e)) end
        if why then log(("%s left cover (%s, was %s)"):format(e.bot:GetFName():ToString(), why, e.cover.state)) end
    end
    e.cover = nil
end

-- The tree shoots at its Enemy regardless of sight, and the controller at MyEnemy: clear both to hold fire.
local function holdFire(e)
    e.ctrl.BlackboardComp:ClearValue(FName("Enemy"))
    e.ctrl.MyEnemy = nil
end

-- Bots reload (issue #115). A bot's shot never touches its gun's clip (only ServerMultiSimulateWeaponFire runs, see
-- the gunfire hook), so its 30 rounds never ran out. Shots are counted here against the gun's magazine
-- (WeaponConfig.AmmoPerClip) and the clip kept in step; on empty the bot holds fire for the reload (its controller's
-- ReloadAIWeapon plays what the game has for it), and updateBots refills the clip when the time is up.
function M.botShot(w, owner)
    local addr = owner:GetAddress()
    local by = raid.botByAddr
    if not by or raid.botByAddrN ~= #raid.bots then
        by = {}
        for _, o in ipairs(raid.bots) do
            if valid(o.bot) then by[o.bot:GetAddress()] = o end
        end
        raid.botByAddr, raid.botByAddrN = by, #raid.bots
    end
    local e = by[addr]
    if not (e and valid(e.ctrl)) then return end
    if not e.mag then
        local ok, m = pcall(function() return w.WeaponConfig.AmmoPerClip end)
        e.mag = ok and m and m > 0 and m or 30
    end
    e.shots = (e.shots or 0) + 1
    pcall(function() w.CurrentAmmoInClip = math.max(0, e.mag - e.shots) end)
    if e.shots < e.mag then return end
    e.shots = 0
    e.reloadUntil = os.clock() + CFG.BOT_RELOAD_SECONDS + math.random() * CFG.BOT_RELOAD_JITTER
    e.holdUntil = e.reloadUntil
    pcall(holdFire, e)
    pcall(function() e.ctrl:ReloadAIWeapon() end)
    raid.reloads = (raid.reloads or 0) + 1
    if raid.reloads == 1 then log(("bots reload: first one after %d shots"):format(e.mag)) end
end

local function strafeTo(e, at)
    e.ctrl:MoveToLocation(at, 15, false, true, true, true, queryFilter(), true)
end

local function hide(e, c, now)
    if c.state == "peeking" then c.blindPeeks = c.peekSaw and 0 or (c.blindPeeks or 0) + 1 end
    c.peekSaw = false
    e.bot:ServerLean(LEAN_NONE)
    holdFire(e)
    if c.peekPos and c.state == "peeking" then strafeTo(e, c.pos) end
    if c.low then e.bot:Crouch(false) else e.bot:UnCrouch(false) end
    c.state, c["until"] = "hiding", now + rnd(CFG.HIDE_SECONDS)
end

local function peek(e, c, now)
    e.bot:UnCrouch(false)
    if foeOf(e) then setEnemy(e, foeOf(e)) end
    if not c.low then
        e.bot:ServerLean(c.side) -- looks right; the step out is what lets it actually fire
        strafeTo(e, c.peekPos)
    end
    c.state, c["until"] = "peeking", now + rnd(CFG.PEEK_SECONDS)
end

-- Runs the cover behaviour; returns false when there's no usable cover (the caller falls back to strafing).
local function coverCycle(e, pawn, playerLoc, now)
    local c = e.cover
    if c and c.state == "hiding" and (c.blindPeeks or 0) >= CFG.COVER_BLIND_PEEKS then
        -- Its peeks keep finding nothing: the player has moved to an angle this spot doesn't cover. Look for a spot
        -- that covers the new angle (a different one: the search used to hand back the one it was in); if there's
        -- none (the player is out of sight from everywhere around), stay put and keep watching.
        e.avoidCover = c.pos
        local ok, alt = pcall(findCover, e, pawn, playerLoc, CFG.COVER_SEARCH, CFG.COVER_CANDIDATES)
        e.avoidCover = nil
        if ok and alt and e.los and dist2d(e.bot:K2_GetActorLocation(), alt.pos) > CFG.EXPOSED_COVER_DIST then alt = nil end
        if ok and alt then
            releaseCover(e, "angle lost")
            e.nextCover, c = alt, nil
        else
            c.blindPeeks = 0
        end
    elseif c and c.state == "hiding" and exposed(e, pawn, c) then
        releaseCover(e, "flanked")
        c = nil
    end
    local justHurt = e.hurtAt and now - e.hurtAt < CFG.HURT_DUCK_SECONDS
    if c and c.state == "peeking" and justHurt then
        hide(e, c, now) -- shot while leaning out: duck back in
        return true
    end
    if not c and e.nextCover then -- moving on to the spot picked when the last one's time ran out
        c, e.nextCover = e.nextCover, nil
    elseif not c then
        if justHurt then e.openUntil, e.nextCoverSearch = 0, 0 end -- shot in the open: think about cover now
        if now < (e.nextCoverSearch or 0) or now < (e.openUntil or 0) then return false end
        e.nextCoverSearch = now + CFG.COVER_RETRY
        -- Does it want cover at all? Bold personalities would rather keep shooting.
        local p = e.mind and e.mind.personality
        local hold = p and p.holdGround or 1
        -- chance ^ aggression: 0.95 is ~0.93 for a GigaChad (1.5) and ~0.86 for a Wreckless (3)
        if math.random() >= (justHurt and CFG.COVER_HURT_CHANCE or CFG.COVER_SEEK_CHANCE) ^ (p and p.aggression or 1) then
            e.openUntil = now + CFG.OPEN_FIGHT_SECONDS * hold
            M.openLog(e, now, "chose not to look for cover")
            return false
        end
        -- Cover first, but a soldier in the player's sight only runs for cover close by; out of sight it can
        -- look further. With nothing quick, it strafes and shoots for a while (OPEN_FIGHT_SECONDS).
        local here = e.bot:K2_GetActorLocation()
        local st, why
        c, st = findCover(e, pawn, playerLoc, CFG.COVER_SEARCH, CFG.COVER_CANDIDATES)
        if e.los then
            if c and dist2d(here, c.pos) > CFG.EXPOSED_COVER_DIST then c, why = nil, "nearest cover too far to run in sight" end
        elseif not c then
            c, st = findCover(e, pawn, playerLoc, CFG.COVER_SEARCH_FAR, CFG.COVER_CANDIDATES_FAR)
        end
        if not c then
            e.openUntil = now + CFG.OPEN_FIGHT_SECONDS * hold
            M.openLog(e, now, why or "no cover found", st)
            return false
        end
    end
    if not e.cover then -- a new spot: go there
        c.started = now
        c.state = "moving"
        local here = e.bot:K2_GetActorLocation()
        local far = dist2d(here, c.pos)
        c.run = math.random() < (e.los and CFG.SPRINT_EXPOSED_CHANCE or CFG.SPRINT_UNSEEN_CHANCE)
            and far > CFG.COVER_MOVE_MIN -- no sprinting a couple of steps
        -- A spot behind it, walked to while facing the enemy, was a long slow backpedal that rarely got there
        -- (2026-11-14): turn and run instead.
        local toP = dist2d(here, playerLoc)
        if not c.run and far > CFG.COVER_MOVE_MIN and toP > 1 then
            local cos = ((c.pos.X - here.X) * (playerLoc.X - here.X) + (c.pos.Y - here.Y) * (playerLoc.Y - here.Y))
                / (far * toP)
            if cos < -CFG.COVER_BACK_RUN then c.run, c.back = true, true end
        end
        c.left, c.retries = far, 0
        e.cover = c
        -- Sprinting: weapon down, no shooting on the way, facing the path. Otherwise it walks there, still focused on
        -- its enemy, so the tree keeps shooting and the move stays a strafe (trackTargets keeps the focus).
        if c.run then
            holdFire(e)
            e.ctrl:K2_ClearFocus()
        end
        log(("%s %s to %s %s cover %.0f away"):format(e.bot:GetFName():ToString(),
            c.back and "turning to run back" or c.run and "sprinting" or "firing on the way",
            c.baked and "baked" or "random", c.low and "low" or (c.side == LEAN_LEFT and "lean-left" or "lean-right"), far))
        e.bot:UnCrouch(false)
        e.ctrl:MoveToLocation(c.pos, 30, false, true, true, true, queryFilter(), true)
        return true
    end
    if c.state == "moving" then
        if c.run and e.los and now - c.started > CFG.EXPOSED_RUN_SECONDS then
            releaseCover(e, "too long running in sight")
            e.openUntil = now + CFG.OPEN_FIGHT_SECONDS * (e.mind and e.mind.personality.holdGround or 1)
            e.nextHint = 0 -- start strafing right away
            return false
        end
        if e.ctrl:GetMoveStatus() ~= 3 then -- arrived, or the move ended
            local off = dist2d(e.bot:K2_GetActorLocation(), c.pos)
            -- Moves to cover often ended hundreds of units short (the tree, or the stuck check below), and the soldier
            -- gave up and started over somewhere else. Send it again while it's still gaining ground.
            local stuck = e.stuckAt and now - e.stuckAt < 0.5
            if off > 150 and c.retries < CFG.COVER_MOVE_RETRIES and c.left - off > 100 then
                c.retries, c.left = c.retries + 1, off
                log(("%s move to cover ended %.0f short%s: sent again"):format(e.bot:GetFName():ToString(), off,
                    stuck and " (stuck)" or ""))
                e.ctrl:MoveToLocation(c.pos, 30, false, true, true, true, queryFilter(), true)
                return true
            end
            if off > 150 then
                releaseCover(e, ("move ended %.0f short%s"):format(off, stuck and ", stuck" or ""))
                return false
            end
            hide(e, c, now)
        end
        return true
    end
    -- (animate() holds the posture each phase wants, every frame.)
    if now >= c["until"] then
        if c.state == "hiding" then peek(e, c, now) else hide(e, c, now) end
    end
    return true
end

local function soldierSees(e, pawn)
    return e.ctrl:LineOfSightTo(pawn, { X = 0, Y = 0, Z = 0 }, false)
end

-- A side-step across the player's line of fire (a random nearby point is often a single step away).
local function strafePoint(e, playerLoc)
    local here = e.bot:K2_GetActorLocation()
    local d = dist2d(here, playerLoc)
    if d < 1 then return reachableNear(e, here, CFG.STRAFE_DIST[2]) end
    local rx, ry = -(playerLoc.Y - here.Y) / d, (playerLoc.X - here.X) / d
    local side = math.random(0, 1) == 0 and -1 or 1
    for _ = 1, 4 do
        local step = rnd(CFG.STRAFE_DIST) * side
        local p = walkable(e, { X = here.X + rx * step, Y = here.Y + ry * step, Z = here.Z })
        if p and dist2d(p, here) > 150 and not offLimits(p) then return p end
        side = -side
    end
    return reachableNear(e, here, CFG.STRAFE_DIST[2])
end

-- Out of sight: close in on where the target was last seen. The soldier keeps its focus on the target while it walks,
-- so a point behind it is a slow walk backwards (seen 2026-11-14): of a few points near that spot take the nearest to
-- it, and only if it's actually nearer than where the soldier stands; otherwise hold and watch.
function M.advancePoint(e, goal)
    local here = e.bot:K2_GetActorLocation()
    local cur = dist2d(here, goal)
    local best, bestD
    for _ = 1, 3 do
        local p = reachableNear(e, goal, CFG.ADVANCE_RADIUS)
        local d = p and dist2d(p, goal)
        if d and (not best or d < bestD) then best, bestD = p, d end
    end
    if best and bestD < cur - 100 then return best end
    return nil
end

-- Knife and truncheon soldiers (weapons on Weap_Knife_C): cached per held weapon.
function M.isMelee(e)
    local w = e.bot and e.bot.CurrentWeapon
    if not valid(w) then return e.melee end
    local a = w:GetAddress()
    if a ~= e.meleeW then
        e.meleeW, e.melee = a, false
        pcall(function()
            local c = w:GetClass()
            for _ = 1, 10 do
                if not valid(c) then break end
                if c:GetFName():ToString() == "Weap_Knife_C" then e.melee = true break end
                c = c:GetSuperStruct()
            end
        end)
    end
    return e.melee
end

-- The tree swings at its Enemy at any range, and the gunman's hints (cover, strafing) only walked melee soldiers
-- around swinging at the air (seen 2026-11-14). They charge instead: run at the target (or where it was last seen),
-- with no Enemy set until within CFG.MELEE_REACH. Returns true when it handled the soldier.
function M.meleeHints(e, pawn, playerLoc, los, now)
    if not M.isMelee(e) then
        e.meleeClose, e.meleeRun = nil, nil
        return false
    end
    if e.cover then releaseCover(e, "melee") end
    local here = e.bot:K2_GetActorLocation()
    local d = dist2d(here, playerLoc)
    local close = math.abs(here.Z - playerLoc.Z) < 200 and d < (e.meleeClose and CFG.MELEE_LET_GO or CFG.MELEE_REACH)
    if close and not e.meleeClose then
        e.meleeClose = true
        setEnemy(e, pawn)
    elseif not close then
        e.meleeClose = false
    end
    e.meleeRun = d > CFG.MELEE_RUN
    e.standUntil, e.crouchSince = now + 1, nil
    if now >= (e.nextHint or 0) then
        e.nextHint = now + 0.4
        if not close then
            holdFire(e) -- trackTargets or the tree may have set it again
            e.ctrl:MoveToLocation(los and playerLoc or e.lastSeen or playerLoc, 60, false, true, true, true, queryFilter(), true)
        end
    end
    return true
end

-- Length of the walk from one point to another (nil when unknown), and whether the path stops short.
function M.pathLen(e, from, to)
    local ok, len, partial = pcall(function()
        local p = navLib():FindPathToLocationSynchronously(e.ctrl, from, to, e.bot, nil)
        if not valid(p) then return nil end
        return p:GetPathLength(), p:IsPartial()
    end)
    if ok then return len, partial end
    return nil
end

-- A cover spot near in a straight line can be a long walk round (another room or floor): the soldier then ran away
-- from the fight towards it (seen 2026-11-14: a spot 611 away, the move ended 2727 short).
function M.longWay(e, here, to)
    local len, partial = M.pathLen(e, here, to)
    if not len then return false end
    return partial or len > dist2d(here, to) * CFG.COVER_PATH_STRETCH + CFG.COVER_PATH_SLACK
end

local function combatHints(e, pawn, playerLoc)
    local bb, ctrl = e.ctrl.BlackboardComp, e.ctrl
    local los = soldierSees(e, pawn)
    bb:SetValueAsBool(FName("HasLosToEnemy"), los)
    ctrl.bCanSeePlayer = los
    e.los = los -- trackTargets() keeps LastKnownPlayerPosition current every frame while this holds
    if los and e.cover and e.cover.state == "peeking" then e.cover.peekSaw = true end
    if los then e.lastSeen = playerLoc end
    local now = os.clock()
    local v = e.bot:GetVelocity()
    if los and not e.losSince then e.losSince = now elseif not los then e.losSince = nil end
    if e.mind then
        local tv = pawn:GetVelocity()
        e.bot.AIMissRate = AI.aimFor(e, now, { skillSpread = CFG.AIM_SKILL_SPREAD, streak = CFG.AIM_STREAK,
            streakSeconds = CFG.AIM_STREAK_SECONDS, settleSeconds = CFG.AIM_SETTLE_SECONDS,
            settlePenalty = CFG.AIM_SETTLE_PENALTY, movingPenalty = CFG.AIM_MOVING,
            targetMovingPenalty = CFG.AIM_TARGET_MOVING, hurtPenalty = CFG.AIM_UNDER_FIRE,
            hurtSeconds = CFG.AIM_UNDER_FIRE_SECONDS, rangePer10m = CFG.AIM_RANGE_PER_10M, maxMiss = CFG.AIM_MISS_MAX,
            moving = v.X * v.X + v.Y * v.Y > 2500, targetMoving = tv.X * tv.X + tv.Y * tv.Y > 2500,
            distance = dist2d(e.bot:K2_GetActorLocation(), playerLoc), losSince = e.losSince, hurtAt = e.hurtAt })
        local f = e.foeEntry
        local side = f and f ~= PLAYER and edge(factionOf(e), factionOf(f))
        if side then
            e.bot.AIMissRate = math.min(CFG.AIM_MISS_MAX,
                e.bot.AIMissRate * (side == "guard" and CFG.EDGE_GUARD_MISS or CFG.EDGE_RIVAL_MISS))
        end
    end

    -- A move that barely progresses (blocked by geometry or another soldier) looks like walking on the spot.
    if ctrl:GetMoveStatus() == 3 and math.sqrt(v.X * v.X + v.Y * v.Y) < CFG.STUCK_SPEED then
        e.slowSince = e.slowSince or now
        if now - e.slowSince >= CFG.STUCK_SECONDS then
            ctrl:StopMovement()
            e.slowSince, e.nextHint, e.stuckAt = nil, now + 0.5, now
        end
    else
        e.slowSince = nil
    end

    if M.meleeHints(e, pawn, playerLoc, los, now) then return end
    Cover.want(e.bot:K2_GetActorLocation(), CFG.COVER_SEARCH_FAR)
    if coverCycle(e, pawn, playerLoc, now) then
        e.standUntil, e.crouchSince = nil, nil -- cover decides the posture
        return
    end

    -- No cover: limit the tree's crouch-peeking (animate() keeps the soldier standing until standUntil).
    if e.bot.bIsCrouched and not e.standUntil then
        e.crouchSince = e.crouchSince or now
        if now - e.crouchSince >= CFG.CROUCH_MAX then
            e.standUntil, e.crouchSince = now + CFG.CROUCH_COOLDOWN, nil
        end
    elseif not e.bot.bIsCrouched then
        e.crouchSince = nil
    end
    if e.standUntil and now >= e.standUntil then e.standUntil = nil end
    if now >= (e.nextHint or 0) then
        local here = e.bot:K2_GetActorLocation()
        -- Without sight of the player, close in on where they were last seen; with it, strafe quickly.
        local dest = los and strafePoint(e, playerLoc)
            or M.advancePoint(e, e.lastSeen or playerLoc)
        if dest then
            bb:SetValueAsVector(FName("destination"), dest)
            bb:SetValueAsVector(FName("CoverEQsResult"), dest)
            -- The tree itself never moves once it has sight (it only shoots and crouch-peeks), but it lets a
            -- strafing move run: the soldier keeps its focus, so it keeps facing and shooting the player.
            ctrl:MoveToLocation(dest, 40, false, true, true, true, queryFilter(), true)
        end
        e.nextHint = now + (los and rnd(CFG.STRAFE_SECONDS)
            or math.random(CFG.REPOSITION_SECONDS[1], CFG.REPOSITION_SECONDS[2]))
    end
end

-- Distant bots: wake() makes every bot tick its pose every frame even unseen, with update-rate optimisation off (asleep
-- bots never turned or aimed, and URO made near ones choppy). With a garrison and docked crews that's dozens of
-- skeletons evaluated each frame while you fly kilometres away. Past ANIM_FAR from the camera they go back to the
-- engine's cheaper way: montages only while not drawn, URO on. They still move, fight and take damage.
local ANIM_FAR_FLAG = PROJECT .. "bridge/anim_far_off" -- on by default since 2026-11-17 (build 4 fps reports); present = off, for testing
local function animDistance(e, cam, farOn)
    local far = farOn and dist(e.bot:K2_GetActorLocation(), cam) > CFG.ANIM_FAR
    if far == e.animFar then return end
    e.animFar = far
    local mesh = e.bot.Mesh
    mesh.VisibilityBasedAnimTickOption = far and 2 or 1 -- OnlyTickMontagesWhenNotRendered / AlwaysTickPose
    mesh.bEnableUpdateRateOptimizations = far
    local P = _G.PVE_PROF
    if P then P.animSwitch = (P.animSwitch or 0) + 1 end
end

local function updateBots(pc)
    -- On space maps the target is your on-foot character, which stays at the helm while you fly the ship.
    local pawn = valid(raid.target) and raid.target or pc.Pawn
    local alive = valid(pawn) and (pawn.Health or 0) > 0
    local playerLoc = alive and pawn:K2_GetActorLocation() or nil
    reapDead()
    -- Did something just hurt you? (a taunting Chad that is fighting you takes credit, below)
    local playerHurt = alive and raid.pHp ~= nil and pawn.Health < raid.pHp
    raid.pHp = alive and pawn.Health or nil
    local cam
    pcall(function() cam = pc.PlayerCameraManager:GetCameraLocation() end)
    raid.camAt = cam or playerLoc
    if Aux.due("animFar", 5) then
        local ff = io.open(ANIM_FAR_FLAG, "r")
        if ff then ff:close() end
        M.animFarOn = ff == nil
    end
    local farOn = M.animFarOn ~= false
    -- Cover is baked around you on foot (fights happen near you) and around every fighting soldier (combatHints).
    if playerLoc and raid.navReady and valid(pc.Pawn) and pc.Pawn:GetAddress() == pawn:GetAddress() then
        Cover.want(playerLoc, CFG.COVER_BAKE_RADIUS)
    end
    -- Everyone who can be fought: you, and every live bot (by faction).
    local bodies = {}
    if alive then bodies[1] = { entry = PLAYER, pawn = pawn, at = playerLoc, faction = "player" } end
    -- Each bot's location is read once per update here (each read makes a new table): M.parked and the loop below
    -- use it too, where they used to read it again.
    for _, o in ipairs(raid.bots) do
        o.updAt = nil
        if valid(o.bot) and (o.bot.Health or 0) > 0 then
            o.updAt = o.bot:K2_GetActorLocation()
            if not o.parked then
                bodies[#bodies + 1] = { entry = o, pawn = o.bot, at = o.updAt, faction = factionOf(o) }
            end
        end
    end
    for _, e in ipairs(raid.bots) do
        if valid(e.bot) and valid(e.ctrl) and (e.bot.Health or 0) > 0 and not M.parked(e, playerLoc) then
            local foe = foeOf(e)
            if e.inCombat and not foe then
                -- whoever it was fighting is dead or gone: back to searching
                e.inCombat, e.foeEntry, e.cover = false, nil, nil
                pcall(function() holdFire(e) end)
            end
            local fighting = engaged(e)
            -- Re-arm a bot the game put back to sleep. A stopped tree only counts while fighting:
            -- patrolling bots have it stopped on purpose.
            if not valid(e.bot.Controller) or (fighting and not e.ctrl.BrainComponent:IsRunning()) then
                e.rearms = (e.rearms or 0) + 1
                -- arm() puts a bot on the soldiers' team: rivals and your crew keep their own
                local team = e.faction and e.ctrl.TeamNumber
                if e.rearms <= 20 then
                    arm(e.bot, e.ctrl)
                    if team and valid(e.ctrl) then e.ctrl.TeamNumber = team end
                end
                if e.rearms == 20 then log("giving up re-arming " .. e.bot:GetFName():ToString()) end
            elseif e.bot.CustomTimeDilation < 1 or not e.bot.Mesh:IsComponentTickEnabled() then
                wake(e.bot, e.ctrl)
            end
            if cam then
                if e.bot.Mesh.VisibilityBasedAnimTickOption == 1 and e.animFar then e.animFar = nil end -- woken again
                animDistance(e, cam, farOn)
            end
            local hp = e.bot.Health
            local hurt = e.hp ~= nil and hp < e.hp
            e.hp = hp
            e.hpMax = math.max(e.hpMax or 0, hp)
            local now = os.clock()
            if hurt then
                e.hurtAt = now
                pcall(Voice.say, e, hp < 40 and "Help" or "Pain", hp >= 40)
            end
            local dt = math.min(1, now - (e.perceivedAt or now))
            e.perceivedAt = now
            local here = e.updAt or e.bot:K2_GetActorLocation()
            e.lastAt = here
            local mine = factionOf(e)
            -- Routed (rivalbodies.lua routGuards, #313: its leader is down): no fighting, no looking for one, no patrol
            -- while it runs, unless you come within e.routNear.
            local routed = e.routUntil and now < e.routUntil
                and not (playerLoc and dist(here, playerLoc) < (e.routNear or 0)) or false
            -- Begging (banter.lua, #316): a badly hurt Rat, Coward or Timmy near you holds fire and stays put like a routed
            -- bot, then runs (routUntil, from the next update) or fights again if hit.
            if e.mind then
                local okb, rb = pcall(Banter.beg, e, now, hp, hurt, here, playerLoc, fighting or e.alert ~= nil or e.inCombat,
                    holdFire)
                if okb and rb == true then routed = true end
            end
            if routed and (fighting or e.alert or e.investigate) then
                e.inCombat, e.foeEntry, e.cover, e.alert, e.investigate = false, nil, nil, nil, nil
                fighting = false
                pcall(function() holdFire(e) end)
            end
            -- Size up every hostile body within range: the first spotted (nearest first) is the foe; otherwise
            -- the nearest one heard.
            local spotted, heard
            if not fighting and not e.alert and not routed then
                local cands = {}
                for _, b in ipairs(bodies) do
                    if b.faction ~= mine then
                        local d = dist(here, b.at)
                        if d < CFG.PERCEIVE_RANGE then cands[#cands + 1] = { b = b, d = d } end
                    end
                end
                table.sort(cands, function(x, y) return x.d < y.d end)
                for _, k in ipairs(cands) do
                    if hurt then AI.hurt(e, k.b.pawn, now) end
                    local spotMul = edge(mine, k.b.faction) == "guard" and CFG.EDGE_GUARD_SPOT or nil
                    local what, d, heardAt, kind = AI.perceive(e, k.b.pawn, k.b.at, now, dt, spotMul, k.b)
                    if what == "spotted" then spotted = { b = k.b, d = d } break end
                    if what == "heard" and not heard then heard = { b = k.b, d = d, at = heardAt, kind = kind } end
                end
                -- Shot by someone it didn't see: turn on the nearest hostile.
                if hurt and not spotted and cands[1] then spotted = { b = cands[1].b, d = cands[1].d, shot = true } end
            end
            local function who() return ("%s (%s)"):format(e.rival and e.rival.name or e.crewmate and ("your " .. e.crewmate.name)
                or e.bot:GetFName():ToString(), AI.describe(e)) end
            local function name(b)
                local o = b.entry
                return o == PLAYER and "the player" or (o.rival and o.rival.name
                    or o.crewmate and ("your " .. o.crewmate.name) or "a soldier")
            end
            if not fighting and e.alert and alive then
                engage(e, pawn, PLAYER)
                fighting, e.lastSeen, e.alert = true, playerLoc, nil -- boarders know where you are
                log(who() .. " knows where the player is")
            elseif spotted or (heard and heard.d < CFG.POINT_BLANK) then
                local b = spotted and spotted.b or heard.b
                engage(e, b.pawn, b.entry)
                fighting = true
                e.lastSeen = spotted and b.at or heard.at
                pcall(Voice.say, e, spotted and spotted.shot and "CoverMe" or "EnemySpotted")
                log(who() .. (spotted and spotted.shot and (" was shot, fighting " .. name(b))
                    or spotted and (" spotted %s at %.0f m"):format(name(b), spotted.d / 100)
                    or (" heard %s point-blank"):format(name(b))))
            elseif heard then
                e.heardEntry = heard.b.entry
                hearNoise(e, heard.b.pawn, heard.at, heard.kind, now)
                fighting = e.inCombat == true
            end
            -- Already fighting: perception above only runs at peace, so a bot locked on a far foe used to ignore an
            -- enemy standing beside it (a crewmate and a soldier side by side, each shooting someone across the room).
            -- About once a second, switch to a hostile that is much closer than the current foe and either in sight
            -- or shooting at this bot.
            -- Hurt while its foe is out of sight (behind a wall), the shot came from someone else: turn on the nearest
            -- hostile it can see, however far. Without this a guard locked on a rival through a wall took the
            -- player's fire and kept shooting the wall (Penal Colony, 2026-11-14): the player never counts as "onMe".
            local hitBlind = false
            if fighting and hurt then
                local cur = foeOf(e)
                hitBlind = not (cur and e.ctrl:LineOfSightTo(cur, { X = 0, Y = 0, Z = 0 }, false))
            end
            if fighting and (hitBlind or now >= (e.nextRetarget or 0)) then
                e.nextRetarget = now + CFG.RETARGET_EVERY
                local cur = foeOf(e)
                local df = cur and dist(here, cur:K2_GetActorLocation()) or math.huge
                local best, bd
                for _, b in ipairs(bodies) do
                    if b.faction ~= mine and b.pawn ~= cur then
                        local d = dist(here, b.at)
                        local inReach = hitBlind and d < CFG.PERCEIVE_RANGE
                            or d < CFG.RETARGET_NEAR and d < df * CFG.RETARGET_RATIO
                        if inReach and (not bd or d < bd) then
                            local onMe = b.entry ~= PLAYER and b.entry.inCombat and b.entry.foeEntry == e
                            if onMe or e.ctrl:LineOfSightTo(b.pawn, { X = 0, Y = 0, Z = 0 }, false) then
                                best, bd = b, d
                            end
                        end
                    end
                end
                if best then
                    engage(e, best.pawn, best.entry)
                    e.lastSeen = best.at
                    log(("%s turns on %s at %.0f m (was fighting someone %.0f m off)"):format(who(), name(best), bd / 100,
                        df == math.huge and 0 or df / 100))
                end
            end
            if not fighting and not routed then
                -- your crew (crew.lua) follows you instead of patrolling or going to look at noises
                if e.follow then
                    if e.cover then releaseCover(e) end
                    e.investigate = nil
                    local okf, errf = pcall(e.follow, e)
                    if not okf then log("crew follow failed: " .. tostring(errf)) end
                elseif e.investigate then investigate(e, now) else patrol(e) end
            end
            foe = foeOf(e)
            -- A won fight gets an insult; a long one gets the odd call to the crew.
            local won = e.fighting and not (fighting and foe)
            if won and Banter.isTaunter(e) then
                Banter.taunt(e, now) -- Chads gloat (rate-limited, CFG.TAUNT_CHANCE)
            elseif won and math.random() < 0.5 then
                pcall(Voice.say, e, math.random() < 0.5 and "Insult01" or "FuckOff")
            elseif e.fighting and now >= (e.calloutAt or 0) then
                e.calloutAt = now + math.random(8, 16)
                local calls = { "Attack", "CoverMe", "HoldPosition" }
                pcall(Voice.say, e, calls[math.random(#calls)])
            end
            if playerHurt and fighting and e.foeEntry == PLAYER and Banter.isTaunter(e) then Banter.taunt(e, now) end
            e.fighting = fighting and foe ~= nil
            if e.fighting then combatHints(e, foe, foe:K2_GetActorLocation()) end
            if e.fighting then -- every update: how fighting soldiers spend their time (logged with the status line)
                local st = e.cover and e.cover.state or (e.los and "open" or "unseen")
                raid.coverTally = raid.coverTally or {}
                raid.coverTally[st] = (raid.coverTally[st] or 0) + 1
            end
        end
    end
    if os.clock() - (raid.lastReport or 0) >= 10 then
        local now, since = os.clock(), raid.lastReport
        raid.lastReport = now
        local living, walking, fighting, parked = 0, 0, 0, 0
        for _, e in ipairs(raid.bots) do
            if valid(e.bot) and (e.bot.Health or 0) > 0 then
                living = living + 1
                if e.parked then parked = parked + 1
                elseif e.fighting then fighting = fighting + 1
                elseif e.ctrl:GetMoveStatus() == 3 then walking = walking + 1 end
            end
        end
        local fps = since and now > since and (raid.frames or 0) / (now - since) or nil
        raid.frames = 0
        log(("soldiers alive %d, fighting %d, patrolling %d, parked %d, player hp %s | fps %s | crew: %s"):format(living,
            fighting, walking, parked, alive and string.format("%.0f", pawn.Health) or "dead",
            fps and string.format("%.0f", fps) or "-", Crew and Crew.status() or "-"))
        -- bridge/cover_nobake (testing): random-point cover search only, as before cover.lua
        local nb = io.open(PROJECT .. "bridge/cover_nobake", "r")
        if nb then nb:close() end
        if (nb ~= nil) ~= (raid.coverNoBake == true) then
            raid.coverNoBake = nb ~= nil
            log("cover: baked spots " .. (raid.coverNoBake and "OFF" or "on"))
        end
        local pr = {}
        for k, v in pairs(raid.coverProbe or {}) do pr[#pr + 1] = k .. " " .. v end
        local ow = {}
        for k, v in pairs(raid.openWhy or {}) do ow[#ow + 1] = k .. " " .. v end
        log("cover probes of baked spots: " .. table.concat(pr, ", ") .. " | open fights: " .. table.concat(ow, ", "))
        local t = raid.coverTally or {}
        log(("cover %s | fighting samples: hiding %d, peeking %d, moving %d, open in sight %d, open unseen %d"):format(
            Cover.stats(), t.hiding or 0, t.peeking or 0, t.moving or 0, t.open or 0, t.unseen or 0))
    end
end

-- 5. Aim --------------------------------------------------------------------------------------------
-- Something in the AI (a tree service on its own timer) keeps swapping the controller's focus for a point it
-- refreshes slowly, so the focal point trailed a moving player by 100-1000 units and the bot turned "late".
-- Re-asserting focus every frame keeps the body within ~5 degrees of the player (measured at 1.5-5 m).
-- The AI anim blueprint picks the leg play rate itself every update (Standing_LegsPlayrate 1.1 walking,
-- 0.65 aiming) and overwrites anything we write (post-hooks on BlueprintUpdateAnimation don't fire). Legs
-- slid whenever the bot moved faster than that. So match the speed to the legs instead: 1.1 → 220, 0.65 → 130.
local SPEED_PER_LEG_RATE, CROUCH_ANIM_SPEED = 200, 132
local function animate(e, now)
    local bot = e.bot
    -- Posture, every frame: the tree crouches between updates. In cover only low cover crouches (to hide);
    -- otherwise crouches are cut short by standUntil. (NavAgentProps.bCanCrouch can't be written from Lua.)
    local c = e.cover
    local wantCrouch
    if c and c.state ~= "moving" then wantCrouch = c.low and c.state == "hiding"
    elseif c or e.standUntil then wantCrouch = false end
    local crouched = bot.bIsCrouched -- read once: Crouch() only takes effect on the next movement tick anyway
    if wantCrouch ~= nil and crouched ~= wantCrouch then
        if wantCrouch then bot:Crouch(false) else bot:UnCrouch(false) end
    end

    -- The pawn's components are kept on the entry (reapDead drops them with the pawn): every read of bot.Mesh or
    -- bot.CharacterMovement makes a new UE4SS object (with a finalizer), and this runs per bot per frame. The anim
    -- instance isn't kept: a new skeletal mesh (female.lua) can replace it.
    local mesh, move = e.mesh, e.move
    if not mesh then
        mesh, move = bot.Mesh, bot.CharacterMovement
        e.mesh, e.move = mesh, move
    end
    local anim = mesh:GetAnimInstance()
    if not valid(anim) then return end
    local v = bot:GetVelocity()
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
    -- The blueprint's leg rates make for a slow 220 walk / 130 aiming walk. Play the whole body faster while
    -- moving and scale the speed to match, so soldiers move briskly without their feet sliding.
    -- The tree's own shuffle input creeps a standing soldier along at a few units/s with its legs walking.
    if speed > 0 and speed < CFG.STUCK_SPEED and valid(e.ctrl) and e.ctrl:GetMoveStatus() ~= 3 then
        move:StopMovementImmediately()
        speed = 0
    end
    -- Running to cover: the AI anim blueprint has no run cycle, so play the player's base sprint on its
    -- FullBodyCinematic slot (combat montages use DefaultSlot and would cut it off).
    local inv = e.investigate
    local running = (c and c.state == "moving" and c.run) or (inv and inv.state == "go" and inv.run)
        or (e.followRun and not e.fighting) or (e.meleeRun and e.fighting)
    local sprinting = running and speed > 150
    if sprinting and not e.sprintAnim then
        local seq = lib(CFG.SPRINT_ANIM)
        if valid(seq) then
            anim:PlaySlotAnimationAsDynamicMontage(seq, FName("FullBodyCinematic"), 0.15, 0.2, 1.0, 1000, -1, 0)
            e.sprintAnim = true
        end
    elseif not sprinting and e.sprintAnim then
        anim:StopSlotAnimation(0.2, FName("FullBodyCinematic"))
        e.sprintAnim = false
    end
    -- Feet match the ground: the body plays at (actual speed / the speed its leg cycle was made for). A fixed
    -- speed-up per mode cycled the legs 2-10x too fast whenever the real speed fell short of the target: side-steps
    -- (the strafe cap, see AI.tuneBody), crouch-walking (crouched speed isn't raised), and sprinting while aiming
    -- (the game's aim modifier holds a 550 run to ~330). Smoothed so the gait doesn't flicker frame to frame.
    local rate = anim.Standing_LegsPlayrate
    if not (rate and rate > 0) then rate = 1.1 end
    local natural = running and CFG.SPRINT_SPEED or crouched and CROUCH_ANIM_SPEED or SPEED_PER_LEG_RATE * rate
    local want = speed > 30 and math.max(0.6, math.min(CFG.LEG_RATE_MAX, speed / natural)) or 1
    -- settles in ~0.1 s whatever the rate (a half step per 1/30 s)
    local k = 1 - 0.5 ^ (math.min(now - (e.animAt or now - 1 / 30), 0.2) * 30)
    e.animAt = now
    e.animScale = (e.animScale or 1) + (want - (e.animScale or 1)) * k
    mesh.GlobalAnimRateScale = e.animScale
    -- That scale is for the legs. The gun's own montage (bolt, pump, recoil) plays at 1.0 on its mesh, so the arms'
    -- matching montage is held at 1.0 too or the two drift apart while the bot moves.
    if not e.sprintAnim and math.abs(e.animScale - 1) > 0.02 then
        local m = anim:GetCurrentActiveMontage()
        if valid(m) then anim:Montage_SetPlayRate(m, 1 / e.animScale) end
    end
    -- The top speed is worked out in `walk` and written once at the end (it was up to four writes and two reads).
    local walk
    if running then
        walk = CFG.SPRINT_SPEED
    elseif crouched then
        anim.Crouching_Legs_Playrate = 1
    else
        -- top speed: brisker than the blueprint's slow walk, faster still when strafing in a fight
        local base = ((not c or c.state == "moving") and e.fighting and e.los) and CFG.STRAFE_ANIM_SCALE
            or CFG.MOVE_ANIM_SCALE
        walk = SPEED_PER_LEG_RATE * rate * base
    end
    -- Stepping between the cover spot and its firing point: fast, with no sideways speed cap (AI.tuneBody's
    -- strafe factor would hold the 60 unit side-step to ~110/s).
    local step = c and c.peekPos and ((c.state == "peeking" and c.peekPos) or (c.state == "hiding" and c.pos))
    local quick = step and dist2d(bot:K2_GetActorLocation(), step) > 12
    if quick ~= e.quickStep then
        e.quickStep = quick
        e.baseAccel = e.baseAccel or move.MaxAcceleration
        move.MaxAcceleration = quick and CFG.PEEK_ACCEL or e.baseAccel
        move.MaxMoveBackAndStrafeSpeed = quick and 1 or (e.mind and e.mind.profile.strafe or 0.6)
    end
    if quick then walk = CFG.PEEK_SPEED end
    -- The game slows an aiming bot to half its top speed (measured: forward x 0.5, sideways x 0.5 x the strafe cap),
    -- so fights were walked at 75-95 and strafed at 115-145 while you walk at 280. Every speed above is meant as the
    -- real one. Crouched speed isn't set here each frame, so it's left alone.
    local targeting = not running and not crouched and bot:IsTargeting()
    if targeting then
        walk = walk / CFG.AIM_SLOWDOWN
    end
    -- No faster than the legs can carry them at LEG_RATE_MAX (the aim slowdown is divided out the same way).
    if not running and not crouched then
        local cap = natural * CFG.LEG_RATE_MAX / (targeting and CFG.AIM_SLOWDOWN or 1)
        if walk > cap then walk = cap end
    end
    if walk then move.MaxWalkSpeed = walk end
end

local function trackTargets()
    if not raid.spawned then return end
    reapDead()
    -- Every bot animates ANIM_HZ_LOW times a second, ANIM_HZ_HIGH while the game runs faster than ANIM_HI_FPS: the
    -- pose follows the director's inputs (gait, speed, posture) as often as it can be told apart. The frame rate is
    -- measured here (smoothed, with a margin so it doesn't flip between the two). A call is ~a dozen engine reads and
    -- writes (~1.2 ms a frame and 3 MB of garbage a second for 20 bots every frame, profile.txt 2026-11-14), so at
    -- most ANIM_BUDGET run in one frame, starting where the last frame stopped so no bot starves.
    -- reapDead has just checked every bot in raid.bots is valid and alive and dropped the rest, and nothing is freed
    -- before the frame ends: the loops below don't ask the engine again (two calls per bot per loop, every frame).
    local now = os.clock()
    local dt = now - (raid.trackAt or now)
    raid.trackAt = now
    if dt > 0 and dt < 0.25 then raid.fps = raid.fps and (raid.fps + (1 / dt - raid.fps) * 0.05) or 1 / dt end
    local fps, hz = raid.fps or 60, raid.animHz or CFG.ANIM_HZ_LOW
    if fps > CFG.ANIM_HI_FPS + 5 then hz = CFG.ANIM_HZ_HIGH elseif fps < CFG.ANIM_HI_FPS - 5 then hz = CFG.ANIM_HZ_LOW end
    raid.animHz = hz
    local bots, step = raid.bots, 1 / hz
    local n, left, from = #bots, CFG.ANIM_BUDGET, raid.animFrom or 0
    local nextFrom = from + 1
    for k = 1, n do
        local e = bots[(from + k - 1) % n + 1]
        local due = e.animNext or 0
        if now >= due and not e.parked then
            if left <= 0 then nextFrom = from + k - 1 break end
            left = left - 1
            -- on a grid of 1/hz (not now + 1/hz), so a rate near the frame rate isn't halved by rounding up to a frame
            e.animNext = due > now - step and due + step or now + step
            animate(e, now)
        end
    end
    raid.animFrom = n > 0 and nextFrom % n or 0
    for _, e in ipairs(raid.bots) do
        -- Hide / lean out on time to the frame, not on the 0.5 s update.
        local c = e.cover
        local alive = not e.parked
        if c and e.fighting and alive and valid(e.ctrl) and c["until"] and now >= c["until"] then
            if c.state == "hiding" then peek(e, c, now) elseif c.state == "peeking" then hide(e, c, now) end
        end
        local state = e.cover and e.cover.state
        local sprinting = state == "moving" and e.cover.run
        -- A reload done (M.botShot): a full clip again.
        if e.reloadUntil and now >= e.reloadUntil then
            e.reloadUntil = nil
            pcall(function() e.bot.CurrentWeapon.CurrentAmmoInClip = e.mag or 30 end)
        end
        -- Reaction time over: open fire, unless cover says hold it (running to cover, hiding).
        if e.holdUntil and now >= e.holdUntil and valid(e.ctrl) and not (e.reloadUntil and now < e.reloadUntil) then
            e.holdUntil = nil
            local pawn = foeOf(e)
            if e.inCombat and pawn and state ~= "hiding" and not sprinting then setEnemy(e, pawn) end
        end
        -- Aim upkeep, hz a second (focus is kept by the controller between calls), or at once when what the bot
        -- should be doing changes. Only the aiming pose follows the aim up and down, and only it plays the arms' firing
        -- montage. The native shooting code turns it on now and then: from the hip a bot shoots at you with its gun
        -- level or pointing down.
        local want = (e.fighting and not sprinting and state ~= "hiding") and true or false
        if alive and (now >= (e.aimNext or 0) or want ~= e.aimWant) then
            -- (at peace: ANIM_PEACE_HZ; nothing changes until want does, which is caught at once)
            e.aimNext, e.aimWant = now + 1 / ((want or e.fighting) and hz or CFG.ANIM_PEACE_HZ), want
            local pawn = foeOf(e)
            local aiming = (want and pawn) and true or false
            if e.bot:IsTargeting() ~= aiming then e.bot:ServerSetTargeting(aiming) end
            if e.fighting and pawn and valid(e.ctrl) and not sprinting then
                if e.los then
                    e.ctrl:K2_SetFocus(pawn)
                    e.ctrl.LastKnownPlayerPosition = pawn:K2_GetActorLocation()
                elseif e.lastSeen then
                    e.ctrl:K2_SetFocalPoint(e.lastSeen)
                end
            end
        end
    end
end

-- Station garrisons on space maps: stations streamed into a space map have no soldiers (only the game's sleeping
-- placeholder raiders), so the first time you walk into one, it gets a garrison like a raid map: soldiers at its AI
-- spawn nodes (RaidAINodeStart inside the station), else at random walkable spots, never close to you.
local function spawnGarrison(pc, box, name, count)
    count = count or CFG.GARRISON
    local foot = raid.target
    local here = valid(foot) and foot:K2_GetActorLocation() or nil
    local function inside(l)
        return math.abs(l.X - box.c.X) <= box.e.X + 1500 and math.abs(l.Y - box.c.Y) <= box.e.Y + 1500
            and math.abs(l.Z - box.c.Z) <= box.e.Z + 1500
    end
    local spots = {}
    for _, n in ipairs(FindAllOf("RaidAINodeStart") or {}) do
        if valid(n) then
            local l = n:K2_GetActorLocation()
            if inside(l) and (not here or dist(l, here) >= CFG.MIN_SPAWN_DIST) then spots[#spots + 1] = l end
        end
    end
    local fromNodes = #spots
    for _ = 1, count * 3 do
        if #spots >= count then break end
        local out = {}
        if Out.call(navLib(), "K2_GetRandomReachablePointInRadius", pc, box.c, out, math.max(box.e.X, box.e.Y), navMesh(),
            queryFilter()) and out.X and (not here or dist(out, here) >= CFG.MIN_SPAWN_DIST) and not offLimits(out) then
            spots[#spots + 1] = { X = out.X, Y = out.Y, Z = out.Z }
        end
    end
    -- Spawned one per update (spawnQueued), not all at once: a burst of actor spawns inside the tick hook (with a
    -- rival crew materializing in the same tick) crashed the game once in UE4SS's hook dispatch.
    raid.spawnQueue = raid.spawnQueue or {}
    for i = 1, math.min(count, #spots) do table.insert(raid.spawnQueue, spots[i]) end
    log(("%s garrison: %d soldiers coming (%d at AI nodes)"):format(name, math.min(count, #spots),
        math.min(count, fromNodes)))
end

local function spawnQueued(pc)
    local q = raid.spawnQueue
    if q and #q > 0 then spawnBot(pc, table.remove(q, 1), math.random(0, 359)) end
end

M.PLAYER = PLAYER
M.arm, M.engage, M.spawnBot, M.spawnRaidBots = arm, engage, spawnBot, spawnRaidBots
M.updateBots, M.trackTargets, M.spawnGarrison, M.spawnQueued = updateBots, trackTargets, spawnGarrison, spawnQueued

return M
