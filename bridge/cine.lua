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
    elseif ok(a) then s.last = C.ahead(a) s.lastRot = a:K2_GetActorRotation() end
    return s.last, s.lastRot
end

-- The controller ticks before ships move, so a plain K2_GetActorLocation is a frame stale: the ship then jumps
-- against the camera, worst on a long frame. Push it on by velocity * this frame's time (C.dt, set per tick).
function C.ahead(a)
    local l = a:K2_GetActorLocation()
    local dt = C.dt or 0
    if dt <= 0 then return l end
    local okv, v = pcall(function() return a:GetVelocity() end)
    if not okv or not v then return l end
    return { X = l.X + v.X * dt, Y = l.Y + v.Y * dt, Z = l.Z + v.Z * dt }
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
        C.hidden = C.hidden or {}
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

local NOCOL = { R = 0, G = 0, B = 0, A = 0 }
function C.unblock(from, to, clear, ignore, rad)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len <= clear + 50 then return to end
    local ux, uy, uz = dx / len, dy / len, dz / len
    -- looked up once, never per frame: FindFirstOf every frame takes the game to ~20 fps
    if not ok(C.ksl) then C.ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    if not ok(C.ctx) then C.ctx = C.cam end
    if not ok(C.ctx) then return to end
    local a = { X = from.X + ux * clear, Y = from.Y + uy * clear, Z = from.Z + uz * clear }
    local out = {}
    local okc, hit = pcall(function()
        return C.ksl:SphereTraceSingle(C.ctx, a, to, rad or 80, 0, false, ignore or {}, 0, out, true, NOCOL, NOCOL, 0)
    end)
    if not (okc and hit) then return to end
    local d = clear + math.max(0, (out.Distance or 0) - (rad and rad * 2 or 120))
    C.blocked = (C.blocked or 0) + 1
    return { X = from.X + ux * d, Y = from.Y + uy * d, Z = from.Z + uz * d }
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
    elseif s.kind == "pair" then
        -- side-on to the line between two ships (the subject is their midpoint), far enough out that both fit in frame,
        -- following as the gap closes
        local A, B = s.pa, s.pb
        if ok(A) and ok(B) then
            local la, lb = A:K2_GetActorLocation(), B:K2_GetActorLocation()
            local dx, dy = lb.X - la.X, lb.Y - la.Y
            local hl = math.max(1, math.sqrt(dx * dx + dy * dy))
            local d = math.sqrt(dx * dx + dy * dy + (lb.Z - la.Z) ^ 2)
            s.pr = math.max(s.rmin or 12000, math.min(s.rmax or 45000, d * (s.k or 0.95)))
            s.pyaw = math.atan(dy, dx) + math.pi / 2
        end
        local r = s.pr or (s.rmin or 12000)
        s.clear = s.pclear or 2500 -- just past the hulls (the camera is side-on to them), so rocks near the fight count too
        local function spot(off, hk)
            local a = (s.pyaw or 0) + off + math.rad(lerp(s.a0 or -15, s.a1 or 15, e))
            return { X = loc.X + math.cos(a) * r, Y = loc.Y + math.sin(a) * r, Z = loc.Z + r * hk }
        end
        -- In an asteroid field the view is often blocked, and pulling the camera in to the rock looked like clipping into
        -- it: every 0.25 s, if the line from the fight to the camera is blocked, cut to the first clear angle around it.
        s.poff, s.phk = s.poff or 0, s.phk or (s.hk or 0.25)
        if now >= (s.pcheck or 0) then
            s.pcheck = now + 0.25
            local cur = spot(s.poff, s.phk)
            if C.unblock(loc, cur, s.clear) ~= cur then
                for _, off in ipairs({ 0, math.pi, 0.6, -0.6, math.pi + 0.6, math.pi - 0.6, 1.2, -1.2 }) do
                    local found
                    for _, hk in ipairs({ s.hk or 0.25, 0.6, -0.3 }) do
                        local c = spot(off, hk)
                        if C.unblock(loc, c, s.clear) == c then s.poff, s.phk, found = off, hk, true break end
                    end
                    if found then C.prev = nil s.cuts = (s.cuts or 0) + 1 break end
                end
            end
        end
        at = spot(s.poff, s.phk)
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
        if ok(o) then s.otherLoc = C.ahead(o) elseif type(o) == "table" and o.X then s.otherLoc = o end
        local b = s.otherLoc or aim
        local dx, dy, dz = loc.X - b.X, loc.Y - b.Y, loc.Z - b.Z
        local len = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
        local back, side = lerp(s.back, s.back1 or s.back, e), lerp(s.side or 0, s.side1 or s.side or 0, e)
        local px, py = -dy / len, dx / len -- horizontal perpendicular
        local up = lerp(s.up, s.up1 or s.up, e)
        local function spot(off) -- the back direction swung `off` radians around the shooter
            local c, sn = math.cos(off), math.sin(off)
            local ux, uy = dx / len, dy / len
            return { X = loc.X + (ux * c - uy * sn) * back + px * side, Y = loc.Y + (ux * sn + uy * c) * back + py * side,
                     Z = loc.Z + dz / len * back + up }
        end
        if s.infantry then
            -- indoors: every 0.2 s, if the spot behind the shooter is inside a wall or can't see the enemy, swing to the
            -- first clear angle around it (a cut), rather than squeezing the camera up against the wall
            local function clear(c)
                if C.unblock(loc, c, s.clear, s.ignore, s.rad) ~= c then return false end
                return C.unblock(b, c, s.clear, s.ignore, s.rad) == c
            end
            s.doff = s.doff or 0
            if now >= (s.dcheck or 0) then
                s.dcheck = now + 0.2
                if not clear(spot(s.doff)) then
                    for _, off in ipairs({ 0, 0.45, -0.45, 0.9, -0.9, 1.35, -1.35, 1.8, -1.8 }) do
                        if clear(spot(off)) then
                            if off ~= s.doff then s.doff, C.prev, s.cuts = off, nil, (s.cuts or 0) + 1 end
                            break
                        end
                    end
                end
            end
            at = spot(s.doff)
        else
            at = spot(0)
        end
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
    -- keep the camera out of rocks and hulls: sphere-trace from the subject out to the camera spot, and stop short of
    -- the first hit (the trace starts `clear` units out so the subject's own hull doesn't count). collide=false turns it off.
    if s.collide ~= false then at = C.unblock(loc, at, s.clear or 400, s.ignore, s.rad) end
    -- smooth the camera a little so ship jitter doesn't shake the shot
    -- (time-based, so a long frame doesn't leave the camera further behind than a short one)
    if C.prev and not s.snap then
        at = vlerp(C.prev, at, 1 - (1 - (s.smooth or 0.35)) ^ (math.max(0.001, C.dt or 1 / 60) * 60))
    end
    s.snap = false
    -- the smoothed point lags the target spot and can drift through a corner: trace it again
    if s.infantry then at = C.unblock(loc, at, s.clear, s.ignore, s.rad) end
    C.prev = at
    local r = lookAt(at, aim)
    r.Roll = lerp(s.roll or 0, s.roll1 or s.roll or 0, e)
    camera():K2_SetActorLocationAndRotation(at, r, false, {}, true)
    if t >= 1 and s.hold == false then C.shot = nil end
end

-- the social overlay (friend toasts) pops back up mid-shot: hidden again every ~2 s. It is found once, at load (below):
-- any FindAllOf costs 35+ ms, and re-hiding every widget (C.hud) ~75 ms; either showed as a stutter.
C.frame = function()
    local now = os.clock()
    C.dt = C.tickAt and math.min(0.1, now - C.tickAt) or 0
    C.tickAt = now
    -- An infantry fighter down: end the shot now. Its body is destroyed ~3 s later and freed after that, and any look
    -- at a freed actor (even IsValid) can crash inside UE4SS.
    local s = C.shot
    if s.infantry then
        for _, b in ipairs({ s.actor, type(s.other) ~= "function" and s.other or nil }) do
            if (b.Health or 0) <= 0 then C.stop() C.ended = "a fighter died" return end
        end
    end
    frame()
    C.n = (C.n or 0) + 1
    if C.hudOff and C.n % 120 == 0 then
        pcall(function()
            for _, o in ipairs(C.overlays or {}) do
                if ok(o) and o:GetVisibility() ~= 1 and o:GetVisibility() ~= 2 then o:SetVisibility(2) end
            end
        end)
    end
end

function C.start(kind, actor, o)
    o = o or {}
    o.kind, o.actor, o.t0, o.dur = kind, actor, os.clock(), o.dur or 8
    o.snap = true
    C.tickAt = nil
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
-- An infantry fight: behind `a` looking past it at `b`, kept out of walls (thin probe starting 70 out, past the 40 capsule;
-- swings round to a clear angle that still sees `b`). Traces from chest height so the floor doesn't count.
function C.fight(a, b, o)
    o = o or {}
    o.other, o.back, o.up = b, o.back or 380, o.up or 70
    o.infantry, o.clear, o.rad, o.ignore = true, o.clear or 70, o.rad or 18, { a, b }
    o.aimUp = o.aimUp or 40
    return C.start("duel", a, o)
end
-- A portrait: in front of `a` (on its facing), looking back at it, kept out of walls like C.fight (swings to a clear
-- angle). The point it "looks past" is a spot behind the subject, so the duel framing puts the camera in front.
function C.front(a, o)
    o = o or {}
    o.back, o.up = o.back or 260, o.up or 30
    o.infantry, o.clear, o.rad, o.ignore = true, o.clear or 70, o.rad or 18, { a }
    o.aimUp, o.aimMix = o.aimUp or 50, o.aimMix or 0
    o.other = function()
        if not ok(a) then return nil end
        local l, y = a:K2_GetActorLocation(), math.rad(a:K2_GetActorRotation().Yaw + (o.yaw or 0))
        return { X = l.X - math.cos(y) * 1000, Y = l.Y - math.sin(y) * 1000, Z = l.Z }
    end
    return C.start("duel", a, o)
end
function C.trail(a, o) o = o or {} o.back, o.up = o.back or 250, o.up or 80 return C.start("trail", a, o) end
function C.pair(a, b, o) -- both ships of a fight in one frame, from the side (see frame)
    o = o or {} o.pa, o.pb = a, b
    return C.start("pair", function()
        if not (ok(a) and ok(b)) then return nil end
        local x, y = a:K2_GetActorLocation(), b:K2_GetActorLocation()
        return { X = (x.X + y.X) / 2, Y = (x.Y + y.Y) / 2, Z = (x.Z + y.Z) / 2 }
    end, o)
end
function C.dolly(a, o) return C.start("dolly", a, o) end
function C.track(a, o) return C.start("track", a, o) end

function C.stop()
    C.shot = nil
    local p = pc()
    if ok(p.Pawn) then p:SetViewTargetWithBlend(p.Pawn, 0, 0, 0, false) end
    if C.hudOff then C.hud(true) C.hudOff = false end
    return "camera back"
end

-- A new world: the camera, the shot's actors and the hidden HUD widgets were freed with the old one. Drop them before
-- anything checks them: IsValid reads the object's memory, so checking a freed actor can crash inside UE4SS.
-- Keyed on the ticking controller (a new world has a new one; its name's number tells a reused address apart), not on
-- GetWorld: right after this file registers the hook from inside a bridge command (itself in this same tick), UE4SS
-- calls the new hook once with a null controller, and GetWorld on that read address 0.
local function pcKey(o)
    if o == nil then return nil end
    local a = o:GetAddress()
    if not a or a == 0 then return nil end
    return ("%x %s"):format(a, o:GetFName():ToString())
end
function C.tick(ctx)
    local wk = pcKey(ctx:get())
    if not wk then return end
    if wk ~= C.world then
        if C.world ~= nil then
            C.shot, C.cam, C.ctx, C.prev, C.hidden, C.hudOff, C.tickAt = nil, nil, nil, nil, nil, false, nil
        end
        C.world = wk
    end
    if C.shot and C.frame then pcall(C.frame) end
end

if not C.hooked then
    RegisterHook("/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:ReceiveTick", function(ctx)
        CINE.ticks = (CINE.ticks or 0) + 1
        if CINE.ticks <= 1 then return end -- the call made while registering (see C.tick): its ctx isn't the controller
        if CINE.tick then CINE.tick(ctx) end
    end)
    C.ticks = 0
    C.hooked = true
end
-- reloaded in a new world before its first tick: forget the old camera (never IsValid it, see C.tick)
do
    local wk = pcKey(pc())
    if wk ~= C.world then C.cam, C.ctx, C.shot, C.hidden, C.hudOff = nil, nil, nil, nil, false end
    C.world = wk
end
C.overlays = FindAllOf("PgosOverlay_BP_C") or {}
return "cine ready"
