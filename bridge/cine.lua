-- Trailer camera: a CameraActor the player controller views through, animated every frame from the controller's
-- ReceiveTick. Load with dofile, then e.g.:
--   CINE.orbit(actor, {r=3000, h=600, a0=0, a1=90, dur=8, fov=60})
--   CINE.chase(actor, {back=2500, up=500, side=0, dur=8})
--   CINE.dolly(actor, {from={X=..}, to={X=..}, dur=6})        -- absolute points, looking at the actor
--   CINE.track(actor, {at={X=..}, dur=6})                       -- fixed spot, turning to follow the actor
--   CINE.stop()                                                -- back to the player's own view
-- `actor` may be a function returning an actor or a location {X,Y,Z} (re-evaluated each frame).
CINE = CINE or {}
local C = CINE

local function ok(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function pc() return FindFirstOf("MainPlayerController_C") end
local function lerp(a, b, t) return a + (b - a) * t end
local function ease(t) return t * t * (3 - 2 * t) end
local function vlerp(a, b, t) return { X = lerp(a.X, b.X, t), Y = lerp(a.Y, b.Y, t), Z = lerp(a.Z, b.Z, t) } end
local function lookAt(from, to)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    return { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
end

local function target(s)
    local a = s.actor
    if type(a) == "function" then a = a() end
    if type(a) == "table" and a.X then s.last, s.lastRot = a, s.lastRot or { Pitch = 0, Yaw = 0, Roll = 0 }
    elseif ok(a) then s.last = a:K2_GetActorLocation() s.lastRot = a:K2_GetActorRotation() end
    return s.last, s.lastRot
end

local function camera()
    if ok(C.cam) then return C.cam end
    local p = pc()
    local cls = StaticFindObject("/Script/Engine.CameraActor")
    C.cam = p:GetWorld():SpawnActor(cls, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    return C.cam
end

-- Hide / show the HUD and every on-screen widget (restored by C.hud(true)).
function C.hud(show)
    local p = pc()
    if ok(p.MyHUD) then p.MyHUD.bShowHUD = show end
    if not show then
        C.hidden = {}
        for _, w in ipairs(FindAllOf("UserWidget") or {}) do
            if ok(w) and w:IsInViewport() and w:GetVisibility() ~= 1 and w:GetVisibility() ~= 2 then
                C.hidden[#C.hidden + 1] = { w = w, v = w:GetVisibility() }
                w:SetVisibility(2) -- Hidden
            end
        end
    else
        for _, h in ipairs(C.hidden or {}) do if ok(h.w) then h.w:SetVisibility(h.v) end end
        C.hidden = nil
    end
end

local function frame()
    local s = C.shot
    if not s then return end
    local now = os.clock()
    local t = math.min(1, (now - s.t0) / s.dur)
    local e = s.linear and t or ease(t)
    local loc, rot = target(s)
    if not loc then return end
    local aim = { X = loc.X, Y = loc.Y, Z = loc.Z + (s.aimUp or 0) }
    local at
    if s.kind == "orbit" then
        local a = math.rad(lerp(s.a0, s.a1, e) + (s.relative and rot.Yaw or 0))
        local r = lerp(s.r, s.r1 or s.r, e)
        at = { X = loc.X + math.cos(a) * r, Y = loc.Y + math.sin(a) * r, Z = loc.Z + lerp(s.h, s.h1 or s.h, e) }
    elseif s.kind == "chase" then
        local yaw = math.rad(rot.Yaw)
        local back, side = lerp(s.back, s.back1 or s.back, e), lerp(s.side or 0, s.side1 or s.side or 0, e)
        at = { X = loc.X - math.cos(yaw) * back - math.sin(yaw) * side,
               Y = loc.Y - math.sin(yaw) * back + math.cos(yaw) * side,
               Z = loc.Z + lerp(s.up, s.up1 or s.up, e) }
        aim = { X = loc.X + math.cos(yaw) * (s.lead or 0), Y = loc.Y + math.sin(yaw) * (s.lead or 0), Z = aim.Z }
    elseif s.kind == "duel" then
        -- behind `actor`, on the line from its target (`other`), looking past it at the target
        local o = type(s.other) == "function" and s.other() or s.other
        if ok(o) then s.otherLoc = o:K2_GetActorLocation() end
        local b = s.otherLoc or aim
        local dx, dy, dz = loc.X - b.X, loc.Y - b.Y, loc.Z - b.Z
        local len = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
        local back, side = lerp(s.back, s.back1 or s.back, e), lerp(s.side or 0, s.side1 or s.side or 0, e)
        local px, py = -dy / len, dx / len -- horizontal perpendicular
        at = { X = loc.X + dx / len * back + px * side, Y = loc.Y + dy / len * back + py * side,
               Z = loc.Z + dz / len * back + lerp(s.up, s.up1 or s.up, e) }
        local w = s.aimMix or 0.35 -- aim between the two, nearer the shooter
        aim = { X = loc.X + (b.X - loc.X) * w, Y = loc.Y + (b.Y - loc.Y) * w, Z = loc.Z + (b.Z - loc.Z) * w }
    elseif s.kind == "trail" then
        -- on the path the target walked: the point `back` units behind it along its own trail (open space,
        -- so the camera stays out of walls in corridors)
        s.trail = s.trail or {}
        local tr = s.trail
        local lastp = tr[#tr]
        if not lastp or (loc.X - lastp.X) ^ 2 + (loc.Y - lastp.Y) ^ 2 > 400 then tr[#tr + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z } end
        local back = lerp(s.back, s.back1 or s.back, e)
        local need, prev = back, loc
        at = nil
        for i = #tr, 1, -1 do
            local q = tr[i]
            local d = math.sqrt((q.X - prev.X) ^ 2 + (q.Y - prev.Y) ^ 2)
            if d >= need then
                local f = need / d
                at = { X = prev.X + (q.X - prev.X) * f, Y = prev.Y + (q.Y - prev.Y) * f, Z = prev.Z + (q.Z - prev.Z) * f }
                break
            end
            need, prev = need - d, q
        end
        at = at or { X = (tr[1] or loc).X, Y = (tr[1] or loc).Y, Z = (tr[1] or loc).Z }
        at = { X = at.X, Y = at.Y, Z = at.Z + lerp(s.up, s.up1 or s.up, e) }
        while #tr > 200 do table.remove(tr, 1) end
    elseif s.kind == "dolly" then
        at = vlerp(s.from, s.to, e)
    else -- track
        at = s.at
    end
    -- smooth the camera a little so ship jitter doesn't shake the shot
    if C.prev and not s.snap then at = vlerp(C.prev, at, s.smooth or 0.35) end
    s.snap = false
    C.prev = at
    local r = lookAt(at, aim)
    r.Roll = lerp(s.roll or 0, s.roll1 or s.roll or 0, e)
    camera():K2_SetActorLocationAndRotation(at, r, false, {}, true)
    if t >= 1 and s.hold == false then C.shot = nil end
end

C.frame = frame

function C.start(kind, actor, o)
    o = o or {}
    o.kind, o.actor, o.t0, o.dur = kind, actor, os.clock(), o.dur or 8
    o.snap = true
    C.shot = o
    C.prev = nil
    local p = pc()
    local cam = camera()
    if ok(cam.CameraComponent) then
        cam.CameraComponent.FieldOfView = o.fov or 70
        cam.CameraComponent.bConstrainAspectRatio = false
    end
    frame()
    p:SetViewTargetWithBlend(cam, 0, 0, 0, false)
    if not C.hudOff then C.hud(false) C.hudOff = true end
    return "shot " .. kind
end
function C.orbit(a, o) o = o or {} o.r, o.h, o.a0, o.a1 = o.r or 3000, o.h or 500, o.a0 or 0, o.a1 or 60 return C.start("orbit", a, o) end
function C.chase(a, o) o = o or {} o.back, o.up = o.back or 2500, o.up or 500 return C.start("chase", a, o) end
function C.duel(a, b, o) o = o or {} o.other, o.back, o.up = b, o.back or 600, o.up or 150 return C.start("duel", a, o) end
function C.trail(a, o) o = o or {} o.back, o.up = o.back or 250, o.up or 80 return C.start("trail", a, o) end
function C.dolly(a, o) return C.start("dolly", a, o) end
function C.track(a, o) return C.start("track", a, o) end

function C.stop()
    C.shot = nil
    local p = pc()
    if ok(p.Pawn) then p:SetViewTargetWithBlend(p.Pawn, 0, 0, 0, false) end
    if C.hudOff then C.hud(true) C.hudOff = false end
    return "camera back"
end

if not C.hooked then
    RegisterHook("/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:ReceiveTick", function()
        CINE.ticks = (CINE.ticks or 0) + 1
        if CINE.shot and CINE.frame then pcall(CINE.frame) end
    end)
    C.hooked = true
end
-- per-world reset: the camera actor dies with the world
C.cam = ok(C.cam) and C.cam or nil
return "cine ready"
