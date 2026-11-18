-- Raid length (issue #159): the launcher's "Raid length" setting, config/raid_length.txt: minutes, "default" or "none".
-- The game keeps the raid's countdown in RaidGameState.RemainingTime (seconds; RaidGameMode.RoundTime = 1500, 25 min)
-- and ends the raid at 0; bTimerPaused stops it. Offline we're the server, so a value written here holds and counts
-- down as usual (checked: 2700 -> 2693 after 7 s; paused, it stayed put). Set once per raid, as soon as the game state
-- exists, as length minus the time already gone. The space gate (RaidGameMode.TimeTillEvacSpawn, 300 s) is left alone.
local PROJECT = require("pveproject")
local M = {}

local SETTING = PROJECT .. "config/raid_length.txt"
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

-- Every update in a raid. During the warmup (the first WarmupTime, 15 s) RemainingTime holds the warmup's own
-- countdown, and the round then starts it again from RoundTime: so RoundTime is set at once, and RemainingTime (or the
-- pause, which would otherwise hold the warmup and the raid would never start) only once the round is running.
function M.update()
    if not raid or raid.lengthSet then return end
    local gs = FindFirstOf("RaidGameState")
    if not X.valid(gs) then return end
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

return M
