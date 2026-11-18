-- Your gear in and your loot out (moved out of main.lua): the stash loadout and the SIGIS HUD overlay it needs, a
-- soldier's gun when you have none, floor loot, and extraction back to the main menu.
local M = {}

local CFG, log, valid, lib, TREE -- from main.lua (M.init)
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)

function M.setRaid(r) raid = r end

-- Player loadout --------------------------------------------------------------------------------------
-- Offline the player spawns with no weapons, and the SIGIS inventory path (Server_AddItem + Server_EquipItem /
-- the equipment component's ServerEquipItemToSlot) crashes in game code. A soldier's gun is a plain ARaidWeapon,
-- though: spawn a donor soldier out of sight, move its weapon to the player and equip it, then delete the donor.
local function startGiveGun(pc)
    local pawn = pc.Pawn
    local l = pawn:K2_GetActorLocation()
    local donor = lib("/Script/AIModule.Default__AIBlueprintHelperLibrary"):SpawnAIFromClass(pc,
        lib("/Game/Blueprints/Pawns/BotPawnMilitary.BotPawnMilitary_C"), lib(TREE),
        { X = l.X, Y = l.Y, Z = l.Z + 3000 }, { Pitch = 0, Yaw = 0, Roll = 0 }, true, pc)
    if valid(donor) then raid.donor, raid.donorAt = donor, os.clock() end
end

-- For a player-controlled pawn the weapon's ammo-in-clip getter (RVA 0x18875a0) ignores CurrentAmmoInClip and
-- returns the StackAmount of the SIGIS item whose UniqueItemGUID == gun.UUIDSIGIS (0 when there is none), so
-- HandleFiring sees an empty gun and never shoots. Bots skip that lookup. So the gun gets an item of its own: its
-- stack is the loaded magazine, firing drains it (UseAmmo) and the native reload refills it from ammo items in
-- the inventory whose row AmmoType matches the gun's BulletType.
-- UseAmmo also refreshes the item's inventory widget, which only exists once the SIGIS HUD overlay does (the
-- server creates it in a live raid; offline nothing does): without it the first shot crashes (null getter 0x9f2e80).
local GUN_ROWS = { MG42 = "MG42Rifle", Sten = "StenSMG", Mat49 = "Mat49Rifle", M45 = "M45CarlSMG", DP28 = "DP28Rifle",
    Bren = "BrenMk2Rifle", Krasa = "KrasaRifle", Daewoo = "DaewooK1Rifle", Mac10 = "Mac10Rifle",
    Reising = "M50ReisingRifle", Sterling = "SterlingRifle_Short", M712 = "M712Pistol", P08 = "P08Pistol",
    ["1911"] = "1911Pistol", STG44 = "STG44Rifle", Mas44 = "Mas44Rifle" }
-- EBulletType -> ammo row (row AmmoType bytes read from SIGIS_ExampleItemData)
local AMMO_ROWS = { [0] = "12GaugeAmmo", "300Ammo", "32Ammo", "45Ammo", "9mmAmmo", "10mmAmmo", "762Ammo", "54RAmmo",
    "556Ammo", "40mmAmmo", "FlareAmmo", "FlameFuel", "DartAmmo" }
local AMMO_STACK = 60        -- rounds per pocket stack (the 2x2 pocket takes four)

local function inventory() return FindFirstOf("SIGISInventoryComponent") end

local function itemById(guid)
    if guid == "" then return nil end
    for _, it in ipairs(FindAllOf("SIGISInventoryItem") or {}) do
        if it.UniqueItemGUID:ToString() == guid then return it end
    end
end

-- The gun's SIGIS item, remembered per raid (itemById scans every object; keepGunLoaded asks every update).
local function gunItem(gun)
    local guid = gun.UUIDSIGIS:ToString()
    local it = raid.gunItem
    if not (valid(it) and it.UniqueItemGUID:ToString() == guid) then
        it = itemById(guid)
        raid.gunItem = it
    end
    return it
end

-- Returns whether the overlay exists (the match HUD itself can appear a moment after the pawn).
local function ensureHud(pc)
    local hud = pc.MyHUD
    if not (valid(hud) and hud:GetClass():GetFName():ToString() == "MatchHUD_C") then return false end
    if valid(hud.InGameOverlay) then
        -- With the local backend the game now builds its own overlay ("In Game Overlay Match") a moment after ours.
        -- Two full-screen overlays: ours sat on top and swallowed every click (loot grid, Esc menu). Collapse ours.
        -- MatchHUD_C.HUD_Widget (the main HUD every prompt goes to: "F" interact on doors, contracts and loot, the
        -- ship's salvage prompt, the frigate panel) was taken from ours when it was made, so point it at the game's
        -- one too; otherwise those prompts kept going to the collapsed overlay and never showed.
        local own = raid.ownOverlay
        if valid(own) and own:GetAddress() ~= hud.InGameOverlay:GetAddress() then
            local main = hud.InGameOverlay.HUD_Main_Widget
            if valid(main) then -- else try again next update
                own:SetVisibility(1) -- Collapsed
                hud.HUD_Widget = main
                raid.ownOverlay = nil
                log("the game created its own SIGIS HUD overlay; collapsed ours and moved the main HUD to it")
            end
        end
        return true
    end
    local overlay = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc,
        lib("/SIGISPlugin/Widgets/HUD/SIGIS_HUDOverlay.SIGIS_HUDOverlay_C"), pc)
    if not valid(overlay) then log("couldn't create the SIGIS HUD overlay") return false end
    overlay:AddToViewport(50)
    hud.InGameOverlay = overlay
    raid.ownOverlay = overlay
    log("created the SIGIS HUD overlay")
    return true
end

-- The player's own loadout. In a live raid the server asks the client for its equipped stash items
-- (Client_GetEquippedItems; the client reads them from Nakama) and builds the loadout in
-- SIGISPlayerController::Server_AwsN_EquippedItemsReturned: items into their slots under their stash ids, weapon
-- actors for the guns, each gun's loaded rounds as its item stack. Offline nothing asks, so this feeds that function
-- the equipped items the local Nakama stand-in keeps in backend/loadout.json (only while bridge/offline_backend
-- exists: with the live backend the file would be a stale copy). The SIGIS HUD overlay has to exist first (see
-- above). Returns whether it ran.
local function applyLoadout(pc)
    local flag = io.open(CFG.OFFLINE_BACKEND_FLAG, "r")
    if not flag then return false end
    flag:close()
    local f = io.open(CFG.LOADOUT_FILE, "r")
    if not f then log("no " .. CFG.LOADOUT_FILE .. "; is the Nakama stand-in running?") return false end
    local json = f:read("a")
    f:close()
    pc:Server_AwsN_EquippedItemsReturned(json)
    -- The items are in the raid now, not in the stash: the stand-in removes these ids (lost on death; extraction
    -- saves what comes out as new items). Item strings start with the id: "<id>-<Row>-...".
    local ids = {}
    for id in json:gmatch('"value":"([^"%-]+)%-') do ids[#ids + 1] = id end
    local tmp = CFG.CHECKOUT_FILE .. ".tmp"
    local out = io.open(tmp, "w")
    if out then
        out:write(table.concat(ids, "\n"), "\n")
        out:close()
        os.remove(CFG.CHECKOUT_FILE)
        os.rename(tmp, CFG.CHECKOUT_FILE)
    end
    log(("loadout: %d equipped item(s) from the stand-in stash, checked out of it"):format(#ids))
    -- Your look and voice: the raid server gets them the same way (Server_AwsN_EquippedplayerCosmeticsReturned), and
    -- offline nobody sent them, so raids had the default head, body and English voice whatever the lobby showed. The
    -- call fills the controller's EquippedHead/Body/Voice, the pawn's voice and its replicated R_FaceMesh/R_BodyMesh;
    -- OnRep_SetHead (no replication here) puts those meshes on the character.
    do
        local cf = io.open(CFG.COSMETICS_FILE, "r")
        local cos = cf and cf:read("a")
        if cf then cf:close() end
        if cos and cos:find('"key"', 1, true) then
            local okCos, errCos = pcall(function()
                pc:Server_AwsN_EquippedplayerCosmeticsReturned(cos)
                local pawn = pc.Pawn
                if valid(pawn) then pawn:OnRep_SetHead() end
            end)
            log(okCos and ("cosmetics: " .. cos) or ("cosmetics failed: " .. tostring(errCos)))
        end
    end
    return true
end

-- Floor loot. Each ASIGISLootSingleSpawner places one item from its loot table (or nothing, when the roll says "null")
-- as a pickup actor, which it takes from the level's ASIGISResourceManager pool (Manager.ActorForSingleSpawns). The
-- manager is server-only content, so offline TriggerSpawn found none and did nothing. Spawn one with the game
-- instance's DefaultDropItem class (SIGIS_ExamplePickUP_C, also used for dropped items) and trigger every spawner once.
local function spawnFloorLoot(pc)
    raid.floorLoot = true
    local mgr = FindFirstOf("SIGISResourceManager")
    if not valid(mgr) then
        mgr = pc:GetWorld():SpawnActor(lib("/Script/SIGISPlugin.SIGISResourceManager"), { X = 0, Y = 0, Z = 0 },
            { Pitch = 0, Yaw = 0, Roll = 0 })
    end
    local gi = FindFirstOf("SIGISGameInstance")
    if not (valid(mgr) and valid(gi) and valid(gi.DefaultDropItem)) then return log("floor loot: no resource manager") end
    mgr.ActorForSingleSpawns = gi.DefaultDropItem
    local n, placed = 0, 0
    for _, sp in ipairs(FindAllOf("SIGISLootSingleSpawner") or {}) do
        if valid(sp) then
            n = n + 1
            if not sp.HasCompletedASpawn then sp:TriggerSpawn() end
            if valid(sp.ActiveActorHere) then placed = placed + 1 end
        end
    end
    log(("floor loot: %d of %d spawners placed an item"):format(placed, n))
end

-- Extraction. In a live raid the server calls the inventory's Client_GetOutWithLoot when the player gets out: the
-- client copies everything it carries (not keycards / guild badges) into SIGISGameInstanceNakama.ExtractedLoot,
-- and back in the lobby (after Play on the splash screen) saves those as new stash items. Then the server ends
-- the player's session. Offline this hook does that last part: back to the main menu after EXTRACT_SECONDS.
local function extractNow()
    local inv = FindFirstOf("SIGISInventoryComponent")
    if valid(inv) then inv:Client_GetOutWithLoot() end
end

-- Equips the first weapon the pawn carries (the loadout's guns arrive unequipped). Returns whether it had one.
local function equipCarried(pawn)
    local gun
    pawn.Inventory:ForEach(function(_, w)
        if not gun and valid(w:get()) then gun = w:get() end
    end)
    if not gun then return false end
    pawn:ServerEquipWeapon(gun)
    log("equipped " .. gun:GetClass():GetFName():ToString() .. " from the loadout")
    return true
end

local ids = 0
local function newId(kind)
    ids = ids + 1
    return ("pve-%s-%d-%d"):format(kind, os.time(), ids)
end

-- Registers the gun's own item. A fresh id: the donor soldier owns an item under the gun's old id (its loot copy),
-- which went away with the donor, and the gun then had no item and couldn't fire.
local function loadGun(gun, rounds)
    local guid = newId("gun")
    gun.UUIDSIGIS = guid
    local cls, row = gun:GetClass():GetFName():ToString(), "MG42Rifle"
    for k, r in pairs(GUN_ROWS) do if cls:find(k, 1, true) then row = r end end
    -- "Equipment" isn't a grid container, so the item needs no grid cell.
    inventory():Server_AddItem(FName(row), rounds, 100, "Equipment", { Column = 0, Row = 0 }, false, guid, 0, "", 100)
    local it = gunItem(gun)
    if not it then return log("couldn't register the gun's SIGIS item; it won't fire") end
    it.StackAmount = rounds
    gun.CurrentAmmoInClip = rounds
    raid.gun, raid.gunRounds = gun, rounds
end

local function giveAmmo(gun, rounds)
    local row = AMMO_ROWS[gun.BulletType]
    if not row then return log("no ammo row for bullet type " .. tostring(gun.BulletType)) end
    local slot = 0
    while rounds > 0 and slot < 4 do
        local n = math.min(rounds, require("itemdata").capStack(row, AMMO_STACK)) -- (12 gauge stacks at 20, #102)
        inventory():Server_AddItem(FName(row), n, 100, "PocketLeft", { Column = slot % 2, Row = slot // 2 }, false,
            newId("ammo"), 0, "", 100)
        rounds, slot = rounds - n, slot + 1
    end
    log(("put %d stacks of %s in the left pocket"):format(slot, row))
end

-- If the gun's item ever disappears the gun is dead weight; put it back with the rounds it last had.
local function keepGunLoaded()
    local gun = raid.gun
    if not valid(gun) then return end
    local it = gunItem(gun)
    if it then raid.gunRounds = it.StackAmount return end
    log("the gun's SIGIS item vanished; re-registering it")
    loadGun(gun, raid.gunRounds or 0)
end

-- The donor's weapon appears a moment after it spawns, so this runs from a later update.
local function finishGiveGun(pc)
    local donor, pawn = raid.donor, pc.Pawn
    if os.clock() - raid.donorAt < 1 then return end
    raid.donor = nil
    if not (valid(donor) and valid(pawn)) then return end
    local gun = donor.CurrentWeapon
    if valid(gun) then
        gun:SetOwner(pawn)
        gun.Instigator = pawn
        gun.MyPawn = pawn
        pcall(function() gun:OnRep_MyPawn() end)
        local n = 0
        pawn.Inventory:ForEach(function() n = n + 1 end)
        pawn.Inventory[n + 1] = gun
        pawn:ServerEquipWeapon(gun)
        ensureHud(pc)
        local mag = gun.CurrentAmmoInClip -- a fresh soldier's gun holds a full magazine
        loadGun(gun, mag)
        giveAmmo(gun, mag * CFG.START_MAGS)
        log("gave the player a " .. gun:GetClass():GetFName():ToString())
    end
    -- Empty the donor's weapon list first so deleting it can't take the gun along.
    donor.CurrentWeapon = nil
    donor.Inventory:Empty()
    donor:K2_DestroyActor()
end

local function tellBackend(path, text)
    local f = io.open(path, "w")
    if f then
        f:write(text)
        f:close()
    end
end

function M.init(ctx)
    CFG, log, valid, lib, TREE = ctx.CFG, ctx.log, ctx.valid, ctx.lib, ctx.TREE
    RegisterHook("/Script/SIGISPlugin.SIGISInventoryComponent:Client_GetOutWithLoot", function()
        if not raid.extractedAt then raid.extractedAt = os.clock() end
        tellBackend(CFG.SHIP_LOST_FILE, "") -- out on foot or by pod: a ship leaves through Client_GetOutWithLootAndShip
    end)

    -- You died: the backend forgets the ship you took in.
    RegisterHook("/Script/SIGISPlugin.SIGISInventoryComponent:Client_DiedCloseInv", function()
        tellBackend(CFG.SHIP_LOST_FILE, "")
    end)

    -- In a space gate: only then does the next ship item the game saves count as the ship coming home (settle_ship). The
    -- extraction call itself passes item structs, which can't safely be hooked from Lua.
    RegisterHook("/Script/RaidGame.RaidPlayerController:Server_EnterEvacRaidVolume", function()
        tellBackend(CFG.SHIP_GATE_FILE, "1")
    end)
    RegisterHook("/Script/RaidGame.RaidPlayerController:LeaveEvacRaidVolume", function()
        tellBackend(CFG.SHIP_GATE_FILE, "0")
    end)
end

-- Back to the main menu EXTRACT_SECONDS after extracting (from main.lua's update, which stops there when this
-- returns true).
function M.returnAfterExtract(pc)
    if not (raid.extractedAt and os.clock() - raid.extractedAt >= CFG.EXTRACT_SECONDS) then return false end
    raid.extractedAt = nil
    local gi, n = FindFirstOf("SIGISGameInstanceNakama"), 0
    if valid(gi) then gi.ExtractedLoot:ForEach(function() n = n + 1 end) end
    log(("extracted with %d item(s): back to the main menu; they return to the stash in the lobby (after Play)")
        :format(n))
    -- Leave the way the raid server sent an escaped player home: RaidPlayerController's override of
    -- ClientReturnToMainMenuWithTextReason reads the reason ("ESCAPED", "DEATH", "DISCONNECT") and records the
    -- raid result, which makes the menu pay out finished contracts / campaign steps and write XP, cash, faction
    -- XP and the Escapes stat. A console `open MainMenu` left the result at LoggedIn: no rewards.
    local ok = pcall(function() pc:ClientReturnToMainMenuWithTextReason(FText("ESCAPED")) end)
    if not ok then
        lib("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, "open /Game/Maps/MainMenu", pc)
    end
    return true
end

M.startGiveGun, M.finishGiveGun, M.keepGunLoaded = startGiveGun, finishGiveGun, keepGunLoaded
M.ensureHud, M.applyLoadout, M.equipCarried, M.spawnFloorLoot = ensureHud, applyLoadout, equipCarried, spawnFloorLoot
M.extractNow = extractNow

return M
