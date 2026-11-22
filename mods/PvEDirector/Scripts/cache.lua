-- Objects many modules look up again and again, found once and kept while valid (main.lua's valid: pve_alive first).
-- A FindFirstOf walks every object in the game: the lobby helpers asked for the menu's player controller every frame
-- (~600 scans and ~7 s of every 10 s in a tester's frames: log, build 23), and two space-map helpers asked for the
-- world twice a second (#336).
local M = {}
local valid = function() return false end
local MISS_WAIT = 2 -- s before looking again after finding nothing (there's no menu controller in a raid)
local kept, missAt = {}, {}

function M.init(v) valid = v end

local function find(cls)
    local o = kept[cls]
    if valid(o) then return o end
    kept[cls] = nil
    local now = os.clock()
    if missAt[cls] and now - missAt[cls] < MISS_WAIT then return nil end
    o = FindFirstOf(cls)
    if valid(o) then kept[cls], missAt[cls] = o, nil return o end
    missAt[cls] = now
    return nil
end

function M.menuPc() return find("MenuPlayerController_C") end

function M.world() return find("World") end

return M
