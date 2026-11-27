-- Raid summary (#390, first pass): after a raid, a small panel in the lobby with how it went: extracted or died, the
-- map and time, your kills by kind (the game's own kill list, PlayerState.InMatchStats K_* entries, after killstats.lua
-- has moved rival kills to K_Human), the crew that came and who of them died, and how many contract/chapter events the
-- mod fired (missions.lua's version counter). One "raid summary: ..." line goes to the log too.
--
-- The tally lives in this module's own state: the director's Lua state survives map travel (hire.lua's D.raid and
-- main.lua's tick table rely on the same), only the world's objects go. M.frame (each raid frame) keeps it current,
-- M.finish (the first lobby frame after a raid) closes it, and M.lobby (each lobby frame)
-- shows it once for SHOW_SECONDS or until Esc. Nothing world-owned is kept past a world change: M.reset drops the panel.
-- Loot: one bounded snapshot of your inventory (StashedItems rows, stacks, GUIDs; property reads only) a few seconds
-- in, and one when you extract or die; priced from itemdata.lua. NOT tested in game (2026-11-25).
local M = {}
local UI = require("ui")
local log, valid, lib
local raid = {}

local CFG = { SHOW_SECONDS = 12, READ_SECONDS = 2, LOBBY_DELAY = 3, SNAP_AFTER = 5, SNAP_CAP = 300 }
M.CFG = CFG
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

-- The player's inventory as { [guid] = { row, n } }, at most SNAP_CAP items. Property reads only.
local function snapshot(pc)
    local out, n = {}, 0
    local comps = pc:K2_GetComponentsByClass(lib("/Script/SIGISPlugin.SIGISInventoryComponent"))
    local inv
    for i = 1, #comps do
        local c = comps[i]:get()
        if valid(c) then inv = c break end
    end
    if not inv then return nil end
    inv.StashedItems:ForEach(function(_, e)
        if n >= CFG.SNAP_CAP then return true end
        local it = e:get()
        if valid(it) then
            n = n + 1
            local st = it.StackAmount
            out[it.UniqueItemGUID:ToString()] = { row = it.ItemData:ToString(), n = type(st) == "number" and st > 0 and st or 1 }
        end
    end)
    return out
end

local function value(e)
    local r = require("itemdata").get(e.row)
    return (r and r.price or 0) * ((r and r.stackable == 1) and e.n or 1)
end

local function take(pc)
    local ok, s = pcall(snapshot, pc)
    if not ok then log("raid summary: inventory snapshot failed: " .. tostring(s)) return nil end
    return s
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
    if not T.inSnap and now - T.startedAt >= CFG.SNAP_AFTER and valid(pc) then T.inSnap = take(pc) or {} end
    local mv = 0
    pcall(function() mv = require("missions").version() end)
    if mv > T.events then T.events = mv end
    local p = pc.Pawn
    if p and valid(p) then
        local ok, n = pcall(function() return p:GetClass():GetFName():ToString() end)
        if ok and n == "PlayerPawn_C" and (p.Health or 1) <= 0 then T.died = true end
    end
    -- Extracted (before the travel) or died: the one closing snapshot.
    if T.inSnap and not T.outSnap and (T.extracted or T.died) and valid(pc) then T.outSnap = take(pc) or {} end
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
    local loot
    if t.outSnap then
        local cnt, worth, new = 0, 0, {}
        for g, e in pairs(t.outSnap) do
            cnt, worth = cnt + 1, worth + value(e)
            if t.inSnap and not t.inSnap[g] then new[#new + 1] = { row = e.row, v = value(e) } end
        end
        if t.outcome == "Died" then
            loot = ("Lost: %d items worth ~$%d"):format(cnt, worth)
        else
            table.sort(new, function(a, b) return a.v > b.v end)
            local top = {}
            for i = 1, math.min(3, #new) do top[i] = new[i].row end
            loot = ("Brought out: %d items worth ~$%d (+%d new%s)"):format(cnt, worth, #new,
                #top > 0 and (": " .. table.concat(top, ", ")) or "")
        end
    end
    log(("raid summary: %s; %s; %s; %s%s"):format(head, kills, crew, prog, loot and ("; " .. loot) or ""))
    ready = { lines = {
        { text = "Raid summary: " .. head, size = 18, col = ACCENT },
        { text = kills }, { text = crew }, { text = prog, col = TEXT_MUTED },
    } }
    if loot then table.insert(ready.lines, 3, { text = loot }) end
    table.insert(ready.lines, { text = "Esc to close", col = TEXT_MUTED, size = 11 })
end

-- The panel: ui.lua's card.

local function show(pc, lines)
    local h = UI.card(pc, { w = 640, row = 26, y = 120, col = TEXT_LIGHT, lines = lines })
    if h then panel = { host = h, untilAt = os.clock() + CFG.SHOW_SECONDS } end
end

local function hide()
    local h = panel and panel.host
    panel = nil
    UI.remove(h)
end

-- Esc (main.lua's key bind, #567).
function M.close() if panel then hide() end end

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
