-- Bullet holes (fix/bullet-impacts-and-particles). Offline, a shot at a wall made the impact's particles and sound but no
-- bullet hole: the pooled impact actors (BasePoolHitEffect_C, taken by native code when a shot lands) have no decal
-- component (DecalComp is nil on every one of them), and the game's own client side code, the part that would place
-- one, never runs offline. The game does leave a few marks of its own (blood on a bot), so this only adds the
-- ones that are missing, from the decal materials the game already ships: BulletImpactDecal_<family><n>_MIC.
-- How, in short (docs/internals/BULLET_IMPACTS.md has the diagrams and the measurements):
--   1. The player controller keeps the pool (RaidPlayerController.PooledImpactActors, 500 actors here). Each actor has
--      a bInUse flag the native code sets when it takes the actor for a shot. Hooking OnPoolActive from Lua does not
--      work (native calls it, Lua hooks never see it), so this watches bInUse every EVERY seconds instead.
--   2. A pool actor that just became in use (or moved while in use) is a new impact. Its rotation points along the
--      surface normal (walls Yaw 180 = facing -X, floors Pitch 90 = up), and EffectForHit says what was hit
--      (PS_BulletHit_Concrete / MetalSolid / Tinplate / Wood / Glass ...).
--   3. A 30 cm line trace through the impact along that normal finds the exact surface point and normal.
--   4. GameplayStatics:SpawnDecalAtLocation puts a small decal there (size is half extents, the decal projects along
--      its X axis, so it is rotated to face into the surface) with a random roll so holes do not repeat.
-- Blood (a bot hit) and the surfaces with no material (Ground, Water, Fabric) are left to the game.
-- Nothing is hooked: reading properties and one trace per impact, no engine statics are hooked (those crashed the game
-- twice during testing, see NOTES.md).
local Out = require("outref")
local M = {}
local X -- log, valid

local CFG = {
    BULLET_HOLES = 1, -- 1 = on, 0 = off (F10 Effects)
    HOLE_SECONDS = 60, -- a hole fades out after this long
    MAX_HOLES = 250,  -- most holes alive at once: the oldest go first (a shotgun fired in a firefight makes dozens)
    HOLE_SIZE = 5,    -- half the width of a hole, cm (5 = a 10 cm hole)
}
M.CFG = CFG

local EVERY = 0.1     -- seconds between looks at the pool while shooting (500 flag reads each; a hole shows within a tenth of a second)
local IDLE = 0.5      -- seconds between looks when no new impact for BUSY seconds: the first hole of a quiet spell is up to 0.5 s late.
                      -- Nothing is missed: offline an actor is never handed back (ReturnToPoolTime is client code), so a new impact
                      -- is either a never-used actor turning bInUse on or a used one moving, and both stay visible until the next look
                      -- (an actor would have to be reused twice in 0.5 s, 500 impacts in the pool's round robin).
local BUSY = 2        -- seconds after the last new impact that the pool is looked at every EVERY
local REFRESH = 10    -- seconds between re-reading the pool's list
local PER_PASS = 12   -- most holes in one look; the rest are picked up on the next
local MOVED = 2       -- cm: an actor already in use that moved this far is a new impact (reused before it was returned)
local TRACE_HALF = 15 -- cm each side of the impact point for the surface trace
local DEPTH = 12      -- cm the decal projects into the surface (half extent along its X)
local NO_COLOUR = { R = 0, G = 0, B = 0, A = 0 }

-- Pool effect surface (PS_BulletHit_<name>) -> decal material family (BulletImpactDecal_<family><n>_MIC).
local SURF = {
    Concrete = "Concrete", MetalSolid = "MetalSolid", Tinplate = "MetalThin",
    Wood = "Wood", Glass = "Glass_BulletProof", Snow = "Snow",
}

local S -- this raid's state, thrown away when the player controller changes

local function fresh(addr)
    return { addr = addr, pool = {}, count = -1, listAt = 0, nextAt = 0, was = {}, at = {}, holes = {}, first = 1, last = 0,
        mats = nil, matsAt = 0, seen = {}, made = 0 }
end

-- Every BulletImpactDecal material the game has loaded, by family. One scan of the material instances, then cached
-- (a FindAllOf walks every object): rescanned at most every 30 s while a family is missing.
local function loadMaterials(s, now)
    if s.mats and now < s.matsAt then return end
    s.matsAt = now + 30
    local mats = {}
    local n = 0
    for _, m in ipairs(FindAllOf("MaterialInstanceConstant") or {}) do
        local ok, name = pcall(function() return m:GetFName():ToString() end)
        local family = ok and name:match("^BulletImpactDecal_(.-)%d+_MIC")
        if family and X.valid(m) then
            mats[family] = mats[family] or {}
            table.insert(mats[family], m)
            n = n + 1
        end
    end
    s.mats = mats
    if not s.matsLogged then
        s.matsLogged = true
        local fams = {}
        for f, l in pairs(mats) do fams[#fams + 1] = f .. " x" .. #l end
        table.sort(fams)
        X.log("bullet holes: " .. n .. " hole materials (" .. table.concat(fams, ", ") .. ")")
    end
end

-- Re-reads the pool's actor list when it is due or its length changed. Actors seen for the first time are recorded as
-- they are now, so a hole is never stamped for an impact that was already there.
local function readPool(pc, s, now)
    if now < s.listAt then return end
    s.listAt = now + REFRESH
    local ok, arr = pcall(function() return pc.PooledImpactActors end)
    if not ok or not arr then return end
    local okn, n = pcall(function() return arr:GetArrayNum() end)
    if not okn or n == s.count then return end
    s.count = n
    local list = {}
    arr:ForEach(function(_, el)
        local okg, a = pcall(function() return el:get() end)
        if okg and a and X.valid(a) then list[#list + 1] = a end
    end)
    s.pool = list
    for _, a in ipairs(list) do
        local key = a:GetAddress()
        if s.was[key] == nil then
            local oki, inUse = pcall(function() return a.bInUse end)
            s.was[key] = oki and inUse == true
        end
    end
end

local function readInUse(a) return a.bInUse end

local function surfaceOf(a)
    local ok, full = pcall(function() return a.EffectForHit:GetFullName() end)
    if not ok then return nil end
    return full:match("PS_BulletHit_(%w+)")
end

local function drop(s, count)
    -- oldest first; the engine removes a hole at its lifespan on its own, this is only the cap
    while s.last - s.first + 1 > count do
        local c = s.holes[s.first]
        s.holes[s.first] = nil
        s.first = s.first + 1
        if c and X.valid(c) then pcall(function() c:K2_DestroyComponent(c) end) end
    end
end

-- One hole where the pool actor `a` landed at `p`. Returns what was done, for the first-seen log.
local function stamp(pc, s, a, p, sfc, kml, ksl, gs)
    local family = SURF[sfc]
    if not family then return "none" end
    loadMaterials(s, os.clock())
    local list = s.mats[family]
    if not list or #list == 0 then return "nomat" end
    local rot = a:K2_GetActorRotation()
    local n = kml:GetForwardVector(rot)
    local from = { X = p.X + n.X * TRACE_HALF, Y = p.Y + n.Y * TRACE_HALF, Z = p.Z + n.Z * TRACE_HALF }
    local to = { X = p.X - n.X * TRACE_HALF, Y = p.Y - n.Y * TRACE_HALF, Z = p.Z - n.Z * TRACE_HALF }
    local out = {}
    local hit = Out.call(ksl, "LineTraceSingle", pc, from, to, 0, false, { pc.Pawn }, 0, out, true, NO_COLOUR, NO_COLOUR, 0)
    local at, nn = p, n -- no surface found: the pool actor's own point and normal
    if hit and out.ImpactPoint and out.ImpactNormal then at, nn = out.ImpactPoint, out.ImpactNormal end
    local r = kml:MakeRotFromX({ X = -nn.X, Y = -nn.Y, Z = -nn.Z })
    r.Roll = math.random() * 360
    local lift = { X = at.X + nn.X * 0.5, Y = at.Y + nn.Y * 0.5, Z = at.Z + nn.Z * 0.5 } -- off the surface, no z-fight
    local size = CFG.HOLE_SIZE
    local comp = gs:SpawnDecalAtLocation(pc, list[math.random(#list)], { X = DEPTH, Y = size, Z = size }, lift, r, CFG.HOLE_SECONDS)
    if comp then
        s.last = s.last + 1
        s.holes[s.last] = comp
        drop(s, CFG.MAX_HOLES)
    end
    s.made = s.made + 1
    return "made"
end

-- From the director's per-frame tick, with the player controller.
function M.frame(pc)
    if CFG.BULLET_HOLES == 0 or not X.valid(pc) then return end
    local now = os.clock()
    local addr = pc:GetAddress()
    if not S or S.addr ~= addr then S = fresh(addr) end
    local s = S
    if now < s.nextAt then return end
    s.nextAt = now + ((now < (s.busyUntil or 0)) and EVERY or IDLE)
    readPool(pc, s, now)
    if not s.mats and #s.pool > 0 then loadMaterials(s, now) end -- on the first quiet pass, not on the first shot
    local budget = PER_PASS
    local kml, ksl, gs
    for _, a in ipairs(s.pool) do
        local key = a:GetAddress()
        local ok, inUse = pcall(readInUse, a)
        if ok then
            inUse = inUse == true
            local fire = false
            if inUse then
                local p = a:K2_GetActorLocation()
                local old = s.at[key]
                if not s.was[key] then
                    fire = true
                elseif old and math.abs(old.X - p.X) + math.abs(old.Y - p.Y) + math.abs(old.Z - p.Z) > MOVED then
                    fire = true
                end
                if fire then
                    s.busyUntil = now + BUSY
                    s.nextAt = now + EVERY
                    if budget <= 0 then break end -- the rest next pass: their state is left as it was
                    budget = budget - 1
                    kml = kml or StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
                    ksl = ksl or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
                    gs = gs or StaticFindObject("/Script/Engine.Default__GameplayStatics")
                    local sfc = surfaceOf(a) or "?"
                    local okS, res = pcall(stamp, pc, s, a, p, sfc, kml, ksl, gs)
                    if not okS then
                        if not s.failed then s.failed = true X.log("bullet holes: a hole failed: " .. tostring(res)) end
                    elseif not s.seen[sfc] then
                        s.seen[sfc] = true
                        X.log("bullet holes: first " .. sfc .. " impact: " .. res)
                    end
                end
                if old then old.X, old.Y, old.Z = p.X, p.Y, p.Z else s.at[key] = { X = p.X, Y = p.Y, Z = p.Z } end
            else
                s.at[key] = nil
            end
            s.was[key] = inUse
        end
    end
end

function M.init(ctx) X = ctx end
function M.reset() S = nil end

return M
