-- Shots that land on the reticle, at the distance of whatever is under it.
-- A shell leaves the barrel, which sits about 1.5 m under the helm camera, so a shell flown parallel to your view runs that far
-- below the crosshair at every range (measured 2026-11-22: 1.49 m below the view line from 35 m to 136 m, 11 px low at 222 m on a
-- 1440p screen). The game bends the helm shot toward what is under the crosshair, but only for things its own check finds (about 1
-- degree up at 90 m), and a gun seat's shot was aimed at a point 600 m out, right at 600 m only.
-- Here a shot still leaves the barrel (its trail starts at the turret) but is aimed at the point on your view line where
-- the view hits something, found with a line trace out to FAR (3 km; nothing hit: that far point), so it passes through the
-- crosshair exactly at the distance of the thing you are aiming at. A shot is only changed when it is yours: the helm click (a
-- flag set while RaidFrigate::ServerFireFrigate runs, on the ship you are flying) or the gun seat (gunseat.lua calls aimDir itself).
-- Crew gunners and rival ships are left as they are. CFG.ON = false leaves the game's shots alone.
local M = {}
local log, valid, lib
local Out = require("outref")
local CFG = { ON = true, START = 1500, FAR = 300000 } -- trace from 15 m out (past your own turrets) to 3 km
M.CFG = CFG
M.helmAt = -1e9 -- os.clock() of the last helm click; a shot within HELM_WINDOW of it is the helm's own
local HELM_WINDOW = 0.05
local SYS
local COLOR = { R = 1, G = 0, B = 0, A = 1 }
local traceErr

-- Distance along the view (c = camera, f = view direction) to what is under the crosshair, FAR if nothing; nil if the trace failed.
local function viewDistance(ship, c, f)
    if not (SYS and SYS:IsValid()) then SYS = lib("/Script/Engine.Default__KismetSystemLibrary") end
    local from = { X = c.X + f.X * CFG.START, Y = c.Y + f.Y * CFG.START, Z = c.Z + f.Z * CFG.START }
    local to = { X = c.X + f.X * CFG.FAR, Y = c.Y + f.Y * CFG.FAR, Z = c.Z + f.Z * CFG.FAR }
    local hit = {}
    local ok, r = pcall(function()
        return Out.call(SYS, "LineTraceSingle", ship, from, to, 0, false, {}, 0, hit, true, COLOR, COLOR, 0) -- (the ship itself is left out)
    end)
    if not ok then
        if not traceErr and log then traceErr = true log("[helmaim] view trace failed: " .. tostring(r)) end
        return nil
    end
    if r ~= true then return CFG.FAR end
    local d
    pcall(function() d = CFG.START + hit.Distance end)
    if not d then
        pcall(function()
            local p = hit.ImpactPoint
            d = math.sqrt((p.X - c.X) ^ 2 + (p.Y - c.Y) ^ 2 + (p.Z - c.Z) ^ 2)
        end)
    end
    return d
end

-- The direction from barrel o to the point under the crosshair; nil leaves the shot as it was. ship: the ship you fly (world context
-- of the trace, left out of it), c: the camera's location, f: its direction.
function M.aimDir(ship, o, c, f)
    if not CFG.ON then return nil end
    local d = viewDistance(ship, c, f)
    if not d then return nil end
    local dx, dy, dz = c.X + f.X * d - o.X, c.Y + f.Y * d - o.Y, c.Z + f.Z * d - o.Z
    local n = math.sqrt(dx * dx + dy * dy + dz * dz)
    if n < 1 then return nil end
    return { X = dx / n, Y = dy / n, Z = dz / n }
end

function M.init(ctx)
    log, valid, lib = ctx.log, ctx.valid, ctx.lib
    local ok1, e1 = pcall(RegisterHook, "/Script/RaidGame.RaidFrigate:ServerFireFrigate",
        function() M.helmAt = os.clock() end, function() M.helmAt = -1e9 end)
    local ok2, e2 = pcall(RegisterHook, "/Script/RaidGame.RaidCharacterTurrent:ServerFireProjectile", function(ctx2, originP, dirP)
        if not CFG.ON or os.clock() - M.helmAt > HELM_WINDOW then return end
        local ok, err = pcall(function()
            local t = ctx2:get()
            local ship = t.MyFrigateOwner
            local pc = lib("/Script/Engine.Default__GameplayStatics"):GetPlayerController(t, 0)
            if not (valid(pc) and valid(pc.Pawn) and valid(ship) and pc.Pawn:GetAddress() == ship:GetAddress()) then return end
            local pcm = pc.PlayerCameraManager
            local c, r = pcm:GetCameraLocation(), pcm:GetCameraRotation()
            local cp, sp = math.cos(math.rad(r.Pitch)), math.sin(math.rad(r.Pitch))
            local f = { X = cp * math.cos(math.rad(r.Yaw)), Y = cp * math.sin(math.rad(r.Yaw)), Z = sp }
            local dir = M.aimDir(ship, originP:get(), c, f)
            if dir then dirP:set(dir) end
        end)
        if not ok and log and not M.failed then M.failed = true log("[helmaim] shot not adjusted: " .. tostring(err)) end
    end)
    if log and not (ok1 and ok2) then log("[helmaim] hooks not set: " .. tostring(e1) .. " / " .. tostring(e2)) end
end

return M
