-- Ship speed (#207): the Rustbucket was too slow to cross a map in a raid's time.
-- 1. The Rustbucket (Ship_StarterFrigate01_Pawn_C: only ever your own ship; rival Rustbuckets are Scout pawns) flies
--    RUSTBUCKET_SPEED x faster and accelerates RUSTBUCKET_ACCEL x quicker.
-- 2. A boost at the helm of any frigate, like the drop pod's (its own is native ServerBoost, 4 s, then a 12 s
--    cooldown, on ARaidSpaceship; frigates are ARaidFrigate and have none): Space while piloting.
-- Measured 2026-11-19 (Space_Alpha, the Rustbucket possessed, W held): the top speed is the movement component's
-- MaxFlySpeed (1000 cm/s, reached in ~4 s at MaxAcceleration 256). Class defaults: Rustbucket, Scout, Frigate 1000 / 256;
-- Fast and VIP 1100 / 512; Red Baron's strike frigate 1200 / 512; Capital 1000 / 512; drop pod 800 / 1024.
-- Offline the game is the authority, so writing the component is enough. Co-op: a joiner's own boost would be undone by
-- the host's movement (not handled).
local M = {}
local log, valid

local CFG = {
    RUSTBUCKET_SPEED = 1.25, -- 1000 -> 1250 cm/s: past the Fast frigate (1100), behind the Baron's (1200 x boost)
    RUSTBUCKET_ACCEL = 1.5,  -- 256 -> 384: up to speed in ~3 s instead of ~4
    BOOST_SPEED = 1.8,       -- top speed while boosting
    BOOST_ACCEL = 4,         -- acceleration while boosting (it has to get there within the boost)
    BOOST_SECONDS = 4,       -- as the pod's
    BOOST_COOLDOWN = 12,     -- as the pod's, counted from the end of the boost
}
M.CFG = CFG

local RUSTBUCKET = "Ship_StarterFrigate01_Pawn_C"
local frigateClass
local defaults = {} -- class name -> { fly, acc } from the class default object
local boost = { untilT = 0, readyAt = 0, on = false }
local lastPc

function M.init(ctx) log, valid = ctx.log, ctx.valid end

local function tell(pc, text) pcall(function() pc:ClientMessage(text, FName("Event"), 2.5) end) end

-- The frigate you're flying, or nil.
local function shipOf(pc)
    local p = valid(pc) and pc.Pawn
    if not (p and valid(p)) then return nil end
    frigateClass = frigateClass and valid(frigateClass) and frigateClass or StaticFindObject("/Script/RaidGame.RaidFrigate")
    if not valid(frigateClass) or not p:IsA(frigateClass) then return nil end
    return p
end

local function baseOf(ship)
    local cls = ship:GetClass()
    local name = cls:GetFName():ToString()
    local b = defaults[name]
    if not b then
        local d = cls:GetCDO()
        local m = valid(d) and d.CharacterMovement
        if not (m and valid(m)) then return nil, name end
        b = { fly = m.MaxFlySpeed, acc = m.MaxAcceleration }
        defaults[name] = b
    end
    return b, name
end

local function apply(ship, boosting)
    local b, name = baseOf(ship)
    if not b then return end
    local rust = name == RUSTBUCKET
    local fly = b.fly * (rust and CFG.RUSTBUCKET_SPEED or 1) * (boosting and CFG.BOOST_SPEED or 1)
    local acc = b.acc * (rust and CFG.RUSTBUCKET_ACCEL or 1) * (boosting and CFG.BOOST_ACCEL or 1)
    local m = ship.CharacterMovement
    if not valid(m) then return end
    if math.abs(m.MaxFlySpeed - fly) > 1 then m.MaxFlySpeed = fly end
    if math.abs(m.MaxAcceleration - acc) > 1 then m.MaxAcceleration = acc end
end

-- From main.lua's update (every UPDATE_SECONDS) on a space map.
function M.update(pc)
    lastPc = pc
    local ship = shipOf(pc)
    if not ship then
        boost.on = false
        return
    end
    local boosting = os.clock() < boost.untilT
    if boost.on and not boosting then tell(pc, ("Boost spent: ready again in %d s"):format(CFG.BOOST_COOLDOWN)) end
    boost.on = boosting
    apply(ship, boosting)
end

-- Space (main.lua's key binding, on the game thread).
function M.boost()
    local pc = lastPc
    local ship = valid(pc) and shipOf(pc)
    if not ship then return end -- on foot: Space is the game's jump
    local now = os.clock()
    if now < boost.untilT then return end
    if now < boost.readyAt then
        return tell(pc, ("Boost recharging: %d s"):format(math.ceil(boost.readyAt - now)))
    end
    boost.untilT = now + CFG.BOOST_SECONDS
    boost.readyAt = boost.untilT + CFG.BOOST_COOLDOWN
    boost.on = true
    apply(ship, true)
    -- Raising the top speed alone barely helps: the ship gains speed slowly (1250 -> 1440 cm/s in 4 s, measured; the
    -- thrust ramps, not MaxAcceleration). So the boost starts at full speed, along where you're going (or where the
    -- nose points, from a standstill), and the raised top speed keeps it there while you hold W.
    pcall(function()
        local m = ship.CharacterMovement
        local v = ship:GetVelocity()
        local len = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
        local d = len > 100 and { X = v.X / len, Y = v.Y / len, Z = v.Z / len } or ship:GetActorForwardVector()
        local top = m.MaxFlySpeed
        m.Velocity = { X = d.X * top, Y = d.Y * top, Z = d.Z * top }
    end)
    tell(pc, "BOOST")
    log(("ship boost: %s for %d s"):format(ship:GetClass():GetFName():ToString(), CFG.BOOST_SECONDS))
end

-- A new raid: the next boost is ready at once.
function M.reset()
    boost = { untilT = 0, readyAt = 0, on = false }
    lastPc = nil
end

return M
