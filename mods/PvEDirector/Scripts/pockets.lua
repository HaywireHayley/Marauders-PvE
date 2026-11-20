-- Free space in your pocket (PocketLeft, 2 x 2 cells), from every carried item's real footprint. PocketRight exists
-- in the inventory (1 x 2) but the game never builds its grid or shows it: anything put there is invisible and can't
-- be moved (2026-11-20), so nothing goes there.
-- Anything the mod puts into your pockets (defuse.lua's loot, the F9 ammo button, loadout.lua's ammo with a soldier's
-- gun) goes through here, so nothing lands on top of another item: items stacked on one cell break the inventory (the
-- top one hides the rest, moves freeze, discards come back; #239, #240).
-- Sizes come from items.json (itemdata.lua): the game's own GetGridSizeVector reads 0 x 0. `bRotated` reads as a
-- number from Lua, and 0 is true to Lua, so it's compared with 1.
--   local Pockets = require("pockets")
--   local cells = Pockets.cells(inv)                         -- { ["PocketLeft 0 1"] = true, ... }
--   local col, row, rot = Pockets.fit(cells, "PocketLeft", "AP_Mine")
--   Pockets.claim(cells, "PocketLeft", "AP_Mine", col, row, rot)
local Items = require("itemdata")
local P = {}

P.POCKETS = { "PocketLeft" }
local SIDE = 2

local function key(con, col, row) return ("%s %d %d"):format(con, col, row) end

-- A row's width and height in cells, rotated or not (unknown rows: 1 x 1).
function P.size(row, rotated)
    local r = Items.get(row) or {}
    local w, h = r.w or 1, r.h or 1
    if rotated then return h, w end
    return w, h
end

function P.rotated(it)
    local r = it.bRotated
    return r == true or r == 1
end

-- Every cell each item in the inventory covers, keyed "container column row". `each(item, container, row)` is
-- called for every item too, if given.
function P.cells(inv, each)
    local cells = {}
    if not (inv and inv:IsValid()) then return cells end
    inv.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if it and it:IsValid() then
            local con, row = it.MotherItemGUID:ToString(), it.ItemData:ToString()
            if each then each(it, con, row) end
            pcall(function()
                local w, h = P.size(row, P.rotated(it))
                local c0, r0 = it.ItemInSlot.Column, it.ItemInSlot.Row
                for dc = 0, w - 1 do
                    for dr = 0, h - 1 do cells[key(con, c0 + dc, r0 + dr)] = true end
                end
            end)
        end
    end)
    return cells
end

-- A free spot for one `row` item in a pocket: column, row, rotated; nil when it doesn't fit.
function P.fit(cells, pocket, row)
    for _, rot in ipairs({ false, true }) do
        local w, h = P.size(row, rot)
        for line = 0, SIDE - h do
            for col = 0, SIDE - w do
                local free = true
                for dc = 0, w - 1 do
                    for dr = 0, h - 1 do
                        if cells[key(pocket, col + dc, line + dr)] then free = false end
                    end
                end
                if free then return col, line, rot end
            end
        end
    end
end

-- Marks a spot taken (after putting an item there), so the next fit looks past it.
function P.claim(cells, pocket, row, col, line, rot)
    local w, h = P.size(row, rot)
    for dc = 0, w - 1 do
        for dr = 0, h - 1 do cells[key(pocket, col + dc, line + dr)] = true end
    end
end

-- The first pocket with room: pocket, column, row, rotated (or nil).
function P.find(cells, row)
    for _, pocket in ipairs(P.POCKETS) do
        local col, line, rot = P.fit(cells, pocket, row)
        if col then return pocket, col, line, rot end
    end
end

return P
