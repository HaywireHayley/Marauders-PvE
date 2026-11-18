-- Play areas (moved out of main.lua): which parts of a station's navmesh bots may use. offLimits() is asked by the
-- soldiers (bots.lua), rival crews and your crew; findAll() is a short-lived cache of object scans rivals.lua shares.
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local M = {}

local log, valid -- from main.lua (M.init)
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)

function M.init(ctx) log, valid = ctx.log, ctx.valid end
function M.setRaid(r) raid = r end

-- Where bots may go on a station. The runtime navmesh covers everything walkable, roofs and the shell around a station
-- included, and nothing in the map says which parts are for play. What does: loot, contract objects, AI nodes and airlocks
-- only sit in played areas, so a point counts when one of those is near it on the same level (bridge/t_nav.lua maps this).
-- Spaceport's sealed basement has an AI node of its own, by the hidden stash contracts, so it's ruled out by hand.
local PLAY_RANGE, PLAY_LEVEL, PLAY_CELL = 1800, 260, 2000
local SEALED = { { x0 = 66500, x1 = 73500, y0 = 19500, y1 = 27000, z1 = -60 } }
local PLAY_MARKS = { "SIGISLootSingleSpawner", "SIGISContractActor", "RaidAINodeStart", "RaidUseableAirLockComponent" }
local STATIONS = { "NavyOutpost", "Spaceport", "Merchant", "Fortress", "MiniMine", "RebelBase", "PenalColony",
    "Asteriod", "MoonBase", "ColonyCruiser", "PlanetKiller" }

local function sealed(p)
    for _, a in ipairs(SEALED) do
        if p.X >= a.x0 and p.X <= a.x1 and p.Y >= a.y0 and p.Y <= a.y1 and p.Z <= a.z1 then return true end
    end
    return false
end

function M.inBox(b, p) return math.abs(p.X - b.at.X) <= b.ext.X and math.abs(p.Y - b.at.Y) <= b.ext.Y end

-- Object scans shared for a few seconds: on stepping into a station, rivals.lua's garrison (seedSpots) and the boarding
-- rescan below scan the same classes within a second or two (~50 ms each, so each class was paid twice). Results can
-- hold actors destroyed since; every caller checks valid().
function M.findAll(cls)
    local c, now = raid.scanCache, os.clock()
    if not c or c.world ~= raid.world then c = { world = raid.world } raid.scanCache = c end
    local e = c[cls]
    if e and now - e.at < 3 then return e.list end
    local list = FindAllOf(cls) or {}
    c[cls] = { at = now, list = list }
    return list
end

-- One marker class into a cell table. Airlocks don't count towards a box being mapped: they're on the hull and load
-- with the outside of the station, before its insides.
function M.scan(cls, cells, boxes)
    for _, a in ipairs(M.findAll(cls)) do
        if valid(a) then
            local l = cls == "RaidUseableAirLockComponent" and a:K2_GetComponentLocation() or a:K2_GetActorLocation()
            if not sealed(l) then
                local key = math.floor(l.X / PLAY_CELL) .. "," .. math.floor(l.Y / PLAY_CELL) -- integer keys: see offLimits
                cells[key] = cells[key] or {}
                table.insert(cells[key], { X = l.X, Y = l.Y, Z = l.Z })
                if cls ~= "RaidUseableAirLockComponent" then
                    for _, b in ipairs(boxes) do
                        if M.inBox(b, l) then b.marks = b.marks + 1 end
                    end
                end
            end
        end
    end
end

-- Once per raid, under the loading veil: five object scans. In space a station's insides stream in only as you come
-- close, so this first scan can miss its loot and AI nodes (Rebel Base, 2026-11-14: every baked cover spot in it was
-- thrown out as off limits). A box with none counts as unmapped, and M.rescan() maps it again once you're aboard.
function M.mapPlayAreas()
    local play = { boxes = {}, cells = {} }
    for _, v in ipairs(FindAllOf("LevelStreamingVolume") or {}) do
        if valid(v) then
            local name = v:GetFName():ToString()
            for _, key in ipairs(STATIONS) do
                if name:find(key, 1, true) then
                    local at, ext = {}, {}
                    Out.call(v, "GetActorBounds", false, at, ext, false)
                    table.insert(play.boxes, { at = at, ext = ext, name = key, marks = 0 })
                end
            end
        end
    end
    for _, cls in ipairs(PLAY_MARKS) do M.scan(cls, play.cells, play.boxes) end
    raid.play = play
    local counts = {}
    for _, b in ipairs(play.boxes) do counts[#counts + 1] = b.name .. " " .. b.marks end
    log("play areas: markers per station box: " .. table.concat(counts, ", "))
end

-- On foot inside a station box for the first time: scan the markers again, one class per frame (each scan is a
-- FindAllOf, ~50 ms on a big map), and swap the new cells in at the end.
function M.rescan(at)
    local play = raid.play
    local job = play.job
    if not job then
        for _, b in ipairs(play.boxes) do
            if not b.rescanned and M.inBox(b, at) then
                b.rescanned = true
                local boxes = {}
                for i, o in ipairs(play.boxes) do boxes[i] = { at = o.at, ext = o.ext, marks = 0 } end
                play.job = { name = b.name, i = 1, cells = {}, boxes = boxes }
                return
            end
        end
        return
    end
    M.scan(PLAY_MARKS[job.i], job.cells, job.boxes)
    job.i = job.i + 1
    if job.i > #PLAY_MARKS then
        play.cells, play.job = job.cells, nil
        local counts = {}
        for i, b in ipairs(play.boxes) do
            b.marks = job.boxes[i].marks
            counts[#counts + 1] = b.name .. " " .. b.marks
        end
        log(("play areas: rescanned on boarding %s: %s"):format(job.name, table.concat(counts, ", ")))
    end
end

local function offLimits(p)
    if not (raid.space and raid.play) or sealed(p) then return raid.space and sealed(p) or false end
    local inside = nil
    for _, b in ipairs(raid.play.boxes) do
        if M.inBox(b, p) then inside = b break end
    end
    if not inside then return false end -- ships and everything else off the stations
    if inside.marks == 0 then return false end -- not streamed in when scanned: can't tell, so nothing is ruled out
    -- math.floor, not //: a float's // is a float ("26.0") and an integer's an integer ("26"), so a baked cover spot
    -- (whole numbers from cover/*.txt) never found the markers filed under the engine's float positions. Every baked
    -- spot was off limits on every station (Rebel Base, Space_Alpha, 2026-11-14: "off 40" of 40).
    local cx, cy = math.floor(p.X / PLAY_CELL), math.floor(p.Y / PLAY_CELL)
    for gx = cx - 1, cx + 1 do
        for gy = cy - 1, cy + 1 do
            for _, m in ipairs(raid.play.cells[gx .. "," .. gy] or {}) do
                if math.abs(m.Z - p.Z) <= PLAY_LEVEL and (m.X - p.X) ^ 2 + (m.Y - p.Y) ^ 2 <= PLAY_RANGE ^ 2 then return false end
            end
        end
    end
    return true
end

M.offLimits = offLimits

return M
