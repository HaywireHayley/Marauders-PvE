-- TEST (test installs only, tools/space_test): F9 "Bottomless mags", and the space object spawner (turrets, radar dishes...)
-- with a kill button that logs every particle, sound and actor the death makes (bridge/space_explosion.txt; issue 15).
-- Bottomless mags: no game flags (bInfiniteClip and bInfiniteAmmo changed how the clip reads, so the damage code never saw a shot,
-- and finding the flags searched the world twice a second). Each frame, right after botdamage.lua has read the clip, whatever a
-- shot took off the clip (and the reserve, if a reload took it) is put back. One property read a frame, nothing searched.
local D = {}

local on = false

local controller -- (defined below valid)
local lastWhy, tickPc = "not checked yet", nil -- why controller() last said no; the controller that ticked last

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end

-- The player controller that has a pawn: on foot (PlayerPawn_C) or at the helm of a ship (Ship_*_Pawn_C), so the space tools work
-- while you fly and can shoot what you spawn. The one that ticked last comes first, then every MainPlayerController_C
-- (FindFirstOf can return the previous raid's), and lastWhy says why none did.
local ctlAt, ctlPc = -1, nil -- the answer is kept half a second: every menu row asks, and the search is ~40 ms
controller = function()
    if os.clock() - ctlAt < 0.5 then return ctlPc end
    ctlAt, ctlPc = os.clock(), nil
    local cands = {}
    if valid(tickPc) then cands[#cands + 1] = tickPc end
    for _, p in ipairs(FindAllOf("MainPlayerController_C") or {}) do
        if valid(p) then cands[#cands + 1] = p end
    end
    lastWhy = "no player controller found"
    for _, pc in ipairs(cands) do
        local pawn = pc.Pawn
        if not valid(pawn) then
            lastWhy = "the controller has no pawn"
        else
            local cn = "?"
            pcall(function() cn = pawn:GetClass():GetFName():ToString() end)
            if cn == "PlayerPawn_C" or cn:find("^Ship_") then lastWhy, ctlPc = "ok", pc return pc end
            lastWhy = "you control " .. cn .. ", not your character or your ship"
        end
    end
    return nil
end

-- For the player the loaded rounds are the StackAmount of the gun's own SIGIS item (found by UniqueItemGUID == gun.UUIDSIGIS); the
-- weapon's CurrentAmmoInClip only follows it, so putting that property back alone changed nothing. Both are put back.
local prev = {} -- gun address, its item, and the item's stack and the clip as of the last frame
local bottomlessLogged = false

local function findItem(gun)
    local guid = gun.UUIDSIGIS:ToString()
    for _, it in ipairs(FindAllOf("SIGISInventoryItem") or {}) do
        if valid(it) and it.UniqueItemGUID:ToString() == guid then return it end
    end
    return nil
end

-- Called by botdamage.lua's test wrapper right AFTER the damage code has read the clip this frame.
function D.afterFrame(pc)
    if not on then return end
    local pawn = pc.Pawn
    if not valid(pawn) then return end
    local g = pawn.CurrentWeapon
    if not valid(g) then prev.addr = nil return end
    local addr = g:GetAddress()
    if prev.addr ~= addr then -- a different gun: find its item once, then start counting from what it holds now
        prev = { addr = addr, item = findItem(g), at = os.clock() }
    elseif not valid(prev.item) and os.clock() - prev.at > 1 then
        prev.item, prev.at = findItem(g), os.clock()
    end
    local clip = g.CurrentAmmoInClip
    local it = prev.item
    local stack = valid(it) and it.StackAmount or nil
    if type(clip) == "number" and type(prev.clip) == "number" and clip < prev.clip then
        if not bottomlessLogged then
            bottomlessLogged = true
            print(("[PvEDirector] bottomless mags: first shot, clip %s -> %s, item stack %s -> %s, putting both back\n"):format(
                tostring(prev.clip), tostring(clip), tostring(prev.stack), tostring(stack)))
        end
        g.CurrentAmmoInClip = prev.clip
        clip = prev.clip
    end
    if type(stack) == "number" and type(prev.stack) == "number" and stack < prev.stack then
        it.StackAmount = prev.stack
        stack = prev.stack
    end
    prev.clip, prev.stack = clip, stack
end


-- Space objects ------------------------------------------------------------------------------------
-- The classes you can spawn: the stationary space turrets and mines alive in this level (found once per level, with the real
-- class, so a flak turret spawns as the flak turret). They appear 40 m in front of your ship, facing it. "Kill" hits them with damage so they die the game's own way, and
-- a watcher writes what appeared (actors, particles, Niagara, sounds) 0.15, 1 and 3 s later to bridge/space_explosion.txt.
local OUT = require("pveproject") .. "bridge/space_explosion.txt"
-- Only the stationary space objects (Flak, Rocket Artillery and Radar node turrets, the nuclear and small mines): not the ship
-- turrets, not the tripmine, and not the mine map's own props (drills, fans, spawners, doors).
local KIND_PAT = { "nodeturret", "nodemine" }
local SKIP_PAT = { "proj", "shell", "widget", "anim", "hud", "icon", "marker", "missile", "torpedo_", "ui_" }
local COMPS = { "ParticleSystemComponent", "NiagaraComponent", "AudioComponent" }
local OBJ_PROPS = { "Health", "MaxHealth", "bIsDying", "bCanBeDamaged", "bHidden", "ArmourDamageMitagation", "FireDistance",
    "AmmoLeft", "TotalAmmo", "ReloadTime", "SystemHealth", "bExploded", "bDoesExplode", "ExplosionDamage", "ExplosionRadius" }
local RANGE = 8000
local KILL_DAMAGE = 1000000

local pool, poolKey, idx = nil, nil, 1
local spawned = {}
local watches = {}

local function put(text)
    local f = io.open(OUT, "a")
    if f then f:write(text, "\n") f:close() end
end

local function className(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function readProps(o)
    local vals = {}
    for _, p in ipairs(OBJ_PROPS) do
        local ok, v = pcall(function() return o[p] end)
        if ok and (type(v) == "number" or type(v) == "boolean") then vals[#vals + 1] = p .. "=" .. tostring(v) end
    end
    return #vals > 0 and table.concat(vals, " ") or "no value read"
end

local function loadClass(path)
    local name = path:match("([^/]+)$")
    local full = path .. "." .. name .. "_C"
    local c = StaticFindObject(full)
    if not (c and c:IsValid()) then pcall(LoadAsset, path .. "." .. name) c = StaticFindObject(full) end
    return (c and c:IsValid()) and c or nil
end

local function hasAny(name, list)
    local l = name:lower()
    for _, p in ipairs(list) do if l:find(p, 1, true) then return true end end
    return false
end

local function buildPool(pc)
    local list, seen = {}, {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if valid(a) then
            local n = className(a)
            if not seen[n] and hasAny(n, KIND_PAT) and not hasAny(n, SKIP_PAT) then
                local c
                pcall(function() c = a:GetClass() end)
                if valid(c) then seen[n] = true list[#list + 1] = { name = n, cls = c, live = true } end
            end
        end
    end
    local function first(n) return n:find("NodeTurret", 1, true) or n:find("NodeMine", 1, true) or n:find("MineStaticActor", 1, true) end
    table.sort(list, function(a, b)
        local fa, fb = first(a.name) and 0 or 1, first(b.name) and 0 or 1
        if fa ~= fb then return fa < fb end
        return a.name < b.name
    end)
    print(("[PvEDirector] space objects: %d kinds alive in this level\n"):format(#list))
    return list
end

local function ensurePool(pc)
    local key = "?"
    pcall(function() key = tostring(pc.Pawn:GetWorld():GetAddress()) end)
    if pool == nil or key ~= poolKey then
        poolKey, pool, idx, spawned = key, buildPool(pc), 1, {}
    end
    return pool
end

local function classOf(e)
    if e.cls and valid(e.cls) then return e.cls end
    if e.path then return loadClass(e.path) end
    return nil
end

-- How far ahead of your ship things appear (cm): the button next to the spawn button cycles it. 80 m is inside the reach of a ship
-- gun (60 to 95 m), so you can fly at it and shoot it; the longer ones are for the stationary turrets' own range.
local DISTS = { 4000, 8000, 15000, 30000 }
local distIdx = 2

local function spawnPoint(pc, dist)
    local base, yaw = pc.Pawn:K2_GetActorLocation(), pc.Pawn:K2_GetActorRotation().Yaw
    local ship
    if className(pc.Pawn):find("^Ship_") then
        ship = pc.Pawn -- at the helm: ahead of what you fly
    else
        local okR, R = pcall(require, "rivals")
        ship = okR and R.playerShip and R.playerShip() or nil
    end
    if valid(ship) then
        pcall(function()
            base = ship:K2_GetActorLocation()
            yaw = ship:K2_GetActorRotation().Yaw
        end)
    end
    local r, d = math.rad(yaw), dist or DISTS[distIdx]
    return { X = base.X + d * math.cos(r), Y = base.Y + d * math.sin(r), Z = base.Z }, yaw + 180
end

local function actorSet()
    local set = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if valid(a) then set[math.tointeger(a:GetAddress())] = true end
    end
    return set
end

local function compSets()
    local sets = {}
    for _, c in ipairs(COMPS) do
        local set = {}
        for _, o in ipairs(FindAllOf(c) or {}) do
            if valid(o) then set[math.tointeger(o:GetAddress())] = true end
        end
        sets[c] = set
    end
    return sets
end

local function distTo(o, at, comp)
    local l
    pcall(function() l = comp and o:K2_GetComponentLocation() or o:K2_GetActorLocation() end)
    if not l then return nil, nil end
    local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz), l
end

-- What exists now that did not at the kill, near it.
local CRUMB = OUT:gsub("[^/\\]*$", "space_crumb.txt")
local function crumb(text)
    local f = io.open(CRUMB, "w")
    if f then f:write(text, "\n") f:close() end
end

local function report(w, label)
    put(("  [%s, %.2f s after the kill]"):format(label, os.clock() - w.t0))
    local a = w.actor
    if valid(a) then put("  the target: " .. className(a) .. " | " .. readProps(a))
    else put("  the target: gone (destroyed)") end
    -- A dead actor reads its place as the origin, and the area around the origin is full of objects being torn down: scanning it
    -- crashed the game (access violation, 2026-11-18). Nothing useful is there, so don't.
    if math.abs(w.at.X) < 100 and math.abs(w.at.Y) < 100 and math.abs(w.at.Z) < 100 then
        put("  (target place is the origin: area scan skipped)")
        return
    end
    local n = 0
    for _, o in ipairs(FindAllOf("Actor") or {}) do
        if valid(o) and not w.actors[math.tointeger(o:GetAddress())] then
            local d, l = distTo(o, w.at, false)
            if d and d < RANGE then
                crumb("actor " .. className(o))
                n = n + 1
                put(("  NEW ACTOR %s | %.0f cm away at %.0f %.0f %.0f | %s"):format(className(o), d, l.X, l.Y, l.Z, readProps(o)))
            end
        end
    end
    local comps = 0
    for _, c in ipairs(COMPS) do
        for _, o in ipairs(FindAllOf(c) or {}) do
            if valid(o) and not w.comps[c][math.tointeger(o:GetAddress())] then
                local d, l = distTo(o, w.at, true)
                if d and d < RANGE then
                    crumb("component " .. c .. " " .. o:GetFName():ToString())
                    comps = comps + 1
                    local owner = "?"
                    pcall(function() owner = o:GetOwner():GetFName():ToString() end)
                    local active = ""
                    pcall(function() active = " active=" .. tostring(o:IsActive()) end)
                    put(("  NEW %s %s (owner %s) | %.0f cm away at %.0f %.0f %.0f%s"):format(c, o:GetFName():ToString(), owner, d, l.X, l.Y, l.Z, active))
                end
            end
        end
    end
    put(("  %d new actors and %d new particle or sound components within %d cm"):format(n, comps, RANGE))
end

function D.tick(now, pc)
    if pc then tickPc = pc end
    pcall(function() require("explowatch").tick(now, pc) end) -- F9 Log explosions (explowatch.lua)
    pcall(function() require("salvagewatch").tick(now, pc) end) -- F9 Log salvage (salvagewatch.lua)
    for i = #watches, 1, -1 do
        local w = watches[i]
        local due = w.marks[w.next]
        if due and now - w.t0 >= due then
            local ok, err = pcall(report, w, "mark " .. w.next)
            if not ok then put("  report error: " .. tostring(err)) end
            w.next = w.next + 1
            -- still alive after a second: hit it again, in case the first blow was clipped
            if w.next == 3 and valid(w.actor) and w.pc and valid(w.pc) then
                local hp
                pcall(function() hp = w.actor.Health end)
                if type(hp) == "number" and hp > 0 then
                    put("  still has Health " .. hp .. " after a second: hitting it again")
                    pcall(function()
                        StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(w.actor, KILL_DAMAGE, w.pc, w.pc.Pawn,
                            StaticFindObject("/Script/Engine.DamageType"))
                    end)
                end
            end
        elseif not due then
            table.remove(watches, i)
        end
    end
end

local function step(i, n, delta) return (i - 1 + delta) % n + 1 end

local function stepPick(delta)
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local list = ensurePool(pc)
    idx = step(idx, #list, delta)
    return "Space object: " .. list[idx].name
end
local function pick() return stepPick(1) end
local function pickBack() return stepPick(-1) end

local function pickLabel()
    if not pool then return "Space object: click to list what this level has" end
    local name = pool[idx].name
    if #name > 30 then name = name:sub(1, 27) .. "..." end
    return ("Space object %d of %d: %s"):format(idx, #pool, name)
end

local function spawn()
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local list = ensurePool(pc)
    local e = list[idx]
    local cls = classOf(e)
    if not cls then return "Couldn't load " .. e.name end
    local at, yaw = spawnPoint(pc)
    local world = pc.Pawn:GetWorld()
    local a = world:SpawnActor(cls, at, { Pitch = 0, Yaw = yaw, Roll = 0 })
    if not valid(a) then return "Spawn failed for " .. e.name end
    spawned[#spawned + 1] = a
    put(("SPAWNED %s at %.0f %.0f %.0f | %s"):format(className(a), at.X, at.Y, at.Z, readProps(a)))
    return ("Spawned %s, %d m ahead of your ship"):format(className(a), DISTS[distIdx] / 100)
end

local function kill()
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local dtype = StaticFindObject("/Script/Engine.DamageType")
    local n = 0
    for _, a in ipairs(spawned) do
        if valid(a) then
            local d, l = distTo(a, { X = 0, Y = 0, Z = 0 }, false)
            local at = l or { X = 0, Y = 0, Z = 0 }
            local w = { actor = a, at = at, t0 = os.clock(), next = 1, marks = { 0.15, 1.0, 3.0 }, pc = pc,
                actors = actorSet(), comps = compSets() }
            put(("KILL %s at %.0f %.0f %.0f | before: %s"):format(className(a), at.X, at.Y, at.Z, readProps(a)))
            local ok, err = pcall(function() gs:ApplyDamage(a, KILL_DAMAGE, pc, pc.Pawn, dtype) end)
            if not ok then put("  ApplyDamage error: " .. tostring(err)) end
            watches[#watches + 1] = w
            n = n + 1
        end
    end
    return n > 0 and ("Hit %d with %d damage: bridge\\space_explosion.txt"):format(n, KILL_DAMAGE) or "Nothing spawned yet"
end

local function remove()
    local n = 0
    for _, a in ipairs(spawned) do
        if valid(a) then pcall(function() a:K2_DestroyActor() end) n = n + 1 end
    end
    spawned = {}
    pcall(function() require("salvagewatch").note(("removed %d spawned actors from the menu"):format(n)) end)
    return ("Removed %d (no explosion)"):format(n)
end

local function toggle()
    if not controller() then return "Not usable: " .. lastWhy end
    on = not on
    prev = {}
    return on and "Bottomless mags on: every shot is put back" or "Bottomless mags off"
end


-- Discovery tools -------------------------------------------------------------------------------------------------------------
-- Everything below exists to stop guessing: read what an object holds, try a function by name without editing code, and spawn the
-- game's own explosion Blueprints to see whether they work by themselves.
local SWEEP_FILE = require("pveproject") .. "bridge/sweep_names.txt"
local POKE_FILE = require("pveproject") .. "bridge/poke.txt"
local POKE_DEFAULT = [[# One command per line, run on the last thing you spawned ("Spawn it ahead of your ship"). Save, press Poke it again: no restart.
#   call <Function> [args]     args: numbers, true, false, nil, self, world, or a word
#   get <Property>             set <Property> <value>
#   sound <asset path>         spawn <class path>        hide        destroy
# Example: sound /Game/Sounds/Space/Space_TurretDestroyed01_Cue
call OnDeathEvent
]]

local function showValue(v)
    local t = type(v)
    if t == "number" then return ("%.5g"):format(v) end
    if t == "boolean" then return tostring(v) end
    if t == "string" then return '"' .. v .. '"' end
    -- Objects, text, arrays and the like are never touched: asking a freshly spawned exploder's object pointer whether it is valid
    -- read garbage and crashed the game (access violation at 0xffffffffffffffff, 2026-11-18). Plain numbers and flags only.
    return nil
end

local function authority(obj, sink)
    local parts = {}
    pcall(function() parts[#parts + 1] = "HasAuthority=" .. tostring(obj:HasAuthority()) end)
    pcall(function() parts[#parts + 1] = "Role=" .. tostring(obj.Role) .. " RemoteRole=" .. tostring(obj.RemoteRole) end)
    pcall(function()
        local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        parts[#parts + 1] = ("IsServer=%s IsDedicatedServer=%s IsStandalone=%s"):format(tostring(k:IsServer(obj)),
            tostring(k:IsDedicatedServer(obj)), tostring(k:IsStandalone(obj)))
    end)
    sink("  authority: " .. (#parts > 0 and table.concat(parts, " | ") or "nothing readable"))
end

-- Reads every name in bridge/sweep_names.txt (property names pulled from the game's own Blueprints) off the object and writes the
-- ones that hold a value. Names that are functions or don't exist are skipped.
function D.sweep(obj, label, sink)
    sink = sink or put
    if not valid(obj) then sink("SWEEP " .. tostring(label) .. ": object is gone") return end
    sink(("SWEEP %s %s"):format(tostring(label), className(obj)))
    authority(obj, sink)
    local f = io.open(SWEEP_FILE, "r")
    if not f then sink("  (no bridge/sweep_names.txt)") return end
    local row, n = {}, 0
    local crumbFile = SWEEP_FILE:gsub("sweep_names%.txt$", "sweep_crumb.txt")
    for line in f:lines() do
        local name = line:gsub("[\r\n]", "")
        if name ~= "" then
            local cf = io.open(crumbFile, "w") -- the name being read when the game dies is the last one here
            if cf then cf:write(name, "\n") cf:close() end
            local ok, v = pcall(function() return obj[name] end)
            if ok and v ~= nil and type(v) ~= "function" then
                local text = showValue(v)
                if text then
                    n = n + 1
                    row[#row + 1] = name .. "=" .. text
                    if #row >= 6 then sink("  " .. table.concat(row, " | ")) row = {} end
                end
            end
        end
    end
    f:close()
    if #row > 0 then sink("  " .. table.concat(row, " | ")) end
    sink(("  %d values"):format(n))
end

local function loadObject(path)
    local name = path:match("([^/]+)$")
    local o = StaticFindObject(path .. "." .. name)
    if not (o and o:IsValid()) then pcall(LoadAsset, path) o = StaticFindObject(path .. "." .. name) end
    return (o and o:IsValid()) and o or nil
end

local function lastSpawned()
    for i = #spawned, 1, -1 do if valid(spawned[i]) then return spawned[i] end end
    return nil
end

local function startWatch(a, at, pc, marks)
    watches[#watches + 1] = { actor = a, at = at, t0 = os.clock(), next = 1, marks = marks or { 0.15, 1.0, 3.0, 6.0 }, pc = pc,
        actors = actorSet(), comps = compSets() }
end

local function parseArg(tok, a, world)
    if tok == "self" then return a end
    if tok == "world" then return world end
    if tok == "true" then return true end
    if tok == "false" then return false end
    if tok == "nil" then return nil end
    local n = tonumber(tok)
    if n then return n end
    return (tok:gsub('^"(.*)"$', "%1"))
end

local function poke()
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local a = lastSpawned()
    if not a then return "Spawn something first" end
    local f = io.open(POKE_FILE, "r")
    if not f then
        local w = io.open(POKE_FILE, "w")
        if w then w:write(POKE_DEFAULT) w:close() end
        f = io.open(POKE_FILE, "r")
    end
    if not f then return "Couldn't open bridge/poke.txt" end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line:gsub("[\r\n]", "") end
    f:close()
    local world = a:GetWorld()
    local at = a:K2_GetActorLocation()
    local cls = className(a)
    startWatch(a, at, pc)
    put(("POKE %s at %.0f %.0f %.0f | %s"):format(cls, at.X, at.Y, at.Z, readProps(a)))
    local ran = 0
    for _, line in ipairs(lines) do
        local toks = {}
        for t in line:gmatch("%S+") do toks[#toks + 1] = t end
        local cmd = toks[1]
        if cmd and cmd:sub(1, 1) ~= "#" then
            ran = ran + 1
            local ok, err = pcall(function()
                if cmd == "call" then
                    local args, n = {}, 0
                    for i = 3, #toks do n = n + 1 args[n] = parseArg(toks[i], a, world) end
                    a[toks[2]](a, table.unpack(args, 1, n))
                elseif cmd == "get" then
                    put(("  %s = %s"):format(toks[2], tostring(showValue(a[toks[2]]))))
                elseif cmd == "set" then
                    a[toks[2]] = parseArg(toks[3], a, world)
                elseif cmd == "sound" then
                    local cue = loadObject(toks[2])
                    if not cue then error("could not load " .. toks[2]) end
                    StaticFindObject("/Script/Engine.Default__GameplayStatics"):SpawnSoundAtLocation(a, cue, at, { Pitch = 0, Yaw = 0, Roll = 0 },
                        1.0, 1.0, 0.0, nil, nil, true)
                elseif cmd == "spawn" then
                    local c = loadClass(toks[2])
                    if not c then error("could not load " .. toks[2]) end
                    local made = world:SpawnActor(c, at, a:K2_GetActorRotation())
                    spawned[#spawned + 1] = made
                    put("  made " .. className(made))
                elseif cmd == "hide" then
                    a:SetActorHiddenInGame(true)
                elseif cmd == "destroy" then
                    a:K2_DestroyActor()
                else
                    error("unknown command " .. cmd)
                end
            end)
            put(("  %s -> %s"):format(line, ok and "ok" or ("error: " .. tostring(err))))
        end
    end
    return ("Ran %d lines on %s: bridge\\space_explosion.txt"):format(ran, cls)
end

local function sweepButton()
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local a = lastSpawned()
    if not a then return "Spawn something first" end
    D.sweep(a, "button")
    return "Swept " .. className(a) .. ": bridge\\space_explosion.txt"
end

local EXPL = { "Radar_Exploder_Child", "FlakTurret_Exploder_Child", "RocketTurret_Exploder_Child", "TripleTurret_Exploder_Child",
    "Mine_Exploder_Child", "NuclearMine_Exploder_Child", "Exploder_Base" }
local explIdx = 1

local function spawnExploder()
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local name = EXPL[explIdx]
    local cls = loadClass("/Game/Blueprints/Exploders/" .. name)
    if not cls then return "Couldn't load " .. name end
    local at, yaw = spawnPoint(pc)
    local a = pc.Pawn:GetWorld():SpawnActor(cls, at, { Pitch = 0, Yaw = yaw, Roll = 0 })
    if not valid(a) then return "Spawn failed for " .. name end
    spawned[#spawned + 1] = a
    startWatch(a, at, pc)
    put(("SPAWNED EXPLODER %s at %.0f %.0f %.0f | %s"):format(className(a), at.X, at.Y, at.Z, readProps(a)))
    D.sweep(a, "exploder")
    return ("Spawned %s, %d m ahead: bridge\\space_explosion.txt"):format(name, DISTS[distIdx] / 100)
end

-- Salvage wrecks: the four kinds of SIGISSpaceSalvageableActor the game scatters in space (NodeSystem/Lootables). The frigate's
-- salvage scan only looks 1500 cm out (NOTES.md, "Missing prompts, salvage"), so they appear close ahead of your ship, not far like the
-- turrets: fly up to one and press R to take it aboard.
local SALVAGE = { "Industrial_SpaceSalvage_01", "Ammo_SpaceSalvage_01", "Medic_SpaceSalvage_01", "Rare_SpaceSalvage_01" }
local SALVAGE_DIR = "/Game/Blueprints/NodeSystem/Lootables/"
local SALVAGE_AHEAD = 1000 -- cm
local salvIdx = 1

local function salvageLabel() return ("Salvage %d of %d: %s"):format(salvIdx, #SALVAGE, SALVAGE[salvIdx]) end

local function spawnSalvage()
    local pc = controller()
    if not pc then return "Not usable: " .. lastWhy end
    local name = SALVAGE[salvIdx]
    local cls = loadClass(SALVAGE_DIR .. name)
    if not cls then return "Couldn't load " .. name end
    local at, yaw = spawnPoint(pc, SALVAGE_AHEAD)
    local a = pc.Pawn:GetWorld():SpawnActor(cls, at, { Pitch = 0, Yaw = yaw, Roll = 0 })
    if not valid(a) then return "Spawn failed for " .. name end
    spawned[#spawned + 1] = a
    put(("SPAWNED %s at %.0f %.0f %.0f | %s"):format(className(a), at.X, at.Y, at.Z, readProps(a)))
    pcall(function() require("salvagewatch").note(("spawned %s at %.0f %.0f %.0f"):format(className(a), at.X, at.Y, at.Z)) end)
    return ("Spawned %s, %d m ahead: fly up to it, press R"):format(name, SALVAGE_AHEAD / 100)
end

local function baseActions()
    local inRaid = function() return controller() ~= nil end
    return {
        { id = "explolog", label = function() return require("explowatch").label() end,
          help = "Writes bridge/explosions.txt: what a destroyed turret or radar makes", run = function() return require("explowatch").toggle() end },
        { id = "spaceraid", label = "Start a space raid", help = "START RAID from here, on the picked or a random map", closes = true,
          run = function()
              local ok, L = pcall(require, "launch")
              if not ok or not L.testSearch then return "launch.lua has no testSearch" end
              return L.testSearch()
          end },
        { id = "explofix", label = function() return require("explowatch").fixLabel() end,
          help = "A dying turret gets its death functions called, logged in explosions.txt", run = function() return require("explowatch").fixToggle() end },
        { id = "spacepick", label = pickLabel, help = "Click: next kind. Right click: previous kind",
          when = inRaid, run = pick, back = pickBack },
        { id = "spacedist", label = function() return ("Spawn distance: %d m ahead"):format(DISTS[distIdx] / 100) end,
          help = "Click: 40, 80, 150, 300 m. Right click: back",
          when = inRaid,
          run = function() distIdx = step(distIdx, #DISTS, 1) return ("Spawn distance %d m"):format(DISTS[distIdx] / 100) end,
          back = function() distIdx = step(distIdx, #DISTS, -1) return ("Spawn distance %d m"):format(DISTS[distIdx] / 100) end },
        { id = "spacespawn", label = "Spawn it ahead of your ship", help = "Works at the helm too: fly at it and shoot it",
          when = inRaid, run = spawn },
        { id = "spacekill", label = "Kill what I spawned", help = "Dies the game's way; logs what appears",
          when = inRaid, run = kill },
        { id = "spaceremove", label = "Remove what I spawned", help = "Gone with no explosion",
          when = inRaid, run = remove },
        { id = "spacepoke", label = "Poke it (bridge/poke.txt)", help = "Runs the lines of bridge/poke.txt on what you spawned: try a function with no restart",
          when = inRaid, run = poke },
        { id = "spacesweep", label = "Read everything off it", help = "Writes every readable value of what you spawned, plus its authority, to space_explosion.txt",
          when = inRaid, run = sweepButton },
        { id = "spaceexplpick", label = function() return "Exploder: " .. EXPL[explIdx] end, help = "Click: next explosion Blueprint. Right click: previous",
          when = inRaid, run = function() explIdx = step(explIdx, #EXPL, 1) return "Exploder: " .. EXPL[explIdx] end,
          back = function() explIdx = step(explIdx, #EXPL, -1) return "Exploder: " .. EXPL[explIdx] end },
        { id = "spaceexplspawn", label = "Spawn that exploder ahead", help = "The game's own explosion (particles, flying pieces, damage), made by hand",
          when = inRaid, run = spawnExploder },
        { id = "salvagepick", label = salvageLabel, help = "Click: next wreck kind. Right click: previous",
          when = inRaid, run = function() salvIdx = step(salvIdx, #SALVAGE, 1) return salvageLabel() end,
          back = function() salvIdx = step(salvIdx, #SALVAGE, -1) return salvageLabel() end },
        { id = "salvagespawn", label = "Spawn that salvage ahead", help = "10 m ahead, inside the salvage scan's reach (press R)",
          when = inRaid, run = spawnSalvage },
        { id = "salvagegoto", label = "Fly my ship to a level wreck", help = "8 m from the nearest wreck the game made, not one you spawned",
          when = inRaid, run = function() return require("salvagewatch").gotoWreck() end },
        { id = "salvagedock", label = "Fly my ship to the nearest dock", help = "20 m out from a docking area that looks usable: fly in",
          when = inRaid, run = function() return require("salvagewatch").gotoDock() end },
        { id = "salvagelog", label = function() return require("salvagewatch").label() end,
          help = "Writes bridge/salvage.txt. Starts by itself in a ship",
          run = function() return require("salvagewatch").toggle() end },
    }
end

-- The rows that need an on foot player say why they can't be used (it is read again each time the menu refreshes).
function D.actions()
    local rows = baseActions()
    for _, row in ipairs(rows) do
        local when = row.when
        if when then
            row.when = function()
                local ok = when()
                row.unusable = ok and nil or ("Not usable: " .. lastWhy)
                return ok
            end
        end
    end
    return rows
end

return D
