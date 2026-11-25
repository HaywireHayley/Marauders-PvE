-- Raid summary (#390, first pass): after a raid, a small panel in the lobby with how it went: extracted or died, the
-- map and time, your kills by kind (the game's own kill list, PlayerState.InMatchStats K_* entries, after killstats.lua
-- has moved rival kills to K_Human), the crew that came and who of them died, and how many contract/chapter events the
-- mod fired (missions.lua's version counter). One "raid summary: ..." line goes to the log too.
--
-- The tally lives in this module's own state: the director's Lua state survives map travel (hire.lua's D.raid and
-- main.lua's tick table rely on the same), only the world's objects go. M.frame (each raid frame) keeps it current,
-- M.finish (the first lobby frame after a raid) closes it, and M.lobby (each lobby frame)
-- shows it once for SHOW_SECONDS or until Esc. Nothing world-owned is kept past a world change: M.reset drops the panel.
-- Loot brought out is not counted yet. NOT tested in game (2026-11-25).
local M = {}
local log, valid, lib
local raid = {}

local CFG = { SHOW_SECONDS = 12, READ_SECONDS = 2, LOBBY_DELAY = 3 }
M.CFG = CFG
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local INK = { R = 0.02, G = 0.022, B = 0.028, A = 0.9 }
local ACCENT = { R = 0.95, G = 0.5, B = 0.12, A = 1 }
local TEXT_LIGHT = { R = 0.92, G = 0.92, B = 0.9, A = 1 }
local TEXT_MUTED = { R = 0.6, G = 0.62, B = 0.65, A = 1 }
local KINDS = { K_Human = "Marauders", K_AISAS = "SAS", K_AICommando = "Commandos", K_AIRaider = "Raiders" }

local T          -- this raid's tally, nil outside a raid
local ready      -- the closed tally, waiting for the lobby: { lines, shownAt }
local panel      -- { host, untilAt }

function M.init(ctx) log, valid, lib = ctx.log, ctx.valid, ctx.lib end
function M.setRaid(r) raid = r or {} end
local function on() return require("features").RAID_SUMMARY == 1 end

-- New world: the panel's widgets belonged to the old one; dropped, never touched again.
function M.reset() panel = nil end

local function readKills(pc)
    local ps = pc.PlayerState
    if not (ps and valid(ps)) then return end
    local arr = ps.InMatchStats
    if not arr then return end
    local k = {}
    for i = 1, #arr do
        local el = arr[i]
        local name = el.StatName
        if type(name) ~= "string" then
            local ok, s = pcall(function() return name:ToString() end)
            name = ok and s or ""
        end
        local n = el.StatAmmount or 0
        if name:sub(1, 2) == "K_" and n > 0 then k[name] = (k[name] or 0) + n end
    end
    T.kills = k
end

-- Each raid frame, with this raid's player controller.
function M.frame(pc)
    if not on() then return end
    local now = os.clock()
    if not T then
        local map = tostring(raid.world or ""):match("/Maps/([%w_]+)") or "?"
        T = { startedAt = now, map = map, kills = {}, crew = {}, crewDied = {}, events = 0, readAt = 0 }
        pcall(function()
            for _, r in ipairs(require("hire").raidCrew()) do T.crew[#T.crew + 1] = r.name end
        end)
    end
    if raid.extractedAt then T.extracted = true end
    local mv = 0
    pcall(function() mv = require("missions").version() end)
    if mv > T.events then T.events = mv end
    local p = pc.Pawn
    if p and valid(p) then
        local ok, n = pcall(function() return p:GetClass():GetFName():ToString() end)
        if ok and n == "PlayerPawn_C" and (p.Health or 1) <= 0 then T.died = true end
    end
    if now < T.readAt then return end
    T.readAt = now + CFG.READ_SECONDS
    pcall(readKills, pc)
end

-- hire.lua: a crewmate of this raid died.
function M.noteCrewDied(name) if T then T.crewDied[#T.crewDied + 1] = name end end

-- Back in the lobby (M.lobby's first frame there): close the last raid's tally.
function M.finish()
    if not T then return end
    local t = T
    T = nil
    if t.died and not t.extracted then t.outcome = "Died" elseif t.extracted then t.outcome = "Extracted" else t.outcome = "Left" end
    local secs = math.floor(os.clock() - t.startedAt)
    local total, parts = 0, {}
    for k, n in pairs(t.kills) do
        total = total + n
        parts[#parts + 1] = ("%s %d"):format(KINDS[k] or k:gsub("^K_AI", ""):gsub("^K_", ""), n)
    end
    table.sort(parts)
    local back = {}
    local dead = {}
    for _, n in ipairs(t.crewDied) do dead[n] = true end
    for _, n in ipairs(t.crew) do if not dead[n] then back[#back + 1] = n end end
    local head = ("%s - %s, %d:%02d"):format(t.outcome, t.map, math.floor(secs / 60), secs % 60)
    local kills = ("Kills: %d%s"):format(total, #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
    local crew = #t.crew == 0 and "Crew: none hired"
        or ("Crew: %d came, %d back%s"):format(#t.crew, #back,
            #t.crewDied > 0 and ("; lost " .. table.concat(t.crewDied, ", ")) or "")
    local prog = ("Contract/chapter events: %d"):format(t.events)
    log(("raid summary: %s; %s; %s; %s"):format(head, kills, crew, prog))
    ready = { lines = {
        { text = "Raid summary: " .. head, size = 18, col = ACCENT },
        { text = kills }, { text = crew }, { text = prog, col = TEXT_MUTED },
        { text = "Esc to close", col = TEXT_MUTED, size = 11 },
    } }
end

-- UMG as deathscreen.lua builds it.
local function make(tree, cls) return StaticConstructObject(lib("/Script/UMG." .. cls), tree) end
local function tint(t, col)
    pcall(function()
        local c = t.ColorAndOpacity
        c.SpecifiedColor.R, c.SpecifiedColor.G, c.SpecifiedColor.B, c.SpecifiedColor.A = col.R, col.G, col.B, col.A
        c.ColorUseRule = 0
    end)
end

local function show(pc, lines)
    local cls = lib(HOST)
    if not valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = lib(HOST) end
    if not valid(cls) then return end
    local h = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(h) then return end
    local tree = h.WidgetTree
    local root = tree.RootWidget
    if not (root and valid(root)) then return end
    root:ClearChildren()
    local W, ROW, vw = 640, 26, 1600
    pcall(function()
        local wll = lib("/Script/UMG.Default__WidgetLayoutLibrary")
        local vp, sc = wll:GetViewportSize(pc), wll:GetViewportScale(pc)
        if sc and sc > 0 then vw = vp.X / sc end
    end)
    local x0, y0 = math.floor((vw - W) / 2), 120
    local bg = make(tree, "Border")
    pcall(function() bg:SetBrushColor(INK) end)
    local s = root:AddChildToCanvas(bg)
    s:SetPosition({ X = x0, Y = y0 }) s:SetSize({ X = W, Y = 24 + ROW * #lines })
    for i, l in ipairs(lines) do
        local t = make(tree, "TextBlock")
        t.Font.Size = l.size or 13
        t:SetText(FText(l.text))
        tint(t, l.col or TEXT_LIGHT)
        local ts = root:AddChildToCanvas(t)
        ts:SetPosition({ X = x0 + 16, Y = y0 + 12 + ROW * (i - 1) }) ts:SetSize({ X = W - 32, Y = ROW })
    end
    h:AddToViewport(5010)
    panel = { host = h, untilAt = os.clock() + CFG.SHOW_SECONDS }
end

local function hide()
    local h = panel and panel.host
    panel = nil
    if h and valid(h) then pcall(function() h:RemoveFromParent() end) end
end

-- Each lobby frame, with the lobby's player controller and how long the lobby has been up.
function M.lobby(pc, age)
    if T then M.finish() end
    if panel then
        local esc = false
        pcall(function() esc = pc:IsInputKeyDown({ KeyName = FName("Escape") }) end)
        if esc or os.clock() > panel.untilAt then hide() end
        return
    end
    if not ready or (age or 0) < CFG.LOBBY_DELAY then return end
    local lines = ready.lines
    ready = nil
    if not on() or not valid(pc) then return end
    local ok, err = pcall(show, pc, lines)
    if not ok then log("raid summary panel failed: " .. tostring(err)) end
end

return M
