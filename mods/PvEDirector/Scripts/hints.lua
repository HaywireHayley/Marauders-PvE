-- First-use hints (#389, the second half after keyhelp.lua's key list): a short line on screen the first time a player
-- reaches a few moments, each once per save. Seen ids live in <backend>/saves/<active save id>/hints_seen.txt (one id a
-- line, like rivalcrews.lua's baron_streak.txt), or hints_seen.txt next to the backend without a launcher save.
-- The panel is keyhelp.lua's pattern (a DebugInfo_Widget host refilled with a Border and a TextBlock), shown SHOW_SECONDS;
-- a new world drops it (its widgets belong to the old world: never touched again, never rooted). Switch: features.HINTS.
-- NOT tested in game (2026-11-25).
local M = {}
local valid, lib, log -- main.lua's helpers (init)
local host, hideAt, seen, seenPath
local queue = {}

local SHOW_SECONDS = 8
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local INK = { R = 0.02, G = 0.022, B = 0.028, A = 0.85 }
local ACCENT = { R = 0.95, G = 0.5, B = 0.12, A = 1 }

M.TEXT = {
    lobby = "F9 debug and key list, F10 PvE settings, F11 crew",
    raid = "N minimap, M overview, B next task",
    helm = "Hold Shift (Run) at the Rustbucket's helm: boost",
    mine = "F with a ToolKit defuses",
    crew = "Your crew follows you; F11 manages them",
}

function M.init(ctx) valid, lib, log = ctx.valid, ctx.lib, ctx.log end

local function path()
    local dir = require("pvebackend")
    local ok, id = pcall(function()
        local f = io.open(dir .. "active_save.txt", "r")
        if not f then return nil end
        local t = f:read("*l"); f:close()
        t = (t or ""):gsub("^%s+", ""):gsub("%s+$", "")
        return t:match("^[%w_%-%.]+$") and t ~= "." and t ~= ".." and t or nil
    end)
    if ok and id then
        local sdir = dir .. "saves/" .. id .. "/"
        local f = io.open(sdir .. "meta.json", "r")
        if f then f:close() return sdir .. "hints_seen.txt" end
    end
    return dir .. "hints_seen.txt"
end

-- Read once per world (the launcher can switch saves between sessions, never inside a world).
local function load()
    if seen then return end
    seen, seenPath = {}, path()
    local f = io.open(seenPath, "r")
    if not f then return end
    for line in f:lines() do
        local id = line:match("^%s*([%w_]+)")
        if id then seen[id] = true end
    end
    f:close()
end

local function mark(id)
    seen[id] = true
    local f = io.open(seenPath, "a")
    if f then f:write(id, "\n") f:close() end
end

local function hide()
    local h = host
    host = nil
    if h and valid(h) then pcall(function() h:RemoveFromParent() end) end
end

local function make(tree, cls) return StaticConstructObject(lib("/Script/UMG." .. cls), tree) end

local function show(pc, str)
    local cls = lib(HOST)
    if not valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = lib(HOST) end
    if not valid(cls) then return false end
    local h = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(h) then return false end
    local tree = h.WidgetTree
    local root = tree.RootWidget
    if not valid(root) then return false end
    root:ClearChildren()
    local W, H, x0, y0 = 520, 36, 40, 80
    local bg = make(tree, "Border")
    pcall(function() bg:SetBrushColor(INK) end)
    local s = root:AddChildToCanvas(bg)
    s:SetPosition({ X = x0, Y = y0 }) s:SetSize({ X = W, Y = H })
    local t = make(tree, "TextBlock")
    t.Font.Size = 15
    t:SetText(FText("Tip: " .. str))
    pcall(function()
        local c = t.ColorAndOpacity
        c.SpecifiedColor.R, c.SpecifiedColor.G, c.SpecifiedColor.B, c.SpecifiedColor.A = ACCENT.R, ACCENT.G, ACCENT.B, 1
        c.ColorUseRule = 0
    end)
    local ts = root:AddChildToCanvas(t)
    ts:SetPosition({ X = x0 + 14, Y = y0 + 7 }) ts:SetSize({ X = W - 28, Y = H - 10 })
    h:AddToViewport(5010)
    host = h
    return true
end

-- New world: the panel's widgets went with it. Dropped, never touched again; the queue starts over.
function M.reset()
    host, hideAt, seen = nil, nil, nil
    queue = {}
end

local function want(id)
    if seen[id] then return end
    for _, q in ipairs(queue) do if q == id then return end end
    queue[#queue + 1] = id
end

-- From main.lua's update. lobby: the main menu; raid: a raid or space map; space: a space map.
function M.update(pc, lobby, raid, space)
    if require("features").HINTS ~= 1 then
        if host then hide() end
        return
    end
    if not valid(pc) then return end
    load()
    if lobby then want("lobby") end
    if raid and not space and valid(pc.Pawn) then want("raid") end
    if space and require("shipspeed").atHelm then want("helm") end
    if raid and not space and require("defuse").nearStation() then want("mine") end
    local okC, n = pcall(function() return require("hire").crewCount() end)
    if okC and (n or 0) > 0 then want("crew") end
    local now = os.clock()
    if host then
        if now < hideAt then return end
        hide()
    end
    local id = table.remove(queue, 1)
    if not id then return end
    local ok, shown = pcall(show, pc, M.TEXT[id])
    if ok and shown then
        hideAt = now + SHOW_SECONDS
        mark(id)
        log("hint shown: " .. id)
    else
        seen[id] = true -- not again this world (no log spam); the file isn't marked, so it's tried next world
        if not ok then log("hint failed: " .. tostring(shown)) end
    end
end

return M
