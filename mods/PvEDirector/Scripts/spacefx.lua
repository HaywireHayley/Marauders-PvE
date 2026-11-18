-- Explosions and their sound for space objects (issue #15): turrets (flak, rocket, triple, radar dishes) and mines
-- (small and nuclear). Their Blueprints build the blast on the client side only, so offline, where the game is the
-- server and nothing replicates, a dying turret or a mine going off showed nothing and made no sound.
-- Decompiled 2026-11-18 (tools/offline-audit/kdis.py), see docs/internals/SPACE_OBJECT_DEATH.md for the flow:
--   SubNodeActorTurret_C ubergraph (OnDeathEvent): `if GetLocalRole() != 3` (ROLE_Authority) then
--     BeginDeferredActorSpawnFromClass(Exploder Class), FinishSpawningActor, PlaySoundAtLocation(Destroyed_Sound).
--   SubNodeActorMine_C ubergraph: radial damage first (that part runs), then the same role gate around the spawn of
--     Exploder Class and the Sound_Explode sound, then the mesh is hidden and the mine destroys itself (K2_DestroyActor).
-- Offline our role is 3, so both gates skip the effect. Each actor carries its own Exploder Class and sound, so this
-- hooks the moment the game reaches that point and does the skipped part by hand, per actor, from its own properties:
--   turrets: the native RaidSubNodeActor_Turret:NetOnDeathEvent (the BP's OnDeathEvent entry runs from it; the BP
--     functions themselves are not hooked, which is why this is a native hook that fires offline);
--   mines: Actor:K2_DestroyActor, for a *NodeMine* whose mesh is already hidden (hidden = it exploded; a mine that
--     is cleaned up with the level still shows its mesh and is left alone).
-- Both only spawn the exploder (particles and destructible; the exploder Blueprints have no audio) at the object's
-- place and play its sound there. Once per object (its address, for a few seconds, since addresses get reused).
-- Not hooked: ApplyRadialDamageWithFalloff (a first attempt at the mine; the game died on the nuclear mine with it).
local M = {}
local X -- log, valid, lib

local TURRET_DEATH = "/Script/RaidGame.RaidSubNodeActor_Turret:NetOnDeathEvent"
local DESTROY = "/Script/Engine.Actor:K2_DestroyActor"
local ONCE_FOR = 10 -- seconds an object's address stays remembered
local NO_ROT = { Pitch = 0, Yaw = 0, Roll = 0 }

local seen = {}
local function firstTime(actor)
    local key, now = actor:GetAddress(), os.clock()
    local at = seen[key]
    if at and now - at < ONCE_FOR then return false end
    seen[key] = now
    for k, t in pairs(seen) do
        if now - t > 60 then seen[k] = nil end
    end
    return true
end

-- The blast and its sound at the actor's place, from the actor's own "Exploder Class" and sound property.
local function explode(actor, soundKey, what)
    if not firstTime(actor) then return end
    local cls, snd = actor["Exploder Class"], actor[soundKey]
    local loc = actor:K2_GetActorLocation()
    local rot = actor:K2_GetActorRotation() or NO_ROT
    local name = actor:GetFName():ToString()
    local world = FindFirstOf("World")
    local spawned, played = false, false
    if X.valid(cls) and X.valid(world) then
        spawned = pcall(function() world:SpawnActor(cls, loc, rot) end)
    end
    local gs = X.lib("/Script/Engine.Default__GameplayStatics")
    if X.valid(snd) and gs then
        played = pcall(function() gs:SpawnSoundAtLocation(actor, snd, loc, NO_ROT, 1.0, 1.0, 0.0, nil, nil, true) end)
    end
    X.log(("space fx: %s %s (blast %s, sound %s)"):format(what, name, tostring(spawned), tostring(played)))
end

function M.init(ctx)
    X = ctx
    local okt, errt = pcall(RegisterHook, TURRET_DEATH, function(self)
        local ok, err = pcall(function()
            local a = self:get()
            if X.valid(a) then explode(a, "Destroyed_Sound", "turret destroyed") end
        end)
        if not ok then X.log("space fx: turret: " .. tostring(err)) end
    end)
    if not okt then X.log("space fx: turret hook failed: " .. tostring(errt)) end

    local okm, errm = pcall(RegisterHook, DESTROY, function(self)
        local ok, err = pcall(function()
            local a = self:get()
            if not X.valid(a) then return end
            if not a:GetClass():GetFName():ToString():find("NodeMine", 1, true) then return end
            local mesh = a.StaticMesh
            if X.valid(mesh) and not mesh:IsVisible() then explode(a, "Sound_Explode", "mine exploded") end
        end)
        if not ok then X.log("space fx: mine: " .. tostring(err)) end
    end)
    if not okm then X.log("space fx: mine hook failed: " .. tostring(errm)) end
end

return M
