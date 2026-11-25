-- Your player controller and inventory component, kept between calls. Many modules did FindFirstOf("PlayerController")
-- or FindFirstOf("SIGISInventoryComponent") each time they needed them: a walk over every object (tens of ms on a
-- space map). Here the last one found is kept while it's still valid, and found again only when it isn't (a new world
-- frees the old ones; valid() checks through pve_alive, so a freed object is never touched).
--   controller()   your PlayerController (the local one), or nil
--   inventory()    your SIGISInventoryComponent, or nil
--   reset()        forget both (main.lua, on a new world)
local M = {}
local X -- valid, lib
local pc, inv

function M.init(ctx) X = ctx end
function M.reset() pc, inv = nil, nil end

function M.controller()
    if pc and X.valid(pc) then return pc end
    pc = nil
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if X.valid(c) then
            local ok, mine = pcall(function() return c:IsLocalController() end)
            if ok and mine then pc = c break end
        end
    end
    return pc
end

function M.inventory()
    if inv and X.valid(inv) then return inv end
    inv = nil
    local c = M.controller()
    if c then
        pcall(function()
            local comps = c:K2_GetComponentsByClass(X.lib("/Script/SIGISPlugin.SIGISInventoryComponent"))
            for i = 1, #comps do
                local o = comps[i]:get()
                if X.valid(o) then inv = o break end
            end
        end)
    end
    if not inv then
        local o = FindFirstOf("SIGISInventoryComponent")
        if o and X.valid(o) then inv = o end
    end
    return inv
end

return M
