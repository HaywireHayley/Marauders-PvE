-- Bots look after themselves (#314, first pass): a soldier whose magazine runs low goes to cover and reloads there, one
-- that is hurt and hasn't been shot for a few seconds goes to cover and heals, and Chads and GigaChads push you while
-- you reload or heal. The magazine count itself is bots.lua's M.botShot (e.mag, e.shots, e.reloadUntil, #115).
-- bots.lua's updateBots calls watchPlayer() and step(); coverCycle takes e.careWant as "wants cover now".
-- Settings are main.lua's CFG (BOT_LOW_MAG, BOT_HEAL_*, BOT_PUSH_*; F10 > Fighting). Not tested in game.
local M = {}
local X -- context from bots.lua: CFG, log, valid, dist

local PUSHERS = { Chad = true, GigaChad = true }
local playerBusyUntil = 0
local loggedBusy = false

function M.init(ctx) X = ctx end

local function maxHp(e) return e.rival and e.rival.maxHp or e.hpMax or 0 end

function M.wantCover(e) return e.careWant ~= nil end

-- Is the player reloading or healing? (pawn:IsHealing() and weapon:IsReloading() are plain getters, NOTES "Shared AI
-- brain"; everything is checked valid and pcall'd). Call once per update with a live pawn.
function M.watchPlayer(pawn, now)
    if (X.CFG.BOT_PUSH_SECONDS or 0) <= 0 or not X.valid(pawn) then return end
    local what
    local okh, h = pcall(function() return pawn:IsHealing() end)
    if okh and h == true then what = "healing" end
    if not what then
        local okw, w = pcall(function() return pawn.CurrentWeapon end)
        if okw and X.valid(w) then
            local okr, r = pcall(function() return w:IsReloading() end)
            if okr and r == true then what = "reloading" end
        end
    end
    if what then
        playerBusyUntil = now + 0.8
        if not loggedBusy then loggedBusy = true X.log("player is " .. what .. ": Chads may push") end
    end
end

function M.pushing(e, now) return e.pushUntil ~= nil and now < e.pushUntil end

-- What does the bot need: "heal", "reload" or nil.
local function wants(e, now, hp)
    local CFG = X.CFG
    if e.careKind or e.reloadUntil or now < (e.careCool or 0) then return nil end
    if (CFG.BOT_HEAL_COUNT or 0) > 0 and (e.heals or 0) < CFG.BOT_HEAL_COUNT then
        local max = maxHp(e)
        if max > 0 and hp / max < CFG.BOT_HEAL_HP and now - (e.hurtAt or -1e9) >= CFG.BOT_HEAL_QUIET then return "heal" end
    end
    if (CFG.BOT_LOW_MAG or 0) > 0 and e.mag and e.mag > 0 and e.mag - (e.shots or 0) <= e.mag * CFG.BOT_LOW_MAG then
        return "reload"
    end
    return nil
end

local function giveUp(e, now, why)
    e.careWant, e.careKind, e.healUntil = nil, nil, nil
    e.careCool = now + X.CFG.BOT_CARE_COOLDOWN
    X.log(("%s: %s"):format(e.bot:GetFName():ToString(), why))
end

-- Once per update for a bot that is fighting (hp = its health now; holdFire = bots.lua's).
function M.step(e, now, hp, fighting, holdFire, here, playerLoc, foeIsPlayer)
    local CFG = X.CFG
    local c = e.cover
    local inCover = c and c.state == "hiding"
    if e.careKind == "heal" then
        if not fighting or not inCover or (e.hurtAt or 0) > e.careStart then
            giveUp(e, now, "healing interrupted")
            return
        end
        pcall(holdFire, e)
        local p = math.min(1, (now - e.careStart) / math.max(0.5, e.healUntil - e.careStart))
        local goal = e.healFrom + (e.healTo - e.healFrom) * p
        if goal > hp then pcall(function() e.bot.Health = goal end) end
        if p >= 1 then e.careKind, e.healUntil = nil, nil end
        return
    elseif e.careKind == "reload" then
        if not e.reloadUntil then e.careKind = nil end
        return
    end
    if not fighting then e.careWant, e.pushUntil = nil, nil return end

    -- Push: a Chad that is fighting you rushes while you reload or heal.
    if foeIsPlayer and now < playerBusyUntil and PUSHERS[e.mind and e.mind.personalityName]
        and (CFG.BOT_PUSH_SECONDS or 0) > 0 and playerLoc and X.dist(here, playerLoc) < CFG.BOT_PUSH_RANGE
        and not e.careWant then
        if not M.pushing(e, now) then X.log(e.bot:GetFName():ToString() .. " pushes while the player is busy") end
        e.pushUntil = now + CFG.BOT_PUSH_SECONDS
    end

    local want = e.careWant
    if not want then
        want = wants(e, now, hp)
        if not want then return end
        e.careWant, e.careSince, e.pushUntil = want, now, nil
    end
    if now - e.careSince > CFG.BOT_CARE_GIVEUP then
        giveUp(e, now, "no cover to " .. want .. " in, carries on")
        return
    end
    if not c then return end -- coverCycle looks for a spot (it treats careWant as "wants cover now")
    if c.state == "peeking" then c["until"] = now return end -- duck back in
    if not inCover then return end
    if want == "heal" then
        if now - (e.hurtAt or -1e9) < CFG.BOT_HEAL_QUIET then return end -- shot on the way: wait it out
        local max = maxHp(e)
        e.heals = (e.heals or 0) + 1
        e.careKind, e.careWant, e.careStart = "heal", nil, now
        e.healUntil, e.healFrom, e.healTo = now + CFG.BOT_HEAL_SECONDS, hp, math.max(hp, max * CFG.BOT_HEAL_TO)
        c["until"] = math.max(c["until"] or 0, e.healUntil)
        pcall(holdFire, e)
        X.log(("%s heals in cover: %.0f to %.0f over %.0f s"):format(e.bot:GetFName():ToString(), hp, e.healTo,
            CFG.BOT_HEAL_SECONDS))
    else
        e.shots = 0 -- (the refill comes from bots.lua's frame loop when reloadUntil passes)
        e.reloadUntil = now + CFG.BOT_RELOAD_SECONDS + math.random() * CFG.BOT_RELOAD_JITTER
        e.holdUntil = e.reloadUntil
        e.careKind, e.careWant = "reload", nil
        c["until"] = math.max(c["until"] or 0, e.reloadUntil)
        pcall(holdFire, e)
        pcall(function() e.ctrl:ReloadAIWeapon() end) -- as M.botShot does
        X.log(("%s reloads in cover (magazine of %d low)"):format(e.bot:GetFName():ToString(), e.mag or 0))
    end
end

return M
