-- TEST (test installs only, tools/space_test): F9 "Log explosions" (issue #15), version 2. Passive: play normally, in the ship or on
-- foot, and shoot a turret, a radar dish or a mine. While it is on, bridge/explosions.txt gets (t is seconds since the game started):
--   WATCH   what it is watching: a count per class of turret, radar, dish, flak, rocket and mine actors, then each one's place
--   HP      a watched actor's Health or bIsDying changed (so a shot that did not kill it still shows)
--   DEATH   a watched actor died: Health at 0, bIsDying true, or gone
--   NEW     a new actor, particle system, Niagara system or sound (NotifyOnNewObject), read 0.25 s after it was made so its place is
--           set. The game reuses pooled effect actors parked at 0 0 0, so a pooled effect that is switched on is NOT new:
--   ACTIVE  0.15, 1 and 3 s after a death, every particle system, Niagara system and sound that is playing within 8000 cm of it
--           (of you, when the dead actor's own place is the world's origin), with its owner and distance
-- Classes that repeat (ship gun impacts) are written 25 times, then only counted; the counts are written when logging stops.
-- Reading it: what plays at a death with a name worth hearing or seeing (explosion, fire, smoke, boom) is what the game does offline.
-- Nothing ACTIVE or NEAR a death means the game made no effect for it.
local PROJECT = require("pveproject")
local W = {}

local OUT = PROJECT .. "bridge/explosions.txt"
local LINE_CAP = 20000
local RANGE = 8000
local PER_CLASS = 25
local WATCH_PAT = { "turret", "radar", "dish", "flak", "rocket", "mine" }
local SKIP_PAT = { "proj", "shell", "widget", "anim", "hud", "icon", "marker", "missile", "torpedo_", "ui_" }
local CLASSES = {
    { "/Script/Engine.Actor", "actor", false }, { "/Script/Engine.ParticleSystemComponent", "particle", true },
    { "/Script/Niagara.NiagaraComponent", "niagara", true }, { "/Script/Engine.AudioComponent", "sound", true },
}
local COMP_CLASSES = { "ParticleSystemComponent", "NiagaraComponent", "AudioComponent" }

local on, registered, lines = false, false, 0
local queue, watched, marks, seen = {}, {}, {}, {}
local worldKey, nextPoll, lastPc = nil, 0, nil

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end

local function put(text)
    if lines >= LINE_CAP then return end
    lines = lines + 1
    local f = io.open(OUT, "a")
    if f then
        f:write(text, "\n")
        if lines == LINE_CAP then f:write("line cap reached, logging stopped\n") end
        f:close()
    end
end

local function className(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function nameOf(o)
    local n = "?"
    pcall(function() n = o:GetFName():ToString() end)
    return n
end

local function hasAny(name, list)
    local l = name:lower()
    for _, p in ipairs(list) do if l:find(p, 1, true) then return true end end
    return false
end

local function place(o, comp)
    local l
    pcall(function() l = comp and o:K2_GetComponentLocation() or o:K2_GetActorLocation() end)
    if l and type(l.X) == "number" then return { X = l.X, Y = l.Y, Z = l.Z } end
    return nil
end

local function dist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isOrigin(l) return l == nil or (math.abs(l.X) < 1 and math.abs(l.Y) < 1 and math.abs(l.Z) < 1) end

local function ownerName(o)
    local n = "?"
    pcall(function()
        local ow = o:GetOwner()
        if valid(ow) then n = className(ow) .. " " .. nameOf(ow) end
    end)
    return n
end

local function fmt(l) return l and ("%.0f %.0f %.0f"):format(l.X, l.Y, l.Z) or "no place" end

local function readHealth(a)
    local hp, dying
    pcall(function() hp = a.Health end)
    pcall(function() dying = a.bIsDying end)
    if type(hp) ~= "number" then hp = nil end
    if type(dying) == "number" then dying = dying ~= 0 end
    if type(dying) ~= "boolean" then dying = nil end
    return hp, dying
end

local function watch(a)
    local n = className(a)
    if hasAny(n, WATCH_PAT) and not hasAny(n, SKIP_PAT) then
        local hp, dying = readHealth(a)
        watched[#watched + 1] = { actor = a, name = n, id = nameOf(a), loc = place(a, false), hp = hp, dying = dying }
        return true
    end
end

-- Every function a class has from its own blueprint up to (not including) Actor, by class: what a turret or mine can be told to do.
local function funcsOf(a)
    local out = {}
    local ok, err = pcall(function()
        local c = a:GetClass()
        for _ = 1, 8 do
            if not valid(c) then break end
            local cn = c:GetFName():ToString()
            if cn == "Actor" or cn == "Object" then break end
            c:ForEachFunction(function(fn)
                local fnm = fn:GetFName():ToString()
                if not fnm:lower():find("ubergraph", 1, true) then out[#out + 1] = cn .. "::" .. fnm end
            end)
            c = c:GetSuperStruct()
        end
    end)
    if not ok then out[#out + 1] = "(ForEachFunction failed: " .. tostring(err) .. ")" end
    return out
end

-- What the functions that matter take (type and name of each parameter), so they can be called right.
local PARAM_WORDS = { "health", "death", "explo", "triggered", "effect", "dying", "destroy", "damage", "multi", "net" }
local ALL_PAT = { "nodeturret", "nodemine", "exploder", "minestatic", "subnodeactor", "radar" }
local function functionsWithParams(a, only, all)
    local out = {}
    pcall(function()
        local c = a:GetClass()
        for _ = 1, 8 do
            if not valid(c) then break end
            local cn = c:GetFName():ToString()
            if cn == "Actor" or cn == "Object" then break end
            c:ForEachFunction(function(fn)
                local fnm = fn:GetFName():ToString()
                local l = fnm:lower()
                if (only and l == only:lower()) or (not only and (all or (hasAny(l, PARAM_WORDS) and not l:find("ubergraph", 1, true)))) then
                    local ps = {}
                    local okp, errp = pcall(function()
                        fn:ForEachProperty(function(p)
                            local ty, nm = "?", "?"
                            pcall(function() nm = p:GetFName():ToString() end)
                            pcall(function() ty = p:GetClass():GetFName():ToString():gsub("Property$", "") end)
                            if ty == "?" then pcall(function() ty = (p:GetFullName():match("^(%w+)") or "?"):gsub("Property$", "") end) end
                            ps[#ps + 1] = { ty = ty, name = nm }
                        end)
                    end)
                    if not okp then ps[#ps + 1] = { ty = "ForEachProperty failed", name = tostring(errp) } end
                    local addr
                    pcall(function() addr = math.tointeger(fn:GetAddress()) end)
                    out[#out + 1] = { class = cn, name = fnm, params = ps, addr = addr }
                end
            end)
            c = c:GetSuperStruct()
        end
    end)
    return out
end

-- The explosion fix attempt (F9 "Try explosion fix"): when a watched turret dies, call the functions of its class that look like
-- what plays on a death (the RepNotify of its health or dying flag, multicast effects) and log each call, so the ACTIVE lists that
-- follow show whether any of them made an effect. Replication callbacks never run on the authority, which offline is everyone.
local attempt = false
local WORDS = { "health", "dying", "dead", "destroy", "explo", "death", "die", "blast", "boom", "kill" }
local ORDER = { "onrep_health", "healthchanged", "ondeathevent", "netondeathevent" } -- tried in this order, all of them
local function candidates(list)
    local seen, picked = {}, {}
    for _, full in ipairs(list) do
        local fnm = full:match("::(.+)$") or full
        local l = fnm:lower()
        if not seen[l] and (l:find("onrep", 1, true) or l:find("multicast", 1, true) or l:find("explo", 1, true) or l:find("ondeath", 1, true) or l == "healthchanged")
            and hasAny(l, WORDS) and not l:find("receive", 1, true) and not l:find("tick", 1, true) and not l:find("construct", 1, true) then
            seen[l] = true
            picked[#picked + 1] = fnm
        end
    end
    table.sort(picked, function(a, b)
        local ra, rb = #ORDER + 1, #ORDER + 1
        for i, k in ipairs(ORDER) do
            if a:lower() == k then ra = i end
            if b:lower() == k then rb = i end
        end
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    return picked
end

local listed = {}
local function listClass(a)
    local n = className(a)
    if listed[n] then return end
    listed[n] = true
    local fns = funcsOf(a)
    put(("FUNCS %s (%d): %s"):format(n, #fns, table.concat(fns, ", ")))
    for _, f in ipairs(functionsWithParams(a, nil, hasAny(n, ALL_PAT))) do
        local ps = {}
        for _, p in ipairs(f.params) do ps[#ps + 1] = p.ty .. " " .. p.name end
        put(("PARAMS %s::%s(%s) @%s"):format(f.class, f.name, table.concat(ps, ", "), f.addr and ("%x"):format(f.addr) or "?"))
    end
end

-- Found in the pak (2026-11-18): SubNodeActorTurret_C::ReceiveDestroyed spawns the turret's "Exploder Class" (an Apex destructible
-- with a particle burst, Blueprints/Exploders/*_Exploder_Child) and plays its Destroyed_Sound. A dead turret is only hidden offline.
-- This logs what the turret holds (authority too), runs the game's own destroyed event and counts the exploders it made; if none
-- appeared it spawns the class the turret names by hand and plays the sound, then destroys the turret.
local EXPLODER_NAMES = { "Radar_Exploder_Child_C", "FlakTurret_Exploder_Child_C", "RocketTurret_Exploder_Child_C",
    "TripleTurret_Exploder_Child_C", "Mine_Exploder_Child_C", "NuclearMine_Exploder_Child_C" }
local function exploderCount()
    local n = 0
    for _, cn in ipairs(EXPLODER_NAMES) do
        for _, o in ipairs(FindAllOf(cn) or {}) do if valid(o) then n = n + 1 end end
    end
    return n
end

local function tryFix(w)
    if not attempt or not valid(w.actor) or not w.name:lower():find("turret", 1, true) then return end
    local a = w.actor
    local world, loc, rot, cls, snd
    pcall(function() world = a:GetWorld() end)
    pcall(function() loc = a:K2_GetActorLocation() end)
    pcall(function() rot = a:K2_GetActorRotation() end)
    pcall(function() cls = a["Exploder Class"] end)
    pcall(function() snd = a["Destroyed_Sound"] end)
    put(("TRY %s %s at %s | Exploder Class %s | Destroyed_Sound %s"):format(w.name, w.id, fmt(loc),
        valid(cls) and cls:GetFName():ToString() or "none", valid(snd) and snd:GetFName():ToString() or "none"))
    pcall(function() require("testtools").sweep(a, "dying " .. w.name, put) end)
    local okd, errd = pcall(function() a:OnDeathEvent() end)
    put(("  OnDeathEvent -> %s"):format(okd and "ran" or ("error: " .. tostring(errd))))
    local before = exploderCount()
    local okr, errr = pcall(function() a:ReceiveDestroyed() end)
    local made = exploderCount() - before
    put(("  ReceiveDestroyed (the game's own) -> %s, exploders made: %d"):format(okr and "ran" or ("error: " .. tostring(errr)), made))
    if made <= 0 then
        if valid(world) and valid(cls) and loc then
            local ok, ex = pcall(function() return world:SpawnActor(cls, loc, rot or { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            put(("  spawn exploder by hand -> %s"):format(ok and (valid(ex) and ("made " .. className(ex)) or "nothing came back") or ("error: " .. tostring(ex))))
            if ok and valid(ex) then pcall(function() require("testtools").sweep(ex, "exploder just made", put) end) end
        end
        if valid(world) and valid(snd) and loc then
            put("  playing the destroyed sound ...")
            local ok, err = pcall(function()
                StaticFindObject("/Script/Engine.Default__GameplayStatics"):SpawnSoundAtLocation(a, snd, loc, { Pitch = 0, Yaw = 0, Roll = 0 },
                    1.0, 1.0, 0.0, nil, nil, true)
            end)
            put(("  sound -> %s"):format(ok and "played" or ("error: " .. tostring(err))))
        end
        local okx, errx = pcall(function() a:K2_DestroyActor() end)
        put(("  K2_DestroyActor -> %s"):format(okx and "ran" or ("error: " .. tostring(errx))))
    else
        pcall(function() a:SetActorHiddenInGame(true) a:SetActorEnableCollision(false) end)
        put("  the game's own path worked; turret hidden and left for the game to clean up")
    end
end

local function scan()
    local counts = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if valid(a) and watch(a) then
            local n = watched[#watched].name
            counts[n] = (counts[n] or 0) + 1
        end
    end
    for _, w in ipairs(watched) do if valid(w.actor) then pcall(listClass, w.actor) end end
    put(("WATCH %d actors:"):format(#watched))
    local names = {}
    for n in pairs(counts) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do put(("  %d x %s"):format(counts[n], n)) end
    for i, w in ipairs(watched) do
        if i <= 60 then put(("  %s | place %s | Health %s | bIsDying %s"):format(w.id, fmt(w.loc), tostring(w.hp), tostring(w.dying))) end
    end
end

local function register()
    if registered then return end
    registered = true
    for _, c in ipairs(CLASSES) do
        local path, kind, comp = c[1], c[2], c[3]
        pcall(NotifyOnNewObject, path, function(o)
            if on and #queue < 400 then queue[#queue + 1] = { o = o, kind = kind, comp = comp, t = os.clock() } end
        end)
    end
end

local function playerPlace()
    if valid(lastPc) and valid(lastPc.Pawn) then return place(lastPc.Pawn, false) end
    return nil
end

-- A new object is written 0.25 s after it was made, with its place by then.
local function drain(now)
    for _ = 1, 40 do
        local q = queue[1]
        if not q or now - q.t < 0.25 then return end
        table.remove(queue, 1)
        if valid(q.o) then
            local cn = className(q.o)
            local key = q.kind .. " " .. cn
            seen[key] = (seen[key] or 0) + 1
            if seen[key] <= PER_CLASS then
                local l = place(q.o, q.comp)
                put(("NEW %s %s | %s | owner %s | %s | made t=%.2f"):format(q.kind, cn, nameOf(q.o), ownerName(q.o), fmt(l), q.t))
            end
            if not q.comp and (watch(q.o) or hasAny(cn, { "explosion", "impacts", "exploder" })) then pcall(listClass, q.o) end
        end
    end
end

local function died(w, why, now)
    local l = w.loc
    local at = isOrigin(l) and playerPlace() or l
    put(("DEATH %s %s at %s (%s) | last Health %s | t=%.2f%s"):format(w.name, w.id, fmt(l), why, tostring(w.hp), now,
        isOrigin(l) and (" | its place is the origin, listing near you at " .. fmt(at)) or ""))
    if at then marks[#marks + 1] = { loc = at, t = now, name = w.name, due = { 0.15, 1.0, 3.0 }, i = 1 } end
    local okf, errf = pcall(tryFix, w)
    if not okf then put("TRY failed: " .. tostring(errf)) end
end

local function poll(now)
    for i = #watched, 1, -1 do
        local w = watched[i]
        if not valid(w.actor) then
            died(w, "gone", now)
            table.remove(watched, i)
        else
            local hp, dying = readHealth(w.actor)
            if hp ~= w.hp or dying ~= w.dying then
                put(("HP %s %s | Health %s -> %s | bIsDying %s -> %s | t=%.2f"):format(w.name, w.id, tostring(w.hp), tostring(hp),
                    tostring(w.dying), tostring(dying), now))
            end
            local was = w.hp
            w.hp, w.dying = hp, dying
            w.loc = place(w.actor, false) or w.loc
            if dying == true then
                died(w, "bIsDying", now)
                table.remove(watched, i)
            elseif hp and hp <= 0 and (was == nil or was > 0) then
                died(w, "Health " .. tostring(hp), now)
                table.remove(watched, i)
            end
        end
    end
end

local function snapshot(m, now)
    put(("ACTIVE %.2f s after the death of %s, within %d cm of %s:"):format(now - m.t, m.name, RANGE, fmt(m.loc)))
    local n = 0
    for _, cn in ipairs(COMP_CLASSES) do
        for _, o in ipairs(FindAllOf(cn) or {}) do
            if n < 60 and valid(o) then
                local active, playing = false, false
                pcall(function() active = o:IsActive() == true end)
                if cn == "AudioComponent" then pcall(function() playing = o:IsPlaying() == true end) end
                if active or playing then
                    local l = place(o, true)
                    if l and dist(l, m.loc) < RANGE then
                        n = n + 1
                        put(("  %s %s | owner %s | %s | %.0f cm"):format(cn, nameOf(o), ownerName(o), cn == "AudioComponent" and ("playing=" .. tostring(playing)) or "active", dist(l, m.loc)))
                    end
                end
            end
        end
    end
    put(("  %d active"):format(n))
end

function W.tick(now, pc)
    if not on then return end
    if pc then lastPc = pc end
    local key
    pcall(function() key = tostring(pc:GetWorld():GetAddress()) end)
    if key and key ~= worldKey then -- a new world: nothing watched before it is still there
        worldKey, watched, queue, marks = key, {}, {}, {}
        put("-- new world, rescanning")
        pcall(scan)
    end
    drain(now)
    if now >= nextPoll then
        nextPoll = now + 0.1
        poll(now)
    end
    for i = #marks, 1, -1 do
        local m = marks[i]
        local due = m.due[m.i]
        if not due then
            table.remove(marks, i)
        elseif now - m.t >= due then
            local ok, err = pcall(snapshot, m, now)
            if not ok then put("  snapshot error: " .. tostring(err)) end
            m.i = m.i + 1
        end
    end
end

function W.label() return "Log explosions: " .. (on and "ON" or "off") end

function W.fixLabel() return "Try explosion fix: " .. (attempt and "ON" or "off") end
function W.fixToggle()
    attempt = not attempt
    return attempt and "On: a dying turret gets its death functions called (needs Log explosions on to see)" or "Off"
end

function W.toggle()
    if on then
        on = false
        put("-- off. How many of each new object there were (written in full up to " .. PER_CLASS .. " each):")
        local keys = {}
        for k in pairs(seen) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do put(("  %d x %s"):format(seen[k], k)) end
        return "Explosion log off"
    end
    on = true
    register()
    lines, watched, queue, marks, seen, worldKey = 0, {}, {}, {}, {}, nil
    local f = io.open(OUT, "w")
    if f then f:write("explosion log v2, t is seconds since the game started\n") f:close() end
    return "Logging to bridge\\explosions.txt: shoot a turret, a radar dish, a mine"
end

return W
