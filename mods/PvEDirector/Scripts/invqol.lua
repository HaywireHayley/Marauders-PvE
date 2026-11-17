-- Stash quality of life (lobby): SORT (merges stacks, then packs by kind), a search box that dims what doesn't match,
-- and SELL SHOWN (at a trader: sells the stash items the search shows, after a confirm press). Hotkeys: K moves the
-- item under the mouse between stash and gear, J discards it (pressed twice).
-- A bar of plain widgets sits on top of the SECURE STORAGE panel while it's shown (LOADOUT and TRADE), polled like the
-- debug menu's buttons (UMG delegates can't be bound from Lua).
--
-- Everything goes through the game's own inventory calls, the ones its drag and drop makes, so the stand-in saves each
-- change as it would a hand-made one (verified 2026-11-17, hooked during a real drag):
--   Server_MoveItem(guid, "Stash", {Column, Row}, Normal 0, Normal 0, rotated)   a move (a drag fires exactly this)
--   Server_MergeStack(keep, absorbed, 0, 0)    the two stacks become `keep`; `absorbed` is deleted
--   Server_SellItem(guid)                      sold to the open trader
-- Server_MoveLobbyItem crashed the game, and Server_MenuMoveLobbyItem does nothing: don't use them.
-- Where things are: the stash grid's slot widgets (InventorySlots, row-major) each point at the item covering them,
-- which gives every item's footprint as it lies (rotation included; the item's own GetGridSizeVector is 0 x 0 in the
-- menu). Each item widget (DraggableItemsCanvas) has the item's type (GetItemType) and its "amount / max" text.
local Q = {}
local X -- log, valid, lib

local STASH = "Stash"
local TEXT = 12
local GAP = 6
local STEP = 0.12            -- seconds between the sort's moves (each is checked before the next)
local FIND_MAX = 10          -- the stash panel is looked for at most this often (seconds) while it hasn't been found
local DIM = 0.18             -- opacity of items the search doesn't match

-- Sort order by EItemType: guns, ammo, attachments, armour and bags, meds, storage, valuables, ship parts, cards.
local ORDER = { [0] = 1, [1] = 2, [2] = 3, [18] = 4, [15] = 5, [4] = 6, [9] = 7, [7] = 8, [8] = 8, [5] = 9, [6] = 9,
    [10] = 10, [11] = 10, [12] = 10, [3] = 11, [19] = 12, [13] = 13, [16] = 14, [17] = 14, [14] = 15, [20] = 16 }
local MERGE = { [18] = true, [3] = true } -- what stacks: Ammo, Consumable

local ui      -- { host, tree, root, sort, sell, search, status, ... }
local paths = { con = nil }  -- the stash container widget's path (looked up, never held)
local nextFind, findEvery = 0, 1
local job     -- the running sort or sale
local lastQuery, nextFilter = nil, 0
local worldKey

function Q.init(ctx) X = ctx end

local function live(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end

-- The stash panel. Found by search (backing off), kept as a path; a path that stops resolving is forgotten at once: a
-- lookup that finds nothing walks every object in the game (issue #112).
local function stashCon()
    local c = live(paths.con)
    if c then return c end
    paths.con = nil
    local now = os.clock()
    if now < nextFind then return nil end
    findEvery = math.min(FIND_MAX, findEvery * 2)
    nextFind = now + findEvery
    for _, w in ipairs(FindAllOf("InventoryContainerWidget") or {}) do
        if w:GetFullName():find("Transient", 1, true) and w.ContainerID:ToString() == STASH then
            paths.con = pathOf(w)
            findEvery = 1
            return w
        end
    end
end

-- The menu player's inventory component (the one the stash belongs to).
local function inventory()
    local pc = FindFirstOf("MenuPlayerController_C")
    if not X.valid(pc) then return nil end
    local comps = pc:K2_GetComponentsByClass(X.lib("/Script/SIGISPlugin.SIGISInventoryComponent"))
    for i = 1, #comps do
        local c = comps[i]:get()
        if X.valid(c) then return c, pc end
    end
end

-- Every stash item as it lies: guid -> { guid, row, c, r, w, h, rot, item }, and the grid's cells -> guid.
local function scan(con)
    local cols, rows = con.InventoryGridSize.Column, con.InventoryGridSize.Row
    local items, cells, i = {}, {}, 0
    con.InventorySlots:ForEach(function(_, e)
        local s = e:get()
        local c, r = i % cols, i // cols
        i = i + 1
        local it = X.valid(s) and s.Item
        if it and X.valid(it) then
            local g = it.UniqueItemGUID:ToString()
            cells[r * cols + c] = g
            local f = items[g]
            if not f then
                f = { guid = g, row = it.ItemData:ToString(), c = c, r = r, c1 = c, r1 = r, rot = it.bRotated,
                      stack = it.StackAmount, item = it }
                items[g] = f
            end
            f.n = (f.n or 0) + 1
            f.c, f.r = math.min(f.c, c), math.min(f.r, r)
            f.c1, f.r1 = math.max(f.c1, c), math.max(f.r1, r)
        end
    end)
    for _, f in pairs(items) do
        f.w, f.h = f.c1 - f.c + 1, f.r1 - f.r + 1
        f.bad = f.n ~= f.w * f.h -- (not a clean rectangle: an item hanging off the grid's edge wraps into the next row)
    end
    return items, cells, cols, rows
end

-- What the item widgets know: type, shown name and max stack ("12 / 60" -> 60), by guid.
local function details(con)
    local out = {}
    local canvas = con.DraggableItemsCanvas
    if not X.valid(canvas) then return out end
    for k = 0, canvas:GetChildrenCount() - 1 do
        local w = canvas:GetChildAt(k)
        local it = X.valid(w) and w.Item
        if it and X.valid(it) then
            local d = { widget = w, type = 24, name = it.ItemData:ToString(), max = 1 }
            pcall(function() d.type = w:GetItemType() end)
            -- (the widget's own name text: the item's GetItemName crashed the game, a null read, from the menu)
            pcall(function() d.name = w.ItemName:GetText():ToString() end)
            d.key = (d.name .. " " .. it.ItemData:ToString()):lower() -- (small items show a short name: "Band")
            pcall(function()
                local t = w.amount:GetText():ToString()
                d.max = tonumber(t:match("/%s*(%d+)")) or 1
            end)
            out[it.UniqueItemGUID:ToString()] = d
        end
    end
    return out
end

local function fits(cells, cols, rows, c, r, w, h, self)
    if c < 0 or r < 0 or c + w > cols or r + h > rows then return false end
    for y = r, r + h - 1 do
        for x = c, c + w - 1 do
            local g = cells[y * cols + x]
            if g and g ~= self then return false end
        end
    end
    return true
end

local function mark(cells, cols, c, r, w, h, g)
    for y = r, r + h - 1 do for x = c, c + w - 1 do cells[y * cols + x] = g end end
end

local function say(s)
    if ui and ui.status then ui.status:SetText(FText(s)) end
end

-- Sort -----------------------------------------------------------------------------------------------------------
-- 1. Merges: each kind's part stacks into the fullest one, never past its max (what the game does past it is unknown).
local function mergePlan(items, info)
    local byRow, plan = {}, {}
    for g, f in pairs(items) do
        local d = info[g]
        -- Ammo and consumables only. A gun's StackAmount is its magazine and its text reads like a stack ("36/36"):
        -- merging guns duplicated and overlapped them (2026-11-17, a test stash).
        if d and MERGE[d.type] and d.max > 1 and f.stack < d.max then
            byRow[f.row] = byRow[f.row] or {}
            table.insert(byRow[f.row], { guid = g, n = f.stack, max = d.max })
        end
    end
    for _, list in pairs(byRow) do
        table.sort(list, function(a, b) return a.n > b.n end)
        local i, j = 1, #list
        while i < j do
            local keep, take = list[i], list[j]
            if keep.n + take.n <= keep.max then
                plan[#plan + 1] = { keep = keep.guid, take = take.guid }
                keep.n = keep.n + take.n
                j = j - 1
                if keep.n == keep.max then i = i + 1 end
            else
                i = i + 1
            end
        end
    end
    return plan
end

-- 2. Where everything goes: packed left to right, top to bottom. By kind (then biggest first, then name) if that
-- packs; a nearly full stash may only pack biggest-first (kinds then follow within each size), or tallest-first.
local ORDERINGS = {
    function(a, b) if a.order ~= b.order then return a.order < b.order end
        if a.w * a.h ~= b.w * b.h then return a.w * a.h > b.w * b.h end
        if a.name ~= b.name then return a.name < b.name end return a.stack > b.stack end,
    function(a, b) if a.w * a.h ~= b.w * b.h then return a.w * a.h > b.w * b.h end
        if a.order ~= b.order then return a.order < b.order end
        if a.name ~= b.name then return a.name < b.name end return a.stack > b.stack end,
    function(a, b) if a.h ~= b.h then return a.h > b.h end
        if a.w ~= b.w then return a.w > b.w end
        if a.order ~= b.order then return a.order < b.order end
        return a.name < b.name end,
}

local function pack(list, cols, rows)
    local cells = {}
    for _, f in ipairs(list) do
        local placed = false
        for r = 0, rows - f.h do
            for c = 0, cols - f.w do
                if fits(cells, cols, rows, c, r, f.w, f.h) then
                    mark(cells, cols, c, r, f.w, f.h, f.guid)
                    f.tc, f.tr, placed = c, r, true
                    break
                end
            end
            if placed then break end
        end
        if not placed then return false end
    end
    return true
end

local function layout(items, info, cols, rows)
    local list = {}
    for g, f in pairs(items) do
        list[#list + 1] = f
        f.order = ORDER[(info[g] or {}).type or 24] or 20
        f.name = (info[g] or {}).name or f.row
    end
    for n, cmp in ipairs(ORDERINGS) do
        table.sort(list, cmp)
        if pack(list, cols, rows) then return list, n end
    end
    return nil
end

local function move(inv, f, c, r)
    inv:Server_MoveItem(f.guid, STASH, { Column = c, Row = r }, 0, 0, f.rot)
end

-- One step of a running sort: a merge, or one move into space that's free now (an item in the way is put aside
-- first). Every step is checked on the next: one that didn't happen twice stops the sort.
local function sortStep(con, inv)
    if job.phase == "merge" then
        local m = job.merges[job.mi]
        if m then
            job.mi = job.mi + 1
            inv:Server_MergeStack(m.keep, m.take, 0, 0)
            job.merged = job.merged + 1
            return
        end
        job.phase = "plan"
        return
    end
    local items, cells, cols, rows = scan(con)
    if job.phase == "plan" then
        for _, f in pairs(items) do
            if f.bad then return ("%s lies across the grid's edge: move it by hand first"):format(f.row) end
        end
        job.list, job.how = layout(items, details(con), cols, rows)
        if not job.list then return "the stash is too full to sort neatly: free some space" end
        job.phase, job.steps, job.limit, job.k = "move", 0, #job.list * 4 + 20, 1
    end
    if job.last then
        local f = items[job.last.guid]
        if f and (f.bad or f.w ~= job.last.w or f.h ~= job.last.h) then
            return ("%s didn't land as expected (now %dx%d at %d,%d)"):format(f.row, f.w, f.h, f.c, f.r)
        end
        if f and (f.c ~= job.last.c or f.r ~= job.last.r) then
            job.misses = (job.misses or 0) + 1
            if job.misses >= 2 then return "a move didn't happen" end
        else
            job.misses = 0
        end
        job.last = nil
    end
    -- Items are placed in the final layout's order, and an item in its place is never moved again. When the next one
    -- can't go yet, what's in its way goes to free space outside every finished place (preferably outside the places
    -- still to come too); failing that, any later item whose place is free goes there, or something in a later item's
    -- way is put aside. (Simulated on 300 random, packed-full 10 x 15 stashes: 297 sorted completely, the rest stop
    -- at the move limit with the stash intact.)
    job.steps = job.steps + 1
    if job.steps > job.limit then return "too many moves" end
    local list = job.list
    local function at(t) local f = items[t.guid] return not f or (f.c == t.tc and f.r == t.tr) end
    while job.k <= #list and at(list[job.k]) do job.k = job.k + 1 end
    if job.k > #list then return true end
    local done, later = {}, {}
    for n, p in ipairs(list) do
        if n <= job.k or at(p) then mark(done, cols, p.tc, p.tr, p.w, p.h, p.guid)
        else mark(later, cols, p.tc, p.tr, p.w, p.h, p.guid) end
    end
    job.hist = job.hist or {}
    local function been(g, c, r) return job.hist[g] and job.hist[g][c .. "," .. r] end
    local function go(f, c, r)
        job.hist[f.guid] = job.hist[f.guid] or { [f.c .. "," .. f.r] = true }
        job.hist[f.guid][c .. "," .. r] = true
        if c < 0 or r < 0 or c + f.w > cols or r + f.h > rows then error("target off the grid") end
        X.log(("stash: move %s %dx%d %d,%d -> %d,%d"):format(f.row, f.w, f.h, f.c, f.r, c, r))
        move(inv, f, c, r)
        job.last, job.moved = { guid = f.guid, c = c, r = r, w = f.w, h = f.h }, job.moved + 1
    end
    local function blockers(t)
        local out, seen = {}, {}
        for y = t.tr, t.tr + t.h - 1 do
            for x = t.tc, t.tc + t.w - 1 do
                local g = cells[y * cols + x]
                if g and g ~= t.guid and not seen[g] and items[g] then seen[g] = true; out[#out + 1] = items[g] end
            end
        end
        return out
    end
    local placedAt = {}
    for _, p in ipairs(list) do if at(p) then placedAt[p.guid] = true end end
    local function aside(b)
        if placedAt[b.guid] then return false end
        for pass = 1, 2 do
            for r = 0, rows - b.h do
                for c = 0, cols - b.w do
                    if fits(cells, cols, rows, c, r, b.w, b.h, b.guid) and fits(done, cols, rows, c, r, b.w, b.h)
                        and (pass == 2 or fits(later, cols, rows, c, r, b.w, b.h, b.guid))
                        and not (c == b.c and r == b.r) and not been(b.guid, c, r) then
                        go(b, c, r) -- (never back to a spot it has had: two rules undoing each other cycled forever)
                        return true
                    end
                end
            end
        end
        return false
    end
    local t = list[job.k]
    if fits(cells, cols, rows, t.tc, t.tr, t.w, t.h, t.guid) then go(items[t.guid], t.tc, t.tr) return end
    for _, b in ipairs(blockers(t)) do if aside(b) then return end end
    for n = job.k + 1, #list do
        local p = list[n]
        if not at(p) and fits(cells, cols, rows, p.tc, p.tr, p.w, p.h, p.guid) then go(items[p.guid], p.tc, p.tr) return end
    end
    for n = job.k + 1, #list do
        local p = list[n]
        if not at(p) then
            for _, b in ipairs(blockers(p)) do
                if b.guid ~= t.guid and aside(b) then return end
            end
        end
    end
    return "the stash is too full to rearrange: free a few cells"
end

-- Sell what the search shows ------------------------------------------------------------------------------------
local function shopOpen(con)
    local canvas = con.DraggableItemsCanvas
    for k = 0, math.min(canvas:GetChildrenCount(), 3) - 1 do
        local w = canvas:GetChildAt(k)
        local ok, open = pcall(function() return w:IsShopOpen() end)
        if ok then return open end
    end
    return false
end

-- What the search box shows: the stash items whose name (or row) matches it. Nothing when it's empty.
local function matching(con, query)
    local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local out = {}
    if q == "" then return out end
    for g, d in pairs(details(con)) do
        if (d.key or d.name:lower()):find(q, 1, true) then out[#out + 1] = g end
    end
    return out
end

local function sellStep(con, inv)
    local g = job.list[job.i]
    if not g then return true end
    job.i = job.i + 1
    inv:Server_SellItem(g)
    job.sold = job.sold + 1
end

-- Search ---------------------------------------------------------------------------------------------------------
local function filter(con, query)
    local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- Every widget on the canvas (an item that has moved can have more than one: dimming one per item missed some).
    local canvas = con.DraggableItemsCanvas
    for k = 0, canvas:GetChildrenCount() - 1 do
        local w = canvas:GetChildAt(k)
        local it = X.valid(w) and w.Item
        if it and X.valid(it) then
            local on = q == ""
            if not on then
                local name = ""
                pcall(function() name = w.ItemName:GetText():ToString() end)
                on = (name .. " " .. it.ItemData:ToString()):lower():find(q, 1, true) ~= nil
            end
            pcall(function() w:SetRenderOpacity(on and 1 or DIM) end)
        end
    end
end

-- Hotkeys (main.lua binds them; they arrive here on the game thread): K moves the item under the mouse between the
-- stash and your pockets and bags, J discards it (a second J within CONFIRM seconds: it can't be undone). Ignored while
-- the search box is being typed in.
local CONFIRM = 2
local function freeSpot(con, f)
    local _, cells, cols, rows = scan(con)
    for _, dims in ipairs({ { f.w, f.h, f.rot }, { f.h, f.w, 1 - f.rot } }) do
        for r = 0, rows - dims[2] do
            for c = 0, cols - dims[1] do
                if fits(cells, cols, rows, c, r, dims[1], dims[2]) then return c, r, dims[3] end
            end
        end
    end
end

local function hovered()
    for _, w in ipairs(FindAllOf("InventoryContainerWidget") or {}) do
        if w:GetFullName():find("Transient", 1, true) and w:IsVisible() and w.SlotMasterType == 0 then
            local canvas = w.DraggableItemsCanvas
            for k = 0, (X.valid(canvas) and canvas:GetChildrenCount() or 0) - 1 do
                local iw = canvas:GetChildAt(k)
                if X.valid(iw) and X.valid(iw.Item) and iw:IsHovered() then return iw, w end
            end
        end
    end
end

function Q.hotkey(what)
    if not (ui and ui.search) then return end
    if ui.search:HasKeyboardFocus() then return end
    local inv = inventory()
    local stash = stashCon()
    if not (inv and stash and stash:IsVisible()) then return end
    local iw, from = hovered()
    if not iw then return end
    local it = iw.Item
    local guid = it.UniqueItemGUID:ToString()
    local items = scan(from)
    local f = items[guid]
    if not f then return end
    local name = it.ItemData:ToString()
    pcall(function() name = iw.ItemName:GetText():ToString() end)
    if what == "discard" then
        local now = os.clock()
        if ui.discard == guid and now < (ui.discardAt or 0) then
            ui.discard = nil
            inv:Server_RemoveItem(guid)
            say("Discarded " .. name)
            X.log("stash: discarded " .. f.row)
        else
            ui.discard, ui.discardAt = guid, now + CONFIRM
            say(("Press J again to discard %s"):format(name))
        end
        return
    end
    -- K: from the stash to the first pocket or bag with room; from anywhere else to the stash.
    local targets = {}
    if from.ContainerID:ToString() == STASH then
        for _, w in ipairs(FindAllOf("InventoryContainerWidget") or {}) do
            if w:GetFullName():find("Transient", 1, true) and w:IsVisible() and w.SlotMasterType == 0
                and not w.bARigCon and w.ContainerID:ToString() ~= STASH then targets[#targets + 1] = w end
        end
    else
        targets[1] = stash
    end
    for _, w in ipairs(targets) do
        local c, r, rot = freeSpot(w, f)
        if c then
            inv:Server_MoveItem(guid, w.ContainerID:ToString(), { Column = c, Row = r }, 0, 0, rot)
            say(("Moved %s to %s"):format(name, w.ContainerID:ToString() == STASH and "the stash" or "your gear"))
            lastQuery = nil
            return
        end
    end
    say(("No room for %s"):format(name))
end

-- The bar ---------------------------------------------------------------------------------------------------------
-- A row added to the stash panel itself (its VerticalBox: the SECURE STORAGE title, the scrolling grid, then this), so
-- it follows the menu's own layout and scaling and shows and hides with the panel. (Placing a separate overlay over
-- it needs the panel's on-screen geometry, which UE4SS can't return here: GetCachedGeometry comes back empty.)
local function make(cls, outer) return StaticConstructObject(X.lib("/Script/UMG." .. cls), outer) end

local function build(con)
    local box = con:GetParent() and con:GetParent():GetParent()
    if not (box and X.valid(box) and box:GetClass():GetFName():ToString() == "VerticalBox") then return false end
    local outer = box:GetOuter()
    local row = make("HorizontalBox", outer)
    local function text(s, opacity)
        local t = make("TextBlock", outer)
        t.Font.Size = TEXT
        t:SetText(FText(s))
        if opacity then t:SetOpacity(opacity) end
        return t
    end
    local function button(label)
        local b = make("Button", outer)
        local t = text(label)
        b:AddChild(t)
        local slot = row:AddChildToHorizontalBox(b)
        slot:SetPadding({ Left = 0, Top = 4, Right = GAP, Bottom = 2 })
        return { b = b, text = t }
    end
    ui = { row = row }
    ui.sort = button("SORT")
    ui.sell = button("SELL SHOWN")
    ui.search = make("EditableTextBox", outer)
    pcall(function() ui.search:SetHintText(FText("Search the stash")) end)
    local ss = row:AddChildToHorizontalBox(ui.search)
    ss:SetPadding({ Left = 0, Top = 4, Right = GAP, Bottom = 2 })
    pcall(function() ss:SetSize({ Value = 1, SizeRule = 1 }) end) -- Fill
    local slot = box:AddChildToVerticalBox(row)
    slot:SetPadding({ Left = 6, Top = 0, Right = 6, Bottom = 0 })
    ui.status = text(" ", 0.8) -- (its own line under the bar)
    local st = box:AddChildToVerticalBox(ui.status)
    st:SetPadding({ Left = 8, Top = 0, Right = 6, Bottom = 4 })
    ui.box = pathOf(box)
    X.log("stash tools: SORT, search and SELL SHOWN added under the stash")
    return true
end

local function pressed(b)
    local down = b.b:IsPressed()
    local click = b.down and not down
    b.down = down
    return click
end

-- Every frame in the lobby (from main.lua's tick, lobby only).
function Q.tick(ticker)
    local lobby = ticker:IsValid() and ticker:GetClass():GetFName():ToString() == "MM_CoreMissions_C"
    local wk = lobby and ticker:GetWorld():GetAddress() or nil
    if wk ~= worldKey then worldKey, ui, job, paths.con, lastQuery = wk, nil, nil, nil, nil end
    if not lobby then return end
    local con = stashCon()
    local shown = con and con:IsVisible()
    if not shown then return end
    local inv, pc = inventory()
    if not inv then return end
    if not ui and not build(con) then return end
    local now = os.clock()

    if job and now >= (job.at or 0) then
        job.at = now + STEP
        local ok, res = pcall(job.kind == "sort" and sortStep or sellStep, con, inv)
        if not ok then res = "failed: " .. tostring(res) end
        if res == true then
            say(job.kind == "sort" and ("Sorted: %d moves, %d stacks merged"):format(job.moved, job.merged)
                or ("Sold %d item(s)"):format(job.sold))
            X.log("stash: " .. (job.kind == "sort" and ("sorted, %d moves, %d merges"):format(job.moved, job.merged)
                or ("sold %d item(s)"):format(job.sold)))
            job, lastQuery = nil, nil -- (moved items get new widgets: filter them again)
        elseif res then
            say(res:find("too full", 1, true) and ("Sorted as far as space allows (%d moves): " .. res):format(job.moved)
                or ("Stopped: " .. res))
            X.log("stash: " .. job.kind .. " stopped: " .. res)
            job = nil
        end
    end

    if not job and pressed(ui.sort) then
        local items = scan(con)
        local plan = mergePlan(items, details(con))
        job = { kind = "sort", phase = "merge", merges = plan, mi = 1, merged = 0, moved = 0 }
        say("Sorting...")
    end
    local isShop = shopOpen(con)
    local query = ui.search:GetText():ToString()
    ui.sell.b:SetIsEnabled(isShop and not job and query:match("%S") ~= nil)
    if pressed(ui.sell) and not job then
        local list = matching(con, query)
        if #list == 0 then say("Nothing in the stash matches the search")
        elseif ui.sellArmed and now < ui.sellArmed and ui.sellCount == #list then
            ui.sellArmed = nil
            ui.sell.text:SetText(FText("SELL SHOWN"))
            job = { kind = "sell", list = list, i = 1, sold = 0 }
            say("Selling...")
        else
            ui.sellArmed, ui.sellCount = now + 4, #list
            ui.sell.text:SetText(FText(("CONFIRM: SELL %d"):format(#list)))
        end
    end
    if ui.sellArmed and now >= ui.sellArmed then ui.sellArmed = nil ui.sell.text:SetText(FText("SELL SHOWN")) end

    if now >= nextFilter then
        nextFilter = now + 0.25
        local qtext = ui.search:GetText():ToString()
        if qtext ~= lastQuery then lastQuery = qtext filter(con, qtext) end
    end
end

return Q
