-- Raid length (issue #159): the launcher's "Raid length" setting, config/raid_length.txt: minutes, "default" or "none".
-- The game keeps the raid's countdown in RaidGameState.RemainingTime (seconds; RaidGameMode.RoundTime = 1500, 25 min)
-- and ends the raid at 0; bTimerPaused stops it. Offline we're the server, so a value written here holds and counts
-- down as usual (checked: 2700 -> 2693 after 7 s; paused, it stayed put). Set once per raid, as soon as the game state
-- exists, as length minus the time already gone.
-- The space gate: config/gate_time.txt (the launcher's "Space gate"): minutes, "instant" or "default". The game spawns the
-- gate 300 s into the raid (RaidGameMode.TimeTillEvacSpawn) whatever the raid's length, but its on screen countdown
-- ("Spacegate arrives in") counts to the last 20 minutes of the raid, so with a long raid it said 40 minutes and the gate
-- came at 5 (measured 2026-11-18, 60 minute raid: EvacSpawned flipped at 300 s elapsed, the countdown read 34:53 at 329 s).
-- A write to TimeTillEvacSpawn at 71 s into the raid did not move the spawn, so it is written here in the warmup, with
-- RoundTime, before the round starts; the log line says what the game then did. Measured after that (60 minute raid, gate
-- 10 minutes): EvacSpawned flipped between 585 and 600 s, so the warmup write moves the real arrival. Details, and the
-- countdown text (M.frame, below): docs/internals/SPACE_GATE.md.
local PROJECT = require("pveproject")
local M = {}

local SETTING = PROJECT .. "config/raid_length.txt"
local GATE_SETTING = PROJECT .. "config/gate_time.txt"
local INSTANT_SECONDS = 1 -- "instant": the gate comes as the round starts
local MIN_MINUTES, MAX_MINUTES = 5, 240

local X -- { log, valid }
local raid -- main.lua's per-raid table

function M.init(ctx) X = ctx end
function M.setRaid(r) raid = r end

-- nil (the game's own length), "none", or a length in seconds.
local function wanted()
    local f = io.open(SETTING, "r")
    if not f then return nil end
    local v = (f:read("l") or ""):lower():gsub("%s", "")
    f:close()
    if v == "none" then return "none" end
    local minutes = tonumber(v)
    if not minutes then return nil end
    return math.max(MIN_MINUTES, math.min(MAX_MINUTES, minutes)) * 60
end

-- nil (the game's own, 300 s), or the gate's arrival in seconds from the start of the raid.
local function gateWanted()
    local f = io.open(GATE_SETTING, "r")
    if not f then return nil end
    local v = (f:read("l") or ""):lower():gsub("%s", "")
    f:close()
    if v == "instant" then return INSTANT_SECONDS end
    local minutes = tonumber(v)
    if not minutes or minutes <= 0 then return nil end
    return math.min(minutes, MAX_MINUTES) * 60
end

-- Every update in a raid. During the warmup (the first WarmupTime, 15 s) RemainingTime holds the warmup's own
-- countdown, and the round then starts it again from RoundTime: so RoundTime is set at once, and RemainingTime (or the
-- pause, which would otherwise hold the warmup and the raid would never start) only once the round is running.
function M.update()
    if not raid or (raid.lengthSet and raid.gateSet) then return end
    -- Found once per raid, not every update: a co-op joiner never gets past the AuthorityGameMode check below (the game
    -- mode is the host's), and this FindFirstOf (~60 ms) twice a second was its stutter every 1-2 s (#254).
    local gs = raid.timeState
    if not X.valid(gs) then
        gs = FindFirstOf("RaidGameState")
        raid.timeState = gs
        if not X.valid(gs) then return end
    end
    if not X.valid(gs.AuthorityGameMode) then
        -- No game mode here for ~10 s: a co-op joiner, whose raid length and gate are the host's to set.
        raid.timeWaits = (raid.timeWaits or 0) + 1
        if raid.timeWaits >= 20 then
            raid.gateSet, raid.lengthSet = true, true
            X.log("raid length and space gate: the host's (no game mode here: joined a co-op raid)")
        end
        return
    end
    if not raid.gateSet then
        local ok, err = pcall(function()
            local gm = gs.AuthorityGameMode
            if not X.valid(gm) then return end
            raid.gateSet = true
            local want = gateWanted()
            if not want then return end
            gm.TimeTillEvacSpawn = want
            X.log(("space gate: set to arrive %d s into the raid (the game's own is 300 s; read back %s, %.0f s left)")
                :format(want, tostring(gm.TimeTillEvacSpawn), gs.RemainingTime))
        end)
        if not ok then raid.gateSet = true X.log("space gate: " .. tostring(err)) end
    end
    if raid.lengthSet then return end
    if raid.lengthWant == nil then raid.lengthWant = wanted() or false end
    local want = raid.lengthWant
    if not want then raid.lengthSet = true return end
    local ok, err = pcall(function()
        local gm = gs.AuthorityGameMode -- (the space and land game modes are RaidGameMode subclasses)
        if not X.valid(gm) then return end
        local round = gm.RoundTime
        if want ~= "none" and round ~= want then gm.RoundTime = want end
        if gs.RemainingTime <= (gm.WarmupTime or 15) + 1 then -- warmup: the round will start from RoundTime
            raid.lengthWarmup = true
            return
        end
        raid.lengthSet = true
        if want == "none" then
            gs.bTimerPaused = true
            X.log(("raid length: no limit (timer paused at %.0f s)"):format(gs.RemainingTime))
            return
        end
        if not raid.lengthWarmup then
            -- first seen with the round already running on the old length: keep the time gone, on the new length
            gs.RemainingTime = math.max(60, want - math.max(0, round - gs.RemainingTime))
        end
        X.log(("raid length: %d min (%.0f s left)"):format(want // 60, gs.RemainingTime))
    end)
    if not ok then raid.lengthSet = true X.log("raid length: " .. tostring(err)) end
end

-- The on screen "Spacegate arrives in" countdown (Txt_SpacegateTimeArriveIn on the HUD) is the raid's time left minus a fixed
-- 20 minutes (measured: 34:02 beside 3243 s left, then frozen at 30:01 once the gate came), whatever the gate's own timer
-- says, so it is written here as the gate's time (TimeTillEvacSpawn) minus the time gone. Three text blocks have that name:
-- the HUD widget's template (its path starts /SIGISPlugin/, not on screen) and two live copies (under the game instance);
-- only the live ones are written. The HUD rewrites its own text about once a second (measured: 20 rewrites in 10 s across
-- two copies), so this runs every frame and puts ours back at once. The HUD's own functions (MySlowTick, MyTick, Tick,
-- SpacegateState) never reach a Lua hook, so there is no better moment to write. Names only: the blocks are found by name
-- among the TextBlocks (reading them is safe), every few seconds until they are first found, and never again after that.
local HUD_TEXT = "Txt_SpacegateTimeArriveIn"
local FIND_EVERY = 3 -- s between searches while the text blocks have not been found yet

local function findGateTexts()
    local found = {}
    for _, w in ipairs(FindAllOf("TextBlock") or {}) do
        local ok, name = pcall(function() return w:GetFName():ToString() end)
        if ok and name == HUD_TEXT then
            local okf, full = pcall(function() return w:GetFullName() end)
            if okf and not full:find("/SIGISPlugin/", 1, true) then found[#found + 1] = w end
        end
    end
    return found
end

-- Every frame of a raid once the gate is set: the countdown shows when the gate really arrives.
function M.frame()
    if not raid or not raid.gateSet then return end
    local now = os.clock()
    local list = raid.gateTexts
    local good = list ~= nil and #list > 0
    if good then
        for _, w in ipairs(list) do if not X.valid(w) then good = false break end end
    end
    if not good then
        -- Searched only until the blocks were first found: after that, "not valid" means the HUD is going (a raid ending, a map
        -- change), and listing every TextBlock while widgets are being torn down is the one thing here that could hurt.
        if raid.gateTextFound or (raid.gateTextAt and now - raid.gateTextAt < FIND_EVERY) then return end
        raid.gateTextAt = now
        list = findGateTexts()
        raid.gateTexts = list
        if #list == 0 then return end
        raid.gateTextFound = true
    end
    local gs = raid.gateState
    if not (gs and X.valid(gs)) then
        gs = FindFirstOf("RaidGameState")
        raid.gateState = gs
        if not X.valid(gs) then return end
    end
    local gm = gs.AuthorityGameMode
    if not X.valid(gm) or gs.EvacSpawned then return end
    local left = gs.RemainingTime
    if left <= (gm.WarmupTime or 15) + 1 then return end -- warmup: the clock isn't the raid's yet
    local arrive = math.max(0, gm.TimeTillEvacSpawn - (gm.RoundTime - left))
    local text = ("%02d:%02d"):format(arrive // 60, arrive % 60)
    for _, w in ipairs(list) do
        if w:GetText():ToString() ~= text then w:SetText(FText(text)) end
    end
    if not raid.gateTextLogged then
        raid.gateTextLogged = true
        X.log(("space gate: countdown on %d text blocks, showing %s (gate in %d s)"):format(#list, text, arrive))
    end
end

return M
