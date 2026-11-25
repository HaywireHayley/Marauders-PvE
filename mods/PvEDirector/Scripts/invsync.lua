-- Stale cells in the inventory grids (the desync report, 2026-11-20): moving items sometimes left the cells they came
-- from "occupied", so nothing could be put there, and moving things around more duplicated or lost items. A container
-- widget's grid is a list of slot widgets (InventoryGridSlotWidget), each pointing at the item that covers it (`Item`);
-- the game moves those pointers itself when an item moves. When it misses one, the old cell keeps pointing at an item
-- that's now somewhere else: the game then treats that cell as taken, and a drop computed from it can land on top of
-- something (stacked items: #239, #240).
-- So, about once a second while a grid is shown, every cell is checked against the inventory itself
-- (SIGISInventoryComponent.StashedItems: each item's MotherItemGUID is the container it's really in), and a cell that
-- points at an item that's gone, or that isn't in this container any more, is cleared. Nothing else is touched: cells
-- are never filled in from guessed sizes, and only your own containers are checked (pockets, the stash, the grids of
-- your bags, rigs and boxes, whose ContainerID is the bag's item id); loot, shop and gift grids are left alone.
-- The game's own Server_ValidateEquippedInventory (it sends the item list back through Client_ValidateEquippedInventory)
-- was tried first: it left a stale cell as it was.
local S = {}
local X -- log, valid

local EVERY = 10.0           -- seconds between checks when nothing was dragged (was 1 s: a big stash cost ~100-800 ms
                             -- a second in the lobby, where the stash is always on screen)
local AFTER_DRAG = 0.3       -- a check this long after a mouse button comes up: when items move, so when cells go stale
local FIND_MAX = 30          -- the widgets are looked for at most this often (seconds) while none are found
local OWN = { PocketLeft = true, PocketRight = true, Stash = true }

local paths, inv, nextRun, nextFind, findEvery = {}, nil, 0, 0, 2
local cleared = 0

function S.init(ctx) X = ctx end

local function live(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and X.valid(o) then return o end
end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end

-- The live container widgets (both copies in a raid: the HUD overlay's and the menu's) and your inventory component,
-- kept as paths. FindAllOf walks every object (30-45 ms), so it runs only when the paths stop resolving, backing off.
local function find(now)
    if now < nextFind then return false end
    findEvery = math.min(FIND_MAX, findEvery * 2)
    nextFind = now + findEvery
    paths, inv = {}, nil
    for _, w in ipairs(FindAllOf("InventoryContainerWidget") or {}) do
        if X.valid(w) and w:GetFullName():find("Transient", 1, true) then paths[#paths + 1] = pathOf(w) end
    end
    for _, c in ipairs(FindAllOf("SIGISInventoryComponent") or {}) do
        local owner = X.valid(c) and c:GetOwner()
        local cls = owner and X.valid(owner) and owner:GetClass():GetFName():ToString() or ""
        if cls == "MainPlayerController_C" or cls == "MenuPlayerController_C" then inv = pathOf(c) end
    end
    if #paths > 0 and inv then findEvery = 2 return true end
    return false
end

-- Drawn: the widget and every parent visible. In a raid each container widget exists twice, and the mod's own HUD
-- overlay copy (collapsed once the game makes its own) keeps pointing at dead items: not ours to tidy, nobody sees it.
local function shown(w)
    local p, depth = w, 0
    while p and X.valid(p) and depth < 40 do
        if not p:IsVisible() then return false end
        p = p:GetParent()
        depth = depth + 1
    end
    return true
end

-- Where each item really is: guid -> container.
local function truth(comp)
    local at = {}
    comp.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if it and X.valid(it) then at[it.UniqueItemGUID:ToString()] = it.MotherItemGUID:ToString() end
    end)
    return at
end

local function check(w, at)
    local id = w.ContainerID:ToString()
    -- your own containers only: a bag's, rig's or box's grid is named after that item, which is in your inventory
    if not (OWN[id] or at[id]) then return 0 end
    local n, rows, memo = 0, {}, {}
    w.InventorySlots:ForEach(function(_, e)
        local slot = e:get()
        local it = slot and X.valid(slot) and slot.Item
        -- (an empty cell reads as a wrapper around a null pointer, which Lua counts as true: address 0 is empty)
        if it and it:GetAddress() ~= 0 then
            local stale = not X.valid(it)
            local row
            if not stale then
                -- an item covers several cells: its GUID and row are read once per check, by address
                local a = it:GetAddress()
                local m = memo[a]
                if not m then
                    m = { g = it.UniqueItemGUID:ToString(), row = it.ItemData:ToString() }
                    memo[a] = m
                end
                stale = at[m.g] ~= id
                row = m.row
            end
            if stale then
                slot.Item = nil
                n = n + 1
                rows[row or "a removed item"] = true
            end
        end
    end)
    if n > 0 then
        local names = {}
        for r in pairs(rows) do names[#names + 1] = r end
        X.log(("inventory: %d stale cell(s) in %s cleared (they still pointed at %s)"):format(n, id,
            table.concat(names, ", ")))
    end
    return n
end

-- Every frame (main.lua onTick, lobby and raid), with the ticking player controller.
-- Only while the mouse cursor is up (a menu open: the inventory, the lobby): shown() can't tell a closed inventory, as a
-- grid's parent chain ends at its own widget's root and a copy that's off screen stays flagged visible. Without this,
-- after a bag or armour swap the check ran on such a copy every second for the rest of the raid: ~175 ms each time,
-- walking the whole inventory (#369, Walmarx's report: once-a-second stalls right after dragging a backpack on).
local LMB, wasDown, dueAt -- the left mouse button's key, its last state, a check asked for by a drag ending

function S.tick(pc)
    local now = os.clock()
    if pc and X.valid(pc) then
        LMB = LMB or { KeyName = FName("LeftMouseButton") }
        local ok, down = pcall(function() return pc:IsInputKeyDown(LMB) end)
        if ok then
            if wasDown and not down then dueAt = now + AFTER_DRAG end
            wasDown = down
        end
    end
    if now < nextRun and not (dueAt and now >= dueAt) then return end
    dueAt = nil
    nextRun = now + EVERY
    local cursor = true
    -- (only a controller has the flag: anything else ticking, like a lobby widget, reads nil and doesn't stop it)
    if pc and X.valid(pc) then pcall(function() cursor = pc.bShowMouseCursor ~= false end) end
    if not cursor then return end
    local comp = live(inv)
    if not comp or not live(paths[1]) then
        if not find(now) then return end
        comp = live(inv)
        if not comp then return end
    end
    local at
    for _, p in ipairs(paths) do
        local w = live(p)
        if w and shown(w) then
            at = at or truth(comp)
            cleared = cleared + check(w, at)
        end
    end
end

-- Tests: how many cells have been cleared this session.
function S.cleared() return cleared end

return S
