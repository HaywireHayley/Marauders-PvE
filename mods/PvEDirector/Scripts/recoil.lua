-- Per-gun recoil scale for the gun you hold (#371). NOT TESTED IN GAME.
--
-- The game's per-tick recoil (0x189f890) treats WeaponConfig.VerticalRecoil as the total climb allowed for a burst, not
-- a kick per shot (spork, Discord 22 Nov), and almost every gun sits at 1.25-3.0. So a 700 RPM PPSh reaches its cap as
-- hard as an LMG and every gun feels the same. Here each automatic gun's VerticalRecoil (and HorizontalRecoil, if that
-- property exists) is scaled down by its fire rate: a gun firing faster than REF_INTERVAL gets interval / REF_INTERVAL,
-- never below MIN_SCALE. Slower guns, semi-autos, pistols and shotguns keep the game's value. Then x MULT for every gun.
--
-- Assumptions (property names): WeaponConfig.VerticalRecoil is confirmed by NOTES ("Bren VerticalRecoil 2.25");
-- WeaponConfig.HorizontalRecoil and WeaponConfig.TimeBetweenShots are guessed (the latter only a fallback for guns not
-- in INTERVAL). The values are written on the held gun's own WeaponConfig struct, once per gun (the original is kept, so
-- a change of MULT in the settings menu rescales from it).
local M = {}

local CFG = {
    RECOIL_MULT = 1.0,     -- every gun's recoil x this (1 = the game's own, 0 = none)
    REF_INTERVAL = 0.12,   -- seconds between shots (500 RPM) at and above which a gun keeps its full recoil
    MIN_SCALE = 0.55,      -- the fastest guns never drop below this share
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

local seen = {} -- weapon address -> { v = original vertical, h = original horizontal, wv = written vertical, mult }

local function scaleFor(gun, class)
    local iv = INTERVAL[class]
    if not iv and class:find("^Rifle_") then
        local ok, t = pcall(function() return gun.WeaponConfig.TimeBetweenShots end)
        if ok and type(t) == "number" and t > 0 then iv = t end
    end
    local s = 1
    if iv and iv < CFG.REF_INTERVAL then s = math.max(CFG.MIN_SCALE, iv / CFG.REF_INTERVAL) end
    return s * CFG.RECOIL_MULT
end

-- Called each update with the held gun. Property reads and writes only.
function M.apply(gun, valid)
    if not valid(gun) then return end
    local addr = gun:GetAddress()
    local cfgOk, cfg = pcall(function() return gun.WeaponConfig end)
    if not cfgOk or cfg == nil then return end
    local okv, v = pcall(function() return cfg.VerticalRecoil end)
    if not okv or type(v) ~= "number" then return end
    local s = seen[addr]
    -- A new gun, or another gun reusing a freed one's address (its value is not the one we wrote).
    if not s or math.abs(v - s.wv) > 1e-4 then
        local okh, h = pcall(function() return cfg.HorizontalRecoil end)
        s = { v = v, h = (okh and type(h) == "number") and h or nil }
        seen[addr] = s
    elseif s.mult == CFG.RECOIL_MULT and s.ref == CFG.REF_INTERVAL and s.min == CFG.MIN_SCALE then
        return
    end
    local okc, class = pcall(function() return gun:GetClass():GetFName():ToString() end)
    if not okc or type(class) ~= "string" then class = "" end
    local k = scaleFor(gun, class)
    s.wv, s.mult, s.ref, s.min = s.v * k, CFG.RECOIL_MULT, CFG.REF_INTERVAL, CFG.MIN_SCALE
    pcall(function() cfg.VerticalRecoil = s.wv end)
    if s.h then pcall(function() cfg.HorizontalRecoil = s.h * k end) end
    -- Read back: if the write did not stick, remember what is there so it is not retried every frame.
    local okr, now = pcall(function() return cfg.VerticalRecoil end)
    if okr and type(now) == "number" then s.wv = now end
    print(("[PvEDirector] recoil: %s vertical %.2f -> %.2f (x%.2f)\n"):format(class, s.v, s.wv, k))
end

-- Drop remembered guns on world change.
function M.reset() seen = {} end

return M
