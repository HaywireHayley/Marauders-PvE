-- What bots say when it matters (#316): a badly hurt Rat, Coward or Timmy near you may beg, and a Chad or GigaChad
-- taunts after a kill or a hit on you. Only lines the game ships (voicelines.lua rows, played by voice.lua).
-- bots.lua's updateBots calls beg() and taunt(); the settings are main.lua's CFG (BEG_*, TAUNT_*; F10 > Personalities).
local Voice = require("voice")

local M = {}
local X -- context from bots.lua: CFG, log, valid, dist, rivals, queryFilter

local BEGGARS = { Rat = true, Coward = true, Timmy = true }
local TAUNTERS = { Chad = true, GigaChad = true }
local TAUNT_ROWS = { "Insult01", "FuckOff" }
local lastTaunt = -1e9

local function personality(e) return e.mind and e.mind.personalityName end

function M.isTaunter(e) return TAUNTERS[personality(e)] == true end

-- Rival crews' captains (and the Red Baron) and bosses never beg.
local function exempt(e)
    if e.crewmate or e.follow then return true end
    if e.rival and (e.rival.isCaptain or e.rival.baron) then return true end
    return e.mind.profileName == "boss"
end

-- The begging is over: run from you for BEG_FLEE_SECONDS, as routed guards do (nothing if no walkable point is found).
function M.flee(e, now, here, playerLoc)
    local R = X.rivals
    if not (R and R.routPoint and X.valid(e.ctrl)) then return end
    e.routUntil, e.routNear = now + X.CFG.BEG_FLEE_SECONDS, R.CFG.ROUT_FIRE_RANGE
    e.alert, e.investigate, e.rehome = nil, nil, e.routUntil
    local p = R.routPoint(e, here, playerLoc)
    if p then
        e.home, e.patrolRadius, e.nextPatrol = p, R.CFG.ROAM_PATROL, e.routUntil
        e.ctrl:MoveToLocation(p, 80, false, true, false, true, X.queryFilter(), true)
    end
end

-- Beg to be spared (once per bot, if the roll goes its way): stops shooting and stays put with a plea for
-- CFG.BEG_SECONDS, then runs (the guards' rout of #313: e.routUntil/e.routNear, bots.lua treats it as "routed") or
-- fights again if it's hit meanwhile. Returns true while the bot begs (the caller then keeps it from fighting).
--   hurt: its health dropped since the last update; engaged: it's fighting or alerted; holdFire: bots.lua's
function M.beg(e, now, hp, hurt, here, playerLoc, engaged, holdFire)
    local CFG = X.CFG
    if e.begUntil then
        if hurt then
            e.begUntil = nil -- shot while begging: no mercy shown, it fights back
            X.log("a begging " .. tostring(personality(e)) .. " was shot and fights again")
            return false
        end
        if now < e.begUntil then
            if now >= (e.begPlea or math.huge) then
                e.begPlea = nil
                pcall(Voice.say, e, "Help", true)
            end
            return true
        end
        e.begUntil = nil
        M.flee(e, now, here, playerLoc)
        return false
    end
    if e.begDone or not BEGGARS[personality(e)] or (CFG.BEG_CHANCE or 0) <= 0 or not playerLoc or not engaged then
        return false
    end
    local max = e.rival and e.rival.maxHp or e.hpMax or 0
    if max <= 0 or hp / max >= CFG.BEG_HP or exempt(e) or X.dist(here, playerLoc) > CFG.BEG_RANGE then return false end
    e.begDone = true
    if math.random() >= CFG.BEG_CHANCE then return false end
    local lo, hi = CFG.BEG_SECONDS[1], math.max(CFG.BEG_SECONDS[1], CFG.BEG_SECONDS[2])
    e.begUntil = now + lo + math.random() * (hi - lo)
    e.begPlea = now + (e.begUntil - now) * 0.5 -- a second plea halfway
    pcall(holdFire, e)
    pcall(function() e.ctrl:StopMovement() end)
    pcall(Voice.say, e, "Help", true)
    X.log(("a %s begs for its life (health %.0f of %.0f) for %.0f s"):format(personality(e), hp, max, e.begUntil - now))
    return true
end

-- A taunt after a kill or a hit on you: the chance applies each time, a bot waits TAUNT_EVERY seconds between its own
-- and nobody speaks within TAUNT_GAP of anyone else's. CFG.TAUNT_CHANCE 0 = off.
function M.taunt(e, now)
    local CFG = X.CFG
    if (CFG.TAUNT_CHANCE or 0) <= 0 or not TAUNTERS[personality(e)] then return end
    if now - (e.tauntAt or -1e9) < CFG.TAUNT_EVERY or now - lastTaunt < CFG.TAUNT_GAP then return end
    if math.random() >= CFG.TAUNT_CHANCE then return end
    e.tauntAt, lastTaunt = now, now
    pcall(Voice.say, e, TAUNT_ROWS[math.random(#TAUNT_ROWS)], true)
end

function M.init(ctx) X = ctx end

return M
