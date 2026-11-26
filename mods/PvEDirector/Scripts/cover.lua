-- Cover map: where on the navmesh a soldier has something solid beside it, baked from collision traces.
--
-- The old search tested random reachable points for line of sight, and few random points sit behind anything, so
-- soldiers often found nothing and fought in the open. This bakes cells of the map instead (on demand, a little per
-- frame, saved per map): a grid of navmesh points, each traced in 8 directions at crouched and standing eye height.
--   full  = blocked at standing eye height in that direction
--   low   = blocked at crouched eye height only (shoot over it standing)
--   corner = full, and a standing eye a step to one side sees past it (a lean-out spot)
-- A fight asks candidates(): baked points that block towards the threat (within 45 deg), nearest first. main.lua's
-- probeCover still checks real line of sight on the few it tries.
local PROJECT = require("pveproject")
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local M = {}

local CELL = 1600          -- cell size (units); cells are baked whole
local STEP = 100           -- grid spacing inside a cell
local BAND = 400           -- vertical band per cell (one floor of a station)
local REACH = 90           -- an obstacle this close to a point's centre, in a direction, counts as cover
local LOW_Z, HIGH_Z = 100, 160 -- above the navmesh point: crouched eye, standing eye
local SIDE = 120           -- corner test: this far to the side (main.lua PEEK_STEPS go to 140)...
local SEE_PAST = 200       -- ...a standing eye must see this far forward unblocked
local BUDGET = 0.001       -- seconds of baking per frame
local SLOW_FRAME = 0.025   -- a gap this long since the last step means the game is struggling: skip baking this frame
local SAVE_CELLS, SAVE_EVERY = 8, 5 -- baked cells are appended to the file in batches: this many, or after this long (s)
local EMPTY_RETRY = 60     -- a cell that baked to nothing (sublevel not loaded yet?) is baked again after this long

local DIRS = {}
for i = 0, 7 do
    local a = i * math.pi / 4
    DIRS[i + 1] = { math.cos(a), math.sin(a) }
end

local S = { key = nil }
local function log(msg) print("[PvEDirector] cover: " .. tostring(msg) .. "\n") end
local function lib(p) return StaticFindObject(p) end
local function cellKey(cx, cy, cz) return cx .. "," .. cy .. "," .. cz end
local function cellOf(p) return p.X // CELL, p.Y // CELL, (p.Z + BAND / 2) // BAND end

-- Traces --------------------------------------------------------------------------------------------
local NOCOL = { R = 0, G = 0, B = 0, A = 0 }
-- The Visibility channel, the one LineOfSightTo uses. (LineTraceSingleForObjects with an object-type list from Lua hit
-- nothing at all: the enum array doesn't get through.) A pawn in the way isn't cover.
-- Baking runs thousands of traces a second: the engine objects are looked up once and the trace's argument tables are
-- reused (each lookup and each table was garbage, and garbage is what made the collector stall the game).
local K = {}
local function libs()
    if not (K.ksl and K.ksl:IsValid()) then
        K.ksl = lib("/Script/Engine.Default__KismetSystemLibrary")
        K.pawn = lib("/Script/Engine.Pawn")
        K.nav = lib("/Script/NavigationSystem.Default__NavigationSystemV1")
        K.filter = lib("/Script/NavigationSystem.NavigationQueryFilter")
    end
    return K
end
local IGNORE, EXTENT = {}, { X = 40, Y = 40, Z = BAND / 2 }
local A, B = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }
local function isPawn(out) return out.Actor:Get():IsA(K.pawn) end

local function hit(ctx, ax, ay, az, bx, by, bz)
    local k = libs()
    A.X, A.Y, A.Z, B.X, B.Y, B.Z = ax, ay, az, bx, by, bz
    local out = {}
    S.traces = S.traces + 1
    if not Out.call(k.ksl, "LineTraceSingle", ctx, A, B, 0, false, IGNORE, 0, out, true, NOCOL, NOCOL, 0) then return false end
    local ok, pawn = pcall(isPawn, out)
    return not (ok and pawn)
end

local function project(ctx, at)
    local k = libs()
    local out = {}
    if Out.call(k.nav, "K2_ProjectPointToNavigation", ctx, at, out, S.navData, k.filter, EXTENT) and out.X then return out end
    return nil
end

-- One grid point: masks of directions (bit i = DIRS[i+1]).
local function bakePoint(ctx, p)
    local full, low, corner = 0, 0, 0
    for i, d in ipairs(DIRS) do
        local bit = 1 << (i - 1)
        local lz = p.Z + LOW_Z
        if hit(ctx, p.X, p.Y, lz, p.X + d[1] * REACH, p.Y + d[2] * REACH, lz) then
            local hz = p.Z + HIGH_Z
            if hit(ctx, p.X, p.Y, hz, p.X + d[1] * REACH, p.Y + d[2] * REACH, hz) then
                full = full | bit
                for s = -1, 1, 2 do
                    local sx, sy = p.X - d[2] * SIDE * s, p.Y + d[1] * SIDE * s
                    -- the step out itself must be clear, and from there the view forward
                    if not hit(ctx, p.X, p.Y, hz, sx, sy, hz)
                        and not hit(ctx, sx, sy, hz, sx + d[1] * SEE_PAST, sy + d[2] * SEE_PAST, hz) then
                        corner = corner | bit
                        break
                    end
                end
            else
                low = low | bit
            end
        end
    end
    return full, low, corner
end

-- Cells ---------------------------------------------------------------------------------------------
local function newJob(cx, cy, cz)
    local grid = {}
    for gx = 0, CELL // STEP - 1 do
        for gy = 0, CELL // STEP - 1 do
            grid[#grid + 1] = { cx * CELL + gx * STEP + STEP / 2, cy * CELL + gy * STEP + STEP / 2 }
        end
    end
    return { cx = cx, cy = cy, cz = cz, grid = grid, i = 1, points = {}, seen = {}, started = os.clock() }
end

-- Baked cells wait in S.pending and are appended in one open/close (flush), not one file open per cell.
local function flush()
    local pend = S.pending
    if not pend or #pend == 0 then return end
    S.pending, S.savedAt = {}, os.clock()
    if not S.file then return end
    local f = io.open(S.file, "a")
    if not f then return end
    for _, e in ipairs(pend) do
        f:write("C ", e.key, "\n")
        for _, p in ipairs(e.cell.points) do
            f:write(("%d %d %d %d %d %d\n"):format(math.floor(p.X), math.floor(p.Y), math.floor(p.Z), p.full, p.low, p.corner))
        end
    end
    f:close()
end
M.flush = flush

local function save(cell, key)
    if not S.file or #cell.points == 0 then return end
    table.insert(S.pending, { key = key, cell = cell })
    if #S.pending >= SAVE_CELLS or os.clock() - (S.savedAt or 0) > SAVE_EVERY then flush() end
end

local function load(file)
    local f = io.open(file, "r")
    if not f then return 0 end
    local n, cur = 0, nil
    for line in f:lines() do
        local key = line:match("^C (%S+)")
        if key then
            cur = { points = {}, done = true }
            S.cells[key] = cur
            n = n + 1
        elseif cur then
            local x, y, z, fu, lo, co = line:match("^(%-?%d+) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d+)")
            if x then
                table.insert(cur.points, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z), full = tonumber(fu),
                    low = tonumber(lo), corner = tonumber(co) })
            end
        end
    end
    f:close()
    return n
end

-- New world: forget the old map's cells and load this one's.
function M.reset(world, navData)
    flush() -- the old map's batch goes to the old map's file before S is replaced
    local name = world and world:GetFName():ToString() or "none"
    S = { key = name, cells = {}, queue = {}, job = nil, navData = navData, traces = 0, baked = 0, bakeTime = 0,
        pending = {}, savedAt = os.clock() }
    S.file = PROJECT .. "cover/" .. name .. ".txt"
    local n = load(S.file)
    if n > 0 then log(("%s: %d cells loaded"):format(name, n)) end
end

function M.setNav(navData) S.navData = navData end

-- Ask for the cells around a spot (radius) to be baked; nearer requests go first.
function M.want(at, radius)
    if not S.cells then return end
    radius = radius or CELL
    local x0, y0, cz = cellOf(at)
    local r = math.ceil(radius / CELL)
    for cx = x0 - r, x0 + r do
        for cy = y0 - r, y0 + r do
            local key = cellKey(cx, cy, cz)
            local c = S.cells[key]
            if not c or (c.done and #c.points == 0 and c.emptyAt and os.clock() - c.emptyAt > EMPTY_RETRY) then
                S.cells[key] = { points = {}, queued = true }
                -- nearest cell to this request at the front
                local d = math.abs(cx - x0) + math.abs(cy - y0)
                table.insert(S.queue, math.min(#S.queue + 1, d + 1), { cx = cx, cy = cy, cz = cz })
            end
        end
    end
end

-- Bakes for up to BUDGET seconds. ctx: any actor in the world (the player controller).
function M.step(ctx)
    if not S.cells or not S.navData then return end
    local t0 = os.clock()
    local gap = S.lastStep and t0 - S.lastStep
    S.lastStep = t0
    if #S.pending > 0 and t0 - (S.savedAt or 0) > SAVE_EVERY then flush() end
    if gap and gap > SLOW_FRAME then return end -- the last frame was slow: don't add to it
    while os.clock() - t0 < BUDGET do
        local job = S.job
        if not job then
            local q = table.remove(S.queue, 1)
            if not q then break end
            job = newJob(q.cx, q.cy, q.cz)
            S.job = job
        end
        local g = job.grid[job.i]
        if not g then
            local key = cellKey(job.cx, job.cy, job.cz)
            local cell = { points = job.points, done = true }
            if #cell.points == 0 then cell.emptyAt = os.clock() end
            S.cells[key] = cell
            S.baked = S.baked + 1
            save(cell, key)
            S.job = nil
        else
            job.i = job.i + 1
            A.X, A.Y, A.Z = g[1], g[2], job.cz * BAND
            local p = project(ctx, A)
            if p and math.abs(p.X - g[1]) <= STEP / 2 and math.abs(p.Y - g[2]) <= STEP / 2 then
                local snap = math.floor(p.X / 50) .. "," .. math.floor(p.Y / 50) .. "," .. math.floor(p.Z / 100)
                if not job.seen[snap] then
                    job.seen[snap] = true
                    local full, low, corner = bakePoint(ctx, p)
                    if corner ~= 0 or low ~= 0 then
                        table.insert(job.points, { X = p.X, Y = p.Y, Z = p.Z, full = full, low = low, corner = corner })
                    end
                end
            end
        end
    end
    S.bakeTime = S.bakeTime + (os.clock() - t0)
end

-- Baked spots within radius of `at` (same floor) that block towards `threat`: { pos, low, lean } nearest first.
-- lean = a corner spot (step out to fire), else low cover (stand up to fire). Unbaked cells are queued.
function M.candidates(at, threat, radius, max)
    if not S.cells then return {} end
    M.want(at, radius)
    local x0, y0, cz = cellOf(at)
    local r = math.ceil(radius / CELL)
    local out = {}
    for cx = x0 - r, x0 + r do
        for cy = y0 - r, y0 + r do
            for dz = -1, 1 do
                local c = S.cells[cellKey(cx, cy, cz + dz)]
                if c and c.done then
                    for _, p in ipairs(c.points) do
                        local d = math.sqrt((p.X - at.X) ^ 2 + (p.Y - at.Y) ^ 2)
                        if d <= radius and math.abs(p.Z - at.Z) < 250 then
                            local k = math.floor(math.atan(threat.Y - p.Y, threat.X - p.X) / (math.pi / 4) + 0.5) % 8
                            local mask = (1 << k) | (1 << ((k + 1) % 8)) | (1 << ((k + 7) % 8))
                            local lean = p.corner & mask ~= 0
                            -- low cover counts only if nothing above blocks the standing shot that way
                            local low = not lean and (p.low & mask ~= 0) and (p.full & (1 << k)) == 0
                            if lean or low then
                                table.insert(out, { pos = { X = p.X, Y = p.Y, Z = p.Z }, low = low, d = d })
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    while max and #out > max do table.remove(out) end
    return out
end

-- Status for the log / bridge.
function M.stats()
    if not S.cells then return "off" end
    local cells, pts = 0, 0
    for _, c in pairs(S.cells) do
        if c.done then cells = cells + 1 pts = pts + #c.points end
    end
    return ("%s: %d cells (%d baked now), %d points, %d queued, %d traces, %.2f s baking"):format(S.key or "?",
        cells, S.baked or 0, pts, #(S.queue or {}), S.traces or 0, S.bakeTime or 0)
end

-- All points (for debugging probes).
function M.points()
    local all = {}
    for key, c in pairs(S.cells or {}) do
        for _, p in ipairs(c.points) do all[#all + 1] = p end
    end
    return all
end

return M
