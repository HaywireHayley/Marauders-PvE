-- Civilians (issue #81): miners at the mines, prisoners at the Penal Colony, workers at the ports and the Colony
-- Cruiser. They don't fight. They go about their business near where they spawned, run from you when you come close
-- with a gun or start shooting, cower and plead when cornered, and carry things of their trade in their pockets.
-- Killing one is seen: station guards near it come for you ("rival marauders" don't care either way). Uncommon on
-- purpose (CFG.COUNT per matching station, F3 "How many": 0 turns them off).
--
-- They're kept out of raid.bots, so no soldier, rival or crewmate ever targets or protects them, and the per-bot
-- fighting code never touches them. Their body is a raider body with an empty kit (rivalbodies.lua R.civilianBody),
-- woken like a soldier (Bots.arm) and then left without a behaviour tree: everything they do is a MoveToLocation from
-- here, every update.
local M = {}
local X -- log, valid, lib, dist, navLib, navMesh, queryFilter, offLimits, arm, voice, female, rivals, bots
local raid

local CFG = {
    COUNT = 3,             -- civilians per matching station (F3: How many). 0 = none
    MIN_SPAWN_DIST = 2500, -- never spawned closer to you than this
    WANDER = 900,          -- how far they potter about from where they started
    WANDER_PAUSE = { 4, 14 },
    FEAR_RANGE = 1800,     -- you, in sight, this close: they run
    SHOT_RANGE = 4000,     -- your gunfire this close (you fired within SHOT_MEMORY s): they run
    SHOT_MEMORY = 3,
    FLEE_DIST = 2200,      -- how far they try to get from you
    FLEE_SPEED = 520,
    WALK_SPEED = 170,
    CORNER_RANGE = 450,    -- you this close while they run: they give up, crouch and plead
    COWER_SECONDS = 8,
    CALM_SECONDS = 12,     -- out of sight and quiet this long: back to work
    ALERT_RANGE = 3500,    -- a civilian killed: station guards this close come for you
}
M.CFG = CFG

-- Station name (rivals.lua survey) -> who works there and what's in their pockets (gear.lua loot rows).
local TRADES = {
    ["Mini Mine"] = "miner", ["Asteroid Mine"] = "miner", ["Moon Base"] = "miner",
    ["Penal Colony"] = "prisoner",
    ["Spaceport"] = "worker", ["Colony Cruiser"] = "worker", ["Navy Outpost"] = "worker",
}
local POCKETS = {
    miner = { "NickelOre", "Hammer", "Wrench", "WorkGloves", "ToolKit", "MineToken", "TobaccoPouch", "Cable" },
    prisoner = { "TobaccoPouch", "BottleCaps", "Lockpick", "PanzerChoc", "PenalToken", "JunkScrap", "Fabric" },
    worker = { "Cable", "Wrench", "BankNotes", "CopperCoin", "WorkApron", "PortToken", "PortableRadio", "IndustrialPaper" },
}

function M.init(ctx) X = ctx end
function M.setRaid(r) raid = r end

local function pick(list) return list[math.random(#list)] end

local why = {} -- (for the spawn log: why spots were turned down)
local function reachable(ctrl, origin, radius)
    local out = {}
    if not require("outref").call(X.navLib(), "K2_GetRandomReachablePointInRadius", ctrl, origin, out, radius, X.navMesh(),
        X.queryFilter()) or not out.X then why.nav = (why.nav or 0) + 1 return nil end
    if X.offLimits(out) then why.off = (why.off or 0) + 1 return nil end
    return { X = out.X, Y = out.Y, Z = out.Z }
end

-- Called by rivalbodies.lua the first time you walk into a station (after its guards).
function M.station(pc, st)
    local trade = TRADES[st.name]
    local n = math.floor(CFG.COUNT or 0)
    if not trade or n <= 0 or not X.rivals.civilianBody then return end
    raid.civilians = raid.civilians or {}
    local foot = raid.target
    local here = X.valid(foot) and foot:K2_GetActorLocation() or nil
    local made = 0
    why = {}
    -- Like a garrison: the station's own AI spawn nodes (random spots across a station's box mostly land in parts that
    -- aren't played: 12 of 12 off limits at Penal Colony), each nudged a few metres so two don't stand on one.
    local box, nodes = st.box, {}
    for _, nd in ipairs(FindAllOf("RaidAINodeStart") or {}) do
        if X.valid(nd) then
            local l = nd:K2_GetActorLocation()
            if math.abs(l.X - box.c.X) <= box.e.X + 1500 and math.abs(l.Y - box.c.Y) <= box.e.Y + 1500
                and math.abs(l.Z - box.c.Z) <= box.e.Z + 1500 then nodes[#nodes + 1] = l end
        end
    end
    if #nodes == 0 then X.log("[civilians] " .. st.name .. ": no AI nodes to start at") return end
    for _ = 1, n * 4 do
        if made >= n then break end
        local at = reachable(pc, pick(nodes), 400)
        if at and here and X.dist(at, here) < CFG.MIN_SPAWN_DIST then why.near = (why.near or 0) + 1 at = nil end
        if at then
            local pockets = {}
            for _ = 1, math.random(1, 3) do pockets[#pockets + 1] = pick(POCKETS[trade]) end
            local body = X.rivals.civilianBody(pc, at, pockets)
            if body then
                local female = trade ~= "prisoner" and math.random() < X.rivals.CFG.FEMALE
                table.insert(raid.civilians, { bot = body, trade = trade, home = at, state = "new", station = st.name,
                    female = female, voice = X.voice.pick(female), nextMove = 0, hp = nil })
                made = made + 1
            else
                why.body = (why.body or 0) + 1
            end
        end
    end
    local w = {}
    for k, v in pairs(why) do w[#w + 1] = k .. " " .. v end
    X.log(("[civilians] %s: %d %ss%s"):format(st.name, made, trade, #w > 0 and (" (spots turned down: " .. table.concat(w, ", ") .. ")") or ""))
end

local function speed(c, v)
    pcall(function() c.bot.CharacterMovement.MaxWalkSpeed = v end)
end

local function setState(c, state, now)
    if c.state == state then return end
    c.state, c.since = state, now
    if state == "flee" then
        speed(c, CFG.FLEE_SPEED)
        pcall(function() c.bot:UnCrouch(false) end)
        pcall(X.voice.say, c, "Help", true)
    elseif state == "cower" then
        pcall(function() c.ctrl:StopMovement() end)
        pcall(function() c.bot:Crouch(false) end)
        pcall(X.voice.say, c, "Help", true)
    elseif state == "work" then
        speed(c, CFG.WALK_SPEED)
        pcall(function() c.bot:UnCrouch(false) end)
    end
end

-- Away from you: of a few reachable points around them, the one farthest from you.
local function fleeFrom(c, from)
    local here = c.at
    local best, bd
    for _ = 1, 5 do
        local p = reachable(c.ctrl, here, CFG.FLEE_DIST)
        if p then
            local d = X.dist(p, from)
            if not bd or d > bd then best, bd = p, d end
        end
    end
    if best then c.ctrl:MoveToLocation(best, 80, false, true, false, true, X.queryFilter(), true) end
end

-- A civilian has just died: who saw it? Station guards near it come for you.
local function killed(c, playerLoc)
    raid.civiliansKilled = (raid.civiliansKilled or 0) + 1
    local near = playerLoc and c.at and X.dist(playerLoc, c.at) < CFG.SHOT_RANGE
    if not near then
        X.log(("[civilians] a %s died at %s (not near you)"):format(c.trade, c.station))
        return
    end
    local n = 0
    for _, e in ipairs(raid.bots or {}) do
        if not e.dead and not e.faction and not e.crewmate and X.valid(e.bot) and c.at
            and X.dist(e.updAt or e.bot:K2_GetActorLocation(), c.at) < CFG.ALERT_RANGE then
            e.alert = true
            n = n + 1
        end
    end
    X.log(("[civilians] you killed a %s at %s: %d guard(s) come for you (%d civilians killed this raid)"):format(
        c.trade, c.station, n, raid.civiliansKilled))
end

-- Every update on space maps (main.lua).
function M.update(pc)
    local list = raid and raid.civilians
    if not list or #list == 0 then return end
    local now = os.clock()
    local you = raid.target
    local alive = X.valid(you) and (you.Health or 0) > 0
    local playerLoc = alive and you:K2_GetActorLocation() or nil
    local shooting = raid.playerShotAt and now - raid.playerShotAt < CFG.SHOT_MEMORY
    for i = #list, 1, -1 do
        local c = list[i]
        if not X.valid(c.bot) or (c.bot.Health or 0) <= 0 then
            if not c.dead then c.dead = true pcall(killed, c, playerLoc) end
            table.remove(list, i)
        else
            c.at = c.bot:K2_GetActorLocation()
            if c.state == "new" then
                c.ctrl = X.arm(c.bot)
                if c.ctrl then
                    pcall(function() c.ctrl.BrainComponent:StopLogic("civilian") end)
                    if c.female then pcall(X.female.dress, c.bot, true) end
                    setState(c, "work", now)
                end
            elseif c.ctrl and X.valid(c.ctrl) then
                if not X.valid(c.bot.Controller) then c.ctrl = X.arm(c.bot, c.ctrl) end -- the game put it to sleep
                pcall(function() if c.ctrl.BrainComponent:IsRunning() then c.ctrl.BrainComponent:StopLogic("civilian") end end)
                local hp = c.bot.Health
                local hurt = c.hp and hp < c.hp
                c.hp = hp
                local d = playerLoc and X.dist(c.at, playerLoc) or math.huge
                local seen = d < CFG.FEAR_RANGE and c.ctrl:LineOfSightTo(you, { X = 0, Y = 0, Z = 0 }, false)
                local scared = hurt or seen or (shooting and d < CFG.SHOT_RANGE)
                if hurt then pcall(X.voice.say, c, hp < 40 and "Help" or "Pain", true) end
                if c.state == "cower" then
                    if hurt then setState(c, "flee", now) fleeFrom(c, playerLoc)
                    elseif now - c.since > CFG.COWER_SECONDS and d > CFG.CORNER_RANGE then setState(c, "flee", now) end
                elseif scared then
                    c.scaredAt = now
                    if c.state == "flee" and d < CFG.CORNER_RANGE and not hurt then
                        setState(c, "cower", now)
                    else
                        setState(c, "flee", now)
                        if now >= c.nextMove or c.ctrl:GetMoveStatus() ~= 3 then
                            c.nextMove = now + 2
                            fleeFrom(c, playerLoc)
                        end
                    end
                elseif c.state == "flee" and now - (c.scaredAt or 0) > CFG.CALM_SECONDS then
                    setState(c, "work", now)
                elseif c.state == "work" and now >= c.nextMove and c.ctrl:GetMoveStatus() ~= 3 then
                    c.nextMove = now + math.random(CFG.WANDER_PAUSE[1], CFG.WANDER_PAUSE[2])
                    local p = reachable(c.ctrl, c.home, CFG.WANDER)
                    if p then c.ctrl:MoveToLocation(p, 60, false, true, false, true, X.queryFilter(), true) end
                end
            end
        end
    end
end

-- This raid's civilians (tests through bridge/dir_eval.lua; the entries are live, don't keep them).
function M.list() return raid and raid.civilians or {} end

function M.status()
    local list = raid and raid.civilians or {}
    local t = {}
    for _, c in ipairs(list) do t[c.state] = (t[c.state] or 0) + 1 end
    local o = {}
    for k, v in pairs(t) do o[#o + 1] = k .. " " .. v end
    return #list .. " (" .. table.concat(o, ", ") .. "), killed " .. (raid and raid.civiliansKilled or 0)
end

return M
