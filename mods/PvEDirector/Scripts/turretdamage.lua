-- Full ship turret damage: impact + explosion.
-- Offline, the game's shells land only the ExplosionDamage half of their damage on a ship: the HitDamage (impact) half never
-- arrives, so every turret did a fraction of its listed damage (measured 2026-11-21: Singular 45 of 65, Dual25mm 50 of 70, 75mm
-- 120 of 170, Triple 90 of 155, Howitzer 125 of 225, Flak 70 of 85, Rocket Artillery 70 of 85, Dual Rocket 85 of 235, Torpedo 300
-- of 600, the same at 20 m and 55 m; GameplayStatics:ApplyDamage straight on a hull works, so the hull side is fine).
-- The fix is on the turret's ProjectileConfig.ExplosionDamage, which is what lands: it is set to impact + explosion on each
-- turret class's defaults (so every turret made afterwards has it, the mod's fitted ones included) and on the turrets already on
-- your ship. Checked in game: fresh turrets landed exactly 65, 170 and 600 afterwards, and the Nuclear launcher takes a hull
-- whole either way. Blast radius, fire rate and reload are untouched. CFG.FULL_DAMAGE = 0 leaves the game's numbers alone.
local M = {}
local log, valid

local CFG = { FULL_DAMAGE = 1 } -- 1 = on, 0 = off
M.CFG = CFG

local TP = "/Game/Blueprints/Ships_Extras/Turrets/"
-- turret class -> impact + explosion, from the game's own turret and shell assets (they match the wiki)
local TOTAL = {
    InGame_Turret_SingleTurret01 = 65, InGame_Turret_Dual25mm01 = 70, InGame_75mm_Turret01 = 170,
    InGame_Turret_TrippleTurret01 = 155, InGame_Turret_Howitzer01 = 225, InGame_Turret_FlakCannon01 = 85,
    InGame_Turret_RocketArtillery01 = 85, InGame_Turret_DualRocket01 = 235, InGame_Turret_TorpedoLauncher = 600,
    InGame_Turret_NuclearLauncher = 3100,
}
M.TOTAL = TOTAL

local st = { done = {}, req = nil, tries = 0, nextAt = 0, nextShip = 0, nextCdo = 0 }

function M.init(ctx) log, valid = ctx.log, ctx.valid end
function M.reset() st.nextShip = 0 end -- (the class defaults last as long as the game does; a new raid's ship is looked at again)

local function findClass(name)
    local c = StaticFindObject(TP .. name .. "." .. name .. "_C")
    return (c and c:IsValid()) and c or nil
end

-- An instance (a turret the mod fits, or one on your ship): sets its own copy.
function M.fit(turret, className)
    if CFG.FULL_DAMAGE == 0 then return end
    local total = TOTAL[className]
    if not total then return end
    pcall(function() turret.ProjectileConfig.ExplosionDamage = total end)
end

-- Every tick from the rivals update (space raids); does its own throttling. ship: your ship (may be nil).
function M.update(ship)
    if CFG.FULL_DAMAGE == 0 then return end
    local now = os.clock()
    if now < st.nextAt then return end
    st.nextAt = now + 1
    local pending = 0
    for name in pairs(TOTAL) do if not st.done[name] then pending = pending + 1 end end
    if pending > 0 and st.tries < 6 then
        if not st.req then
            -- classes nothing has used yet are loaded on request and are there a few seconds later
            st.req = now
            for name in pairs(TOTAL) do
                if not st.done[name] and not findClass(name) then pcall(LoadAsset, TP .. name .. "." .. name) end
            end
        elseif now - st.req >= 3 then
            st.req = nil
            st.tries = st.tries + 1
            for name, total in pairs(TOTAL) do
                if not st.done[name] then
                    local cls = findClass(name)
                    if cls then
                        local ok = pcall(function() cls:GetCDO().ProjectileConfig.ExplosionDamage = total end)
                        if ok then st.done[name] = true end
                    end
                end
            end
            local n = 0
            for _ in pairs(st.done) do n = n + 1 end
            if log then log(("full turret damage: %d of %d turret kinds set (try %d)"):format(n, 10, st.tries)) end
        end
    end
    -- the game unloads a turret class nothing is using and loads it again fresh later, which puts its default back: look
    -- at the classes that are loaded now and set any that read wrong
    -- StaticFindObject is cheap for a loaded class but ~28 ms for one that isn't (it searches every object): five
    -- unloaded turret classes made this a ~140 ms hitch every 5 s (#521, timed in game 2026-11-26). So a class found is
    -- kept and only checked for validity, and at most one class that isn't kept is looked up per pass.
    if now >= st.nextCdo then
        st.nextCdo = now + 5
        st.cls = st.cls or {}
        if not st.names then
            st.names = {}
            for name in pairs(TOTAL) do st.names[#st.names + 1] = name end
            table.sort(st.names)
            st.rr = 0
        end
        -- the one missing class looked up this pass: the next in turn, so one that stays unloaded doesn't starve the rest
        local want
        for k = 1, #st.names do
            local name = st.names[(st.rr + k - 1) % #st.names + 1]
            local kept = st.cls[name]
            if st.done[name] and not (kept and valid and valid(kept)) then want = name st.rr = st.rr + k break end
        end
        for _, name in ipairs(st.names) do
            local total = TOTAL[name]
            local cls = st.cls[name]
            if cls and not (valid and valid(cls)) then cls = nil st.cls[name] = nil end
            if not cls and name == want then
                cls = findClass(name)
                st.cls[name] = cls
            end
            if cls then
                pcall(function()
                    local cdo = cls:GetCDO()
                    if cdo.ProjectileConfig.ExplosionDamage ~= total then
                        cdo.ProjectileConfig.ExplosionDamage = total
                        if log then log("full turret damage: " .. name .. " class set again after a reload") end
                    end
                end)
            end
        end
    end
    -- the turrets already on your ship, looked at every few seconds (they can be fitted a little after the raid starts)
    if now >= st.nextShip and valid(ship) then
        st.nextShip = now + 5
        pcall(function()
            ship.SpawnedTurretArray:ForEach(function(_, e)
                local t = e:get()
                if valid(t) then
                    local name = t:GetClass():GetFName():ToString():gsub("_C$", "")
                    local total = TOTAL[name]
                    if total and t.ProjectileConfig.ExplosionDamage ~= total then
                        t.ProjectileConfig.ExplosionDamage = total
                        if log then log("full turret damage: your ship's " .. name .. " set to " .. total) end
                    end
                end
            end)
        end)
    end
end

return M
