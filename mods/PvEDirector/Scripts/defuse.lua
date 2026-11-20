-- Defusing the mines inside stations (#197, the first part: small mines in place). The Raid maps' UA_Mine_Spawner_C
-- place a MineStaticActor_C (15% each; Spaceport_01 has 33 spawners): an anti-personnel mine whose 30 cm trigger
-- sphere sets Active false, clicks, and 0.25 s later explodes (radial damage 60 within 2-5 m). Both of its trigger paths
-- check Active first (bytecode, 2026-11-20), so a mine with Active false never goes off.
-- Stand next to an armed mine with a ToolKit in your gear and press F: a Minesweeper board (6 x 6, MINES hidden, a
-- timer) comes up. Clear it and the mine is disarmed and comes apart: the mine itself (AP_Mine) and some gunpowder go
-- into your pockets if there's room. Reveal a hidden charge or run out of time and it goes off, through the mine's own
-- MultiExpo (its sound, blast and damage). The ToolKit is a tool: it's kept either way. Back away to stop.
-- Built and polled like the F9 menu (debugmenu.lua): plain widgets in a DebugInfo_Widget, UMG delegates can't be
-- bound from Lua. Flags: a "Flag mode" button, since only left clicks reach a polled button.
local M = {}
local X -- log, valid, lib, menuClosed

local CFG = {
    SIZE = 6, MINES = 6, TIME = 75,  -- the board and its timer (s)
    REACH = 170,                     -- cm from your feet to a mine you can work on (its trigger sphere is 30 cm)
    SCAN_EVERY = 20,                 -- s between looks for mines on foot (a FindAllOf)
    TOOL = "ToolKit",                -- the item row you need on you
    LOOT = { { "AP_Mine", 1 }, { "Gunpowder", 2 } }, -- what a defused mine leaves (row, stack)
}
M.CFG = CFG
local NOT_CARRIED = { Stash = true, Lobby = true, Shop = true, LootCon = true, Gift = true, scrap = true }
local POCKETS = { "PocketLeft", "PocketRight" } -- 2 x 2 cells each
local CELL, GAP = 46, 4
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local HIDDEN = { R = 0.32, G = 0.33, B = 0.35, A = 1 }
local OPEN = { R = 0.08, G = 0.09, B = 0.1, A = 1 }
local FLAGGED = { R = 0.75, G = 0.45, B = 0.1, A = 1 }
local BOOM = { R = 0.8, G = 0.1, B = 0.05, A = 1 }

local mines, scanAt, near = {}, 0, nil
local hint   -- { host, text, shown } the prompt line
local board  -- the open board, see open()

function M.init(ctx) X = ctx end

local function lib(p) return X.lib(p) end
local function make(tree, cls) return StaticConstructObject(lib("/Script/UMG." .. cls), tree) end

local function host(pc)
    local cls = lib(HOST)
    if not X.valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = lib(HOST) end
    if not X.valid(cls) then return nil end
    local h = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not X.valid(h) then return nil end
    h.WidgetTree.RootWidget:ClearChildren()
    return h
end

local function place(root, w, x, y, wd, ht)
    local s = root:AddChildToCanvas(w)
    s:SetPosition({ X = x, Y = y })
    s:SetSize({ X = wd, Y = ht })
    return s
end

local function text(tree, s, size)
    local t = make(tree, "TextBlock")
    t.Font.Size = size or 14
    t:SetText(FText(s))
    return t
end

-- The viewport in widget units (what a canvas slot's position is measured in).
local function screen(pc)
    local wll = lib("/Script/UMG.Default__WidgetLayoutLibrary")
    local vp, scale = { X = 1600, Y = 900 }, 1
    pcall(function() vp = wll:GetViewportSize(pc) end)
    pcall(function() scale = wll:GetViewportScale(pc) end)
    if not (scale and scale > 0) then scale = 1 end
    return vp.X / scale, vp.Y / scale, scale
end

local function onFoot(pc)
    local p = X.valid(pc) and pc.Pawn
    if not (p and X.valid(p)) then return nil end
    local ok, n = pcall(function() return p:GetClass():GetFName():ToString() end)
    return ok and n == "PlayerPawn_C" and p or nil
end

-- What you carry: a ToolKit?, and which pocket cells are taken.
local function carried()
    local out = { tool = false, cells = {} }
    local inv = FindFirstOf("SIGISInventoryComponent")
    if not X.valid(inv) then return out end
    inv.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if it and it:IsValid() then
            local con = it.MotherItemGUID:ToString()
            if not NOT_CARRIED[con] and it.ItemData:ToString() == CFG.TOOL then out.tool = true end
            pcall(function() out.cells[("%s %d %d"):format(con, it.ItemInSlot.Column, it.ItemInSlot.Row)] = true end)
        end
    end)
    return out
end

-- Into the first free pocket cells, the way the F9 ammo button gives (debuggive.lua).
local function giveLoot(pc)
    local cells, given = carried().cells, {}
    for _, l in ipairs(CFG.LOOT) do
        local done = false
        for _, pocket in ipairs(POCKETS) do
            for line = 0, 1 do
                for col = 0, 1 do
                    local key = ("%s %d %d"):format(pocket, col, line)
                    if not done and not cells[key] then
                        cells[key], done = true, true
                        pc:Server_AwsN_EquippedItemsReturned(('[{"value":{"equip":true,"value":"%s-%s-%d-100-%d-%d-0-%s"}}]')
                            :format(tostring(math.random(10000000, 99999999)), l[1], l[2], col, line, pocket))
                        given[#given + 1] = l[1]
                    end
                end
            end
        end
    end
    return given
end

-- The prompt line, bottom middle, while you stand by an armed mine.
local function say(pc, s)
    if hint and not X.valid(hint.host) then hint = nil end
    if not hint then
        local h = host(pc)
        if not h then return end
        hint = { host = h, text = text(h.WidgetTree, "", 18) }
        hint.slot = h.WidgetTree.RootWidget:AddChildToCanvas(hint.text)
        hint.slot:SetAutoSize(true)
        hint.slot:SetAlignment({ X = 0.5, Y = 0.5 })
        h:AddToViewport(40)
    end
    if s and hint.shown ~= s then -- (SetAnchors with a table didn't take: placed from the viewport's size instead)
        local w, h = screen(pc)
        hint.slot:SetPosition({ X = w / 2, Y = h * 0.72 })
    end
    if hint.shown ~= s then
        hint.shown = s
        hint.text:SetText(FText(s or ""))
        hint.host:SetVisibility(s and 4 or 1) -- HitTestInvisible / Collapsed
    end
end

-- The board ---------------------------------------------------------------------------------------------------------
local function neighbours(i, f)
    local n = CFG.SIZE
    local r, c = (i - 1) // n, (i - 1) % n
    for dr = -1, 1 do
        for dc = -1, 1 do
            local rr, cc = r + dr, c + dc
            if (dr ~= 0 or dc ~= 0) and rr >= 0 and rr < n and cc >= 0 and cc < n then f(rr * n + cc + 1) end
        end
    end
end

-- Charges are laid on the first reveal, never under it or next to it (so the first click always opens an area).
local function lay(first)
    local n, safe, pool = CFG.SIZE * CFG.SIZE, { [first] = true }, {}
    neighbours(first, function(j) safe[j] = true end)
    for i = 1, n do if not safe[i] then pool[#pool + 1] = i end end
    for _ = 1, CFG.MINES do
        local k = math.random(#pool)
        board.charge[pool[k]] = true
        table.remove(pool, k)
    end
    for i = 1, n do
        local c = 0
        neighbours(i, function(j) if board.charge[j] then c = c + 1 end end)
        board.count[i] = c
    end
end

local function paint(i)
    local cell = board.cells[i]
    local label, col = "", HIDDEN
    if board.open[i] then
        col = board.charge[i] and BOOM or OPEN
        label = board.charge[i] and "X" or (board.count[i] > 0 and tostring(board.count[i]) or "")
    elseif board.flag[i] then
        col, label = FLAGGED, "!"
    end
    cell.text:SetText(FText(label))
    pcall(function() cell.b:SetBackgroundColor(col) end)
end

local function reveal(i)
    if board.open[i] or board.flag[i] then return end
    board.open[i] = true
    board.opened = board.opened + (board.charge[i] and 0 or 1)
    paint(i)
    if board.charge[i] then return end
    if board.count[i] == 0 then neighbours(i, reveal) end
end

local function close(pc)
    if not board then return end
    pcall(function() board.host:RemoveFromParent() end)
    board = nil
    if X.valid(pc) then pcall(X.menuClosed, pc) end
end

local function finish(pc, won, why)
    local mine = board.mine
    close(pc)
    if not X.valid(mine) then return end
    if won then
        mine.Active = false
        pcall(function() mine:Stop_LightEffect() end)
        pcall(function() mine.PointLight:SetIntensity(0) end)
        pcall(function() mine.ParticleSystem:Deactivate() end)
        local given = giveLoot(pc)
        pcall(function() mine:K2_DestroyActor() end)
        X.log(("defuse: mine defused, loot %s"):format(#given > 0 and table.concat(given, ", ") or "none (pockets full)"))
        say(pc, #given > 0 and "Defused. The parts are in your pockets" or "Defused. No room in your pockets for the parts")
    else
        X.log("defuse: failed (" .. why .. "), the mine goes off")
        pcall(function() mine:MultiExpo() end)
    end
end

local function open(pc, mine)
    local h = host(pc)
    if not h then return X.log("defuse: no host widget") end
    local tree, root = h.WidgetTree, h.WidgetTree.RootWidget
    local n = CFG.SIZE
    local side = n * CELL + (n - 1) * GAP
    local W, H = side + 40, side + 170
    local sw, sh, scale = screen(pc)
    local x0, y0 = math.max(20, (sw - W) / 2), math.max(20, (sh - H) / 2)
    local bg = make(tree, "Border")
    bg:SetBrushColor({ R = 0.03, G = 0.03, B = 0.04, A = 0.94 })
    place(root, bg, x0, y0, W, H)
    place(root, text(tree, "Defuse the mine", 18), x0 + 20, y0 + 10, W - 40, 28)
    local status = text(tree, "", 13)
    place(root, status, x0 + 20, y0 + 40, W - 40, 22)
    board = { host = h, mine = mine, cells = {}, open = {}, flag = {}, charge = {}, count = {}, opened = 0,
              laid = false, flagMode = false, started = os.clock(), status = status }
    for i = 1, n * n do
        local r, c = (i - 1) // n, (i - 1) % n
        local b = make(tree, "Button")
        local t = text(tree, "", 16)
        b:AddChild(t)
        place(root, b, x0 + 20 + c * (CELL + GAP), y0 + 70 + r * (CELL + GAP), CELL, CELL)
        board.cells[i] = { b = b, text = t }
        paint(i)
    end
    local by = y0 + 70 + side + 14
    local flag = make(tree, "Button")
    local flagText = text(tree, "Flag mode: off", 13)
    flag:AddChild(flagText)
    place(root, flag, x0 + 20, by, (side - 10) / 2, 32)
    local back = make(tree, "Button")
    back:AddChild(text(tree, "Back away", 13))
    place(root, back, x0 + 20 + (side + 10) / 2, by, (side - 10) / 2, 32)
    local help = text(tree, ("%d charges. Clear every safe cell; a number counts the charges around it."):format(CFG.MINES), 11)
    pcall(function() help:SetAutoWrapText(true) end)
    place(root, help, x0 + 20, by + 40, W - 40, 40)
    board.flag_b, board.flagText, board.back = { b = flag }, flagText, { b = back }
    h:AddToViewport(5020)
    pc.bShowMouseCursor = true
    lib("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, h, 0)
    say(pc, nil)
    board.x0, board.y0, board.scale = x0, y0, scale
    X.log(("defuse: board opened at %.0f,%.0f (viewport scale %.2f)"):format(x0, y0, scale))
end

local function pressed(b)
    local down = b.b:IsPressed()
    local click = b.down and not down -- on release, like a real button
    b.down = down
    return click
end

local function tick(pc)
    if not X.valid(board.host) or not onFoot(pc) then board = nil return end
    if not X.valid(board.mine) or board.mine.Active ~= true then return close(pc) end
    local left = CFG.TIME - (os.clock() - board.started)
    if left <= 0 then return finish(pc, false, "out of time") end
    board.status:SetText(FText(("Time %d s   Cleared %d of %d"):format(math.ceil(left), board.opened,
        CFG.SIZE * CFG.SIZE - CFG.MINES)))
    if pressed(board.back) then
        X.log("defuse: backed away")
        return close(pc)
    end
    if pressed(board.flag_b) then
        board.flagMode = not board.flagMode
        board.flagText:SetText(FText("Flag mode: " .. (board.flagMode and "ON" or "off")))
    end
    for i, cell in ipairs(board.cells) do
        if pressed(cell) and not board.open[i] then
            if board.flagMode then
                board.flag[i] = not board.flag[i] or nil
                paint(i)
            elseif not board.flag[i] then
                if not board.laid then lay(i) board.laid = true end
                reveal(i)
                if board.charge[i] then return finish(pc, false, "hit a charge") end
                if board.opened >= CFG.SIZE * CFG.SIZE - CFG.MINES then return finish(pc, true) end
            end
        end
    end
end

-- Every frame in a raid (main.lua).
function M.update(pc)
    if board then return tick(pc) end
    local pawn = onFoot(pc)
    if not pawn then near = nil return say(pc, nil) end
    local now = os.clock()
    if now >= scanAt then
        scanAt = now + CFG.SCAN_EVERY
        mines = {}
        for _, m in ipairs(FindAllOf("MineStaticActor_C") or {}) do
            if X.valid(m) then mines[#mines + 1] = m end
        end
    end
    near = nil
    if #mines == 0 then return say(pc, nil) end
    local at, best = pawn:K2_GetActorLocation(), CFG.REACH
    for _, m in ipairs(mines) do
        if X.valid(m) and m.Active == true then
            local l = m:K2_GetActorLocation()
            local d = math.sqrt((l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2)
            if d < best and math.abs(l.Z - at.Z) < 200 then best, near = d, m end
        end
    end
    if not near then return say(pc, nil) end
    say(pc, carried().tool and "F   Defuse the mine" or "A mine. You need a ToolKit to defuse it")
end

-- F (main.lua's key bind, on the game thread): opens the board by an armed mine.
function M.key()
    if board or not X.valid(near) or near.Active ~= true then return end
    local pc = FindFirstOf("MainPlayerController_C")
    if not onFoot(pc) then return end
    if not carried().tool then return X.log("defuse: no ToolKit") end
    open(pc, near)
end

function M.isOpen() return board ~= nil end
-- Tests (bridge/dir_eval.lua): the open board (charges, counts, where it is), and the mine you're next to.
function M.peek() return board, near end

-- A new world: its mines and widgets are gone.
function M.reset()
    mines, scanAt, near, hint, board = {}, 0, nil, nil, nil
end

return M
