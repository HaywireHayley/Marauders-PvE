-- Minimap: your tasks for this raid, where they are and how to reach them, on the HUD.
-- N shows or hides it (remembered between sessions), M switches between the small map and the full overview, B picks the
-- next task to follow. bridge/minimap_cmd does the same without the keyboard: toggle, expand, next.
--
-- The small map turns with you (up = where you're facing). The overview has +X up and shows the whole place.
-- Tasks are the game's own: the raid's contracts (GetAllMissionsForRaid, progress in the game instance), the campaign step,
-- and leaving through a space gate. Each task's place comes from the contract actors missions.lua found (tags match), or
-- from the contract's RaidTag for tasks with no fixed spot, like kills.
--
-- A map has two coordinate spaces: stations seen from space are Node_* actors with RaidDockingComponents, while the
-- walkable interiors sit far away at their own coordinates. So a route is a list of stages: helm, fly to the dock, airlock,
-- then the navmesh route to the spot.
--
-- Floor plans are read from the navmesh, a little per frame, the first time a place is seen, and cached as bitmaps in
-- assets/minimap. Delete those (the place names, not the icons) to have them rebuilt.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local M = {}
local X -- context from main.lua: log, valid, lib, raid, missions

local DIR = PROJECT .. "assets/minimap/"
local SAVE_FILE = PROJECT .. "config/minimap.txt"
local CMD_FILE = PROJECT .. "bridge/minimap_cmd"
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C" -- as tuning.lua: a Blueprint with a canvas root

local CFG = {
    MINI = 300,             -- small map's side, UI units
    MINI_LEFT = 16,         -- top left: the game's contract cards and gate timer fill the top right
    MINI_TOP = 34,
    MINI_TEXT = 118,        -- text panel under the small map
    FULL_MARGIN = 54,       -- overview: gap to the window's edges
    FULL_SIDE = 470,        -- overview: width of the task column
    LOCAL_RANGE = 3200,     -- small map on foot: world units from centre to edge
    LOOSE_AIRLOCK = 20000,  -- an airlock with no station in its name joins a place this close, at most
    SPACE_MIN_RANGE = 9000, -- small map in space: never zoom in further than this
    SPACE_FIT = 1.2,        -- ...and keep the target this far inside the edge
    FRAME = 1 / 30,         -- map redraw
    THINK = 1,              -- tasks, stages and the route
    GATE_RESCAN = 20,       -- seconds between looks for space gates, once they can be there
    SURVEY_RETRY = 5,       -- until the raid's contracts and stations exist
    ROUTE_MOVED = 120,      -- on foot: a move this large refreshes the route early
    ROUTE_SPACING = 20,     -- px between route dots
    ROUTE_DOTS = 44,
    ROUTE_NEAR = 500,       -- a route ending this close to the spot gets you there
    MARGIN = 5000,          -- floor plan: around a place's known spots
    SHIP_RADIUS = 7500,     -- floor plan of your ship: around its airlock and helm
    SHIP_NEAR = 16000,      -- on foot this close to your ship's airlock: you're aboard
    CELL = 100,             -- floor plan: world units per pixel
    FLOOR = 250,            -- floor plan: surfaces this far apart in height count as separate
    SCAN_BUDGET = 0.002,    -- floor plan: seconds per frame
    SCAN_RETRY = 8,         -- floor plan: seconds between tries when no floor is found
    SCAN_TRIES = 6,
    MENU_TYPES = { [1] = true }, -- Deliver: done from the menu, not in a raid
    SHOW_KILLS = true,      -- grey X where each enemy you killed fell (this raid, this place; #326)
    SHOW_DROPS = true,      -- bag where you dropped an item with J (#326)
    SHOW_CREW = true,       -- your crewmates (#326)
    MAX_KILLS = 40,         -- oldest dropped beyond this
    MAX_DROPS = 20,
    KILL_WINDOW = 3,        -- a death counts as yours if your kill list grew within this many seconds of it
}
M.CFG = CFG

local COLOR = {
    panel = { R = 0.002, G = 0.003, B = 0.005, A = 0.86 }, -- linear colours: these read much brighter on screen
    map = { R = 0.003, G = 0.005, B = 0.008, A = 0.95 },
    accent = { R = 0.9, G = 0.35, B = 0.1, A = 1 },
    me = { R = 1, G = 1, B = 1, A = 1 },
    target = { R = 1, G = 0.55, B = 0.12, A = 1 },
    route = { R = 1, G = 0.62, B = 0.2, A = 0.9 },
    plan = { R = 0.25, G = 0.25, B = 0.25, A = 0.9 },
    ahtu = { R = 0.9, G = 0.9, B = 0.9, A = 0.95 }, -- Ahtu's illustrated maps: drawn near their own colours
    place = { R = 0.55, G = 0.75, B = 0.85, A = 0.9 },
    gate = { R = 0.3, G = 0.95, B = 0.5, A = 1 },
    kill = { R = 0.35, G = 0.35, B = 0.35, A = 0.95 },
    drop = { R = 0.95, G = 0.8, B = 0.3, A = 1 },
    crew = { R = 0.25, G = 0.65, B = 1, A = 1 },
}

-- Levels whose file name doesn't read well.
local NAMES = { Asteriod_Mine_01 = "Asteroid Mine", Capital_Frigate_01_Ai_Interior = "Capital Ship",
    Strike_Frigate_01_Ai_Interior = "Strike Frigate", Fast_Frigate_01_Ai_Interior = "Fast Frigate" }
-- A contract's RaidTag, where its first letters don't match the level's. Levels and tags are compared on those letters.
local TAG_KEYS = { priso = "penal" }

local S       -- per-world state: places, tasks, stages, route
local ui      -- the widgets
local shown, expanded = true, false
local stepLogged
-- This raid's extra markers (#326): copied vectors only, never actors. { world, kills, drops, deaths }; each mark is
-- { at = vector, place = the place you were in }. Lives outside S because deaths and drops can come before the map does.
local marks = {}

local function valid(o) return X.valid(o) end

local function dist(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

local function copy(l) return { X = l.X, Y = l.Y, Z = l.Z } end

local function key5(s) return s:lower():gsub("^node_", ""):gsub("[^a-z]", ""):sub(1, 5) end

local function levelOf(o) return o:GetFullName():match("([%w_]+):PersistentLevel") end

local function loadSettings()
    local f = io.open(SAVE_FILE, "r")
    if not f then return end
    local line = f:read("l")
    f:close()
    if line == "hidden" then shown = false end
end

local function saveSettings()
    local f = io.open(SAVE_FILE, "w")
    if not f then return end
    f:write(shown and "shown" or "hidden", "\n")
    f:close()
end

function M.init(ctx)
    X = ctx
    loadSettings()
end

-- Places ---------------------------------------------------------------------------------------------------------
-- Markers from other modules (#326) ------------------------------------------------------------------------------
local function markList(name)
    local w = X.raid().world
    if marks.world ~= w then marks = { world = w, kills = {}, drops = {}, deaths = {} } end
    return marks[name]
end

local function addMark(name, at, cap)
    local list = markList(name)
    list[#list + 1] = { at = copy(at), place = S and S.me and S.me.place or nil, t = os.clock() }
    while #list > cap do table.remove(list, 1) end
end

-- An enemy soldier died here (main.lua's Multi_Deathevent hook). Held until the kill list says whether it was yours.
function M.noteDeath(at) if at then addMark("deaths", at, 16) end end

-- Your kill list grew by n (killstats.lua): the newest n recent deaths become kill markers.
function M.noteKills(n)
    local deaths, now = markList("deaths"), os.clock()
    while n > 0 and #deaths > 0 do
        local d = table.remove(deaths)
        if now - d.t <= CFG.KILL_WINDOW then
            local kills = markList("kills")
            kills[#kills + 1] = d
            while #kills > CFG.MAX_KILLS do table.remove(kills, 1) end
            n = n - 1
        end
    end
end

-- You dropped an item here (invqol.lua's J). The game picks the exact spot near your feet.
function M.noteDrop(at) if at then addMark("drops", at, CFG.MAX_DROPS) end end

local function placeFor(lvl)
    local p = S.places[lvl]
    if not p then
        p = { key = lvl, level = lvl, spots = {}, airlocks = {}, tag = key5(lvl),
            name = NAMES[lvl] or lvl:gsub("_%d+$", ""):gsub("Whitebox", ""):gsub("(%l)(%u)", "%1 %2"):gsub("_", " ") }
        S.places[lvl] = p
    end
    return p
end

local function setRect(p)
    if #p.spots == 0 then return end
    local x0, x1, y0, y1, z0, z1 = 1e12, -1e12, 1e12, -1e12, 1e12, -1e12
    for _, l in ipairs(p.spots) do
        x0, x1, y0, y1 = math.min(x0, l.X), math.max(x1, l.X), math.min(y0, l.Y), math.max(y1, l.Y)
        z0, z1 = math.min(z0, l.Z), math.max(z1, l.Z)
    end
    local m = CFG.MARGIN
    p.rect = { x0 = x0 - m, x1 = x1 + m, y0 = y0 - m, y1 = y1 + m, z0 = z0 - 1500, z1 = z1 + 1500 }
end

-- Your ship is a place too: its interior moves between raids, so its floor plan is stored relative to the airlock.
-- (locate() calls this on every redraw on foot, 30 times a second, until S.ship exists. Its two FindAllOf walk every
-- object, 44-101 ms each on space maps: while a ship's airlock or helm wasn't found, that was two scans per redraw,
-- about 10 fps for as long as you were on foot with the map shown. Now a miss waits SURVEY_RETRY before the next look.)
local function surveyShip(home)
    local p = S.ship
    if p or not valid(home) then return end
    local now = os.clock()
    if now < (S.shipSurveyAt or 0) then return end
    S.shipSurveyAt = now + CFG.SURVEY_RETRY
    local locks, helms = {}, {}
    for _, c in ipairs(FindAllOf("RaidUseableAirLockComponent") or {}) do
        if valid(c) and not c.StationAirLock and c:GetOwner():GetAddress() == home:GetAddress() then
            locks[#locks + 1] = copy(c:K2_GetComponentLocation())
        end
    end
    for _, c in ipairs(FindAllOf("RaidUseableFrigateHelmComponent") or {}) do
        if valid(c) and c:GetOwner():GetAddress() == home:GetAddress() then
            helms[#helms + 1] = copy(c:K2_GetComponentLocation())
        end
    end
    if #locks == 0 or #helms == 0 then
        if not S.shipSurveyMiss then
            S.shipSurveyMiss = true
            X.log(("minimap: your ship (%s) has %d airlock(s) and %d helm(s) of its own: no ship map yet, looking again every %d s")
                :format(home:GetClass():GetFName():ToString(), #locks, #helms, CFG.SURVEY_RETRY))
        end
        return
    end
    local a, r = locks[1], CFG.SHIP_RADIUS
    a = { X = math.floor(a.X), Y = math.floor(a.Y), Z = a.Z }
    S.ship = { key = "ship_" .. home:GetClass():GetFName():ToString(), name = "your ship", isShip = true, tag = "", airlocks = {},
        lock = a, helms = helms, spots = { a, table.unpack(helms) },
        rect = { x0 = a.X - r, x1 = a.X + r, y0 = a.Y - r, y1 = a.Y + r, z0 = a.Z - 1500, z1 = a.Z + 2500 } }
end

-- A place on the map: a station seen from space (its docking node), an AI frigate (its hull), or, for a co-op joiner,
-- any interior with spots: the host's game doesn't send a joiner the far stations' Node_* actors (0 of them, measured,
-- while its airlocks and contract actors are all there), so a joiner gets floor plans and tasks but no flying route
-- (#214: its minimap was an empty box).
local function known(p)
    return p.node or p.hull or (S.joiner and p.spots and #p.spots > 0)
end

local function survey()
    local list = X.missions.actors()
    if #list == 0 then return false end
    S.places, S.nodes, S.targets = {}, {}, {}
    for _, c in ipairs(list) do
        local lvl = c.level and placeFor(c.level)
        if lvl then table.insert(lvl.spots, c.at) end
        for _, t in ipairs(c.tags) do
            S.targets[t] = S.targets[t] or {}
            table.insert(S.targets[t], { at = c.at, place = lvl, name = c.name })
        end
    end
    -- Airlocks of the newer maps (StationAirlockDockingAreaAbility<Station>_N) sit in the space map's own level, not the
    -- station's: they go to the place their name points to (TAG_KEYS too), else the nearest place. Before this they made
    -- a "Space Beta" place of their own, holding you once you were through (wrong station, empty map).
    local loose = {}
    for _, c in ipairs(FindAllOf("RaidUseableAirLockComponent") or {}) do
        if valid(c) and c.StationAirLock then
            local owner = c:GetOwner()
            local lvl = levelOf(owner)
            local l = copy(c:K2_GetComponentLocation())
            if lvl and lvl:find("^Space_") then
                loose[#loose + 1] = { at = l, dock = owner }
            elseif lvl then
                local p = placeFor(lvl)
                table.insert(p.spots, l)
                table.insert(p.airlocks, { at = l, dock = owner })
            end
        end
    end
    for _, a in ipairs(loose) do
        local k = key5(a.dock:GetFName():ToString():gsub("^StationAirlockDockingAreaAbility_?", ""))
        k = TAG_KEYS[k] or k
        local best, bd
        for _, p in pairs(S.places) do
            if p.tag == k then best, bd = p, -1 break end
            for _, s in ipairs(p.spots) do
                local d = dist(s, a.at)
                if d < CFG.LOOSE_AIRLOCK and (not bd or (bd >= 0 and d < bd)) then best, bd = p, d end
            end
        end
        if best then
            table.insert(best.spots, a.at)
            table.insert(best.airlocks, a)
        end
    end
    for _, p in pairs(S.places) do setRect(p) end
    -- What's actually in this map, seen from space: stations (their docking components)...
    for _, c in ipairs(FindAllOf("RaidDockingComponent") or {}) do
        if valid(c) then
            local owner = c:GetOwner()
            local k = key5(owner:GetClass():GetFName():ToString())
            local n = S.nodes[k]
            if not n then
                n = { docks = {}, at = copy(owner:K2_GetActorLocation()) }
                S.nodes[k] = n
                for _, p in pairs(S.places) do
                    if p.tag == k then p.node, n.place = n, p end
                end
            end
            table.insert(n.docks, copy(c:K2_GetComponentLocation()))
        end
    end
    -- ...and big AI frigates whose interior holds contract actors: those fly around, so they're followed live.
    for _, ins in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if valid(ins) and ins.IsAnAIShip and valid(ins.SpaceshipToPairTo) then
            local l = ins:K2_GetActorLocation()
            for _, p in pairs(S.places) do
                if not p.node and p.spots[1] and dist(l, p.spots[1]) < 12000 then p.hull = ins.SpaceshipToPairTo end
            end
        end
    end
    local n, names = 0, {}
    for _, p in pairs(S.places) do
        if known(p) then n = n + 1 names[n] = p.name end
    end
    X.log(("minimap: %d places here: %s"):format(n, table.concat(names, ", ")))
    return n > 0
end

-- Tasks ----------------------------------------------------------------------------------------------------------
local function readRow(m, row)
    local tags = {}
    pcall(function() m.ContractRequiredActorTags:ForEach(function(_, t) tags[#tags + 1] = t:get():ToString() end) end)
    local title, summary, raidTag = "", "", ""
    pcall(function() title = m.ContractTitle:ToString() end)
    pcall(function() summary = m.InMatchSummary:ToString() end)
    pcall(function() raidTag = m.RaidTag:ToString() end)
    return { row = row, title = title, summary = summary, type = m.ContractType, need = m.ContractMaxAmountNeeded,
        tags = tags, raidTag = raidTag, progress = 0 }
end

local function loadTasks(pc)
    S.contracts = {}
    for _, e in ipairs(pc:GetAllMissionsForRaid() or {}) do
        local m = e:get()
        local t = readRow(m, m.RowName:ToString())
        t.kind = "contract"
        table.insert(S.contracts, t)
    end
    -- (kept on S, as refreshProgress does: with no contract and no chapter task this is tried again every think, and a
    -- FindFirstOf each second is a hitch each second for the whole raid)
    S.gi = valid(S.gi) and S.gi or FindFirstOf("SIGIS_ExampleGameInstance_C") -- pc:GetGameInstance() throws from Lua here
    local gi = S.gi
    local c = gi.PrologueChapter
    local stage, chapter = c.ChapterStage, c.Chapter:ToString()
    local rows = pc:GetAllMissionsForChapters(chapter)
    local e = rows and rows[stage + 1]
    if e then
        S.chapter = readRow(e:get(), "chapter")
        S.chapter.kind = "campaign"
    end
    return #S.contracts > 0 or S.chapter ~= nil
end

local function refreshProgress(pc)
    S.gi = valid(S.gi) and S.gi or FindFirstOf("SIGIS_ExampleGameInstance_C") -- once: this runs every think, and a scan is 30-45 ms
    local gi = S.gi
    local by = {}
    gi.ActiveMissions:ForEach(function(_, e)
        local m = e:get()
        by[m.MissionRow:ToString()] = m.Progress
    end)
    for _, t in ipairs(S.contracts) do t.progress = by[t.row] or t.progress end
    if S.chapter then S.chapter.progress = gi.PrologueChapter.Progress end
end

local function placeByTag(tag)
    if tag == "" then return nil end
    local k = key5(tag)
    k = TAG_KEYS[k] or k
    for _, p in pairs(S.places) do
        if p.tag == k and known(p) then return p end
    end
end

-- The nearest spot for a task: where it says, or nil when it can be done anywhere.
local function targetFor(t, me)
    local best, bd
    for _, tag in ipairs(t.tags) do
        for _, c in ipairs(S.targets[tag] or {}) do
            local there = c.place and (c.place.node or c.place.hull or c.place == me.place)
            local d = there and dist(c.at, me.at)
            if d and (not bd or d < bd) then best, bd = c, d end
        end
    end
    if best then return best end
    local p = placeByTag(t.raidTag)
    return p and { place = p, wide = true } or nil
end

-- Seconds until the space gate comes. The game spawns it TimeTillEvacSpawn into the raid, which the launcher's "Space gate"
-- setting changes (raidtime.lua); RemainingTime - 1200 (the stock HUD's rule) only holds in a 25 minute raid with the
-- stock gate: with the gate on "instant" the minimap counted down 4 minutes to a gate that was already there.
-- A joiner has no game mode: it keeps the stock rule.
local function gateIn(gs)
    if not valid(gs) then return 0 end
    if gs.EvacSpawned then return 0 end
    local gm = gs.AuthorityGameMode
    local left = gs.RemainingTime
    if valid(gm) and left <= (gm.WarmupTime or 15) + 1 then return math.max(0, gm.TimeTillEvacSpawn) end -- warmup
    if valid(gm) then return math.max(0, gm.TimeTillEvacSpawn - (gm.RoundTime - left)) end
    return math.max(0, left - 1200)
end

-- Gates appear when the timer runs out, so the scan only runs then, and rarely: every think it was a hitch a second.
local function gates()
    local now = os.clock()
    if (S.gateIn and S.gateIn > 0) or now < (S.gatesAt or 0) then return S.gates or {} end
    local r = {}
    for _, g in ipairs(FindAllOf("EscapeZoneSpaceGate_C") or {}) do
        if valid(g) then r[#r + 1] = copy(g:K2_GetActorLocation()) end
    end
    S.gatesAt = now + (#r > 0 and CFG.GATE_RESCAN * 6 or CFG.GATE_RESCAN)
    return r
end

local function gateTask(me)
    local t = { kind = "exit", title = "Leave through a space gate", summary = "Fly into a gate to take your loot home", tags = {},
        need = 1, progress = 0 }
    local best, bd
    for _, l in ipairs(S.gates) do
        local d = me.space and dist(l, me.space) or 0
        if not bd or d < bd then best, bd = l, d end
    end
    if best then t.target = { at = best, space = true, name = "space gate" } end
    return t
end

local function activeTasks(me)
    local r = {}
    for _, t in ipairs(S.contracts) do
        if t.progress < t.need then r[#r + 1] = t end
    end
    if S.chapter and S.chapter.progress < S.chapter.need then r[#r + 1] = S.chapter end
    r[#r + 1] = gateTask(me)
    for _, t in ipairs(r) do
        if t.kind ~= "exit" then t.target = targetFor(t, me) end
    end
    return r
end

-- A task nothing here can advance (it's for another map, or the menu) can't be followed.
local function followable(t)
    return t.target ~= nil and not CFG.MENU_TYPES[t.type] or t.kind == "exit"
end

-- Where you are --------------------------------------------------------------------------------------------------
local function inRect(r, l) return l.X >= r.x0 and l.X <= r.x1 and l.Y >= r.y0 and l.Y <= r.y1 end

-- Your ship's interior: the director's (space.lua), or for a co-op joiner, whose director never finds one (that's the
-- host's job), the nearest player ship interior to you, looked up once (it's the ship you came aboard).
local function homeInside(pawn)
    local home = X.raid().home
    if valid(home) or not S.joiner then return home end
    if valid(S.joinHome) then return S.joinHome end
    if S.joinHomeTried then return nil end
    S.joinHomeTried = true
    local at, best, bd = pawn:K2_GetActorLocation(), nil, nil
    for _, ins in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if valid(ins) and not ins.IsAnAIShip then
            local d = dist(at, ins:K2_GetActorLocation())
            if not bd or d < bd then best, bd = ins, d end
        end
    end
    S.joinHome = best
    return best
end

local function locate(pc)
    local pawn = pc.Pawn
    if not valid(pawn) then return nil end
    local home = homeInside(pawn)
    local me = { at = copy(pawn:K2_GetActorLocation()) }
    me.piloting = pawn:GetClass():GetFName():ToString():find("^Ship_") ~= nil
    me.yaw = me.piloting and pawn:K2_GetActorRotation().Yaw or pc:GetControlRotation().Yaw
    if me.piloting then
        me.space, me.spaceYaw = me.at, me.yaw
        return me
    end
    surveyShip(home)
    if S.ship and dist(me.at, S.ship.lock) < CFG.SHIP_NEAR then
        me.place = S.ship
    else
        for _, p in pairs(S.places or {}) do
            if p.rect and inRect(p.rect, me.at) then me.place = p break end
        end
    end
    local hull = valid(home) and home.SpaceshipToPairTo
    if valid(hull) then
        me.space, me.spaceYaw = copy(hull:K2_GetActorLocation()), hull:K2_GetActorRotation().Yaw
    end
    return me
end

-- Which station your ship is docked at, if any: the docking volume it's holding.
local function dockedAt()
    local home = X.raid().home
    if not valid(home) and S.joiner then home = S.joinHome end
    if not valid(home) then return nil end
    local vol = home.CurrentDockingVolume
    if not valid(vol) then return nil end
    local n = S.nodes[key5(vol:GetOwner():GetClass():GetFName():ToString())]
    return n and n.place
end

-- Stages ---------------------------------------------------------------------------------------------------------
local function howto(t)
    local left = math.max(1, t.need - t.progress)
    if t.type == 5 then return ("Look at it and hold F for %d s"):format(left) end
    if t.type == 6 then return ("Stay in the area for %d s"):format(left) end
    if t.type == 2 or t.type == 7 then return ("%d kills to go"):format(left) end
    if t.type == 3 then return ("%d to destroy"):format(left) end
    return t.summary
end

local function km(d)
    if d >= 100000 then return ("%.1f km"):format(d / 100000) end
    return ("%.0f m"):format(d / 100)
end

-- In words, for flying: where the spot is from the nose.
local function bearing(me, at)
    local dx, dy = at.X - me.at.X, at.Y - me.at.Y
    local side = (math.deg(math.atan(dy, dx)) - me.yaw + 180) % 360 - 180
    local turn
    if math.abs(side) < 12 then turn = "dead ahead"
    elseif math.abs(side) > 160 then turn = "behind you"
    else turn = ("%.0f deg %s"):format(math.abs(side), side > 0 and "right" or "left") end
    local flat, up = math.sqrt(dx * dx + dy * dy), at.Z - me.at.Z
    if math.abs(up) > math.max(1500, flat * 0.15) then turn = turn .. (up > 0 and ", above you" or ", below you") end
    return turn
end

local function nearest(list, from)
    local best, bd
    for _, l in ipairs(list) do
        local d = dist(l, from)
        if not bd or d < bd then best, bd = l, d end
    end
    return best
end

-- Where a place is, from space.
local function spaceSpot(place, from)
    if place.hull and valid(place.hull) then return copy(place.hull:K2_GetActorLocation()) end
    return place.node and nearest(place.node.docks, from) or nil
end

-- The next thing to do for a task. Returns { text, at (spot), walk (navmesh route), space (fly straight) }.
local function stage(t, me)
    local g = t.target
    local place = g and g.place
    if not g then
        if t.kind == "exit" then
            return { text = ("Gate arrives in %d:%02d"):format(S.gateIn // 60, S.gateIn % 60) }
        end
        return { text = t.summary }
    end
    local docked = dockedAt()
    if me.piloting then
        if g.space then
            return { text = ("Fly to the %s: %s, %s"):format(g.name, km(dist(me.at, g.at)), bearing(me, g.at)), at = g.at, space = true }
        end
        local spot = spaceSpot(place, me.at)
        if not spot then return { text = t.summary } end
        local arrive = dist(me.at, spot) < 3000 and "Fly into the docking arm at " .. place.name
            or ("Fly to %s: %s, %s"):format(place.name, km(dist(me.at, spot)), bearing(me, spot))
        return { text = arrive, at = spot, space = true }
    end
    if me.place and me.place.isShip then
        local ship = me.place
        -- (a target with no place, out in space: nil == nil here read place.name, 488 errors in one raid, #42's log)
        if place and docked == place then
            return { text = "Go through the airlock into " .. place.name, at = ship.lock, walk = true }
        end
        local helm = nearest(ship.helms, me.at)
        return { text = docked and "Go to the helm and press F to undock" or "Go to the helm and press F to fly", at = helm, walk = true }
    end
    if me.place then
        if me.place == place then
            if g.wide then return { text = howto(t) .. " in " .. place.name } end
            return { text = howto(t), at = g.at, walk = true }
        end
        -- Back the way you came in: not every station has airlock objects (Mini Mine, Merchant).
        local locks = {}
        for _, a in ipairs(me.place.airlocks) do locks[#locks + 1] = a.at end
        local came = S.entry and S.entry.place == me.place and S.entry.at
        local out = came and (nearest(locks, came) or came) or nearest(locks, me.at)
        if out then return { text = "Back to your ship through the airlock", at = out, walk = true } end
    end
    return { text = "Get back to your ship" }
end

-- Routes ---------------------------------------------------------------------------------------------------------
local function walkRoute(pc, s, me)
    local nav = X.lib("/Script/NavigationSystem.Default__NavigationSystemV1")
    local path = nav:FindPathToLocationSynchronously(pc, me.at, s.at, nil, nil)
    local pts = {}
    if valid(path) then
        path.PathPoints:ForEach(function(_, e)
            local v = e:get()
            pts[#pts + 1] = { X = v.X, Y = v.Y, Z = v.Z }
        end)
        s.length = path:GetPathLength()
        -- Contract objects stand on walls and desks, off the navmesh, so a route to one always counts as partial for the
        -- engine. It only falls short if it ends well away from the spot.
        s.partial = #pts > 0 and dist(pts[#pts], s.at) > CFG.ROUTE_NEAR
    end
    return pts
end

-- Evenly spaced dots along a route, at the map's current scale, spread out if that's what it takes to reach the end.
local function dotsAlong(pts, scale)
    local total = 0
    for i = 2, #pts do total = total + dist(pts[i - 1], pts[i]) end
    local dots, step = {}, math.max(CFG.ROUTE_SPACING / scale, total / CFG.ROUTE_DOTS)
    local carry = step
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local len = dist(a, b)
        local at = carry
        while at < len and #dots < CFG.ROUTE_DOTS do
            local f = at / len
            dots[#dots + 1] = { X = a.X + (b.X - a.X) * f, Y = a.Y + (b.Y - a.Y) * f, Z = a.Z }
            at = at + step
        end
        carry = at - len
    end
    return dots
end

-- Floor plans ----------------------------------------------------------------------------------------------------
local function planPath(p) return DIR .. p.key .. ".png" end

local function readPlan(p)
    local f = io.open(DIR .. p.key .. ".txt", "r")
    if not f then return false end
    local w, h = f:read("n", "n")
    f:close()
    if not w or not h then return false end
    p.plan = { w = w, h = h }
    return true
end

-- Lua has no image writer and ImportFileAsTexture2D reads PNG (not BMP), so this is a PNG with its data stored uncompressed.
local crcTable
local function crc32(data)
    if not crcTable then
        crcTable = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do c = c & 1 == 1 and 0xEDB88320 ~ (c >> 1) or c >> 1 end
            crcTable[i] = c
        end
    end
    local c = 0xFFFFFFFF
    for i = 1, #data do c = crcTable[(c ~ data:byte(i)) & 255] ~ (c >> 8) end
    return c ~ 0xFFFFFFFF
end

local function adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b << 16 | a
end

local function pngChunk(kind, data)
    return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", crc32(kind .. data))
end

local function encodePng(w, h, raw)
    local parts = { string.char(0x78, 0x01) } -- zlib header, then stored blocks
    local at, size = 1, #raw
    while at <= size do
        local n = math.min(65535, size - at + 1)
        parts[#parts + 1] = string.pack("<BI2I2", at + n > size and 1 or 0, n, ~n & 0xFFFF)
        parts[#parts + 1] = raw:sub(at, at + n - 1)
        at = at + n
    end
    parts[#parts + 1] = string.pack(">I4", adler32(raw))
    return string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) .. pngChunk("IHDR", string.pack(">I4I4BBBBB", w, h, 8, 6, 0, 0, 0))
        .. pngChunk("IDAT", table.concat(parts)) .. pngChunk("IEND", "")
end

-- Top of the image = +X, right = +Y. Off the floor is transparent.
local function writePlan(p, scan)
    local w, h, cells = scan.w, scan.h, scan.cells
    local lo, hi = scan.lo, scan.hi
    if hi <= lo then hi = lo + 1 end
    local rows = {}
    for y = 0, h - 1 do
        local row = { string.char(0) } -- PNG filter byte: none
        for x = 0, w - 1 do
            local z = cells[y * w + x]
            local px = string.char(0, 0, 0, 0)
            if z then
                local edge = not (cells[y * w + x - 1] and cells[y * w + x + 1] and cells[(y - 1) * w + x] and cells[(y + 1) * w + x])
                local lift = (z - lo) / (hi - lo)
                if edge then px = string.char(150, 185, 205, 255)
                else px = string.char(48 + math.floor(lift * 40), 66 + math.floor(lift * 48), 84 + math.floor(lift * 56), 255) end
            end
            row[#row + 1] = px
        end
        rows[#rows + 1] = table.concat(row)
    end
    local f = io.open(planPath(p), "wb")
    if not f then return false end
    f:write(encodePng(w, h, table.concat(rows)))
    f:close()
    f = io.open(DIR .. p.key .. ".txt", "w")
    if f then
        f:write(w, " ", h, "\n")
        f:close()
    end
    p.plan = { w = w, h = h }
    return true
end

local function startScan(p)
    local r = p.rect
    local w = math.ceil((r.y1 - r.y0) / CFG.CELL)
    local h = math.ceil((r.x1 - r.x0) / CFG.CELL)
    S.scan = { place = p, w = w, h = h, cells = {}, seen = {}, queue = {}, head = 1, lo = 1e12, hi = -1e12, hits = 0,
        seeds = { table.unpack(p.spots) }, seed = 1, started = os.clock() }
    -- bridge/plan_floors (tools): every floor of every cell is kept too and written beside the plan (<key>.floors),
    -- for tools/minimap/ahtu_align.py to split the plan into floors.
    local ff = io.open(PROJECT .. "bridge/plan_floors", "r")
    if ff then ff:close() S.scan.all = {} end
    -- Where you're standing is walkable for certain, which a contract object on a shelf isn't.
    if S.me and S.me.place == p then table.insert(S.scan.seeds, 1, S.me.at) end
end

-- cachedOnly: load plans already on disk, never scan (a co-op joiner: its game has no navmesh to read; #214).
local function nextScan(cachedOnly)
    local all = {}
    if S.ship then all[1] = S.ship end
    for _, p in pairs(S.places or {}) do
        if known(p) and p.rect then all[#all + 1] = p end
    end
    local waiting = false
    for _, p in ipairs(all) do
        if not p.plan and not p.noPlan and not readPlan(p) and not cachedOnly then
            if os.clock() >= (p.retryAt or 0) then
                startScan(p)
                return
            end
            waiting = true
        end
    end
    S.scansDone = not waiting
end

-- A little of the navmesh each frame. Navmesh queries only look a short way up and down, so this floods out from known
-- spots across walkable floor, following each surface up stairs and onto other floors. It touches floor and its edges,
-- not the empty space around them. Where floors overlap the highest shows (brighter = higher).
local function stepScan(pc)
    local sc = S.scan
    local p, r = sc.place, sc.place.rect
    local nav = X.lib("/Script/NavigationSystem.Default__NavigationSystemV1")
    local cell, w, h = CFG.CELL, sc.w, sc.h
    local function visit(cx, cy, z)
        if cx < 0 or cy < 0 or cx >= w or cy >= h then return end
        local out = {}
        local q = { X = r.x1 - (cy + 0.5) * cell, Y = r.y0 + (cx + 0.5) * cell, Z = z }
        if not (Out.call(nav, "K2_ProjectPointToNavigation", pc, q, out, nil, nil, { X = cell / 2, Y = cell / 2, Z = 300 }) and out.Z) then return end
        local i = cy * w + cx
        local key = i * 64 + (math.floor(out.Z / CFG.FLOOR) % 64)
        if sc.seen[key] then return end
        sc.seen[key] = true
        local top = sc.cells[i]
        if not top then sc.hits = sc.hits + 1 end
        if not top or out.Z > top then sc.cells[i] = out.Z end
        if sc.all then sc.all[#sc.all + 1] = ("%d %d %.0f"):format(cx, cy, out.Z) end
        sc.lo, sc.hi = math.min(sc.lo, out.Z), math.max(sc.hi, out.Z)
        sc.queue[#sc.queue + 1] = { cx, cy, out.Z }
    end
    local stop = os.clock() + CFG.SCAN_BUDGET
    repeat
        if sc.head <= #sc.queue then
            local c = sc.queue[sc.head]
            sc.queue[sc.head] = false
            sc.head = sc.head + 1
            visit(c[1] + 1, c[2], c[3])
            visit(c[1] - 1, c[2], c[3])
            visit(c[1], c[2] + 1, c[3])
            visit(c[1], c[2] - 1, c[3])
        elseif sc.seed <= #sc.seeds then
            local l = sc.seeds[sc.seed]
            sc.seed = sc.seed + 1
            visit((l.Y - r.y0) // cell, (r.x1 - l.X) // cell, l.Z)
        else
            S.scan = nil
            if sc.hits == 0 then
                -- The navmesh may still be building.
                p.tries = (p.tries or 0) + 1
                p.retryAt = os.clock() + CFG.SCAN_RETRY
                if p.tries >= CFG.SCAN_TRIES then
                    p.noPlan = true
                    X.log("minimap: no walkable floor found for " .. p.name)
                end
                return
            end
            writePlan(p, sc)
            if sc.all then
                local f = io.open(DIR .. p.key .. ".floors", "w")
                if f then
                    local nl = string.char(10)
                    f:write(("rect %.0f %.0f %.0f %.0f"):format(p.rect.x0, p.rect.x1, p.rect.y0, p.rect.y1), nl,
                        table.concat(sc.all, nl), nl)
                    f:close()
                end
            end
            X.log(("minimap: floor plan of %s, %d x %d, %d floor cells, %.1f s"):format(p.name, sc.w, sc.h, sc.hits, os.clock() - sc.started))
            return
        end
    until os.clock() >= stop
end

-- Widgets --------------------------------------------------------------------------------------------------------
local function make(cls)
    return StaticConstructObject(X.lib("/Script/UMG." .. cls), ui.tree)
end

local function texture(pc, file)
    local tex = X.lib("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc, file)
    return valid(tex) and tex or nil
end

local function box(color, parent)
    local b = make("Border")
    b:SetBrushColor(color)
    local slot = (parent or ui.root):AddChildToCanvas(b)
    return b, slot
end

local function text(size, parent, wrap)
    local t = make("TextBlock")
    t.Font.Size = size
    if wrap then t:SetAutoWrapText(true) end
    local slot = (parent or ui.root):AddChildToCanvas(t)
    return t, slot
end

local function icon(file, size, color)
    local tex = ui.art[file] or ui.art.dot
    local img = make("Image")
    img:SetBrushFromTexture(tex, false)
    img:SetColorAndOpacity(color)
    local slot = ui.map:AddChildToCanvas(img)
    slot:SetSize({ X = size, Y = size })
    img:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
    img:SetVisibility(1)
    return { img = img, slot = slot, size = size, on = false }
end

local function setIcon(m, x, y)
    if not m.on then
        m.img:SetVisibility(3) -- HitTestInvisible
        m.on = true
    end
    m.slot:SetPosition({ X = x - m.size / 2, Y = y - m.size / 2 })
end

local function hideIcon(m)
    if m.on then
        m.img:SetVisibility(1)
        m.on = false
    end
end

local function build(pc)
    local lib = X.lib
    local cls = lib(HOST)
    if not valid(cls) then
        pcall(LoadAsset, (HOST:match("^[^.]+")))
        cls = lib(HOST)
    end
    if not valid(cls) then return false end
    local host = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(host) then return false end
    ui = { host = host, tree = host.WidgetTree, root = host.WidgetTree.RootWidget, art = {}, dots = {}, labels = {}, rings = {},
        gates = {}, planTex = {} }
    ui.root:ClearChildren()
    for _, f in ipairs({ "cross", "bag" }) do -- #326, optional: older art folders fall back to the dot
        ui.art[f] = texture(pc, DIR .. f .. ".png")
    end
    for _, f in ipairs({ "dot", "arrow", "target", "station", "gate" }) do
        ui.art[f] = texture(pc, DIR .. f .. ".png")
        if not ui.art[f] then
            X.log("minimap: no art in " .. DIR .. " (python -I tools/make_minimap_art.py)")
            ui = nil
            return false
        end
    end
    local layout = lib("/Script/UMG.Default__WidgetLayoutLibrary")
    local vp, s = layout:GetViewportSize(pc), layout:GetViewportScale(pc)
    ui.vw, ui.vh = vp.X / s, vp.Y / s

    ui.panel, ui.panelSlot = box(COLOR.panel)
    local _, line = box(COLOR.accent)
    ui.lineSlot = line
    _, ui.mapBack = box(COLOR.map)
    ui.map = make("CanvasPanel")
    ui.map:SetClipping(1) -- ClipToBounds: what's off the map stays inside it
    ui.mapSlot = ui.root:AddChildToCanvas(ui.map)
    ui.plan = make("Image")
    ui.planSlot = ui.map:AddChildToCanvas(ui.plan)
    ui.plan:SetVisibility(1)
    ui.plan:SetColorAndOpacity(COLOR.plan)
    for i = 1, CFG.ROUTE_DOTS do ui.dots[i] = icon("dot", 7, COLOR.route) end
    for i = 1, 8 do ui.rings[i] = icon("station", 20, COLOR.place) end
    for i = 1, 2 do ui.gates[i] = icon("gate", 22, COLOR.gate) end
    ui.kills, ui.drops, ui.crew = {}, {}, {}
    for i = 1, CFG.MAX_KILLS do ui.kills[i] = icon("cross", 10, COLOR.kill) end
    for i = 1, CFG.MAX_DROPS do ui.drops[i] = icon("bag", 13, COLOR.drop) end
    for i = 1, 4 do ui.crew[i] = icon("dot", 10, COLOR.crew) end
    ui.target = icon("target", 20, COLOR.target)
    ui.me = icon("arrow", 20, COLOR.me)
    for i = 1, 8 do
        local t, slot = text(11, ui.map)
        slot:SetAutoSize(true)
        t:SetVisibility(1)
        ui.labels[i] = { t = t, slot = slot, on = false }
    end
    -- Ahtu's maps are credited while one is shown (their wish: "Illustrated by Ahtu").
    ui.credit, ui.creditSlot = text(9, ui.map)
    ui.creditSlot:SetAutoSize(true)
    ui.credit:SetText(FText("Map illustrated by Ahtu"))
    ui.credit:SetOpacity(0.7)
    ui.credit:SetVisibility(1)
    ui.title, ui.titleSlot = text(15)
    ui.step, ui.stepSlot = text(13, nil, true)
    ui.list, ui.listSlot = text(13, nil, true)
    ui.keys, ui.keysSlot = text(11)
    ui.keys:SetOpacity(0.6)
    ui.keys:SetText(FText("M  small map     B  next task     N  hide"))
    host:AddToViewport(-1) -- below the game's own widgets, so the inventory and Esc menu cover it
    return true
end

local function place(slot, x, y, w, h)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
end

local function applyLayout()
    local big = expanded
    ui.big = big
    if big then
        local m = CFG.FULL_MARGIN
        local h = ui.vh - m * 2
        local side = CFG.FULL_SIDE
        local mapW = math.min(ui.vw - m * 2 - side - 24, h - 24)
        local panelW = mapW + side + 36
        local x = (ui.vw - panelW) / 2
        ui.view = { x = x + 12, y = m + 12, w = mapW, h = mapW }
        place(ui.panelSlot, x, m, panelW, mapW + 24)
        place(ui.lineSlot, x, m, panelW, 3)
        local tx = x + mapW + 24
        place(ui.titleSlot, tx, m + 14, side, 24)
        place(ui.stepSlot, tx, m + 42, side, 60)
        place(ui.listSlot, tx, m + 132, side, mapW - 154)
        place(ui.keysSlot, tx, m + mapW - 6, side, 20)
        ui.keys:SetVisibility(3)
        ui.list:SetVisibility(3)
    else
        local w = CFG.MINI
        local x, y = CFG.MINI_LEFT, CFG.MINI_TOP
        ui.view = { x = x, y = y, w = w, h = w }
        place(ui.panelSlot, x - 8, y - 8, w + 16, w + 16 + CFG.MINI_TEXT)
        place(ui.lineSlot, x - 8, y - 8, w + 16, 3)
        place(ui.titleSlot, x, y + w + 6, w, 22)
        place(ui.stepSlot, x, y + w + 30, w, CFG.MINI_TEXT - 34)
        ui.keys:SetVisibility(1)
        ui.list:SetVisibility(1)
    end
    place(ui.mapBack, ui.view.x, ui.view.y, ui.view.w, ui.view.h)
    place(ui.mapSlot, ui.view.x, ui.view.y, ui.view.w, ui.view.h)
end

-- Map drawing ----------------------------------------------------------------------------------------------------
-- Screen position of a world spot, inside the map. off = true when it had to be pulled in to the edge.
local function project(v, at)
    local dx, dy = (at.Y - v.focus.Y) * v.scale, (v.focus.X - at.X) * v.scale
    local x, y = dx * v.cos - dy * v.sin, dx * v.sin + dy * v.cos
    return v.cx + x, v.cy + y
end

local function clamped(v, x, y)
    local m = 12
    local cx, cy = math.max(m, math.min(ui.view.w - m, x)), math.max(m, math.min(ui.view.h - m, y))
    return cx, cy, cx ~= x or cy ~= y
end

local function setView(v, focus, scale, angle)
    v.focus, v.scale, v.angle = focus, scale, angle
    local a = math.rad(angle)
    v.cos, v.sin = math.cos(a), math.sin(a)
end

local function showLabel(i, s, x, y)
    local l = ui.labels[i]
    if not l then return end
    if l.text ~= s then
        l.t:SetText(FText(s))
        l.text = s
    end
    if not l.on then
        l.t:SetVisibility(3)
        l.on = true
    end
    l.slot:SetPosition({ X = x, Y = y })
end

local function hideRest(list, from, off)
    for i = from, #list do off(list[i]) end
end

local function hideLabel(l)
    if l.on then
        l.t:SetVisibility(1)
        l.on = false
    end
end

-- A floor plan's texture, loaded once per minimap. The plan Image only references the texture it shows, and a texture
-- loaded from a file has nothing else holding it: once the plan switched to another place, garbage collection freed the
-- old one, and coming back reused that freed pointer from Lua. Slate then crashed painting it (an IsA on a dead object
-- in the game's UI paint): the airlock crash, issue #53, on the way back aboard or on entering a station a second time.
-- So every texture loaded also sits in a collapsed Image of its own in the minimap's widget tree, which keeps it alive
-- for as long as the minimap.
local function planTexture(path)
    local tex = ui.planTex[path]
    if tex then return tex end
    tex = texture(ui.pc, path)
    if not tex then return nil end
    local keep = make("Image")
    keep:SetBrushFromTexture(tex, false)
    keep:SetVisibility(1) -- Collapsed: never painted
    ui.root:AddChildToCanvas(keep)
    ui.planTex[path] = tex
    return tex
end

-- Ahtu's illustrated floors for a place (tools/minimap/ahtu_align.py): assets/minimap/ahtu/<key>.ahtu, one line per
-- floor, "<image> <z> <name>", each image drawn in the plan's own frame (so it takes the plan's place and size), z the
-- floor's typical height. false: none for this place.
local function ahtuFloors(p)
    if p.ahtu ~= nil then return p.ahtu end
    p.ahtu = false
    local f = io.open(DIR .. "ahtu/" .. p.key .. ".ahtu", "r")
    if not f then return false end
    local floors = {}
    for line in f:lines() do
        local file, z = line:match("^(%S+)%s+(%-?[%d.]+)")
        if file then floors[#floors + 1] = { path = DIR .. "ahtu/" .. file, z = tonumber(z) } end
    end
    f:close()
    if #floors > 0 then p.ahtu = floors end
    return p.ahtu
end

-- The floor you're on: the one whose height is nearest yours (the first, from afar).
local function ahtuFloor(p, floors)
    local z = S.me and S.me.place == p and S.me.at and S.me.at.Z
    local best, bestD = floors[1], math.huge
    if z then
        for _, fl in ipairs(floors) do
            local d = math.abs(fl.z - z)
            if d < bestD then best, bestD = fl, d end
        end
    end
    return best
end

-- The floor plan under a local view. It turns about you, so its pivot is your spot in the image.
local function drawPlan(v, p)
    local plan = p and p.plan
    if not plan then
        if ui.planOn then
            ui.plan:SetVisibility(1)
            ui.credit:SetVisibility(1)
            ui.planOn = false
        end
        return
    end
    local floors = ahtuFloors(p)
    local path = floors and ahtuFloor(p, floors).path or planPath(p)
    if ui.planFor ~= path then
        ui.planFor = path
        p.tex = planTexture(path)
        if p.tex then ui.plan:SetBrushFromTexture(p.tex, false)
        else X.log("minimap: couldn't load " .. path) end
        ui.plan:SetColorAndOpacity(floors and COLOR.ahtu or COLOR.plan)
        ui.credit:SetVisibility(floors and p.tex and 3 or 1)
    end
    if floors then ui.creditSlot:SetPosition({ X = 6, Y = ui.view.h - 16 }) end
    if not p.tex then return end
    if not ui.planOn then
        ui.plan:SetVisibility(3)
        ui.credit:SetVisibility(floors and 3 or 1)
        ui.planOn = true
    end
    local r = p.rect
    local w, h = plan.w * CFG.CELL * v.scale, plan.h * CFG.CELL * v.scale
    local fx, fy = (v.focus.Y - r.y0) * v.scale, (r.x1 - v.focus.X) * v.scale
    ui.planSlot:SetPosition({ X = v.cx - fx, Y = v.cy - fy })
    ui.planSlot:SetSize({ X = w, Y = h })
    ui.plan:SetRenderTransformPivot({ X = fx / w, Y = fy / h })
    ui.plan:SetRenderTransformAngle(v.angle)
end

local function fitScale(x0, x1, y0, y1)
    return math.min(ui.view.w / math.max(1, y1 - y0), ui.view.h / math.max(1, x1 - x0))
end

local function chooseView(me, st)
    local v = { cx = ui.view.w / 2, cy = ui.view.h / 2 }
    local p = me.place
    if p and not (ui.big and p.isShip) then
        -- On foot in a place: its floor plan.
        if ui.big then
            local r = p.rect
            setView(v, { X = (r.x0 + r.x1) / 2, Y = (r.y0 + r.y1) / 2 }, fitScale(r.x0, r.x1, r.y0, r.y1), 0)
        else
            setView(v, me.at, ui.view.w / 2 / CFG.LOCAL_RANGE, -me.yaw)
        end
        v.space, v.place = false, p
        return v
    end
    -- In space. The small map follows you and zooms to fit where you're heading.
    v.space = true
    local here = me.space or me.at
    if not ui.big then
        local range = CFG.SPACE_MIN_RANGE
        if st and st.at and st.space then range = math.max(range, dist(here, st.at) * CFG.SPACE_FIT) end
        setView(v, here, ui.view.w / 2 / range, -(me.spaceYaw or me.yaw))
        return v
    end
    local x0, x1, y0, y1 = here.X, here.X, here.Y, here.Y
    local function take(l)
        x0, x1, y0, y1 = math.min(x0, l.X), math.max(x1, l.X), math.min(y0, l.Y), math.max(y1, l.Y)
    end
    for _, p2 in pairs(S.places or {}) do
        local spot = spaceSpot(p2, here)
        if spot then take(spot) end
    end
    for _, g in ipairs(S.gates or {}) do take(g) end
    local pad = math.max(x1 - x0, y1 - y0, 20000) * 0.12
    setView(v, { X = (x0 + x1) / 2, Y = (y0 + y1) / 2 }, fitScale(x0 - pad, x1 + pad, y0 - pad, y1 + pad), 0)
    return v
end

local function drawMarkers(v, me, st)
    local rings, labels, gatesUsed = 0, 0, 0
    if v.space then
        local here = me.space or me.at
        for _, p in pairs(S.places or {}) do
            local spot = spaceSpot(p, here)
            if spot and rings < #ui.rings then
                rings = rings + 1
                local x, y, off = clamped(v, project(v, spot))
                setIcon(ui.rings[rings], x, y)
                if ui.big and not off then
                    labels = labels + 1
                    showLabel(labels, p.name, x + 13, y - 8)
                end
            end
        end
        for _, g in ipairs(S.gates or {}) do
            if gatesUsed < #ui.gates then
                gatesUsed = gatesUsed + 1
                local x, y = clamped(v, project(v, g))
                setIcon(ui.gates[gatesUsed], x, y)
            end
        end
    end
    hideRest(ui.rings, rings + 1, hideIcon)
    hideRest(ui.gates, gatesUsed + 1, hideIcon)
    hideRest(ui.labels, labels + 1, hideLabel)
    -- The target shows only in the view it's in: a station spot means nothing on the space map, and the reverse.
    local tgt = st and st.at and (st.space or false) == v.space and st.at or nil
    if tgt then
        local x, y = clamped(v, project(v, tgt))
        setIcon(ui.target, x, y)
    else
        hideIcon(ui.target)
    end
    local here = v.space and (me.space or me.at) or me.at
    local x, y = clamped(v, project(v, here))
    setIcon(ui.me, x, y)
    -- Heading-up maps put you pointing up; the overview turns the arrow instead.
    ui.me.img:SetRenderTransformAngle(v.angle == 0 and ((v.space and me.spaceYaw or me.yaw) or 0) or 0)
end

local function drawRoute(v, me, st)
    local pts
    if st and st.at then
        if st.space and v.space then pts = { me.space or me.at, st.at }
        elseif st.walk and not v.space then pts = S.routePts end
    end
    local n = 0
    if pts and #pts > 1 then
        for _, d in ipairs(dotsAlong(pts, v.scale)) do
            local x, y = project(v, d)
            if x > 0 and y > 0 and x < ui.view.w and y < ui.view.h then
                n = n + 1
                setIcon(ui.dots[n], x, y)
            end
        end
    end
    hideRest(ui.dots, n + 1, hideIcon)
end

-- Kills, drops and crew (#326): on foot, in the place you're in, and only where they fall inside the map.
local function drawList(v, list, widgets, at)
    local n = 0
    for _, m in ipairs(list) do
        if n >= #widgets then break end
        local x, y = project(v, at(m))
        if x > 0 and y > 0 and x < ui.view.w and y < ui.view.h then
            n = n + 1
            setIcon(widgets[n], x, y)
        end
    end
    hideRest(widgets, n + 1, hideIcon)
end

local NONE = {}
local function drawExtras(v, me)
    local foot = not v.space
    local function here(list)
        if not (foot and list) then return NONE end
        local out = {}
        for _, m in ipairs(list) do if m.place == me.place then out[#out + 1] = m end end
        return out
    end
    local mine = marks.world == X.raid().world
    drawList(v, CFG.SHOW_KILLS and mine and here(marks.kills) or NONE, ui.kills, function(m) return m.at end)
    drawList(v, CFG.SHOW_DROPS and mine and here(marks.drops) or NONE, ui.drops, function(m) return m.at end)
    local crew = NONE
    if foot and CFG.SHOW_CREW and X.crew then
        local ok, list = pcall(X.crew.positions)
        if ok and list then crew = list end
    end
    drawList(v, crew, ui.crew, function(p) return p end)
end

local function draw(me)
    local st = S.stage
    local v = chooseView(me, st)
    drawPlan(v, v.place or nil)
    drawRoute(v, me, st)
    drawExtras(v, me)
    drawMarkers(v, me, st)
end

-- Text -----------------------------------------------------------------------------------------------------------
local function taskLine(t, tracked)
    local place = t.target and (t.target.place and t.target.place.name or t.target.name)
    local where = t.kind == "exit" and "" or place and "  -  " .. place or "  -  not in this sector"
    if CFG.MENU_TYPES[t.type] then where = "  -  from the menu" end
    local count = t.kind ~= "exit" and t.need > 1 and ("  (%d/%d)"):format(t.progress, t.need) or ""
    return ("%s%s%s%s\n      %s"):format(tracked and "> " or "   ", t.title, count, where, t.summary)
end

-- Lore (#272): the first time you reach a place in a raid, a line about it sits over the step text for ARRIVAL seconds.
local ARRIVAL = 9
local function arrive(me)
    local p = me.place
    if not p or p.isShip or not p.tag or p.tag == "" then return end
    S.arrived = S.arrived or {}
    if S.arrived[p.key] then return end
    S.arrived[p.key] = true
    for tag, lines in pairs(require("lorelines").places) do
        local k = key5(tag)
        if k == p.tag or TAG_KEYS[p.tag] == k then
            S.arrival = { text = p.name .. ": " .. lines[math.random(#lines)], untilAt = os.clock() + ARRIVAL }
            return
        end
    end
end

local function writeText(me)
    local t = S.tracked
    local st = S.stage
    if not t then return end
    local title = t.title
    if t.need and t.need > 1 and t.kind ~= "exit" then title = ("%s  %d/%d"):format(title, t.progress, t.need) end
    if title ~= ui.titleText then
        ui.title:SetText(FText(title))
        ui.titleText = title
    end
    local step = st and st.text or t.summary
    if S.arrival and os.clock() < S.arrival.untilAt then step = S.arrival.text .. "\n\n" .. step end
    if st and st.walk and st.at then
        -- No route from where you stand (an airlock chamber is off the navmesh): a path of length 0. Straight line then.
        local straight = dist(me.at, st.at)
        local d = (st.length and (st.length > 1 or straight < CFG.ROUTE_NEAR)) and st.length or straight
        step = ("%s\n%s to go"):format(step, km(d))
        local up = st.at.Z - me.at.Z
        if math.abs(up) > 300 then step = step .. (up > 0 and ", up a level" or ", down a level") end
        if st.partial then step = step .. "\nRoute not fully known: follow it as far as it goes" end
    end
    if step ~= ui.stepText then
        ui.step:SetText(FText(step))
        ui.stepText = step
        if stepLogged ~= st.text then
            stepLogged = st.text
            X.log("minimap: " .. t.title .. ": " .. tostring(st.text))
        end
    end
    if ui.big then
        local lines = {}
        for _, a in ipairs(S.tasks) do lines[#lines + 1] = taskLine(a, a == t) end
        for _, c in ipairs(S.contracts) do
            if c.progress >= c.need then lines[#lines + 1] = "   " .. c.title .. "  -  done" end
        end
        local s = table.concat(lines, "\n\n")
        if s ~= ui.listText then
            ui.list:SetText(FText(s))
            ui.listText = s
        end
    end
end

-- Once a second ---------------------------------------------------------------------------------------------------
local function think(pc, me)
    if not S.places then
        if os.clock() - (S.surveyedAt or -1e9) >= CFG.SURVEY_RETRY then
            S.surveyedAt = os.clock()
            if not survey() then S.places = nil end
        end
    end
    if not S.contracts then
        local ok, got = pcall(loadTasks, pc)
        if not ok or not got then
            if not ok and not S.taskError then
                S.taskError = true
                X.log("minimap: tasks not readable: " .. tostring(got))
            end
            S.contracts = nil
        end
    end
    if not (S.places and S.contracts) then return false end
    refreshProgress(pc)
    local gs = pc:GetWorld().GameState
    S.gateIn = math.ceil(gateIn(gs)) -- whole seconds: the countdown text formats it with %d
    S.gates = gates()
    S.tasks = activeTasks(me)
    -- Keep following a task while it's open; else the first one that can be followed.
    local kept
    for _, t in ipairs(S.tasks) do
        if t.row and S.trackedRow == t.row or (t.kind == "exit" and S.trackedRow == "exit") then kept = t end
    end
    if not kept then
        for _, t in ipairs(S.tasks) do
            if followable(t) then kept = t break end
        end
    end
    S.tracked = kept
    S.trackedRow = kept and (kept.row or "exit")
    S.stage = kept and stage(kept, me) or nil
    if S.stage and S.stage.walk and S.stage.at then
        local ok, pts = pcall(walkRoute, pc, S.stage, me)
        S.routePts = ok and pts or nil
        S.routeFrom = me.at
    else
        S.routePts = nil
    end
    return true
end

local function nextTask()
    if not (S and S.tasks) then return end
    local list = {}
    for _, t in ipairs(S.tasks) do
        if followable(t) then list[#list + 1] = t end
    end
    for i, t in ipairs(list) do
        if t == S.tracked then
            local n = list[i % #list + 1]
            S.trackedRow = n.row or "exit"
            S.thinkAt = 0
            return
        end
    end
end

local function setShown(on)
    shown = on
    saveSettings()
end

function M.toggle() setShown(not shown) end

function M.expand()
    if not shown then setShown(true) end
    expanded = not expanded
end

M.next = nextTask

local function command()
    local f = io.open(CMD_FILE, "r")
    if not f then return end
    local line = f:read("l")
    f:close()
    os.remove(CMD_FILE)
    if line == "toggle" then M.toggle()
    elseif line == "expand" then M.expand()
    elseif line == "next" then M.next() end
end

-- Every frame, from the director. Hidden until you can see the game. The game's menus draw over it (see build).
function M.tick(pc)
    local raid = X.raid()
    -- Land raids (the debug menu's test raid) have no stations or ship, so nothing to map: the survey could never find
    -- a place, and locate() threw every frame there (valid(false) on the missing ship's hull).
    if not raid.space then return end
    if not raid.revealed then return end
    local now = os.clock()
    if not S or S.key ~= raid.world then
        S = { key = raid.world, thinkAt = 0, drawAt = 0, joiner = not valid(pc:GetWorld().AuthorityGameMode) }
    end
    if S.scan then stepScan(pc) end
    if now - (S.cmdAt or 0) >= 0.25 then
        S.cmdAt = now
        command()
    end
    local away = not shown
    if ui and ui.pc and ui.pc:GetAddress() ~= pc:GetAddress() then ui = nil end
    if not ui then
        if away or S.failed then return end
        if not build(pc) then
            S.failed = true
            return
        end
        ui.pc = pc
        ui.visible = true
        applyLayout()
    end
    if away then
        if ui.visible then
            ui.host:SetVisibility(1)
            ui.visible = false
        end
        return
    end
    if not ui.visible then
        ui.host:SetVisibility(3)
        ui.visible = true
    end
    if ui.big ~= expanded then applyLayout() end
    if now - S.drawAt < CFG.FRAME then return end
    S.drawAt = now
    local me = locate(pc)
    if not me then return end
    if S.me and S.me.place and S.me.place.isShip and me.place and not me.place.isShip then S.entry = { place = me.place, at = me.at } end
    S.me = me
    pcall(arrive, me)
    local moved = S.routeFrom and not me.piloting and dist(me.at, S.routeFrom) > CFG.ROUTE_MOVED
    if now >= S.thinkAt or moved then
        S.thinkAt = now + CFG.THINK
        S.ready = think(pc, me)
        if S.ready then writeText(me) end
        if S.ready and not S.scan and not S.scansDone then
            if raid.navReady then nextScan()
            elseif S.joiner then nextScan(true) end
        end
    end
    if S.ready then draw(me) end
end

-- A new world: the old one took the widgets with it, so they're dropped untouched.
function M.reset()
    ui, S = nil, nil
end

return M
