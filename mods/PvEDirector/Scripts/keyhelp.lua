-- A key reference (#389, first pass), opened by the F9 menu's "Key list" button. A small panel listing the mod's own keys, built like deathscreen.lua's panel
-- (a DebugInfo_Widget host emptied and refilled with a Border and TextBlocks). The button again hides it; a new world drops it
-- (its widgets belong to the old world: never touched again, never rooted). Keep KEYS in step with main.lua's
-- RegisterKeyBind block and README.md's key list.
-- NOT tested in game (2026-11-24).
local M = {}
local UI = require("ui")
local valid, lib, log -- main.lua's helpers (init)
local host

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
    { "Space", "at a ship's helm: boost" },
    { "F", "by an armed station mine, with a ToolKit: defuse" },
    { "R", "at the helm by a space mine: defuse" },
}

function M.init(ctx) valid, lib, log = ctx.valid, ctx.lib, ctx.log end

-- New world: the old panel's widgets went with it. Dropped, never touched again.
function M.reset() host = nil end


local function show(pc)
    local KEYW = 90
    local lines = { { text = "Marauders PvE keys   (F9 or Esc closes)", col = ACCENT, size = 16 } }
    for _, k in ipairs(M.KEYS) do
        lines[#lines + 1] = { text = k[1], col = ACCENT, w = KEYW }
        lines[#lines + 1] = { text = k[2], x = KEYW, sameRow = true }
    end
    host = UI.card(pc, { x = 40, y = 120, w = 560, row = 24, col = TEXT_LIGHT, z = 5011, lines = lines })
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
