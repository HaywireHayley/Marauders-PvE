-- Recoil as the weapon data says (issue #371). Measured with tools/recoil_test on the automatic guns, the single shot guns and the pistols:
--   * aim down sights: the game kicks the view by a figure of its own, never VerticalRecoilADS. For the automatic guns held down it is
--     1.25 degrees for every point of VerticalRecoil (so the Jackhammer, 0.3 ADS, kicks like a 2.0 gun), but clicked one shot at a time
--     it differs from gun to gun: the Trench gun, Johnson, Welrod and Terminator get the full 1.25 * VerticalRecoil, the Reising, M1 Para,
--     AC14, SVT, the 1911s, the P08 and the M712 a fraction of it, and the Liberators anything from nothing to three degrees, shot by shot.
--   * the hip: no kick to the view at all, whatever the gun's VerticalRecoil.
-- The game does this in native code that writes the view directly, so there is nothing to hook before it. This adds what is missing, on
-- the view, for every shot you fire: at the hip the whole climb, aimed the difference between the climb the weapon data asks for and
-- the climb the game gave. The game's climb is MEASURED for every shot, as the movement of the view around the shot (less what this file
-- itself added), because it cannot be worked out from the weapon. Horizontal kick at the hip is the gun's own HorizontalRecoilMin to Max.
--
-- What each shot should climb (degrees), D = 1.25:
--   aimed   D * VerticalRecoilADS      (topped up, or cut, by what the game's own kick measured)
--   hip     D * VerticalRecoil         (the game gave nothing), times the crouch, moving and in air modifiers of the weapon
-- Both times RECOIL_SCALE (F3 Recoil), the hip also times HIP_SCALE.
local M = {}
local log, valid

local CFG = {
    RECOIL_FIX = 1,   -- 1 = the weapon data's recoil, 0 = the game's own (aimed only, the hip values ignored)
    ADS_VALUES = 1,   -- 1 = aimed shots use VerticalRecoilADS, 0 = they use VerticalRecoil like the game
    HIP_KICK = 1,     -- 1 = shots at the hip kick the view, 0 = they don't (the game's own)
    RECOIL_SCALE = 1, -- every gun's recoil times this (0.5 = half, 2 = double), aimed and hip
    HIP_SCALE = 1,    -- the hip's share on top of that
}
M.CFG = CFG

local DEGREES = 1.25 -- degrees of climb per point of VerticalRecoil (measured on 28 guns, steady over 5 shots)
local BLEND = 0.04   -- seconds the game's own kick takes to land
local FAST = 100     -- cm/s: faster than this is "moving"

-- Measuring the game's own aimed kick: it lands within about 0.1 s of the shot hook, a little before it or a little after.
local LEAD = 0.04    -- seconds before the hook the measuring starts
local SETTLE = 0.12  -- seconds after the hook it ends (a shot is topped up then)
local HISTORY = 0.4  -- seconds of view history kept

local pitchPending, yawPending, last = 0, 0, nil
local ownSum = 0     -- what this file has added to the view pitch so far (taken off again when measuring)
local hist = {}      -- { time, view pitch less ownSum } every frame, newest last
local shots = {}     -- aimed shots waiting to be measured: { t, want, cap }
local lastEnd = 0    -- where the last measured shot's window ended

function M.init(ctx) log, valid = ctx.log, ctx.valid end

local function num(f, d)
    local ok, v = pcall(f)
    if ok and type(v) == "number" then return v end
    return d
end

-- The weapon modifier for the way the player is standing (the hip's whole kick is scaled by it, like the wiki's crouch multipliers).
local function stateModifier(pawn, c)
    local m = 1
    if pawn.bIsCrouched then m = m * num(function() return c.recoilModifier.Crouching end, 1) end
    local v = num(function() local vel = pawn:GetVelocity() return math.sqrt(vel.X * vel.X + vel.Y * vel.Y) end, 0)
    if v > FAST then m = m * num(function() return c.recoilModifier.Moving end, 1) end
    if num(function() return pawn.CharacterMovement:IsFalling() and 1 or 0 end, 0) == 1 then m = m * num(function() return c.recoilModifier.InAir end, 1) end
    return m
end

-- The difference between two view pitches in degrees, the short way round (the view's pitch wraps at 360).
local function delta(a, b) return ((b - a + 540) % 360) - 180 end

-- The view pitch (less what this file added) at the last sample taken at or before time t.
local function pitchAt(t)
    for i = #hist, 1, -1 do
        if hist[i][1] <= t then return hist[i][2] end
    end
    return nil
end

local function onShot(w)
    if CFG.RECOIL_FIX ~= 1 then return end
    local pawn = w.MyPawn
    if not (valid(pawn) and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return end
    local c = w.WeaponConfig
    local v = num(function() return c.VerticalRecoil end, 0)
    local va = num(function() return c.VerticalRecoilADS end, v)
    local scale = CFG.RECOIL_SCALE
    if pawn:IsTargeting() then
        -- (recoilModifier.Aiming is not part of what the game gave: the Welrod and SPP-1 have 6.0, the Obrez and Sawed-off 3.0, and they kick
        -- 1.25 * VerticalRecoil all the same)
        local want = DEGREES * (CFG.ADS_VALUES == 1 and va or v) * scale
        shots[#shots + 1] = { t = os.clock(), want = want, cap = DEGREES * v * 1.5 + 0.5 }
    elseif CFG.HIP_KICK == 1 then
        local k = scale * CFG.HIP_SCALE * stateModifier(pawn, c)
        pitchPending = pitchPending + DEGREES * v * k
        local lo, hi = num(function() return c.HorizontalRecoilMin end, 0), num(function() return c.HorizontalRecoilMax end, 0)
        yawPending = yawPending + (lo + math.random() * (hi - lo)) * k
    end
end

-- The shot hook goes on from the first frame in a raid, never while the script loads: the weapon class is not there yet at load.
local function hookShots()
    if package.loaded["recoil.hook"] then return end
    package.loaded["recoil.hook"] = true
    local ok, err = pcall(RegisterHook, "/Script/RaidGame.RaidWeapon:ServerMultiSimulateWeaponFire", function(ctx)
        pcall(function() onShot(ctx:get()) end)
    end)
    if not ok then print("[PvEDirector] recoil: shot hook failed: " .. tostring(err) .. "\n") end
end

-- Aimed shots whose window has passed: the game's own kick is the movement of the view over the shot's window, and the shot is topped
-- up (or cut) to what the weapon data asks for. A window never reaches into the one before it.
local function measure(now)
    while shots[1] and now >= shots[1].t + SETTLE do
        local s = table.remove(shots, 1)
        local a, b = math.max(s.t - LEAD, lastEnd), s.t + SETTLE
        if shots[1] then b = math.min(b, shots[1].t - LEAD) end
        if b > a then
            local pa, pb = pitchAt(a), pitchAt(b)
            if pa and pb then
                local gave = math.max(0, math.min(s.cap, delta(pa, pb)))
                pitchPending = pitchPending + (s.want - gave)
            end
        end
        lastEnd = math.max(lastEnd, b)
    end
end

-- Every frame in a raid: the view is sampled, the aimed shots are measured, and the pending climb goes onto the view over BLEND seconds.
function M.frame(pc)
    hookShots()
    local now = os.clock()
    local dt = math.min(0.1, now - (last or now))
    last = now
    local r = pc:GetControlRotation()
    hist[#hist + 1] = { now, r.Pitch - ownSum }
    while hist[1] and hist[1][1] < now - HISTORY do table.remove(hist, 1) end
    measure(now)
    if math.abs(pitchPending) < 1e-4 and math.abs(yawPending) < 1e-4 then
        pitchPending, yawPending = 0, 0
        return
    end
    local f = math.min(1, dt / BLEND)
    local dp, dy = pitchPending * f, yawPending * f
    pitchPending, yawPending = pitchPending - dp, yawPending - dy
    ownSum = ownSum + dp
    pc:SetControlRotation({ Pitch = r.Pitch + dp, Yaw = r.Yaw + dy, Roll = r.Roll })
end

-- A new raid starts with nothing pending.
function M.reset() pitchPending, yawPending, last, ownSum, hist, shots, lastEnd = 0, 0, nil, 0, {}, {}, 0 end

return M
