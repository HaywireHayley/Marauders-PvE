-- Vendors stock (#384): the four faction traders sold a handful of things, one every few faction levels, and levels
-- 11-40 repeat level 10's list. This adds most of the game's guns, armour, helmets, bags and their ammo, by faction
-- (lore: United = American and Commonwealth, Republic = Soviet and German, Kingdom = British, Pirate = scavenged and
-- odd), unlocked by faction level in tiers by price. Left out on purpose (Discord, 22 Nov): heavy variants, Full Panzer
-- and Full Sherman, boss and signature gear, the oddities that make loot fun (radios, barrel bags) and the
-- flamethrower. Loot stays the cheap way to gear up: the game's own prices apply, and VENDOR_PRICE (Features tab)
-- scales every price at the four traders.
--
-- Where the stock lives: DT_FactionShops, one row per faction, one element per faction level, each holding the extra
-- items at that level (ShopDeduction = that level's discount). The arrays are grown in native code with the engine's
-- allocator (pvepatch.c pve_shop_add, pve_shop_price): growing a TArray from Lua corrupts the heap (NOTES).
-- Applied in the lobby, once per game session (the table stays loaded; a reload is noticed and patched again).
local M = {}
local X -- log, valid, shopAdd, shopPrice
local done, pricedAt, nextAt = nil, nil, 0

local TABLE = "/Game/Blueprints/Factions/DT_FactionShops.DT_FactionShops"
local Feats = require("features")

-- Level an item unlocks at, from its price (#384: basics early, LMGs and battle rifles around 6-8, top armour 9-10).
local function tier(price)
    if price < 2500 then return 1 elseif price < 5000 then return 3 elseif price < 8000 then return 5
    elseif price < 11000 then return 7 else return 9 end
end

-- What each trader adds (row names from gear.lua). Ammo comes with the first gun that needs it.
local STOCK = {
    United = { "M1ParaRifle", "1911Pistol", "M45CarlSMG", "M16Rifle", "BARRifle", "JohnsonRifle", "StonerRifle",
        "ChinaLake", "Mac10Rifle", "LiberatorShotgun", "M1Helmet", "HeavyM1Helmet", "M5Helmet", "PilotHelmet",
        "HeavyPilotHelmet", "M1FlakChest", "M1FlakRig", "M2FlakChest", "ShermanPlate", "ShermanRig", "PilotArmourChest",
        "HeavyPilotArmourChest", "LightBag", "MedicBag" },
    Republic = { "P08Pistol", "MosinObrezPistol", "PPSHSmg", "MP40Rifle", "STG44Rifle", "DP28Rifle", "MG42Rifle",
        "SVURifle", "APSRifle", "KrasaRifle", "StahlhelmHelmet", "HeavyStahlhelmHelmet", "PSHHelmet", "HalfPlateChest",
        "PlateRig", "CEFullPlate", "PanzerChest", "PanzerRig", "CommandoBag" },
    Kingdom = { "StenSMG", "WelrodPistol", "WebleyPistol", "SterlingRifle_Short", "SterlingRifle", "DeLisleRifle",
        "BrenMk2Rifle", "FALRifle", "BAHelmet", "BrodieHelmet", "BAHeavyHelmet", "SASBeret", "MK3FlakVest", "Mk3FlakRig",
        "BAFlakVest", "BAHeavyVest", "LightBag", "CommandoBag" },
    Pirate = { "UziSmg", "KlobbSMG", "SPP1Pistol", "Mat49Rifle", "LongDoubleBarrel", "Mas44Rifle", "MiniThumper",
        "DaewooK1Rifle", "AC14Rifle", "ViperMk1", "PirateHelmet", "PirateHelmetBlue", "CivilianHelmet", "RiotHelmet",
        "SafetyHelmet", "HeavyRiotHelmet", "LeatherJerkinChest", "PouchRig", "HalfPlateChest", "SackBag", "LightBag",
        "FreebooterBag" },
}

function M.init(ctx) X = ctx end
function M.reset() pricedAt = nil end

-- price and ammo of a row (gear.lua lists guns { row, price, ammo }, the rest { row, price })
local function lookup()
    local Gear, by = require("gear"), {}
    for _, list in ipairs({ Gear.guns, Gear.helmets, Gear.chests, Gear.bags }) do
        for _, r in ipairs(list or {}) do by[r[1]] = r end
    end
    return by
end

-- The stock list as { faction = { {row, level}, ... } }, ammo included (public for the tests and the log).
function M.plan()
    local by, out = lookup(), {}
    for faction, rows in pairs(STOCK) do
        local list, ammoAt = {}, {}
        for _, name in ipairs(rows) do
            local r = by[name]
            if r then
                local lvl = tier(r[2])
                list[#list + 1] = { name, lvl }
                if r[3] and (not ammoAt[r[3]] or lvl < ammoAt[r[3]]) then ammoAt[r[3]] = lvl end
            end
        end
        for ammo, lvl in pairs(ammoAt) do list[#list + 1] = { ammo, lvl } end
        out[faction] = list
    end
    return out
end

local function idx(name) return FName(name):GetComparisonIndex() end

-- Every lobby update (main.lua, the menu world only).
function M.tick()
    if os.clock() < nextAt then return end
    nextAt = os.clock() + 2
    local dt = StaticFindObject(TABLE)
    if not (dt and X.valid(dt)) then return end
    local at = math.tointeger(dt:GetAddress())
    if (Feats.VENDOR_STOCK or 1) ~= 0 and done ~= at then
        done = at
        local n = 0
        for faction, list in pairs(M.plan()) do
            for _, e in ipairs(list) do
                X.shopAdd(at, idx(faction), e[2], idx(e[1]))
                n = n + 1
            end
        end
        X.log(("vendors: %d items added to the four traders' stock (#384)"):format(n))
    end
    local pct = math.floor((tonumber(Feats.VENDOR_PRICE) or 100) + 0.5)
    if pricedAt ~= at .. ":" .. pct then
        pricedAt = at .. ":" .. pct
        for faction in pairs(STOCK) do X.shopPrice(at, idx(faction), pct) end
        if pct ~= 100 then X.log(("vendors: prices at the four traders %d%% of the game's"):format(pct)) end
    end
end

return M
