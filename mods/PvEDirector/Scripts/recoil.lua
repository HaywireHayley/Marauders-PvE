-- Recoil (issue #371). What the game does, measured with tools/recoil_test on every automatic gun, single shot gun and pistol with
-- this file switched off:
--   * the hip: no kick to the view at all, whatever the gun's VerticalRecoil.
--   * aimed: the view climbs by a fixed figure for each gun, the same on every shot, whatever the mouse does. It is never
--     VerticalRecoilADS. On the automatic guns it is 1.25 degrees for every point of VerticalRecoil; on most single shot guns and
--     pistols it is a fixed share of that (the table NATIVE below, one figure per gun).
-- The game does this in native code that writes the view directly, so there is nothing to hook before it. This file adds on the view
-- what the settings ask for on top of that, and with the settings left alone it adds nothing at all: the recoil is the game's own.
--
-- What each shot adds (degrees), D = 1.25, native = the game's own climb for that gun (NATIVE, times the muzzle and stock adjustment):
--   aimed   native * mult           minus native, so the shot climbs native * mult. mult = RECOIL_MULT * fire rate share * RECOIL_ADS_MULT
--   aimed   D * VerticalRecoilADS * mult, minus native, when ADS_VALUES is 1 (the weapon data's aimed figure instead of the game's)
--   hip     D * VerticalRecoil * mult * HIP_SCALE * the crouch, moving and in air modifiers, when HIP_KICK is 1 (the game gives none)
-- The game's aimed shots also drift sideways on its own (random on every shot: the automatics, the M16, the Terminator). That is
-- measured over the same kind of window, and each aimed shot adds (mult - 1) times it, so RECOIL_MULT 0 takes the drift out as well
-- and 2 doubles it. Hip shots have no drift of the game's own, and with HIP_KICK 1 they get the weapon data's sideways figure times mult.
-- A shot with the player turning fast just before it is left alone, and the correction is capped, so the player's own aim is not eaten.
-- A gun that is not in NATIVE is measured instead (the movement of the view around the shot), and only when a setting asks for a
-- change.
--
-- Settings names and the per gun field log are kept from build 36's recoil.lua (#371, #453), whose way of scaling the weapon's own
-- WeaponConfig is gone: it shrank VerticalRecoil, which this file reads as the weapon data, and the game's hip never read it at all.
-- The fire rate share (REF_INTERVAL, MIN_SCALE) is now a factor on the kick this file adds. MIN_SCALE 1 = no fire rate share (the
-- game's own). The muzzle and stock add their own recoil adjustment to the weapon's value in the game (#453, vertical getter
-- 0x188a260); it is part of the gun's recoil here too.
local M = {}
local log, valid

local CFG = {
    RECOIL_FIX = 1,   -- 1 = this file works, 0 = the game's own recoil and nothing else
    ADS_VALUES = 0,   -- 1 = aimed shots climb 1.25 * VerticalRecoilADS instead of the game's own figure (the Jackhammer 0.3, not 2.0)
    HIP_KICK = 0,     -- 1 = shots at the hip kick the view like the weapon data says, 0 = no kick at the hip like the game
    RECOIL_MULT = 1,  -- every kick this file knows (aimed, and the hip when HIP_KICK is 1) times this (0.5 = half, 2 = double)
    RECOIL_ADS_MULT = 1, -- aimed shots times this on top of that (the hip is not changed)
    HIP_SCALE = 1,    -- the hip's share on top of RECOIL_MULT (only when HIP_KICK is 1)
    REF_INTERVAL = 0.12, -- seconds between shots (500 RPM) at and above which an automatic gun keeps its full recoil
    MIN_SCALE = 1,    -- the fastest automatic guns' least share (faster than REF_INTERVAL: interval / REF_INTERVAL, never below this). 1 = fire rate makes no difference
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
local ownYaw = 0     -- what this file has added to the view yaw so far (taken off again when measuring)
local yshots = {}    -- aimed shots whose sideways drift is waiting to be measured: { t, k, cap }
local lastEndY = 0   -- where the last measured yaw window ended
local PAN = 30       -- degrees a second of the player's own turning before a shot, above which the drift is left alone

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

-- Seconds between shots by weapon class (docs/internals/DAMAGE_REFERENCE.md, TimeBetweenShots from the value dump), from build 36.
local INTERVAL = {
    Rifle_PPSH_Child_C = 0.086, Rifle_Mac10_Child_C = 0.086, Rifle_Klobb_Child_C = 0.075, Rifle_Krasa_Child_C = 0.092,
    Rifle_Uzi_Child_C = 0.1, Rifle_Mat49_Child_C = 0.1, Rifle_CustomMat49_Child_C = 0.1, Rifle_M16_Child_C = 0.1,
    Rifle_M712_Special_Child_C = 0.1, Rifle_Stoner63A_Child_C = 0.103, Rifle_Thompson_Child_C = 0.109,
    Rifle_HeavyThompson_Child_C = 0.109, Rifle_Thompson_Special_Child_C = 0.109, Rifle_SterlingMk4_Regular_Child_C = 0.109,
    Rifle_SterlingMk4_Short_Child_C = 0.109, Rifle_SterlingMk4_Suppressed_Child_C = 0.109, Rifle_DP28_Child_C = 0.109,
    Rifle_Bren_MKII_Child_C = 0.111, Rifle_ViperMK1_Child_C = 0.115,
}

local function className(w)
    local ok, name = pcall(function() return w:GetClass():GetFName():ToString() end)
    if ok and type(name) == "string" then return name end
    return ""
end

-- The fire rate share of the kick: an automatic gun firing faster than REF_INTERVAL gets interval / REF_INTERVAL, never below MIN_SCALE.
-- Anything else (slower guns, semi autos, pistols, shotguns) is 1.
local function rateScale(w)
    local class = className(w)
    local iv = INTERVAL[class]
    if not iv and class:find("^Rifle_") then
        iv = num(function() return w.WeaponConfig.TimeBetweenShots end, nil)
        if type(iv) ~= "number" or iv <= 0 then iv = nil end
    end
    if iv and iv < CFG.REF_INTERVAL then return math.max(CFG.MIN_SCALE, iv / CFG.REF_INTERVAL) end
    return 1
end

-- What the muzzle and stock add to the weapon's own recoil (the game's vertical getter sums them with WeaponConfig.VerticalRecoil).
local ATTACH = { "MuzzleSlot", "StockSlot" }
local function adjustments(w)
    local adj = { v = 0, hmin = 0, hmax = 0 }
    for _, slot in ipairs(ATTACH) do
        local ok, a = pcall(function() return w[slot] end)
        if ok and a and valid(a) then
            adj.v = adj.v + num(function() return a.VerticalRecoilAdjustment end, 0)
            adj.hmin = adj.hmin + num(function() return a.HorizontalRecoilAdjustmentMin end, 0)
            adj.hmax = adj.hmax + num(function() return a.HorizontalRecoilAdjustmentMax end, 0)
        end
    end
    return adj
end

-- The game's own aimed climb of each gun in degrees for every point of VerticalRecoil (shot after shot the same, measured clicking
-- one shot at a time and holding the automatic guns, aimed at a wall with this file switched off). 1.25 is the automatic guns' figure.
-- The Pistol_M712 and Rifle_M712_Special blend their kick in slowly (RecoilBlendSpeed 1.0), so theirs is only what showed within a
-- third of a second.
local FULL = 1.25
local NATIVE = {
    Rifle_Sten_Child_C = FULL, Rifle_SterlingMk4_Regular_Child_C = FULL, Rifle_SterlingMk4_Short_Child_C = FULL,
    Rifle_SterlingMk4_Suppressed_Child_C = FULL, Rifle_Mat49_Child_C = FULL, Rifle_CustomMat49_Child_C = FULL, Rifle_MP40_Child_C = FULL,
    Rifle_Uzi_Child_C = FULL, Rifle_Mac10_Child_C = FULL, Rifle_PPSH_Child_C = FULL, Rifle_Thompson_Child_C = FULL,
    Rifle_HeavyThompson_Child_C = FULL, Rifle_Thompson_Special_Child_C = FULL, Rifle_M45_Child_C = FULL, Rifle_GreaseGun_Child_C = FULL,
    Rifle_Klobb_Child_C = FULL, Rifle_ViperMK1_Child_C = FULL, Rifle_STG44_Child_C = FULL, Rifle_Stoner63A_Child_C = FULL,
    Rifle_Krasa_Child_C = FULL, Rifle_DaewooK1_Child_C = FULL, Rifle_APS_Rifle_Child_C = FULL, Rifle_EM2_Child_C = FULL,
    Rifle_FAL_Child_C = FULL, Rifle_BAR_Child_C = FULL, Rifle_SVU_Special_Child_C = FULL, Rifle_Bren_MKII_Child_C = FULL,
    Rifle_DP28_Child_C = FULL, Rifle_MG42_Child_C = FULL, Rifle_HeavyMG42_Child_C = FULL, Rifle_M16_Child_C = FULL,
    Rifle_DeLisle_Child_C = FULL, Shotgun_Jackhammer_Child_C = FULL, Shotgun_Terminator_Child_C = FULL,
    Pistol_Welrod_Child_C = FULL, Pistol_SPP1_Child_C = FULL, Pistol_Mosin_Child_C = FULL,
    Rifle_M50reising_Child_C = 0.4014, Rifle_Johnson_Child_C = 0.7633, Rifle_SVT40_Child_C = 0.2544, Rifle_M1_Para_Child_C = 0.2543,
    Rifle_Mas44_Child_C = 0.2544, Rifle_AC14_Child_C = 0.2543, Shotgun_Liberator_Child_C = 0.1032, Shotgun_HeavyLiberator_Child_C = 0.1032,
    Shotgun_TrenchGun_Child_C = 0.7173, Shotgun_LongDouble_Child_C = 0.3096, Shotgun_SawedOffDouble_Child_C = 0.322,
    Pistol_1911_Child_C = 0.1541, Pistol_1911_G_Child_C = 0.1541, Pistol_P08_Child_C = 0.2544, Pistol_Webley_Child_C = 0.2544,
    Pistol_M712_Child_C = 0.026, Rifle_M712_Special_Child_C = 0.838,
}

-- The game's own climb of this gun for one shot, v = its vertical recoil with the muzzle and stock; nil for a gun that was not measured.
local function nativeAimed(w, v)
    local per = NATIVE[className(w)]
    if per then return per * v end
    return nil
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

-- The view yaw (less what this file added) at the last sample taken at or before time t.
local function yawAt(t)
    for i = #hist, 1, -1 do
        if hist[i][1] <= t then return hist[i][3] end
    end
    return nil
end

local function onShot(w)
    if CFG.RECOIL_FIX ~= 1 then return end
    local pawn = w.MyPawn
    if not (valid(pawn) and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return end
    local c = w.WeaponConfig
    local adj = adjustments(w)
    local v0 = num(function() return c.VerticalRecoil end, 0)
    local v = v0 + adj.v
    local va = num(function() return c.VerticalRecoilADS end, v0) + adj.v
    local scale = CFG.RECOIL_MULT * rateScale(w)
    if pawn:IsTargeting() then
        -- (recoilModifier.Aiming is not part of what the game gave: the Welrod and SPP 1 have 6.0, the Obrez and Sawed off 3.0, and they kick
        -- 1.25 * VerticalRecoil all the same)
        local mult = scale * CFG.RECOIL_ADS_MULT
        if CFG.ADS_VALUES ~= 1 and math.abs(mult - 1) < 1e-4 then return end -- the game's own: nothing to add, nothing to measure
        if math.abs(mult - 1) >= 1e-4 then
            -- the game's own sideways drift on aimed shots (the automatics, the M16, the Terminator): it is random on every shot, so it is
            -- measured, and the shot adds (mult - 1) times what it gave. The cap keeps a fast turn of the player's own from being taken for it.
            local amax = math.max(math.abs(num(function() return c.AngleMin end, 0)), math.abs(num(function() return c.AngleMax end, 0)))
            yshots[#yshots + 1] = { t = os.clock(), k = mult - 1, cap = 1.5 + 0.1 * amax }
        end
        local native = nativeAimed(w, v)
        if native then
            local target = (CFG.ADS_VALUES == 1) and (DEGREES * va * mult) or (native * mult)
            pitchPending = pitchPending + (target - native)
        else
            local want = DEGREES * (CFG.ADS_VALUES == 1 and va or v) * mult
            shots[#shots + 1] = { t = os.clock(), want = want, cap = DEGREES * v * 1.5 + 0.5 }
        end
    elseif CFG.HIP_KICK == 1 then
        local k = scale * CFG.HIP_SCALE * stateModifier(pawn, c)
        pitchPending = pitchPending + DEGREES * v * k
        local lo = num(function() return c.HorizontalRecoilMin end, 0) + adj.hmin
        local hi = num(function() return c.HorizontalRecoilMax end, 0) + adj.hmax
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

-- Aimed shots whose window has passed: the game's own sideways drift is the movement of the view yaw over the window. Windows never
-- overlap, so a run of shots is counted once. A shot with the player turning fast just before it is left alone.
local function measureYaw(now)
    while yshots[1] and now >= yshots[1].t + SETTLE do
        local s = table.remove(yshots, 1)
        local a, b = math.max(s.t - LEAD, lastEndY), s.t + SETTLE
        if yshots[1] then b = math.min(b, yshots[1].t - LEAD) end
        if b > a then
            local ya, yb, yp = yawAt(a), yawAt(b), yawAt(a - 0.1)
            if ya and yb then
                local turning = yp and math.abs(delta(yp, ya)) / 0.1 > PAN
                if not turning then
                    local gave = math.max(-s.cap, math.min(s.cap, delta(ya, yb)))
                    yawPending = yawPending + s.k * gave
                end
            end
        end
        lastEndY = math.max(lastEndY, b)
    end
end

-- Every frame in a raid: the view is sampled, the aimed shots are measured, and the pending climb goes onto the view over BLEND seconds.
function M.frame(pc)
    hookShots()
    local now = os.clock()
    local dt = math.min(0.1, now - (last or now))
    last = now
    local r = pc:GetControlRotation()
    hist[#hist + 1] = { now, r.Pitch - ownSum, r.Yaw - ownYaw }
    while hist[1] and hist[1][1] < now - HISTORY do table.remove(hist, 1) end
    measure(now)
    measureYaw(now)
    if math.abs(pitchPending) < 1e-4 and math.abs(yawPending) < 1e-4 then
        pitchPending, yawPending = 0, 0
        return
    end
    local f = math.min(1, dt / BLEND)
    local dp, dy = pitchPending * f, yawPending * f
    pitchPending, yawPending = pitchPending - dp, yawPending - dy
    ownSum = ownSum + dp
    ownYaw = ownYaw + dy
    pc:SetControlRotation({ Pitch = r.Pitch + dp, Yaw = r.Yaw + dy, Roll = r.Roll })
end

-- Guessed names; a missing property reads as nil and is skipped.
local FIELDS = { "VerticalRecoil", "HorizontalRecoilMin", "HorizontalRecoilMax", "VerticalRecoilADS", "RecoilBlendSpeed",
    "RecoilRecoveryRate", "RecoilRecoveryDelay", "HorizontalRecoilADS", "RecoilADSMultiplier",
    "ADSRecoilMultiplier", "RecoilRecovery", "RecoilRecoverySpeed", "RecoilSpeed", "RecoilInterpSpeed", "MaxRecoil",
    "TimeBetweenShots", "ADSTime", "ADSSpread", "BulletSpread", "BulletSpreadADS" }
local logged = {} -- class -> true

local function logFields(cfg, class)
    if logged[class] then return end
    logged[class] = true
    local parts = {}
    for _, f in ipairs(FIELDS) do
        local ok, val = pcall(function() return cfg[f] end)
        if ok and type(val) == "number" then parts[#parts + 1] = ("%s=%.3f"):format(f, val) end
    end
    print(("[PvEDirector] recoil fields: %s %s\n"):format(class, table.concat(parts, " ")))
end

-- Called each update with the held gun (main.lua). Property reads only: the first time each gun class is held, its recoil looking
-- WeaponConfig fields are logged ("recoil fields:", from build 36 #453) so a playtest can see which exist. Nothing is written.
function M.apply(gun, valid_)
    if not valid_(gun) then return end
    local okc, cfg = pcall(function() return gun.WeaponConfig end)
    if not okc or cfg == nil then return end
    logFields(cfg, className(gun))
end

-- A new raid starts with nothing pending.
function M.reset() pitchPending, yawPending, last, ownSum, hist, shots, lastEnd = 0, 0, nil, 0, {}, {}, 0; ownYaw, yshots, lastEndY = 0, {}, 0; logged = {} end

return M
