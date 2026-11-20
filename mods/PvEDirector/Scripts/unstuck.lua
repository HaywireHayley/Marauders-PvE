-- Unstuck and no collision (#198), two F9 buttons.
-- Unstuck: back at the last spot you walked through on solid ground at least BACK_AT_LEAST s ago (a spot is kept each
--   time you've walked STEP further, so standing wedged somewhere doesn't push the good ones out); with none, the
--   nearest walkable floor (the navmesh within a few metres). Spots first: under the map the nearest navmesh can be a
--   floor below it (Spaceport_01 has walkable floor 17 m under the play area, tested 2026-11-19). A cooldown keeps it
--   from being a free escape.
-- No collision: walk through walls and fly (look up or down to rise or sink while moving). A test cheat like god
--   mode, not a player feature: it's off at every map change.
-- Offline you're the authority, so moving your own pawn is enough. Co-op: only the host's own body (a joiner's would
-- need the host to move it).
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local M = {}
local log, valid, navLib, navMesh, queryFilter

local CFG = {
    COOLDOWN = 30,          -- s between two unstucks
    SAMPLE_EVERY = 1,       -- s between looks at where you stand
    STEP = 150,             -- cm walked since the last kept spot before another is kept
    KEEP = 10,              -- spots kept
    BACK_AT_LEAST = 6,      -- s: the fallback spot is at least this old (the newest ones may be where you got stuck)
    SEARCH = { X = 400, Y = 400, Z = 500 }, -- how far to look for walkable floor
    SAME_SPOT = 100,        -- cm across, and SAME_HEIGHT up or down: floor this close is where you already are
    SAME_HEIGHT = 200,      -- (a navmesh point sits up to ~1 m above the floor: measured 108 cm on Spaceport_01)
    NOCLIP_SPEED = 1200,    -- cm/s flying with no collision
    NOCLIP_BRAKE = 4000,    -- cm/s2 stopping when you let go (the game's flying braking is 0: you drifted on, tested)
}
M.CFG = CFG

local MOVE_WALKING, MOVE_FALLING, MOVE_FLYING = 1, 3, 5
local spots, lastSample, readyAt = {}, 0, 0
local ghost -- { addr, fly, brake } while no collision is on (by address: two wrappers of one pawn aren't ==)

function M.init(ctx)
    log, valid = ctx.log, ctx.valid
    navLib, navMesh, queryFilter = ctx.navLib, ctx.navMesh, ctx.queryFilter
end

local function onFoot(pc)
    local p = valid(pc) and pc.Pawn
    if not (p and valid(p)) then return nil end
    local ok, name = pcall(function() return p:GetClass():GetFName():ToString() end)
    return ok and name == "PlayerPawn_C" and p or nil
end

local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function across(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

-- Every frame in a raid (main.lua): where you stand, and flying while no collision is on.
function M.update(pc)
    local pawn = onFoot(pc)
    if not pawn then return end
    local move = pawn.CharacterMovement
    if not valid(move) then return end
    if ghost then
        if ghost.addr ~= pawn:GetAddress() then ghost = nil return end -- a new body (map change, death): it has collision
        -- The game's input moves you level; the camera's pitch adds the climb or the dive.
        local v = move.Velocity
        local flat = math.sqrt(v.X * v.X + v.Y * v.Y)
        local pitch = math.rad(pc.ControlRotation.Pitch > 180 and pc.ControlRotation.Pitch - 360 or pc.ControlRotation.Pitch)
        move.Velocity = { X = v.X, Y = v.Y, Z = flat > 10 and flat * math.tan(math.max(-1.2, math.min(1.2, pitch))) or 0 }
        return
    end
    local now = os.clock()
    if now - lastSample < CFG.SAMPLE_EVERY then return end
    lastSample = now
    if move.MovementMode ~= MOVE_WALKING then return end
    local at = pawn:K2_GetActorLocation()
    if #spots > 0 and dist(spots[#spots], at) < CFG.STEP then return end
    table.insert(spots, { X = at.X, Y = at.Y, Z = at.Z, t = now })
    if #spots > CFG.KEEP then table.remove(spots, 1) end
end

local function floorNear(pc, at)
    local out = {}
    local ok = Out.call(navLib(), "K2_ProjectPointToNavigation", pc, at, out, navMesh(), queryFilter(), CFG.SEARCH)
    return ok and out.X and { X = out.X, Y = out.Y, Z = out.Z } or nil
end

local function goTo(pawn, to, rot)
    pcall(function() pawn.CharacterMovement:StopMovementImmediately() end)
    return pawn:K2_TeleportTo(to, rot)
end

function M.unstuck()
    local pc = FindFirstOf("PlayerController")
    local pawn = onFoot(pc)
    if not pawn then return "Only on foot" end
    if ghost then return "Turn no collision off first" end
    local now = os.clock()
    if now < readyAt then return ("Again in %d s"):format(math.ceil(readyAt - now)) end
    local at, rot = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
    local half = 90
    pcall(function() half = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    local to, how
    for i = #spots, 1, -1 do
        local s = spots[i]
        if now - s.t >= CFG.BACK_AT_LEAST and dist(s, at) > 100 then
            to, how = { X = s.X, Y = s.Y, Z = s.Z - half }, "Back where you stood"
            break
        end
    end
    if not to then
        local floor = floorNear(pc, at)
        local here = floor and across(floor, at) <= CFG.SAME_SPOT and math.abs(floor.Z - (at.Z - half)) <= CFG.SAME_HEIGHT
        if floor and not here then to, how = floor, "Moved to the nearest floor" end
    end
    if not to then return "Nowhere safe found nearby" end
    local dest = { X = to.X, Y = to.Y, Z = to.Z + half + 20 }
    local ok, moved = pcall(goTo, pawn, dest, rot)
    if not (ok and moved) then
        log(("unstuck: the move to %.0f,%.0f,%.0f was refused"):format(dest.X, dest.Y, dest.Z))
        return "Couldn't move you there"
    end
    readyAt = now + CFG.COOLDOWN
    log(("unstuck: %s, %.0f m (%.0f,%.0f,%.0f)"):format(how, dist(at, dest) / 100, dest.X, dest.Y, dest.Z))
    return how
end

function M.noclipOn() return ghost ~= nil end

function M.toggleNoclip()
    local pc = FindFirstOf("PlayerController")
    local pawn = onFoot(pc)
    if not pawn then return "Only on foot" end
    local move = pawn.CharacterMovement
    if ghost then
        pawn:SetActorEnableCollision(true)
        move.MaxFlySpeed = ghost.fly
        move.BrakingDecelerationFlying = ghost.brake
        move:SetMovementMode(MOVE_FALLING, 0)
        ghost = nil
        log("no collision OFF")
        return "Collision back on"
    end
    ghost = { addr = pawn:GetAddress(), fly = move.MaxFlySpeed, brake = move.BrakingDecelerationFlying }
    pawn:SetActorEnableCollision(false)
    move.MaxFlySpeed = CFG.NOCLIP_SPEED
    move.BrakingDecelerationFlying = CFG.NOCLIP_BRAKE
    move:SetMovementMode(MOVE_FLYING, 0)
    log("no collision ON")
    return "No collision: look up or down to fly"
end

-- A new map: the old spots are somewhere else, and the new body has its collision.
function M.reset()
    spots, lastSample, ghost = {}, 0, nil
end

function M.actions(inRaid)
    return {
        { id = "unstuck", label = "Unstuck", help = ("Back to where you last stood, or the nearest floor (%d s)"):format(CFG.COOLDOWN),
          when = inRaid, unusable = "Only on foot in a raid", run = M.unstuck },
        { id = "noclip", label = function() return "No collision: " .. (ghost and "ON" or "off") end,
          help = "Walk through walls and fly (off at every map change)",
          when = inRaid, unusable = "Only on foot in a raid", run = M.toggleNoclip },
    }
end

return M
