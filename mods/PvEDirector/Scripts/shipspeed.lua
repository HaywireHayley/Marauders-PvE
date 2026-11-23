-- Ship speed (#207): the Rustbucket was too slow to cross a map in a raid's time.
-- 1. The Rustbucket (Ship_StarterFrigate01_Pawn_C: only ever your own ship; rival Rustbuckets are Scout pawns) flies
--    RUSTBUCKET_SPEED x faster and accelerates RUSTBUCKET_ACCEL x quicker.
-- 2. A boost at the helm of the Rustbucket only, like the drop pod's (its own is native ServerBoost, 4 s, then a 12 s
--    cooldown, on ARaidSpaceship; frigates are ARaidFrigate and have none), held, not toggled: the key bound to Run (Shift) while piloting.
--    Space is the game's ship up (MoveUp axis), so it can't be the boost key.
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

-- The drop pod's own boost sounds (Ship_DropPod_Pawn): a one shot as it starts, an engine loop while it lasts, a one shot
-- as it ends. All three are SoundCues. They play 2D, since the pilot is the only one who hears the boost, and the loop is
-- the audio component SpawnSound2D returns, so letting go of the key can stop it.
local SOUND = {
    start = "/Game/Sounds/Ships/EF_ShipPod_Boosting_OneShot",
    loop = "/Game/Sounds/Ships/EF_ShipPod_Boosting_EngineLoop",
    stop = "/Game/Sounds/Ships/EF_ShipPod_BoostEnd_OneShot01",
}
local cues, loopComp = {}, nil

local function cue(key)
    local c = cues[key]
    if c and valid(c) then return c end
    local path = SOUND[key]
    local full = path .. "." .. path:match("[^/]+$")
    c = StaticFindObject(full)
    if not valid(c) then pcall(LoadAsset, path) c = StaticFindObject(full) end
    if valid(c) then cues[key] = c return c end
    return nil
end

local function play(pc, key)
    local sound = cue(key)
    if not sound then return nil end
    local comp
    pcall(function()
        comp = StaticFindObject("/Script/Engine.Default__GameplayStatics"):SpawnSound2D(pc, sound, 1.0, 1.0, 0.0, nil, false, true)
    end)
    return comp
end

local function stopLoop()
    local c = loopComp
    loopComp = nil
    if c and valid(c) then pcall(function() c:Stop() end) end
end

local onRustbucket = false -- set by update (twice a second), so the per frame key poll costs nothing in any other ship

-- The boost is over (key let go, the 4 s used up, or the helm left): normal speed, the loop stops, the end sound plays, and
-- the cooldown counts from now.
local function endBoost(pc, ship, why)
    local now = os.clock()
    boost.on = false
    boost.untilT = now
    boost.readyAt = now + CFG.BOOST_COOLDOWN
    if ship then pcall(apply, ship, false) end
    stopLoop()
    if why ~= "helm" then
        play(pc, "stop")
        tell(pc, why == "spent" and ("Boost spent: ready again in %d s"):format(CFG.BOOST_COOLDOWN)
            or ("Boost off: ready again in %d s"):format(CFG.BOOST_COOLDOWN))
    end
end

-- From main.lua's update (every UPDATE_SECONDS) on a space map.
function M.update(pc)
    lastPc = pc
    local ship = shipOf(pc)
    if not ship then
        onRustbucket = false
        if boost.on then endBoost(pc, nil, "helm") end
        return
    end
    onRustbucket = ship:GetClass():GetFName():ToString() == RUSTBUCKET
    if boost.on and os.clock() >= boost.untilT then endBoost(pc, ship, "spent") end
    apply(ship, boost.on)
end

-- The boost key: whatever the game has bound to Run (Shift by default, Input.ini ActionMappings, so a remap follows).
-- Run is an on foot action (nothing at a frigate's helm that we know of) and this UE4SS has no Shift key for RegisterKeyBind
-- (only Shift as a modifier), so main.lua's per frame tick asks whether it is held: pressing it starts the boost and
-- letting go ends it (the 4 s still ends it if you hold on). Space is the game's ship up (MoveUp), which is why it was
-- taken off this.
local Keys = require("keys")
local held, polledAt = false, 0
function M.frame(pc)
    if not (onRustbucket or boost.on) then held = false return end
    local now = os.clock()
    if now - polledAt < 0.04 then return end
    polledAt = now
    if not valid(pc) then return end
    lastPc = pc
    local down = false
    if not pc.bShowMouseCursor then down = Keys.down(pc, "Run", "LeftShift") end
    if down and not held then M.boost() end
    held = down
    if boost.on then
        local ship = shipOf(pc)
        if not ship then
            endBoost(pc, nil, "helm")
        elseif not down then
            endBoost(pc, ship, "released")
        elseif now >= boost.untilT then
            endBoost(pc, ship, "spent")
        end
    end
end

function M.boost()
    local pc = lastPc
    local ship = valid(pc) and shipOf(pc)
    if not ship then return end
    if ship:GetClass():GetFName():ToString() ~= RUSTBUCKET then return end -- the Rustbucket's boost only
    require("gatetaps").tap() -- a press at the helm may be a gate tap (#332)
    local now = os.clock()
    if boost.on then return end
    if now < boost.readyAt then
        return tell(pc, ("Boost recharging: %d s"):format(math.ceil(boost.readyAt - now)))
    end
    boost.untilT = now + CFG.BOOST_SECONDS
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
    stopLoop()
    play(pc, "start")
    loopComp = play(pc, "loop")
    tell(pc, "BOOST")
    log(("ship boost: %s, up to %d s while the key is held"):format(ship:GetClass():GetFName():ToString(), CFG.BOOST_SECONDS))
end

-- A new raid: the next boost is ready at once.
function M.reset()
    stopLoop()
    boost = { untilT = 0, readyAt = 0, on = false }
    lastPc = nil
    onRustbucket = false
    held = false
    require("gatetaps").reset()
end

return M
