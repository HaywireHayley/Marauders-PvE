-- One map census for object scans. FindAllOf walks every object (30-100 ms on a space map), and rivals.lua's station
-- survey, minimap.lua's survey and playareas.lua's scans looked for the same classes within seconds of each other.
-- Here each class is scanned once per world and the list kept (keyed by main.lua's raid.world, the world's name and
-- address, so a new world starts empty and nothing freed with the old one is ever read).
--   all(cls)          the kept list (scanned on first use), valid() objects only
--   all(cls, maxAge)  the same, scanned again when the kept list is older than maxAge seconds (actors that stream in
--                     later: a caller that used to rescan keeps doing so, at most every maxAge s)
--   refresh(cls)      a fresh scan now, kept for the others
local M = {}
M.FRESH = 3 -- seconds a scan is shared by the setup surveys before the next look scans again

local valid -- main.lua's valid (M.init)
local raid -- main.lua's per-raid table (M.setRaid)
local kept = { world = false }

function M.init(ctx) valid = ctx.valid end
function M.setRaid(r) raid = r end

local function forWorld()
    local w = raid and raid.world
    if kept.world ~= w then kept = { world = w } end
    return kept
end

local function alive(list)
    local out = {}
    for _, o in ipairs(list) do
        if valid(o) then out[#out + 1] = o end
    end
    return out
end

function M.refresh(cls)
    local list = FindAllOf(cls) or {}
    forWorld()[cls] = { at = os.clock(), list = list }
    return alive(list)
end

function M.all(cls, maxAge)
    local e = forWorld()[cls]
    if not e or (maxAge and os.clock() - e.at >= maxAge) then return M.refresh(cls) end
    return alive(e.list)
end

return M
