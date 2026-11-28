-- Location difficulty tiers (#579): 1 (easy) to 5 (hardest) per station, by the names rivals.lua's station survey gives
-- (CFG.VOLUME_NAMES and the streaming-volume suffixes; the same keys as lorelines.lua). Tier 3 is the mod as it was:
-- every factor at tier 3 is 1 / 0, and an unknown station is tier 3. features.lua LOCATION_TIERS = 0 turns it all off.
-- Read by rivalbodies.lua garrisonStation (guard count) and topUpKit (rolled fallback kits). Untested in game.
local M = {}

local CFG = {
    DEFAULT = 3,
    TIERS = {
        ["Mini Mine"] = 1, ["Asteroid Mine"] = 1,
        ["Penal Colony"] = 2, ["Spaceport"] = 2,
        ["Moon Base"] = 3, ["Terraformer"] = 3, ["Colony Cruiser"] = 3, ["Merchant Ship"] = 3, ["Merchant"] = 3,
        ["Navy Outpost"] = 4, ["Capital Ship"] = 4, ["Planet Killer"] = 4,
        ["Fortress"] = 5, ["Red Baron"] = 5,
        -- Rebel Base: neutral, left out (tier 3 = unchanged)
    },
    COUNT = { 0.7, 0.85, 1, 1.2, 1.4 },       -- guard count multiplier per tier (applied before AWAKE_MAX's cap)
    COUNT_EXTRA = { ["Penal Colony"] = 1.3 }, -- its challenge is numbers: more guards, tier-2 gear
    GEAR = { -0.2, -0.1, 0, 0.1, 0.2 },       -- gear grade shift (gearscale.lua, 0..1) for rolled guard kits; 0 = as today
}
M.CFG = CFG

function M.init(_) end

local function on() return (require("features").LOCATION_TIERS or 0) >= 1 end
M.on = on

-- The station's tier, or DEFAULT (also when the feature is off).
function M.tierOf(name)
    if not on() then return CFG.DEFAULT end
    return CFG.TIERS[name or ""] or CFG.DEFAULT
end

-- Guard count multiplier (1 when off or tier 3).
function M.countFactor(name)
    if not on() then return 1 end
    return (CFG.COUNT[M.tierOf(name)] or 1) * (CFG.COUNT_EXTRA[name or ""] or 1)
end

-- Gear grade shift (0 when off or tier 3).
function M.gearBias(name)
    if not on() then return 0 end
    return CFG.GEAR[M.tierOf(name)] or 0
end

return M
