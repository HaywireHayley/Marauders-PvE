-- Manning a turret yourself (the gunner seat). Using the seat works natively offline: your view moves to the turret's
-- camera and the turret records you (pawn.MYTurret, turret.ControllerHere). The rest is client code that never runs
-- offline: the camera doesn't turn, the fire button does nothing, the seat's
-- TurretControlUsing / OnRep_SetGunning (sitting animation) never happen, and F doesn't get you up again. This does it:
-- the camera swings to where you look, the fire button fires its own ServerFireProjectile along your view (its shells,
-- effects and damage) at its own fire rate, magazine and reload, and F stands you up.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local G = {}
local X -- context from main.lua

local CFG = {
    FIRE_KEY = "LeftMouseButton",
    USE_KEY = "F",
    LEAVE_AFTER = 0.5,          -- seconds seated before F gets you up (the F that sat you down is still held)
    LEAVE_BLEND = 0.3,          -- view blend back to your body
    TEST_EVERY = 0.5,           -- seconds between checks of the bridge test files below
    AIM_RANGE = 60000,          -- shots converge on the crosshair this far out
}
-- Bridge tests (no real input): while gunseat_fire exists the fire button counts as held; gunseat_leave = one F press.
local TEST_FIRE = PROJECT .. "bridge/gunseat_fire"
local TEST_LEAVE = PROJECT .. "bridge/gunseat_leave"
G.CFG = CFG

local S -- while seated: { body, turret, comp, socks, si, left, ammo, rate, reload, next, at, fDown }

local function valid(o) return X.valid(o) end

local function keyDown(pc, k)
    local down = false
    pcall(function() down = pc:IsInputKeyDown({ KeyName = FName(k) }) end)
    return down
end

local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end

local function name(o) local n = "?" pcall(function() n = o:GetFName():ToString() end) return n end

-- The seat's control component: what you pressed F on (InteractionDetection keeps it in LastInteractionComp).
local function seatComp(body)
    local c
    pcall(function()
        local x = body.LastInteractionComp
        if valid(x) and x:GetClass():GetFName():ToString():find("TurretConrtrol", 1, true) then c = x end
    end)
    return c
end

local function sit(pc, body, t)
    local socks = {}
    pcall(function() t.FiringSockets:ForEach(function(_, e) socks[#socks + 1] = e:get():ToString() end) end)
    S = { body = body, turret = t, socks = socks, si = 1, ammo = math.max(1, t.TotalAmmo), rate = t.FireRate,
        reload = t.ReloadTime, next = 0, at = os.clock(), fDown = true }
    S.left = (t.AmmoLeft and t.AmmoLeft > 0) and t.AmmoLeft or S.ammo
    S.comp = seatComp(body)
    -- what the server's seat code would have sent: the seat in TurretControlUsing, then the sitting animation
    if S.comp then
        pcall(function() body:SendGunnerSeatOnRep(S.comp) end)
        pcall(function() body.TurretControlUsing = S.comp end)
    end
    pcall(function() body:OnRep_SetGunning() end)
    pcall(function() t.IsOccupied = true end)
    pcall(function() pc:TurretFirstTimeOpen() end)
    pcall(function() pc:RefreshTurretInfo() end)
    X.log(("[gunseat] you man %s (%d barrel(s), %d rounds, seat %s)"):format(name(t), #socks, S.left,
        S.comp and name(S.comp) or "?"))
end

-- Stands you up: view back to your body and the turret free again (also used when the seat state goes away under you).
local function stand(pc, why)
    if not S then return end
    local body, t = S.body, S.turret
    if valid(body) then
        if valid(pc) then pcall(function() pc:SetViewTargetWithBlend(body, CFG.LEAVE_BLEND, 0, 0, false) end) end
        pcall(function() body.MYTurret = nil end)
        pcall(function() body.TurretControlUsing = nil end)
        pcall(function() body.CurrentTurret = nil end)
        pcall(function() body:TurnOffTheGunner() end)
    end
    if valid(t) then
        pcall(function()
            if valid(pc) and t.ControllerHere and t.ControllerHere:IsValid()
                and t.ControllerHere:GetAddress() == pc:GetAddress() then t.ControllerHere = nil end
        end)
        pcall(function() t.IsOccupied = false end)
    end
    X.log("[gunseat] you leave the turret (" .. why .. ")")
    S = nil
end

-- The barrel already follows your mouse (its AnimBP reads your view: rivals.lua aimTurret), but the seat's camera
-- hangs on a SpringArm that only the server's seat code turned, so it stared one way. It's swung to your view here
-- (pitch kept within the camera's limits off the hull), and that's the way you shoot.
local function view(pc, t)
    local r = pc:GetControlRotation()
    local pitch = (r.Pitch + 180) % 360 - 180
    local lo, hi = t.CameraMinPitch, t.CameraMaxPitch
    local hull = t:GetAttachParentActor()
    if lo and hi and lo < hi and valid(hull) then
        local hp = hull:K2_GetActorRotation().Pitch
        pitch = math.max(hp + lo, math.min(hp + hi, pitch))
    end
    local rot = { Pitch = pitch, Yaw = r.Yaw, Roll = 0 }
    pcall(function() Out.call(t.SpringArm, "K2_SetWorldRotation", rot, false, {}, true) end)
    local p, y = math.rad(pitch), math.rad(r.Yaw)
    return { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
end

-- Along your view: from the barrel to the point under the crosshair (far off, so the barrel/camera offset washes out).
local function shotDir(t, sock, look)
    local c = t.Camera:K2_GetComponentLocation()
    local o = t.TurretBarrelMesh:GetSocketLocation(FName(sock))
    local a = { X = c.X + look.X * CFG.AIM_RANGE, Y = c.Y + look.Y * CFG.AIM_RANGE, Z = c.Z + look.Z * CFG.AIM_RANGE }
    local dx, dy, dz = a.X - o.X, a.Y - o.Y, a.Z - o.Z
    local n = math.sqrt(dx * dx + dy * dy + dz * dz)
    if n < 1 then return o, look end
    return o, { X = dx / n, Y = dy / n, Z = dz / n }
end

local function fire(pc, t, look, now)
    if now < S.next then return end
    local sock = S.socks[S.si] or "Soc_Barrel01"
    local o, dir = shotDir(t, sock, look)
    local ok, err = pcall(function() t:ServerFireProjectile(o, dir, S.si - 1) end)
    if not ok then
        if not S.fireErr then S.fireErr = true X.log("[gunseat] firing failed: " .. tostring(err)) end
        S.next = now + 1
        return
    end
    S.si = S.si % math.max(1, #S.socks) + 1
    S.left = S.left - 1
    local wait = S.rate
    if S.left <= 0 then S.left, wait = S.ammo, S.reload end
    S.next = now + wait
    pcall(function() t.AmmoLeft = S.left end)
    -- the HUD's ammo/reload readout, and what tells rivals you fired (rivals.lua hooks OnClientFiredTurret)
    pcall(function() pc:ClientFiredTurret(wait) end)
end

-- Every frame in a space raid, from the player controller.
function G.frame(pc)
    if not valid(pc) then S = nil return end
    if S and not (valid(S.body) and valid(S.turret)) then S = nil end -- a new raid (map travel freed them)
    local body = pc.Pawn
    local t
    pcall(function() if valid(body) then t = body.MYTurret end end)
    if not valid(t) then
        if S then stand(pc, "seat state gone") end
        return
    end
    if S and (S.turret:GetAddress() ~= t:GetAddress() or S.body:GetAddress() ~= body:GetAddress()) then
        stand(pc, "another turret")
    end
    if not S then sit(pc, body, t) end
    if (body.Health or 0) <= 0 then stand(pc, "dead") return end
    local now = os.clock()
    if now >= (S.testAt or 0) then
        S.testAt = now + CFG.TEST_EVERY
        S.testFire = exists(TEST_FIRE)
        if exists(TEST_LEAVE) then os.remove(TEST_LEAVE) stand(pc, "F (bridge test)") return end
    end
    local f = keyDown(pc, CFG.USE_KEY)
    if f and not S.fDown and now - S.at >= CFG.LEAVE_AFTER then stand(pc, "F") return end
    S.fDown = f
    local ok, look = pcall(view, pc, t)
    if not ok then
        if not S.viewErr then S.viewErr = true X.log("[gunseat] view failed: " .. tostring(look)) end
        look = t.Camera:GetForwardVector()
    end
    if S.testFire or keyDown(pc, CFG.FIRE_KEY) then fire(pc, t, look, now) end
end

-- The turret you're sitting at, or nil (crew.lua leaves it alone).
function G.seated() return S and valid(S.turret) and S.turret or nil end

function G.reset() S = nil end

function G.init(ctx) X = ctx end

return G
