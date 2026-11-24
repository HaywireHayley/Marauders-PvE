-- Raid conditions (issue #78): a named set-up for a raid, for community events or just a change: the Red Baron or a
-- capital ship guaranteed, crews that hunt you, a busier sky, a fixed map, and more loot on bodies when it's harder.
--
-- Conditions live in config/raid_conditions.txt (shipped) and config/my_raid_conditions.txt (yours; same name = yours
-- wins). Each is a [Name] then key = value lines:
--   about = one line shown in the lobby and the launcher
--   map   = Space_Charlie                  (a fixed map: it wins over the map picked in the lobby)
--   ships = FrigateCapitalShip_Ship, ...  (rival crews guaranteed in these hulls: rivals.lua CFG.HULLS rows)
--   loot  = 1.5                            (more and better loot on bodies: x items in a bag, x the value cap)
--   mines = 20                             (x the map's space mines: minefield.lua copies each one near itself)
--   any F10 setting by its id in config/ai_tuning.txt, e.g. Crews:BARON = 1, Spawns:CREWS = 9, Crews:ATTACK_CHANCE = 1
-- The pick is config/raid_condition.txt (a name; missing = Normal), set by the launcher or the lobby's REGION picker.
--
-- A condition only lasts the raid: its values are put in when a raid map loads and your own are back in the lobby.
-- The F10 menu saves your own values, never a condition's (tuning.lua asks M.base).
local M = {}
local X -- log, project, tuning (tuning.lua), tables = { Rivals = rivals CFG, ... }

local NORMAL = "Normal"
local list = {}      -- { name, about, map, ships = { rows }, loot, values = { { key, value } } } in file order
local picked = NORMAL
local changed = {}   -- [table][key or key.."."..index] = { t, k, i, base }: what an applied condition replaced
local active         -- the condition applied now, or nil

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function readFile(path, byName)
    local f = io.open(path, "r")
    if not f then return end
    local cur
    for raw in f:lines() do
        local line = trim(raw)
        local name = line:match("^%[(.+)%]$")
        local k, v = line:match("^([^#=][^=]-)%s*=%s*(.-)$")
        if name then
            cur = byName[name]
            if not cur then
                cur = { name = name }
                list[#list + 1] = cur
                byName[name] = cur
            end
            cur.values, cur.about, cur.map, cur.ships, cur.loot, cur.mines = {}, nil, nil, nil, nil, nil -- yours replaces the shipped one
        elseif cur and k then
            k = trim(k)
            if k == "about" then cur.about = v
            elseif k == "map" then cur.map = v ~= "" and v or nil
            elseif k == "ships" then
                cur.ships = {}
                for row in v:gmatch("[^,%s]+") do cur.ships[#cur.ships + 1] = row end
            elseif k == "loot" then cur.loot = tonumber(v)
            elseif k == "mines" then cur.mines = tonumber(v)
            elseif tonumber(v) then cur.values[#cur.values + 1] = { k, tonumber(v) }
            end
        end
    end
    f:close()
end

local function load()
    list = { { name = NORMAL, about = "The usual raid.", values = {} } }
    local byName = { [NORMAL] = list[1] }
    readFile(X.project .. "config/raid_conditions.txt", byName)
    readFile(X.project .. "config/my_raid_conditions.txt", byName)
    picked = NORMAL
    local f = io.open(X.project .. "config/raid_condition.txt", "r")
    if f then
        local name = trim(f:read("l") or "")
        f:close()
        if byName[name] then picked = name end
    end
end

function M.init(ctx)
    X = ctx
    load()
    X.log(("raid conditions: %d (picked: %s)"):format(#list - 1, picked))
end

function M.names()
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = c.name end
    return out
end

local function byName(name)
    for _, c in ipairs(list) do if c.name == name then return c end end
end

function M.picked() return picked end
function M.about(name) local c = byName(name or picked) return c and c.about or "" end
function M.isNormal() return picked == NORMAL end

-- Picks a condition (the lobby's button cycles through them) and remembers it.
function M.pick(name)
    if not byName(name) then return end
    picked = name
    local path = X.project .. "config/raid_condition.txt"
    if name == NORMAL then os.remove(path) return end
    local f = io.open(path, "w")
    if f then f:write(name, "\n") f:close() end
end

function M.cycle()
    for i, c in ipairs(list) do
        if c.name == picked then return M.pick(list[i % #list + 1].name) end
    end
    M.pick(NORMAL)
end

-- The map the picked condition fixes, or nil.
function M.map() local c = byName(picked) return c and c.map end
-- Hull rows guaranteed among the rival crews (rivalcrews.lua makeCrews), or nil.
function M.ships() return active and active.ships end
-- How many times the map's space mines this raid has (minefield.lua), or nil.
function M.mines() return active and active.mines end

-- Where a key points: an F10 setting id ("Crews:BARON", "Spawns:CREW_SIZE.2"), or Table.KEY[.index] for anything in
-- X.tables (e.g. Rivals.CARRY_JACKPOT).
local function resolve(key)
    local t, k, i = X.tuning.row(key)
    if t then return t, k, i end
    local tname, rest = key:match("^(%a+)%.(.+)$")
    t = tname and X.tables[tname]
    if not t then return end
    k, i = rest:match("^([%w_]+)%.(%d+)$")
    if k then return t, k, tonumber(i) end
    return t, rest, nil
end

local function get(t, k, i) if i then return t[k][i] end return t[k] end
local function set(t, k, i, v) if i then t[k][i] = v else t[k] = v end end

local function put(t, k, i, v)
    local slot = k .. (i and ("." .. i) or "")
    changed[t] = changed[t] or {}
    if not changed[t][slot] then changed[t][slot] = { t = t, k = k, i = i, base = get(t, k, i) } end
    set(t, k, i, v)
end

-- Puts every changed value back.
function M.restore()
    for _, slots in pairs(changed) do
        for _, c in pairs(slots) do set(c.t, c.k, c.i, c.base) end
    end
    changed = {}
    if active then X.log("raid conditions: back to your own settings") end
    active = nil
end

-- What a setting is without the condition (tuning.lua saves this), given its current value v.
function M.base(t, k, i, v)
    local c = changed[t] and changed[t][k .. (i and ("." .. i) or "")]
    if c then return c.base end
    return v
end

-- Applies the picked condition, once per raid (main.lua calls it when a raid map loads).
function M.apply()
    local c = byName(picked)
    if active == c then return end
    M.restore()
    if not c or c.name == NORMAL then return end
    active = c
    local n, bad = 0, {}
    for _, kv in ipairs(c.values) do
        local t, k, i = resolve(kv[1])
        if t and get(t, k, i) ~= nil then put(t, k, i, kv[2]) n = n + 1 else bad[#bad + 1] = kv[1] end
    end
    local loot = c.loot and c.loot > 0 and c.loot or 1
    local R = X.tables.Rivals
    if loot ~= 1 and R then
        -- more items in each bag, a higher value cap for each, and more jackpots (rivalbodies.lua rollCarried)
        put(R, "CARRY_BAG", 1, math.floor(R.CARRY_BAG[1] * loot + 0.5))
        put(R, "CARRY_BAG", 2, math.floor(R.CARRY_BAG[2] * loot + 0.5))
        put(R, "MEDS", 2, math.floor(R.MEDS[2] * loot + 0.5))
        put(R, "CARRY_CAP_MIN", nil, R.CARRY_CAP_MIN * loot)
        put(R, "CARRY_CAP_SHARE", nil, R.CARRY_CAP_SHARE * loot)
        put(R, "CARRY_JACKPOT", nil, math.min(0.5, R.CARRY_JACKPOT * loot))
    end
    X.log(("raid conditions: %s (%d settings%s%s%s)%s"):format(c.name, n,
        loot ~= 1 and (", loot x" .. loot) or "", c.ships and (", ships " .. table.concat(c.ships, " ")) or "",
        (c.map and (", map " .. c.map) or "") .. (c.mines and (", mines x" .. c.mines) or ""), #bad > 0 and (" -- unknown: " .. table.concat(bad, ", ")) or ""))
end

return M
