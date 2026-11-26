-- 40mm rounds that blew up in the shooter's hands (#360). Two causes, both seen in game on 2026-11-25:
-- 1. Offline every projectile gun fired two rounds at the same muzzle point (the client-predicted one and the server's);
--    a 40mm round detonated on its twin. pvepatch.c "FireWeapon no local projectile" now skips the local one.
-- 2. The one round left still went off on its first move, inside its shooter: nothing tells it to ignore the pawn and
--    gun that fired it offline. Here, right after ServerFireProjectile (which pvepatch lets run locally) has spawned
--    it, the round's collision is told to ignore both (IgnoreActorWhenMoving). Tested: the round flew down the corridor
--    and burst on the far wall (5 splash damage at that range); without it, 45 damage in your hands.
-- The blast of your 40mm launchers on bots (2026-11-25, asked for):
--   * The fire patch a round leaves (DamagePerCheck 5 every 0.3 s for HowLongFireLasts 2 s, then a flame fade of its own) does no
--     damage now, burns one check and fades in about 0.6 s in all: a quick explosion flash, not a 4 second field.
--   * Its damage went into the blast: a round that goes off right on a bot is a direct hit. China Lake: 150 percent of the bot's
--     health (dead unless armoured), Mini Thumper: 90 percent (an unarmoured bot is left with 10 percent). Armour takes 5 percent
--     off per point of the body rating (a vest of 13 takes 65 percent: a China Lake then leaves a bot about half its health; up to a rating of 6 it still kills). The total is worked out here from the health before the blast, so the game's own splash
--     does not add to it.
--   * Every bot near the blast is thrown away from it (the throw a shotgun volley gives, botdamage.lua), like a barrel's.
-- Only your own rounds count; a rival's launcher keeps the game's fire.
-- Rounds are pooled (RaidProjectile.PooledProjectile): the pool builds them once, so they're collected as they're
-- constructed (NotifyOnNewObject) instead of searched for per shot (a FindAllOf is ~50 ms). Only exploding rounds.
local M = {}
local X -- log, valid

local FIRE = "/Script/RaidGame.RaidWeapon:ServerFireProjectile"
local PROJECTILE = "/Script/RaidGame.RaidProjectile"

-- Blast, tuned here (cm, shares of a bot's health, cm/s, seconds):
local CHINA, THUMPER = "Launcher_ChinaLake_Child_C", "Launcher_Thumper_Child_C"
local DIRECT = { [CHINA] = 1.5, [THUMPER] = 0.9 } -- a direct hit's damage before armour, as a share of the bot's health before the blast
local DIRECT_RADIUS = 160 -- a round that goes off this close to a bot's middle is a direct hit
local ARMOUR_SHARE = 0.05 -- the share of a direct hit each point of the body armour rating takes off (13 points: 65 percent)
local BLAST_RADIUS = 700 -- bots this close to the blast are thrown
local THROW = 1800 -- (unused while a bot on its feet is left alone)
local DEAD_THROW = 513 -- the flat speed of a bot the blast kills or has killed: about a 2 m nudge once it slides to a stop
local TRACK_FOR = 10 -- seconds a round is followed
local FIRE_DAMAGE = 0 -- DamagePerCheck of the fire a round leaves
local FIRE_BURN = 0.3 -- HowLongFireLasts: the first check puts it out
local FIRE_FADE = 0.3 -- seconds the flames take to fade (the burn is 0.3 of the 0.6 s)
local FIRE_GROW = 0.3 -- seconds its other animations take

local tracked = {} -- your launcher rounds in the air: { p = round, cls = launcher class, at = fired, last = place }
local quenched = {} -- fire patches already dealt with (address -> time)
local booms = {} -- blasts lately: { at = time, l = place }
local prevH = {} -- bot address -> { cur = health last frame, old = the frame before }
local rounds = {} -- every projectile the pools have built (dead ones dropped as they're met)
local logged = false

-- Runs after every projectile shot from any gun, bots' included, so it stays cheap: rounds that don't explode are
-- dropped from the list the first time they're met (a pooled round keeps its kind), and a gun is checked for being
-- yours once per shot through its pawn's controller, not a FindFirstOf per round.
local function afterFire(ctx)
    local w = ctx:get()
    if not X.valid(w) or #rounds == 0 then return end
    local pawn = w.MyPawn
    local wAddr = w:GetAddress()
    local mine -- nil: not worked out yet this shot
    for i = #rounds, 1, -1 do
        local p = rounds[i]
        if not X.valid(p) or not p.bDoesExplode then
            table.remove(rounds, i)
        elseif not p.bExploded then
            local owner = p.MyWeaponOwner
            if X.valid(owner) and owner:GetAddress() == wAddr then
                local c = p.CollisionComp
                if X.valid(c) then
                    if mine == nil then
                        mine = false
                        local okC, cls = pcall(function() return w:GetClass():GetFName():ToString() end)
                        if okC and DIRECT[cls] and X.valid(pawn) then
                            local ctrl = pawn.Controller
                            if X.valid(ctrl) and ctrl:IsPlayerController() then mine = cls end
                        end
                    end
                    if mine then
                        local have = false
                        for _, t in ipairs(tracked) do if t.p == p then have = true end end
                        if not have then tracked[#tracked + 1] = { p = p, cls = mine, at = os.clock() } end
                    end
                    c:IgnoreActorWhenMoving(w, true)
                    if X.valid(pawn) then c:IgnoreActorWhenMoving(pawn, true) end
                    if not logged then
                        logged = true
                        X.log("launchers: an exploding round ignores its gun and shooter (#360)")
                    end
                end
            end
        end
    end
end

local function where(o)
    local ok, l = pcall(function() local v = o:K2_GetActorLocation() return { X = v.X, Y = v.Y, Z = v.Z } end)
    return ok and l or nil
end

-- A round of `cls` has gone off at `at`: the bots near it.
local pending = {} -- direct hits waiting for the game's own splash to land: { bot, h0, take, at }
local function blast(pc, bots, at, cls, now)
    local BD = require("botdamage")
    for _, e in ipairs(bots) do
        local bot = e.bot
        local h = X.valid(bot) and bot.Health
        local l = type(h) == "number" and h > 0 and where(bot)
        if l then
            local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d <= DIRECT_RADIUS then
                -- (a bot's MaxHealth is not a plain number here, so the share is of the health it had just before the blast)
                local rating = BD.armour(e).body
                local pv = prevH[bot:GetAddress()]
                local h0 = math.max(pv and math.max(pv.cur or 0, pv.old or 0) or 0, h)
                local take = DIRECT[cls] * h0 * math.max(0, 1 - rating * ARMOUR_SHARE)
                pending[#pending + 1] = { bot = bot, h0 = h0, take = take, at = now + 0.15, cls = cls, rating = rating }
            end
            if d <= BLAST_RADIUS then
                local k = THROW * (1 - d / BLAST_RADIUS)
                local len = math.max(d, 1)
                -- away from the blast, flat; a push up so a live bot leaves the ground
                local dk = DEAD_THROW * math.max(0.3, 1 - d / BLAST_RADIUS)
                -- a bot still on its feet is left alone (as the game has it); one that is dead or ragdolled within 1.7 s gets the small dead throw
                BD.throw(bot, { X = dx / len * k, Y = dy / len * k, Z = k * 0.45 }, 0,
                    { X = dx / len * dk, Y = dy / len * dk, Z = dk * 0.25 })
            end
        end
    end
end

-- A direct hit lands once the game's own splash has: the bot ends up at its health from before the blast less `take`
-- (never higher than it is), or dead.
local function land(pc, q)
    local bot = q.bot
    if not X.valid(bot) then return end
    local h = bot.Health
    if type(h) ~= "number" or h <= 0 then return end
    local target = q.h0 - q.take
    if target <= 0 then
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local dtype = StaticFindObject("/Script/Engine.DamageType")
        pcall(function() gs:ApplyDamage(bot, h + 100, pc, pc.Pawn.CurrentWeapon, dtype) end)
    elseif target < h then
        pcall(function() bot.Health = target end)
    end
    X.log(("launchers: %s direct hit on %s (armour %d): health %.0f -> %s"):format(q.cls == CHINA and "China Lake" or "Mini Thumper",
        bot:GetFName():ToString(), q.rating, h, target <= 0 and "dead" or ("%.0f"):format(math.min(target, h))))
end

-- A fire patch next to a blast: no damage, one check, quick animations.
local fireLogged = false
local function quench(f)
    pcall(function() f.DamagePerCheck = FIRE_DAMAGE end)
    pcall(function() f.HowLongFireLasts = FIRE_BURN end)
    local okC, comps = pcall(function() return f:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.TimelineComponent")) end)
    if okC and comps then
        for i = 1, #comps do
            local tl = comps[i]:get()
            if X.valid(tl) then
                local okN, name = pcall(function() return tl:GetFName():ToString() end)
                local okL, len = pcall(function() return tl:GetTimelineLength() end)
                if okN and okL and type(len) == "number" and len > 0 then
                    local want = name:find("FireTurnOff", 1, true) and FIRE_FADE or FIRE_GROW
                    pcall(function() tl:SetPlayRate(len / want) end)
                    if not fireLogged then X.log(("launchers: fire timeline %s, %.2f s, sped up to %.2f s"):format(name, len, want)) end
                end
            end
        end
    end
    if not fireLogged then fireLogged = true X.log("launchers: a 40mm fire patch made a quick flash with no damage") end
end

-- Every frame (from botdamage.lua): your launcher rounds until one has gone off, the blasts' direct hits, the fire patches near them.
function M.frame(pc, bots, now)
    for i = #tracked, 1, -1 do
        local t = tracked[i]
        local p = t.p
        local alive = X.valid(p)
        local exploded = false
        if alive then
            local okE, ex = pcall(function() return p.bExploded end)
            exploded = okE and ex and true or false
            local l = where(p)
            if l then t.last = l end
        end
        if exploded or not alive or now - t.at > TRACK_FOR then
            table.remove(tracked, i)
            if (exploded or not alive) and t.last then
                booms[#booms + 1] = { at = now, l = t.last, scans = 0, nextScan = now }
                local ok, err = pcall(blast, pc, bots, t.last, t.cls, now)
                if not ok then X.log("launchers: blast failed: " .. tostring(err)) end
            end
        end
    end
    for i = #pending, 1, -1 do
        local q = pending[i]
        if now >= q.at then
            table.remove(pending, i)
            local ok, err = pcall(land, pc, q)
            if not ok then X.log("launchers: direct hit failed: " .. tostring(err)) end
        end
    end
    -- The fire patch a blast leaves: looked for once the frame after it (the patch's first check is 0.3 s after it is built), once
    -- more 0.15 s later if it was not there yet. Within 5 m of the blast. (A NotifyOnNewObject on the patch's class never fired at
    -- startup: the class is not loaded when the mod starts, so it is searched for with FindAllOf, which costs a few ms.)
    for i = #booms, 1, -1 do
        local b = booms[i]
        if b.done or now - b.at > 1.5 or b.scans >= 2 then
            table.remove(booms, i)
        elseif now >= b.nextScan then
            b.scans = b.scans + 1
            b.nextScan = now + 0.15
            for _, f in ipairs(FindAllOf("00_UA_GrenadeFire_DamageArea_C") or {}) do
                if X.valid(f) and not quenched[f:GetAddress()] then
                    local l = where(f)
                    if l then
                        local dx, dy, dz = l.X - b.l.X, l.Y - b.l.Y, l.Z - b.l.Z
                        if dx * dx + dy * dy + dz * dz < 500 * 500 then
                            quenched[f:GetAddress()] = now
                            b.done = true
                            local ok, err = pcall(quench, f)
                            if not ok then X.log("launchers: fire patch failed: " .. tostring(err)) end
                        end
                    end
                end
            end
        end
    end
    for a, at in pairs(quenched) do if now - at > 30 then quenched[a] = nil end end
    -- Health before the blast is only needed while one of your rounds is in the air: with none (nearly always) the
    -- per-bot reads are skipped and the table emptied, so it doesn't grow with every bot address seen.
    if #tracked == 0 and #pending == 0 then
        if next(prevH) then prevH = {} end
        return
    end
    for _, b in ipairs(bots) do
        if X.valid(b.bot) then
            local a = b.bot:GetAddress()
            local h = b.bot.Health
            local pv = prevH[a]
            if not pv then pv = {} prevH[a] = pv end
            pv.old, pv.cur = pv.cur, h
        end
    end
end

-- Rounds the game built before this module was loaded (a hot reload in a running raid).
function M.adopt(list)
    for _, p in ipairs(list or {}) do rounds[#rounds + 1] = p end
end

function M.init(ctx)
    X = ctx
    local ok = pcall(RegisterHook, FIRE, function() end, function(c)
        local okf, err = pcall(afterFire, c)
        if not okf then X.log("launchers: " .. tostring(err)) end
    end)
    local ok2 = pcall(NotifyOnNewObject, PROJECTILE, function(p) rounds[#rounds + 1] = p end)
    if not (ok and ok2) then X.log(("launchers: hook %s, notify %s"):format(tostring(ok), tostring(ok2))) end
end

return M
