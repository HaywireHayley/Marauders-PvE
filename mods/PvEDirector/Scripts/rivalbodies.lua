-- Rivals, part: rival people on foot: their bodies and kit, spreading out through a station, and station defenders.
-- Moved verbatim from rivals.lua (issue #149, sections: Bodies, Spreading out, Station defenders); rivals.lua requires it and keeps the
-- public side. Its helpers and constants (and earlier modules' functions) come through require("rivalshared");
-- main's context (X) and the per-raid state (S) arrive through M.bind whenever rivals.lua changes them.
local H = require("rivalshared")
local M = {}
local X, S
function M.bind(x, s) X, S = x, s end
local AI, CFG, Gear, GearScale, Kills, NodeBots = H.AI, H.CFG, H.Gear, H.GearScale, H.Kills, H.NodeBots
local Out, R, between, crewLabel, dist, helper = H.Out, H.R, H.between, H.crewLabel, H.dist, H.helper
local inBox, lib, loadClass, newMember, pick, rnd = H.inBox, H.lib, H.loadClass, H.newMember, H.pick, H.rnd
local valid = H.valid
-- A bot's Health as a number. A placed NPC from the spawn hook can be a stale or reused address whose `Health`
-- reads back as an object, and comparing it threw: the garrison and stray sweep died on it and the station's guards
-- were never taken over, standing still (build 23 report, 2026-11-22).
local function hpOf(b)
    local h = b.Health
    return type(h) == "number" and h or 0
end
-- Bodies ---------------------------------------------------------------------------------------------------------
-- Building one takes more than one update: the kit goes on at once, but its gun arrives a moment later.
local function comps(actor)
    local out = {}
    local all = actor:K2_GetComponentsByClass(lib("/Script/Engine.SkeletalMeshComponent"))
    for i = 1, #all do
        local c = all[i]:get()
        if valid(c) then out[c:GetFName():ToString()] = c end
    end
    return out
end

-- The looks catalog below loads every head and body and its women's version: ~160 synchronous loads, a 6.7 s freeze on
-- the first space raid of a session (24 Nov report: rivalsUpdate max 6652 ms). The lobby loads them first, one per call
-- (main.lua, every 0.5 s once the lobby has been up a while), so the raid finds them in memory. Loaded meshes are
-- rooted, as gearCatalog roots them, and female.lua caches its versions, so gearCatalog then takes milliseconds.
local preQueue -- nil: not started; a list with .i: in progress; false: done
function M.preload()
    if preQueue == false then return true end
    if not preQueue then
        preQueue = { i = 0, t0 = os.clock() }
        -- parent interiors first, so no raid's async loader finds one half loaded under its child (#192, #522)
        for _, name in ipairs(CFG.INSIDE_BASES) do preQueue[#preQueue + 1] = { inside = CFG.INSIDES .. name } end
        for _, list in ipairs({ Gear.heads, Gear.bodies }) do
            for _, path in ipairs(list) do preQueue[#preQueue + 1] = path end
        end
    end
    preQueue.i = preQueue.i + 1
    local path = preQueue[preQueue.i]
    if not path then
        X.log(("[rivals] looks loaded in the lobby: %d meshes and interiors over %.0f s"):format(#preQueue, os.clock() - preQueue.t0))
        preQueue = false
        return true
    end
    if type(path) == "table" then
        local cls = loadClass(path.inside)
        if cls then X.root(cls) else X.log("[rivals] interior class not loaded in the lobby: " .. path.inside) end
        return false
    end
    local mesh = lib(path)
    if not valid(mesh) then
        pcall(LoadAsset, path)
        mesh = lib(path)
    end
    if valid(mesh) then
        X.root(mesh)
        pcall(X.female.version, mesh, true)
    end
    return false
end

local landCatalog -- land raids have no rivals state; your crew (crew.lua) still needs looks there
local function gearCatalog()
    -- Every head and body in the game, loaded once: a look for each rival.
    if S and S.catalog then return S.catalog end
    if not S and landCatalog then return landCatalog end
    local cat = { heads = {}, bodies = {} }
    for key, paths in pairs({ heads = Gear.heads, bodies = Gear.bodies }) do
        for _, path in ipairs(paths) do
            local mesh = lib(path)
            if not valid(mesh) then
                pcall(LoadAsset, path)
                mesh = lib(path)
            end
            if valid(mesh) then
                X.root(mesh)
                table.insert(cat[key], mesh)
            end
        end
    end
    for _, list in ipairs({ cat.heads, cat.bodies }) do
        for _, mesh in ipairs(list) do X.female.version(mesh, true) end
    end
    X.log(("[rivals] looks: %d heads, %d bodies"):format(#cat.heads, #cat.bodies))
    if S then S.catalog = cat else landCatalog = cat end
    return cat
end

-- A raider body's gun must be equipped or it never fires: the bot ran around with its gun lowered, harmless
-- (director's arm() only equips an existing CurrentWeapon). Equipping
-- attaches it to CharacterMesh0, which on a raider is the head (the gun was invisible there): carry it on the body.
-- Checked again every update, in case the game re-equips or re-attaches.
-- A kit, rolled once for a person: rows of the game's item table within the tier's price ranges.
local function inBand(list, band)
    local fits = {}
    for _, row in ipairs(list) do
        if row[2] >= band[1] and row[2] <= band[2] then fits[#fits + 1] = row end
    end
    return pick(fits)
end

-- `tier` is one of CFG.TIERS (price bands) or a GearScale.spec (a grade g: rows near that share of each price-sorted list).
local function rollKit(tier, helmet, chest, bag)
    local function row(list, band)
        if tier.g then return GearScale.pick(list, tier.g) end
        return inBand(list, band)
    end
    return { gun = row(Gear.botGuns, tier.guns), helmet = helmet and row(Gear.helmets, tier.helmets)[1] or nil,
        chest = chest and row(Gear.chests, tier.chests)[1] or nil, bag = bag and row(Gear.bags, tier.bags)[1] or nil,
        stacks = math.random(CFG.AMMO_STACKS[1], CFG.AMMO_STACKS[2]), meds = math.random(CFG.MEDS[1], CFG.MEDS[2]) }
end

-- Puts a kit on a body the way the game does for a placed bot: the rows go into its spawn slots and the game's kit step
-- makes the items, dresses the body from them and spawns the gun, so what a body wears, holds and drops is one thing.
local function equipKit(body, kit)
    local function row(name) return name and FName(name):GetComparisonIndex() or 0 end
    local at = math.tointeger(body:GetAddress())
    -- A pistol rolled as the gun goes in the pistol slot (it showed in the primary's on the body, #101).
    local gun, pistol = kit.gun and kit.gun[1], kit.pistol
    local gi = gun and require("itemdata").get(gun)
    if gi and gi.type == 1 and not pistol then gun, pistol = nil, gun end
    X.rollKit(at, math.tointeger(lib(CFG.ITEM_TABLE):GetAddress()), row(gun), row(pistol), row(kit.helmet),
        row(kit.chest), row(kit.bag))
    if kit.gun and kit.gun[3] then
        for _ = 1, kit.stacks do X.addItem(at, row(kit.gun[3]), require("itemdata").capStack(kit.gun[3], CFG.AMMO_STACK)) end
    end
    for _ = 1, kit.meds do X.addItem(at, row(pick(Gear.meds)[1]), 1) end
end

-- A station guard's bags and pockets, rolled (the level gives each one a single row: an ammo stack, maybe a bandage). Its
-- worn gear stays. Better-equipped guards carry dearer things; a bag holds more than pockets do.
local PRICES
local function priceOf(name)
    if not PRICES then
        PRICES = {}
        for _, list in ipairs({ Gear.guns, Gear.helmets, Gear.chests, Gear.bags }) do
            for _, r in ipairs(list) do PRICES[r[1]] = r end
        end
    end
    return PRICES[name]
end

local function weightedRow(list, cap)
    local fits, total = {}, 0
    for _, r in ipairs(list) do
        if r[2] <= cap then fits[#fits + 1] = r total = total + 1 / math.sqrt(r[2]) end
    end
    local x = math.random() * total
    for _, r in ipairs(fits) do
        x = x - 1 / math.sqrt(r[2])
        if x <= 0 then return r end
    end
    return fits[#fits]
end

-- The kit rows a placed NPC was given by its level ("None" slots left out): gun, pistol, helmet, chest, bag.
local KIT_FIELDS = { gun = "WeaponToSpawn", pistol = "PistolToSpawn", helmet = "HelmetToSpawn", chest = "ArmourToSpawn",
    bag = "BackPackToSpawn" }
local function wornRows(b)
    local rows = {}
    for k, f in pairs(KIT_FIELDS) do
        local name = "None"
        pcall(function() name = b[f].RowName:ToString() end)
        if name ~= "None" and name ~= "" then rows[k] = name end
    end
    return rows
end

local function rollCarried(b)
    local worn, wealth, guns = {}, 0, {}
    for _, f in ipairs({ "WeaponToSpawn", "PistolToSpawn", "HelmetToSpawn", "ArmourToSpawn", "BackPackToSpawn" }) do
        local name = "None"
        pcall(function() name = b[f].RowName:ToString() end)
        local r = name ~= "None" and priceOf(name)
        if r then
            worn[f] = name
            wealth = wealth + r[2]
            if r[3] then guns[#guns + 1] = r[3] end
        end
    end
    local at = math.tointeger(b:GetAddress())
    X.keepWorn(at)
    -- Never past the row's own stack (12 gauge stacks at 20, and a 35-shell stack showed as 35/20, issue #102). A
    -- blueprint's stack is its uses: one found on a body has half to all of them, not 1 (#100).
    local function add(name, n)
        local Items = require("itemdata")
        local max = Items.max(name)
        if name:find("Blueprint", 1, true) and max and max > 1 and n <= 1 then n = math.random(math.ceil(max / 2), max) end
        X.addItem(at, FName(name):GetComparisonIndex(), Items.capStack(name, n))
    end
    local cap = math.max(CFG.CARRY_CAP_MIN, wealth * CFG.CARRY_CAP_SHARE)
    if math.random() < CFG.CARRY_JACKPOT then cap = 1e9 end
    local bag = worn.BackPackToSpawn ~= nil
    local carried = {}
    local mult = math.max(0, math.min(3, tonumber(CFG.BODY_LOOT) or 1)) -- #325; 1 = unchanged (no extra random draw)
    local function scaled(n)
        if mult == 1 then return n end
        local x = n * mult
        return math.floor(x) + (math.random() < x - math.floor(x) and 1 or 0)
    end
    -- No bag: one pocket slot (the game turns away the rest), so one roll for it.
    if not bag then
        if mult < 1 and math.random() >= mult then return {} end
        local function count() local n = 0 b.BotLootItems:ForEach(function() n = n + 1 end) return n end
        local before = count()
        for _ = 1, 4 do -- a roll too big for the pocket is turned away: roll again
            local x, name, n = math.random(), nil, 1
            if x < CFG.POCKET_AMMO and guns[1] then
                name, n = guns[1], math.random(CFG.CARRY_AMMO[1], CFG.CARRY_AMMO[2])
            else
                local r = x < CFG.POCKET_AMMO + CFG.POCKET_MED and weightedRow(Gear.meds, cap)
                    or weightedRow(math.random() < CFG.CARRY_PART and Gear.parts or Gear.loot, cap)
                name = r and r[1]
            end
            if name then
                add(name, n)
                if count() > before then return { n > 1 and (name .. " x" .. n) or name } end
            end
        end
        return {}
    end
    for i, ammo in ipairs(guns) do
        for _ = 1, (i == 1 and math.random(CFG.AMMO_STACKS[1], CFG.AMMO_STACKS[2]) or 1) do
            local n = math.random(CFG.CARRY_AMMO[1], CFG.CARRY_AMMO[2])
            add(ammo, n)
            carried[#carried + 1] = ammo .. " x" .. n
        end
    end
    for _ = 1, scaled(math.random(CFG.MEDS[1], CFG.MEDS[2])) do
        local r = weightedRow(Gear.meds, cap)
        if r then add(r[1], 1) carried[#carried + 1] = r[1] end
    end
    for _ = 1, scaled(math.random(CFG.CARRY_BAG[1], CFG.CARRY_BAG[2])) do
        local x, list = math.random(), Gear.loot
        if x < CFG.CARRY_BOX then list = Gear.boxes elseif x < CFG.CARRY_BOX + CFG.CARRY_PART then list = Gear.parts end
        local r = weightedRow(list, cap)
        if r then add(r[1], 1) carried[#carried + 1] = r[1] end
    end
    return carried
end

local function gunName(gun)
    return (gun:GetClass():GetFName():ToString():gsub("_Child_C$", ""):gsub("^%a+_", ""))
end

local function holdGun(e)
    local bot = e.bot
    if not valid(bot) or hpOf(bot) <= 0 then return end
    local gun = bot.CurrentWeapon
    if not valid(gun) then
        bot.Inventory:ForEach(function(_, w)
            local g = w:get()
            if not valid(gun) and valid(g) then gun = g end
        end)
        if not valid(gun) then return end
        bot:ServerEquipWeapon(gun)
    end
    if valid(e.hand) and valid(gun.Mesh1P) and gun.Mesh1P:GetAttachParent():GetFName():ToString() ~= "CharacterBody0" then
        gun.Mesh1P:K2_AttachToComponent(e.hand, FName("Weapon"), 2, 2, 2, false)
    end
end

-- A raider body of the soldier AI's kind. Raiders spawn with a GOAP controller, whose brain doesn't run offline; the
-- soldier tree needs a RaidAIController.
local function spawnBody(pc, at)
    local bodyCls = loadClass(CFG.BODY)
    loadClass(CFG.SOLDIER)
    local soldier = lib(CFG.SOLDIER .. ".Default__BotPawnMilitary_C")
    local bodyCdo = lib(CFG.BODY .. ".Default__GOAPNodeBot_Raider_C")
    if not (valid(soldier) and bodyCls and valid(bodyCdo)) then return nil end
    bodyCdo.AIControllerClass = soldier.AIControllerClass
    local body = helper():SpawnAIFromClass(pc, bodyCls, lib(CFG.TREE), { X = at.X, Y = at.Y, Z = at.Z + 100 },
        { Pitch = 0, Yaw = math.random(0, 359), Roll = 0 }, true, pc)
    return valid(body) and body or nil
end

-- A civilian (issue #81, civilians.lua): a raider body dressed with an empty kit (no gun, no armour, no bag), with a
-- few things in its pockets. look (#196): { heads = {mesh names}, bodies = {mesh names} } of its trade, one of each
-- picked from the catalog (meshes only: no helmet or chest row, so no armour). Returns the body (asleep: X.arm wakes
-- it) or nil, and the look it got ({ head, suit }, for R.dressCivilian once the kit has landed).
local function pickNamed(meshes, names)
    local want, fit = {}, {}
    for _, n in ipairs(names or {}) do want[n] = true end
    for _, m in ipairs(meshes) do if want[m:GetFName():ToString()] then fit[#fit + 1] = m end end
    return #fit > 0 and pick(fit) or nil
end
function R.civilianBody(pc, at, pockets, look)
    local body = spawnBody(pc, at)
    if not body then return nil end
    equipKit(body, { stacks = 0, meds = 0 })
    local worn
    if look then
        local cat = gearCatalog()
        worn = { head = pickNamed(cat.heads, look.heads), suit = pickNamed(cat.bodies, look.bodies) }
        R.dressCivilian(body, worn)
    end
    -- Not a defender: the garrison's adoption (placed NPCs, stray sweep) must leave it alone, or it's armed and enlisted.
    R.civilianAt = R.civilianAt or {}
    R.civilianAt[body:GetAddress()] = true
    local bodyAt = math.tointeger(body:GetAddress())
    for _, name in ipairs(pockets or {}) do X.addItem(bodyAt, FName(name):GetComparisonIndex(), 1) end
    return body, worn
end

-- Puts a civilian's look on (again: the empty kit lands after the spawn, and a gear change puts the game's meshes back).
function R.dressCivilian(body, worn)
    if not (worn and valid(body)) then return end
    local outfit = comps(body).CharacterBody0
    if worn.head and valid(worn.head) then pcall(function() body.Mesh:SetSkeletalMesh(worn.head, false) end) end
    if outfit and worn.suit and valid(worn.suit) then pcall(function() outfit:SetSkeletalMesh(worn.suit, false) end) end
end

local function startBody(pc, m, at)
    local body = spawnBody(pc, at)
    if not body then return nil end
    m.kit = m.kit or rollKit(m.tier, m.helmet, m.chest, m.backpack)
    equipKit(body, m.kit)
    return { m = m, body = body, startedAt = os.clock() }
end

-- Weapon wear (#86). The game's kit step rolls a gun's condition AND its maximum low and at random (a 1911 at 10/10,
-- full is 100): bodies dropped near-useless guns that cost a fortune to repair. A body's guns and melee weapons get
-- their condition and maximum set to a share of the item's full durability (items.json `dur`): rivals keep their gear
-- well (more so the better their kit), station guards less. Bots don't wear guns by firing (their shots aren't counted).
R.WEAR = { budget = { 0.55, 0.85 }, mid = { 0.7, 0.95 }, geared = { 0.85, 1 }, guard = { 0.35, 0.85 } }
function R.wear(body, band)
    local Items = require("itemdata")
    local slots = { Prim = true, Sec = true, Pistol = true, Melee = true }
    pcall(function()
        body.BotLootItems:ForEach(function(_, e)
            local it = e:get()
            if valid(it) and slots[it.MotherItemGUID:ToString()] then
                local r = Items.get(it.ItemData:ToString())
                if r and r.dur and r.dur > 0 then
                    local c = math.max(1, math.floor(r.dur * (band[1] + math.random() * (band[2] - band[1])) + 0.5))
                    it.MaxCondition, it.Condition = c, c
                end
            end
        end)
    end)
end
R.WEAR.of = function(tier)
    if tier and tier.g then local lo = 0.55 + 0.3 * tier.g return { lo, math.min(1, lo + 0.25) } end
    return R.WEAR[tier and tier.name or ""] or R.WEAR.mid
end

-- Second half: look, wake, arm, once the gun is there. Returns the director entry or nil (not ready / failed).
local function finishBody(b)
    local body, m = b.body, b.m
    if not valid(body) then return false end
    if not valid(body.CurrentWeapon) then
        if os.clock() - b.startedAt < CFG.GUN_WAIT then return nil end
        X.log(("[rivals] %s: no %s arrived, rolling another gun next time"):format(m.name, m.kit.gun[1]))
        m.kit = nil
        R.destroy(body)
        return false
    end
    R.wear(body, R.WEAR.of(m.tier))
    local cat = gearCatalog()
    local mine = comps(body)
    -- Look: kept per member so the same person looks the same every time they materialize. Your hired crew have set
    -- looks (crew.lua headPath/bodyPath): the catalog has already loaded and rooted those meshes.
    if m.headPath and not valid(m.look.head) then m.look.head = lib(m.headPath) end
    if m.bodyPath and not valid(m.look.body) then m.look.body = lib(m.bodyPath) end
    -- A rival's head has to fit under the helmet it rolled (gear.lua fits; a new kit can bring another helmet).
    local helmet = m.kit and m.kit.helmet
    if not m.headPath and valid(m.look.head) and not Gear.fits(helmet, m.look.head:GetFName():ToString()) then
        m.look.head = nil
    end
    if not m.look.head and #cat.heads > 0 then
        local fit = {}
        for _, h in ipairs(cat.heads) do if Gear.fits(helmet, h:GetFName():ToString()) then fit[#fit + 1] = h end end
        m.look.head = pick(#fit > 0 and fit or cat.heads)
    end
    if not m.look.body and #cat.bodies > 0 then m.look.body = pick(cat.bodies) end
    if valid(m.look.head) then body.Mesh:SetSkeletalMesh(m.look.head, false) end
    if mine.CharacterBody0 and valid(m.look.body) then mine.CharacterBody0:SetSkeletalMesh(m.look.body, false) end
    if m.female then X.female.dress(body, true) end
    m.gunName = gunName(body.CurrentWeapon)
    local ctrl = X.arm(body)
    if not ctrl then R.destroy(body) return false end
    ctrl.TeamNumber = CFG.TEAM_BASE + m.crew
    body.Health = m.hp
    -- Player-like senses and aim (ai.lua "rival" profile); the personality comes from the kit, once per member.
    m.personality = m.personality or AI.pickPersonality(AI.power({ pmc = true, gun = m.gunName, helmet = m.helmet,
        chest = m.chest }))
    local e = { bot = body, ctrl = ctrl, home = body:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(1, 4),
        rival = m, mind = AI.mind("rival", m.personality), hand = mine.CharacterBody0, faction = "crew" .. m.crew, voice = m.voice }
    AI.tuneBody(e)
    holdGun(e)
    return e
end

local function navData() return X.navMesh() end -- the registered navmesh (see main.lua navMesh)

local function reachableNear(at, radius)
    local out = {}
    if Out.call(X.navLib(), "K2_GetRandomReachablePointInRadius", S.pc, at, out, radius, navData(), X.queryFilter()) and out.X then
        if not X.offLimits(out) then return out end
        S.offRejects = (S.offRejects or 0) + 1
    end
    return nil
end

local function projected(at, ext)
    local out = {}
    if Out.call(X.navLib(), "K2_ProjectPointToNavigation", S.pc, at, out, navData(), X.queryFilter(),
        ext or { X = 400, Y = 400, Z = 800 }) and out.X then return out end
    return nil
end

-- A random walkable point somewhere in a station. Searching from the station box's centre fails (often empty space,
-- off the navmesh), so it searches around real points inside: airlocks / arrival points and defenders' posts.
local function stationPoint(st, radius)
    local origins = {}
    for _, p in ipairs(st.entries or {}) do origins[#origins + 1] = p end
    for _, p in ipairs(st.posts or {}) do origins[#origins + 1] = p end
    if #origins == 0 then origins[1] = st.box.c end
    -- moderate radius: a big one mostly lands outside the station (the navmesh carries on past its box)
    for _ = 1, 16 do
        local o = projected(origins[math.random(#origins)])
        -- No box check: a station's box is one navmesh volume (the first holding an airlock), which can miss most of
        -- the station (Spaceport); points this close to an airlock or a defender's post are inside it anyway.
        local p = o and reachableNear(o, radius or 3000)
        if p then return p end
    end
end

-- Spreading out --------------------------------------------------------------------------------------------------
-- stationPoint only searches within 30 m of the airlocks and guards' posts, so everyone sent somewhere "random" (guards,
-- crews spawning in, crews picking an area to search) ended up in the same few rooms and fought on arrival. Each station
-- keeps a pool of walkable points that creeps outward instead: every new point is searched for around an earlier one
-- (the furthest from the airlocks and posts of a few), so within seconds of you arriving it covers the whole station.
-- Idle bodies are sent to the pooled point furthest from everyone else.
local function anchorDist(st, p)
    local best = math.huge
    for _, list in ipairs({ st.entries or {}, st.posts or {} }) do
        for _, q in ipairs(list) do best = math.min(best, dist(p, q)) end
    end
    return best
end

local function nearStation(st, p)
    return inBox(st.box, p, CFG.MATERIALIZE_MARGIN) or anchorDist(st, p) <= CFG.SPREAD_REACH
end

local function spotTaken(pool, p)
    for _, q in ipairs(pool) do if dist(p, q) < CFG.SPREAD_GAP then return true end end
end

-- First: the station's loot spawners, AI spawn spots and contract objects, which the level designers spread over every
-- room you're meant to play in (a few hundred in a big station), on the navmesh and in random order.
local function seedSpots(st)
    local pool, seeds = st.spots, {}
    for _, cls in ipairs(CFG.SPREAD_SEEDS) do
        for _, a in ipairs(X.findAll(cls)) do -- shared with main.lua's boarding rescan (same classes, same moment)
            if valid(a) then
                local l = a:K2_GetActorLocation()
                if nearStation(st, l) then seeds[#seeds + 1] = l end
            end
        end
    end
    for i = #seeds, 2, -1 do local j = math.random(i) seeds[i], seeds[j] = seeds[j], seeds[i] end
    local n = 0
    for _, l in ipairs(seeds) do
        if #pool >= CFG.SPREAD_POOL then break end
        local p = projected(l)
        if p and not X.offLimits(p) and not spotTaken(pool, p) then
            table.insert(pool, { X = p.X, Y = p.Y, Z = p.Z })
            n = n + 1
        end
    end
    X.log(("[rivals] %s: spread pool seeded with %d points (%d candidates)"):format(st.name, n, #seeds))
    return n, #seeds
end

local function growSpots(st, n)
    st.spots = st.spots or {}
    local pool = st.spots
    -- (again in 10 s if hardly any landed on the navmesh: the station's may not have streamed in yet)
    if st.box and os.clock() >= (st.seedAt or 0) and not st.seeded then
        local ok, got, of = pcall(seedSpots, st)
        if not ok then X.log("[rivals] seeding " .. st.name .. "'s spread pool failed: " .. tostring(got)) end
        if ok and (got >= 10 or got * 2 >= of or #pool >= CFG.SPREAD_POOL) then st.seeded = true
        else st.seedAt = os.clock() + 10 end
    end
    for _ = 1, n do
        if #pool >= CFG.SPREAD_POOL then return end
        local p
        if #pool < 4 then
            p = stationPoint(st)
        else
            local o, od
            for _ = 1, 3 do
                local q = pool[math.random(#pool)]
                local d = anchorDist(st, q)
                if not od or d > od then o, od = q, d end
            end
            p = reachableNear(o, CFG.SPREAD_STEP)
        end
        if p and nearStation(st, p) and not spotTaken(pool, p) then table.insert(pool, { X = p.X, Y = p.Y, Z = p.Z }) end
    end
end

-- The pooled point furthest from every other living body (and where each is headed), skipping `self` and anyone in
-- `mates` (a rival's own crew: they search together). `visited`: places this one (or its crew) went lately, avoided
-- too. `awayFrom`: a point the result must be at least SPAWN_AWAY from (you, when spawning someone in).
local function spreadPoint(st, self, mates, visited, awayFrom)
    growSpots(st, CFG.SPREAD_GROW)
    local pool = st.spots
    if #pool == 0 then return nil end -- callers fall back to stationPoint
    local others = {}
    for _, o in ipairs(X.raid().bots) do
        if o ~= self and not o.dead and o.bot and valid(o.bot) and not (mates and mates[o]) then
            others[#others + 1] = o.bot:K2_GetActorLocation()
            if o.home then others[#others + 1] = o.home end
        end
    end
    for _, v in ipairs(visited or {}) do others[#others + 1] = v end
    -- bodies spawned but not yet armed aren't in the director's list yet: a rival body or a guard top-up
    for _, job in ipairs(S.building or {}) do
        if job.b and valid(job.b.body) then others[#others + 1] = job.b.body:K2_GetActorLocation() end
    end
    for _, d in ipairs(S.pendingDefenders or {}) do
        if valid(d.body) then others[#others + 1] = d.body:K2_GetActorLocation() end
    end
    local best, bestScore
    for _ = 1, CFG.SPREAD_TRIES do
        local p = pool[math.random(#pool)]
        if not awayFrom or dist(p, awayFrom) >= CFG.SPAWN_AWAY then
            local score = math.huge
            for _, q in ipairs(others) do score = math.min(score, dist(p, q)) end
            if not bestScore or score > bestScore then best, bestScore = p, score end
        end
    end
    if not best then return nil end
    return { X = best.X, Y = best.Y, Z = best.Z }, bestScore
end

-- Idle station guards (the level's own, top-ups and the director's garrison soldiers) don't hold their posts: every
-- GUARD_ROAM seconds each moves on to the part of the station furthest from everyone, and walks about there.
local function roamGuards(st, now)
    growSpots(st, CFG.SPREAD_GROW)
    for _, e in ipairs(X.raid().bots) do
        if not e.faction and not e.crewmate and not e.follow and not e.dead and e.bot and valid(e.bot)
            and not e.fighting and not e.inCombat and not e.investigate and not e.alert then
            if e.roamSt == nil then e.roamSt = nearStation(st, e.bot:K2_GetActorLocation()) and st or false end
            if e.roamSt == st then
                if not e.rehome then
                    e.rehome = now + math.random() * CFG.GUARD_FIRST_ROAM -- not all at once
                elseif now >= e.rehome then
                    local p = spreadPoint(st, e)
                    if p then e.home, e.patrolRadius, e.nextPatrol = p, CFG.ROAM_PATROL, now end
                    e.rehome = now + rnd(CFG.GUARD_ROAM)
                end
            end
        end
    end
end

-- Leaderless guards run (#313). Each station's guards (the group roamGuards counts as its own: no faction, not your
-- crew) get a leader once two or more are up: its boss if it has one, else the first adopted defender, else the first
-- found. When the leader dies the others are routed for ROUT_SECONDS: bots.lua stops them engaging (unless you come
-- within ROUT_FIRE_RANGE, e.routNear) and this sends them to a walkable point away from you. Once per station a raid.
local function guardName(e)
    return e.bot and valid(e.bot) and e.bot:GetFName():ToString() or "a guard"
end

local function routPoint(e, here, from)
    local best, bd
    for _ = 1, 5 do
        local p = reachableNear(here, CFG.ROUT_DIST)
        if p then
            local d = from and dist(p, from) or 0
            if not bd or d > bd then best, bd = p, d end
        end
    end
    return best
end

local function routGuards(st, now, playerLoc)
    local hi = CFG.ROUT_SECONDS and CFG.ROUT_SECONDS[2] or 0
    if st.routed or hi <= 0 then return end
    local group = {}
    for _, e in ipairs(X.raid().bots) do
        if not e.faction and not e.crewmate and not e.follow and not e.dead and e.bot and valid(e.bot) then
            if e.roamSt == nil then e.roamSt = nearStation(st, e.updAt or e.bot:K2_GetActorLocation()) and st or false end
            if e.roamSt == st then group[#group + 1] = e end
        end
    end
    local lead = st.leader
    if not lead then
        if #group < 2 then return end
        for _, e in ipairs(group) do
            if e.mind and e.mind.profileName == "boss" then lead = e break end
        end
        if not lead then
            for _, a in ipairs(S.adopted or {}) do
                if not a.dead and a.roamSt == st then lead = a break end
            end
        end
        lead = lead or group[1]
        st.leader, st.leaderName = lead, guardName(lead)
        X.log(("[rivals] %s: guards' leader is %s (%s), %d guards"):format(st.name, st.leaderName,
            lead.mind and AI.describe(lead) or "?", #group))
        return
    end
    if not lead.dead then return end
    st.routed, st.leader = true, nil -- (don't keep the dead entry)
    local lo = math.min(CFG.ROUT_SECONDS[1] or hi, hi)
    for _, e in ipairs(group) do
        e.routUntil, e.routNear = now + lo + math.random() * (hi - lo), CFG.ROUT_FIRE_RANGE
        e.alert, e.investigate, e.rehome = nil, nil, e.routUntil -- roamGuards leaves it alone till it's over
        if valid(e.ctrl) then
            local p = routPoint(e, e.updAt or e.bot:K2_GetActorLocation(), playerLoc)
            if p then
                e.home, e.patrolRadius, e.nextPatrol = p, CFG.ROAM_PATROL, e.routUntil
                e.ctrl:MoveToLocation(p, 80, false, true, false, true, X.queryFilter(), true)
            end
        end
    end
    X.log(("[rivals] guards at %s run: their leader %s is down (%d running)"):format(st.name, st.leaderName or "?", #group))
end

-- Their ship's key card in a crew body's loot (#410): taking a ship off its crew, you take its card off one of them, and
-- can carry several ships' cards. The native helper adds the row only; the Attachments (which ship it opens) are then
-- written on the new item and read back. Must run before a corpse is killed (death copies the loot to the body).
local function giveShipCard(c, body)
    if not (c and c.shipName and valid(body)) then return end
    local at = math.tointeger(body:GetAddress())
    local function cards()
        local t = {}
        body.BotLootItems:ForEach(function(_, e)
            local it = e:get()
            if valid(it) and it.ItemData:ToString() == "KEYCARD" then t[#t + 1] = it end
        end)
        return t
    end
    local before = #cards()
    X.addItem(at, FName("KEYCARD"):GetComparisonIndex(), 1)
    local list = cards()
    if #list <= before then
        if not S.cardTurnedAway then S.cardTurnedAway = true X.log("[rivals] key card: turned away by a crew body (no room)") end
        return
    end
    local card = list[#list]
    local att = require("space").shipCardAtt(c.inside, c.shipName, c.design and c.design.row)
    pcall(function() card.Attachments = att end)
    local got = ""
    pcall(function() got = card.Attachments:ToString() end)
    if got ~= att and not S.cardAttFailed then
        S.cardAttFailed = true
        X.log(("[rivals] key card: Attachments didn't take on a body's card (read %q)"):format(got))
    end
end

-- Queue bodies for a crew's living members at the given spots (one spot per member, reused if fewer).
-- corpses: those who went down with their ship (m.sankWith) are built too, and killed as soon as they're armed
-- (rivals.lua finishBuilding): a wreck you board holds its dead, with their gear, as well as any survivors (#251).
local function materialize(c, spots, mode, members, corpses)
    if c.bodies or #spots == 0 then return end
    c.bodies, c.mode = {}, mode
    local living = 0
    for _, m in ipairs(members or c.members) do
        local dead = corpses and not m.alive and m.sankWith
        if dead or (m.alive and not (mode == "station" and m.boarding)) then
            living = living + 1
            -- spread out on floor joined to the spot (a plain offset could put them the far side of a wall)
            local at = spots[(living - 1) % #spots + 1]
            at = reachableNear(at, 150) or at
            local b = startBody(S.pc, m, at)
            if b then table.insert(S.building, { crew = c, b = b, mode = mode, corpse = dead }) end
        end
    end
end

-- Out of the director's list for good (the body is put away): its object references go too, as main.lua's reapDead
-- does for the dead. Others can still hold the entry (a soldier's or crewmate's foeEntry), and once the actor is freed
-- any look at it, even IsValid, reads freed memory: an access violation (the crash crossing an airlock after a fight
-- at a station, 2026-11-15). Destroy the body before this.
local function removeEntry(e)
    local bots = X.raid().bots
    for i = #bots, 1, -1 do if bots[i] == e then table.remove(bots, i) end end
    e.bot, e.ctrl, e.hand, e.mesh, e.move = nil, nil, nil, nil, nil
    e.fighting, e.inCombat, e.cover, e.investigate, e.foeEntry, e.holdUntil = false, false, nil, nil, nil, nil
end

-- Back to simulation: remember health, delete the bodies (their guns go with them; a new body rolls a new gun of
-- the same tier, which a player wouldn't notice between visits).
local function dematerialize(c)
    if not c.bodies then return end
    for _, e in ipairs(c.bodies) do
        -- Corpses stay where they fell (lootable); only the living go back into the simulation.
        if valid(e.bot) and hpOf(e.bot) > 0 then
            e.rival.hp = e.bot.Health
            R.destroy(e.bot)
        end
        removeEntry(e)
    end
    c.bodies, c.exitAt, c.arrival = nil, nil, nil
end

local function bodiesAlive(c)
    local n = 0
    for _, e in ipairs(c.bodies or {}) do
        if valid(e.bot) and hpOf(e.bot) > 0 then
            n = n + 1
            pcall(holdGun, e)
        elseif e.rival.alive then
            e.rival.alive = false
            X.log(("[rivals] %s (%s, %s) was killed%s"):format(e.rival.name, e.rival.tier.name, e.rival.gunName or "?",
                e.rival.impostor and " (a man calling himself the Red Baron: not the Baron)" or ""))
            -- Rivals stand in for other players: their deaths count for "Kill N Marauders" (tag Human). Bodies only
            -- exist near you and share the soldiers' team, so you're the only one who can kill them.
            pcall(function() S.pc:Client_CheckMissionEvent(FName("Human"), 2) end)
            Kills.rivalDied() -- the kill list files it under the soldier body's kind: moved to Marauder (killstats.lua)
        end
    end
    return n
end

-- Some stay with the ship: a docked crew's ship is never left empty for anyone to take. They're extra people (not drawn
-- from the crew), on the crew's team, rolled like the crew; once rolled they stay for the raid, dead or alive.
local function setWatch(c)
    if c.watch then return end
    local used = {}
    for _, m in ipairs(c.members) do used[m.name] = true end
    c.watch = {}
    for _ = 1, between(CFG.SHIP_WATCH) do
        local m = newMember(used)
        m.crew, m.watch = c.id, true
        table.insert(c.watch, m)
    end
end

-- The airlock a docking crew uses: one per berth (the same berth always gives the same airlock), skipping one your ship
-- is docked at or another crew holds.
local function lockFree(st, l, c)
    if not valid(l.dock) then return false end
    local ships = 0
    pcall(function() l.dock.DockedShips:ForEach(function() ships = ships + 1 end) end)
    if ships > 0 then return false end
    for _, o in ipairs(S.crews or {}) do
        if o ~= c and o.lock == l and o.state == "docked" and o.station == st then return false end
    end
    return true
end

local function pickLock(st, c)
    local locks = st.locks
    if not locks or #locks == 0 then return nil end
    -- the free one used longest ago (never used: oldest), ties at random: crews docking one after another came in
    -- through the same airlock and died in a heap at its door
    local best
    for _, l in ipairs(locks) do
        if lockFree(st, l, c) then
            local t = (l.usedAt or -1e9) + math.random()
            if not best or t < best.t then best = { l = l, t = t } end
        end
    end
    if best then best.l.usedAt = os.clock() return best.l end
end

-- Walking out once the door is open: a point on the station side, past the button.
local function lockExit(l)
    local dx, dy = l.btn.X - l.floor.X, l.btn.Y - l.floor.Y
    local d = math.max(1, math.sqrt(dx * dx + dy * dy))
    local out = { X = l.btn.X + dx / d * 250, Y = l.btn.Y + dy / d * 250, Z = l.btn.Z }
    return projected(out) or reachableNear(l.btn, 400) or l.btn
end

-- A crew coming in: once everyone is built and armed in the chamber (or ARRIVAL_WAIT is up), the door opens and they
-- walk out; it closes again once nobody stands in the chamber.
local function crewArrival(c, now)
    local a = c.arrival
    if not valid(a.lock.dock) then c.arrival = nil return end
    if not a.openedAt or not a.out then
        -- Until the hatch has swung open they stay put: no search areas, no patrol legs.
        for _, e in ipairs(c.bodies or {}) do
            if not e.fighting then e.rehome, e.nextPatrol = now + 60, now + 60 end
        end
    end
    if not a.openedAt then
        local pending = 0
        for _, job in ipairs(S.building or {}) do if job.crew == c then pending = pending + 1 end end
        local have = c.bodies and #c.bodies or 0
        if now - a.started < CFG.ARRIVAL_MIN then return end
        if (pending > 0 or have == 0) and now - a.started < CFG.ARRIVAL_WAIT then return end
        if have == 0 then
            if pending == 0 then c.arrival = nil end
            return
        end
        -- Another crew came in here not long ago: this one waits its turn in the closed chamber.
        local st = c.station
        if st and st.lastArrival and now - st.lastArrival < CFG.ARRIVAL_STAGGER then return end
        local inside = 0
        for _, e in ipairs(c.bodies) do
            if valid(e.bot) and dist(e.bot:K2_GetActorLocation(), a.lock.floor) < 600 then inside = inside + 1 end
        end
        pcall(function() a.lock.dock:StartDoorEvent(true) end)
        a.openedAt = now
        if st then st.lastArrival = now end
        for _, e in ipairs(c.bodies) do
            e.home, e.patrolRadius = a.lock.floor, 100
            pcall(function() e.ctrl:StopMovement() end)
        end
        X.log(("[rivals] %s came in through %s's airlock %s (%d of %d waiting in the chamber, %.0f s)"):format(crewLabel(c),
            c.station.name, a.lock.name, inside, #c.bodies, now - a.started))
    elseif not a.out then
        -- The way is clear the moment the door starts opening: hold them until it has swung open.
        if now - a.openedAt < CFG.DOOR_OPENING then return end
        a.out = now
        local out = lockExit(a.lock)
        for _, e in ipairs(c.bodies or {}) do e.home, e.patrolRadius, e.nextPatrol, e.rehome = out, 300, now, now + 20 end
    elseif now - a.out >= CFG.ARRIVAL_CLOSE then
        local inside = false
        for _, e in ipairs(c.bodies or {}) do
            if valid(e.bot) and hpOf(e.bot) > 0 and dist(e.bot:K2_GetActorLocation(), a.lock.floor) < 600 then inside = true end
        end
        if S.foot and valid(S.foot) and dist(S.foot:K2_GetActorLocation(), a.lock.floor) < 600 then inside = true end
        if not inside or now - a.out > 40 then
            pcall(function() a.lock.dock:StartDoorEvent(false) end)
            c.arrival = nil
        end
    end
end

local function stationSpawnSpots(c, st, playerLoc)
    local spots = {}
    local l = c.lock
    local fresh = os.clock() - (c.dockedAt or 0) <= CFG.FRESH_DOCK or c.lateEntry
    if fresh and l and valid(l.dock)
        and not (playerLoc and dist(playerLoc, l.floor) < CFG.LOCK_YOU) then
        -- Just docked: built in their airlock's closed chamber, then the door opens (crewArrival).
        c.arrival = { lock = l, started = os.clock() }
        table.insert(spots, l.floor)
        return spots
    end
    if fresh then
        -- Just docked (or waited aboard for room): they come in through the airlock / arrival point furthest from
        -- everyone already inside.
        local e, far = pick(st.entries), -1
        for _, q in ipairs(st.entries or {}) do
            local near = math.huge
            for _, o in ipairs(X.raid().bots) do
                if not o.dead and o.bot and valid(o.bot) then near = math.min(near, dist(q, o.bot:K2_GetActorLocation())) end
            end
            if playerLoc then near = math.min(near, dist(q, playerLoc)) end
            near = near * (0.8 + 0.4 * math.random())
            if near > far then e, far = q, near end
        end
        local p = projected(e)
        if not p or X.offLimits(p) then p = reachableNear(e, 600) end
        if p then table.insert(spots, p) end
    else
        -- Already inside: somewhere well away from you and from everyone else in the station. Not until the
        -- station's spread pool covers it (it starts as a few points by the airlocks), and not next to anyone: wait
        -- for a clear spot (an empty list: materialize tries again next update), up to SPAWN_WAIT_MAX.
        local now = os.clock()
        c.spawnWait = c.spawnWait or now
        local patient = now - c.spawnWait < CFG.SPAWN_WAIT_MAX
        st.spots = st.spots or {}
        if #st.spots < CFG.SPAWN_POOL_READY then
            growSpots(st, CFG.SPAWN_POOL_BURST)
            if patient and #st.spots < CFG.SPAWN_POOL_READY then return spots end
        end
        local p, clear = spreadPoint(st, nil, nil, nil, playerLoc)
        if p and patient and clear < CFG.SPAWN_CLEAR then return spots end
        if p then
            if not patient then
                X.log(("[rivals] %s: no clear spot in %s after %d s, spawning %.0f m from the nearest body"):format(
                    crewLabel(c), st.name, CFG.SPAWN_WAIT_MAX, clear / 100))
            end
            table.insert(spots, p)
            c.spawnWait = nil
        end
        for _ = 1, 12 do
            if #spots > 0 then break end
            p = stationPoint(st)
            if p and (not playerLoc or dist(p, playerLoc) >= CFG.SPAWN_AWAY) then table.insert(spots, p) break end
        end
    end
    return spots
end

-- Where to come aboard: the breach points, or the dock starts on a ship that has none (the Strike interior).
local function entryPoints(inside)
    local points = {}
    local il = inside:K2_GetActorLocation()
    inside.BreachTransforms:ForEach(function(_, t)
        local tl = t:get().Translation
        table.insert(points, { X = il.X + tl.X, Y = il.Y + tl.Y, Z = il.Z + tl.Z })
    end)
    if #points == 0 then
        for _, name in ipairs({ "ShipDockOnePlayerStart", "ShipDockTwoPlayerStart", "ShipDockThreePlayerStart" }) do
            table.insert(points, inside[name]:K2_GetComponentLocation())
        end
    end
    return points
end

-- Whether a walkable spot joins up with one known to be inside: the runtime navmesh also lays floor outside the
-- interior's walls (in the hull's skin, on top of it), and a breach point is right against the hull, so the nearest
-- floor to one can be out there. Boarders spawned on it stood outside the walls. No path, or one that stops short: no.
local function joined(from, to)
    local path = lib("/Script/NavigationSystem.Default__NavigationSystemV1"):FindPathToLocationSynchronously(S.pc, from, to,
        nil, nil)
    if not valid(path) then return false end
    local last
    path.PathPoints:ForEach(function(_, e) last = e:get() end)
    return last ~= nil and dist(last, to) < CFG.BREACH_JOINED
end

-- A walkable point known to be inside: `from` (you, aboard), else the interior's dock starts.
local function insideAnchor(home, from)
    local ext = { X = 200, Y = 200, Z = 300 }
    if from then
        local p = projected(from, ext)
        if p then return p end
    end
    for _, name in ipairs({ "ShipDockOnePlayerStart", "ShipDockTwoPlayerStart", "ShipDockThreePlayerStart" }) do
        local ok, at = pcall(function() return home[name]:K2_GetComponentLocation() end)
        local p = ok and at and projected(at, ext)
        if p then return p end
    end
end

-- Where the helm is in an interior (its RaidUseableFrigateHelmComponent(s), as minimap.lua finds them), or {}.
local function helmSpots(home)
    local out = {}
    pcall(function()
        local cls = lib("/Script/RaidGame.RaidUseableFrigateHelmComponent")
        if not valid(cls) then return end
        local all = home:K2_GetComponentsByClass(cls)
        for i = 1, #all do
            local c = all[i]:get()
            if valid(c) then
                local l = c:K2_GetComponentLocation()
                out[#out + 1] = { X = l.X, Y = l.Y, Z = l.Z }
            end
        end
    end)
    return out
end

-- A boarder's spot is fit if it's clear of the helm and on the floor at the height of what it was searched around
-- (#473: boarders came in on top of the cockpit).
local function fitSpot(p, around, helms)
    if math.abs(p.Z - around.Z) > CFG.BREACH_FLOOR_Z then return false end
    for _, h in ipairs(helms) do if dist(p, h) < CFG.BREACH_HELM_CLEAR then return false end end
    return true
end

-- Floor by the breach points that joins up with the inside (`from`: a point known to be inside, e.g. you). With no
-- breach point joined up, floor around the inside point itself, so nobody comes in through the outside of the walls.
-- Spots by the helm or off the breach point's floor are skipped (#473); kept only when nothing else qualifies.
local function breachSpots(inside, from)
    local spots, unfit = {}, {}
    local home = inside or S.homeInside
    if not valid(home) then return spots end
    local anchor = insideAnchor(home, from)
    local helms = helmSpots(home)
    for _, at in ipairs(entryPoints(home)) do
        local p
        for _ = 1, 4 do
            p = reachableNear(at, 600)
            if not p or fitSpot(p, at, helms) then break end
            if not anchor or joined(anchor, p) then unfit[#unfit + 1] = p end
            p = nil
        end
        if p and (not anchor or joined(anchor, p)) then table.insert(spots, p) end
    end
    if #spots == 0 and anchor then
        for _ = 1, 8 do
            local p = reachableNear(anchor, CFG.BREACH_FALLBACK)
            if p and fitSpot(p, anchor, helms) then table.insert(spots, p)
            elseif p then unfit[#unfit + 1] = p end
            if #spots >= 4 then break end
        end
        if #spots > 0 then X.log("[rivals] no breach point joins up with the inside: boarders come in nearer the middle") end
    end
    if #spots == 0 and #unfit > 0 then
        X.log(("[rivals] no boarder spot clear of the helm (%d helm(s)) on the floor: using %d unfit"):format(#helms, #unfit))
        return unfit
    end
    return spots
end

-- Station defenders ----------------------------------------------------------------------------------------------
-- Live placed NPCs (CFG.PLACED classes) from the spawn hook; dead and destroyed entries are dropped as it goes.
-- (Defined before garrisonStation, which uses it too: defined after, it was a nil global there and the garrison of
-- the first station you boarded failed, 2026-11-14.)
local function hookedPlaced()
    local placed, list, out = {}, NodeBots.list, {}
    for _, c in ipairs(CFG.PLACED) do placed[c] = true end
    for i = #list, 1, -1 do
        local n = list[i]
        if not valid(n.o) or n.placed == false then
            list[i] = list[#list]
            list[#list] = nil
        else
            if n.placed == nil then
                local ok, name = pcall(function() return n.o:GetClass():GetFName():ToString() end)
                n.placed = ok and placed[name] == true and not n.o:GetFName():ToString():find("^Default__")
            end
            if n.placed and not (R.civilianAt and R.civilianAt[n.o:GetAddress()]) then out[#out + 1] = n.o end
        end
    end
    return out
end

local function placedDefenders(st)
    local managed = {}
    for _, e in ipairs(X.raid().bots) do
        if e.bot and valid(e.bot) then managed[e.bot:GetAddress()] = true end
    end
    for addr in pairs(R.civilianAt or {}) do managed[addr] = true end -- (civilians.lua's people: not defenders)
    -- From the spawn hook when it's on (the two FindAllOf scans cost ~105 ms in the frame you step into a station and
    -- found the same NPCs: "spawn hook knows 6 ... FindAllOf found 6", 2026-11-15); the scans are the fallback.
    local found
    if NodeBots.hooked then
        found = hookedPlaced()
    else
        found = {}
        for _, cls in ipairs(CFG.PLACED) do
            for _, b in ipairs(FindAllOf(cls) or {}) do found[#found + 1] = b end
        end
    end
    local list = {}
    for _, b in ipairs(found) do
        if valid(b) and not managed[b:GetAddress()] and hpOf(b) > 0
            and inBox(st.box, b:K2_GetActorLocation(), 500) and not X.offLimits(b:K2_GetActorLocation()) then
            table.insert(list, b)
        end
    end
    return list
end

-- Wake one placed NPC under the director's soldier AI: a RaidAIController instead of its GOAP one, its own gun
-- held in the body mesh's hand, the station's faction and team.
local function adopt(b)
    if not valid(b) or hpOf(b) <= 0 then return nil end
    local soldier = lib(CFG.SOLDIER .. ".Default__BotPawnMilitary_C")
    if not valid(soldier) then pcall(LoadAsset, CFG.SOLDIER) soldier = lib(CFG.SOLDIER .. ".Default__BotPawnMilitary_C") end
    if not valid(soldier) then return nil end
    local old = b.Controller
    if valid(old) then old:UnPossess() end
    b.AIControllerClass = soldier.AIControllerClass
    b:SpawnDefaultController()
    local ctrl = b.Controller
    if not valid(ctrl) then return nil end
    ctrl = X.arm(b, ctrl)
    if not ctrl then return nil end
    R.wear(b, R.WEAR.guard) -- (the level's own guards too: their rolls ran as low as 1/1, #86)
    local boss = b:GetClass():GetFName():ToString():find("Boss", 1, true) ~= nil
    local row = ""
    -- the placed NPC's GOAP controller (a weak pointer) names its brain row, e.g. EliteRaider / AverageRaiderSemi
    pcall(function()
        local gc = b.CachedPlayerController:Get()
        if gc and gc:IsValid() then row = gc.AIActionsRowname:ToString() end
    end)
    local profile = boss and "boss" or (row:find("Elite", 1, true) and "guard" or "soldier")
    local gun = b.CurrentWeapon
    local held = valid(gun) and gunName(gun) or nil
    local e = { bot = b, ctrl = ctrl, home = b:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(2, 8),
        patrolRadius = CFG.POST_RADIUS, placed = true, hand = comps(b).CharacterBody0,
        mind = AI.mind(profile, AI.pickPersonality(AI.power({ gun = held }) + (boss and 2 or 0))) }
    -- what the level gave it (kit rows, and how it looks before female.lua dresses it): top-ups copy this
    local okw, rows = pcall(wornRows, b)
    e.rows = okw and rows or {}
    e.look = { head = b.Mesh.SkeletalMesh, gear = {} }
    local parts = comps(b)
    for _, key in ipairs(CFG.GEAR_SLOTS) do if parts[key] then e.look.gear[key] = parts[key].SkeletalMesh end end
    local female = math.random() < CFG.FEMALE
    e.voice = X.voice.pick(female)
    if female then pcall(X.female.dress, b, true) end
    AI.tuneBody(e)
    pcall(holdGun, e)
    local ok, carried = pcall(rollCarried, b)
    e.carried = ok and carried or { "roll failed: " .. tostring(carried) }
    table.insert(X.raid().bots, e)
    return e, profile, row
end

-- First visit to a station: queue its own NPCs for adoption (one per update), then top it up to MIN_DEFENDERS.
local function garrisonStation(pc, st)
    local list = placedDefenders(st)
    X.log(("[rivals] %s: %d placed NPC(s) to adopt (%s)"):format(st.name, #list,
        NodeBots.hooked and "from the spawn hook" or "from object scans"))
    S.adoptQueue = S.adoptQueue or {}
    for _, b in ipairs(list) do table.insert(S.adoptQueue, { bot = b, st = st }) end
    -- MIN_DEFENDERS is for a mid-size station: a small one gets as few as half, a big one up to DEFENDERS_MAX_SCALE x.
    local scale = math.max(0.5, math.min(CFG.DEFENDERS_MAX_SCALE, (st.area or CFG.STATION_AREA_MID) / CFG.STATION_AREA_MID))
    local extra = math.max(0, math.floor(CFG.MIN_DEFENDERS * scale + 0.5) - #list)
    if CFG.AWAKE_MAX > 0 then
        local room = math.max(0, CFG.AWAKE_MAX - R.awakeCount() - #list)
        if room < extra then
            X.log(("[rivals] %s: %d more guards wanted, room for %d (AWAKE_MAX)"):format(st.name, extra, room))
            extra = room
        end
    end
    if #list > 0 then
        X.log(("[rivals] %s: %d of its own defenders%s"):format(st.name, #list,
            extra > 0 and (", plus %d more like them"):format(extra) or ""))
        if extra > 0 then
            S.topUps = S.topUps or {}
            table.insert(S.topUps, { st = st, left = extra, templates = {}, guns = {} })
        end
    else
        X.log(("[rivals] %s: none of its own defenders, %d soldiers"):format(st.name, extra))
        if extra > 0 and X.garrison then X.garrison(pc, st.box, st.name, extra) end
    end
    if R.onStation then -- civilians.lua (#81): miners, prisoners and workers where they belong
        local ok, err = pcall(R.onStation, pc, st)
        if not ok then X.log("[civilians] " .. tostring(err)) end
    end
end

-- Top-ups: a raider body like one of the station's own, with a kit of its own. Two steps, like rival bodies: spawn the body
-- and roll the kit, then on a later update, once the gun has arrived, arm it.
local function defenderSpot(st)
    local you = valid(S.foot) and S.foot:K2_GetActorLocation() or nil
    -- the pool starts as a few points by the airlocks: grow it first, so top-ups spread over the whole station
    if #(st.spots or {}) < CFG.SPAWN_POOL_READY then growSpots(st, CFG.SPAWN_POOL_BURST) end
    local spread = spreadPoint(st, nil, nil, nil, you)
    if spread then return spread end
    local found, near = 0, 0
    for _ = 1, 8 do
        local p = stationPoint(st)
        if p then
            found = found + 1
            if not S.foot or not valid(S.foot) or dist(p, S.foot:K2_GetActorLocation()) >= CFG.SPAWN_AWAY then return p end
            near = near + 1
        end
    end
    X.log(("[rivals] %s: no defender spot (%d points found, %d too close to you; %d entries, %d posts; %d off limits so far)")
        :format(st.name, found, near, #(st.entries or {}), #(st.posts or {}), S.offRejects or 0))
end

-- A top-up's kit: the template guard's own helmet, chest armour, bag and sidearm rows (so it looks like them), and a gun
-- one of the station's own guards carries (the station's gear pool, not your level). A template whose rows couldn't be
-- read falls back to a rolled kit.
local function topUpKit(job, tpl)
    local r = tpl.rows or {}
    if not (r.gun or r.pistol or r.helmet or r.chest or r.bag) then
        local tier = CFG.TIERS[2]
        return rollKit(tier, math.random() < tier.helmet, math.random() < tier.chest, math.random() < tier.backpack)
    end
    local gun = #job.guns > 0 and job.guns[math.random(#job.guns)] or r.gun
    return { gun = gun and (priceOf(gun) or { gun, 0 }) or nil, pistol = r.pistol, helmet = r.helmet, chest = r.chest,
        bag = r.bag, stacks = math.random(CFG.AMMO_STACKS[1], CFG.AMMO_STACKS[2]), meds = math.random(CFG.MEDS[1], CFG.MEDS[2]) }
end

local function startTopUp(pc, job)
    local tpl = job.templates[math.random(#job.templates)]
    local at = defenderSpot(job.st)
    if not at then return "no free spot in the station" end
    local body = spawnBody(pc, at)
    if not body then return "spawn refused" end
    -- the template's head (the raider's Mesh) and outfit; its gear slots come from the kit, and once that has arrived
    -- finishTopUp puts the template's own meshes on them (a placed guard can wear a mesh its rows don't name).
    local female = math.random() < CFG.FEMALE
    if valid(tpl.head) then pcall(function() body.Mesh:SetSkeletalMesh(tpl.head, false) end) end
    local outfit, suit = comps(body).CharacterBody0, tpl.gear.CharacterBody0
    if outfit and valid(suit) then pcall(function() outfit:SetSkeletalMesh(suit, false) end) end
    body.Health = tpl.maxHp or body.Health
    S.pendingDefenders = S.pendingDefenders or {}
    table.insert(S.pendingDefenders, { body = body, st = job.st, profile = tpl.profile, startedAt = os.clock(), female = female,
        look = tpl.gear })
    equipKit(body, topUpKit(job, tpl))
end

local function finishTopUp(p)
    local body = p.body
    if not valid(body) then return true end
    if not valid(body.CurrentWeapon) and os.clock() - p.startedAt < CFG.GUN_WAIT then return false end
    local name = valid(body.CurrentWeapon) and gunName(body.CurrentWeapon) or "no gun"
    local parts = comps(body)
    for key, mesh in pairs(p.look or {}) do
        if key ~= "CharacterBody0" and parts[key] and valid(mesh) then
            pcall(function() parts[key]:SetSkeletalMesh(mesh, false) end)
        end
    end
    if p.female then X.female.dress(body, true) end
    local ctrl = X.arm(body)
    if not ctrl then R.destroy(body) return true end
    R.wear(body, R.WEAR.guard)
    local e = { bot = body, ctrl = ctrl, home = body:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(2, 8),
        patrolRadius = CFG.POST_RADIUS, placed = true, hand = comps(body).CharacterBody0, voice = X.voice.pick(p.female),
        mind = AI.mind(p.profile or "soldier", AI.pickPersonality(AI.power({ gun = name }))) }
    AI.tuneBody(e)
    pcall(holdGun, e)
    local ok, carried = pcall(rollCarried, body)
    table.insert(X.raid().bots, e)
    S.adopted = S.adopted or {}
    table.insert(S.adopted, e)
    X.log(("[rivals] %s defender up: copy with %s, carrying %s"):format(p.st.name, name,
        ok and table.concat(carried, ", ") or ("roll failed: " .. tostring(carried))))
    return true
end

-- One step per update: finish a pending top-up, else start the next one once the station's own are all adopted.
local function topUpStep(pc)
    local pend = S.pendingDefenders
    if pend and #pend > 0 then
        local ok, done = pcall(finishTopUp, pend[1])
        if not ok then X.log("[rivals] defender top-up failed: " .. tostring(done)) end
        if not ok or done then table.remove(pend, 1) end
        return
    end
    if S.adoptQueue and #S.adoptQueue > 0 then return end
    local jobs = S.topUps
    if not jobs or #jobs == 0 then return end
    local job = jobs[1]
    if #job.templates == 0 then
        X.log("[rivals] " .. job.st.name .. ": no defenders of its own came up; soldiers instead")
        if X.garrison then pcall(X.garrison, pc, job.st.box, job.st.name, job.left) end
        table.remove(jobs, 1)
        return
    end
    local ok, err = pcall(startTopUp, pc, job)
    if not ok or err then X.log("[rivals] defender top-up failed: " .. tostring(err)) end
    job.left = job.left - 1
    if job.left <= 0 then table.remove(jobs, 1) end
end

local function adoptQueued()
    local q = S.adoptQueue
    if not q or #q == 0 then return end
    local job = table.remove(q, 1)
    local ok, e, profile, row = pcall(adopt, job.bot)
    if ok and e then
        S.adopted = S.adopted or {}
        table.insert(S.adopted, e)
        job.st.posts = job.st.posts or {}
        table.insert(job.st.posts, e.home)
        local b = e.bot
        local look = e.look or { head = b.Mesh.SkeletalMesh, gear = {} }
        local tpl = { head = look.head, gear = look.gear, rows = e.rows, profile = profile, maxHp = b.Health }
        for _, t in ipairs(S.topUps or {}) do
            if t.st == job.st then
                table.insert(t.templates, tpl)
                if e.rows and e.rows.gun then table.insert(t.guns, e.rows.gun) end
            end
        end
        X.log(("[rivals] %s defender up: %s (%s%s, %s), carrying %s"):format(job.st.name, e.bot:GetClass():GetFName():ToString()
            :gsub("_C$", ""), profile, row ~= "" and ("/" .. row) or "", AI.describe(e), table.concat(e.carried or {}, ", ")))
    elseif not ok then
        X.log("[rivals] adopting a defender failed: " .. tostring(e))
    end
end

-- Strays: the garrison sweep runs once, on your first step into a station, and only takes NPCs inside its box. A placed
-- NPC outside the box (Spaceport's box misses most of it) or one that streams in later keeps its GOAP controller, which
-- does nothing offline: it stands there, gun up, until shot. Every STRAY_EVERY s, any living, unmanaged placed NPC in the
-- box or near you is queued for adoption, once it has gone unmanaged for two sweeps in a row (a body the director is
-- still building is unmanaged for a few seconds too; GUN_WAIT is well under a sweep).
-- Each sweep scans one of the PLACED classes in turn: a FindAllOf walks every object in the game, ~50 ms each on a
-- space map, and both at once were a 100+ ms hitch every 8 s (profile.txt, Moon Base, 2026-11-14).
local function sweepStrays(st, now)
    if now < (S.nextStraySweep or 0) or (S.adoptQueue and #S.adoptQueue > 0) then return end
    S.nextStraySweep = now + CFG.STRAY_EVERY
    local managed = {}
    for _, e in ipairs(X.raid().bots) do
        if e.bot and valid(e.bot) then managed[e.bot:GetAddress()] = true end
    end
    for addr in pairs(R.civilianAt or {}) do managed[addr] = true end -- (civilians.lua's people: not defenders)
    for _, job in ipairs(S.building or {}) do
        if job.b and valid(job.b.body) then managed[job.b.body:GetAddress()] = true end
    end
    for _, p in ipairs(S.pendingDefenders or {}) do
        if valid(p.body) then managed[p.body:GetAddress()] = true end
    end
    local foot = valid(S.foot) and S.foot:K2_GetActorLocation() or nil
    local seen, found = {}, 0
    -- Without the spawn hook: one of the PLACED classes per sweep, by FindAllOf (both at once was a 100+ ms hitch).
    local cls, bots = "hooked", nil
    if NodeBots.hooked then
        bots = hookedPlaced()
    else
        S.strayClass = (S.strayClass or 0) % #CFG.PLACED + 1
        cls = CFG.PLACED[S.strayClass]
        bots = FindAllOf(cls) or {}
    end
    S.strays = S.strays or {}
    local before = S.strays[cls] or {}
    do
        for _, b in ipairs(bots) do
            if valid(b) and hpOf(b) > 0 and not managed[b:GetAddress()] then
                local at = b:K2_GetActorLocation()
                if (inBox(st.box, at, 500) or (foot and dist(at, foot) <= CFG.STRAY_RANGE)) and not X.offLimits(at) then
                    local key = b:GetAddress()
                    seen[key] = true
                    if before[key] then
                        table.insert(S.adoptQueue, { bot = b, st = st })
                        found = found + 1
                    end
                end
            end
        end
    end
    S.strays[cls] = seen
    if found > 0 then X.log(("[rivals] %s: %d stray NPC(s) the garrison missed, adopting"):format(st.name, found)) end
end

-- Your ship, flown and undocked, with its movement component not ticking: it takes thrust (CurrentThrust 1) and goes
-- nowhere, though nothing looks disabled. Seen once, after undocking from Penal Colony on Space_Beta (2026-11-14);
-- turning the tick back on from the bridge freed it at once. Two seconds' grace so the game's own undock can finish.
local function keepShipMoving(now)
    local ship = S.playerShip
    if not (valid(ship) and valid(S.pc) and valid(S.pc.Pawn) and S.pc.Pawn:GetAddress() == ship:GetAddress()) then
        S.shipStillSince = nil return
    end
    local cm = ship.CharacterMovement
    if not valid(cm) or ship.bDocked or cm:IsComponentTickEnabled() then S.shipStillSince = nil return end
    S.shipStillSince = S.shipStillSince or now
    if now - S.shipStillSince < 2 then return end
    S.shipStillSince = nil
    cm:SetComponentTickEnabled(true)
    X.log("[rivals] your ship's movement had stopped ticking after undocking: turned it back on")
end

-- Defenders' guns: equipping puts the gun on the head mesh (invisible); keep it in the body's hand (like rivals).
local function keepDefendersArmed()
    for i = #(S.adopted or {}), 1, -1 do
        local e = S.adopted[i]
        if e.dead or not e.bot then table.remove(S.adopted, i) else pcall(holdGun, e) end
    end
end


-- What rivals.lua and the later modules call
M.adoptQueued, M.bodiesAlive, M.breachSpots = adoptQueued, bodiesAlive, breachSpots
M.crewArrival, M.dematerialize, M.entryPoints = crewArrival, dematerialize, entryPoints
M.finishBody, M.garrisonStation, M.gearCatalog = finishBody, garrisonStation, gearCatalog
M.holdGun, M.insideAnchor, M.joined = holdGun, insideAnchor, joined
M.keepDefendersArmed, M.keepShipMoving, M.lockExit = keepDefendersArmed, keepShipMoving, lockExit
M.materialize, M.pickLock, M.projected, M.reachableNear = materialize, pickLock, projected, reachableNear
M.giveShipCard = giveShipCard
M.removeEntry, M.roamGuards, M.rollKit, M.setWatch = removeEntry, roamGuards, rollKit, setWatch
M.spreadPoint, M.startBody, M.stationSpawnSpots = spreadPoint, startBody, stationSpawnSpots
M.routGuards, M.sweepStrays, M.topUpStep = routGuards, sweepStrays, topUpStep
M.routPoint = routPoint

return M
