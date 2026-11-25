-- 40mm rounds that blew up in the shooter's hands (#360). Two causes, both seen in game on 2026-11-25:
-- 1. Offline every projectile gun fired two rounds at the same muzzle point (the client-predicted one and the server's);
--    a 40mm round detonated on its twin. pvepatch.c "FireWeapon no local projectile" now skips the local one.
-- 2. The one round left still went off on its first move, inside its shooter: nothing tells it to ignore the pawn and
--    gun that fired it offline. Here, right after ServerFireProjectile (which pvepatch lets run locally) has spawned
--    it, the round's collision is told to ignore both (IgnoreActorWhenMoving). Tested: the round flew down the corridor
--    and burst on the far wall (5 splash damage at that range); without it, 45 damage in your hands.
-- Rounds are pooled (RaidProjectile.PooledProjectile): the pool builds them once, so they're collected as they're
-- constructed (NotifyOnNewObject) instead of searched for per shot (a FindAllOf is ~50 ms). Only exploding rounds.
local M = {}
local X -- log, valid

local FIRE = "/Script/RaidGame.RaidWeapon:ServerFireProjectile"
local PROJECTILE = "/Script/RaidGame.RaidProjectile"

local rounds = {} -- every projectile the pools have built (dead ones dropped as they're met)
local logged = false

local function afterFire(ctx)
    local w = ctx:get()
    if not X.valid(w) then return end
    local pawn = w.MyPawn
    local wAddr = w:GetAddress()
    for i = #rounds, 1, -1 do
        local p = rounds[i]
        if not X.valid(p) then
            table.remove(rounds, i)
        elseif p.bDoesExplode and not p.bExploded then
            local owner = p.MyWeaponOwner
            if X.valid(owner) and owner:GetAddress() == wAddr then
                local c = p.CollisionComp
                if X.valid(c) then
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
