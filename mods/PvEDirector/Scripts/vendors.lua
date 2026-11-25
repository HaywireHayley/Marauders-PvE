-- Vendors stock (#384): the four faction traders sold a handful of things, one every few faction levels, and levels
-- 11-40 repeat level 10's list. This adds the most wanted guns, armour and helmets and their ammo, by faction
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

-- What each trader adds (row names from gear.lua), most wanted first: the shop screen is one fixed 10 x 11 grid
-- (SHOPMainCon, 110 cells) that shows every level's items at once, locked ones greyed, and anything that doesn't fit
-- isn't shown at all (#384 follow-up: the first list needed 173-256 cells a faction). So each list is cut to what fits
-- (BUDGET cells, after the base stock and the game's own extras), in this order. Ammo for a gun that made it is added
-- too (one cell each).
local STOCK = {
    United = { "BARRifle", "M16Rifle", "ShermanPlate", "M5Helmet", "JohnsonRifle", "M1Helmet", "M2FlakChest",
        "1911Pistol", "M1ParaRifle", "ChinaLake", "StonerRifle", "Mac10Rifle" },
    Republic = { "MG42Rifle", "STG44Rifle", "PanzerChest", "PSHHelmet", "PPSHSmg", "HeavyStahlhelmHelmet", "DP28Rifle",
        "P08Pistol", "StahlhelmHelmet", "SVURifle" },
    Kingdom = { "BrenMk2Rifle", "FALRifle", "BAHeavyVest", "BAHeavyHelmet", "SterlingRifle", "BrodieHelmet",
        "WebleyPistol", "DeLisleRifle", "MK3FlakVest", "LightBag" },
    Pirate = { "DaewooK1Rifle", "LongDoubleBarrel", "HeavyRiotHelmet", "HalfPlateChest", "Mas44Rifle", "AC14Rifle",
        "KlobbSMG", "UziSmg", "RiotHelmet", "LeatherJerkinChest", "SackBag", "LightBag", "MiniThumper" },
}
-- Cells each trader may add: 110, less ~30 for the base stock, less the game's own extras at their top level (United
-- 36, Republic 46, Kingdom 37, Pirate 16 cells), less ~15% for gaps a fixed grid can't fill.
local BUDGET = { United = 37, Republic = 29, Kingdom = 36, Pirate = 54 }

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

-- The stock list as { faction = { {row, level}, ... } }, cut to the faction's BUDGET of shop cells, ammo included
-- (public for the log and the tests). dropped = { faction = { rows left out } }.
function M.plan()
    local by, Items, out, dropped = lookup(), require("itemdata"), {}, {}
    local function cells(name)
        local r = Items.get(name)
        return r and (r.w or 1) * (r.h or 1) or 1
    end
    for faction, rows in pairs(STOCK) do
        local list, ammoAt, used, left = {}, {}, 0, {}
        for _, name in ipairs(rows) do
            local r = by[name]
            if r then
                local need = cells(name) + ((r[3] and not ammoAt[r[3]]) and 1 or 0)
                if used + need <= (BUDGET[faction] or 0) then
                    used = used + need
                    local lvl = tier(r[2])
                    list[#list + 1] = { name, lvl }
                    if r[3] and (not ammoAt[r[3]] or lvl < ammoAt[r[3]]) then ammoAt[r[3]] = lvl end
                else
                    left[#left + 1] = name
                end
            end
        end
        for ammo, lvl in pairs(ammoAt) do list[#list + 1] = { ammo, lvl } end
        out[faction], dropped[faction] = list, left
    end
    return out, dropped
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
        local n, plan, dropped = 0, M.plan()
        for faction, list in pairs(plan) do
            for _, e in ipairs(list) do
                X.shopAdd(at, idx(faction), e[2], idx(e[1]))
                n = n + 1
            end
            if #dropped[faction] > 0 then
                X.log(("vendors: %s: no room on the shop screen for %s"):format(faction, table.concat(dropped[faction], ", ")))
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
