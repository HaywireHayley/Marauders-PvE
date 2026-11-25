-- A key reference (#389, first pass), opened by the F9 menu's "Key list" button. A small panel listing the mod's own keys, built like deathscreen.lua's panel
-- (a DebugInfo_Widget host emptied and refilled with a Border and TextBlocks). The button again hides it; a new world drops it
-- (its widgets belong to the old world: never touched again, never rooted). Keep KEYS in step with main.lua's
-- RegisterKeyBind block and README.md's key list.
-- NOT tested in game (2026-11-24).
local M = {}
local valid, lib, log -- main.lua's helpers (init)
local host

local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local INK = { R = 0.02, G = 0.022, B = 0.028, A = 0.9 }
local ACCENT = { R = 0.95, G = 0.5, B = 0.12, A = 1 }
local TEXT_LIGHT = { R = 0.92, G = 0.92, B = 0.9, A = 1 }

M.KEYS = {
    { "F9", "debug menu: god mode, your body, this key list, unstuck, extract, spawn" },
    { "F10", "AI tuning menu (lobby and raids)" },
    { "F11", "your crew: hire and manage" },
    { "F1-F8", "the game's own voice lines (NPCs hear them)" },
    { "N", "minimap on / off" },
    { "M", "minimap: full overview and back" },
    { "B", "minimap: follow the next task" },
    { "K", "stash: quick-move the item under the mouse" },
    { "J", "stash: discard the item under the mouse (press twice)" },
    { "Shift", "held, at the Rustbucket's helm: boost" },
    { "F", "by an armed station mine, with a ToolKit: defuse" },
    { "R", "at the helm by a space mine: defuse" },
}

function M.init(ctx) valid, lib, log = ctx.valid, ctx.lib, ctx.log end

-- New world: the old panel's widgets went with it. Dropped, never touched again.
function M.reset() host = nil end

local function make(tree, cls) return StaticConstructObject(lib("/Script/UMG." .. cls), tree) end
local function tint(t, col)
    pcall(function()
        local c = t.ColorAndOpacity
        c.SpecifiedColor.R, c.SpecifiedColor.G, c.SpecifiedColor.B, c.SpecifiedColor.A = col.R, col.G, col.B, col.A
        c.ColorUseRule = 0
    end)
end

local function show(pc)
    local cls = lib(HOST)
    if not valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = lib(HOST) end
    if not valid(cls) then return end
    local h = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(h) then return end
    local tree = h.WidgetTree
    local root = tree.RootWidget
    if not valid(root) then return end
    root:ClearChildren()
    local W, ROW, KEYW = 560, 24, 90
    local x0, y0 = 40, 120
    local bg = make(tree, "Border")
    pcall(function() bg:SetBrushColor(INK) end)
    local s = root:AddChildToCanvas(bg)
    s:SetPosition({ X = x0, Y = y0 }) s:SetSize({ X = W, Y = 24 + ROW * (#M.KEYS + 1) })
    local function text(str, x, y, w, col, size)
        local t = make(tree, "TextBlock")
        t.Font.Size = size or 13
        t:SetText(FText(str))
        tint(t, col)
        local ts = root:AddChildToCanvas(t)
        ts:SetPosition({ X = x, Y = y }) ts:SetSize({ X = w, Y = ROW })
    end
    text("Marauders PvE keys   (F9 or Esc closes)", x0 + 16, y0 + 10, W - 32, ACCENT, 16)
    for i, k in ipairs(M.KEYS) do
        local y = y0 + 12 + ROW * i
        text(k[1], x0 + 16, y, KEYW, ACCENT)
        text(k[2], x0 + 16 + KEYW, y, W - 32 - KEYW, TEXT_LIGHT)
    end
    h:AddToViewport(5011)
    host = h
end

function M.isOpen() return host ~= nil end

-- The stock UE4SS ConsoleEnablerMod puts the game console on F10, the mod's AI settings key (F1-F8 being the game's
-- voice lines), so F10 opened both. Every few seconds (it re-applies F10 whenever it makes or remaps the console) the
-- console key is put back on Tilde (`), the engine's usual one.
local consoleAt = 0
function M.consoleKey()
    local now = os.clock()
    if now < consoleAt then return end
    consoleAt = now + 5
    local s = StaticFindObject("/Script/Engine.Default__InputSettings")
    if not (s and valid(s)) then return end
    local keys = s.ConsoleKeys
    if keys[1].KeyName:ToString() == "F10" then
        keys[1].KeyName = FName("Tilde")
        log("console key: F10 -> Tilde (F10 is the AI settings key)")
    end
end

-- F9 and Esc close it (#450: it stayed on screen until a restart, the F9 menu having closed when it opened).
function M.close()
    local h = host
    host = nil
    if h and valid(h) then pcall(function() h:RemoveFromParent() end) end
end

-- The F9 menu's Key list button, with the controller main.lua's menus use (nil when there is none yet).
function M.toggle(pc)
    if host then return M.close() end
    if not valid(pc) then return end
    local ok, err = pcall(show, pc)
    if not ok then log("key list failed: " .. tostring(err)) end
end

return M
