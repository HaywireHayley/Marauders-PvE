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
-- Space mines (#197, the second part): the small mines out in space (Small_NodeMine_C, a SubNodeActorMine_C) go off
-- when a ship touches their trigger box (80 cm) or the blast of another one reaches them: radial damage 500 within
-- 4 m, falling off to 15 m. At the helm, with your ship within SPACE_REACH of one and a ToolKit on you, R (the ship's
-- salvage key) opens the same board. Clear it and the mine goes quiet (Active? false, lights off) and comes apart: its
-- fuse and powder go into your pockets. Lose and it goes off through its own explosion (ExecuteUbergraph entry 15:
-- radial damage, mesh hidden, destroyed; spacefx.lua adds the blast and sound), its reach stretched to your ship.
-- Nuclear mines (#197, the third part): Nuclear_NodeMine_C, the same SubNodeActorMine_C with Base Damage 1000 within
-- 10 m, falling off to 25 m. Defused in place from the helm like a small one (towing one home to the hold is still to
-- come), on a bigger board with more charges and more time. Win: a fuse and high-grade powder into your pocket, and the
-- nuclear material (3 x 3, too big for a pocket) sent to your gift box through the stand-in (gifts_in.txt), to claim in
-- the lobby. Lose: its blast, stretched to your ship like a small one's: 1000 hull damage, more than a starter frigate has.
-- Nuclear mines in the hold (#197, the last part, as the issue first described it): at the helm, R by a nuclear mine
-- takes it aboard instead (no ToolKit needed to tow it): it goes quiet (Active? false, its light still pulsing), shrunk
-- to fit, and is set down at your hold's salvage spot. On foot beside it, F with a ToolKit opens the nuclear board.
-- Win: the loot above. Lose: it goes off in the hold, the blast reaching everyone aboard, and your ship is wrecked:
-- "instant ship and marauder death". One at a time.
local M = {}
local X -- log, valid, lib, menuClosed
local Pockets = require("pockets")

local CFG = {
    BOARDS = {                       -- board side, hidden charges, seconds, per kind of mine
        station = { size = 6, mines = 6, time = 75 },
        small = { size = 6, mines = 6, time = 75 },
        nuclear = { size = 8, mines = 12, time = 120 },
    },
    REACH = 170,                     -- cm from your feet to a mine you can work on (its trigger sphere is 30 cm)
    SCAN_EVERY = 20,                 -- s between the first looks for mines (a FindAllOf, ~70 ms: a visible hitch)...
    SCAN_LATER = 90,                 -- ...and between later ones (mines are placed at map start; this only drops gone ones)
    SCAN_GIVE_UP = 3,                -- no mines after this many looks: none on this map, stop looking (per kind)
    TOOL = "ToolKit",                -- the item row you need on you
    LOOT = { { "AP_Mine", 1 }, { "Gunpowder", 2 } }, -- what a defused mine leaves (row, stack)
    SPACE_CLASS = "Small_NodeMine_C",
    NUCLEAR_CLASS = "Nuclear_NodeMine_C",
    NUCLEAR_LOOT = { { "Fuse", 1 }, { "HiGunpowder", 3 } },
    NUCLEAR_GIFT = "NuclearMaterial", -- into the gift box (3 x 3: no pocket holds it)
    SPACE_REACH = 3000,              -- cm from your ship to a space mine you can work on from the helm
    SPACE_SCAN_EVERY = 60,           -- s between looks for space mines while you fly (they don't move)
    SPACE_LOOT = { { "Fuse", 1 }, { "Gunpowder", 3 }, { "Chemicals", 1 } },
    SPACE_BLAST_REACH = 500,         -- cm past your ship that a space mine's blast reaches when defusing fails
    HOLD_SCALE = 0.35,               -- a nuclear mine taken aboard is shrunk to this (it's ~4 m across out in space)
    HOLD_REACH = 350,                -- cm from your feet to the mine in the hold you can work on
    HOLD_BLAST = 3000,               -- cm its blast reaches inside your ship when defusing it fails
    SPARES = 1,                      -- charges you can hit and still pull the fuse in time; the next one sets it off
}
M.CFG = CFG
local NOT_CARRIED = { Stash = true, Lobby = true, Shop = true, LootCon = true, Gift = true, scrap = true }
local CELL, GAP = 46, 4
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
-- The look: the launcher's ink and orange, raised steel cells, cleared cells sunk dark, classic number colours.
local INK = { R = 0.02, G = 0.022, B = 0.028, A = 0.96 }
local ACCENT = { R = 0.95, G = 0.5, B = 0.12, A = 1 }
local HIDDEN = { R = 0.42, G = 0.45, B = 0.48, A = 1 }
local OPEN = { R = 0.05, G = 0.055, B = 0.065, A = 1 }
local FLAGGED = { R = 0.95, G = 0.5, B = 0.12, A = 1 }
local BOOM = { R = 0.85, G = 0.12, B = 0.06, A = 1 }
local DEFUSED = { R = 0.35, G = 0.08, B = 0.06, A = 1 } -- a charge you hit and caught (a spare)
local TEXT_LIGHT = { R = 0.92, G = 0.92, B = 0.9, A = 1 }
local TEXT_MUTED = { R = 0.6, G = 0.62, B = 0.65, A = 1 }
local NUMBER = {
    { R = 0.4, G = 0.68, B = 1, A = 1 }, { R = 0.45, G = 0.85, B = 0.4, A = 1 }, { R = 1, G = 0.42, B = 0.36, A = 1 },
    { R = 0.78, G = 0.55, B = 1, A = 1 }, { R = 1, G = 0.68, B = 0.22, A = 1 }, { R = 0.3, G = 0.88, B = 0.88, A = 1 },
    { R = 0.95, G = 0.95, B = 0.95, A = 1 }, { R = 0.7, G = 0.7, B = 0.7, A = 1 },
}

local mines, scanAt, near, nearKind, scanKind = {}, 0, nil, nil, nil
local scans = {} -- per kind ("station", "space"): { list, at, looks } for this world
local hint   -- { host, text, shown } the prompt line
local board  -- the open board, see open()
local held   -- { mine, inside }: the nuclear mine in your hold

-- Where you have to be for a kind of mine: on foot ("station": station mines, and the one in your hold) or at the helm.
local function where(kind) return kind == "space" and "space" or "station" end

local lib -- main.lua's helpers, from ctx (init)
function M.init(ctx) X = ctx lib = ctx.lib end

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

-- A text block's colour, written into its property: only before the board is added to the screen (the widget reads it
-- when it's built). SetColorAndOpacity can't be used from here: UE4SS passes the FSlateColor table as all zeros, which
-- made the text transparent (2026-11-21). So colours that change later (numbers, flags, the clock) go on the cells'
-- backgrounds and the time bar instead.
local function tint(t, col)
    pcall(function()
        local c = t.ColorAndOpacity
        c.SpecifiedColor.R, c.SpecifiedColor.G, c.SpecifiedColor.B, c.SpecifiedColor.A = col.R, col.G, col.B, col.A
        c.ColorUseRule = 0
    end)
end

local function text(tree, s, size, col, centre)
    local t = make(tree, "TextBlock")
    t.Font.Size = size or 14
    t:SetText(FText(s))
    tint(t, col or TEXT_LIGHT)
    if centre then pcall(function() t:SetJustification(1) end) end
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

-- Your ship, while you're at its helm (the controller's pawn is then the ship, and it has your interior).
local function piloting(pc)
    local p = X.valid(pc) and pc.Pawn
    if not (p and X.valid(p)) or onFoot(pc) then return nil end
    local ok, inside = pcall(function() return p.MyShipInside end)
    return ok and inside and X.valid(inside) and p or nil
end

-- Where you are for a defuse: "station" (on foot) or "space" (at the helm), and the pawn that counts.
local function context(pc)
    local foot = onFoot(pc)
    if foot then return "station", foot end
    local ship = piloting(pc)
    if ship then return "space", ship end
end

local function armed(kind, m)
    if not X.valid(m) then return false end
    if kind == "hold" then return held ~= nil and held.mine == m end
    if kind == "space" then return m["Active?"] == true end
    return m.Active == true
end

-- What you carry: a ToolKit? (an FName keeps the case it was first made with in the session: the row reads "Toolkit"
-- in some sessions, "ToolKit" in others), and which cells are taken (pockets.lua: every cell an item covers).
local function carried()
    local out = { tool = false }
    out.cells = Pockets.cells(FindFirstOf("SIGISInventoryComponent"), function(_, con, row)
        if not NOT_CARRIED[con] and row:lower() == CFG.TOOL:lower() then out.tool = true end
    end)
    return out
end

-- Into free pocket space, the way the F9 ammo button gives (debuggive.lua). Nothing goes on top of another item.
local function giveLoot(pc, loot)
    local cells, given = carried().cells, {}
    for _, l in ipairs(loot) do
        local pocket, col, line, rot = Pockets.find(cells, l[1])
        if pocket then
            Pockets.claim(cells, pocket, l[1], col, line, rot)
            pc:Server_AwsN_EquippedItemsReturned(('[{"value":{"equip":true,"value":"%s-%s-%d-100-%d-%d-%d-%s"}}]')
                :format(tostring(math.random(10000000, 99999999)), l[1], l[2], col, line, rot and 1 or 0, pocket))
            given[#given + 1] = l[1]
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
    local n = board.n
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
    local n, safe, pool = board.n * board.n, { [first] = true }, {}
    neighbours(first, function(j) safe[j] = true end)
    for i = 1, n do if not safe[i] then pool[#pool + 1] = i end end
    for _ = 1, board.mines do
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

-- A cleared cell with a number takes that number's classic colour, dimmed, behind a white digit.
local function shade(c, k)
    return { R = OPEN.R + (c.R - OPEN.R) * k, G = OPEN.G + (c.G - OPEN.G) * k, B = OPEN.B + (c.B - OPEN.B) * k, A = 1 }
end

local function paint(i)
    local cell = board.cells[i]
    local label, col = "", HIDDEN
    if board.open[i] then
        if board.charge[i] then
            col, label = board.caught and board.caught[i] and DEFUSED or BOOM, "*"
        else
            local n = board.count[i]
            col, label = n > 0 and shade(NUMBER[n] or TEXT_LIGHT, 0.45) or OPEN, n > 0 and tostring(n) or ""
        end
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

-- A row into the gift box (claimed in the lobby's GIFTS): the stand-in picks gifts_in.txt up within a second.
local function sendGift(row)
    local ok = pcall(function()
        local f = assert(io.open(require("pvebackend") .. "gifts_in.txt", "a"))
        f:write(row, "\n")
        f:close()
    end)
    return ok
end

-- A space mine goes off on its own: radial damage from its place, reaching your ship, then its mesh hides and it's
-- destroyed (spacefx.lua makes the blast and sound for a hidden mine).
local function spaceBlast(mine, ship)
    if X.valid(ship) then
        local a, b = mine:K2_GetActorLocation(), ship:K2_GetActorLocation()
        local d = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
        mine["Damage Radius_Maximum"] = math.max(mine["Damage Radius_Maximum"] or 0, d + CFG.SPACE_BLAST_REACH)
        -- full damage at your ship: with only the outer radius stretched, a nuclear mine 20 m off did nothing (its
        -- falloff past the 10 m inner radius came out at 0), while a small one did its full 500
        mine["Damage Radius_Inner"] = math.max(mine["Damage Radius_Inner"] or 0, d + CFG.SPACE_BLAST_REACH)
    end
    mine:ExecuteUbergraph_SubNodeActorMine(15)
end

-- The mine in your hold goes off: its own blast, reaching everyone aboard, and your ship wrecked with it.
local function holdBlast(mine, pc, ship)
    mine["Damage Radius_Maximum"] = CFG.HOLD_BLAST
    mine["Damage Radius_Inner"] = CFG.HOLD_BLAST
    mine:ExecuteUbergraph_SubNodeActorMine(15)
    local gs = lib("/Script/Engine.Default__GameplayStatics")
    local dt = lib("/Script/Engine.DamageType")
    local foot = onFoot(pc)
    if foot then pcall(function() gs:ApplyDamage(foot, 100000, nil, nil, dt) end) end
    if X.valid(ship) then pcall(function() gs:ApplyDamage(ship, 100000, nil, nil, dt) end) end
end

local function finish(pc, won, why)
    local mine, kind, nuclear = board.mine, board.kind, board.nuclear
    if not X.valid(mine) then return close(pc) end
    if won then
        local given, gift
        if kind == "hold" then
            held = nil
            given = giveLoot(pc, CFG.NUCLEAR_LOOT)
            gift = sendGift(CFG.NUCLEAR_GIFT)
        elseif kind == "space" then
            mine["Active?"] = false
            pcall(function() mine.PulsingLight:Stop() end)
            pcall(function() mine.MineRotation:Stop() end)
            pcall(function() mine.PL_Top:SetIntensity(0) end)
            pcall(function() mine.PL_Bot:SetIntensity(0) end)
            given = giveLoot(pc, board.nuclear and CFG.NUCLEAR_LOOT or CFG.SPACE_LOOT)
            if board.nuclear then gift = sendGift(CFG.NUCLEAR_GIFT) end
        else
            mine.Active = false
            pcall(function() mine:Stop_LightEffect() end)
            pcall(function() mine.PointLight:SetIntensity(0) end)
            pcall(function() mine.ParticleSystem:Deactivate() end)
            given = giveLoot(pc, CFG.LOOT)
        end
        close(pc)
        pcall(function() mine:K2_DestroyActor() end) -- (its mesh is still shown, so spacefx makes no blast)
        X.log(("defuse: %s%s mine defused, loot %s%s"):format(nuclear and "nuclear " or "", kind,
            #given > 0 and table.concat(given, ", ") or "none (pockets full)", gift and (", " .. CFG.NUCLEAR_GIFT .. " to the gift box") or ""))
        say(pc, (#given > 0 and "Defused. The parts are in your pockets" or "Defused. No room in your pockets for the parts")
            .. (gift and ". The nuclear material is in your gift box" or ""))
    else
        close(pc)
        X.log(("defuse: %s%s mine, failed (%s), it goes off"):format(nuclear and "nuclear " or "", kind, why))
        if kind == "hold" then
            local ship = held and X.valid(held.inside) and held.inside.SpaceshipToPairTo or nil
            held = nil
            pcall(holdBlast, mine, pc, ship)
        elseif kind == "space" then
            pcall(spaceBlast, mine, pc.Pawn)
        else
            pcall(function() mine:MultiExpo() end)
        end
    end
end

local function isNuclear(m)
    local ok, n = pcall(function() return m:GetClass():GetFName():ToString() end)
    return ok and n == CFG.NUCLEAR_CLASS
end

local function open(pc, mine, kind)
    local h = host(pc)
    if not h then return X.log("defuse: no host widget") end
    local tree, root = h.WidgetTree, h.WidgetTree.RootWidget
    local nuclear = (kind == "space" or kind == "hold") and isNuclear(mine)
    local spec = CFG.BOARDS[kind == "station" and "station" or nuclear and "nuclear" or "small"]
    local n = spec.size
    local side = n * CELL + (n - 1) * GAP
    local W, H = side + 48, side + 214
    local sw, sh, scale = screen(pc)
    local x0, y0 = math.max(20, (sw - W) / 2), math.max(20, (sh - H) / 2)
    local gx = x0 + 24
    local bg = make(tree, "Border")
    bg:SetBrushColor(INK)
    place(root, bg, x0, y0, W, H)
    local bar = make(tree, "Border") -- the orange strip along the top, as on the launcher's panels
    bar:SetBrushColor(ACCENT)
    place(root, bar, x0, y0, W, 4)
    place(root, text(tree, nuclear and "DEFUSE THE NUCLEAR MINE" or "DEFUSE THE MINE", 18, ACCENT), gx, y0 + 16, side, 28)
    local sub = text(tree, "", 11, TEXT_MUTED)
    place(root, sub, gx, y0 + 46, side, 18)
    local clock = text(tree, "", 13)
    place(root, clock, gx, y0 + 70, side / 2, 20)
    local status = text(tree, "", 13, TEXT_LIGHT)
    pcall(function() status:SetJustification(2) end)
    place(root, status, gx + side / 2, y0 + 70, side / 2, 20)
    local fuse = make(tree, "ProgressBar")
    pcall(function() fuse:SetPercent(1) end)
    pcall(function() fuse:SetFillColorAndOpacity(ACCENT) end)
    place(root, fuse, gx, y0 + 94, side, 8)
    local top = y0 + 114
    board = { host = h, mine = mine, kind = kind, nuclear = nuclear, n = n, mines = spec.mines, time = spec.time, cells = {}, open = {}, flag = {}, charge = {}, count = {}, opened = 0,
              laid = false, flagMode = false, started = os.clock(), status = status, clock = clock, fuse = fuse,
              spares = CFG.SPARES, caught = {}, sub = sub }
    for i = 1, n * n do
        local r, c = (i - 1) // n, (i - 1) % n
        local b = make(tree, "Button")
        local t = text(tree, "", 18, TEXT_LIGHT, true)
        b:AddChild(t)
        place(root, b, gx + c * (CELL + GAP), top + r * (CELL + GAP), CELL, CELL)
        board.cells[i] = { b = b, text = t }
        paint(i)
    end
    -- The first cell is opened for you, somewhere off the edge, with nothing next to it: it clears an area to start from
    -- (lay keeps the first cell and its neighbours free), so no game starts on a blind guess.
    local first = (n >= 4) and (math.random(1, n - 2) * n + math.random(1, n - 2) + 1) or math.random(n * n)
    lay(first)
    board.laid = true
    reveal(first)
    local by = top + side + 16
    local flag = make(tree, "Button")
    local flagText = text(tree, "FLAG MODE: OFF", 13, TEXT_LIGHT, true)
    flag:AddChild(flagText)
    pcall(function() flag:SetBackgroundColor(HIDDEN) end)
    place(root, flag, gx, by, (side - 10) / 2, 34)
    local back = make(tree, "Button")
    back:AddChild(text(tree, "BACK AWAY", 13, TEXT_LIGHT, true))
    pcall(function() back:SetBackgroundColor(HIDDEN) end)
    place(root, back, gx + (side + 10) / 2, by, (side - 10) / 2, 34)
    local help = text(tree, "A number counts the charges touching it. Flag mode marks a cell you think holds one.", 11, TEXT_MUTED)
    pcall(function() help:SetAutoWrapText(true) end)
    place(root, help, gx, by + 44, side, 36)
    board.flag_b, board.flagText, board.back = { b = flag }, flagText, { b = back }
    h:AddToViewport(5020)
    pc.bShowMouseCursor = true
    lib("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, h, 0)
    say(pc, nil)
    board.x0, board.y0, board.scale = x0, y0, scale
    X.log(("defuse: %s mine, board opened at %.0f,%.0f (viewport scale %.2f)"):format(kind, x0, y0, scale))
end

local function pressed(b)
    local down = b.b:IsPressed()
    local click = b.down and not down -- on release, like a real button
    b.down = down
    return click
end

local function tick(pc)
    if not X.valid(board.host) then board = nil return end
    if context(pc) ~= where(board.kind) then return close(pc) end -- (you left the helm, or fell: the board goes, input comes back)
    if not armed(board.kind, board.mine) then return close(pc) end
    local left = board.time - (os.clock() - board.started)
    if left <= 0 then return finish(pc, false, "out of time") end
    local share = left / board.time
    board.clock:SetText(FText(("TIME  %d s"):format(math.ceil(left))))
    pcall(function() board.fuse:SetPercent(share) end)
    if share < 0.25 and not board.late then
        board.late = true
        pcall(function() board.fuse:SetFillColorAndOpacity(BOOM) end)
    end
    board.status:SetText(FText(("CLEARED  %d / %d"):format(board.opened, board.n * board.n - board.mines)))
    -- (the line under the title: the charges, and whether a slip is still covered)
    board.sub:SetText(FText(("%d charges hidden.   %s"):format(board.mines, board.spares > 0
        and ("Spare: %d (one slip is caught)"):format(board.spares) or "No spare left: the next one blows")))
    if pressed(board.back) then
        X.log("defuse: backed away")
        return close(pc)
    end
    if pressed(board.flag_b) then
        board.flagMode = not board.flagMode
        board.flagText:SetText(FText("FLAG MODE: " .. (board.flagMode and "ON" or "OFF")))
        pcall(function() board.flag_b.b:SetBackgroundColor(board.flagMode and FLAGGED or HIDDEN) end)
    end
    for i, cell in ipairs(board.cells) do
        if pressed(cell) and not board.open[i] then
            if board.flagMode then
                board.flag[i] = not board.flag[i] or nil
                paint(i)
            elseif not board.flag[i] then
                if not board.laid then lay(i) board.laid = true end
                reveal(i)
                if board.charge[i] then
                    if board.spares <= 0 then return finish(pc, false, "hit a charge") end
                    -- caught in time: it stays shown as a dead charge, and the board goes on
                    board.spares = board.spares - 1
                    board.caught[i] = true
                    paint(i)
                    X.log(("defuse: a charge set off and caught (%d spare(s) left)"):format(board.spares))
                end
                if board.opened >= board.n * board.n - board.mines then return finish(pc, true) end
            end
        end
    end
end

-- The hold's salvage spot (where a wreck's salvage is set down), or the interior's middle.
local function holdSpot(inside)
    local at
    pcall(function()
        for _, c in ipairs(inside:K2_GetComponentsByClass(lib("/Script/Engine.SceneComponent")) or {}) do
            local comp = c:get()
            if X.valid(comp) and comp:GetFName():ToString() == "SalvageSpawn" then at = comp:K2_GetComponentLocation() end
        end
    end)
    return at or inside:K2_GetActorLocation()
end

-- R at the helm by a nuclear mine: aboard it goes, quiet and shrunk, into the hold.
local function tow(pc, ship, mine)
    if held and X.valid(held.mine) then return say(pc, "Your hold already has a nuclear mine in it") end
    local inside = ship.MyShipInside
    local at = holdSpot(inside)
    mine["Active?"] = false
    pcall(function() mine.MineRotation:Stop() end)
    pcall(function() mine:SetActorEnableCollision(false) end)
    pcall(function() mine:SetActorScale3D({ X = CFG.HOLD_SCALE, Y = CFG.HOLD_SCALE, Z = CFG.HOLD_SCALE }) end)
    mine:K2_SetActorLocation({ X = at.X, Y = at.Y, Z = at.Z + 60 }, false, {}, true)
    held = { mine = mine, inside = inside }
    near, nearKind = nil, nil
    X.log(("defuse: nuclear mine taken aboard, set down in the hold at %.0f,%.0f,%.0f"):format(at.X, at.Y, at.Z))
    say(pc, "The nuclear mine is in your hold. Defuse it there with a ToolKit")
end

-- Every frame in a raid (main.lua).
function M.update(pc)
    if board then return tick(pc) end
    local kind, pawn = context(pc)
    if not kind then near, nearKind = nil, nil return say(pc, nil) end
    -- on foot by the mine in your hold
    if held and not X.valid(held.mine) then held = nil end
    if held and kind == "station" then
        local a, b = pawn:K2_GetActorLocation(), held.mine:K2_GetActorLocation()
        if math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) < CFG.HOLD_REACH then
            near, nearKind = held.mine, "hold"
            return say(pc, carried().tool and "F   Defuse the nuclear mine"
                or "A nuclear mine. You need a ToolKit to defuse it")
        end
    end
    local now = os.clock()
    -- Each kind keeps its own list, so walking to the helm and back doesn't scan again; a map with none of a kind stops
    -- being scanned for it after SCAN_GIVE_UP looks (every one was a ~70 ms hitch, every 20 s, for everyone: #254).
    local sc = scans[kind]
    if not sc then sc = { list = {}, at = 0, looks = 0 } scans[kind] = sc end
    if now >= sc.at and not (sc.looks >= CFG.SCAN_GIVE_UP and #sc.list == 0) then
        sc.looks = sc.looks + 1
        local first = kind == "space" and CFG.SPACE_SCAN_EVERY or CFG.SCAN_EVERY
        sc.at = now + (sc.looks < CFG.SCAN_GIVE_UP and first or math.max(first, CFG.SCAN_LATER))
        sc.list = {}
        for _, cls in ipairs(kind == "space" and { CFG.SPACE_CLASS, CFG.NUCLEAR_CLASS } or { "MineStaticActor_C" }) do
            for _, m in ipairs(FindAllOf(cls) or {}) do
                if X.valid(m) then sc.list[#sc.list + 1] = m end
            end
        end
        if sc.looks == CFG.SCAN_GIVE_UP and #sc.list == 0 then X.log("defuse: no " .. kind .. " mines on this map") end
    end
    scanKind, mines = kind, sc.list
    near, nearKind = nil, nil
    if #mines == 0 then return say(pc, nil) end
    local at = pawn:K2_GetActorLocation()
    local best = kind == "space" and CFG.SPACE_REACH or CFG.REACH
    for _, m in ipairs(mines) do
        if armed(kind, m) then
            local l = m:K2_GetActorLocation()
            if kind == "space" then
                local d = math.sqrt((l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2)
                if d < best then best, near = d, m end
            else
                local d = math.sqrt((l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2)
                if d < best and math.abs(l.Z - at.Z) < 200 then best, near = d, m end
            end
        end
    end
    if not near then return say(pc, nil) end
    nearKind = kind
    local key = kind == "space" and "R" or "F"
    if kind == "space" and isNuclear(near) then return say(pc, "R   Take the nuclear mine aboard") end
    say(pc, carried().tool and (key .. "   Defuse the mine") or "A mine. You need a ToolKit to defuse it")
end

-- F on foot, R at the helm (main.lua's key binds, on the game thread): opens the board by an armed mine.
function M.key(letter)
    letter = letter or "F"
    if board or not armed(nearKind, near) then return end
    if (nearKind == "space") ~= (letter == "R") then return end
    local pc = FindFirstOf("MainPlayerController_C")
    if context(pc) ~= where(nearKind) then return end
    if nearKind == "space" and isNuclear(near) then return tow(pc, pc.Pawn, near) end
    if not carried().tool then return X.log("defuse: no ToolKit") end
    open(pc, near, nearKind)
end

function M.isOpen() return board ~= nil end
-- Tests (bridge/dir_eval.lua): the open board (charges, counts, where it is), and the mine you're next to.
function M.peek() return board, near, held end
function M.nearStation() return near ~= nil and nearKind == "station" end -- hints.lua (#389)

-- A new world: its mines and widgets are gone.
function M.reset()
    mines, scanAt, near, nearKind, scanKind, hint, board, scans, held = {}, 0, nil, nil, nil, nil, nil, {}, nil
end

return M
