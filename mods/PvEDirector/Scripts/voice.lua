-- Rival bots speak with the game's own player voice sets (voicelines.lua): each person keeps one set for life.
local Lines = require("voicelines")

local M = {}
local X -- context from main.lua: valid, lib, log

local CFG = {
    SAME_BOT = 3,      -- seconds a bot stays quiet after speaking (pain and death don't wait)
    ANYONE = 0.3,      -- seconds between any two bots starting a line
    VOLUME = 1.0,
}

local cues = {} -- path -> loaded sound cue
local queue       -- paths still to load
local lastAny = 0

function M.pending() return queue == nil or #queue > 0 end

-- A few lines a frame while the menu is up (main.lua), so no raid starts with a load (10 s all at once, 50 ms a line) and
-- nothing loads mid-fight. The lines are rooted: the garbage collector can't see this table.
function M.step()
    if not queue then
        queue = {}
        for _, sets in pairs(Lines) do
            for _, set in pairs(sets) do
                for _, paths in pairs(set) do
                    for _, path in ipairs(paths) do queue[#queue + 1] = path end
                end
            end
        end
    end
    local path = table.remove(queue)
    if not path then return end
    local cue = X.lib(path)
    if not X.valid(cue) then
        pcall(LoadAsset, path)
        cue = X.lib(path)
    end
    if X.valid(cue) then
        X.root(cue)
        cues[path] = cue
    end
    if #queue == 0 then X.log("voices: all lines loaded") end
end

function M.pick(female)
    local names, sets = {}, female and Lines.female or Lines.male
    for name in pairs(sets) do names[#names + 1] = name end
    return sets[names[math.random(#names)]]
end

-- Says a row of the bot's voice set, if it has one. Lines come in quiet and shouted takes.
function M.say(e, row, urgent)
    local set = e.voice
    if not (set and set[row] and e.bot and X.valid(e.bot)) then return end
    local now = os.clock()
    if not urgent and (now - (e.spokeAt or -1e9) < CFG.SAME_BOT or now - lastAny < CFG.ANYONE) then return end
    local paths = set[row]
    local cue = cues[paths[math.random(#paths)]]
    if not X.valid(cue) then return end
    e.spokeAt, lastAny = now, now
    X.lib("/Script/Engine.Default__GameplayStatics"):SpawnSoundAtLocation(e.bot, cue, e.bot:K2_GetActorLocation(),
        { Pitch = 0, Yaw = 0, Roll = 0 }, CFG.VOLUME, 1.0, 0.0, nil, nil, true)
end

function M.init(ctx) X = ctx end

return M
