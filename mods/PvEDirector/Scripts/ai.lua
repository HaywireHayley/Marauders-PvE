-- Shared bot brain (see AI_DESIGN.md; personality/difficulty values adapted from SAIN, see CREDITS.md): difficulty profiles, personalities, and what each bot
-- knows about its enemies. Senses: spotting someone takes time (gain sight), and noises
-- (footsteps, gunshots) are heard with an error that grows with distance. The director (main.lua) and rival crews
-- (rivals.lua) give every bot entry a mind (AI.mind) and ask AI.perceive what it noticed.
local AI = {}
local X -- context from the director: log, valid, dist

-- Difficulty profiles. One per kind of bot; the type modifier is a per-type dial (PMC 1.0, boss 0.75,
-- guard 0.55, scav 0.3), the rest are what it scales:
--   spotTime    gain-sight time multiplier (higher = slower to spot)
--   sight       max sight distance (cm), halfAngle = half the visible cone (degrees)
--   hearing     hearing range multiplier, dispersion = heard-position error multiplier
--   reaction    seconds from spotting to the first shot
--   strafe      RaidCharacterMovement.MaxMoveBackAndStrafeSpeed: side/backward speed as a share of walking. The bot
--               default is 0.1 (side-steps crawled at 17-48 u/s with the legs walking); the player's is 0.8.
--   miss        base RaidBot.AIMissRate, before aimFor's per-bot and per-moment changes. Measured, damage per shot
--               over hundreds of bot shots: ~5 at 0.1-0.45, ~2.4 at 0.85, and the same up to 2.5. All the range
--               is below ~0.9, so the bases sit where the modifiers can still move them.
AI.PROFILES = {
    rival   = { typeMod = 1.0, spotTime = 1.0, sight = 15000, halfAngle = 80, hearing = 1.0, dispersion = 1.0,
                reaction = { 0.15, 0.35 }, miss = 0.35, strafe = 0.9 },
    boss    = { typeMod = 0.75, spotTime = 1.15, sight = 15000, halfAngle = 80, hearing = 1.0, dispersion = 1.0,
                reaction = { 0.25, 0.5 }, miss = 0.4, strafe = 0.85 },
    guard   = { typeMod = 0.55, spotTime = 1.35, sight = 12000, halfAngle = 75, hearing = 0.8, dispersion = 1.25,
                reaction = { 0.4, 0.75 }, miss = 0.5, strafe = 0.8 },
    soldier = { typeMod = 0.3, spotTime = 1.6, sight = 11250, halfAngle = 75, hearing = 0.66, dispersion = 1.5,
                reaction = { 0.6, 1.1 }, miss = 0.6, strafe = 0.75 },
}

-- Personalities (eight archetypes), with the fields the brain uses so far.
--   window      gear power range in which the personality qualifies; ramp = power where its chance is 0 and where
--               it reaches maxChance (%) (descending for the ones weaker gear makes likelier); chance = outside it
--   aggression  divides the chance of seeking cover in a fight; holdGround = multiplies the time fought in the open
--   heard       reaction to a noise while at peace: "charge" (fight now), "search" (go and look), "freeze" (hold
--               still, watch the noise, then look), freeze = seconds frozen, search = willing to go and look
--   sprintSearch chance to run when going to look; sneaky = crouch-walk the last stretch
AI.PERSONALITIES = {
    GigaChad      = { window = { 250, 1000 }, ramp = { 250, 450 }, maxChance = 80, chance = 3, aggression = 1.5, holdGround = 1.25,
                      rush = true, heard = "search", freeze = { 0, 0 }, search = true, sprintSearch = 0.75 },
    Wreckless     = { window = { 250, 1000 }, ramp = { 250, 450 }, maxChance = 5, chance = 1, aggression = 3.0, holdGround = 2.0,
                      rush = true, heard = "charge", freeze = { 0, 0 }, search = true, sprintSearch = 0.9 },
    Chad          = { window = { 100, 1000 }, ramp = { 100, 250 }, maxChance = 80, chance = 8, aggression = 1.25, holdGround = 1.5,
                      rush = true, heard = "freeze", freeze = { 1, 3 }, search = true, sprintSearch = 0.6 },
    SnappingTurtle = { window = { 150, 1000 }, ramp = { 150, 300 }, maxChance = 30, chance = 1, aggression = 1.0, holdGround = 1.5,
                      rush = true, heard = "freeze", freeze = { 8, 20 }, search = true, sprintSearch = 0.4,
                      sneaky = true },
    Normal        = { window = { 0, 1000 }, ramp = { 1000, 0 }, maxChance = 50, chance = 0, aggression = 1.0,
                      holdGround = 1.0, heard = "freeze", freeze = { 2, 6 }, search = true, sprintSearch = 0.1 },
    Rat           = { window = { 0, 200 }, ramp = { 200, 0 }, maxChance = 60, chance = 10, aggression = 0.5,
                      holdGround = 1.0, heard = "freeze", freeze = { 10, 30 }, search = true, sprintSearch = 0,
                      sneaky = true },
    Timmy         = { window = { 0, 150 }, ramp = { 150, 0 }, maxChance = 60, chance = 0, aggression = 0.7,
                      holdGround = 0.5, heard = "freeze", freeze = { 4, 10 }, search = true, sprintSearch = 0.2 },
    Coward        = { window = { 0, 250 }, ramp = { 250, 0 }, maxChance = 30, chance = 5, aggression = 0.4,
                      holdGround = 0.25, heard = "freeze", freeze = { 10, 25 }, search = false, sprintSearch = 0 },
}

-- Gear power, from what the bot carries.
local GUN_POWER = {
    { "Sten", 75 }, { "PPSH", 75 }, { "Grease", 75 }, { "Mat49", 75 }, { "M45", 75 }, { "Mac10", 75 },
    { "Reising", 75 }, { "Sterling", 75 }, { "Thompson", 75 }, { "MP40", 75 },
    { "MG42", 55 }, { "Bren", 55 }, { "DP28", 55 },
    { "STG", 45 }, { "Krasa", 45 }, { "Daewoo", 45 }, { "Mas44", 45 }, { "M1", 45 }, { "AC14", 45 },
    { "Shotgun", 40 }, { "Trench", 40 }, { "Liberator", 40 },
    { "Pistol", -10 }, { "M712", -10 }, { "P08", -10 }, { "1911", -10 },
}
function AI.power(gear)
    local p = gear.pmc and 20 or -20
    local gun = gear.gun or ""
    for _, g in ipairs(GUN_POWER) do
        if gun:lower():find(g[1]:lower(), 1, true) then p = p + g[2] break end
    end
    if gear.helmet then p = p + 30 end
    if gear.chest then p = p + 90 end -- armour class ~3 x 30
    return p + math.random(0, 60)        -- gear we don't model (sights, attachments)
end

function AI.pickPersonality(power)
    power = math.max(0, math.min(1000, power))
    local list, total = {}, 0
    for name, p in pairs(AI.PERSONALITIES) do
        local w = p.chance
        if power >= p.window[1] and power <= p.window[2] then
            local t = (power - p.ramp[1]) / (p.ramp[2] - p.ramp[1])
            w = math.max(w, p.maxChance * math.max(0, math.min(1, t)))
        end
        if w > 0 then list[#list + 1] = { name, w } total = total + w end
    end
    local r = math.random() * total
    for _, it in ipairs(list) do
        r = r - it[2]
        if r <= 0 then return it[1] end
    end
    return "Normal"
end

local function rnd(r) return r[1] + math.random() * (r[2] - r[1]) end
local function len2(x, y) return math.sqrt(x * x + y * y) end

-- A bot's mind: profile, personality, and knowledge of its enemies (keyed by the enemy's address; only the
-- player for now, other bots later).
function AI.mind(profileName, personality)
    local prof = AI.PROFILES[profileName] or AI.PROFILES.soldier
    return { profileName = profileName, profile = prof, personalityName = personality,
        personality = AI.PERSONALITIES[personality] or AI.PERSONALITIES.Normal, known = {}, heardUpTo = 0 }
end

-- Applies the profile to the pawn (accuracy, strafing speed).
function AI.tuneBody(e)
    if not (e.mind and X.valid(e.bot)) then return end
    local prof = e.mind.profile
    if prof.miss then e.bot.AIMissRate = prof.miss end
    if prof.strafe then e.bot.CharacterMovement.MaxMoveBackAndStrafeSpeed = prof.strafe end
    -- RaidCharacter's editor marker sprite (a smiley) is left visible in game on some bots.
    pcall(function() e.bot.Billboard:SetHiddenInGame(true, false) end)
end

local function knowledge(mind, target)
    local key = target:GetAddress()
    local k = mind.known[key]
    if not k then k = { progress = 0 } mind.known[key] = k end
    return k
end

-- Seconds to spot someone at distance d (cm) at a glance, before modifiers: about 0.15 s at 5 m to 1.5 s at 60 m.
local function baseSpotTime(d)
    return math.max(0.1, 0.15 + 0.0245 * (d / 100 - 5))
end

-- Noises: { at, time, radius (cm at hearing 1.0), kind, source = address }. Old ones age out.
local noises = {}
local NOISE_LIFE = 3

function AI.noise(at, radius, kind, source)
    local now = os.clock()
    noises[#noises + 1] = { at = { X = at.X, Y = at.Y, Z = at.Z }, time = now, radius = radius, kind = kind,
        source = source }
    while #noises > 0 and now - noises[1].time > NOISE_LIFE do table.remove(noises, 1) end
    if #noises > 64 then table.remove(noises, 1) end
end

-- Heard position: the true spot plus an error growing with distance (dispersion: exact within 10 m,
-- then linear, capped at 50 m), halved when facing the noise and x1.5 when it's behind.
local function disperse(mind, here, fwd, at, d)
    local err = math.min(5000, math.max(50, (d - 1000) * 0.1)) * mind.profile.dispersion
    if d > 1 then
        local cos = (fwd.X * (at.X - here.X) + fwd.Y * (at.Y - here.Y)) / math.max(1, len2(at.X - here.X, at.Y - here.Y))
        err = err * (cos > 0.7 and 0.5 or (cos < -0.3 and 1.5 or 1))
    end
    local a, r = math.random() * 2 * math.pi, math.random() * err
    return { X = at.X + math.cos(a) * r, Y = at.Y + math.sin(a) * r, Z = at.Z }
end

-- Footstep radius (cm at hearing 1.0) from the target's speed and posture.
local function footsteps(target)
    local v = target:GetVelocity()
    local s = len2(v.X, v.Y)
    if s < 50 then return 0 end
    if target.bIsCrouched then return 500 end
    if s > 450 then return 3500 end
    if s > 200 then return 2000 end
    return 1000
end

-- What the bot noticed about the target this update. Returns "spotted", "heard" (with the heard position and
-- the kind of noise) or nil. dt = seconds since the last call for this bot.
function AI.perceive(e, target, targetLoc, now, dt)
    local mind, bot, ctrl = e.mind, e.bot, e.ctrl
    local prof = mind.profile
    local k = knowledge(mind, target)
    local here = bot:K2_GetActorLocation()
    local dx, dy, dz = targetLoc.X - here.X, targetLoc.Y - here.Y, targetLoc.Z - here.Z
    local flat = len2(dx, dy)
    local d = math.sqrt(flat * flat + dz * dz)
    local fwd = bot:GetActorForwardVector()

    -- Sight: progress toward "spotted" while in view, faded while not.
    local tv = target:GetVelocity()
    local moving = len2(tv.X, tv.Y) > 100
    local range = prof.sight * (moving and 1.5 or 1)
    local inView = false
    local cos = d > 1 and (fwd.X * dx + fwd.Y * dy + fwd.Z * dz) / d or 1
    local angle = math.deg(math.acos(math.max(-1, math.min(1, cos))))
    if d <= range and angle <= prof.halfAngle then
        inView = ctrl:LineOfSightTo(target, { X = 0, Y = 0, Z = 0 }, false)
    end
    if inView then
        local m = prof.spotTime
        if moving then m = m * 0.5 end
        if target.bIsCrouched then m = m * 1.25 end
        -- peripheral vision: faster dead ahead, up to 2x slower toward the edge of the cone
        if angle <= 3 then m = m * 0.66
        elseif angle <= 6 then m = m * 0.8
        elseif angle > 30 then m = m * (1 + (angle - 30) / math.max(1, prof.halfAngle - 30)) end
        if d < 500 then m = m * 0.8 elseif d < 1000 then m = m * 0.9 end
        -- elevation: above (up to 60 deg) up to 2.5x slower, below (up to 30 deg) down to 0.75x
        local elev = math.deg(math.atan(dz, math.max(1, flat)))
        if elev > 0 then m = m * (1 + 1.5 * math.min(elev, 60) / 60)
        else m = m * (1 - 0.25 * math.min(-elev, 30) / 30) end
        -- under fire (hurt or a shot close by in the last 3 s): twice as fast
        if now - (k.underFire or -99) < 3 then m = m * 0.5 end
        -- re-acquiring near where they were last seen / heard
        if k.seenAt and now - k.seenTime < 30 then
            local ds = X.dist(targetLoc, k.seenAt)
            if ds < 2500 then m = m * math.max(0.01, ds / 2500) end
        elseif k.heardAt and now - k.heardTime < 20 then
            local dh = X.dist(targetLoc, k.heardAt)
            if dh < 2000 then m = m * (0.2 + 0.8 * dh / 2000) end
        end
        -- the target looking away from the bot
        local tf = target:GetActorForwardVector()
        if d > 1 and -(tf.X * dx + tf.Y * dy + tf.Z * dz) / d < 0.7 then m = m * 1.1 end
        k.progress = k.progress + dt / (baseSpotTime(d) * m)
        if k.progress >= 1 then
            k.progress, k.seenAt, k.seenTime, k.spottedIn = 1, targetLoc, now, now - (k.viewSince or now)
            return "spotted", d
        end
        k.viewSince = k.viewSince or now
    else
        k.progress = math.max(0, k.progress - dt / 2.5)
        if k.progress == 0 then k.viewSince = nil end
    end

    -- Hearing: footsteps (this update) and recent noises the bot hasn't processed yet.
    local blocked = not inView
    local heard, kind
    local r = footsteps(target) * prof.hearing * (blocked and 0.6 or 1)
    if d <= r then heard, kind = targetLoc, "footsteps" end
    local key = target:GetAddress()
    for i = #noises, 1, -1 do
        local n = noises[i]
        if n.time <= (k.heardUpTo or 0) then break end
        local nd = X.dist(here, n.at)
        if n.kind == "gunshot" and nd < 1500 and n.source == key then k.underFire = n.time end
        if n.source == key and nd <= n.radius * prof.hearing * (blocked and 0.8 or 1) then
            heard, kind = n.at, n.kind
            break
        end
    end
    k.heardUpTo = now -- per enemy: a bot sizes up several enemies each update
    if heard then
        local hd = X.dist(here, heard)
        k.heardAt, k.heardTime, k.heardKind = disperse(mind, here, fwd, heard, hd), now, kind
        return "heard", hd, k.heardAt, kind
    end
    return nil
end

-- The bot got hurt: it knows roughly where from, and spots the shooter faster.
function AI.hurt(e, target, now)
    local k = knowledge(e.mind, target)
    k.underFire = now
end

function AI.forget(e, target)
    e.mind.known[target:GetAddress()] = nil
end

-- The bot's miss rate right now. AIMissRate is the one accuracy dial the game gives us (the shot itself is native), so
-- variety comes from driving it: a skill rolled once per bot, hot and cold streaks, and the situation.
-- o: skillSpread, streak, streakSeconds, settleSeconds, settlePenalty, movingPenalty, targetMovingPenalty,
-- hurtPenalty, hurtSeconds, rangePer10m, maxMiss; moving, targetMoving, distance, losSince, hurtAt.
function AI.aimFor(e, now, o)
    e.aimRoll = e.aimRoll or (math.random() * 2 - 1)
    if now >= (e.aimStreakUntil or 0) then
        e.aimStreak = math.random() * 2 - 1
        e.aimStreakUntil = now + rnd(o.streakSeconds)
    end
    local m = (e.mind.profile.miss or 0.85) * math.max(0.1, 1 + e.aimRoll * o.skillSpread)
        * math.max(0.1, 1 + e.aimStreak * o.streak)
    if o.moving then m = m * o.movingPenalty end
    if o.targetMoving then m = m * o.targetMovingPenalty end
    if o.hurtAt and now - o.hurtAt < o.hurtSeconds then m = m * o.hurtPenalty end
    m = m * (1 + o.rangePer10m * o.distance / 1000)
    if o.losSince and o.settleSeconds > 0 then
        local t = math.min(1, (now - o.losSince) / o.settleSeconds)
        m = m * (o.settlePenalty + (1 - o.settlePenalty) * t)
    end
    return math.min(o.maxMiss, m)
end

function AI.reactionTime(e)
    return rnd(e.mind.profile.reaction)
end

-- Seconds to stay frozen after hearing something while at peace.
function AI.freezeTime(e)
    local p = e.mind.personality
    return rnd(p.freeze)
end

function AI.describe(e)
    return ("%s/%s"):format(e.mind.profileName, e.mind.personalityName)
end

function AI.init(ctx) X = ctx end

return AI
