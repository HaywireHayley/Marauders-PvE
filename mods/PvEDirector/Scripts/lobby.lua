-- The main menu's own work (moved out of main.lua's update): the captain's START button hook, your player level for
-- gear that follows it, your crew's record, the stash's height and grid, the character standing in the lobby, and the
-- splash sweep. main.lua's update calls M.tick at the same point as before, every update, in the menu or not.
local PROJECT = require("pveproject")
local GearScale = require("gearscale") -- rivals' and crew's gear follows your player level
local Hire = require("hire")
local Launch = require("launch")
local Female = require("female")
local Splash = require("splash")
local M = {}

local X -- log, valid, stashRows (main.lua's pve_stash_rows: inventory component, rows)
local valid
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)

local STASH_ROWS = PROJECT .. "config/stash_rows.txt"
local STASH_ROWS_MAX = 25
local STASH_UNLOCKS = { i1 = true, i2 = true, i3 = true, i4 = true } -- DT_PrestigeUnlockInfo, InventorySpace
local STASH_UNLOCK_ROWS = 2 -- each one's StashSizeIncrease

function M.setRaid(r) raid = r end

function M.init(ctx) X = ctx valid = ctx.valid end

-- age: this map's age (s); inMenu: the world is the main menu.
function M.tick(pc, age, inMenu)
    if inMenu then
        Launch.hookCaptainButton()
        -- Your player level, for gear that follows it (gearscale.lua): only the menu's controller knows it. The cap is the
        -- last level GetXPForLevel still climbs at (asked once).
        if os.clock() - (raid.levelReadAt or -100) > 5 then
            raid.levelReadAt = os.clock()
            pcall(function()
                -- The game counts from 0 (a new player shows "LVL 0"; GetXPForLevel(1) = 525), gearscale from 1. Level 0
                -- used to be dropped, so a new save kept the last save's level (and its geared enemies).
                local lvl = pc:GetPlayersLevel() + 1
                if not raid.levelMax then
                    raid.levelMax = 0
                    local prev, table_ = -1, {}
                    for n = 1, 200 do
                        local xp = pc:GetXPForLevel(n)
                        if type(xp) ~= "number" or xp <= prev then break end
                        prev, raid.levelMax = xp, n
                        table_[n] = string.format("%d", xp)
                    end
                    -- (#561) the launcher's Levels dialog turns a level into XP with the game's own table
                    local f = #table_ > 0 and io.open(PROJECT .. "config/xp_levels.txt", "w")
                    if f then f:write(table.concat(table_, ","), "\n") f:close() end
                end
                local max = raid.levelMax >= 2 and raid.levelMax < 200 and raid.levelMax or nil
                if GearScale.setLevel(lvl, max) then
                    X.log(("gear scale: player level %d of %d, gear grade centre %.2f"):format(GearScale.level(),
                        GearScale.CFG.LEVEL_MAX, GearScale.target()))
                end
            end)
        end
        local okh, errh = pcall(Hire.lobby, pc) -- back from a raid: the crew's record, promotions
        if not okh then X.log("crew lobby: " .. tostring(errh)) end
    else
        Hire.leftLobby()
    end
    if inMenu then
        -- A save with its own stash height (launcher), plus the prestige stash upgrades you own, at most STASH_ROWS_MAX.
        -- The game indexes stash cells with a byte: past 256 cells (25 rows of 10) slots wrap onto the top rows, so the
        -- highlights land 25 rows off and spaces clash. Rechecked every 2 s, so an upgrade bought in the menu counts too.
        if raid.stashFile == nil then
            local f = io.open(STASH_ROWS, "r")
            raid.stashFile = f and tonumber(f:read("l")) or false
            if f then f:close() end
        end
        if raid.stashFile and age >= (raid.stashCheck or 0) then
            raid.stashCheck = age + 2
            if not valid(raid.stashInv) then raid.stashInv = FindFirstOf("SIGISInventoryComponent") end
            if not valid(raid.stashPc) then raid.stashPc = FindFirstOf("SIGISPlayerController") end
            local inv, pc = raid.stashInv, raid.stashPc
            if valid(inv) then
                local bought = 0
                if valid(pc) then
                    pcall(function()
                        pc.PrestigeUnlocks:ForEach(function(_, e)
                            if STASH_UNLOCKS[e:get():ToString()] then bought = bought + 1 end
                        end)
                    end)
                end
                local asked = raid.stashFile + bought * STASH_UNLOCK_ROWS
                local rows = math.min(asked, STASH_ROWS_MAX)
                if raid.stashAsked ~= asked then
                    raid.stashAsked = asked
                    X.log(("stash: %d rows (save %d, %d prestige upgrade(s))%s"):format(rows, raid.stashFile, bought,
                        asked > rows and (", capped from %d: the game's grid can't index more"):format(asked) or ""))
                end
                -- Written every check: the game adds an upgrade's rows to the size itself when you buy one.
                X.stashRows(math.tointeger(inv:GetAddress()), rows)
                -- The stash grid keeps its own size and builds its slots when the menu does: rebuilt when they differ.
                local w = raid.stashGrid
                -- FindAllOf is 30-45 ms and finds nothing until the stash menu is built: after a miss the wait
                -- between looks grows from 2 s to 10 s, and starts over when a look finds it.
                if not valid(w) and age >= (raid.stashGridAt or 0) then
                    w = nil
                    for _, x in ipairs(FindAllOf("InventoryContainerWidget") or {}) do
                        local name = valid(x) and x:GetFullName() or ""
                        if name:find("Transient", 1, true) and name:find("InventoryStashGrid", 1, true)
                            and x.InventorySlots:GetArrayNum() > 0 then
                            w = x
                        end
                    end
                    raid.stashGrid = w
                    raid.stashGridWait = w and 2 or math.min((raid.stashGridWait or 1) * 2, 10)
                    raid.stashGridAt = age + raid.stashGridWait
                elseif not valid(w) then
                    w = nil
                end
                if w and w.InventoryGridSize.Row ~= rows then
                    w.InventoryGridSize.Row = rows
                    w.InventoryGrid:ClearChildren()
                    w.InventorySlots:Empty()
                    w:InitializeGrid()
                    X.log(("stash grid: %d rows, %d items on it"):format(rows, w.DraggableItemsCanvas:GetChildrenCount()))
                end
            end
        end
        -- The character standing in the lobby. It's a scan, so not every update, and it re-dresses when you change clothes.
        if age >= (raid.lobbyDress or 0) then
            raid.lobbyDress = age + 3
            if Female.playerDue() then
                -- The stand is kept (raid is per world) and only looked for again once it's gone.
                if not valid(raid.lobbyStand) then
                    raid.lobbyStand = nil
                    for _, char in ipairs(FindAllOf("MM_PlayerChar_C") or {}) do
                        -- only your own stand: the others are your crew's (crewlobby.lua)
                        if valid(char) and not char:GetFullName():find("Default__", 1, true) and char.isPlayer then
                            raid.lobbyStand = char
                        end
                    end
                end
                if raid.lobbyStand then pcall(Female.dress, raid.lobbyStand, Female.playerOn()) end
            end
        end
        if not raid.splashDone and age >= (raid.splashSweep or 0) then
            raid.splashSweep = age + 1
            raid.splashDone = Splash.apply(pc)
        end
    end
end

return M
