-- Minefield: the raid condition key `mines = N` (conditions.lua) gives the raid N times the map's space mines. Each
-- mine the map placed (Small_NodeMine, Nuclear_NodeMine: RaidSubNodeActor classes with "NodeMine" in the name) gets
-- N - 1 copies of its own class, scattered around it, so the fields stay where the map put them, just much denser.
-- The copies are ordinary mines: they trigger, hurt and explode the game's way (spacefx.lua adds the blast offline).
--
-- Once per world, a few seconds after the space map has its mines (they stream in with the nodes, so it keeps looking
-- for up to LOOK_FOR seconds). Capped at MAX_SPAWNED copies in all.
local M = {}
local X -- log, valid, conditions

local CFG = {
    SPREAD = 9000,       -- copies land up to this far from their mine (cm, each axis); a ship gun reaches 60-95 m
    MIN_GAP = 1500,      -- and at least this far from it
    MAX_SPAWNED = 400,
    WAIT = 8,            -- seconds into the space map before looking
    LOOK_FOR = 90,
}
M.CFG = CFG

local state = { world = nil, since = nil, done = false }

function M.init(ctx) X = ctx end

local function className(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function scatter(at)
    for _ = 1, 8 do
        local dx, dy, dz = (math.random() * 2 - 1) * CFG.SPREAD, (math.random() * 2 - 1) * CFG.SPREAD,
            (math.random() * 2 - 1) * CFG.SPREAD * 0.5
        if dx * dx + dy * dy + dz * dz >= CFG.MIN_GAP * CFG.MIN_GAP then
            return { X = at.X + dx, Y = at.Y + dy, Z = at.Z + dz }
        end
    end
    return { X = at.X + CFG.MIN_GAP, Y = at.Y, Z = at.Z }
end

-- Every update on space maps (main.lua).
function M.update(pc)
    local times = X.conditions.mines and X.conditions.mines()
    local world = (X.valid(pc) and pc:GetWorld()) or require("cache").world()
    if not X.valid(world) then return end
    local key = ("%x"):format(world:GetAddress())
    if key ~= state.world then state.world, state.since, state.done = key, os.clock(), false end
    if state.done or not times or times <= 1 then return end
    local waited = os.clock() - state.since
    if waited < CFG.WAIT then return end

    local mines = {}
    for _, a in ipairs(FindAllOf("RaidSubNodeActor") or {}) do
        if X.valid(a) and className(a):find("NodeMine", 1, true) then mines[#mines + 1] = a end
    end
    if #mines == 0 then
        if waited > CFG.LOOK_FOR then
            state.done = true
            X.log("minefield: this map has no space mines to multiply")
        end
        return
    end
    state.done = true

    local per = math.floor(times) - 1
    local made, failed = 0, 0
    for _, m in ipairs(mines) do
        local cls, at, rot
        pcall(function()
            cls = m:GetClass()
            at = m:K2_GetActorLocation()
            rot = m:K2_GetActorRotation()
        end)
        if X.valid(cls) and at then
            local from = { X = at.X, Y = at.Y, Z = at.Z }
            local r = rot and { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll } or { Pitch = 0, Yaw = 0, Roll = 0 }
            for _ = 1, per do
                if made >= CFG.MAX_SPAWNED then break end
                local ok, a = pcall(function() return world:SpawnActor(cls, scatter(from), r) end)
                if ok and a and X.valid(a) then made = made + 1 else failed = failed + 1 end
            end
        end
    end
    X.log(("minefield: %d mines on the map, %d more spawned (x%s)%s"):format(#mines, made, tostring(times),
        failed > 0 and (", " .. failed .. " failed") or ""))
end

return M
