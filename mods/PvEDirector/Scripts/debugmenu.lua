-- Debug menu (F9): the testing commands that used to sit on their own keys (god mode, extract now, spawn a soldier...),
-- as buttons in one panel. Built and polled like the AI tuning menu (tuning.lua): plain widgets in a DebugInfo_Widget,
-- since UMG delegates can't be bound from Lua.
local D = {}
local X -- context from main.lua: log, valid, lib, menuClosed, actions

local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local X0, Y0, W = 40, 40, 460
local TEXT, SMALL = 15, 12
local ROW = 58

local ui -- { host, tree, root, buttons, status }

local function make(cls) return StaticConstructObject(X.lib("/Script/UMG." .. cls), ui.tree) end

local function text(s, size, opacity)
    local t = make("TextBlock")
    t.Font.Size = size or TEXT
    t:SetText(FText(s))
    if opacity then t:SetOpacity(opacity) end
    return t
end

local function place(widget, x, y, w, h)
    local slot = ui.root:AddChildToCanvas(widget)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
    return slot
end

-- One button per action: { id, label (or a function returning it), help, when = function() -> usable now }.
local function label(a) return type(a.label) == "function" and a.label() or a.label end

local function refresh()
    for _, b in ipairs(ui.buttons) do
        local usable = not b.a.when or b.a.when()
        b.b:SetIsEnabled(usable)
        b.text:SetText(FText(label(b.a)))
        b.help:SetText(FText(usable and b.a.help or (b.a.unusable or "Not here")))
    end
end

local function build(pc)
    local cls = X.lib(HOST)
    if not X.valid(cls) then
        pcall(LoadAsset, (HOST:match("^[^.]+")))
        cls = X.lib(HOST)
    end
    if not X.valid(cls) then return X.log("debug menu: no host widget") end
    local host = X.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not X.valid(host) then return X.log("debug menu: couldn't create it") end
    ui = { host = host, tree = host.WidgetTree, root = host.WidgetTree.RootWidget, buttons = {} }
    ui.root:ClearChildren()
    local actions = X.actions
    local H = 60 + #actions * ROW + 56
    local bg = make("Border")
    bg:SetBrushColor({ R = 0.03, G = 0.03, B = 0.04, A = 0.93 })
    place(bg, X0, Y0, W, H)
    place(text("Debug   (F9 closes)", TEXT), X0 + 16, Y0 + 10, W - 32, 26)
    local y = Y0 + 46
    for _, a in ipairs(actions) do
        local b = make("Button")
        local t = text(label(a), SMALL)
        b:AddChild(t)
        place(b, X0 + 16, y, W - 32, 30)
        local help = text(a.help or "", SMALL, 0.65)
        place(help, X0 + 20, y + 32, W - 40, 20)
        ui.buttons[#ui.buttons + 1] = { b = b, text = t, help = help, a = a }
        y = y + ROW
    end
    ui.status = text(" ", SMALL, 0.85)
    place(ui.status, X0 + 16, y + 2, W - 32, 20)
    local close = make("Button")
    close:AddChild(text("Close", SMALL))
    place(close, X0 + 16, y + 22, W - 32, 30)
    ui.close = { b = close }
    host:AddToViewport(5010) -- above the lobby's own pages, like the crew menu
    return true
end

function D.isOpen() return ui ~= nil and ui.open == true and X.valid(ui.host) end

function D.close(pc)
    if not D.isOpen() then return end
    ui.open = false
    ui.host:SetVisibility(1) -- Collapsed
    X.menuClosed(pc)
end

function D.toggle(pc)
    if D.isOpen() then return D.close(pc) end
    if ui and not X.valid(ui.host) then ui = nil end -- the world it was built in is gone
    if not ui and not build(pc) then return end
    ui.open = true
    refresh()
    ui.host:SetVisibility(0) -- Visible
    pc.bShowMouseCursor = true
    X.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, ui.host, 0)
end

local function run(pc, a)
    local ok, said = pcall(a.run, pc)
    ui.status:SetText(FText(ok and (said or (label(a) .. ": done")) or ("Failed: " .. tostring(said))))
    if not ok then X.log("debug menu: " .. a.id .. " failed: " .. tostring(said)) end
    refresh()
    if ok and a.closes then D.close(pc) end
end

-- Testing without the mouse (bridge/debug_cmd holding an action id): runs it as if clicked, menu open or not.
function D.command(pc, id)
    for _, a in ipairs(X.actions) do
        if a.id == id then
            if a.when and not a.when() then return X.log("debug menu: " .. id .. " not usable here") end
            local ok, said = pcall(a.run, pc)
            X.log("debug menu: " .. id .. " -> " .. tostring(ok and (said or "done") or ("failed: " .. tostring(said))))
            if ui then refresh() end
            return
        end
    end
    X.log("debug menu: no action " .. tostring(id))
end

local function pressed(b)
    local down = b.b:IsPressed()
    local click = b.down and not down -- on release, like a real button
    b.down = down
    return click
end

function D.tick(pc)
    if not D.isOpen() then return end
    for _, b in ipairs(ui.buttons) do
        if pressed(b) then return run(pc, b.a) end
    end
    if pressed(ui.close) then D.close(pc) end
end

-- A new world takes the widgets with it.
function D.reset() ui = nil end

function D.init(ctx) X = ctx end

return D
