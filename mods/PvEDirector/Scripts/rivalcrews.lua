-- Rivals, part: who the rival crews are: crews and members, their names, kits and ships, and the map's kind.
-- Moved verbatim from rivals.lua (issue #149, sections: Crews); rivals.lua requires it and keeps the
-- public side. Its helpers and constants (and earlier modules' functions) come through require("rivalshared");
-- main's context (X) and the per-raid state (S) arrive through M.bind whenever rivals.lua changes them.
local H = require("rivalshared")
local M = {}
local X, S
function M.bind(x, s) X, S = x, s end
local CFG, GearScale, PILOTS, R, SHIP_NAMES, pick = H.CFG, H.GearScale, H.PILOTS, H.R, H.SHIP_NAMES, H.pick
local rnd, weighted = H.rnd, H.weighted
-- Crews ----------------------------------------------------------------------------------------------------------
local function newMember(usedNames)
    -- gear grade around your level (gearscale.lua); CFG.TIERS' fixed odds are only used with SCALE_GEAR off
    local scale = CFG.SCALE_GEAR ~= false and CFG.SCALE_GEAR ~= 0
    local tier = scale and GearScale.spec(GearScale.roll()) or weighted(CFG.TIERS)
    -- A free name; once all PILOTS are taken (11 crews + 6 skirmish pairs + ship watches is more than the list), a
    -- numbered one. This used to `repeat pick until unused`, which never ended then and froze the game mid-flight.
    local free = {}
    for _, n in ipairs(PILOTS) do if not usedNames[n] then free[#free + 1] = n end end
    local name = #free > 0 and pick(free) or nil
    if not name then
        local base, k = pick(PILOTS), 2
        while usedNames[base .. k] do k = k + 1 end
        name = base .. k
    end
    usedNames[name] = true
    local m = { name = name, tier = tier, alive = true, look = {}, skill = math.random() }
    m.female = math.random() < CFG.FEMALE
    m.voice = X.voice.pick(m.female)
    m.helmet = math.random() < tier.helmet
    m.chest = math.random() < tier.chest
    m.backpack = math.random() < tier.backpack
    m.maxHp = CFG.BASE_HP
    m.hp = m.maxHp
    return m
end

local function mapKind(worldName)
    if worldName:find("Raider", 1, true) then return "raider" end
    if worldName:find("Solo", 1, true) then return "solo" end
    return "crew"
end

-- A whole number in a { least, most } setting (the tuning menu can leave least above most).
local function between(r)
    local a, b = math.floor(r[1]), math.floor(r[2])
    if a > b then a, b = b, a end
    return math.random(a, b)
end

local function newCrew(i, used, size)
    local c = { id = i, ship = nil, members = {}, state = "waiting",
        shipName = SHIP_NAMES[(i - 1) % #SHIP_NAMES + 1],
        aggression = math.random(), -- how readily they attack other players' ships
        diehard = math.random() < CFG.DIEHARD,
        fleeHull = rnd(CFG.FLEE_HULL),
        launchAt = os.clock() + rnd(CFG.ARRIVAL_SPREAD),
        stationsLeft = between(CFG.STATIONS_PER_RAID),
        extractRemaining = rnd(CFG.EXTRACT_REMAINING),
        gunnery = rnd(CFG.GUN_SKILL) } -- how well they work their turrets (fireTurrets)
    for _ = 1, between(size) do
        local m = newMember(used)
        m.crew = i
        table.insert(c.members, m)
    end
    c.rusher = math.random() < CFG.RUSHERS
    c.captain = c.members[1].name
    return c
end

-- Event (#78): the Red Baron's crew. The map's own Red Baron frigate only turns up on some runs (the game rolls it), so
-- the guarantee is one of our crews: his strike frigate with its own guns, a full crew that fights to the death and
-- goes for any ship it sees, his best gunner, and the Baron himself as captain in the game's Baron head and coat, in
-- the best gear and with twice the health. He keeps the rivals' player-like brain (ai.lua "boss" is the weaker one).
-- (Fields of R.baron, not locals: this file's main chunk is at Lua's 200-local limit.)
R.baron = {
    head = "/Game/Characters/MainPlayer/Meshes/Heads/Baron_Head_Skel_01.Baron_Head_Skel_01",
    body = "/Game/Characters/MainPlayer/Meshes/Bodies/Baron_Body_Skel_01.Baron_Body_Skel_01",
}

function R.baron.design()
    for _, d in ipairs(CFG.HULLS) do if d.row == "StrikeFrigate_Ship" then return d end end
end

function R.baron.make(c, used)
    c.baron = true
    c.shipName = "Strike Frigate"
    c.diehard, c.rusher, c.aggression = true, false, 1
    c.gunnery = CFG.GUN_SKILL[2]
    local most = math.max(CFG.CREW_SIZE[1], CFG.CREW_SIZE[2])
    while #c.members < most do
        local m = newMember(used)
        m.crew = c.id
        table.insert(c.members, m)
    end
    local b = c.members[1]
    used["Red Baron"] = true
    b.name, b.baron = "Red Baron", true
    b.tier = GearScale.spec(1)
    b.helmet, b.chest, b.backpack = true, true, true
    b.female = false
    b.voice = X.voice.pick(false)
    b.headPath, b.bodyPath = R.baron.head, R.baron.body
    b.maxHp = CFG.BASE_HP * 2
    b.hp = b.maxHp
    c.captain = b.name
end

-- #319: "Three men have been brought in as the Red Baron. None of them was." An ordinary crew's captain wears the real
-- Baron's head and coat and the crew goes by "Red Baron" in quotes; everything else (ship, crew size, health, gear
-- roll, AI profile) stays the crew's own, so he fights like anyone. He keeps his own name underneath (log: "a man
-- calling himself the Red Baron"), and his cap is whatever his gear roll gave him, never the Baron's best kit.
function R.baron.impostor(c)
    local b = c.members[1]
    c.impostor, b.impostor = true, true
    b.female = false
    b.voice = X.voice.pick(false)
    b.headPath, b.bodyPath = R.baron.head, R.baron.body
    c.captain = '"Red Baron" ' .. b.name
end

local function makeCrews(slots, kind)
    local crews, used = {}, {}
    local n = CFG.CREWS > 0 and math.floor(CFG.CREWS) or math.min(CFG.MAX_CREWS, math.max(0, slots - 1))
    local size = CFG.CREW_SIZE
    local baron = (tonumber(CFG.BARON) or 0) >= 1 and R.baron.design() ~= nil
    -- A raid condition's guaranteed hulls (#78, conditions.lua): the crews after the Baron's fly them, fight to the
    -- death and attack what they see, like a boss.
    local ships = R.conditions and R.conditions.ships() or {}
    local first = baron and 2 or 1
    n = math.max(n, first - 1 + #ships)
    for i = 1, n do table.insert(crews, newCrew(i, used, size)) end
    if baron then R.baron.make(crews[1], used) end
    for j, row in ipairs(ships) do
        local c = crews[first - 1 + j]
        c.hullRow, c.diehard, c.rusher, c.aggression = row, true, false, 1
    end
    -- (never with the real Baron in the raid, nor on a condition's guaranteed boss hulls)
    if not baron and (tonumber(CFG.BARON) or 0) < 1 and math.random() < (tonumber(CFG.IMPOSTOR_CHANCE) or 0) then
        local plain = {}
        for _, c in ipairs(crews) do if not c.hullRow and not c.baron then plain[#plain + 1] = c end end
        if #plain > 0 then
            local c = pick(plain)
            R.baron.impostor(c)
            X.log(("[rivals] crew %d: %s, a man calling himself the Red Baron (an impostor)"):format(c.id, c.captain))
        end
    end
    return crews
end

local function crewAlive(c)
    for _, m in ipairs(c.members) do if m.alive then return true end end
    return false
end

local function crewLabel(c)
    return ("%s's %s (%d)"):format(c.captain, c.shipName, #c.members)
end


-- What rivals.lua and the later modules call
M.between, M.crewAlive, M.crewLabel, M.makeCrews = between, crewAlive, crewLabel, makeCrews
M.mapKind, M.newCrew, M.newMember = mapKind, newCrew, newMember

return M
