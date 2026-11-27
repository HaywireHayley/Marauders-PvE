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

-- One cell of the walk below. walk.memo: item address -> its GUID and row (an item covers several cells). Returns the
-- row of a stale item it cleared, or nil.
local function checkSlot(walk, slot, id)
    local memo = walk.memo
    local it = slot and X.valid(slot) and slot.Item
    -- (an empty cell reads as a wrapper around a null pointer, which Lua counts as true: address 0 is empty)
    if not (it and it:GetAddress() ~= 0) then return nil end
    local stale, row = not X.valid(it), nil
    if not stale then
        local a = it:GetAddress()
        local m = memo[a]
        if not m then
            m = { g = it.UniqueItemGUID:ToString(), row = it.ItemData:ToString() }
            memo[a] = m
        end
        stale = walk.at[m.g] ~= id
        row = m.row
        -- The walk is spread over frames, so its truth may be older than a move made since: read it again (once this
        -- frame) before clearing anything. No inventory to read: clear nothing.
        if stale and walk.atStep ~= walk.step then
            if not X.valid(walk.comp) then return nil end
            walk.at, walk.atStep = truth(walk.comp), walk.step
            stale = walk.at[m.g] ~= id
        end
    end
    if not stale then return nil end
    slot.Item = nil
    return row or "a removed item"
end

-- The walk over the shown grids, a slice a frame: a big stash is over a thousand cells and each read goes through
-- UE4SS, so one walk in one frame was up to ~1 s (invsync max 987 ms in players' frames: lines, build 40, #336).
local BUDGET = 0.002 -- seconds of walking per frame
local walk -- { grids = { {w, id, n} }, g, i, at, memo, rows = {}, n }

local function startWalk(comp, ws)
    local at = truth(comp)
    walk = { grids = {}, g = 1, i = 1, at = at, comp = comp, step = 0, atStep = 0, memo = {}, rows = {}, n = 0 }
    for _, w in ipairs(ws) do
        local id = w.ContainerID:ToString()
        -- your own containers only: a bag's, rig's or box's grid is named after that item, which is in your inventory
        if OWN[id] or at[id] then
            walk.grids[#walk.grids + 1] = { w = w, id = id, n = w.InventorySlots:GetArrayNum() }
        end
    end
end

local function stepWalk()
    local t0 = os.clock()
    walk.step = walk.step + 1 -- (the truth read at the start counts as step 0's: the first slice re-reads before clearing)
    local k = 0
    while walk.g <= #walk.grids do
        local gr = walk.grids[walk.g]
        if not X.valid(gr.w) then walk = nil return end
        if walk.i > gr.n then
            walk.g, walk.i = walk.g + 1, 1
        else
            local row = checkSlot(walk, gr.w.InventorySlots[walk.i], gr.id)
            if row then
                walk.n = walk.n + 1
                walk.rows[gr.id .. ": " .. row] = true
            end
            walk.i = walk.i + 1
            k = k + 1
            if k % 16 == 0 and os.clock() - t0 >= BUDGET then return end
        end
    end
    if walk.n > 0 then
        local names = {}
        for r in pairs(walk.rows) do names[#names + 1] = r end
        X.log(("inventory: %d stale cell(s) cleared (they still pointed at %s)"):format(walk.n, table.concat(names, ", ")))
        cleared = cleared + walk.n
    end
    walk = nil
end

-- Every frame (main.lua onTick, lobby and raid), with the ticking player controller.
-- Only while the mouse cursor is up (a menu open: the inventory, the lobby): shown() can't tell a closed inventory, as a
-- grid's parent chain ends at its own widget's root and a copy that's off screen stays flagged visible. Without this,
-- after a bag or armour swap the check ran on such a copy every second for the rest of the raid: ~175 ms each time,
-- walking the whole inventory (#369, Walmarx's report: once-a-second stalls right after dragging a backpack on).
local LMB, wasDown, dueAt -- the left mouse button's key, its last state, a check asked for by a drag ending
local CLICK_GAP, lastClickRun = 1.0, -math.huge -- click-triggered checks at most once a second (perf: rapid clicks)
-- The button is read 20 times a second, not every frame: IsInputKeyDown through UE4SS cost ~0.9 ms a frame in the lobby
-- (invsync 780 ms of every 10 s, 2026-11-26). An item drag lasts far longer than 50 ms; a click too short to be seen is
-- still covered by the EVERY check.
local MOUSE_EVERY, mouseAt = 0.05, 0

function S.tick(pc)
    local now = os.clock()
    if now >= mouseAt and pc and X.valid(pc) then
        mouseAt = now + MOUSE_EVERY
        LMB = LMB or { KeyName = FName("LeftMouseButton") }
        local ok, down = pcall(function() return pc:IsInputKeyDown(LMB) end)
        if ok then
            -- Coalesced: at most one click-triggered check per CLICK_GAP; a release during the gap moves the check to the
            -- gap's end (so the last move of a burst is still checked) instead of adding another.
            if wasDown and not down and not dueAt then
                dueAt = math.max(now + AFTER_DRAG, lastClickRun + CLICK_GAP)
            end
            wasDown = down
        end
    end
    if walk then
        local ok, err = pcall(stepWalk)
        if not ok then walk = nil X.log("inventory check: " .. tostring(err)) end
        if walk then return end
    end
    if now < nextRun and not (dueAt and now >= dueAt) then return end
    if dueAt and now >= dueAt then lastClickRun = now end
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
    local ws = {}
    for _, p in ipairs(paths) do
        local w = live(p)
        if w and shown(w) then ws[#ws + 1] = w end
    end
    if #ws == 0 then return end
    startWalk(comp, ws)
end

-- Tests: how many cells have been cleared this session.
function S.cleared() return cleared end

return S
