-- Space maps (moved out of main.lua): your guns hidden while you ride a pod, docking at a station, each sublevel's
-- fog and post-process kept to its own area, your key card, the sun, the navmesh for your ship's interior, the salvage
-- in your hold, and the per-update work for rival crews and your crew (updateSpace: Space.update in main's update).
local PROJECT = require("pveproject")
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local M = {}

local CFG, log, valid, lib, dist, Aux, Rivals, Bots, navReadyAt -- from main.lua (M.init)
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)
local dockingVolume -- the docking hooks (M.init): DockedVolume kept across the client half's clear

function M.setRaid(r) raid = r end

-- Your guns while you ride a pod (see the space branch of the update): hidden and remembered in raid.podGuns.
local POD_GUN_SCANS = { 0, 1, 4, 10 } -- seconds into the flight to look over every gun in the world
local function hidePodGuns(foot, pod)
    local now = os.clock()
    if not raid.podGuns then raid.podGuns, raid.podScans = {}, { at = now, n = 0 } end
    local guns = raid.podGuns
    local function hide(g, why)
        if not valid(g) then return end
        local key = g:GetAddress()
        if not guns[key] then
            if g.bHidden then return end
            guns[key] = g
            log(("pod: hid %s (%s)"):format(g:GetFName():ToString(), why))
        end
        if not g.bHidden then g:SetActorHiddenInGame(true) end
        -- A gun's attachments (stock, magazine, sight...) are actors of their own in its slots: hiding the gun left
        -- them showing on the pod (tester: the Mat49's stock). Hidden with it, and shown again with it on foot.
        if g.StockSlot ~= nil then
            for _, slot in ipairs({ "MuzzleSlot", "SightSlot", "LowerRailSlot", "UpperRailSlot", "MagSlot", "StockSlot", "SpecialSlot" }) do
                local a = g[slot]
                if valid(a) and not guns[a:GetAddress()] and not a.bHidden then
                    guns[a:GetAddress()] = a
                    a:SetActorHiddenInGame(true)
                end
            end
        end
    end
    for _, g in pairs(guns) do if valid(g) and not g.bHidden then g:SetActorHiddenInGame(true) end end
    pcall(function() foot.Inventory:ForEach(function(_, w) hide(w:get(), "carried") end) end)
    pcall(function() hide(foot.CurrentWeapon, "held") end)
    -- the pod gets its own copy of your gun (MyPawn = the pod), drawn huge over it in the pod's camera
    pcall(function() hide(pod.CurrentWeapon, "the pod's") end)
    pcall(function() pod.Inventory:ForEach(function(_, w) hide(w:get(), "the pod's") end) end)
    local scan = POD_GUN_SCANS[raid.podScans.n + 1]
    if not scan or now - raid.podScans.at < scan then return end
    raid.podScans.n = raid.podScans.n + 1
    local me, at = foot:GetAddress(), pod:K2_GetActorLocation()
    for _, g in ipairs(FindAllOf("RaidWeapon") or {}) do
        if valid(g) then
            local owned = false
            local podAt = pod:GetAddress()
            pcall(function() owned = valid(g.MyPawn) and (g.MyPawn:GetAddress() == me or g.MyPawn:GetAddress() == podAt) end)
            if owned then
                hide(g, "yours")
            else
                local l = g:K2_GetActorLocation()
                local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
                if dx * dx + dy * dy + dz * dz < 800 * 800 then hide(g, "on the pod") end
            end
        end
    end
end

-- Space maps keep every raid location (Spaceport_01, Fortress_01...) and AI ship interiors as always-loaded
-- sublevels away from where you fly. Their height fogs and unbound post-process volumes apply to the whole world,
-- and UE4 draws only one height fog, whichever registered first: open space came out blue and murky (an AI frigate
-- interior's fog) or with a raid's colour grading. So each sublevel's effects only show near that sublevel (its
-- fog's position), and none in open space. Effects are collected once, when the map is ready (two object scans).
local function levelEffects(world)
    local own = world:GetFullName():match("/Game/[^.]+")
    local levels = {}
    for _, cls in ipairs({ "ExponentialHeightFog", "PostProcessVolume" }) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            local pkg = a:GetFullName():match("/Game/[^.]+")
            -- (valid: skips a previous world's actors still waiting to be destroyed)
            if valid(a) and pkg and pkg ~= own and (cls == "ExponentialHeightFog" or a.bUnbound) then
                local l = levels[pkg] or { name = pkg:match("[^/]+$"), fogs = {}, volumes = {} }
                levels[pkg] = l
                if cls == "ExponentialHeightFog" then
                    l.fogs[#l.fogs + 1] = a
                    l.at = a:K2_GetActorLocation()
                else
                    l.volumes[#l.volumes + 1] = a
                    l.at = l.at or a:K2_GetActorLocation()
                end
            end
        end
    end
    local list = {}
    for _, l in pairs(levels) do list[#list + 1] = l end
    return list
end

local function showLevelEffects(level, on)
    for _, f in ipairs(level.fogs) do f.Component:SetVisibility(on, false) end
    for _, v in ipairs(level.volumes) do v.bEnabled = on end
end

local function updateLevelEffects(pc, world)
    if not raid.effects then
        raid.effects = levelEffects(world)
        for _, l in ipairs(raid.effects) do showLevelEffects(l, false) end
        raid.effectsOn = false
    end
    local cam = pc.PlayerCameraManager:GetCameraLocation()
    local near, best = false, CFG.LEVEL_EFFECT_RADIUS
    for _, l in ipairs(raid.effects) do
        local d = dist(cam, l.at)
        if d < best then near, best = l, d end
    end
    if near ~= raid.effectsOn then
        if raid.effectsOn then showLevelEffects(raid.effectsOn, false) end
        if near then showLevelEffects(near, true) end
        raid.effectsOn = near
        log("level effects: " .. (near and near.name or "open space (none)"))
    end
end



-- Your ship's key card. The game puts it in the KeyCard slot at the start of a raid (row KEYCARD, Attachments
-- "<captain>!<ship name>!<KeyCardUUID of the ship interior>!<ship type>"), and a station airlock only lets you back
-- into a docked ship while you carry it. One went missing during a Rebel Base raid (2026-11-07, cause not found), and
-- that leaves you shut out of your own ship. So: remember it, and if it's gone while the KeyCard slot is empty, put the
-- same card back (Server_AddItem with its id and info; verified to open the station side of the airlock again).
-- A card of another crew in the slot is left alone: that's yours to use on their ship.
-- check every 2 s; ask the game for a missing card 6 s after boarding, at most 3 times
local CARD = { CHECK = 2, GRACE = 6, ASKS = 3 }

local function playerInventory()
    for _, inv in ipairs(FindAllOf("SIGISInventoryComponent") or {}) do
        local o = valid(inv) and inv:GetOwner()
        if o and valid(o) and o:GetClass():GetFName():ToString() == "MainPlayerController_C" then return inv end
    end
end

local function guardKeyCard(pc)
    -- found once per raid: FindAllOf walks every object in the game, a hitch every time it ran
    if not (raid.cardInv and valid(raid.cardInv)) then raid.cardInv = playerInventory() end
    local inv = raid.cardInv
    if not inv then return end
    local mine, slotted = false, nil
    inv.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if valid(it) and it.ItemData:ToString() == "KEYCARD" then
            local guid = it.UniqueItemGUID:ToString()
            if not raid.card and it.MotherItemGUID:ToString() == "KeyCard" then
                raid.card = { guid = guid, att = it.Attachments:ToString(), cond = it.Condition }
                log("key card: " .. raid.card.att:gsub("^[^!]*!", ""))
            end
            if raid.card and guid == raid.card.guid then mine = true end
            if it.MotherItemGUID:ToString() == "KeyCard" then slotted = guid end
        end
    end)
    local k = raid.card
    -- No card at all yet (issue #33; seen with an empty loadout): ask the game for one, as its own raid start does.
    -- Server_ReadyforKeyCard makes the card for your ship (verified: KEYCARD in the KeyCard slot a second later).
    if not k and not slotted and raid.readyAt and os.clock() - raid.readyAt >= CARD.GRACE
        and (raid.cardAsked or 0) < CARD.ASKS then
        raid.cardAsked = (raid.cardAsked or 0) + 1
        inv:Server_ReadyforKeyCard()
        log(("key card: none %ds after boarding; asked the game for one (%d)"):format(CARD.GRACE, raid.cardAsked))
        return
    end
    if not k or mine then return end
    if slotted then
        if raid.cardNote ~= slotted then raid.cardNote = slotted log("key card: yours is gone, another crew's is in the slot") end
        return
    end
    inv:Server_AddItem(FName("KEYCARD"), 1, k.cond, "KeyCard", { X = 0, Y = 0 }, false, k.guid, 0, k.att, 0)
    log("key card: it was gone from your inventory; put it back")
end

-- A ship you took from a rival crew (rivalcombat checkStolen, #311): nobody on board carries its card, and without one
-- a station airlock won't let you back in once you've stepped out. Your old card (for the ship you left) is taken out
-- of the KeyCard slot and this ship's goes in, made the way the game makes yours (same Attachments form, the interior's
-- KeyCardUUID), and guardKeyCard guards it from then on.
local function cardForShip(inside, shipName, row)
    if not valid(inside) then return log("key card: the taken ship has no interior") end
    if not (raid.cardInv and valid(raid.cardInv)) then raid.cardInv = playerInventory() end
    local inv = raid.cardInv
    if not inv then return log("key card: no inventory for the taken ship's card") end
    local uuid = inside.KeyCardUUID
    local captain = "Captain"
    pcall(function()
        local n = FindFirstOf("MainPlayerController_C").PlayerState.PlayerNamePrivate:ToString()
        if n ~= "" then captain = n end
    end)
    local att = ("%s!%s!%s!%s"):format(captain, shipName or "Ship", tostring(uuid), row or "")
    local old = {}
    inv.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if valid(it) and it.ItemData:ToString() == "KEYCARD" and it.MotherItemGUID:ToString() == "KeyCard" then
            old[#old + 1] = it.UniqueItemGUID:ToString()
        end
    end)
    for _, g in ipairs(old) do inv:Server_RemoveItem(g) end
    local guid = ("pve-card-%d-%d"):format(os.time(), math.random(1000, 9999))
    inv:Server_AddItem(FName("KEYCARD"), 1, 100, "KeyCard", { X = 0, Y = 0 }, false, guid, 0, att, 0)
    raid.card, raid.cardNote = { guid = guid, att = att, cond = 100 }, nil
    log(("key card: the taken ship's (%s), replacing %d old"):format(att:gsub("^[^!]*!", ""), #old))
end

-- The map's one sun (intensity 10, moving, shadows out to 650000 units) is meant for the hulls and stations seen from
-- space. It has no way to stay out of the interiors: its shadow map spreads over the whole map, far too coarse for a
-- wall to block it, so it lit rooms almost flat, and every station in the map went into that shadow map each frame.
-- Nothing on foot needs it, so it's only on while you fly.
local function updateSun(onFoot)
    if raid.sun == nil then
        raid.sun = false
        for _, c in ipairs(FindAllOf("DirectionalLightComponent") or {}) do
            if valid(c) and c.Intensity > 0 and not c:GetFullName():find("/Engine/Transient", 1, true) then raid.sun = c end
        end
    end
    if raid.sun and valid(raid.sun) and raid.sunOn ~= not onFoot then
        raid.sunOn = not onFoot
        raid.sun:SetVisibility(not onFoot, false)
    end
end

-- Rival crews (rivals.lua) -------------------------------------------------------------------------------
-- Space maps ship a baked navmesh for the stations and AI frigate interiors, but none for your ship's interior
-- (it's spawned at runtime), and boarders have to walk it. Switching the baked navmesh to runtime generation
-- discards its tiles and rebuilds nothing; a freshly spawned dynamic RecastNavMesh (as on raid maps) rebuilds
-- every volume in ~3 s, plus one we add around your interior (a runtime volume has no brush, so it borrows a
-- station volume's box brush, scaled to the interior).
local PROVOKE_FILE = PROJECT .. "bridge/rivals_provoke"
local CLASH_FILE = PROJECT .. "bridge/rivals_clash"
local BOARD_FILE = PROJECT .. "bridge/rivals_board"
local PREP_FILE = PROJECT .. "bridge/rivals_prep"
local FIRED_FILE = PROJECT .. "bridge/rivals_fired"
local SKIRMISH_FILE = PROJECT .. "bridge/rivals_skirmish"

-- A nav bounds volume around a ship interior, borrowing an existing volume's brush.
local function interiorNavVolume(world, src, inside)
    if not valid(src) then return nil end
    local o, e = {}, {}
    Out.call(src, "GetActorBounds", false, o, e, false)
    local s = src:GetActorScale3D()
    local base = { X = e.X / s.X, Y = e.Y / s.Y, Z = e.Z / s.Z }
    local box = inside.InSideComp
    local c, ext = box:K2_GetComponentLocation(), box:GetScaledBoxExtent()
    local vol = world:SpawnActor(lib("/Script/NavigationSystem.NavMeshBoundsVolume"), c,
        { Pitch = 0, Yaw = 0, Roll = 0 })
    vol.Brush = src.Brush
    vol.BrushComponent.Brush = src.BrushComponent.Brush
    vol.BrushComponent.BrushBodySetup = src.BrushComponent.BrushBodySetup
    local sc = { X = (ext.X + 200) / base.X, Y = (ext.Y + 200) / base.Y, Z = (ext.Z + 200) / base.Z }
    vol:SetActorScale3D({ X = sc.X * 1.01, Y = sc.Y * 1.01, Z = sc.Z * 1.01 })
    vol:SetActorScale3D(sc)
    return vol
end

-- Rivals' interiors, spawned when you board one: the runtime navmesh grows to cover them.
-- (the brush donor and the navigation system are looked up once a raid: the two object scans cost ~90 ms per interior)
local function addInteriorNav(pc, inside)
    if not valid(raid.navSrc) then raid.navSrc = (FindAllOf("NavMeshBoundsVolume") or {})[1] end
    if not valid(raid.navSys) then raid.navSys = FindFirstOf("NavigationSystemV1") end
    local vol = interiorNavVolume(pc:GetWorld(), raid.navSrc, inside)
    if valid(vol) then raid.navSys:OnNavigationBoundsUpdated(vol) end
end

local function homeInterior(foot)
    local l, best, bd = foot:K2_GetActorLocation(), nil, nil
    for _, ins in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if valid(ins) and not ins.IsAnAIShip and valid(ins.SpaceshipToPairTo) then
            local d = dist(l, ins.InSideComp:K2_GetComponentLocation())
            if not bd or d < bd then best, bd = ins, d end
        end
    end
    return best
end

local function startSpaceNav(pc, home)
    local world = pc:GetWorld()
    for _, n in ipairs(FindAllOf("RecastNavMesh") or {}) do if valid(n) then n.RuntimeGeneration = 2 end end
    lib("/Script/NavigationSystem.Default__RecastNavMesh").RuntimeGeneration = 2 -- Dynamic
    local ns = FindFirstOf("NavigationSystemV1")
    ns.bGenerateNavigationOnlyAroundNavigationInvokers = false
    raid.navMesh = world:SpawnActor(lib("/Script/NavigationSystem.RecastNavMesh"), { X = 0, Y = 0, Z = 0 },
        { Pitch = 0, Yaw = 0, Roll = 0 })
    local vols = FindAllOf("NavMeshBoundsVolume") or {}
    if valid(home) then table.insert(vols, interiorNavVolume(world, vols[1], home)) end
    for _, v in ipairs(vols) do if valid(v) then ns:OnNavigationBoundsUpdated(v) end end
    raid.navStarted = true
    log(("space navmesh: rebuilding %d volumes (your ship's interior included: %s)"):format(#vols, tostring(valid(home))))
end

-- Salvage in your hold (issue #134). Taking a wreck aboard (R) spawns its inside salvage at the hold's SalvageSpawn and
-- sets the interior's SalvageFull, but the door, the lever panel ("LOCKED / NO SALVAGE DETECTED") and the purge prompt's
-- state are the Blueprint's OnSpaceSalvageChange, which only OnRep_HasSpaceSavage calls. A replication callback never
-- runs on the authority, and offline you are it: the salvage sat behind the shut door. So each change is relayed here.
local function relaySalvage(home)
    local full = home.SalvageFull == true
    if raid.salvageFull == nil then
        raid.salvageFull = full
        if not full then return end
    elseif raid.salvageFull == full then
        return
    end
    raid.salvageFull = full
    local ok, err = pcall(function() home:OnRep_HasSpaceSavage() end)
    log(("salvage: hold %s%s"):format(full and "full: door opened" or "empty",
        ok and "" or (" (couldn't update it: " .. tostring(err) .. ")")))
end

-- Purging salvage while docked (the original game doesn't allow it, and offline nothing stops it: the hold's space door would open
-- into the station). F on the purge lever or its salvage prompt is SIGISCharacter::ServerInteractComp with the hold's component
-- "SalvageControlLever" or "SalvageComp"; while the hold is docked that press is cancelled (the component argument is cleared) and the
-- player gets what a full inventory gives: the HUD's "NOT ENOUGH SPACE" warning, its animation and its error sound, with our text in it.
-- The prompt stays showing, as in the original; only the press is refused. Registered once (M.init).
local DOCKED_REFUSAL = "CAN'T PERFORM ACTION WHILE DOCKED"
local PURGE_COMPS = { SalvageComp = true, SalvageControlLever = true }
local function guardPurgeWhileDocked()
    local shownAt, shownToken, original = 0, 0, nil
    local function refuse()
        local now = os.clock()
        if now - shownAt < 1 then return end
        shownAt = now
        local hud
        for _, w in ipairs(FindAllOf("HUD_Main_Widget_C") or {}) do
            if valid(w) and w:GetFullName():find("In Game Overlay Match", 1, true) then hud = w break end
        end
        if not hud then return end
        local txt = hud.Txt_NotEnoughSpace
        if not valid(txt) then return end
        if not original then original = txt:GetText():ToString() end
        txt:SetText(FText(DOCKED_REFUSAL))
        hud:NoSpaceForItem()
        shownToken = shownToken + 1
        local mine = shownToken
        ExecuteWithDelay(4500, function()
            if mine == shownToken and valid(txt) then pcall(function() txt:SetText(FText(original)) end) end
        end)
    end
    local registered = pcall(RegisterHook, "/Script/SIGISPlugin.SIGISCharacter:ServerInteractComp", function(_, comp)
        local home = raid and raid.home
        if not valid(home) or home.is_Currently_Docked ~= true then return end
        local ok, err = pcall(function()
            local c = comp:get()
            if not valid(c) or not PURGE_COMPS[c:GetFName():ToString()] then return end
            local owner = c:GetOwner()
            if not valid(owner) or owner:GetAddress() ~= home:GetAddress() then return end
            comp:set(nil)
            log("salvage: purge refused while docked")
            refuse()
        end)
        if not ok then log("salvage: purge guard failed: " .. tostring(err)) end
    end)
    if not registered then log("salvage: couldn't hook ServerInteractComp, purging while docked is not blocked") end
end

local function updateSpace(pc, worldName)
    local foot = raid.target
    if not raid.home then
        raid.home = homeInterior(foot)
        if not valid(raid.home) then return end
    end
    if valid(raid.home) then relaySalvage(raid.home) end
    if not raid.navStarted then startSpaceNav(pc, raid.home) return end
    if not raid.navReady then
        raid.navReady = navReadyAt(pc, raid.home.InSideComp:K2_GetComponentLocation())
            or navReadyAt(pc, foot:K2_GetActorLocation())
        if raid.navReady then log("space navmesh ready") end
        if not raid.navReady and os.clock() - raid.readyAt < 20 then return end
        raid.navReady = true
    end
    raid.spawned = true -- aim tracking runs for rivals' bodies
    local P, t0 = _G.PVE_PROF, os.clock()
    Rivals.update(pc, raid.world, worldName, foot, raid.home)
    if P then
        local ms = (os.clock() - t0) * 1000
        P.rivalsUpdate = (P.rivalsUpdate or 0) + ms
        if ms > (P.rivalsUpdateMax or 0) then P.rivalsUpdateMax = ms end
    end
    local okc, errc = pcall(Crew.update, pc, raid.world)
    if not okc then log("crew: " .. tostring(errc)) end
    Bots.spawnQueued(pc)
    -- Testing from outside the game: bridge/rivals_provoke does what F4 does.
    if not Aux.due("rivalFlags", 2) then Bots.updateBots(pc) return end
    local f = io.open(PROVOKE_FILE, "r")
    if f then f:close() os.remove(PROVOKE_FILE) Rivals.provoke() end
    f = io.open(BOARD_FILE, "r")
    if f then f:close() os.remove(BOARD_FILE) Rivals.provoke(true) end
    f = io.open(PREP_FILE, "r")
    if f then
        local want = f:read("l")
        f:close()
        os.remove(PREP_FILE)
        Rivals.prepBoard(want and want:match("%S") and want or nil)
    end
    f = io.open(CLASH_FILE, "r")
    if f then -- holding a number: that far apart (default 3000)
        local apart = f:read("l")
        f:close() os.remove(CLASH_FILE) Rivals.clash(tonumber(apart))
    end
    -- bridge/rivals_fired: as if you'd just fired your ship's guns; bridge/rivals_skirmish: an ambient fight now.
    f = io.open(FIRED_FILE, "r")
    if f then f:close() os.remove(FIRED_FILE) Rivals.firedForTest() end
    f = io.open(SKIRMISH_FILE, "r")
    if f then -- holding a number: that many ships on each side
        local size = f:read("l")
        f:close()
        os.remove(SKIRMISH_FILE)
        Rivals.skirmishNow(size and size:match("%d+"))
    end
    Bots.updateBots(pc)
end

function M.init(ctx)
    CFG, log, valid, lib, dist, Aux = ctx.CFG, ctx.log, ctx.valid, ctx.lib, ctx.dist, ctx.aux
    Rivals, Bots, navReadyAt = ctx.rivals, ctx.bots, ctx.navReadyAt
    require("spacefx").init({ log = log, valid = valid, lib = lib }) -- turret and mine blasts the client side would build (#15)
    guardPurgeWhileDocked()
    -- Docking at a station ------------------------------------------------------------------------------
    -- Flying into a station's docking volume, RaidDockingComponent::FrigateDocking (server) sets the controller's
    -- DockedVolume and starts the docking ability (Ability_Frigate_BoardStation). Its client half ends with
    -- ClientFrigateDockingToStation, which clears the client's DockedVolume; its server half calls
    -- FrigateDockingToStation, which docks the ship (SpaceshipInside::Docked) and lets you through the airlock.
    -- Standalone there is one controller and the ability runs only its client half: the clear wiped the server's
    -- DockedVolume and nothing docked (you kept pushing into the airlock). So keep DockedVolume across the clear and
    -- then run the server half.
    -- Airlock refusals, logged so a lockout can be read afterwards (EHangerEvent: 3 ship not in dock, 4 wrong dock,
    -- 5 no key card, 6 busy, 7 no dock connection).
    pcall(RegisterHook, "/Script/RaidGame.RaidPlayerController:HangerEvent", function(ctx, ev)
        local e = ev:get()
        if e >= 3 then log("airlock refused (hangar event " .. tostring(e) .. ")") end
    end)

    RegisterHook("/Script/RaidGame.RaidPlayerController:ClientFrigateDockingToStation", function(ctx)
        dockingVolume = nil
        local v = ctx:get().DockedVolume
        if valid(v) then dockingVolume = v end
    end, function(ctx)
        local pc, v = ctx:get(), dockingVolume
        dockingVolume = nil
        if not v then return end
        local ok, err = pcall(function()
            pc.DockedVolume = v
            pc:FrigateDockingToStation()
        end)
        log(ok and ("docked at " .. v:GetFName():ToString()) or ("docking failed: " .. tostring(err)))
    end)
end

M.hidePodGuns, M.updateLevelEffects, M.guardKeyCard, M.updateSun = hidePodGuns, updateLevelEffects, guardKeyCard, updateSun
M.CARD, M.addInteriorNav, M.update, M.cardForShip = CARD, addInteriorNav, updateSpace, cardForShip

return M
