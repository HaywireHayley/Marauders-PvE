-- Shared pieces for the mod's on-screen panels. Thirteen modules built their panels the same way, each with its own copy:
-- a DebugInfo_Widget (a Blueprint whose root is a canvas) made for the player controller, emptied, then filled with plain
-- UMG widgets placed on the canvas. One copy here, so a fix to that pattern reaches every panel.
--   host(pc)                      -> host, tree, root   a fresh, empty panel (not on screen yet), or nil
--   make(tree, cls)               a UMG widget ("Border", "TextBlock", ...) owned by the panel's tree
--   place(root, widget, x, y, w, h)   on the canvas, in UI units
--   tint(textBlock, col)          its colour ({ R, G, B, A }); before AddToViewport, as the panels always did
--   text(tree, str, size, col)    a TextBlock
--   viewWidth(pc)                 the screen's width in UI units (1600 if it can't be read)
--   card(pc, spec)                a box of text lines, on screen: see below
--   remove(host)                  off screen; safe on nil or a host from an old world
-- Panels belong to the world they were made in: a module drops its host on a new world and never touches it again.
local M = {}
local X -- log, valid, lib

local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
M.HOST = HOST
M.INK = { R = 0.02, G = 0.022, B = 0.028, A = 0.9 }

function M.init(ctx) X = ctx end

function M.host(pc)
    if not X.valid(pc) then return nil end
    local cls = X.lib(HOST)
    if not X.valid(cls) then
        pcall(LoadAsset, (HOST:match("^[^.]+")))
        cls = X.lib(HOST)
    end
    if not X.valid(cls) then return nil end
    local h = X.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not X.valid(h) then return nil end
    local tree = h.WidgetTree
    local root = tree and tree.RootWidget
    if not (root and X.valid(root)) then return nil end
    root:ClearChildren()
    return h, tree, root
end

function M.make(tree, cls) return StaticConstructObject(X.lib("/Script/UMG." .. cls), tree) end

function M.place(root, widget, x, y, w, h)
    local s = root:AddChildToCanvas(widget)
    s:SetPosition({ X = x, Y = y })
    s:SetSize({ X = w, Y = h })
    return s
end

function M.tint(t, col)
    pcall(function()
        local c = t.ColorAndOpacity
        c.SpecifiedColor.R, c.SpecifiedColor.G, c.SpecifiedColor.B, c.SpecifiedColor.A = col.R, col.G, col.B, col.A or 1
        c.ColorUseRule = 0
    end)
end

function M.text(tree, str, size, col)
    local t = M.make(tree, "TextBlock")
    t.Font.Size = size or 13 -- (read when the widget is built: SetFont can't take the struct back from Lua)
    t:SetText(FText(str))
    if col then M.tint(t, col) end
    return t
end

function M.viewWidth(pc)
    local vw = 1600
    pcall(function()
        local wll = X.lib("/Script/UMG.Default__WidgetLayoutLibrary")
        local vp, sc = wll:GetViewportSize(pc), wll:GetViewportScale(pc)
        if sc and sc > 0 then vw = vp.X / sc end
    end)
    return vw
end

-- A box of text lines on screen. spec: { x (nil: centred), y, w, row (line height), pad (12), bg (INK), z (5010),
-- col (default text colour), lines = { { text, size, col, x (offset in the box), w } , ... } }. Returns the host.
function M.card(pc, spec)
    local h, tree, root = M.host(pc)
    if not h then return nil end
    local W, ROW, pad = spec.w or 560, spec.row or 24, spec.pad or 12
    local x0 = spec.x or math.floor((M.viewWidth(pc) - W) / 2)
    local y0 = spec.y or 120
    local rows = 0
    for _, l in ipairs(spec.lines) do if not l.sameRow then rows = rows + 1 end end
    local bg = M.make(tree, "Border")
    pcall(function() bg:SetBrushColor(spec.bg or M.INK) end)
    M.place(root, bg, x0, y0, W, 2 * pad + ROW * rows)
    local i = 0
    for _, l in ipairs(spec.lines) do
        if not l.sameRow then i = i + 1 end
        local t = M.text(tree, l.text, l.size or spec.size or 13, l.col or spec.col)
        local lx = l.x or 0
        M.place(root, t, x0 + pad + 4 + lx, y0 + pad + ROW * (i - 1), l.w or (W - 2 * (pad + 4) - lx), ROW)
    end
    h:AddToViewport(spec.z or 5010)
    return h
end

function M.remove(h)
    if h and X.valid(h) then pcall(function() h:RemoveFromParent() end) end
end

return M
