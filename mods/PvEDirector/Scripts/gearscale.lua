-- Gear that follows your level: rivals, station guards topped up by rivals.lua, and new or promoted crew (hire.lua) roll
-- their kit around the gear your player level "deserves", not from fixed odds.
--
-- A person's kit gets a gear grade g from 0 (cheapest row in the game's item table) to 1 (dearest). Each list in gear.lua
-- is sorted by price and g picks a row near that share of the way up it, so every gun, helmet, chest and bag stays in play.
-- Your level sets the centre of the roll (TARGET, from level 1 to LEVEL_MAX). Most people roll BELOW it (DOWN_SHARE,
-- anywhere down to SPREAD_DOWN under), the rest above (squared, so far above is rare, up to SPREAD_UP), and a few
-- (OUTLIER) roll anywhere at all: the odd geared rival at level 1, the odd pistol-and-no-helmet one at the top.
-- So levelling up means better-armed enemies, but you stay ahead of most of them, and better gear of your own pays.
local PROJECT = require("pveproject")
local G = {}

local LEVEL_FILE = PROJECT .. "config/player_level.txt" -- "<level> <max level>", written from the menu (main.lua)

local CFG = {
    LEVEL_MAX = 40,               -- the level at which the centre reaches TARGET[2]; replaced by the game's own cap if found
    TARGET = { 0.15, 0.80 },      -- gear grade at the centre of the roll at level 1 and at LEVEL_MAX (straight line between)
    DOWN_SHARE = 0.70,            -- share of rolls below the centre
    SPREAD_DOWN = 0.35,           -- how far below the centre a roll can land (evenly spread)
    SPREAD_UP = 0.25,             -- how far above (squared: most of the above-rolls land close to the centre)
    OUTLIER = 0.06,               -- chance the grade is rolled anywhere 0..1 instead
    PIECE_JITTER = 0.08,          -- each piece of a kit varies this much around the person's grade
    WINDOW = 0.07,                -- rows within this share of the list around the grade are equally likely
    -- Chance of wearing each piece at grade 0 and grade 1 (straight line between).
    WEAR = { helmet = { 0.35, 1.0 }, chest = { 0.25, 1.0 }, backpack = { 0.45, 0.95 } },
    -- Names for the log and the crew menu (and rivals.lua's TIERS by name): below 1/3 budget, below 2/3 mid, else geared.
    NAMES = { { 0.34, "budget" }, { 0.67, "mid" }, { 2, "geared" } },
}
G.CFG = CFG

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(r, t) return r[1] + (r[2] - r[1]) * t end

-- Your level --------------------------------------------------------------------------------------------------------
local cached, readAt = nil, -100

-- Your player level as last seen in the menu (raid-side controllers have no stats: GetXP() is 0 there), or 1.
function G.level()
    if os.clock() - readAt > 10 then
        readAt = os.clock()
        local f = io.open(LEVEL_FILE, "r")
        if f then
            local lvl, max = f:read("n", "n")
            f:close()
            if lvl and lvl >= 1 then cached = math.floor(lvl) end
            if max and max >= 2 then CFG.LEVEL_MAX = math.floor(max) end
        end
    end
    return cached or 1
end

-- From the menu: remember the level (and the cap) for raids and later sessions. Returns true when it changed.
function G.setLevel(lvl, max)
    lvl = math.floor(tonumber(lvl) or 0)
    if lvl < 1 then return false end
    if max and max >= 2 then CFG.LEVEL_MAX = math.floor(max) end
    if lvl == cached then return false end
    cached, readAt = lvl, os.clock()
    local f = io.open(LEVEL_FILE, "w")
    if f then f:write(("%d %d\n"):format(lvl, CFG.LEVEL_MAX)) f:close() end
    return true
end

-- How far along you are, 0 at level 1 .. 1 at LEVEL_MAX.
function G.progress()
    return clamp((G.level() - 1) / math.max(1, CFG.LEVEL_MAX - 1), 0, 1)
end

-- The centre of the roll at your level.
function G.target() return lerp(CFG.TARGET, G.progress()) end

-- Rolling -----------------------------------------------------------------------------------------------------------
-- A person's gear grade. `bias` shifts the centre (crew: their own level adds a little).
function G.roll(bias)
    if math.random() < CFG.OUTLIER then return math.random() end
    local c = G.target() + (bias or 0)
    if math.random() < CFG.DOWN_SHARE then
        return clamp(c - CFG.SPREAD_DOWN * math.random(), 0, 1)
    end
    local u = math.random()
    return clamp(c + CFG.SPREAD_UP * u * u, 0, 1)
end

function G.name(g)
    for _, n in ipairs(CFG.NAMES) do if g < n[1] then return n[2] end end
    return CFG.NAMES[#CFG.NAMES][2]
end

-- A tier-shaped table for grade g (what rivals.lua and hire.lua pass around): name, the grade, and wear chances.
function G.spec(g)
    return { name = G.name(g), g = g, helmet = lerp(CFG.WEAR.helmet, g), chest = lerp(CFG.WEAR.chest, g),
        backpack = lerp(CFG.WEAR.backpack, g) }
end

local sortedCache = setmetatable({}, { __mode = "k" })
local function sorted(list)
    local s = sortedCache[list]
    if not s then
        s = {}
        for i, r in ipairs(list) do s[i] = r end
        table.sort(s, function(a, b) return a[2] < b[2] end)
        sortedCache[list] = s
    end
    return s
end

-- A row of `list` ({ row, price, ... }) near grade g (with this piece's own jitter).
function G.pick(list, g)
    local s = sorted(list)
    local n = #s
    if n == 0 then return nil end
    if n == 1 then return s[1] end
    local at = clamp(g + (math.random() * 2 - 1) * CFG.PIECE_JITTER, 0, 1)
    local fits = {}
    for i, r in ipairs(s) do
        if math.abs((i - 1) / (n - 1) - at) <= CFG.WINDOW then fits[#fits + 1] = r end
    end
    if #fits == 0 then return s[math.floor(at * (n - 1) + 0.5) + 1] end
    return fits[math.random(#fits)]
end

return G
