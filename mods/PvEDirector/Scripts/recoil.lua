-- Per-gun recoil scale for the gun you hold (#371). NOT TESTED IN GAME.
--
-- The game's per-tick recoil (0x189f890) treats WeaponConfig.VerticalRecoil as the total climb allowed for a burst, not
-- a kick per shot (spork, Discord 22 Nov), and almost every gun sits at 1.25-3.0. So a 700 RPM PPSh reaches its cap as
-- hard as an LMG and every gun feels the same. Here each automatic gun's VerticalRecoil (and HorizontalRecoil, if that
-- property exists) is scaled down by its fire rate: a gun firing faster than REF_INTERVAL gets interval / REF_INTERVAL,
-- never below MIN_SCALE. Slower guns, semi-autos, pistols and shotguns keep the game's value. Then x MULT for every gun.
--
-- Property names (read from the game 25 Nov): WeaponConfig.VerticalRecoil (+0xb0), HorizontalRecoilMin/Max (+0xb8/+0xbc);
-- TimeBetweenShots is still a guess (only a fallback for guns not in INTERVAL). The values are written on the held gun's own WeaponConfig struct, once per gun (the original is kept, so
-- a change of MULT in the settings menu rescales from it).
--
-- ADS (#453, NOT TESTED IN GAME): the aim kick these fields drive only applies while bIsTargeting (pawn +0x9e8, NOTES
-- "Recoil"); hip fire only gets the control-rig arm shake, which this file never touches. So VerticalRecoil is in
-- effect the ADS recoil, and RECOIL_ADS_MULT scales it (and HorizontalRecoil) on top of the fire-rate scale without
-- changing the hip feel. The first time each gun class is held its other recoil-looking WeaponConfig fields are logged
-- ("recoil fields:"), property reads only, so a playtest can see whether an ADS-specific field exists and is non-zero.
local M = {}

local CFG = {
    RECOIL_MULT = 1.0,     -- every gun's recoil x this (1 = the game's own, 0 = none)
    REF_INTERVAL = 0.12,   -- seconds between shots (500 RPM) at and above which a gun keeps its full recoil
    MIN_SCALE = 0.55,      -- the fastest guns never drop below this share
    RECOIL_ADS_MULT = 1.0, -- aim kick while aiming down sights x this (the kick only exists in ADS; hip is untouched)
}
M.CFG = CFG

-- Seconds between shots by weapon class (docs/internals/DAMAGE_REFERENCE.md, TimeBetweenShots from the value dump).
-- Only automatic "Rifle_" classes; anything faster than REF_INTERVAL is scaled.
local INTERVAL = {
    Rifle_PPSH_Child_C = 0.086, Rifle_Mac10_Child_C = 0.086, Rifle_Klobb_Child_C = 0.075, Rifle_Krasa_Child_C = 0.092,
    Rifle_Uzi_Child_C = 0.1, Rifle_Mat49_Child_C = 0.1, Rifle_CustomMat49_Child_C = 0.1, Rifle_M16_Child_C = 0.1,
    Rifle_M712_Special_Child_C = 0.1, Rifle_Stoner63A_Child_C = 0.103, Rifle_Thompson_Child_C = 0.109,
    Rifle_HeavyThompson_Child_C = 0.109, Rifle_Thompson_Special_Child_C = 0.109, Rifle_SterlingMk4_Regular_Child_C = 0.109,
    Rifle_SterlingMk4_Short_Child_C = 0.109, Rifle_SterlingMk4_Suppressed_Child_C = 0.109, Rifle_DP28_Child_C = 0.109,
    Rifle_Bren_MKII_Child_C = 0.111, Rifle_ViperMK1_Child_C = 0.115,
}

-- weapon address -> { base = original { v, hmin, hmax }, wrote = written vertical, key = attachments, settings... }
local seen = {}

-- What the game adds to WeaponConfig's recoil (#453, read from the game 25 Nov): the vertical recoil getter 0x188a260
-- returns WeaponConfig.VerticalRecoil (+0x4c0) + MuzzleSlot.VerticalRecoilAdjustment + StockSlot.VerticalRecoilAdjustment
-- (RaidWeaponAttachment +0x234); horizontal has HorizontalRecoilAdjustmentMin/Max beside it. So scaling only the
-- weapon's own value left the attachments' share (a player set recoil to 0 and the M16 still kicked).
local ATTACH = { "MuzzleSlot", "StockSlot" }
local function adjustments(gun, valid)
    local adj, key = { v = 0, hmin = 0, hmax = 0 }, ""
    for _, slot in ipairs(ATTACH) do
        local ok, a = pcall(function() return gun[slot] end)
        if ok and a and valid(a) then
            key = key .. tostring(a:GetAddress()) .. ";"
            pcall(function()
                adj.v = adj.v + (a.VerticalRecoilAdjustment or 0)
                adj.hmin = adj.hmin + (a.HorizontalRecoilAdjustmentMin or 0)
                adj.hmax = adj.hmax + (a.HorizontalRecoilAdjustmentMax or 0)
            end)
        end
    end
    return adj, key
end

local function scaleFor(gun, class)
    local iv = INTERVAL[class]
    if not iv and class:find("^Rifle_") then
        local ok, t = pcall(function() return gun.WeaponConfig.TimeBetweenShots end)
        if ok and type(t) == "number" and t > 0 then iv = t end
    end
    local s = 1
    if iv and iv < CFG.REF_INTERVAL then s = math.max(CFG.MIN_SCALE, iv / CFG.REF_INTERVAL) end
    return s * CFG.RECOIL_MULT * CFG.RECOIL_ADS_MULT
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

-- Called each update with the held gun. Property reads and writes only. The gun's TOTAL recoil (its own value plus
-- its attachments') is scaled: WeaponConfig gets total x k - attachments, so k = 0 really is no recoil. Horizontal
-- uses the real fields HorizontalRecoilMin/Max (#453: "HorizontalRecoil" was a guess and never existed). The arm-shake
-- animation in hip fire (control rig) is not touched.
function M.apply(gun, valid)
    if not valid(gun) then return end
    local addr = gun:GetAddress()
    local cfgOk, cfg = pcall(function() return gun.WeaponConfig end)
    if not cfgOk or cfg == nil then return end
    local okv, v = pcall(function() return cfg.VerticalRecoil end)
    if not okv or type(v) ~= "number" then return end
    local adj, key = adjustments(gun, valid)
    local s = seen[addr]
    -- A new gun, or another gun reusing a freed one's address (its value is not the one we wrote).
    if not s or math.abs(v - s.wrote) > 1e-4 then
        local base = { v = v }
        pcall(function() base.hmin, base.hmax = cfg.HorizontalRecoilMin, cfg.HorizontalRecoilMax end)
        s = { base = base }
        seen[addr] = s
    elseif s.key == key and s.mult == CFG.RECOIL_MULT and s.ads == CFG.RECOIL_ADS_MULT and s.ref == CFG.REF_INTERVAL
        and s.min == CFG.MIN_SCALE then
        return
    end
    local okc, class = pcall(function() return gun:GetClass():GetFName():ToString() end)
    if not okc or type(class) ~= "string" then class = "" end
    logFields(cfg, class)
    local k = scaleFor(gun, class)
    s.key, s.mult, s.ads, s.ref, s.min = key, CFG.RECOIL_MULT, CFG.RECOIL_ADS_MULT, CFG.REF_INTERVAL, CFG.MIN_SCALE
    local b = s.base
    s.wrote = (b.v + adj.v) * k - adj.v
    pcall(function() cfg.VerticalRecoil = s.wrote end)
    if type(b.hmin) == "number" and type(b.hmax) == "number" then
        pcall(function()
            cfg.HorizontalRecoilMin = (b.hmin + adj.hmin) * k - adj.hmin
            cfg.HorizontalRecoilMax = (b.hmax + adj.hmax) * k - adj.hmax
        end)
    end
    -- Read back: if the write did not stick, remember what is there so it is not retried every frame.
    local okr, now = pcall(function() return cfg.VerticalRecoil end)
    if okr and type(now) == "number" then s.wrote = now end
    print(("[PvEDirector] recoil: %s vertical %.2f (+%.2f attachments) -> total %.2f (x%.2f)\n"):format(class, b.v, adj.v,
        s.wrote + adj.v, k))
end

-- Drop remembered guns on world change.
function M.reset() seen = {}; logged = {} end

return M
