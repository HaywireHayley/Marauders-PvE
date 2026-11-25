-- 40mm rounds that blow up in the shooter's hands (#360; also the "40mm shell explodes at the muzzle offline" in NOTES).
-- A guess, not seen in game: the round is spawned at the muzzle, inside or touching its shooter's capsule, and offline
-- nothing tells it to ignore that pawn (on a live server the shooter is a remote client's pawn, and the client's copy of
-- the round is cosmetic), so its first move hits the shooter and it detonates at once (player and bots alike).
-- The fire RPC (ServerFireProjectile, which pvepatch lets run locally) comes before the round is spawned, so its weapon's
-- pawn is remembered for PENDING seconds; a RaidProjectile constructed in that window is told, on its root component,
-- to ignore that pawn when it moves (IgnoreActorWhenMoving, the same list a server's spawn with an Instigator fills).
-- Only projectile guns go through this RPC; trace-fire guns (most guns) never do.
local M = {}
local X -- log, valid

local FIRE = "/Script/RaidGame.RaidWeapon:ServerFireProjectile"
local PROJECTILE = "/Script/RaidGame.RaidProjectile"
local PENDING = 0.5 -- seconds a shot's pawn waits for its round

local shooter, shotAt = nil, -1
local logged = false

local function onNew(p)
    if not shooter or os.clock() - shotAt > PENDING then return end
    local pawn = shooter
    if not X.valid(pawn) then return end
    local root = p.RootComponent
    if not X.valid(root) then return end
    root:IgnoreActorWhenMoving(pawn, true)
    if not logged then
        logged = true
        X.log("launchers: a projectile round ignores its shooter (#360)")
    end
end

function M.init(ctx)
    X = ctx
    local ok = pcall(RegisterHook, FIRE, function(c)
        local w = c:get()
        if X.valid(w) and X.valid(w.MyPawn) then shooter, shotAt = w.MyPawn, os.clock() end
    end)
    local ok2 = pcall(NotifyOnNewObject, PROJECTILE, function(p)
        local okn, err = pcall(onNew, p)
        if not okn then X.log("launchers: " .. tostring(err)) end
    end)
    if not (ok and ok2) then X.log(("launchers: hook %s, notify %s"):format(tostring(ok), tostring(ok2))) end
end

return M
