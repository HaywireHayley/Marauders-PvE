-- The game's own end-of-raid screen (#485, first pass). The game has a results widget, SIGIS_EndMatch (kills you made,
-- XP, missions) with ScrollBox_Kills / ScrollBox_Missions. The mod used to show its own panels next to it (death screen
-- #331, raid summary #390); this adds the same facts as plain rows to the game's screen instead, and the two panels
-- stay away while that works.
--
-- Flow: raidsummary.lua (a closed raid's tally) and deathscreen.lua (your death) hand over plain strings
-- (setSummary / setDeath) and with them start a wait of WAIT_SECONDS. poll() (raidsummary's lobby frame, deathscreen's
-- raid frame) looks for a live SIGIS_EndMatch at most once a second, only while something waits, and appends the rows
-- once (the data is consumed: that is the mark). state(kind) tells the panels: "wait" (hold your panel), "done" (the rows
-- are on the game's screen: no panel), "timeout" or "off" (show your own panel as before).
-- Only strings are kept across a world change; no widget reference outlives one poll (M.reset). Nothing is rooted.
-- NOT tested in game (2026-11-27): the widget's class and property names are from the issue, not yet seen live.
local M = {}
local UI = require("ui")
local log, valid
local CFG = { WAIT_SECONDS = 8, POLL_SECONDS = 1, DEATH_MAX_AGE = 600 }
M.CFG = CFG
local ACCENT = { R = 0.95, G = 0.5, B = 0.12, A = 1 }
local LIGHT = { R = 0.92, G = 0.92, B = 0.9, A = 1 }
local MUTED = { R = 0.6, G = 0.62, B = 0.65, A = 1 }

local P = {}         -- kind ("sum", "death") -> { data, at, st = "wait" | "done" | "timeout" }
local nextAt = 0
local loggedFind

function M.init(ctx) log, valid = ctx.log, ctx.valid end
-- The strings in P are plain Lua and wait for the lobby; only the poll timer is per world.
function M.reset() nextAt = 0 end
local function on() return require("features").END_SCREEN == 1 end

-- data: { head, kills, crew, loot, prog } (strings); died: the raid ended in your death.
function M.setSummary(data, died)
    if not on() then return end
    P.sum = { data = data, died = died, at = os.clock(), st = "wait" }
end

-- lines: plain strings, the first is the headline.
function M.setDeath(lines)
    if not on() then return end
    P.death = { data = lines, at = os.clock(), st = "wait" }
end

function M.state(kind)
    if not on() then return "off" end
    local p = P[kind]
    return p and p.st or "off"
end

local function find()
    for _, cn in ipairs({ "SIGIS_EndMatch_C", "SIGIS_EndMatch" }) do
        local ok, all = pcall(FindAllOf, cn)
        if ok and type(all) == "table" then
            for _, w in ipairs(all) do
                if valid(w) then
                    local okn, fn = pcall(function() return w:GetFullName() end)
                    if okn and type(fn) == "string" and fn:find("Transient", 1, true) and not fn:find("Default__", 1, true) then
                        return w, fn
                    end
                end
            end
        end
    end
end

local function prop(w, name)
    local ok, v = pcall(function() return w[name] end)
    if ok and v and valid(v) then return v end
end

-- The rows for what is waiting, as { text, col, size, box }.
local function rows()
    local out = {}
    local function add(t, col, size, box) if t and t ~= "" then out[#out + 1] = { t, col or LIGHT, size or 14, box } end end
    local s, d = P.sum, P.death
    local sumWaits = s and s.st == "wait"
    if sumWaits then
        local x = s.data
        add("Raid summary: " .. (x.head or ""), ACCENT, 16, "kills")
        add(x.kills, LIGHT, 14, "kills")
        add(x.crew, LIGHT, 14, "kills")
        add(x.loot, LIGHT, 14, "missions")
        add(x.prog, MUTED, 13, "missions")
    end
    -- the death rows ride on the summary of a raid you died in, or alone (the end screen came up in the raid)
    local useDeath = d and os.clock() - d.at <= CFG.DEATH_MAX_AGE
        and ((d.st == "wait" and (not sumWaits or s.died)) or (d.st == "timeout" and sumWaits and s.died))
    if useDeath then
        add("How you died", ACCENT, 16, "kills")
        for i, l in ipairs(d.data) do add(l, i == 1 and LIGHT or MUTED, i == 1 and 14 or 13, "kills") end
    end
    return out, useDeath and true or false
end

local function inject(w, list)
    local tree = prop(w, "WidgetTree")
    local kills, missions = prop(w, "ScrollBox_Kills"), prop(w, "ScrollBox_Missions")
    if not tree or not (kills or missions) then return false end
    local added = 0
    for _, r in ipairs(list) do
        local box = (r.box == "missions" and missions) or kills or missions
        local ok, err = pcall(function() box:AddChild(UI.text(tree, r[1], r[3], r[2])) end)
        if ok then added = added + 1 else log("end screen: row failed: " .. tostring(err)) end
    end
    return added > 0
end

-- From raidsummary's lobby frame and deathscreen's raid frame. Cheap unless something is waiting.
function M.poll()
    local now = os.clock()
    local waiting = false
    for _, p in pairs(P) do
        if p.st == "wait" and now - p.at > CFG.WAIT_SECONDS then
            p.st = "timeout"
            log(("end screen: SIGIS_EndMatch not filled in %d s: the mod's own panel is used"):format(CFG.WAIT_SECONDS))
        end
        if p.st == "wait" then waiting = true end
    end
    if not waiting or now < nextAt then return end
    nextAt = now + CFG.POLL_SECONDS
    local w, fn = find()
    if not w then return end
    if not loggedFind then loggedFind = true log("end screen: found " .. tostring(fn)) end
    local list, useDeath = rows()
    if #list == 0 then return end
    local ok, done = pcall(inject, w, list)
    if not ok then log("end screen: injection failed: " .. tostring(done)) return end
    if not done then return end -- the scroll boxes aren't there yet: try again next second
    if P.sum and P.sum.st == "wait" then P.sum.st = "done" end
    if useDeath then P.death.st = "done" end
    log(("end screen: %d rows added to the game's end screen"):format(#list))
end

return M
