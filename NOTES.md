# Marauders PvE — working notes

Goal: offline singleplayer PvE Marauders that keeps working after the official servers close.
Game: `<game folder>` (Steam app 1789480). Engine **UE 4.26.2** (crash context), one pak
(`pakchunk0-WindowsNoEditor.pak`, v11 footer, encrypted index and data, zlib). Exe is Denuvo-protected.

## Goals (user's words, 2026-10-30)
- Raids: PvE with bots (working, being polished: turning, patrols).
- **Space warfare + boarding with bots too**: the pre-raid/pre-station space phase (frigates in space, ship
  combat, boarding other ships) must work offline with bot crews. Relevant classes seen so far: ARaidFrigate,
  ARaidAIShipController, ARaidSpaceship(Inside), ARaidGame_Space, ARaidFrigateLevelStreamActor, drop pods
  (ARaidDropPodControl, Ship_DropPod_Pawn_C), frigate pawns (Ship_*Frigate01_Pawn_C), turrets, BotBehaviorShip BT,
  ARaidWorldProcManager.AIShipsToSpawn.

## Ground rules
- Offline mode only ever runs with mods; online mode restores stock files (`scripts/mode.ps1 online`). Never take a
  modded client into a live match. Easy Anti-Cheat is skipped by launching `RaidGame-Win64-Shipping.exe` directly.
- Offline project: working with Denuvo-protected code is fine (user, 2026-11-07).

## Layout
- `scripts/mode.ps1 offline|online|status` — installs/removes UE4SS + our mods, swaps `pgos_config.ini`.
- `scripts/launch-offline.ps1` — offline mode + start the game windowed.
- `scripts/send.sh "<cmd>" ...` — talk to the in-game PvEBridge mod (`bridge/cmd.txt` → `bridge/out.txt`).
- `mods/PvEBridge` — Lua bridge. Verbs: status, find <Class>, get <Class> <Prop..>, unwidget <WidgetClass>,
  spawn <ClassPath> [dist], dump/sdk/usmap/actors, anything else = console command.
- `config/` — UE4SS-settings.ini (engine override 4.27 needed for the scan to succeed; hot reload on, Ctrl+R) + mods.txt.
- `dumps/` — CXXHeaderDump, UE4SS_ObjectDump.txt, Mappings.usmap (taken in the main menu).
- `.github/workflows/check.yml` — CI on every push/PR: scripts/luacheck.py over every tracked .lua (Lua 5.4 via lupa, so
  the 200-locals limit too) and py_compile over every .py/.pyw. Needs no game files.

## UE4SS quirks in this game
- Engine version auto-detect fails → override in settings to **4.26** (NOT 4.27: UE4SS picks the ProcessEvent vtable
  slot by version; with 4.27 it calls slot 68, a stub returning 2, so every UFunction call from Lua silently did
  nothing and returned zeros). Real UObject::ProcessEvent = vtable slot 67 (offset 0x218), RVA 0x1c35330,
  prologue `40 55 56 57 41 54 41 55 41 56 41 57 48 81 EC F0 00 00 00 48 8D 6C 24 30`; ProcessInternal RVA 0x1c356e0.
- "unable to resolve JMP @ ...300483" is UE4SS failing to hook ULocalPlayer::Exec (harmless).
- `scripts/procmem.py` reads the live process (read-only) for this kind of check.
- `ExecuteInGameThread` never runs (ProcessEvent hook fails: "unable to resolve JMP"). Game-thread work is queued and
  drained from RegisterHook'd blueprint ReceiveTick functions (MainPlayerController_C in raids, MM_CoreMissions_C in menu).
- In-game console: F10 (ConsoleEnablerMod).

## Online backend (what offline mode must replace)
- Game instance chain: UGameLiftGameInstance → USIGISGameInstancePGOS → ...Nakama → ...GraphQL → USIGISGameInstance
  → SIGIS_ExampleGameInstance_C.
- PGOS (Tencent): URLs in loose `Binaries/pgos_res/pgos_config.ini` (offline mode points them at 127.0.0.1:1).
- Nakama: `marauderea2.us-east1.nakamacloud.io` (hardcoded, still contacted in offline mode!).
- REST: `ApiUrl = https://1lv5atybp2.execute-api.eu-central-1.amazonaws.com/prod/` (GameInstance property).
- Also: Vivox (mtu1xp.api.vivox.com), Sentry crash ingest, AWS EC2 eu-west-1, Team17 t17service auth.
- In "offline" mode the menu still logs in to the live account (PlayerUserName = USER#S#<steamid>) and shows the real
  stash. TODO: in-process network shim to redirect these hosts to a local mock backend.

## Raids offline — WORKS (first test)
- `open /Game/Maps/Raids/Spaceport_01?PID=x?PNAME=x?CREW=x?CPT=1?NUM=1?EOS=x?UPN=x?psid=1` from the menu loads the map
  standalone with a player pawn (PlayerPawn_C, MainPlayerController_C). Without PID the engine asserts
  "Couldn't spawn player: PlayerID is null". URL options read by the raid code: PID CREW CPT NUM EOS UPN PNAME psid.
- Default game mode in that case is ShootingRangeGameMode_C (no AI spawned). Real raid modes: ARaidGame_Space,
  ARaidGame_FreeForAll, ARaidGame_TeamDeathMatch (C++); BP subclasses unknown until the pak is listed.
- Maps: /Game/Maps/Raids/{Asteriod_Mine_01, MoonBase_01, Navy_Outpost_01, Penal_Colony_01, Spaceport_01}.
- AI: ARaidBot / ARaidNodeBot pawns (BotPawn_C, BotPawnGuard_C, BotPawnMilitary_C), ARaidGOAPController
  (GOAP_Controller_C, /Game/AI/Actions/*), AISPAWNTYPE {Player, AINormal, AIGuard, AIMilitary}, frigate AI
  (ARaidAIShipController), ARaidDebugAIGymSpawner, node system (/Game/Blueprints/NodeSystem).

- With UE4SS on 4.26 the player really stands at ~(59161, 24577, 300) on Spaceport (camera inside pod/helmet).
- AI spawns: `AIBlueprintHelperLibrary:SpawnAIFromClass(pc, BotPawnMilitary_C, BotBehavior, loc, rot, true, pc)` →
  BotPawnMilitary_C possessed by RaidAIController. It stands still (speed 0) — needs team/target/node setup (phase 3).
  Pass real objects for every UObject param (nil → UE4SS error); FTransform params don't marshal (use FVector/FRotator
  APIs). FString return values come back garbled; numbers/objects are fine.
- Map has 14 AINodeStart_C (AI spawn nodes) + RaidTeamStart_3. URaidCheatManager has SpawnBot/ForceMatchStart/
  ToggleInfiniteAmmo etc. (SpawnBot did nothing in ShootingRange mode).

## PvE AI — WORKS (mods/PvEDirector, 2026-10-30)
Why bots did nothing, and the fix for each (all automated in PvEDirector):
1. **No navmesh in the shipped client.** Raid maps have only AbstractNavData; every AINodeStart names a stream level
   "SpaceportWhitebox" that isn't in the client pak (server-only content). Fix: set Default__RecastNavMesh
   RuntimeGeneration=2 (Dynamic), spawn a RecastNavMesh, spawn a NavMeshBoundsVolume and give it the
   CullDistanceVolume's BrushBodySetup + transform (runtime volumes have no brush; toggle scale to recompute bounds),
   then NavigationSystemV1:OnNavigationBoundsUpdated(vol). Builds the whole Spaceport in ~1 s.
   (Passing a non-NavMeshBounds volume to OnNavigationBoundsUpdated reads garbage SupportedAgents → nothing builds.)
2. **Bots spawn asleep**: CustomTimeDilation 0, movement tick off / interval 1 s, MovementMode None, mesh hidden,
   bActiveated false. Shortly after spawn the bot also **unpossesses itself and stops its BT**. Fix: wake all of
   that, keep the controller, re-possess + RunBehaviorTree(BotBehavior) + BB IsDeactivated=false whenever found detached.
3. **Stale PathFollowingComponent**: MoveTo fails/never moves until the controller re-possesses the awake pawn.
4. **Teams**: player and bots both team 0. Player PlayerState.TeamNumber=1, RaidAIController.TeamNumber=2.
5. **Perception** never reports the player (HasLosToEnemy stays false); the BT attacks as soon as BB "Enemy" is set.
   PvEDirector sets it when the bot hears (≤900) or sees (≤6000, 70° half-angle, LineOfSightTo) the player, or is hurt.
6. **Invisible shooting**: asleep, the skeletal mesh has tick off / interval 1 s / bNoSkeletonUpdate=true, so the bot
   never visibly turns or aims; and its gun was never equipped, so RaidAIController::ShootEnemy (called every frame
   while engaged) applies damage directly with no weapon effects and no ammo use. Fix: wake the mesh
   (tick on, interval 0, bNoSkeletonUpdate=false, VisibilityBasedAnimTickOption=1), bot:ServerEquipWeapon(CurrentWeapon)
   (afterwards Server/MultiSimulateWeaponFire run per shot), and ctrl:K2_SetFocus(player) on engage.
7. **No muzzle flash / gunshot audio** even after equipping: per AI shot only ServerMultiSimulateWeaponFire runs
   (fire anim + recoil); flash and sound are skipped for bots (weapon.MuzzlePSC stays none). Fix (PvEDirector hook
   on that function, bots only): GameplayStatics:SpawnEmitterAttached(w.MuzzleFX, w.Mesh1P, w.MuzzleAttachPoint, ...)
   and w:OnFiringSound(false, 30, 30, muzzleSocketLoc, w.FireSound). Confirmed in game by the user: both work.
   CurrentAmmoInClip stays 30 (AI may have infinite ammo by design).
8. **Turning**: the AI controller snaps rotation to its focal point every tick (body follows via
   bUseControllerRotationYaw). A per-frame SetControlRotation/K2_SetActorRotation override made it worse, and
   K2_ClearFocus left it facing a stale Move-priority focal point from the last patrol leg. Setting focus once on
   engage isn't enough either: something (a tree service on a timer) keeps replacing it with a slowly refreshed
   point, measured 100-1000 units behind a circling player (felt as "takes ages to turn"). LastKnownPlayerPosition
   is NOT that point. Fix: K2_SetFocus(player) every frame while the bot has LoS (K2_SetFocalPoint(lastSeen)
   without) → focal offset 0, body error 3-7 deg at 1.5-5 m (17 deg at 1.6 m).
   Also: mesh bEnableUpdateRateOptimizations (URO) was on → animation frames skipped, choppy. Turned off.
   Bot MaxWalkSpeed 220 and crouched 220 (player walks 280); director uses 220 patrolling, 380 fighting.
9. **Patrols**: the tree does nothing without an Enemy and ignores BB "destination". Idle bots get StopLogic and walk
   MoveToLocation legs to random reachable points within 1800 of their spawn, pausing 4-12 s.
10. **Combat movement / walking in place**: BB destination and CoverEQsResult stay at FLT_MAX and HasLosToEnemy stays
    false offline (cover EQS / LoS service find nothing), so the tree retried an empty move: crouch + walking in
    place. Director sets HasLosToEnemy (LineOfSightTo), and every 3-7 s a reachable destination (500 around the bot
    with sight, 400 around last-seen without) + issues a strafing MoveToLocation (bCanStrafe keeps focus) — the tree
    doesn't cancel it. Crouch toggling every ~2 s is the tree's own crouch-peek.
11. **Floating helmets**: helmet "Helemt", backpack "Backpc", "ChestSlot" are SkeletalMeshComponents attached to
    CharacterMesh0 with no master pose (set only when a bot activates normally) → rest pose, floating.
    Master pose alone wasn't enough: the gear components are asleep like the body (tick off, interval 1 s,
    bNoSkeletonUpdate) so their drawn pose never refreshed (bone data already matched the head). Fix: wake each
    gear component the same way, then SetMasterPoseComponent(body, true).
12. **Foot sliding / slow legs**: AI anim BP rc_AI_FPS_AnimBP (/Game/Characters/MainPlayer/) sets
    Standing_LegsPlayrate itself each update (1.1 walking, 0.65 aiming) and overwrites Lua writes; RegisterHook
    post-callbacks on its BlueprintUpdateAnimation never fire (pre only). So speed follows legs instead:
    MaxWalkSpeed = 200 x Standing_LegsPlayrate every frame (220 / 130). MaxWalkSpeedCrouched 220 → 132 and
    Crouching_Legs_Playrate (BP leaves it 0) = speed/132. Anim Speed var matches velocity exactly (no lag).
13. **Moonwalking**: fighting moves crawling at 23-38 u/s (blocked) → cancelled after 1 s below 60 u/s.
14. **Crouch-peeking**: capped at 2.5 s crouched, then forced standing (UnCrouch every frame) for 6 s.
    NavAgentProps.bCanCrouch can't be written from UE4SS Lua (nested struct write errors).
15. **Cover + leaning** (director section 6). Game cover (CoverGenerator plugin: ACoverGenerator, UCoverPoint with
    left/right lean flags, cover EQS tests) isn't placed offline; a spawned ACoverGenerator +
    OnNavigationGenerationFinished(navmesh) generates 0 points. Own search instead: 16 reachable spots within 900,
    500-3500 from the player; full cover = standing eye (floor+150) can't see the player but eye ±35 sideways can;
    low cover = crouched eye (+85) can't, standing can (penalised +500 so full cover wins). LoS probes are
    ctrl:LineOfSightTo(player, viewPoint, false). Cycle: move → hide 1.5-3 s → peek 1.5-3.5 s → ... new cover after
    8-15 s or when flanked (exposed at the hide eye). Lean = ARaidCharacter:ServerLean(1 left / 2 right / 0),
    GetLeanAmount -40/+40, head shifts 20-45 units. Leaning doesn't move the AI eye, so LoS while peeking is probed
    from the leaned head. The tree fires at BB Enemy regardless of sight and the controller at MyEnemy: hiding clears
    both (BB ClearValue + MyEnemy=nil), peeking restores; combat state lives in e.inCombat. Result: 0 shots from
    behind cover, ~13% of shots leaned out.
16. **Speed**: whole-body GlobalAnimRateScale 1.45 while moving (>30 u/s) and MaxWalkSpeed = 200 x legs rate x 1.45
    → walk ~320, aiming ~190 with matching legs. Tree "shuffle" input creeping <60 u/s with no move request →
    StopMovementImmediately. Crouch out of cover capped 1.2 s / 10 s cooldown; posture enforced every frame.
17. **Leaning is cosmetic for AI**: while leaned out with BB Enemy, MyEnemy, bCanSeePlayer, HasLosToEnemy all set,
    RaidAIController::ShootEnemy ran ~80x/s but barely fired — it traces from the real (unleaned) eye, still behind
    the wall. Fix: each full-cover spot gets a walkable firing point 60 to the side (K2_ProjectPointToNavigation,
    verified standing LoS); peeking strafes onto it (+ ServerLean for looks), hiding strafes back. Cover search goes
    900 then 2200 before ever fighting in the open; running to cover holds fire (Enemy + MyEnemy cleared), clears
    focus so it faces the path, anim x2.0 (~440). Real sprint (StartSprint, MaxSprintSpeed 550) doesn't engage for
    bots. Result over 30 s: 45 shots, 40 from firing points, 0 while running, 5 standing (low cover / no cover).
18. **Exposed runs**: a soldier in the player's sight only takes cover within 600, and abandons a cover run after
    1.5 s in sight; then 4 s of open fighting before it searches again. Open fighting = side-steps of 200-450 across
    the player's line of fire (walkable-projected) every 1-2 s, anim x2.2 (~290 at the aiming legs rate).
    30 s sample: 52 shots = 20 peeking, 15 strafing, 17 still (low-cover pop-ups, step ends).
19. **Sprint animation** (written, NOT yet tested after a restart): AI anim BP has no run cycle; slots are
    DefaultSlot / FullBodyCinematic / JumpLandAdd / hitReact. A dynamic montage of
    /Game/Characters/MainPlayer/Animations/00_BaseMovement/rc_Sprint_FW_New on FullBodyCinematic keeps playing
    (on DefaultSlot it was cut within 1 s). Director plays it while running to cover at 550, stops on arrival.
    Real sprint for bots: ServerSetRunning(true) sets IsRunning briefly; StartSprint doesn't engage.
20. **Player loadout**: player spawns offline with an empty Inventory. UE4SS World:SpawnActor returns nothing for
    weapon classes. WORKING: take a freshly spawned donor bot's ARaidWeapon → SetOwner/Instigator/MyPawn +
    OnRep_MyPawn → append to pawn.Inventory (`arr[n+1]=x` works) → pawn:ServerEquipWeapon(gun) → donor.CurrentWeapon
    = nil, donor.Inventory:Empty(), K2_DestroyActor. Director does this at raid start (CFG.GIVE_GUN) and on F6.
    Reload fails offline (no ammo items in the SIGIS inventory); cheat toggles had no visible effect. Stopgap:
    R sets CurrentAmmoInClip back to the magazine size (director + bridge). Real fix = ammo items via inventory.

## Inventory / loot system (SIGIS plugin) — findings
- Items = rows of /SIGISPlugin/ExampleBlueprints/SIGIS_ExampleItemData (row struct
  FInventoryDatASIGISInventoryItemStruct: ItemType, size, stack, ItemBP class, AmmoType, container info...).
  Live item instances = ASIGISInventoryItem actors (UniqueItemGUID, ItemData row name, StackAmount, Condition,
  MotherItemGUID = container, BackEndID). ~326 exist in a Spaceport raid (container loot + bot loot).
- Row names seen: weapons StenSMG, Mat49Rifle, M45CarlSMG, DP28Rifle, MG42Rifle, BrenMk2Rifle, KrasaRifle,
  DaewooK1Rifle, Mac10Rifle, M50ReisingRifle, SterlingRifle_Short, M712Pistol, P08Pistol, 1911Pistol; ammo 9mmAmmo,
  45Ammo, 762Ammo, 556Ammo, 54RAmmo, 32Ammo, 12GaugeAmmo, 40mmAmmo; armour M1Helmet, SecurityHelmet, PilotHelmet,
  M1FlakChest, FullPlateChest, PanzerChest, LeatherJerkinChest; rigs/bags ShermanRig, LightBag, SackBag, MedicBag;
  meds BandageAid, SmallFirstAid, Morphine, Aspirin; plus valuables/crafting scrap.
- Loot tables: /Game/Data/Loot/AILoot/{AIBagTable, AILootTable, AIWeaponTable, CommandoLootTable,
  CommandoWeaponTable, SecurityLootTable, SecurityWeaponTable}.
- The player's USIGISInventoryComponent is on MainPlayerController (object name "Inventory"; look it up with
  FindFirstOf("SIGISInventoryComponent") — pc.Inventory is NOT a property). USIGISEquipmentComponent is on each
  pawn (player + bots). EEquipmentSlot: Head0 Chest1 Legs2 Rig3 Prim4 Sec5 Pistol6 Melee7 Bag8 ...
- `inv:Server_AddItem(FName(row), stack, cond, "Equipment", {Column=0,Row=0}, false, guid, 0, "", maxDur)` creates
  an item actor with that GUID (works). Equipping it crashes IN GAME CODE (null read at +0x260) both via
  inv:Server_EquipItem(guid, 4) and via the pawn equipment component's ServerEquipItemToSlot(guid, 4). Likely the
  same missing object as the inventory-screen crash (UI/backend-side). Crash RVA 0x9f2e80 in the exe.
- **Why equipping / the inventory screen crash**: crash RVA 0x9f2e80 is a getter `mov rax,[rcx+0x260]; ret`
  called on null; its neighbour returns +0x2D8. UDraggableItemWidget has ItemCanvas @0x260 and Item @0x2D8 →
  equipping looks up the item's inventory-screen icon widget, which doesn't exist offline. In a raid the
  inventory UI exists (2 InventoryMenuWidget, 32 InventoryContainerWidget, 35 EquipmentSlotWidget) but every
  container has 0 grid cells and there are 0 DraggableItemWidgets. Container IDs: PocketLeft, PocketRight, Stash,
  LootCon, LootPocketLeft, Lobby, Gift, scrap, Shop, RigSlot1-4. InitializeGrid() builds 0 cells even after writing
  InventoryGridSize → it reads sizes from USIGISInventoryComponent.InventoryContainerSizes (TMap<FString,
  FInventoryGridPair>), which the server fills from the backend loadout at raid start. Offline: empty.
- **Gun given via donor still won't fire for the player**: trigger input arrives (PlayerPawn_C:Shooting_Shaking
  fires), but no ServerFireProjectile / no ammo use; magazine attached (Bren_Default_Magazine_C, MagAmmoAmount 20),
  clip 30, reserve 0, not broken. Suspect the player fire path requires the weapon to be equipped in SIGIS
  (EquipmentIDs / HasPrimaryEquipped) — blocked by the same missing container/UI data.
- UE4SS crashers to avoid: out TArray params (DataTableFunctionLibrary:GetDataTableRowNames), reading fields
  inside nested structs (bot.WeaponToSpawn.RowName) and possibly :GetArrayNum().
- Verified: after the open-fight spell, bots re-seek cover ~4-5 s later (log 10:02:30 → 10:02:35).
- **Known issue: opening the inventory in an offline raid locks the controls and later crashes the game**
  (inventory comes from the online backend; PID=offline1 has none). Needs the local stand-in backend.
- Test immunity: bridge/god.txt present → director keeps the player un-damageable across raids; F9 toggles.
  (Toggling damage back on between tests kept killing the user mid-test — leave it on while testing.)
- Bot classes: BotPawn_C (80 hp), BotPawnGuard_C (200 hp), BotPawnMilitary_C; BT /Game/Blueprints/Pawns/BotBehavior,
  blackboard keys Enemy, NeedAmmo, destination, SelfActor, HasLosToEnemy, LookAtDist, bInCover, CoverEQsResult, IsDeactivated.
- masterNodeBot_C (GOAP) refuses SpawnAIFromClass (returns none) — probably needs a RaidWorldNode; not used yet.
- Without an enemy the bots hold their node (no patrol). Two bots killed the player in ~20 s; death → main menu.
- Keys (director): F7 start offline Spaceport raid, F8 spawn a soldier 15 m ahead. Status line every 10 s in UE4SS.log.
- UE4SS Lua gotchas: pass real objects for UObject params (nil breaks); FTransform params don't marshal; GetActorBounds
  needs all 4 args; a failed property read returns a bare function as the error. Never call AssetRegistry from the
  LoopAsync thread (crashed the game), and don't run Lua work there at all (see the bridge hang below). Hide the PGOS overlay (SetVisibility 1) — RemoveFromParent crashed the next travel.

## Pak key (not found yet; may not be needed)
- Static exe scan for the `mov [reg+off], imm32` key pattern: nothing (Denuvo).
- Memory scan (`scripts/find_aes_mem.py`, 8-aligned windows in RW memory, 2.9 GB, 112M candidates): nothing.
- Plan B: list content at runtime through the AssetRegistry from Lua, load assets with StaticLoadObject.
  Note the pak has a .sig file (signing) — check whether extra unsigned paks (LogicMods) mount before relying on them.

## Native helper (native/pvenative.c, built by native/build.sh with WinLibs MinGW) — 2026-10-30
- Why not a UE4SS C++ mod: no MSVC installed, SDK needs a linked Epic/GitHub account and a matching UE4SS rebuild.
  Instead `package.loadlib(<dll>,"*")` from the bridge (`luaq`) loads a plain DLL whose thread polls
  bridge/native_cmd.txt -> native_out.txt (rebuilt copies: `build.sh 2` -> pvenative2.dll / native2_cmd.txt; a loaded
  DLL is locked). Commands: info, alloctest, dumpmap <addr>, merge <addr>, fill <addr>.
- Engine allocator: GMalloc = exe base + 0x58aee70, "binned2" (vtable[18] returns the name), Malloc = vtable[2], Free = [6].
  TMap<FString,FInventoryGridPair> layout verified (TSet: elements 32 B, inline bits, 1 inline hash bucket; HashSize=1
  chain works regardless of hash function).
- **CORRECTION of the earlier theory**: InventoryContainerSizes is NOT empty offline: the player's component holds 9
  defaults (Stash 10x15, PocketLeft 2x2, LootPocketLeft, Shop, Buy, Sell, Gift, unlock, scrap). "0 grid cells" came from
  never-built widget templates (WidgetTree.*). Missing keys PocketRight/LootCon/Lobby/RigSlot1-4 were merged in.
- Real finding: in an offline raid NO live SIGIS_HUDOverlay_C / MainOverlay exists. Creating it
  (WidgetBlueprintLibrary:Create(pc, /SIGISPlugin/Widgets/HUD/SIGIS_HUDOverlay.SIGIS_HUDOverlay_C, pc) + AddToViewport)
  works without a crash and gives live InventoryContainerWidgets; InitializeGrid then builds cells (call it once only,
  it appends). Needed for PocketRight/Lobby/LootCon.
- Still crashing (null read at 0x260, same getter): Server_EquipItem after Server_AddItem(..., ToCon="Equipment"). The item
  has no DraggableItemWidget because "Equipment" is not a container widget. Next try: add the item into a LIVE container
  ("Lobby"/"LootCon"/"PocketLeft") so a draggable exists, then equip; also check whether pressing Tab crashes with the HUD.

## Offline inventory/equip findings — 2026-10-30 (session 3)
- Tab did nothing because the HUD actor (MatchHUD_C, ASIGISHUD) has InGameOverlay == nil offline. Fix: `hud.InGameOverlay = _G.PVE_HUD`
  (our created SIGIS_HUDOverlay_C). Tab then only blurs + shows the cursor; the menu stays Collapsed until
  `overlay:ShowInventoryMenu(0)` is called (then the Loadout screen shows; slots all empty placeholders).
- DraggableItemWidgets ARE created once the overlay is wired (Server_AddItem with the correct signature:
  `inv:Server_AddItem(FName(row),1,100,"Lobby",{Column=c,Row=r},false,guid,0,"",100)`); they sit at 0,0 size 100x30 in the Lobby canvas.
  Earlier adds (before the HUD was wired) never got widgets.
- Bridge usage: `send.sh 'lua <code>'` — verb and code in ONE argument; code must `return` a value (bridge tostring()s it).
- Equip chain runs: Server_EquipItem -> equipment comp ServerEquipItemToSlot -> Client_EquipItemToSlot (all on PlayerPawn_C),
  but pawn:EquipActorItem is never reached and CurrentWeapon stays the donor MG42 (no crash now).
- Donor MG42 has UUIDSIGIS=99841675, RepSlotIn=4, clip 30, reserve 0/-1, lastFireTime 0 (never fired). Registering an item with that
  GUID (MG42Rifle) and equipping it changed nothing.
- Firing: real LMB clicks run PlayerPawn_C:Shooting_Shaking (58 hits) but NEVER ARaidWeapon:ServerStartFire/ServerFireProjectile; a manual
  w:ServerStartFire() also does nothing visible. Mouse input is bound natively (no UFunction to hook); the gate is native code.
  Cursor is off and no menu open during these tests, so it is not an input-mode problem.

## Player gun fires — FIXED (2026-10-30, session 4)
- Root cause (disassembled from live memory): ServerHandleFiring_Implementation (RVA 0x1896b70) = `if (AmmoInClip() > 0
  && CanFire()) HandleFiring+UseAmmo`. The ammo getter (RVA 0x18875a0): ShipGun → 100; infinite-ammo check → 999; if
  MyPawn's controller is a player controller and MyPawn.EquipmentComp exists → returns the **StackAmount of the SIGIS
  item whose UniqueItemGUID == weapon.UUIDSIGIS** (0 if no such item, or if its item type byte > 1); otherwise
  CurrentAmmoInClip. Bots take the last branch, the player the SIGIS one → 0 → never shot. CanFire (0x187aa60) was fine.
- Fix (PvEDirector `loadGun`): Server_AddItem a weapon row with the gun's UUIDSIGIS into container "Equipment", stack =
  magazine size; R refills both. Firing drains the item stack in step with CurrentAmmoInClip. Verified: 17 shots/1 s held.
- Tools: `pc:SimulateInputKey({KeyName=FName("LeftMouseButton")}, true/false)` presses the trigger from Lua (no
  window focus needed). Original native thunks survive UE4SS hooks in UClass NativeFunctionLookupTable (RaidWeapon
  class +0x220, entries {FName, fn}); `_Validate`/`_Implementation` are vtable +0x660/+0x668 for ServerHandleFiring.
  Capstone disassembly of live code works (scratch dis.py pattern: procmem.read + capstone).
- Weapon hidden fields: +0x6D0 bit 0x04 = bWantsToFire, +0x6DC = weapon state (1 firing); pawn +0x8D4 bit 0x04 = wants to fire.
- Not yet checked: bullet damage on bots from the player's gun (no Server* trace RPC fires for the player in standalone;
  the shot path is native). Test by shooting a soldier.

## Player damage, fire effects, native reload — WORKING (2026-10-30, session 4b; fresh-launch tested)
- **native/pvepatch.dll** (pvepatch.c, built with the build.sh gcc line), loaded by PvEDirector at mod load via
  package.loadlib. Patches 3 role checks in memory (original bytes verified first; report in bridge/patch_out.txt):
  1. FireWeapon (vtable +0x7d0, RVA 0x1884b80) @0x1885c1a `jae` → 6-byte NOP (66 0F 1F 44 00 00): trace guns now
     send ServerTraceFireProjectile even as Authority. Standalone RPCs run Local, so the game's own server half
     (lag compensation, hit areas, damage) runs with the client's real trace. Without it shots never hurt anything.
  2. same for projectile guns (ServerFireProjectile) @0x1885d63 `73 28` → `66 90`.
  3. SimulateWeaponFire (vtable +0x7c0, RVA 0x189a490) @0x189a4a3 `je return` → NOP: it skipped all cosmetics
     (muzzle flash, OnFiringSound, shake, fire anim) for Authority weapons = everything offline. Bots get the real
     effects too now, so the director's bot flash/sound hook is off when this patch reports applied.
  A Lua-side alternative (calling the Server* RPCs with hand-made args) never did damage. A role change can't
  work either: standalone absorbs server RPCs from non-Authority actors.
- Firing needs the SIGIS HUD overlay: UseAmmo (vtable +0x748) refreshes the item's widget; no overlay = crash
  (null getter 0x9f2e80). Director `ensureHud` creates SIGIS_HUDOverlay_C and sets MatchHUD_C.InGameOverlay.
- Gun item: director gives the gun a FRESH UUIDSIGIS + item in "Equipment" (the donor soldier owns an item under the
  gun's original id; it was found instead of creating one, then died with the donor → gun had no item, couldn't
  fire). `keepGunLoaded` re-creates it if it ever vanishes.
- Ammo: EBulletType → row: 0 12Gauge, 1 300, 2 32, 3 45, 4 9mm, 5 10mm, 6 762, 7 54R, 8 556, 9 40mm, 10 Flare,
  11 FlameFuel, 12 Dart (row AmmoType byte at +0x1C0, ItemType +0x8 = 18 for ammo; read from the
  SIGIS_ExampleItemData RowMap). Director puts START_MAGS (4) magazines in PocketLeft (stacks of 60). The native
  reload (R, or automatic when empty) pulls from them into the gun item; loot from bodies (LootCon) works too.
  The old R refill hack is gone.
- Verified from a clean launch: 3/3 patches, HUD created, M712 + 2 stacks 10mm, fire drains the gun item, R moved
  10 rounds pocket → gun, soldier 80 → 58 HP, Muzzle_Flash_Small spawned. Gunshot audio not confirmed by ear yet.
- Testing from the bridge: `pc:SimulateInputKey({KeyName=FName("LeftMouseButton"|"R")}, true/false)`; after a
  bridge `raid` load call WidgetBlueprintLibrary:SetInputMode_GameOnly(pc) first (cursor/UI mode eats the input).
  scripts/gbase.py reads the module base from UE4SS.log (it moves between launches).

## Backend capture (2026-10-30, session 5)
- **native/pvenet.dll** (pvenet.c): read-only WinHTTP logger. PvEBridge loads it at mod start while
  `bridge/capture_on` exists. It rewrites WinHTTP import-table entries of modules under the game folder only
  (anti-cheat/Denuvo/other injected modules are skipped: the first build also hooked
  `denuvo-anti-cheat-update-service-launcher.dll`, which must never be touched) and wraps async status callbacks.
  Output: capture/winhttp-<time>.jsonl, one JSON per finished request (host, verb, path, headers with Authorization
  masked, bodies, status). capture/pvenet.log lists hooked modules. **capture/ contains live session tokens (auth
  response, vtoken): never share it.**
- WinHTTP users: nakama-cpp.dll (all Nakama REST), aws-cpp-sdk-core (GameLift/Lambda/Dynamo/Cognito), libcef
  (PGOS overlay web views), vivoxsdk, sentry. NOT the game exe (its own HTTP, e.g. ApiUrl REST/GraphQL, uses
  another stack: not captured yet) and NOT pgos_client.dll (own sockets + TLS).
- Nakama host marauderea2.us-east1.nakamacloud.io, REST v2. Menu load sequence (first capture, 14 requests):
  POST /v2/account/authenticate/steam?create=true&username=<steamid> → session; GET /v2/storage/public;
  GET /v2/account; RPC getbuildinfo {branch:"EA", steamid, needstoken} → {branch:{maintenence,version}, vtoken};
  POST /v2/storage (read social/created); RPC masterstartfunction (GET) → payload with cosequip, gifts, messages,
  playerstats (cash, chapterprogressions "A-0-0", contracts "M25!M15!M23!M18!M1!M40-00-00", contractstarttime,
  shiprotation, shipsleft, xp), prestige, raidertime, servertime; GET /v2/storage/inventory?user_id=<nakama id>
  → the stash; RPC getsteaminfo; GET /v2/storage/twitch; PUT /v2/storage cosequipped head/body (the game writes
  these itself on menu load).
- Stash item = storage object collection "inventory", key = item GUID, value
  `{"equip": false, "value": "<guid>-<Row>-<n>-<n>-<n>-<n>-<n>-<Container>"}` e.g. 13043956-BandageAid-3-1-2-6-0-Stash
  (fields after the row not decoded yet: likely stack, condition, grid column/row, rotation).
- Menu clicking capture (78 requests total). The backend is mostly a client-authoritative key-value store:
  - shops/contracts/quests/stats screens make NO requests: the client builds them from data it already has
    (masterstartfunction payload + its own data tables).
  - buy: client writes playerstats/cash (65000 → 57500 → 56695 → 57086) + a new inventory object, then RPC
    statChangeArray {"arrayIn":[{"stat":"TotalCash","amount":N}]} → payload = the account user record
    (metadata: Deaths, Looted, Matches, PirateGameRank, TotalCash, claimdate). sell: PUT /v2/storage/delete inventory.
  - moving an item in the stash: PUT inventory object with new col/row. Claiming gifts: delete "gifts" object +
    put "inventory". Cosmetics: PUT cosequipped head/body/voice (very chatty).
  - GET /v2/tournament (empty), GET /v2/account again, GET /v2/storage/public (regions, permMessage, titleNews...).
- Stash item value decoded: `<guid>-<Row>-<Stack>-<Condition>-<Col>-<Row>-<Rotated>-<Container>[-a!a!a!a!a!a!a]`
  (7 attachment slots on guns). A gun's Stack = loaded rounds (Mat49Rifle-36-60 = 36 rounds, condition 60), the
  same rule the client's fire path uses. equip=true items are the loadout; their Container is the slot
  (Prim, Head, Rig, PocketLeft...). A live raid presumably Server_AddItem's exactly these.
- scripts/capture_seed.py replays all captures (reads, then the client's writes/deletes) into
  capture/seed/account.json: account, storage collections, last reply of each RPC (getbuildinfo left out: tokens).
- Not capturable within the ground rules: matchmaking / raid / end-of-raid traffic (that would mean taking the
  modded client into a live match). Design those from the client code instead (SendEndMatchInfo, ExtractedLoot,
  DisconecttedLoot, AwsWs_StartSoloMatchMaking...).
- Next: stand-in Nakama server from the seed. Redirect idea: pvenet already wraps WinHttpConnect/OpenRequest, so
  it can point marauderea2.us-east1.nakamacloud.io at 127.0.0.1 and drop WINHTTP_FLAG_SECURE (plain HTTP to a
  local server, no certificate games, no hosts file).

## Local Nakama stand-in — WORKING (2026-10-30, session 5)
- **backend/nakama_standin.py** (Python stdlib, 127.0.0.1:7350): authenticate (Nakama-shaped unsigned JWT with
  uid/usn/exp: the client reads its user id from it), /v2/account, storage list (paged) / read / write / delete,
  RPCs masterstartfunction (built live from storage: playerstats, cosequipped, gifts + servertime),
  getbuildinfo (no maintenance, empty vtoken), getsteaminfo, statChangeArray (adds to account metadata);
  anything else answers {} / {"payload":"{}"} and is logged as UNKNOWN/UNHANDLED in backend/server.log.
  State: backend/state.json, built on first run from capture/seed/account.json (delete it to reset to the seed).
- **Switch:** `bridge/offline_backend` exists → launch-offline.ps1 starts the server (hidden python) if 7350 isn't
  listening, PvEBridge loads pvenet.dll, and pvenet's WinHttpConnect wrapper sends *.nakamacloud.io to
  127.0.0.1:7350 with WINHTTP_FLAG_SECURE dropped (cert/TLS WinHttpSetOption calls on those requests return TRUE
  without doing anything). Remove the file to go back to the live backend. `scripts/mode.ps1 online` removes UE4SS,
  so a stock launch never loads any of this.
- Verified: the menu's whole login sequence (12 requests, same order as live) served locally, 0 requests to the live
  Nakama host, stash moves saved to state.json. Sentry crash telemetry still goes to sentry.io (not redirected).
- Bridge hang (fixed 2026-10-30): after one game-thread `lua` job the PvEBridge LoopAsync thread never ran again
  (cmd.txt left unread) while the game kept rendering and ticking. Both threads shared the mod's Lua state; the
  async one stayed blocked on it. The bridge now reads and runs every command on the game thread (tick hooks,
  polled 4x/s, `luaq` = `lua`); LoopAsync only registers the hooks and then ends. bridge/heartbeat.txt is
  rewritten every 5 s while polling works. Commands wait during loading screens (no ticker then).
  PvEDirector still queues key-bind jobs from other threads (same pattern; fine so far).

## Raid loadout from the stash (WORKING, 2026-10-30)
- Live flow: the raid server calls SIGISPlayerController::Client_GetEquippedItems; the client reads its equip=true
  inventory from Nakama and answers Server_AwsN_EquippedItemsReturned(FString) (thunk 0xa778f0, _Validate vtable
  +0xf18, _Implementation +0xf20 = 0x9d4470 -> 0x9b2a20). Offline Client_GetEquippedItems does nothing (no request).
- The string is a JSON array of storage objects: `[{"value":{"equip":true,"value":"<id>-<Row>-<Stack>-<Cond>-..."}}]`
  (value is read as an object, then its "value" string; items containing "_Ship" are skipped; an empty string takes
  another path). The game registers each item under its stash id, spawns the weapon actor (row ItemBP), loads the
  gun's stack as its magazine and equips it on a fresh pawn.
- The stand-in writes backend/loadout.json in that shape (startup + every save). The director feeds it to that
  function once the SIGIS HUD overlay exists, while bridge/offline_backend exists; the donor gun is only a fallback.
- Verified: Mat49 (stash id 56548551, 36 rounds) equipped, fires, drains its own item (36 -> 26); 32 ammo in the
  left pocket; helmet + vest registered. Not verified: helmet/vest visible on the character.
- Your armour works (2026-11-16, bridge/t_parm.lua = your hp drop per bot shot at 5000 hp; M1FlakChest cond 40 in the
  loadout, Space_Solo_01 Fortress and Space_Delta Navy Outpost): 1911 (28) hit you for 21, Bren (36) for 29, both
  less 7 = the vest's value; a few hits did half of that (legs, armour first). Body hits wear the vest ~2 condition
  each (40 -> 0 in ~20-23 hits, read off its SIGISInventoryItem.Condition), then hits do the full 28 / 36. The
  game's own wear, nothing in the mod. No head hits landed, so the helmet is untested in game.
- Don't pass nil for a UObject parameter (pc:GetItemArmourValue(nil) crashed the game).

## End of raid: extraction and death (WORKING, 2026-10-30)
- Extraction: the raid server calls SIGISInventoryComponent::Client_GetOutWithLoot (thunk 0xa62f20, impl vtable
  +0x708 = 0x980950): on the local client it copies every carried item except KeyCard/GuildBadge rows into
  SIGISGameInstanceNakama.ExtractedLoot (+0x1110), which survives travel. The lobby, after Play on the splash
  screen (the main menu alone writes nothing), PUTs those to Nakama inventory and empties the array.
- The live server must also take the equipped items out of the stash at raid start (otherwise extraction
  duplicates them; seen once, cleaned up). Offline: the director writes the ids it loaded to backend/checkout.txt and
  the stand-in removes them (watch_checkout). Death then loses them, as live.
- The director hooks Client_GetOutWithLoot and opens the main menu EXTRACT_SECONDS (3) later; F5 extracts on the
  spot. Not checked yet: whether the maps' own extraction points call it offline.
- Death: the game goes back to the menu by itself and writes stats (statChangeArray, playerstats xp), nothing to
  the inventory. After every raid it also POSTs /v2/leaderboard/<TotalCash|TotalPres|TotalSP|TotalXP|TotalStash>
  {"score"}; the stand-in stores them in state.json "leaderboards".
- Lua tables passed as TArray<FString> parameters crash (pc:Client_RemoveEquippedItems({...}): game read
  0xffffffffffffffff). Don't pass arrays from Lua.
- Verified 2026-10-30: raid start checked 4 items out; extract -> menu after 3 s -> Play -> 4 items back (Mat49 with
  its remaining 25 rounds); death -> menu, gear gone, stats written. The stash was restored from a backup
  (backend/state.before-death-test.json) after the death test.

## Stability fixes (2026-10-30)
- Raid -> same raid crashed: the director keyed its per-raid state on the world NAME, which is the same when the
  map loads again, so it validated the previous raid's freed soldiers (IsValid reads the object: access violation in
  UObjectBase::GetInternalIndex). Now keyed on name + world address + controller address, and the per-frame aim
  tracking only runs for the controller the state belongs to.
- A hang on raid load: a mod's print() blocked writing to the UE4SS debug console window (Output::send ->
  DebugConsoleDevice -> ucrtbase wait); console writes block while it is paused (text selected). ConsoleEnabled = 0
  in config/UE4SS-settings.ini; logs are in UE4SS.log.
- Crash reports: %LOCALAPPDATA%\RaidGame\Saved\Crashes\*\CrashContext.runtime-xml (PCallStack has module+offset;
  UE4SS offsets map to its exports, no PDB shipped). A crash leaves CrashReportClient holding the game folder's
  DLLs, so mode.ps1 can't copy until it is closed.
- Verified: 3 raid loads in a row, raid -> menu -> raid, all with the loadout and no crash.
- Next: real extraction points offline, loot pickup in raids, then contracts/quests.

## Start Matchmaking -> space raid in your ship (WORKING, 2026-10-30)
- The lobby's START MATCHMAKING is the crew captain's launch button (Crew_LaunchToMatchBtn_SubWidget_Captain on
  SIGIS_MenuMain; you captain a crew of one). It sits on top of the solo button (MM_LaunchToMatchMain_SoloPlay,
  whose press -> SIGIS_MenuMain.LaunchGameSolo -> SIGISGameInstanceGraphQL::AwsWs_StartMatchMaking over the game's
  own AWS websocket). The captain path goes through PGOS crews. Both are dead offline: the lobby searches forever.
- Director: with bridge/offline_backend, the captain button's press (hooked from update() once the menu widget
  class is loaded) or AwsWs_StartMatchMaking starts a 4 s "search", then `open /Game/Maps/Space_Solo_0N` + the raid
  options. Second press during the search cancels. Crew/raider configurations would pick the crew/raider maps.
- Space maps (SpaceGameMode_C, RaidGame_Space, ISASpaceGameMode) need nothing extra: after the 15 s warmup the
  game mode spawns the starter frigate (FrigateInside_Starter_C inside, Ship_StarterFrigate01_Pawn_C outside, from
  /Game/Data/FrigData) and the player pawn in its cockpit; the "Space gate arrives in" timer runs. No backend calls.
  Until then you'd see open space, so the director holds the camera black (SetManualCameraFade) until pawn + ship
  + streaming levels are in, then fades in. Space maps get the loadout/checkout and extraction, no soldiers/navmesh.
- In-ship RPCs for later (RaidPlayerController): ServerDeploySpaceRaid, ServerDeployShipFromHanger, ServerLandFrigate,
  ShipDockingToStation, ShipBreaching, EvacRaid, LeaveSpaceRaidVolume.
- Hooking gotchas found on the way: hooking hundreds of Blueprint functions at once corrupts UE4SS's function map
  (FMallocBinned2 "unrecognized block" / AV at 0x70) - hook a handful. Inside a hook callback the bridge's `reply`
  isn't visible (it's only in the command's environment): log to a file or capture reply in a local first.
  Calling widget functions (GetVisibility...) on non-widget objects crashes. PostMessage clicks don't reach the
  game (UE reads the real cursor). Hovered widgets: UserWidget:IsHovered() from a menu tick hook.

## Flying the ship; interaction offline; per-update cost (2026-10-30)
- F at the helm did nothing and no "F" prompts showed: SIGISCharacter::InteractionDetection (sets
  LastInteractionActor/Comp, which the native Use -> 0x8fdf80 needs, and drives the prompts) runs from a timer the
  server's player setup starts; offline nothing does. The director runs it 10x/s for the on-foot PlayerPawn_C.
  Then F at the helm hands the frigate (Ship_StarterFrigate01_Pawn_C, AI-possessed until then) to the player
  controller and F exits again - all native, nothing else needed.
- PERFORMANCE RULE: FindFirstOf/FindAllOf scan every UObject: 30-45 ms each in this game. The director did two per
  0.5 s update (player controller + PGOS overlay sweep) = an ~85 ms hitch twice a second (ship flight stuttered).
  Never call them per update/tick: take the controller from the ticker, world.AuthorityGameMode, pc.MyHUD, and cache
  per raid (navMesh(), gunItem()). The overlay sweep only runs in a map's first 30 s. Verified after: worst frame
  11 ms over 270 frames of flight (was 85-92 ms every 0.5 s).
- Space look: Space_Solo_01 streams every raid location (Spaceport_01, MerchantShip_01, Navy_Outpost_01,
  Fortress_01) and AI frigate interiors (Strike_/Fast_Frigate_01_Ai_Interior) as LevelStreamingAlwaysLoaded
  sublevels at their own coordinates (raids around +15k..+63k X; the flight area is negative X). Their
  ExponentialHeightFogs and Fortress's unbound PostProcessVolume apply world-wide and UE4 draws one height fog
  (first registered): one run looked fine, the next was pale blue "underwater" (Strike frigate interior fog,
  colour 0.64,0.91,1.0). The space map itself has no fog. Director: per space raid, collect sublevel fogs +
  unbound PPVs once (when ready), all off; switch on only the nearest sublevel's within LEVEL_EFFECT_RADIUS
  (40k) of the camera. Note: a sublevel actor's GetWorld() is the sublevel's own UWorld, not the space map's.

## Docking at a station (WORKING, 2026-10-30)
- Flow: RaidDockingComponent::FrigateDocking (authority; 0x17d33c0) sets pc.DockedVolume (+0xC60) and an unnamed
  docking flag (+0xC38), then ClientStartAbility(10 = FRIGATEDOCK) -> Ability_Frigate_BoardStation (moves the
  ship, fade to black, area name, NetworkSyncPoint OnSync). Client half: ClientFrigateDockingToStation (0x18264a0,
  clears +0xC60/+0xC38). Server half: RaidPlayerController::FrigateDockingToStation (0x182e990: uses
  DockingStationForDroppod or DockedVolume -> SpaceshipInside dock, then Docked()).
- Standalone: one controller, ability takes only the client branch, and the client clear wiped the server's
  DockedVolume -> "docking animation" then nothing. Director: pre/post hook on ClientFrigateDockingToStation keeps
  DockedVolume and calls FrigateDockingToStation. Verified: dock, airlock, on-foot station level, native AI there.
- Same server/client pattern likely for undocking (Ability_Frigate_ExitStation, FRIGATEUNDOCK/FRIGATEEXIT),
  drop pods (Ability_DropPod_*) and breaching: check ClientXxx resets of server state first.
- Interesting natives: ClientStartAbility(EInteractionAbilityTypes) on RaidPlayerController starts these.

## Player-like rival bots — survey (2026-10-31)
Goal (user): "player" bots with random realistic loadouts, their own ship AI, who board you and enter stations
through airlocks like players, and are much more dangerous than the normal bots.
- Space_Solo_01 already runs, offline: 2 crewed AI frigates (Ship_FastFrigate01_Pawn_Ai_Child_C with
  AiFrigateController_Interceptor_C, Ship_RedBaron_StrikeFrigate01_Pawn_Ai_Child_C with AiFrigateController_RedBaron_C,
  ARaidAIShipController, tree /Game/Blueprints/Pawns/BotBehaviorShip = BotSearchEnemyLOS + BotShootEnemy + waits).
  They fly patrols (v 800/1200) on their own. Their interiors (FrigateInside_Fast_Ai_C / Strike_Ai_C) sit at the
  station coordinates with a captain (GOAPNodeBot_Boss_C). RaidFrigate.PlayerVersionOfAIFrig names the player class.
- 25 GOAP bots (GOAPNodeBot_Raider_C 100-250 hp, GOAPNodeBot_Boss_C 200-250) on stations and in AI ships, ASLEEP
  (dilation 0, unpossessed; GOAP_Controller_C kept in bot.CachedPlayerController). Loadouts are already random
  (Sten, M1 Para, PPSH, Bren MkII, Mat49, AC14, Johnson, GreaseGun, Liberator shotgun, China Lake, Webley/1911...).
  Controller AIActionsRowname = brain row (AverageRaiderSemi, EliteRaider ...); brains DefaultBrain_{Average, Elite,
  Rusher, Camper, Suppressor, Semi, Melee, Warden, Baron...}. Team 1 (= the player's team!).
- GOAP brain does NOT run offline: woken + possessed + StartActiveEvent + StartGOAPEvent + SetTargetEnemy(player)
  -> CurrentAction stays "", no movement. (A SpawnAIFromClass'd GOAPNodeBot_Raider_C gets a GOAP controller and
  200 hp but no gun and AIActionsRowname None: the proc manager applies MasterAILoadouts rows.)
- Navmesh: the space map has a baked static RecastNavMesh-Common (RuntimeGeneration 0) with 8 NavMeshBoundsVolumes
  covering the stations / AI ship interiors: bots there project onto navigation. The player's ship interior is
  spawned at runtime (~-110657,-244583) and has NO navmesh -> needs a runtime bounds volume (borrow an existing
  NavMeshBoundsVolume's brush, scale to FrigateInside.InSideComp extent 2550x3600x1250).
- Player ship interior: FrigateInside_Starter_C, 7 BreachTransforms (relative to the interior, e.g. -1444,-393,700),
  ShipDock*PlayerStart components. Breach API seen: RaidSpaceshipInside Breached/StartBreachedEvent/SealAirLock,
  RaidPlayerController ShipBreaching/ClientBeenBreached/NotifiyBreached, Ability_HumanBreachedIn.
- Stations: 11 StationAirlockDockingAreaAbility_C (ARaidFrigateStationDock) at Navy Outpost 1-6 / Spaceport 1-5;
  URaidUseableAirLockComponent StartTransferProcess/HangerDoTransfer.
- Waking a bot without the director's full wake() gives the floating helmet (gear master pose) and arms out of sync
  with the gun (user saw both). Always use the full wake.
- CRASH: a bridge script reusing an actor kept in a Lua global from an earlier command (_G.TBOT, probably dead or
  destroyed by then) crashed the game inside UE4SS (AV 0x18). Never keep actor references across commands/frames
  without re-finding them.

## Rivals module (mods/PvEDirector/Scripts/rivals.lua) — first build, 2026-10-31
- Population = the map's FrigInteriorSpawn slots - 1 (Space_Solo_01: 12 slots -> 11 crews; solo maps 1 per ship,
  crew maps 2-4). Ships: Ship_FastFrigate01_Pawn_Ai_Child_C / RedBaron Strike Ai_Child via SpawnAIFromClass at
  ShipSpawn points; flown with direct MoveToLocation (no pathfinding). The frigate's own AI keeps issuing patrol
  moves, so ours is re-issued whenever GetImmediateMoveDestination isn't ours (before that fix nothing docked).
- Stations found by survey: navmesh volumes named by station airlocks (Navy/Spaceport), anchors (Fortress, Merchant)
  and AI frigate interiors; space targets = Node_* RaidDockingComponents / the AI frigate pawn. Which stations and
  AI frigates exist varies per run.
- Bodies: GOAPNodeBot_Raider_C with AIControllerClass swapped to the soldier's RaidAIController (CDO write), gun from a
  BotPawnMilitary_C donor whose CDO WeaponTable picks the tier (AI/Security/Commando). Gun re-attached to
  CharacterBody0 (raider CharacterMesh0 is the head). Struct row-handle writes (WeaponToSpawn etc.) fail in UE4SS.
- Space maps: director now rebuilds the navmesh at runtime (fresh dynamic RecastNavMesh + a volume around your
  ship's interior), ~3-18 s; then Rivals.update + the soldier AI run.
- Verified in game: 11 crews launch, dock (Merchant), attack your ship, pull alongside and board (bodies at your
  breach points, StartBreachedEvent alarm, boarders engage). First build was far too aggressive (rolled every 0.5 s):
  now one decision per sighting, ~20% attack, max 2 attackers at once.
- Breaching pods (WORKING, verified 08:33): Ship_DropPod_Pawn_C spawned with an AI controller crashes ~0.5 s later:
  a timer (pod delayforLocalSPawnAbility, default 0.5; fn RVA 0xa0ae0a0) casts Controller (+0x258) to a player
  controller and calls vtable +0x6c0 on the result with no null check; with no controller it returns early. Writing
  the CDO's delay did NOT reach spawned pods (crashed again). Fix: SpawnAIFromClass, then UnPossess + destroy the
  controller in the same Lua call. Pods spawn hidden (show them) and are flown frame by frame from the director tick
  (Rivals.frame), aimed each frame at ship.Mesh:GetClosestPointOnCollision (frigate exteriors are small, ~1200 long).
  On contact: K2_AttachToComponent(ship.Mesh, KeepWorld), pod BP events DropPodisBreaching(true) /
  BreachingEffects_Part1_Movement(true) / ForceDropBoostingEffectForBreach(), ServerSetFrigateBreaching(ship,
  "DockAim") (impl RVA 0x183da40: stores ShipBreachingTo/socket, starts ability 9 only for a RaidPlayerController),
  then SpaceshipInside:StartBreachedEvent + pc:ClientBeenBreached (both safe). 2.5 s later the rider's body appears
  at a breach point. BreachCheck (RVA 0x18252c0) = trace from the pod's own "BreachAim" socket BreachingDistance
  (1250) forward hitting a RaidFrigate / breachable node; target ships only have a "DockAim" socket.
- Testing: touch bridge/rivals_provoke (or F4) = nearest crew attacks now (12000 out, pods after ~10 s).
- Tools: scratchpad dis.py / fn.py / ufn.py pattern = procmem.read + capstone; UFunction Func at +0xD8; *_Implementation
  via the object's vtable (thunk shows the offset).
- Boarders "friendly, gun lowered" (fixed): the donor's gun only went into the raider's Inventory; arm() equips
  CurrentWeapon, which was empty, so they never fired. rivals.lua holdGun() equips it (ServerEquipWeapon) and keeps it
  attached to CharacterBody0 (equipping attaches it to CharacterMesh0 = the head, where it's invisible); re-checked
  every update. Verified: MG42 boarder armed on arrival, shooting once in sight (counted via a hook on
  RaidWeapon:ServerMultiSimulateWeaponFire). A ship spawned this frame reads MainHullHealth 0 until it ticks.

## Shared AI brain, step 1-2 (2026-10-31): ai.lua
Engine checks (AI_DESIGN.md §4):
- Bot vs bot damage WORKS between awake, possessed bots on different TeamNumbers (BotPawnMilitary shooting another
  at ~7 m: 23 shots, 119 damage in 12 s). The earlier "sleeping NPC takes no damage" was the sleep.
- Accuracy: RaidBot.AIMissRate is the dial (defaults: BotPawn 0.85, Military 0.65; AIDifficulty 0.2 / 0.5,
  AiMissRange 2.25, AiMissRangeForAimedoff 1000). AIMissRate 0 did ~2x the damage per shot of 0.65-1.0 (noisy:
  guns differ per spawn). ShootEnemy (RVA 0x17eced0) itself only reads AIDifficulty (rand < it -> an extra vcall
  +0x7f0 with the enemy location); then fires via RVA 0x18192a0 / 0x1811890.
- Player shots run ServerMultiSimulateWeaponFire once per shot (same as bots) plus ServerTraceFireProjectile and
  ServerTraceMultiFireProjectile(Origin, ShootDir) (for near-miss suppression later). So one hook = all gunshots.
- Player state: pawn:IsHealing(), weapon:IsReloading() callable; ServerStartReload hook fires on reload.
- Not yet checked: ReloadAIWeapon animation, ShootAtLocation on a RaidAIController.
Built:
- mods/PvEDirector/Scripts/ai.lua: profiles (rival 1.0 / boss / guard 0.55 / soldier 0.3: spot-time multiplier,
  sight, cone, hearing, dispersion, reaction time, AIMissRate), 8 personalities with power-based picking
  (ramps), knowledge per enemy, gain-sight vision (distance curve x moving/crouch/peripheral/close/elevation/under
  fire/re-acquire/looking away), footstep + gunshot hearing with distance-based dispersion.
- main.lua: soldiers get profile by kind (BotPawn soldier, Guard/Military guard) and a personality; noticing is
  AI.perceive (gradual), reaction delay before first shot (e.holdUntil, released in trackTargets), noises at peace
  -> charge / freeze-watch-then-investigate-then-look-around (personality), every shot is AI.noise.
- rivals.lua: bodies get the "rival" profile; personality from kit power, kept per member (logged on materialize).
- Offline sim (lupa, scratchpad ai_sim.lua): spot times at 60 m standing: rival 1.0 s, guard 1.5, soldier 2.0;
  moving halves it; 50 deg off-centre 2.5-4 s.
- In game (Spaceport): loads, soldiers hear footsteps and log "(soldier/Rat) heard footsteps". Spotting not yet
  seen in game (test teleports put the player under the map; the start spot is inside the drop pod).
- Testing tip: don't teleport the player by navmesh projection on Spaceport, the navmesh reaches under the map.

## Bot leg animation vs speed (2026-10-31)
Per-frame log (bridge/t_legs.lua -> bridge/legs.txt; anim BP rc_AI_FPS_AnimBP_C reads Speed, Direction, IsAiming?,
Standing_LegsPlayrate 1.1/0.65) while watching the screen:
- RaidCharacterMovement.MaxMoveBackAndStrafeSpeed = 0.1 on bots (player 0.8): any sideways/backward move is capped
  at 10% (17 u/s aiming, 48 walking), and fighting bots strafe most of the time, with legs cycling at the full
  2.2x speed-up = shuffling on the spot. Now set per ai.lua profile (rival 0.8, boss 0.75, guard 0.65, soldier 0.6).
- The fixed GlobalAnimRateScale (1.45 / 2.2 when moving) also applied crouched (crouch speed 132 isn't raised) and
  the cover sprint montage (made for 550) played at 1.0 while the aim modifier held the bot to ~330.
- Fix (main.lua animate): GlobalAnimRateScale = actual speed / the cycle's natural speed (walk 200 x leg rate,
  crouch 132, sprint 550), clamped 0.6-2.4, smoothed; MOVE/STRAFE_ANIM_SCALE now only set the top walking speed.
  After: side-steps 103 u/s at 0.79x, crouch-walk 79 at 0.6x, side-runs 290 at 1.32x.
- Computer-use key presses (F8) don't reach the game's UE4SS key binds; use the bridge for test actions.

## Container loot (WORKING, 2026-10-31)
- Spaceport has ~206 loot actors (ASIGISBaseActor subclasses: SIGIS_Container_*, LootableCon_*, InteractionType 2),
  filled client-side at load (~300 ASIGISInventoryItem in ItemsInContainer). F -> Interact -> Server_StartLooting
  (impl 0x99eff0; returns early if CurrentActorLooting == this actor) -> Client_OpenInventory + Client_BatchAddLootItems.
- Bug: the client loot handlers (Client_AddLootItem 0x97e560, _Struct 0x97e360, _ItemsStruct 0x97e730,
  Client_BatchAddLootItems 0x97f2e0) skip creating the client's item copy when GetNetMode()==Standalone (0x316ebe0),
  so LootsItems stayed empty and the grid showed nothing. pvepatch.dll now NOPs those 4 jne (7/7 patches).
- Moving loot: Server_MoveItem(guid, "PocketLeft", {Column,Row}, ESlotType Normal 0, from Loot 3, 0) works.
- Clicks blocked (fixed): the game now builds its own SIGIS HUD overlay ("In Game Overlay Match") with the local
  backend, after the director already made one; ours sat on top and swallowed every click (loot grid, Esc menu).
  Director collapses its own overlay once the HUD's InGameOverlay is a different one.
- Testing tip: never SetInputMode_GameOnly / UIOnly from the bridge while the user plays (mouse stays captured,
  no clicks or no game input). Original native thunks: scratchpad nft.py (UClass +0x220 table by FName index).
- Floor loot (WORKING, user-confirmed 2026-11-01): main.lua spawnFloorLoot triggers every ASIGISLootSingleSpawner
  once the raid is ready (raid maps: spawns a SIGISResourceManager with gi.DefaultDropItem; space maps have their own
  ResourceManagerBP). TriggerSpawn (0x9b2380) takes a free pooled pickup (+0x488 in-use flag), moves it onto the
  spawner, rolls the loot table and sets the item. Space_Solo_01: 105 of 141 spawners place an item (the rest roll
  "null"). Pickups stay bIsActive=false offline; that doesn't matter: F picks them up into the inventory and the
  pickup goes back to the pool (it jumps ~64k units away, which looks like a bug in probes but isn't).
  Probe: bridge/t_floor.lua.

## Enemy bodies (WORKING, user-confirmed 2026-10-31)
- Bodies vanished: ARaidBot's death (vtable +0xcc0 = 0x17edf20) spawns DefaultDeathBody (SIGIS_ExampleDeathActor_C),
  moves the bot's loot into it, hides the pawn and sets a 0.2 s lifespan. The call that gives the container its mesh
  and pose (0x17ee028 -> 0x7e0290) is a stripped server function (`ret 0`), so the container stayed bHidden with
  no mesh: invisible but holding the loot.
- The player's death (0x1842800) uses the intact setup ASIGISDeathActor 0x8fac80(death, body mesh, pose comp, head
  mesh, body comp) + 0x8fac00(death, chest, helmet, bag, FString* badge). 0x8fac80 ends in OnRep_SetBoth's
  implementation 0x8f18f0: with a live pose component (R_BodPose has a mesh) it takes 0x8ef3c0, which needs
  R_HeadMesh AND R_BodyMesh non-null, sets both SIGISPoseMesh components and CopyPoseFromSkeletalComponent; else the
  client path applies BoneTransforms. A NULL head mesh made it do nothing: the container's default Raider head/body
  meshes stood in A-pose, bone hitboxes at the origin, so F found nothing.
- Fix (pvepatch.c): the stub call goes to botBody, which only queues the bot; three patches keep the dead pawn
  visible with no lifespan. The director ragdolls it on Multi_Deathevent (fires for bots offline) and calls the DLL's
  exported pve_bodies every frame (a lua_CFunction that ignores L: UE4SS exports no Lua C API). 3 s after the death
  it runs the setup with the bot mesh as both body and head, empties HeadPose, does the gear, then hides the pawn and
  gives it the original 0.2 s. pve_bodies_reset on every new world; queued entries older than 8 s are dropped.
  The jump stub is re-pointed if a renamed copy of the DLL is loaded later (live testing: pvepatch_test*.dll).
- A bot killed without the ragdoll fell through the floor once its pose was taken (seen in testing).
- Swap flicker + slow loot (fixed 2026-10-31): the game shows the body (un-hides SIGIS_ExampleDeathActor) only when
  the pawn is destroyed, so hiding the pawn first left ~20 frames (0.2 s) with no body drawn. And the setup itself
  runs from a 2.8 s timer (0x1819d00 SetTimer -> vcall thunk 0x17f94ec -> 0x17edf20; found with a stack capture in
  botBody: FTimerManager::Tick 0x34975b0), meant for the server's death animation; plus our 3 s = lootable 5.8 s
  after the kill. Now: pvepatch "Bot death: body after 1.0 s" (rate constant -> the 1.0 at 0x4043cb0, as the other
  death path 0x1806760 uses), BODY_DELAY_MS 400, pose -> show the body the next frame (the pose mesh's first frame is
  a few units off) -> hide the ragdoll 35 ms later. Measured (bridge/t_swap.lua, per-frame trace): body shown at
  1.39-1.42 s with the pelvis identical to the ragdoll's, ragdoll hidden 4 frames later, no frame without a body;
  bridge/t_lootable.lua: the interaction trace targets the body at 1.41 s. Not watched on screen.
- Smiley faces above bots: RaidCharacter's Billboard component (editor sprite) is visible in game. AI.tuneBody
  hides it (SetHiddenInGame).

## Cover and peeking, faster (2026-10-31, untested in game)
- Smiley sprites: RaidBot's Billboard shows the AI debug state (sprite texture "AISTATE", RaidBot.SetDebugState).
  Hidden once per bot (it stays hidden through state changes): AI.tuneBody for director bots, the bridge `bot` verb.
- Peeking was slow: hide/peek only switched on the 0.5 s update, and the 60-unit step to the firing point was a
  pathed move under the bots' sideways cap (MaxMoveBackAndStrafeSpeed 0.6 x ~190). Now trackTargets switches
  phases every frame, and animate() gives the step PEEK_SPEED 450, PEEK_ACCEL 6000 and no sideways cap.
  HIDE {0.7,1.6} s, PEEK {0.9,1.8} s.
- More cover: searches every COVER_RETRY 1 s (was 2), 24 candidates within 11 m, runs for cover up to 12 m away in
  sight (was 6) for up to 3 s, OPEN_FIGHT 2 s (was 4), cover 3.5-40 m from the player. Shot while peeking: duck
  back at once; shot in the open: search for cover at once (e.hurtAt, HURT_DUCK_SECONDS).
- Crash (13:13, EXCEPTION_ACCESS_VIOLATION executing heap, in UE4SS's hook dispatch under a blueprint call):
  the Multi_Deathevent hook ragdolled/unpossessed the bot inside the death event. The hook now only queues the
  ragdoll for the next frame (onTick's `pending`). Since then: 3 kills by ApplyDamage and 1 by player gunfire
  (bridge/t_shootbot.lua) plus the user's play, no crash. Crash reports: %LOCALAPPDATA%/RaidGame/Saved/Crashes;
  scratchpad dmp.py lists the faulting address and the stack's return addresses (pip minidump).

## Recoil, bullet impacts, gore (2026-10-31)
- **Recoil (fixed, pvepatch "Weapon recoil ammo gate")**: gun configs are fine (Bren VerticalRecoil 2.25, H +-0.75).
  The per-tick recoil (0x189f890, ARaidWeapon) needs weapon +0x26c > 0, the client's copy of the clip count, which
  is only written when Role < Authority (0x188c27f in the fire loop, 0x189c100 in StartFire; don't un-gate those:
  they then call the Server* RPCs, which run locally standalone). NOP of that `jle` -> verified: one ADS shot raised
  the aim 2.2 deg. By design the aim kick (pawn vtable +0x748 pitch / +0x740 yaw) only applies while
  bIsTargeting (pawn +0x9e8, ADS); hip fire only gets the control-rig arm shake (rc_FPS_AnimBP Recoil_*, which
  worked all along, camera wobble ~0.1 deg). The base FireWeapon (0x1884b80, all Weapon_Master guns) never touches
  currentRecoil/currentBulletSpread (+0x84c/+0x854): those are only used by subclass FireWeapons 0x1885ee0/0x18868b0.
- **Bullet impacts (fixed, pvepatch "Bullet impact effects")**: FireWeapon calls the client hit simulation
  0x18a1c70, which starts `GetNetMode() == 3 (NM_Client)` else return: impact FX, hit reacts (OnProxyHitReact
  event via 0x18d4900) and the pooled impacts (RaidPlayerController.PooledImpactActors, 150, taken by 0x1832420)
  never ran offline. Verified: 9 shots into the floor = 9 pool actors in use with particle, sound and decal set.
  Projectile guns (TraceFireWeapon false) skip 0x18a1c70 (FireWeapon 0x1885b57 jumps to the projectile branch); their
  hits go RaidProjectile OnRealImpact/OnRealAnyHit -> 0x189bc80, same NM_Client gate: pvepatch "Projectile impact
  effects" (0x189bcbc). Every gun seen so far is a trace gun (Sten, M1 Para, MG42, Bren, 1911, M712).
  M712 verified 14:06 (13/13 patches): scoped shot raised aim ~2.5 deg, 3 shots = 3 pooled impacts, impact actors
  BasePoolHitEffect_C at the hit point with PS_BulletHit_Concrete, VfxComp active right after the shot. Their
  DecalComp is nil, so bullet-hole decals are unconfirmed. Not watched on screen (an overlay masked screenshots).
- **Gore (as designed, not an offline bug)**: Mulit_Dismember_Implementation (0x180c4b0) only calls the BP
  DismemberEvent; BotPawn_C AddComponent's a BP_C_SimpleGoreSystem_C (SkeletalMesh = CharacterMesh0, e.g. bone
  lowerarm_l). Its bytecode (all 4 functions) spawns a BP_ChunkActor (generic static Mesh_Hand/Arm/Leg/Foot), blood
  emitters and a decal, and never calls HideBoneByName/BreakConstraint: the limb stays on the model. Fix idea: on
  DismemberEvent hide BrokenBone on the bot mesh, and on the death body's pose meshes after the director's body setup.
- Tools (scratchpad, rebuild if gone): scan.py (all instructions using a displacement), calls.py (numpy rel32
  callers), xref.py (vtable pointers), bpscan.py / bpfns.py (UFunctions a BP function's bytecode calls: Script
  TArray at UFunction +0x60, names via the object dump's [n:] FName indices), wpatch.py (test-write code bytes).
- Recurring crash, NOT caused by these probes (seen 3x, once with no test hooks): AV reading 0xffffffffffffffff in
  UE4SS (+0x4bddae <- +0x380bb0 <- +0x37f6fe <- +0x87b9d0, Lua call path) during/after fights, ~1-10 min into a raid.
  FIXED, see "Dead-bot crash" below.

## Dead-bot crash (FIXED 2026-10-31)
- Cause (from disassembling the stack in tools/ue4ss/UE4SS.dll): 0x87b9d0 is the metamethod dispatcher, 0x37f6f0
  the UObject `__index`, 0x380a50 the property lookup, and 0x4bdd90 is `IsA(UClass)` walking the SuperStruct chain
  (0x516440 = GetSuperStruct). So Lua read a property of a FREED UObject, and its garbage class chain ended at -1. It
  was a hooked ReceiveTick (the director's onTick), so it came from per-frame code. Not a TArray marshalling problem.
- The culprit: dead bots stayed in `raid.bots` forever, with e.fighting / e.cover frozen from their last fight. The
  per-frame peek/hide in trackTargets checked `valid(e.ctrl) and e.bot.Health`, with no valid(e.bot), so it kept
  reading the corpse pawn. The pawn is destroyed ~3.2 s after death (pve_bodies) and freed at the next GC (~60 s
  later), which explains the 1-10 min delay and the link to kills. Even `IsValid` reads the object's memory, so
  holding the reference at all is unsafe.
- Fix (main.lua `reapDead`, run first in trackTargets and updateBots): an entry whose bot is invalid or at Health
  <= 0 drops bot/ctrl/hand plus its fight state and leaves raid.bots while the pawn is still intact. Rivals' c.bodies
  keep the entry, but `valid(nil)` is false there, so bodiesAlive still reports the member killed. An invalid
  controller is swapped for the bot's current one. Line 896 now checks valid(e.bot) too.
- Rule: never keep a reference to an actor that can die or be destroyed past the frame you notice it. Drop it as
  soon as it is dead or invalid, before GC frees it.
- Verified: Spaceport raid (13:56-14:04) with 4 scripted kills of bots fighting from cover, ~3 crossfire deaths and a
  forced GC (KismetSystemLibrary:CollectGarbage) every 20-30 s. No crash and no Lua errors. The user ended the soak
  at ~8 min, satisfied. Not done: a repro on the unfixed code. Test tools: bridge/t_crash.lua (_G.CR_PHASE
  hurt/kill/gc) and bridge/soak.sh.

## Offline audit (2026-10-31)
Whole-game scan for code that only runs as a network client / via replication: see OFFLINE_AUDIT.md (prioritised list
of likely breakages: explosions, hit reacts, whizz, vault anim, ship system damage, turret manning, evac, contracts,
SIGIS add-item early-outs, gear meshes, IsServer-gated Blueprints incl. footsteps). Scripts + raw data:
tools/offline-audit/ (live read-only; name pool at RVA 0x58ceb40, GUObjectArray from UE4SS.log).
- Combat-feel fixes (same day, results in OFFLINE_AUDIT.md): explosions already work; pvepatch now 16 patches
  (+ instant-hit reacts 0x189b74c/0x189bbdf, vault/climb 0x180c648); director plays near-miss whizz and the broken-gun
  effect. Test scripts: bridge/t_wz.lua (whizz counter), t_wzshot.lua (fake bot near-miss), t_vault.lua, t_brk.lua,
  t_expl2.lua; `summon Proj40mm_C` spawns a grenade round (BeginDeferredActorSpawnFromClass fails from Lua).

## Rival ships dock into berths (2026-10-31, user-confirmed)
- Bug: docked rival ships just stopped within 2500 of a dock volume and floated outside the station (random
  heading, several crews piled on one dock).
- Berths: station nodes answer `ReturnAreaEntranceMoveToLocation(ship, dockComp, out FTransform, out cam, out boom)`
  (out FTransform DOES marshal from Lua). Navy Outpost / Spaceport return the berth the docking ability flies your
  ship to (inside the hangar bay, nose-in; ignore the pitch/roll, they belong to a marker mesh: yaw = quat yaw).
  Merchant and Fortress return zeros: there the berth is the docking volume itself along its long axis, nose toward
  the node. Fortress' two volumes overlap (one bay) -> deduped. AI-frigate "stations" get two berths alongside
  (ALONGSIDE 3000, follow the frigate). Survey found: Spaceport 6, Merchant 2, Fortress 1, AI frigate 2.
- rivals.lua: a crew reserves a free berth (stations with free berths preferred; all taken -> wait off the station
  BERTH_WAIT 45 s, then go elsewhere), flies to the approach point 3500 out, glides in (DOCK_GLIDE 7 s, smoothstep,
  in R.frame), is held there (actor AND controller rotation: the ship's AI controller keeps turning it otherwise),
  and glides back out (UNDOCK_GLIDE 5 s) before flying off. flyTo is ignored while gliding.
- Calling RaidDockingComponent:FrigateDocking(ship) / sweeping the player ship into a volume from the bridge did
  nothing (the real flow needs the helm/ability); not needed.
- Screenshots: an always-on-top window masks the game for computer-use; use the console `shot` (bridge) ->
  %LOCALAPPDATA%/RaidGame/Saved/Screenshots/WindowsNoEditor/. bridge/t_view.lua / t_view2.lua aim the player's ship
  (possessed via pc:Possess) as a camera.

## Progression / missions — survey (2026-10-31)
- All on ASIGISPlayerController (client-side system): StartMission, IncrementMission, IncrementChapterMission,
  Client_CheckMissionEvent(FName, EContractType), GetAllMissionsForChapters("A") (54 rows), GetAllMissionsForRaid,
  GetMissionProgression, CollectMissionReward/CollectChapterMission, ApplyRewardsFromRaidMissions,
  ProcessedEndRaidMissionAndClear, AddXP, AddXpToFaction. Returned struct arrays come back as Lua tables of
  LocalUnrealParam: use `e:get()` (bridge/t_miss2.lua, output bridge/missions.txt).
- EContractType: Attack 0, Deliver 1, Kill 2, Destroy 3, Raid 4, Inspect 5, Guard 6 (hold an area), Test 7
  (kills with a weapon), None 8.
- Chapter A = the campaign, 53 steps (A0 Deliver 3 JunkScrap ... A52 Become Infamous): delivers (menu side), Kill
  (item "Human" = Marauders, "Raider Boss", none = any), Destroy (space mines, flak/radar/rocket turrets), Inspect
  (forklift, hidden stash), Guard (hold room/vault/medical/dock pod area/space gate/capital engine room for N s),
  weapon-kill counts. Rewards PlayerXPReward/CashReward; A17 gives FrigateFast_Ship. Storage: playerstats
  chapterprogressions "A-0-0", contracts "M2!M12!M5!M15!M11!M28-00-00" + contractstarttime (rolled by the client
  itself), xp, points — the client writes all of these.
- Offline in a raid: a player kill DOES call Client_CheckMissionEvent("AIRaider", 2). Contract actors exist on the
  maps (Spaceport: 12 Contract_Int_* inspect actors incl. RepoMan/HiddenStash, 7 Contract_Hold_* with a GuardArea
  box), but standing in a GuardArea (IsOverlappingActor true) fires nothing (audit #12: overlap code skipped as
  Authority). Calling Client_CheckMissionEvent by hand with row names / item names / actor class changed no
  progress, GetChapterMissionAmount stays 0 and pc:GetXP() is 0 in the raid: the raid-side controller seems to have
  NO mission state (live, the raid server must have handed it over at raid start). GetAllMissionsForRaid returned
  Spaceport_C2 / Merchant_A21 / Fortress_K28, which don't match the saved contract list.
- Next: disassemble Client_CheckMissionEvent / IncrementMission / StartMission and find where the active missions
  and chapter progress live (game instance? loaded from the masterstartfunction payload in the menu) and how the
  menu applies raid results (ProcessedEndRaidMissionAndClear / ApplyRewardsFromRaidMissions). Then: feed the state
  into the raid, emulate Guard/Inspect overlaps in the director, and check Destroy (RaidSubNodeActor:
  CheckMissionActor hook registered, not yet triggered).
- Spaceport_01 opened directly (`raid`) has no streaming sublevels; 12477 static meshes, only collision blockers
  hidden (MantleBarrier01 etc.). The user saw large void / unfinished (orange grid whitebox) areas; same package as
  the station streamed into the space maps. Unresolved whether live looked different there.

## Missions offline — WORKING (2026-10-31, mods/PvEDirector/Scripts/missions.lua)
- Where the state lives (game instance, survives travel): +0x1190 TArray<FMissionProgress {FName, int}> = this raid's
  active contracts and progress; +0x1160 chapter {FString "A", int stage +0x10, int progress +0x14}. Contract rows:
  gi.ContractTable (+0x23E0, 134 rows), chapter rows gi.ChapterMissionsTable (+0x2400). Row layout (FContract /
  FChapterMission): type +0x58, need +0x5C, item +0x60, ContractRequiredActorTags TArray<FName> +0x68. Dumps:
  bridge/contracts_table.txt, bridge/missions.txt (chapter A). Live readers in the session scratchpad: dtrows.py,
  prog.py, fname.py (name pool RVA 0x58ceb40, 4.26 FNameEntry header len = hdr >> 6).
- The SPACE MAP assigns 3 contracts per run, for stations present (e.g. Spaceport_C2, Merchant_A15, Spaceport_K12).
  Opening a raid map directly (bridge `raid`) gives none: test missions through Space_Solo_01.
- Client_CheckMissionEvent(tag, type) impl 0x9b68d0 (vtable +0xe20); chapter half 0x9b5bb0 runs first. Per active
  row: type must equal the event type and the tag must be in the row's actor tags. Kill/Destroy/Raid -> IncrementMission
  (0x9ca2c0) / IncrementChapterMission (0x9ca1a0). Test (weapon kills) also checks the equipped weapon (vcall +0x1040).
  Guard: 1 s repeating timer (chapter 0x9da150) that counts while bInChapterVolume (+0x980) / bInMissionVolume (+0x964).
  Inspect: sets CurrentTimedMission (+0x968) and a timer (contract 0x9da340) that counts while the "Use" key (F) is
  held, pawn.LastInteractionActor (+0x508) is set and within 400; the first tick without Use stops it.
- Offline gaps and fixes:
  * Contract actors' server half (overlap -> flags + event) is skipped: missions.lua does it. Hold areas: entering the
    GuardArea (IsOverlappingActor) sets both volume flags and sends the actor's Tags[1] (e.g. C2_WeaponIntel; NOT the
    class name) with type 6; leaving clears them. Read actor Tags with a.Tags:ForEach(e:get():ToString()).
  * Inspect objects are never offered by InteractionDetection (ShouldShowContractInteraction): right after each
    director InteractionDetection, missions.interact makes the inspect object within 350 that you look at (35 deg to
    start, 60 to keep, 1.5 s grace) your LastInteractionActor, and sends the type-5 event when Use is down and no
    inspect runs. No "F" prompt is shown for them yet.
  * Raid result: RaidPlayerController's ClientReturnToMainMenuWithTextReason override (0x1826900, vtable +0xa00) maps
    the reason text "ESCAPED"/"DEATH"/"DISCONNECT"/"TERMDISCONNECT" to gi.LastMatchResult (setter 0x8fb7c0) and runs
    the end-of-raid bookkeeping. The director's extraction used `open MainMenu` (result stayed LoggedIn=2, no
    rewards); it now calls pc:ClientReturnToMainMenuWithTextReason(FText("ESCAPED")).
  * Rival deaths send Client_CheckMissionEvent("Human", Kill) (rivals.lua bodiesAlive) for "Kill N Marauders".
- Verified (offline, Space_Solo_01): hold Fortress_A26 0->30 in 30 s; Spaceport_C2 30/30; inspect Spaceport_K12 5/5 via
  the module with F held; extraction -> chapterprogressions + xp written, Escapes/Matches stats, contracts cleared.
  Cash + faction XP for finished contracts were written once (19:25:57: cash +4500 = Spaceport_K10, factions
  0-0-25-0-0), about a minute after reaching the menu, together with the leaderboard posts: most likely when Play
  was pressed on the splash screen (same step that returns extracted loot). Not yet re-confirmed.
- Not verified: Destroy contracts (space mines / turrets; RaidSubNodeActor:CheckMissionActor), chapter steps in a raid
  (A0 is a menu Deliver; you need 3 JunkScrap), double counting of rival kills (native may also send AIRaider), the
  Use key if rebound (CFG.USE_KEY = "F"), death path (game returns to the menu by itself).
- Crash: reading a TArray<FName> inside a returned struct (FRaidMissionUI.ContractRequiredActorTags) from Lua crashed
  the game. Read row data from memory instead.
- Crash (2026-11-16, pod to the Mini Mine, contract Just Deserts): the contract actors were kept as UObjects from the
  once-a-raid scan; one was freed later, and the first IsValid on it (on arriving within 4000) read freed memory
  (AV in UObjectBase::GetInternalIndex under a Lua call, 2 pcalls deep). Same signature crash on 2026-11-15 21:28.
  Now each entry keeps its object path and missions.lua looks it up with StaticFindObject on every use. Not yet
  re-tested at the Mini Mine.

## Rival ship combat (2026-10-31, rivals.lua)
- Why ships never fired: every frigate's DefaultInventoryClasses = InGame_BowGun_50Cal_C, never spawned offline
  (CurrentWeapon nil, also YOUR ship). And ARaidAIShipController::ShootEnemy (thunk 0x18dabc0 -> 0x17ed260) only fires
  if the pawn is a RaidFrigate with MyShipInside (+0xC90, a crewed interior: 0x1867230), hull > 0, BB Enemy a
  RaidCharacter with bShipAttackable (+0x54D), LoS, and the pawn's CurrentWeapon can fire. Rival ships have no
  interior, so their own ShootEnemy can never fire.
- Fix: `summon InGame_BowGun_50Cal_C` (console cheat, works) + SetOwner/Instigator/MyPawn/OnRep_MyPawn, append to
  ship.Inventory, ship:ServerEquipWeapon (armShips; your ship gets one too). Fired with gun:ServerStartFire/
  ServerStopFire from R.frame (fireControl): bursts while the target is within GUN_RANGE and GUN_CONE of the nose;
  the gun aims along the AI controller's view (K2_SetFocus target). Verified: rival vs rival 20-43 bursts per fight,
  ships sunk; your hull took hits (575 -> 540). Long range = many misses (GUN_RANGE now 6500).
- Swarming: the frigates' own behaviour tree (FindShipToAttack -> nearest ship, usually yours) steered every ship
  at you. Rival ships now get Controller.BrainComponent:StopLogic at spawn; rivals.lua alone decides targets/moves.
- Combat model: travelling crews size up every ship in sight (yours or another crew's) once per ATTACK_COOLDOWN,
  attack with aggression^2 x ATTACK_CHANCE (0.45), max MAX_ON_SHIP (2) attackers per target; shot at -> fight back
  (c.shotBy from fireControl, else you if close). Attack runs: fly at the target firing (nose slewed onto it at
  NOSE_TURN deg/s), overshoot 2500 past, swing out 5-7 km, repeat; break off after ENGAGE_MAX or when the target is
  gone; flee + extract below FLEE_HULL.
- Boarding (your ship only): decided per fight: BOARD_ONE 0.35 (crews of 2+, one member boards, ship keeps fighting),
  BOARD_ALL 0.08 (whole crew; solo crews' only chance). Boarders are a "party" (members flagged m.boarding, own
  materialize/dematerialize via a party table); pods take only them. Station visits leave boarders out. NOT yet
  seen in game (solo map = crews of 1 = 8% chance).
- Simulated clashes: two simulated crews docked at one station: SIM_CLASH_PER_MIN 0.25 that one loses a member.
- End of raid: GameState.RemainingTime (seconds; round 1500). Each crew heads out at EXTRACT_REMAINING (150-420 s
  left): flying crews extract, docked crews walk back to the airlock, undock and extract, boarders go back.
  Verified by setting RemainingTime from the bridge (300 -> flying crews left; 140 -> docked crew left and extracted).
- Stations: materialized rivals roam areas; hunters (0.25 + 0.5 x aggression per re-home) pick your area (logged
  "is hunting through your part of"). Not yet watched; rival bodies in one station don't fight each other (same team,
  director AI targets only you).
- Probe rule (crashed once): never touch an actor from FindAllOf without IsValid (destroyed ships are still listed).

## Factions, station garrisons, rushers (2026-11-01)
- Director AI is faction-based now (main.lua): factions = station soldiers ("station"), each rival crew
  ("crewN", team 10+N so bot damage applies between crews), and the player (team 1). Everyone is hostile to every
  other faction. Each bot keeps its foe as an ENTRY (PLAYER sentinel or another raid.bots entry; foeOf(e)), never a
  pawn, so a foe that died reads as gone (reapDead clears entry.bot). updateBots sizes up every hostile body within
  PERCEIVE_RANGE (7000) with AI.perceive (nearest first); spotted -> engage(e, pawn, entry); heard -> investigate;
  shot by someone unseen -> the nearest hostile. combatHints/trackTargets/peek use the bot's own foe.
  ai.lua: the "heard up to" noise marker is per enemy (k.heardUpTo), since a bot now checks several enemies per update.
- Rivals no longer know where you are: in a station each body searches a new area every 50-110 s, preferring spots
  far from the crew's last 6 searched areas; they find you, other crews and soldiers only by sight/sound.
  Verified (Spaceport): 3 crews inside, "Zed spotted salvage_sally at 7 m" -> salvage_sally killed; soldiers heard it.
- Station garrisons on space maps: stations streamed into a space map had NO soldiers (log "soldiers alive 0" all
  raid). The first time you enter a station (rivals.lua playerPlace), the director queues CFG.GARRISON (8) soldiers
  at its RaidAINodeStart nodes (else random reachable points) >= MIN_SPAWN_DIST from you, spawned ONE PER UPDATE
  (spawnQueued): 8 spawns + a rival materializing in one tick crashed the game once (EXCEPTION executing heap from
  UE4SS's hook dispatch under the ReceiveTick hook; same signature as the old death-hook crash).
- Ship targeting: you and rival ships are equal candidates (same chance per sighting, MAX_ON_SHIP 2 each). Shot by an
  unknown shooter -> the nearest ship in gun range (no longer "you if close").
- Rushers (RUSHERS 0.25 of crews, logged "(rusher)"): never start fights in space, fly straight to a station and
  dock; they fight back only when shot at. Verified: rushers were first to dock.
- The station's own GOAP raiders (GOAPNodeBot_Raider_C, team 1 = the PLAYER's team, not director-managed) were awake
  and moving in one run and one was being shot. Not handled: they're neither soldiers nor rivals.
- PROBE CRASH RULE: an unpossessed bot's Controller comes back as a wrapper around NULL; reading a field through it
  (c.MyEnemy, c.TeamNumber) crashes the game (AV 0x18 in UE4SS, pcall can't catch it). IsValid-check every object
  before reading fields (bridge/t_botfight.lua does).

## Station defenders = the levels' own NPCs (2026-11-01)
- Space_Solo_01 places 25 node bots across the station/AI-frigate sublevels: 22 GOAPNodeBot_Raider_C + 3
  GOAPNodeBot_Boss_C (asleep, unpossessed; the GOAP brain doesn't run offline). Navy Outpost has 7 of its own; the
  Fortress none (it gets spawned soldiers). These are presumably the live server's station NPCs.
- rivals.lua garrisonStation (first time you enter a station): placedDefenders(st) = those classes inside the
  station box, not already in raid.bots (rival bodies are the same class); adopted ONE PER UPDATE (adoptQueued):
  old controller UnPossess, b.AIControllerClass = BotPawnMilitary's (RaidAIController), b:SpawnDefaultController(),
  X.arm (wake/possess/team 2/tree), entry { placed = true, patrolRadius = POST_RADIUS 900, hand = CharacterBody0,
  mind profile boss/guard/soldier }. Their own gun is kept in the body mesh's hand (holdGun each update,
  keepDefendersArmed). Fewer than MIN_DEFENDERS (4) of its own -> X.garrison spawns the rest as BotPawn soldiers.
- Brain row: b.CachedPlayerController is a WEAK pointer (FWeakObjectPtr): read it with :Get() (calling IsValid on the
  weak pointer itself errors). The row came back empty on Navy Outpost, so all were profiled "soldier".
- Teams: player 3 (was 1, which the placed NPCs default to), soldiers/defenders 2, rival crews 10+.
- Verified (Navy Outpost): 7 defenders up with their own guns (Webley, Bren MkII, LongDouble, Sten, DeLisle) in hand,
  visible, patrolling; one spotted the player at 4 m and engaged, another at 10 m. Screenshot: body looks normal.

## 8 defenders per station; space-map navmesh bug (2026-11-01)
- MIN_DEFENDERS = 8. A station with some of its own placed NPCs is topped up with copies (topUpStep, one step per
  update, after its own are adopted): a GOAPNodeBot_Raider_C body with the head/body/helmet/chest/backpack meshes of
  one of the station's own (template DATA recorded at adoption: mesh assets, gun class, profile, health; never the
  pawn), its gun = `summon <the template's gun class>` handed over on a later update (like the bow guns), armed on
  the station side (team 2, faction "station"), patrolling POST_RADIUS around a spot. A station with none of its own
  (Fortress) gets 8 of the raid maps' soldier types (X.garrison). Verified: Navy Outpost 7 + 1 (LongDouble), Spaceport
  6 + 2 (1911s like its own).
- BUG FOUND: on space maps the director's navMesh() returned the RecastNavMesh actor startSpaceNav spawned
  (RecastNavMesh_<n>), which the navigation system doesn't use: every space-map nav query against it came back empty
  (rival body spawn spots, rivals' station searching, defender spots, and main.lua's reachableNear for soldiers'
  patrol/cover/strafe points on space maps). navMesh() now picks the registered RecastNavMesh-Common on space maps.
  (The runtime rebuild works on -Common: it's RuntimeGeneration 2.) Raid maps unchanged.
- stationPoint(st): random reachable point within 3000 of a station's entries / defenders' posts (st.posts). No box
  check: a station's box is one navmesh volume (the first holding an airlock) and can miss most of the station.

## Trailer tooling (2026-11-01, trailer/)
- `bridge/cine.lua`: trailer camera (a CameraActor the controller views through, animated from the controller's
  ReceiveTick; HUD + widgets hidden). Shots: orbit, chase, duel (behind one ship looking past it at another), trail
  (follows the path a bot walked: stays out of walls in corridors), dolly, track. Ships are small (~300 units long):
  orbit radius 500-700 for your frigate. Helpers: bridge/t_pick.lua (ships), t_pair.lua (closest moving pair),
  t_bots.lua (station bodies), t_tocon.lua (walk up to a container).
- Recording: `trailer/setup.sh` after every map change (r.setres 1472x828w + window to the top-left, so the
  always-on-top Claude window doesn't cover it), then `trailer/rec.sh <name> <secs>` (ddagrab desktop duplication;
  gdigrab only sees black for this DirectX window). The crop drops the Razer overlay's FPS bar. Avoid computer-use
  while recording (its "Claude is using your computer" banner is captured); front.ps1 / key.ps1 / click.ps1 do focus
  and input instead (mouse clicks don't reach the menu: call the widget's BndEvt function from the bridge).
  Watch for Steam friend pop-ups in the bottom-right of takes.
- `trailer/make_trailer.py`: edit list, synthesized score (numpy), frame renderer -> marauders_offline_trailer.mp4.

## Rival hulls and turrets (2026-11-01, rivals.lua)
- The player ship designs live in DT_ShipInfo (26 rows: name, hull mesh, Turret01/02Type), DT_FrigateStats (speed,
  turn, armour, hull) and FrigData (interior prefab). The 26 designs are 6 base pawns (/Game/Blueprints/Ships/
  Ship_{Scout,Fast,,VIP,CapitalShip,RedBaron_Strike}Frigate01_Pawn) plus hull meshes in the same folders (same
  skeleton: SetSkeletalMesh keeps Soc_Turret01/02). All 6 fly under SpawnAIFromClass's plain AIController
  (MoveToLocation works) but have NO blackboard: setShipEnemy only sets focus for them.
- Turrets are separate actors (ARaidCharacterTurrent) attached to the hull mesh's Soc_Turret01/02 (scale 1.25). The
  hull blueprints spawn their own default turret (and 2 camera turrets); fitTurrets replaces the default one.
  Classes in this build (Ships_Extras/Turrets): SingleTurret01, Dual25mm01, 75mm_Turret01, RocketArtillery01 (12
  barrels), TorpedoLauncher (3). Triple/Flak/Howitzer/Nuclear/DualRockets have no class: mapped to the nearest.
- Firing without a gunner: turret:ServerFireProjectile(origin, dir, socketIndex) spawns its ProjectileConfig shell
  with its effects and explosion damage (verified: 75mm 120 + torpedo 300 took a Scout 650 -> 230). Projectile
  speeds (InitialSpeed): 25mm 18500, small shell 15500, missile 17500, 75mm 10000, torpedo 3500 (CFG.TURRET_TYPES;
  reading the CDO's ProjectileMovement from the director returned a UObject, not the number). FireRate/ReloadTime/
  TotalAmmo come from the turret. Turrets swing +-60 deg yaw, 0..15 pitch.
- Rivals: CFG.HULLS (weighted: scouts/interceptors common, heavies less, capital ships rare), 25% chance per turret
  slot of a refit with another type. Turrets fitted one ship per armShips pass; removed with the ship.
  Verified: 11 crews in 11 different designs, 58 turret shots in the first fights, crews extracting with hull damage.
- Lua checks: scripts/luacheck.py (the old lupa `load(...)` check never failed: load returns nil + message).
- Trailer capture: the lag was 30 fps CPU-encoded capture. rec.sh now records 60 fps with the AMD encoder at native
  size: the game holds 90 fps while recording. Never call FindFirstOf in a per-frame camera target function (19 fps).

## Busier stations (2026-11-01)
- Solo raids felt empty inside: solo crews were 1 person, stations only took crews into free berths (Fortress has 1,
  Navy Outpost 4; full = crews flew elsewhere), and 8 defenders. Now: CREW_SIZE solo/raider 2-3, crew 3-4;
  DOCK_SECONDS 200-450; RUSHERS 0.4; MIN_DEFENDERS and main.lua GARRISON 14; with every berth taken a crew holds
  off the station BERTH_WAIT (10 s) and then "breaches in" (state docked, ship parked at its holding point, no berth;
  undock() copes with no berth). Verified (Spaceport, ~4 min in): 5 crews (14 rivals, 2 breached), 6 own + 8 copied
  defenders; 6 rivals and 12 defenders alive around you, fighting each other; 90 fps.

## Bot corpses: empty loot, frozen ragdolls (2026-11-06)
- Empty bodies: the death routines only copy bot.BotLootItems (+0xbf0) into the body's ItemsInContainer. Placed raiders
  get theirs from level-set rows (LootToSpawn etc: generator 0x17cae70; soldiers roll tables in 0x17caba0, both through
  the add-item helper 0x17ee360(bot, row FName, stack, condition)). A raider spawned at runtime has no rows, so every
  rival and top-up copy had n=0 and an empty corpse. The loot UI itself was fine (slots come from the item type; the
  0,0 grid position on body items is normal).
- Fix (rivals.lua takeKit): a BotPawnMilitary donor's BotLootItems is a full kit whose gun item's GUID matches its gun.
  Rivals already used a donor for the gun, top-up copies now do too (they no longer `summon` the template's gun class,
  so they carry CFG.DEFENDER_WEAPONS guns instead of the station's). Armour the body isn't shown wearing is dropped.
  Result: no empty bots on any team; 15 kills, every body held all its items through forced GCs.
- NEVER grow a TArray from Lua. UE4SS's __newindex grows only when index >= Max, by one element, and stores past the
  buffer: writes 1..4 into an empty array gave num 1,1,2,3 with write 3 at index 2 of a 2-slot allocation. The heap
  overflow crashed the game with unrelated stacks seconds later (physics task, null read in a worker). Writes below Num
  are safe. Existing `Inventory[n + 1] = gun` only survives on an empty array, or in slack without bumping Num.
- pve_take_loot(donor, body, keep) swaps the two array headers, then trims Num. It reads its integer arguments straight
  from the Lua stack (lua_State.top +0x10, .ci +0x20, slots 16 bytes, tag at +8), with tag and count checks, since
  UE4SS exports no Lua API. Tested with UE4SS as in tools/ue4ss; a mismatch does nothing and logs "loot not handed over".
- Frozen ragdolls: GOAPNodeBot_* (all raiders) die through 0x17ee0a0, not 0x17edf20. The "Enemy bodies" work above only
  covered soldiers. 0x17ee0a0 posed the corpse on the 1.0 s timer, mid-collapse, and set the 0.2 s lifespan. Raider Mesh
  is only a head/mask; the body component is +0xce0. pvepatch now queues that call too and skips its gear step and
  lifespan (patch_out: 19/19 plus the two body hooks).
- Settling: main.lua settleRagdolls samples 6 bones every 0.1 s; 0.4 s under 3 units per sample (not before 1.2 s, at
  most 7 s) writes SETTLED_MARK into the dead bot's AiMissRange (+0xcd0), which pve_bodies polls; it also poses by
  itself 7 s after the setup call. Bodies appear 2.2-7.1 s after the kill (typically 4-5), so looting waits for that.
- Probes: bridge/t_lootsurvey, t_lootwho, t_who2 (loot per bot), t_lootkill, t_killall (soak), t_bodyitems (BI_LOOT runs
  the real Server_StartLooting), t_rag (bone trace), t_donor, t_arr (TArray growth).
- Testing: echo on > bridge/god.txt before a run (or the player dies to vacuum/fire and the raid ends). Teleports with
  t_gostation can land outside; bridge/t_near.lua lands next to a raider, so inside its station. Stay out of the user's
  way: never run trailer/front.ps1 for a capture, use the console's `HighResShot 1`
  (%LOCALAPPDATA%/RaidGame/Saved/Screenshots/WindowsNoEditor), which needs no focus.

## Giant shapes in the space sky (2026-11-06)
- Cause: raid interiors are always-loaded sublevels at their real coordinates, each wrapped in a black shell of thin Cube
  meshes (M_FullyBlack, ~200 m), plus fog cubes and large light panels. Their small props cull with distance, these big
  cubes don't, so from open space they hung in the sky as flat black plates, only when you faced that way. Seen on
  Spaceport from (-30000,22800,8000) and (25000,30000,9000). The runtime NavMeshBoundsVolumes were NOT it (vis=false).
- Fix (main.lua levelShells/updateLevelShells): every Cube with scale >= 10 inside a LevelStreamingVolume's box is hidden
  unless the camera is inside that box (+1500). SetVisibility only, collision stays. 53 pieces in 7 locations, collected
  once when the map is ready (walks all ~95k static meshes, ~3 s, under the veil). Verified: plates gone in both photos;
  Spaceport 19/19 visible inside, 0/19 outside. Whether windows look right from inside was not checked by eye.
- Left alone: ForceField_Mat sheets (Plane, ~120 x 160 m scale, Z 2106 and -23002 around the Spaceport exterior at
  X -88000) and 108 spline_blocker panels: a translucent barrier, probably also the 2 pale squares seen from
  (-30000,22800,8000) (not proven: spline components all report the same origin). The black box at the map origin
  (~20 m, no volume) doesn't render at range. Node_SpacePortWhitebox_01 (-90000,0,-5700) is the real station exterior.
- Tools: bridge/t_cubes (big meshes), t_view (a CameraActor view, no player move), t_ray (which meshes project onto a
  screen rectangle), t_shellvis, t_vols. The sky differs per run: compare geometry, not colours.

## Space gate extraction (WORKING, 2026-11-06)
- Flow: at 300 s (gm.TimeTillEvacSpawn, RemainingTime 1200) the game mode spawns EscapeZoneSpaceGate_C (SpaceEvacToSpawn, a
  RaidPlanetEvac) at both EvacSpawnPoint_C; gs.EvacSpawned true, pc.ClientEvactriggered. All of that already ran offline.
  Calling it early: the stations' UA_SpaceGateTrigger01_C consoles call SIGISGenericActor::TriggerSpaceEvacReady
  (0x9a1720 -> game mode vtable +0x920); `t:TriggerSpaceEvacReady()` from Lua saves the 5 minute wait in tests.
- The gate's Blueprint, on overlap: cast to RaidCharacter, GetController, cast to RaidPlayerController,
  EnterEvacRaidVolume (impl 0x182c210). So only a character a player controls counts: an unpiloted ship does nothing.
- The bug: EnterEvacRaidVolume stops at `cmp Role,3 ; je return` (0x182c23e). Only a client went on to EvacRaid +
  Server_EnterEvacRaidVolume. pvepatch "Space gate extraction" NOPs it (20/20). The server half (0x183e160) is intact.
- Verified with an item in the pocket: pod into the gate -> Client_GetOutWithLoot -> "extracted with 1 item(s)", item
  written to the backend inventory. Piloted ship into the gate -> Client_GetOutWithLootAndShip, item and xp written, menu.
  (Two test bandages, pve-test-*, are in the stand-in's stash.) Gate entry was by teleport, with no jump cinematic
  checked, and whether the ship itself is kept was not checked.
- Pods: DropPodHatch_C (ARaidFrigateShuttleControl). Launching from the bridge is NOT the real path: hatch:OnUsed(pawn)
  leaves pc.DroppodLevelLauncher (+0xc58) null, and the pod starts near 0,0,0 or at garbage coordinates (seen 1.5e16, 6.6e34)
  and a second use in the same raid did nothing. SimulateInputKey F did nothing unfocused, ServerUse needs
  LastInteractionActor on the same frame. Launched by real F in play, pods reached the gate (the user did), so this
  looks like the shortcut's fault, but that isn't proven. On launch the on-foot pawn parks hidden at 0,0,0 with its gun.
- "Massive uzi on the pod" (user report): NOT reproduced. Ruled out: equipCarried (on foot only), pod weapon (none, no gun
  components, 5 skeletal comps only), held rifle (stays hidden on the parked pawn), summoned InGame_BowGun_50Cal actors
  (they stay at the player's spot, assigned to ships, and don't render there). Note the bow guns aren't moved to their
  ships at all. Test scripts: bridge/t_pod, t_podgate, t_pilot, t_shipgate, t_armme, t_gunwhere, t_evachooks(2), t_evacstate.

## AI tuning menu, aim variety, firing on the move (2026-11-06)
- F3 in a raid: tuning.lua, 121 settings in 10 tabs (Aim, Fighting, Cover, Senses, Rivals, Bosses, Guards, Soldiers,
  Personalities, Crews). Rows point at the live tables (main CFG, rivals CFG via R.CFG, ai.lua PROFILES/PERSONALITIES),
  read when bots decide, so changes apply at once. Defaults = the tables' starting values. Changed values only are saved in
  config/ai_tuning.txt (id=value; ids are "Tab:KEY" or "Tab:KEY.1" for one end of a range), loaded at mod start. Delete it
  to go back to defaults.
- Building UMG from Lua works. Host: Create() a DebugInfo_Widget_C (UserWidget itself is abstract; any Blueprint with a
  canvas root will do), root:ClearChildren(), StaticConstructObject(<UMG class>, host.WidgetTree), AddChildToCanvas /
  AddChild. Delegates can't be bound from Lua: the open menu polls Slider:GetValue and Button:IsPressed every frame.
  TextBlock:SetFont throws (a non-string error: pcall's message prints as "function: ..."); write t.Font.Size directly
  before the widget is built. `shot showui` captures UI, HighResShot doesn't. Panel height comes from the viewport.
  Tested through bridge/menu_toggle (empty = toggle; "tab N", "reset", "resetall", "set <id> <value>"), which
  stays in as a test hook, and Slider:SetValue. REAL MOUSE CLICKS AND THE F3 KEY HAVE NOT BEEN TRIED.
- AIMissRate measured properly (bridge/t_dmg2.lua + t_aimrun2.sh: every bot held at one value by `set`, all with a 5000
  health pool, total damage among bots per shot fired, 35-146 shots per value): 0.1 = 5.1 and 4.5, 0.45 = 5.7, 0.85 = 2.3,
  1.3 = 2.4, 2.5 = 2.7 and 1.3. The dial works below ~0.85 and is flat above it, so old soldier miss 0.85 sat at the
  flat end. Between 0.1 and 0.45 no change showed up in this data. Guns differ per bot, so it's a shape, not a precise curve.
- AI.aimFor (main.lua combatHints writes AIMissRate each 0.5 s update while fighting): profile miss x lifelong skill roll
  x streak x moving, target moving, just hit, range, and settle after gaining sight, capped at AIM_MISS_MAX 1.0. Bases
  lowered to rival .35, boss .4, guard .5, soldier .6 so modifiers stay in the live range. Bots are somewhat more accurate
  standing still than before and about the same moving. The native aim itself wasn't reversed: ShootEnemy (0x17eced0) only
  reads AIDifficulty; where AIMissRate is consumed wasn't found. Note the settled-ragdoll mark uses AiMissRange (+0xcd0),
  only on dead bots.
- Cover: every move to cover used to be a weapon-down sprint. Now COVER_SEEK_CHANCE / aggression decides whether to seek cover
  at all (COVER_HURT_CHANCE when just hit), else it fights in the open OPEN_FIGHT_SECONDS x holdGround; c.run rolled from
  SPRINT_EXPOSED_CHANCE / SPRINT_UNSEEN_CHANCE; not run = walks there with focus and enemy kept, so it fires on the way.
  aggression and holdGround existed but were unused until now. Top-up copies and rivals share all of this.
- Result, default settings, Navy Outpost, ~85 s, bots fighting each other too: 214 of 249 shots moving (86%); shots across miss
  bands 0.2-1.0 (old first tuning: 60 of 99 at the cap); 37 walk-and-fire vs 10 sprint cover moves; no errors.

## Difficulty presets (2026-11-06)
- tuning.lua PRESETS, a row of buttons in the F3 menu: Easy, Normal, Hard, Very Hard. They set competence only: every bot type's
  miss, reaction, spotTime, sight, hearing, dispersion (multipliers on the defaults) and part of the Aim tab (absolute values).
  Cover, sprint, strafing and personality settings are untouched at every level. Normal = the defaults exactly (a x1 row returns
  r.default; snapping to the slider step changed 11250 to 11300). Nothing extra is saved: the highlighted button comes from
  matching the current values, and a hand-tuned value shows as "Difficulty (custom)".
- Result (bridge/t_preset.sh + t_dmg2.lua, alternating in one live fight, Merchant, 17 s each, 99-184 shots a run, damage among
  bots per shot): Easy 3.05, 2.68, 1.79; Very Hard 5.23, 4.32, 3.20. Very Hard won every pair, ~1.7x. Hard wasn't measured
  on its own. This measures accuracy only, not reaction or senses, and not damage to the player.
- The menu_toggle commands other than `set` need the menu open: an early run of this test was silently at Normal. Check the logged
  miss values match the preset.

## Your own presets (2026-11-06)
- "My presets" tab in the F3 menu: name box, Save, then Load and Delete per preset (Delete asks for a second click). Saves EVERY
  setting, unlike the difficulty buttons. Stored in config/ai_presets.txt: "[name]" then id=value lines, only what differs
  from the defaults, so a new default in the code reaches anything a preset didn't change. Loading sets absent rows to the
  default. The same name updates that preset; a blank name becomes "My preset N"; [ ] and control characters are stripped.
  "(active)" comes from matching the current values, nothing extra is stored.
- Test commands (menu open): "save <name>", "load N", "delete N". Text box: EditableTextBox GetText():ToString() (checked).
  HorizontalBox:AddChildToHorizontalBox(w):SetPadding works; Button:SetIsEnabled greys it.
- Verified through those commands: save, auto-name, name cleaning, load restores tuning and difficulty, delete, survives a
  restart. NOT tried: actually typing in the box and clicking the buttons (including Delete's second click).

## Faster space raid loads (2026-11-06)
- Timeline of `open Space_Solo_01` (bridge/loadsample.ps1, t_loadstate.lua): real work (disk, CPU) done in ~20 s. WaitingToStart,
  then InProgress, then 45 game seconds with 0 MB read and no ship or pawn, then both appear at once: 65-66 s open to aboard, and
  the same on every run. Not the backend (silent in that gap), not a Blueprint delay (no float constant in the game mode or map),
  not a constant in any of the 284 SetTimer calls (0x348fba0), not gm:RestartPlayer (runs, does nothing early), not
  RaidWorldProcManager::TimedSpawning (0x18befa0, one shot). The timer itself was NOT found.
- Fix (main.lua veilUntilAboard): the wait is game-time, so SetGlobalTimeDilation(CFG.LOAD_TIME_DILATION = 10) for the whole black
  veil, back to 1 when pawn + ship + streaming are ready, and on giving up at VEIL_MAX. A new map starts at 1 anyway. Same
  simulated seconds, less real time. Rivals only start once the player exists, so they aren't ahead.
- Result: open to aboard 17-20 s (3 loads, "aboard after 8-9 s"), was ~66. Arrival vs. normal speed (2 loads each, bridge/t_arrive.lua):
  raiders 13, 13 vs 16, 13; item actors 1052, 1036 vs 1041, 1040; hull 575, hp 100, time dilation back to 1.00, no ship at bad
  coordinates. Raid clock on arrival ~1440 vs ~1448: up to 0.5 s of update lag x 10, so ~8 s more of the 1500 s gone.
  Played after a fast load: rivals launch/dock/attack, Fortress garrison, fights, gate extraction with item and xp saved. Not seen on
  screen by a person. A station's own defenders weren't checked after a fast load (the Fortress has none).
- Raid maps opened directly aren't touched: the veil only runs on space maps.
- Missing health at raid start (tester report, 2026-11-15): the pawn spawned while the load still ran at 20x, since
  veilUntilAboard only looks every UPDATE_SECONDS (10 game seconds at 20x). It arrived with Health 97 or 85 and
  totalTallyHealthBurn 3 or 15 (burned: the bar's white segments stay short), set between two frames with no
  ReceiveAnyDamage, so the landing in big physics steps. At LOAD_TIME_DILATION 1: Health 100, burn 0, but ~50 s slower.
  Fix: onTick (per frame) sets the speed back to 1 from CFG.SPAWN_SLOW_AT (40) match seconds, or as soon as a pawn
  exists. Two raids after the fix: 100 HP, burn 0, aboard after 13 s and 15 s.

## Raid loading screen (2026-11-06)
- Style from trailer/make_trailer.py: Bahnschrift, orange (255,138,36), tracked title with an orange ghost edge, rules, lower-left
  bar captions. Bahnschrift isn't in the game and Lua can't add a font, so all text is pre-rendered: trailer/make_loading.py ->
  assets/loading/ (backdrop, cap_world/match/ship/ready, travel). Runtime: KismetRenderingLibrary:ImportFileAsTexture2D(pc, path)
  + Image:SetBrushFromTexture. Re-run the script to change wording.
- loading.lua: full-screen UMG over the veil, shown from veilUntilAboard; stage and progress from what the load is really doing
  (main.lua loadProgress: streaming levels, match state, then the match clock over the 45 game second spawn wait). Fades out as
  the game fades in. Art scales to cover, so a window that isn't 16:9 crops it.
- The game's own travel screen is the AsyncLoadingScreen plugin, drawn on its own thread (Default__LoadingScreenSettings, picture
  /Game/LoadingScreens/Screen3 by soft path). Pointing Background.Images[1].AssetPathName at a runtime Transient texture works: paths
  resolve to objects in memory. Loading.arm (launchMatch only) does that, blanks LoadingText, moves the pistol away
  (TransformTranslation.X) and clears the Classic footer strip's tint; Loading.disarm restores all of it on the next world, so
  other travel (extraction, back to the menu) keeps the game's screen. Only via the lobby button: a bare `open` isn't armed.
- launchMatch waits 0.3 s before `open` so the screen draws. CRASH found by testing the real button: widgets shown in the menu die
  with that world and Loading.tick then read them on the new world's first frame (AV in UE4SS, every launch). Fix: Loading.reset right
  after `open`, and the screen stores its world's address; a tick from another world drops it untouched. Test launches through
  bridge/t_launch.lua (presses the lobby button), not `open`.
- A crash leaves the DLLs mapped briefly: launch-offline's copy can fail with "user-mapped section open"; wait and retry.

## Startup video re-cut (2026-11-06)
- The launch video is Content/Movies/LoadingScreen.mp4 (AsyncLoadingScreen StartupLoadingScreen, MoviePaths "LoadingScreen", skippable, 60.4 s).
  NOT IntroVideo01 (the menu's planet loop, played by Intro_MediaPlayer). Key art fades in 42.13-42.70 with the logo baked in.
- trailer/make_intro.py -> assets/intro/LoadingScreen.mp4: song starts at 17.13 s so its first big hit (25.27 s) lands on a hard cut at 42.4 s,
  with the trailer's flash and glitch; old logo buried by a gradient, trailer title + OFFLINE PvE on top. Same length, 1080p, H.264 Main.
  Measured: flash on 42.400, audio rise 42.40-42.45. Game reached the menu 61 s after launch, no crash. Audio by ear NOT checked.
- mode.ps1: offline copies our video in, online restores backup/LoadingScreen.mp4.original. The file contains the user's own copy of
  the song: this install only, don't share it.

## Startup video, second pass (2026-11-06, replaces the timing above)
- User wanted the song from the first frame, and the music was drowning the dialogue. The source's sound runs nearly unbroken 0-40 s and
  again 42-45 s, and the first cut faded it from 41 s (a mistake): now it's never touched; output minus source subtracts clean.
- No footage cut (17 s would lose dialogue). The song plays from t=0, its piano intro extended by one 16 s repeat: at 19.27 s it jumps
  back to 3.27 s (50 ms crossfade, 120 BPM, spectra ~0.90 alike; best of the beat-grid candidates). The band lands at 41.27, inside the
  source's near-silent gap, so the logo cut moved up to HIT 41.26 (the key art used to fade in at 42.13).
- Music level (only the song moves): -18 dB through the cinematic, -8 dB at the hit, -23 dB at 42-45 s, -11 dB over the studio logos.
  No scipy/whisper here: speech wasn't transcribed, only mapped by level and syllable-rate modulation.

## Startup video, third pass (2026-11-06, replaces the loop and levels above)
- Loop: phrase 9.64 s + 7.99 s, played 3 times (joins at 17.63 and 25.62 in the output), 350 ms equal-power crossfade, built sample-accurate
  in make_intro.py extended_song. The band lands at 41.25. Chosen by what the join does, not by waveform match: a high
  waveform correlation (6.98 / 7.993, 0.73) scored WORSE than the old join. Score: spectral change across the join against the piano's own
  (77th percentile, old 93rd), mean spectrum 1.5 s either side (54th, old 71st), level -0.2 dB. Blocks more than ~20 ms off the 2 s grid were
  rejected: they join smoothly but the rhythm stumbles. Scratch tools (search2/refine) not kept.
- Music: -18 dB under the cinematic, -3 dB for the whole logo (to 47.9 s, then down over 0.8 s), -11 dB over the studio logos. Source untouched.

## Startup video, fourth pass (2026-11-06, replaces the music levels above)
- The source audio is just mixed low: peaks -21.6 dB, flat ceiling throughout. SOURCE_GAIN_DB = 16 brings it to about -18 RMS, peaks -5.6 dB,
  no limiting. The logo stayed at MUSIC_LOGO -3 dB (song RMS about -17); MUSIC_UNDER_SPEECH rose with the source to 0.79 so the margin holds.
  Measured total: -19/-18 through the cinematic, -15 at the logo, -20 over the studio logos, output peak -2.6 dB, nothing above 0.94.
  Source over music: +11 dB median through the cinematic (min +6), -3 dB at 42.3-45 s, +2 dB over the studio logos.

## Splash screen logo and credit (2026-11-06)
- The screen after the intro is SIGIS_LoginWidget (live instance under "Main Menu", in the game instance). Logo: Border_Logo, brush is a sheen
  material, in SizeBox_9 (410x80), in VerticalBox_5 anchored bottom centre, so a taller box grows upward and the buttons stay put.
  Footer: TextBlock_59 under Border_288, which has no Blueprint variable; GetWidgetFromName errors from Lua, so it's found by object path.
- trailer/make_menu_logo.py -> assets/menu/logo.png (trailer title on transparency, cropped to the ink); splash.lua swaps the brush and text,
  from main.lua's update on the MainMenu world, retried each second until the widget exists. The game's own bytes aren't touched.
- trailer/grab.ps1 <file.png>: PrintWindow capture of the game window with UI, no focus needed. HighResShot and `shot showui` saved nothing here.
- Skipping the startup video (2026-11-15; config/skip_intro.txt, the launcher's "Skip the intro video", mode.ps1): the game
  plays LoadingScreen.mp4 (60.4 s) to the end before this screen, so launch -> splash was 69 s; a 1 s black clip
  (assets/loading/skip_intro.mp4) in its place makes it 16 s. `-NoLoadingScreen` on the command line changes nothing.
- CRASH that the long video hid: the splash is then up ~6 s before the game's backend login (the stand-in's
  POST /v2/account/authenticate/steam; afterwards SIGIS_ExampleGameInstance_C.NakamaPlayerID holds a 36-char id), and
  PLAY in that window (login widget MM_GenericSmallBtn01_1, event BndEvt__MM_GenericSmallBtn01_1_K2Node_
  ComponentBoundEvent_6_GenericSmallBtnPressed__DelegateSignature) dies with an access violation reading 0 in
  nakama-cpp.dll+0x7c2fc under exe+0x934799 (report in %LOCALAPPDATA%\RaidGame\Saved\Crashes). splash.lua gatePlay keeps
  PLAY Hidden (2, layout kept) until NakamaPlayerID is non-empty, checked from the director's tick 4x a second until the
  first login. Measured: PLAY visible at 12 s, hidden at 13 s, shown at 14 s with the login. A window under ~0.5 s remains
  between the widget appearing and the first check.

## Footsteps (2026-11-06)
- Silent for player and bots: every footstep event in rc_FPS_AnimBP / rc_AI_FPS_AnimBP (walk, sprint, jump, land, crouch) starts with
  `if IsServer: stop`, and offline is always the server. AnimNotifies fired fine (215 for bots, 9 for the player in one test).
- Fix: pvepatch `pve_bp_jump(UFunction, offset)` turns that JumpIfNot (0x07) into Jump (0x06), same size and target, checked against the
  surrounding bytes. main.lua FOOTSTEP_BRANCHES holds the offsets, applied once per world. Tools: tools/offline-audit/bpseq, bpwin, bpserver.
- Other IsServer sites in those ubergraphs (player 17357, 22810, 27791; bots 14316, 16650) are untouched. Player ones checked 2026-11-08:
  17357 montage check after a Delay, 22810 a RaidBot test (not a branch), 27791 landing camera shake. None is a sound.
- 2026-11-08 "footsteps only sometimes": the player's PlayFootstepSound has its OWN gate (offset 1288: `if not IsServer -> sound`, else only
  the footprint decals), so your walk/sprint/crouch steps were silent while bots' (their copy has no gate) and the jump/land foley
  (JumpStartFoleySound/LandFoleySound, ungated) played. Patched the same way (FOOTSTEP_BRANCHES); the sound path's pop returns to the
  decal branch, as on a client. Verified in Spaceport: Footstep_Concrete/Metal_walk01 cues attached to the player's mesh while walking
  (bridge/t_fsplayer.lua). Not checked by ear.
- tools/offline-audit/kdis.py <UFunction hex> [from] [to]: Kismet bytecode disassembler (live, read-only) with real names, jumps and
  execution-flow push/pop. Mostly complete for 4.26 tokens; stops with "!! token" on one it doesn't know.
- Verified: Footstep_* cues on live AudioComponents (concrete, metal, thin metal, rubber, dirt land, jump). Not checked by ear. AudioComponents
  pile up to ~900 between garbage collections and drop back about once a minute (8 bots, ~14 steps/s). Harmless, but it scales with bots.
- CRASHES from test scripts, not the patch: RegisterHook on GameplayStatics:SpawnSoundAttached (AV marshalling), and a:GetOwner() on
  AudioComponents from a tick hook (null read, pcall can't catch). Don't hook sound functions; sample FindAllOf from the bridge, not a tick.
- A crash leaves dwmapi.dll mapped and CrashReportClient running: kill it and wait a few seconds before launching.

## Rival boarding and morale (2026-11-06, rivals.lua)
- Rivals board each other: engage() rolls RIVAL_BOARD_ONE/ALL, real pods fly at the target (S.pods entries carry .ship). AI ships have no interior,
  so the fight is simulated (fightAboard: one kill per BOARD_ROUND, odds 0.5 + skill gap x BOARD_SKILL). Boarders who clear it keep the ship
  (captureShip: it keeps its name, the old ship is destroyed if nobody is left on it). Happens on its own: seen with no forcing, Slag vs Salt Witch etc.
- Diehards (DIEHARD 0.35): never flee, never "had enough", chase to SHIP_SIGHT x 4, ignore the raid clock while fighting. Others flee at a rolled
  10-25% hull (was a flat 30%); ENGAGE_MAX 80-160 s (was 50-110). Player boarding: BOARD_ONE 0.45, BOARD_ALL 0.15 (was 0.35, 0.08), BREACH_AFTER 20-55 s.
- Pods aim at the hull's side (podAim, POD_ALONG/POD_SIDE), not the closest point to the pod (which from behind was the engines), and vanish on impact
  (user: an embedded pod looked awkward; the rider still cuts through BREACH_DELAY later). Measured on the starter frigate: -164 to +156 ahead of centre, about 50 to the side. Not looked at on screen.
- Known gap: a parent ship that extracts mid-fight stops updating its party, so those boarders just stop; the victim carries on.
- Test triggers: bridge/rivals_clash (two crews, boarding), bridge/rivals_board (provoke + boarders). Provoked ships spawn 12000 +X of you and at the
  start spot park ~9000 out, likely on the nearby station; bridge/t_nudge.lua moves them into pod range. t_ships.lua lists distances.
- Player boarding a rival: NOT possible yet. Rival hulls have no MyShipInside, which breaching needs. The map has FrigInteriorSpawn slots and the
  game spawns interiors for AI frigates (AIFrigateInsideToSpawn), so the likely route is giving a rival's hull an interior. Stealing also needs
  pilot handover and what happens at extraction. Not attempted.

## Player boarding and stealing rival ships (2026-11-06, rivals.lua; first build)
- Spawning FrigateInside_Starter_C at a free RaidFrigateIntSpawn slot with World:SpawnActor brings its own streamed level AND spawns + pairs its own hull
  (plain AIController, hull.MyShipInside set). Space_Solo_01 has 12 slots; yours takes one. RaidUseableFrigateHelmComponent:Interact(pawn) on that interior
  possesses whatever SpaceshipToPairTo points at, a rival's hull included: pc.Pawn becomes it. OnUsed is a delegate, not callable.
- Flow: your pod (pawn.bADropPod) within PLAYER_BOARD_PREP of a flying rival -> makeInterior; next crew update pairInterior swaps the auto hull for the rival's
  and adds a nav volume (addInteriorNav); within PLAYER_BOARD_RANGE of its centre -> breachInto: Possess the on-foot pawn at the first breach point, destroy
  the pod. Inside (place "rival", S.aboard) the crew materializes as "boarding" bodies. Crew dead: state "derelict", ship stops. Helm: checkStolen sees
  pc.Pawn == c.ship and makes it S.playerShip / S.homeInside; the crew goes to "gone". Your old ship stays where it was. Max PLAYER_BOARD_MAX interiors a raid.
- Interiors by design: see "Rival interiors" below.
- Verified end to end (bridge/bd_test.sh, Lucky Strike): interior ready, breached, 2 armed bodies in the ship, helm, "you took". NOT verified: a pod launched by real F
  (the dock's Interact does nothing from the bridge; test pods are spawned beside the hull and possessed), a fight with those bodies, helm by real F (bridge
  calls Interact), extraction with a stolen ship, leftovers of the destroyed auto hull (its turrets), the SetControlRotation facing line (added after the last run).
- Crew still alive when you take the helm: they stay as bodies, but their kills no longer count (crew is "gone").
- FPS: 90 dropped to 5-15 about 40 s into a map, BEFORE any interior was spawned, and not tied to nav building (90 while building, 7 idle). Wow.exe was the foreground
  window and Roblox open, game window in the background, 4.9 GB RAM free. Likely that, not proven: measure with the game focused.

## Rival interiors (2026-11-06, rivals.lua CFG designs `inside`)
- /Game/Data/FrigData column 0x18 (tools/offline-audit/frigdata.py) gives each design its FrigateInside_* class. All 26 load and spawn, and each pairs its exact hull variant.
- LoadAsset on a cooked Blueprint needs "Path/Name.Name": the bare package path does nothing, silently (no "Asset loaded" line), and the class then appears as Name_C. loadClass uses that form.
  LoadClassAsset_Blocking with a soft path table crashed in Lua marshalling; don't use it. tools/offline-audit/fnames.py searches the whole FName pool, cooked asset names included.
- Real levels: Starter, Scout (all scout classes), Capital (all capital classes), Strike, plus Merchant and the _Ai ones. Every Interceptor, every Heavy and the VIP point at /Game/Maps/Main/ShipBlockOut:
  a grey roofless box open to space, seen on screen. So Interceptors use DefaultScout, Heavies use Capital, the Vulture uses Strike. LevelPath is what the level really is here (checked in StreamingLevels).
- Strike and VIP interiors have 0 BreachTransforms: entryPoints falls back to the ShipDock*PlayerStart components, solid floor at Z 2430 on Strike. Helm spots are NOT safe to stand at: on Fast and Strike the spot next to
  the helm has no floor and you fall into space. Whether the helm can be walked to on each interior by a real player is unchecked.
- Verified with full runs: Heavy Raider -> Capital interior, Strike Frigate -> Strike interior: breach, 3 armed bodies, helm, stolen. Scout family spawned and floor checked, not boarded. Fast_Frigate_01_Ai_Interior is a real level
  that only the map's own AI ship uses; it could serve Interceptors better if a way to stream it for a second ship turns up.
- Pods vanish on impact: 3 hits in the last session with riders aboard after, no crash. Not watched on screen.

## Keeping a stolen ship (2026-11-06)
- Works, by the game's own path: extracting at the gate while piloting a stolen hull goes through Client_GetOutWithLootAndShip, and the lobby (after the return to the menu) PUTs an inventory item:
  "47943293-StrikeFrigate_Ship-1-Vanquisher-0!0!0!0!0" equip true. The row is right for the hull stolen; the name is rolled by the game.
- The hangar lists it: MY SHIPS shows Vanquisher / Strike Frigate with the hull in the bay, its stats, and the green active bar with no click. Rustbucket is the "BACKUP SHIP". Slots 1/3. Reached with bridge/t_play.lua (splash Play) and
  t_tab2.lua (overlay Btn_TEMP_SubBtn_Hangar). PgosOverlay covers half the lobby after the 30 s sweep ends: t_tabs.lua hides it. InventoryMenuWidget.ActiveFrigate (+0x7B0) is null until the hangar page opens.
- A ship item with equip:true is in loadout.json, so it counts as gear: watch_checkout takes it out at raid start and only extraction writes it back (same id). Leaving a raid with `open MainMenu` or dying loses it. That is how the first test lost it;
  restored by hand (backend/state.before-ship-restore.json is the save without it). Round trip verified once: raid start took 47943293, gate, wrote 47943293 again, still in the save.
- The raid ignored it: Starter interior and hull both times, hangar opened or not, and the interior is named after the ship. Offline nothing reads the active ship when spawning you. It's independent of ActiveFrigate.

## Spawning your active ship (2026-11-06, replaces the in-raid swap idea)
- The travel URL takes ?SHIP=<FrigData row> (string at +0x409ad08, tools/offline-audit/strs.py). With it the game spawns that row's interior and hull itself. Without it, the Rustbucket. launchMatch reads the row from loadout.json and appends R.shipOption(row).
- Verified through the lobby button: Strike interior + hull, 1250 hull, cockpit deck, raid intro on screen, gate. bridge/rt3_test.sh <name> is the fresh launch path, rt4_test.sh the path from the lobby after a raid, sh_test.sh a bare open.
- Designs on the placeholder level have `stand`: launch on the stand-in row for its real interior, and R.ownHull replaces only the hull when loading finishes, from veilUntilAboard at raid.readyAt. Verified on a Heavy Raider: Capital interior, Ship_Frigate01 hull,
  950 hull, "hull is fitted" 1 s before "aboard". Bow gun fitted after. Turret and modules from the hangar are NOT applied to that hull.
- BUG found: on the FIRST raid after a game launch the interior has no name (ShipInfoItem not linked; on later raids it is) and extraction saves a made-up item: new id, new name, and the ?SHIP= row. A Heavy came back as FrigateCapitalShip_Ship "Helldiver".
  Why the first raid differs is unknown. Client_GetOutWithLootAndShip is what fires for a piloted ship; plain Client_GetOutWithLoot does not, so "extracted with" isn't logged and the mod's own menu return isn't used.
- Fix: stand-in remembers the ship at checkout (state ship_out) and settle_ship turns the next NEW ship item PUT into that exact item. Stolen ship: rivals.lua writes backend/ship_stolen.txt with the hull's row; the item keeps the game's id and name with that row.
  Death: hook Client_DiedCloseInv writes backend/ship_lost.txt, which clears ship_out.
- Verified in game: Heavy Raider from a fresh launch came back as 47943293 HeavyRaider_Ship Vanquisher, Capital interior, 950 hull (the game linked the item itself that time, so the first-raid bug is intermittent and was NOT reproduced). The bad item itself is covered by
  tools/test_settle_ship.py, using the real "Helldiver" write. Stolen Heavy Frigate saved as FrigateHeavy_Ship "The Leviathan" (ship_stolen path). Leviathan flown back in the next raid on the stand-in path, name shown. Death by ApplyDamage (Suicide isn't callable): back to the menu, ship gone, ship_out cleared.
- Leaving in a stolen ship loses the ship you came in: only the stolen one is saved. Several owned ships: which is active in loadout.json not checked. Hangar turrets and modules
  aren't applied to stand-in hulls. Nothing here was played by hand: helm, pods and gate were driven by scripts. Scratchpad tools setship.py, resetship.py need the stand-in stopped. Saves: backend/state.before-save-fix-test.json holds the pre-test save with the Vanquisher Strike.
- Quit then buy (fixed, verified in game by bridge/qb_test.sh): settle_ship now only acts when ship_out has gate=true. The mod hooks RaidPlayerController:Server_EnterEvacRaidVolume (no params) and LeaveEvacRaidVolume and writes backend/ship_gate.txt, 1 or 0.
  So a quit leaves ship_out unflagged and a ship bought afterwards is left alone. Client_GetOutWithLoot (on foot or by pod) now also clears ship_out: your ship stays behind.
  Verified: "ship in the gate: True" logged 1 s after the gate, Vanquisher back as 47943293. Then launch, `open MainMenu`, BuyShipFromShipShop(CorvetteScout_Ship): saved as 8989145 CorvetteScout_Ship "The Colossus", with ship_out still unflagged and untouched, cash written.
  The bought item's quantity field reads 0 where an extracted ship reads 1: that's the game's own write. LeaveEvacRaidVolume (gate=0) wasn't exercised.
- Test: bridge/qb_test.sh from a fresh launch (gate extraction, then launch, quit, BuyShipFromShipShop via t_buy.lua). Costs in-game cash and loses the ship on the quit: backend/state.before-quit-buy-test.json is the save to restore, stand-in stopped.

## Task minimap (2026-11-06, minimap.lua)
- Keys, all handled by UE4SS binds in main.lua: N shows or hides it (saved in config/minimap.txt), M switches small map / full overview, B follows the next task. `bridge/minimap_cmd` takes toggle, expand, next. REAL KEY PRESSES NOT TESTED: every check went through that file (the game window never had focus).
- Small map top left (the game's contract cards and gate timer fill the top right), heading-up. Overview centred, north-up (+X up), with every task listed. Widgets sit at viewport order -1, so inventory and Esc draw over them. pc.bShowMouseCursor is true during play here: useless for "a menu is open".
- Tasks: GetAllMissionsForRaid once, GetAllMissionsForChapters(gi.PrologueChapter.Chapter)[ChapterStage + 1], live progress in gi.ActiveMissions / PrologueChapter.Progress, then a "leave through a gate" task. pc:GetGameInstance() throws from Lua: use FindFirstOf("SIGIS_ExampleGameInstance_C"). GetCurrentChapterMission throws too.
- Places: contract actors (missions.lua, now with .level) and station airlocks grouped by level name. A level is present on this map if its first 5 letters match a Node_* class holding RaidDockingComponents (TAG_KEYS prison -> penal for RaidTag). Stations change per run: Node_PenalColony and Node_RebelBase sit at the same coordinates on different runs. Mini Mine and Merchant have no RaidUseableAirLockComponent.
- Stages (stage()): on foot in your ship -> helm or airlock; flying -> nearest dock of the station, with a bearing in words; in the right station -> navmesh route to the spot; wrong station -> back the way you came in (S.entry). Docked = home.CurrentDockingVolume (home.CurrentDockingVolume's owner names the node); ARaidFrigateStationDock.MyDockedShip stays null. The gate spawn time is RemainingTime - 1200.
- Routes: FindPathToLocationSynchronously, 1 ms for 18000 units. IsPartial is true for every contract object, because they stand off the navmesh: only count it if the route ends over 500 from the spot. ProjectPointToNavigation 8 us per call, and it only looks a short way up and down whatever extent you pass, so scanning from above the top floor finds nothing.
- Floor plans: flood fill over navmesh cells (100 units) from known spots, 2 ms per frame, 2-25 s per place, once. PNG only: ImportFileAsTexture2D returns nothing for BMP. Written by a small stored-deflate encoder in Lua, cached as assets/minimap/<level>.png + .txt (size). Your ship: ship_<interior class>.png, stored relative to the airlock. Floors merge, the highest wins, so a route can cross rooms on the map that are on another level ("up a level" in the text).
- Verified in game by bridge scripts (screens only): ship, flying, station, overview, gate markers, docked at the target, docked elsewhere, wrong station, hide and save, 90 FPS with the map open. Not verified: walking through a real airlock with the map (airlock Interact from Lua does nothing; stations were entered by teleport), AI frigate targets that fly around (place.hull), Destroy contracts (no marker unless a contract actor carries the tag), the first-raid overlap with the loading screen by eye.
- TESTING TRAP: a raid start takes the active ship out of the save (checkout) and only a gate puts it back. Closing the game mid-raid loses it. This test lost the Vanquisher; restored by putting that one inventory key back, stand-in stopped (backend/state.before-vanquisher-restore.json is the save without it). Back up backend/state.json before a raid test, and restore it after. bridge/mm_restart.sh, mm_launch.sh, mm_tour.sh do NOT do that for you.
- Land raids (the F9 test raid; 2026-11-15): locate() did `hull = valid(home) and home.SpaceshipToPairTo`, false with
  no ship, and valid(false) threw every frame ("minimap failed ... attempt to index a boolean value", ~24 lines/s in
  UE4SS.log; the minimap never drew there). Fixing only that line made survey() retry its 3 FindAllOf scans every 5 s
  all raid instead (land maps have no stations, so it finds 0 places; worst frame gap 87-94 ms vs 12-21 ms). M.tick now
  returns early off space maps.

## Stutter, lighting, bot aim, kit looks (2026-11-06, written; NOT yet run in game)
Measured live in a Navy Outpost raid, with WoW in front for all of it, so frame numbers are only rough: p50 11 ms, 100-400 ms hitches several times a second. The render thread was busy and the game thread mostly waiting.
- Minimap think() ran FindAllOf + FindFirstOf twice per think (gates, game state, game instance), every second and on every ROUTE_MOVED step. Now cached; gates only scan once the timer is out, every GATE_RESCAN s.
- The only world light is Node_Background_06's DirectionalLight: intensity 10, movable, DynamicShadowDistance 650000. Hiding it live visibly darkened the Navy Outpost and the held gun (mean brightness 39 -> 35). There is no world skylight (the one SkyLightComponent lives in /Engine/Transient). main.lua updateSun keeps it on only while not on foot. Effect on frame time not measured: all tests ran with WoW in front.
- tools/profile/threadsample.py samples the busiest threads from outside. bridge/profile_on makes the director write scan counts and slow ticks to bridge/profile.txt.
- Shot probe (bridge/t_shots.lua, 80 shots): bots shooting while not bIsTargeting keep the gun level (shotgun gun -3 deg, bullets +19). bIsTargeting bots track it within ~5 deg and play the arms' montage (rc_Mat49_Aim_Shoot_Mon); from the hip the arms play nothing while the gun runs Mon_*_Shoot on its own mesh. trackTargets now sets ServerSetTargeting while fighting (not sprinting or hiding). Forcing it live raised hand_r 41-55 from 43-50 above the capsule; no shots landed in that test window.
- GlobalAnimRateScale (0.6-2.4, for the legs) also scaled the arms' montage while the gun's ran at 1.0; animate now counters it with Montage_SetPlayRate.
- anim.Bend: non-zero (2.8-8.5) only on three top-up copies, which sit lower (head 46-53 vs 64). A Lua write doesn't stick (the BP rewrites it each update). Cause unknown; check whether these still point low once aiming is forced.
- bridge/t_kit.lua: placed raiders' looks match their loot. Mismatches were top-ups (template gear, donor loot) and takeKit missing Beret/Cap/Vest/Rig rows. wearKit now shows the donor's piece only for armour in its loot. Rival gear no longer uses the catalog pool, so it's less varied. Assumes donors wear their loot: check on the first run. Donors' ammo can mismatch the gun (M1Para or 1911 with 762Ammo; placed raiders carry 32Ammo): not fixed.

## Native bot kits, tested (2026-11-07, supersedes the donor notes above)
- Rival and top-up bodies have no donors now. pve_roll_kit writes a bot's WeaponToSpawn/PistolToSpawn/HelmetToSpawn/ArmourToSpawn/BackPackToSpawn handles (table at +0, FName at +8; UE4SS can't write these) and calls the game's kit step 0x17cae70. That makes the items, sets the worn meshes and spawns the gun a moment later (GUN_WAIT 6 s). pve_add_item calls 0x17ee690(bot, row, stack, condition, 0xc) for ammo and meds. takeKit, wearKit and pve_take_loot are gone.
- mods/PvEDirector/Scripts/gear.lua: rows of SIGIS_ExampleItemData by type and price, plus every head and body mesh (tools/offline-audit/gearrows.txt, itemrows.py, fnames.py). TIERS are price ranges over it. Defenders use the mid tier, on the station's own head and outfit.
- bridge/t_allgear.lua: 57 of 57 guns arrived and 57 test bodies wore every helmet, rig and bag row with matching loot. 40 heads and 42 bodies loaded. Live: 5 kills, every body held everything the bot carried (4-7 items).
- Frames with WoW still in front: p50 23 ms, max 52 ms, no 100+ ms hitches in 8 s (was 100-400 ms several times a second). In the Navy hall view: p50 56 ms, max 96 ms. Director after the first minute: no tick over 25 ms in the last 40 s of the test. Fitting rival ships still scans about every 5 s during the first ~60 s of a raid (~100 ms). Not measured with the game in front.
- Aim: 140 of 142 shots were bIsTargeting (was mostly off). Skeletal poses freeze off screen, so gun pitch of unseen bots is meaningless, and the first-round shotgun reading may have been that too. Only 2 rendered shots: gun +19, bullet +34. Guns may fall short of the aim on steep angles. Montage rate and bolt sync not checked by eye; fullbright not rechecked on a ship interior.
- UE4SS.log is read by mm_launch.sh before the new run rewrites it, so Play fires too soon and crashes in nakama-cpp: sleep ~25 s after launching first. Heredocs with apostrophes break the Bash tool here; write scripts with Write.
- Stand-in now copies state.json to backend/state.before-last-raid.json at each raid start (full stash, including items bought just before). The 2026-11-06 23:09 raid was closed, not crashed (no crash dump): Vanquisher, PPSh and SackBag restored exactly; 3 x 10mmAmmo 60 and 3 x BandageAid 3 inferred from the write pattern in server.log; 40540596 and 25379686 unknown, not restored.

## Female outfits, voices, off-limits zone (2026-11-07)
- Pak key: not in Denuvo code. FAES tables are referenced by plain engine code (decrypt block 0x19fcb80, setup 0x19fdde0/0x19fe020), found as image-relative disp32, not rip-relative (tools/profile/rvaref.py). tools/profile/keysample.py read the schedule from a thread inside the routine during a raid load, read-only. backup/keys/pak.key, tools/offline-audit/data/paklist.txt (60657 files). Keep the key local.
- No female assets exist. tools/female/make_female.py copies cooked meshes out and moves every LOD's bind-pose vertices in place (FPositionVertexBuffer: 12, n, 12, n, floats). A-pose, front = +Y. Same topology, weights, UVs, materials. Normals aren't recomputed. Copies live in Meshes/BodieF, HeadF, AccessorieF (same name length, so the name table can be swapped in place). assets/female/list.txt: 41 Bodies + 1 Steam + 40 Heads + 24 vests/rigs = 106. WIDTH/DEPTH/THIGH/BUST_*/SEAT_* are the proportions, last tuned by the user.
- Our pak doesn't load (signature). Instead pve_loose_assets empties FPakPlatformFile.ExcludedNonPakExtensions (TSet at +0x60, Data.Num +0x68) and scripts/mode.ps1 copies the meshes as loose files; online removes them. UE4SS LoadAsset only sees the asset registry, so pve_load calls LoadAsset_Blocking 0x3172480 with a TSoftObjectPtr.
- GC: Lua tables are no GC roots. A preloaded cue was freed and SpawnSoundAtLocation crashed (call [null vtable+0x280] at 0x2efb9de). pve_root sets RootSet on FUObjectItem (chunks 0x58e7538, flags +8). Root anything loaded for later.
- rivals.lua: m.female (CFG.FEMALE 0.5) picks the HeadF/BodieF look; wearVest swaps the worn vest; top-up defenders roll it too. Placed bots stay as they are. Voices: voice.lua + voicelines.lua, 13 sets, one for life, lines from the menu one per frame. Top-ups have voices; placed bots don't.
- Verified: 106 assets built, load, skin and animate; 9 of 19 bots women; 208 lines loaded; female and male lines heard by AudioComponent sampling, not by ear; 4 kills with full corpses. Not looked at closely in good light; shading on reshaped areas keeps the old normals. Native hurt sounds still male if the game plays any on bots: unchecked. Corpses use body mesh from the pawn; not visually checked.
- Off limits: Spaceport basement around AINodeStart_2 (68268,23030,-186), walkable on the navmesh 107 m from an airlock, beside hidden stash and locked door contracts. main.lua OFF_LIMITS, checked in patrol, reachableNear, strafe, rival spawns, and adoption. 18 live bots, 10 samples, none inside. Only this zone is known; other stations may have similar ones. Space_Solo_02 often surveys no stations and rivals then extract at once: not new, not fixed.
- Issue #13 (2026-11-15): five Space_Solo_02 runs, none surveyed "none" (2, 1, 2, 3, 3 stations). The interiors are the
  same every run (Mini Mine, Penal Colony, Rebel Base loaded; Asteroid and Moon Base volumes empty); what changes per run
  is which space-side docking nodes exist (one run: only Node_PenalColony_01 + Node_MiniMine; another: Node_CapitalShip_01 +
  Node_PenalColony_01, with Asteroid/Mini Mine/Rebel Base interiors named but no nodes for them). So "none" needs a run
  whose nodes all lack a named interior and no AI frigate, or a survey that throws (pcall -> "station survey failed").
  Never seen in today's ~10 logs. survey now also logs "[rivals] survey: named interiors: ... | docking nodes: <class> ->
  <name or no name>", so the next "none" shows which side was missing.

## Play areas replace the one-box ban (2026-11-07, later)
- The sample shots were at Z~980: the roof. The runtime navmesh covers roofs and shells on every station and the map marks nothing as out of bounds. bridge/t_nav.lua maps the navmesh against designer markers: everything at z 850+ has none.
- main.lua offLimits: on the four stations (and MiniMine), a point needs loot, a contract object, an AI node or an airlock within 1800 units and 260 up or down. Ships are exempt. The sealed basement stays ruled out by hand (SEALED), since it has its own AI node. Built once per raid (mapPlayAreas).
- Rival arrival points (st.entries) included roof spots: filtered after survey, plus guards in stationSpawnSpots and spawnGarrison.
- Verified on Spaceport only: 381 positions, z max 707, 6 outside (single readings at z 500-600). Navy, Merchant and Fortress use the same rule but weren't sampled. Legit floors with no marker nearby are avoided by bots too.
- Proportions: bust 9.5, waist width 0.85, depth 0.83.

## Women's versions of every outfit, player toggle (2026-11-07, later)
- assets/female/list.txt, 112 meshes (113 with the rebuilt Steam body counted by load test): all bodies, heads, vests, rigs and bags, plus the soldiers' one-piece Commando_Skel_01 and Security_Skel_01 (Meshes/ -> MesheF/). tools/female/classify.py lists every skeletal mesh; all 147 share RaiderChar01_Skeleton. Helmets aren't reshaped. Crewman and Traders are NPC models on other skeletons: not covered. Dev_Pirate body and head left out: the body's copy crashed the game on load (not investigated; unused in play).
- Bug fixed: renaming replaced the folder everywhere in the package, breaking Accessories/Mats and physics imports. Now only the package's own name is swapped.
- female.lua: version(mesh, on), dress(actor, on). All bot types go through it (rivals, top-ups, adopted placed bots, spawnBot soldiers) at CFG.FEMALE. Voice follows. F2 / bridge/female_toggle toggles your body, saved in config/female_player.txt; re-applied each update, because changing gear restores native meshes. Lobby re-dresses all MM_PlayerChar_C every 3 s (4 of them exist).
- bridge/t_loadall2.lua loads all with a crash trail, t_me, t_lobby, t_vestmat check the rest. Verified: player swap both ways, vest materials, 13 of 20 bots, corpses. Not verified: soldier outfits on a raid map (loaded only), how your own body looks in first person.

- Final proportions: shoulders width 0.82 at z 150 (0.91 at 135, 0.92 at 158). Locked in by the user 2026-11-07.

## Launcher and saves (2026-11-07)
- launcher/launcher.pyw (tkinter, trailer style) + launcher/saves.py. Marauders Offline.lnk here and on the desktop. backend/saves/<id>/{state.json, meta.json, before-last-raid.json}. Play copies a save to backend/state.json (stand-in and scripts still use that path), backend/active_save.txt names it, and closing the game copies it back, stops the stand-in and goes to stock (backend/last_game.log keeps the UE4SS log). Started by launcher: cleanup waits until the game has been seen, or it kills the backend during boot (first version did: "connecting to backend" crash).
- New save: capture seed with stats, XP, factions, skills, cosmetics and stash reset, keeps Body01/Head01/voice gifts, adds a P08, ammo, bandages, 10,000 cash. Seed's contracts stay as they were. Cheat: state["cheat"], stand-in forces cash to 999999999 on every write; stash from assets/saves/items.json (tools/offline-audit/itemsizes.py; row+0x14 is u8 col,row).
- Double stash: config/stash_rows.txt (written on activate, per save). pve_stash_rows sets the InventoryContainerSizes TMap (32-byte elements at comp+0x128, size at +0x10); the grid widget has its own InventoryGridSize and builds at menu start, so main.lua rebuilds it (ClearChildren, InventorySlots:Empty, InitializeGrid) before items land. 59 items, 28 below row 15, all placed.
- Voice lines must not load during map travel: crash at bad RIP through UE4SS hook, in raid load. They now load only in the menu, 3 a frame, not while a match is pending. Lines not loaded are skipped.
- bridge/menu.sh waits for the splash before Play (fixed sleeps crash in nakama-cpp). rt.sh/zone_test.sh use backend/state.before-voice-model-work.json.
- Waist: width 0.885 at z108, 0.905 at z120, depth 0.86/0.9. Not looked at in game.

- Arms (2026-11-07): ANSUR II medians (ergoassessment.cam ANSUR II explorer), taken at equal height: biceps/forearm 0.92, wrist 0.95, neck 0.90, calf 1.03. make_female slims each arm around its bind-pose centreline (ARM_Z/ARM_Y), 0.88 at the shoulder to 0.97 at the hand; neck 0.9-0.96; calf 1.03. Checked on the lit lobby character, male vs female.
- Bust 8.3, waist width 0.91/0.925, depth 0.885/0.915 (user, 2026-11-07).
- PLAY preflight (2026-11-15): launch-offline.ps1's output used to be thrown away, so a wrong config/game_path.txt, a
  missing tools/ue4ss or Steam not running all showed as "The game didn't start" after START_TIMEOUT (90 s). launcher.pyw
  preflight() checks the game exe, tools/ue4ss (dwmapi.dll, UE4SS.dll, Mods) and steam.exe first; if the script still
  fails, the status line shows its first error line and the launcher tidies up at once.

## Space_Solo_02 stations, Rebel Base lid, key card guard (2026-11-07, later)
- User report: big black cube in the sky at Rebel Base, rivals leaving/gone right at the start, poor loot at Rebel Base, locked out of own ship (captain's ID gone).
- Stations: Space_Solo_02's interiors (Rebel Base, Penal Colony, Mini Mine, Asteroid, Moon Base, Capital Ship) have no Navy/Spaceport airlock names and no anchors, so rivals.lua survey named none: "stations: none", every crew "nowhere to go" and extracted at once; with no station no garrison either, so the only enemies were the base's own native NPCs (native loot). Fix: unnamed nav volumes are named after the LevelStreamingVolume around them (CFG.VOLUME_NAMES) and matched to Node_* RaidDockingComponents by key5 (rebel, penal, minim, capit). Two nav volumes in one streaming volume: the bigger wins. No airlock (Mini Mine): entries are RaidAINodeStart spots. Verified: "Penal Colony (5 entries, 4 berths), Mini Mine (7, 1)" and on another run "Rebel Base (6 entries, 4 berths)"; crews head for them. Fights and loot there not watched.
- Docking on Solo_02: the space-side Node_RebelBase_01 / Node_PenalColony_01 sit near (-85000,0) with RaidDockingComponents; the interior's airlocks are StationAirlockDockingAreaAbility<Name>_N actors (RaidFrigateStationDock, in the persistent level) at the real interior. A docked ship shows in that dock's DockedShips (MyDockedShip stays null).
- Lid: Cube_4549 (Rebel_Base_01, scale 354x490x312, centre z 26140) sits above LevelStreamingVolume_RebelBase, so the shell pass skipped it. levelShells now falls back to matching a cube on the volume's floor plan (x, y). 24 pieces; lid hidden from the ship, verified by IsVisible only.
- Key card: row KEYCARD in container "KeyCard" (MotherItemGUID), Attachments "<captain>!<ship name>!<RaidSpaceshipInside.KeyCardUUID>!<type>". Docking and both airlock transfers keep it (tested at Rebel Base and Penal Colony by bridge: t_helmown, t_flydock, t_airuse, t_usecomp, t_stationuse). Station side: OpenBtn checks the card (dock PendingShipTransfer = your ship, door opens), InsideAirlockBtn transfers. What removed the user's card is NOT known (log shows nothing). main.lua guardKeyCard (every 2 s on space maps) remembers the card and re-adds it with Server_AddItem(KEYCARD, 1, cond, "KeyCard", 0,0, false, guid, 0, att, 0) when it's gone and the slot is empty; verified: removed by Server_RemoveItem, back 1 s later, and a re-added card opened the station side and transferred back. HangerEvent refusals (>= 3) are logged; the hook never fired in tests.
- Test crash: bridge-driven FrigateDockingToStation called again while docked, then OpenBtn twice: access violation in Blueprint code ~20 s later. Not seen in the clean sequence. Native Rebel Base guards still carry the game's own loot (adoption keeps it).
- Tools: bridge/t_rebel.lua (docks, volumes, cubes outside volumes), t_keycard*.lua, t_cardcon.lua, t_cardrestore.lua (+ _G.CARD_STEP="add"), t_cardadd.lua, t_dockstate.lua, t_hangerlog.lua. backend/state.before-rebel-test.json = save before these tests.

## Station guards: own gear kept, bags and pockets rolled (2026-11-07, later)
- User: "keep their basic equipment, but roll what's in their bags and pockets". Placed guards (GOAPNodeBot_Raider/Boss) carry their level rows: worn items in their slot's container (MotherItemGUID Head, Prim, Pistol, Rig, Bag...), plus one LootToSpawn row in the bag (its id) or LootPocketLeft, usually one ammo stack and maybe a bandage.
- pvepatch pve_keep_worn(bot): compacts BotLootItems (+0xbf0) in place to the worn containers and lowers Num (never grows). Dropped item actors are left alone. bridge/keep_worn.txt, if present, gets "kept of total" lines.
- rivals.lua rollCarried (adopt and finishTopUp): reads the five *ToSpawn rows, keeps them, then pve_add_item adds ammo for each gun (1-3 stacks of 20-60 for the main one), 0-2 meds and CARRY_BAG 2-5 picks from gear.lua loot (type 3), boxes (type 20, 6%) and parts (type 15, 12%), weighted 1/sqrt(price), capped at max(1500, 1.5 x worn value), uncapped 5% of the time. No bag = one pocket slot (the game turns away the rest): one roll (50% ammo, 20% med, else loot/part), re-rolled up to 4 times until it lands.
- Verified (Mini Mine, Penal Colony): every guard and copy logs "carrying ..."; a killed guard's body held exactly its worn gear plus the rolled list (9 items). Guards whose gun isn't in gear.lua get no ammo (rare). The bag's grid can turn away the last picks; the log lists what was attempted.
- Once, on the first Penal Colony visit, 7 top-ups found no defender spot (0 points); not seen again in the next run. The message now also counts points rejected as off limits (play-area rule, which now covers RebelBase, PenalColony, Asteriod, MoonBase).

## Debug menu (F9) and spawn counts in the AI menu (2026-11-07, later)
- debugmenu.lua: the old test keys are buttons now, F9 opens/closes (F3 AI menu; opening one closes the other). Removed keys: F4 crew attacks, F5 extract, F6 give gun, F7 test raid, F8 spawn soldier, F9 god mode. Kept: F2 body, F3, N/M/B. Buttons: god mode (label shows state; bridge/god.txt as before), extract now, open the space gates (UA_SpaceGateTrigger01_C:TriggerSpaceEvacReady), nearest crew attacks, spawn a soldier, give a soldier's gun, test raid on CFG.MAP. Each has when() and is greyed where it can't run. bridge/debug_cmd: an action id runs it, empty toggles the menu.
- tuning.lua Spawns tab (simplified at the user's request): rival crews (rivals.lua CFG.CREWS, 0 = one per free player slot, 11 on solo maps), crew size min/max (CFG.CREW_SIZE is now one range for every map: offline matchmaking always sends an empty configuration, so only Space_Solo maps are ever loaded; crew maps Space_Alpha..Delta and raider maps Space_Raider_01/02 never), stations per crew min/max, guards per station (MIN_DEFENDERS; a station with no guards of its own also gets this many soldiers, rivals passes the count to spawnGarrison, so main.lua GARRISON is only a fallback and has no slider). BOTS (land raids, debug test raid only) has no slider either. Ranges drawn with rivals.lua between(), which copes with min > max.
- Verified by bridge: both menus render (screens), god on/off, soldier spawned, gates, extract; CREWS 4 -> next raid "4 rival crews". Real clicks and keys not tested (the window never had focus).
- Crash once (12:03), ~10 s into a Space_Solo raid with no menu open, while rival hulls loaded: access violation through a UE4SS hook (UE4SS +0x555002 -> game +0x1c3574e -> junk). The next run passed that point. Cause unknown; watch for it.

## Map variety (2026-11-07, later)
- Offline matchmaking always got an empty configuration, so only Space_Solo_01/02. main.lua CFG.MAP_POOL now holds both solo and all four crew maps (Space_Alpha, Beta, Charlie, Delta); bridge/map_pin (a map name) forces one for tests. bridge/maps_test.sh loads each map in $MAPS and writes bridge/maps_test.txt.
- Tested (bridge only): every crew map gets you aboard in 10-12 s with the key card, stations found, 11 crews, launches heading for stations. Seen: Alpha Rebel Base + Spaceport; Beta Asteroid Mine, Penal Colony, Capital Ship; Charlie Mini Mine, Colony Cruiser (some runs); Delta FastFrigate, Navy Outpost, Merchant. Charlie also has Planet Killer airlocks but no docking node in the runs seen.
- Charlie has two identical nav volumes in the Mini Mine: the duplicate check now keeps the first of equal ones. VOLUME_NAMES colon / plane, play-area STATIONS ColonyCruiser / PlanetKiller.
- Space_Raider_01/02 (the game's raider mode) shut the game down shortly after "match found" (no crash report): left out of the pool, not investigated.
- Crew sizes use one range for every map (Spawns tab); live crew maps had crews of 3-4.

## Seamless female body (2026-11-07, later)
- User: the body visibly switched to female after each menu click (the lobby pass ran every 3 s after the game's own re-dress). female.lua now post-hooks /Script/Engine.SkinnedMeshComponent:SetSkeletalMesh (native hook): when the owner is MM_PlayerChar_C or PlayerPawn_C, the mesh is replaced by M.version(mesh, playerOn()) inside the same call (re-entry guarded), and R_* fields are kept in step. Applies both ways: with the setting off it enforces the male version. The timed passes stay as a fallback.
- Verified (bridge t_lobbydress.lua, t_pawndress.lua): the lobby character's "PGOS RefreshCrewApperance" and a direct SetSkeletalMesh(male) both leave BodieF on; in a raid head, body, vest and bag stay female after setting the male meshes. Not watched by eye while clicking menus.

## Flying stutter and the minimap in new-map stations (2026-11-07, later)
- Measured on Space_Beta with bridge/profile_on (profile.txt now also counts gaps between frames, the whole game's hitches): every FindAllOf costs 40-50 ms on these maps. While flying, rivals.lua ran FindAllOf(InGame_BowGun_50Cal_C) to find guns it had summoned (about every second while crews launched) and FindAllOf(RaidCharacterTurrent) per ship fitted: pairs of them = the 100-159 ms freezes. Fixed: bow guns spawned with SpawnActor (CFG.GUN_PATH, GUNS_PER_STEP 2) and handed over directly; a hull's own turrets read from ARaidFrigate.SpawnedTurretArray. The PgosOverlay sweep now stops once the loading veil lifts on space maps. The key card guard keeps its inventory component (raid.cardInv). After: director never over 10 ms after boarding, no scans during the flight; frame gaps 0 at rest. Flying was tested by teleport steps (bridge/t_step.lua), which add their own ~50 ms gaps.
- The SetSkeletalMesh hook (seamless body) ran 0-3 times per 10 s: not a cost.
- Minimap: StationAirlockDockingAreaAbility<Station> airlocks are in the space map's own level, so survey() made a place of the space map itself ("Space Beta", and "Space_Solo_01" earlier) holding every station's airlocks: once through you were "in" it, so the guide said back to your ship and drew its (empty) floor plan. Those airlocks now join the place named in them (key5 + TAG_KEYS), else the nearest within LOOSE_AIRLOCK. Old plans moved to backup/minimap-old to rebuild. Distance text falls back to the straight line when the route has length 0 (airlock chambers are off the navmesh). Verified: in Asteroid Mine Large the guide gave the task's own step, map and overview drawn.
- TEST HAZARD: RegisterHook from a bridge command mid-raid crashed the game in UE4SS's hook dispatch (13:15), and GetAttachedActors with a Lua table out-param crashed it (13:09). Don't do either.

## Rivals arrive through airlocks (2026-11-07, later)
- Every station with RaidFrigateStationDock airlocks (StationAirlockDockingAreaAbility_*: Navy Outpost, Spaceport, Asteroid Mine, Penal Colony, Rebel Base, Moon Base, Colony Cruiser, Planet Killer) gets st.locks in survey(): chamber floor (InSideComp box), station-side button (OpenButton). Fortress, Merchant, Mini Mine have none: old arrival (pop in at an entry point).
- A docking crew takes c.lock = pickLock: berth i -> airlock i (sorted by name), skipping one your ship is docked at (DockedShips) or another docked crew holds. Docking while you're inside (FRESH_DOCK 25 s): bodies are built in that chamber (door closed, out of sight), crewArrival holds them (no rehome/patrol) for ARRIVAL_MIN 6 s and until armed (ARRIVAL_WAIT 12 s cap), then StartDoorEvent(true): the game's own hatch sequence (wheel, steam, opens in ~8 s; the passage unblocks at once, so they wait DOOR_OPENING 7 s), then walk to lockExit (past the button) and search as before. The door closes (StartDoorEvent(false)) ARRIVAL_CLOSE 10 s after, once nobody stands in the chamber. Leaving: they walk back to the same airlock.
- Verified: Asteroid Mine (2 of 2 and 3 of 3 in the chamber), Penal Colony (1 of 1), Navy Outpost on Space_Solo_01 (2 of 2); frames show DOCK-3C open and a rival stepping out. Open/close checked by eye from inside a chamber. bIsOpen stays false through StartDoorEvent; DoorMesh / bone reads don't show the animation (and GetBoneName/GetSocketLocation from Lua crashed the game once).
- Not done: a cue before the door (the hatch sequence itself is the warning: ~6 s cycle + 7 s opening); linking the ship's real dock to the airlock (the berth -> airlock map is a fixed assignment, not what the game would pick).
- Tools: bridge/t_lockprobe.lua (doors, chambers, paths; LOCK_OPEN/CLOSE), t_inchamber.lua, t_watchlock.lua, t_arrivals.lua. backend/state.before-airlock-test.json.

## Pods, parked ships, the Mini Mine berth (2026-11-07, evening)
- Black void after a pod breach (user): the pod hit a rival ship parked at the Mini Mine (state "docked"). playerBoarding only made interiors for flying crews, so the hull had no MyShipInside and the game left your on-foot body where it parks during a pod flight, at 0,0,0. Docked ships are boardable now. rescueFromVoid: on foot within VOID_NEAR (3000) of 0,0,0 for VOID_RESCUE (3 s) -> moved to your own ship's first entry point, with a message. (The user's stuck game was rescued by bridge/t_rescue.lua.)
- Guard on parked ships (user: no easy cheese): a docking crew gets c.watch = SHIP_WATCH 1-2 extra members (setWatch, newMember, crew team, rolled like the crew, kept for the raid). Boarding a docked ship materializes the living watch at breach spots other than yours (mode "boarding", alert). The docked branch no longer dematerializes boarding bodies (it did every update: the watch was rebuilt over and over). Verified: Stray Dog, 2 of the watch aboard, 26 and 30 m from you, team 20, armed; logged once.
- Grease Gun on the pod (user: the gun they carried): while pc.Pawn.bADropPod, main.lua hides the on-foot body's Inventory guns (SetActorHiddenInGame) and shows them again on foot. Verified hidden=true in the pod, false after.
- Ship flying into the Mini Mine rock: (1) its one berth was the 0.8 m RaidDocking00 marker 7 m under the real RaidDocking01 dock (dedupe kept the first): now the biggest volume of overlapping ones, and BreachVolume components are not berths (the biggest-volume rule had picked the Colony Cruiser's). (2) Crews waiting for a full station held at approach + c.id x 900 in X, + 1500 Z: now HOLD_OUT 2500 + spacing straight out along the approach lane. Verified: docked ship 5 m over RaidDocking01 at rest; three waiting ships 115-180 m out, drifting in open space. Each berth is logged at survey. The Mini Mine's position differs per run.
- Tools: bridge/t_podto.lua (POD_PHASE spawn/step/guns, POD_NEAR, POD_OFF), t_whereami.lua, t_bowguns.lua, t_shipsnear.lua, t_rescue.lua. Interiors cap PLAYER_BOARD_MAX 4 per raid; a pod's route can board another ship first (that's correct).

## Typed stash size, ambient ship fights (2026-11-07, evening)
- Stash: the old "Double stash size" switch only wrote meta.double_stash; activate() wrote config/stash_rows.txt (30) and the mod resized the Stash container in the menu; switching off was refused with items in rows 16-30. Now the new-save dialog takes a row count (saves.STASH_MIN 10 .. STASH_MAX 100, width stays the game's 10), stored as meta.stash_rows and fixed for the save's life (no switch; set_double_stash removed). saves.stash_rows(meta) reads old saves (double_stash -> 30, else 15). The details panel shows "Stash N items, 10 x R". Verified: dialog and panel captured (test_launcher.py); a 100-row save logged "stash grid: 100 rows" in the lobby. The 100-row grid wasn't looked at on screen.
- Ambient fights (rivals.lua SKIRMISH_*): while you fly your ship, every SKIRMISH_EVERY 70-150 s (first after 20-45 s, max 6 per raid, one at a time) two extra crews (newCrew, ambient, diehard, no boarding) spawn SKIRMISH_AHEAD 140-260 m ahead (any way if you're still), clear of stations, berths and ships, and engage each other. Hull x SKIRMISH_HULL 1.5 (guns only take ~6-7 hull/s each: x3 ran past 5 minutes; x1 with boarding ended in ~20 s). The winner extracts ("won their fight"). They ignore you unless provoked: hit while you fired in the last PROVOKE_SECONDS 4 (OnClientFiredTurret, RaidWeapon ServerStartFire/BurstStartFireEvent on your ship's gun), within 1.5 x GUN_RANGE, and nearest your aim line within PROVOKE_CONE 20 deg (with only a cone both dogfighters turned on you). Spawns tab: per raid and seconds apart.
- Verified: fights spawned 166-254 m away; one ran to "went down" + "won their fight" without touching you; faked fire (bridge/rivals_fired) + 80 hull off one ship with your view on it: only that one "engages your ship (provoked)". NOT verified: the real firing hooks (needs real input), the final x1.5 duration, how a fight looks on screen (the follow camera never framed one). bridge/rivals_skirmish starts one now; t_hitnear.lua, t_faceskirm.lua, t_shipsnear.lua (hull).
- One launch crashed in UE4SS's startup scan (0xe06d7363), before any mod ran; the retry was fine.
- Launcher freeze (user: New save did nothing, then nothing could be clicked or closed): the borderless Dialog (overrideredirect + transient) opened UNDER the main window (wm stackorder: dialog, then "."), and its grab_set blocked every click while it was out of sight. Dialog.show now sets -topmost, lifts, then positions (positioning before -topmost put it at 0,0), and Escape always closes it. Applies to every launcher dialog (new save, rename, confirmations). Verified with a real screen capture (PIL ImageGrab): dialog on top, centred; Escape releases the grab; 5 rows refused with the message; 42 rows creates the save. test_launcher.py's PrintWindow capture can't catch this kind of bug: it draws hidden windows too. The two stuck launcher processes were killed.

## Co-op multiplayer: first look (2026-11-07, evening)
- Net setup (pak Config/DefaultEngine.ini): GameNetDriver = OnlineSubsystemUtils.IpNetDriver (plain UDP), bUseSteamNetworking=false, RaidReplicationGraph, NetServerMaxTickRate 60, timeouts 160/80 s, GameSession MaxPlayers 51. GlobalDefaultServerGameMode SpaceGameMode_C, ServerDefaultMap Space_Raider_02. So a join is "open <ip>:7777", no Steam/EOS relay.
- Listen server works: from the lobby, `open /Game/Maps/Space_Solo_01?listen?PID=...` loads the raid as usual (aboard, stations, rivals) and the process listens on UDP 0.0.0.0:7777.
- A SECOND COPY OF THE GAME ON THE SAME PC QUITS (exit code 0, ~10-15 s after start) when one is already running.
  CAUSE FOUND (2026-11-07, native/pvetrace.dll = IAT tracer injected by native/tracelaunch.exe): NOT Denuvo and NOT
  an OS mutex. The UE4 `"UnrealEngine4"` single-instance mutex does return ALREADY_EXISTS early in init, but the game
  keeps loading right past it (libcef/vivox/pgos load after) -> not the cause. The real exit is `PostQuitMessage(0)`
  on the Nakama thread, stack bottoming out in `nakama-cpp.dll` -> game request-exit path (exe+971c1b < exe+93c61a
  < ... < exe+9fafd0 < PostQuitMessage). It fires at a network-round-trip delay. So the LIVE Nakama backend
  (marauderea2...nakamacloud.io) enforces one realtime socket per account and boots the duplicate; the game treats
  that socket close as fatal. A single OFFLINE copy survives because its Nakama socket never reaches a live server
  (the stand-in is REST-only, no websocket), so there is nothing to boot it. Implication for co-op: two copies BOTH
  blocked from live Nakama (normal offline config, pvenet.dll offline flag / DNS-fail) should both survive on one PC.
  NOTE: a first pvetrace that patched ntdll syscall stubs got the process killed by Denuvo anti-tamper (exit -1);
  IAT patching of kernel32/user32 imports (what pvenet.dll does) is NOT detected. Only ever inject via IAT.
- <game folder>_client: hard-linked copy of the game (no extra space), dwmapi.dll removed (stock, no UE4SS). For a separate client install with its own UE4SS later. Hard links: mode.ps1 rewrites files in PHtest, which may or may not reach the copy (copy-over replaces the link).
- SAME-PC TWO-INSTANCE TEST PASSED (2026-11-07): with the Nakama block applied to BOTH copies (pvenet.dll injected
  via `native/tracelaunch.exe <dll> <exe> [args]`, bridge/offline_backend present so pvenet runs in offline mode),
  two RaidGame-Win64-Shipping.exe ran side by side for 30 s+ (pids 32148 + 33500, ~3.3 GB each), both past the old
  10-15 s death window. So co-op host+join can be tested on ONE PC; the second-PC requirement is lifted.
  Reusable: `tracelaunch.exe pvenet.dll <exe> <args>` starts an offline copy (Nakama blocked) WITHOUT UE4SS - useful
  for a client that must not run the full PvEBridge. These two copies have pvenet only (no UE4SS/PvEBridge), so they
  cannot be driven by console/bridge commands; to send `open`/console a copy still needs UE4SS or the bridge.
- Still unknown / NEXT for co-op: host+join. Host = an offline copy with UE4SS+PvEBridge issuing
  `open /Game/Maps/Space_Solo_01?listen?PID=...`; client = a second offline copy issuing `open 127.0.0.1:7777?PID=...`.
  Open: whether the game mode accepts a joiner (PreLogin URL options, GameLift session checks in a non-GameLift process).

## Co-op host+join attempt (2026-11-07, late evening) — BLOCKED by a deeper second-instance quit
- DONE - per-instance bridge: `mods/PvEBridge/Scripts/main.lua` now reads BRIDGE from env var `PVE_BRIDGE` (defaults
  to the single bridge/). `scripts/bsend.sh <dir> "<cmd>".."` drives a chosen bridge dir; `bridge2/` created (holds
  offline_backend). `native/tracelaunch.exe` now injects a `;`-separated list of DLLs, so a copy can get pvetrace +
  pvenet at once. Launch an instance with its own bridge:
  `PVE_BRIDGE=.../bridge2/ tracelaunch.exe "pvetrace.dll;pvenet.dll" <exe> <args>`.
- NEW PROBLEM: in full OFFLINE MODE (UE4SS + mods + pgos->localhost:1), a SECOND instance still quits (~4-18 s,
  timing varies with a network round-trip), even with live Nakama blocked by pvenet (redirected to the local REST
  stand-in). The FIRST instance survives indefinitely. Traced (pvetrace): B's exit is the same signature as the live
  case - `PostQuitMessage(0)` from `nakama-cpp.dll+5c641 -> exe+971c1b -> exe+93c61a -> <blueprint ProcessEvent
  chain, now with UE4SS.dll frames> -> exe+9fafd0 -> PostQuitMessage`. Deterministic: first instance NEVER calls it,
  second ALWAYS does.
- Levers TRIED and FAILED (all via pvetrace IAT hooks, env-gated):
  * PVE_SUPPRESS_QUIT: swallow PostQuitMessage from the quit site (exe+0x9fafd0). The call is suppressed but the
    process still exits seconds later with NO ExitProcess/TerminateProcess through our hooks -> the engine exit flag
    (GIsRequestingExit) was already set upstream; blocking the window message is too late.
  * PVE_FIRST_INSTANCE: spoof the `"UnrealEngine4"` single-instance mutex as freshly created (SetLastError(0) when it
    returns ALREADY_EXISTS). Confirmed firing ("SPOOFED FIRST") but the quit STILL happened -> the quit is NOT gated
    by UE4's IsFirstInstance. The mutex ALREADY_EXISTS is the only Win32-level difference between survivor and victim
    (diffed both traces), but it's a symptom of "being second", not the cause.
- The stand-in is pure REST (no websocket/status/match endpoint) and returns identical responses to both instances,
  so it is not the signal. The fatal trigger is nakama-cpp's realtime socket callback.
- CAUSE ISOLATED (2026-11-07, controlled A-vs-B traces): the trigger is **UE4SS core**, nothing else.
  * pgos is NOT it: offline mode with STOCK pgos_config (live URLs, pvenet blocks them) -> second still dies.
  * backend/account is NOT it: two copies in ONLINE FILE MODE + pvenet (no UE4SS) both survive 42 s, second has 0
    exits - even though both auth the same account to the stand-in. "Same account twice" is harmless.
  * our mods are NOT it: offline mode with EVERY mod disabled (deployed Mods/mods.txt all 0 except built-in Keybinds)
    -> bare UE4SS core -> second STILL dies (PostQuitMessage, same nakama->blueprint signature).
  So: with UE4SS present, the SECOND instance self-quits via the nakama-disconnect blueprint; without UE4SS neither
  does. UE4SS hooks ProcessEvent (its frames are in the quit chain); likely its per-UFunction overhead perturbs timing
  so the second copy's nakama realtime disconnect handler runs and quits (death time varies 4-18 s = a race).
- SOLVED (2026-11-07, later): the real single-instance guard is an exclusive lock file in %TEMP%
  (`%TEMP%\3BF2080B4AE836B4EC4CBB889BB045C2`, CreateFileW GENERIC_WRITE share=0). The second copy gets
  ERROR_SHARING_VIOLATION, retries once, then calls RequestExit (exe+0x1a70880) -> PostQuitMessage. FIX, no patching:
  launch the client with its own TEMP/TMP (`TMP=...\tmp2 TEMP=...\tmp2 PVE_BRIDGE=.../bridge2/ tracelaunch ...`).
  Verified: host + client both at the main menu with UE4SS, both bridges answering. (The "UE4SS is the cause" result
  above was a timing artefact; ignore it.)
- NEW BLOCKER: the host hangs (not responding) after `open /Game/Maps/Space_Solo_01?listen<RAID_OPTS>` from the main
  menu, even with no client running. UDP 7777 does open. Not yet understood; next session: try the listen open the way
  the earlier successful test did (bridge-loaded pvenet, no early injection, no pvetrace), and from the lobby rather than
  the main menu. scripts/quitsite.py + native/pvestacks.c are the diagnostic tools added.
- HOST HANG RESOLVED BY LAUNCH METHOD (2026-11-07, 21:00): plain `launch-offline.ps1` (bridge loads pvenet itself, no
  tracelaunch, no pvetrace), Play (bridge/t_play.lua), then from the LOBBY `open /Game/Maps/Space_Solo_01?listen<RAID_OPTS>`:
  host stays responsive, aboard after 13 s, rivals running, UDP 7777 listening. The earlier hang came with early
  injection / opening from the main menu. Client = plain Start-Process with env TEMP/TMP=MaraudersPvE\tmp2 and
  PVE_BRIDGE=.../bridge2/ (no tracelaunch needed; PvEBridge loads pvenet from bridge2/offline_backend).
- JOIN FAILS (client side). `open 127.0.0.1:7777?PID=offline2?PNAME=Marauder2?CREW=solo2?CPT=1?NUM=1?EOS=offline2?UPN=offline2?psid=2`:
  the handshake gets through: the host gets a NetConnection and, ~10 s later, a second MainPlayerController (no pawn,
  no PlayerState name) that stays until the connection times out. The client:
  * with PvEDirector on: loads for ~10 s, then is back at MainMenu with no NetDriver. No script-level cause: hooks
    (bridge/t_neterr.lua, t_kick.lua, t_leave.lua) on GameInstance HandleNetworkError/HandleTravelError,
    ClientWasKicked/ClientReturnToMainMenu(WithTextReason)/ClientTravel(Internal), OpenLevel, ExecuteConsoleCommand,
    QuitGame never fired (hooks do work: ExecuteConsoleCommand caught the join itself). So the engine dropped it
    internally (shipping build, no UE_LOG).
  * with PvEDirector off (deployed mods.txt only; host restarted the same way): the client freezes right after the
    join, main thread spinning in exe code (same rip exe+1c3cdc0 in two samples, CPU busy), indefinitely (>3 min).
  * joining from the client's LOBBY (pressed Play first, PvEDirector on): same as the first case, back at MainMenu
    ~20 s later. So a logged-in client doesn't help.
  * LAND RAID (2026-11-07, 21:25): host `open /Game/Maps/Raids/Spaceport_01?listen<RAID_OPTS>` from the lobby works
    (ShootingRangeGameMode_C, responsive, 7777 open). Client (PvEDirector on, UE4SS) joins -> freezes at once, the
    host never gets a second controller. Main thread spins at the SAME exe+1c3cdc0 as the space-map freeze; its
    stack alternates exe frames with UE4SS.dll+555002 / +554f22 (UE4SS's blueprint-VM hooks) under a net tick ->
    likely a blueprint loop that UE4SS's ProcessInternal/ProcessLocalScriptFunction hooks keep running.
  * Stock client without UE4SS (PHtest_client + tracelaunch pvenet.dll, URL `127.0.0.1:7777?PID=..` as first arg):
    the URL is ignored, the game sits on its own title screen (PLAY/EXIT). No way to drive it there.
  * UE4SS-settings HookProcessInternal=0 + HookProcessLocalScriptFunction=0 on the client: crashes ~9 s into startup
    (exit 0xC0000264), twice. So those hooks can't simply be switched off with our mods loaded.
  * CLIENT WITH ONLY PvEBridge (2026-11-07, 21:40; deployed mods.txt trimmed after the host started; host = full mods,
    Spaceport_01 listen): NO freeze. The client bounces back to MainMenu ~3 s after `open` (MainMenu reloads, new
    StationGameMode id), never loads Spaceport. Host: conns 0 -> 1, a second MainPlayerController with NO PlayerState
    (RaidGame pools controllers, so this does not mean the client got in), connection left until timeout.
  * THE FREEZE IS OUR TOOLING: with the diagnostic hook scripts (t_neterr/t_kick/t_leave) loaded on that same
    PvEBridge-only client, the next join froze at the same exe+1c3cdc0 spin. So Lua RegisterHook'd functions firing
    during the join (ours or PvEDirector's) cause the freeze; the real behaviour is the quick bounce.
  * Rejected during the handshake, in native code. Controller chain MainPlayerController_C -> RaidPlayerController ->
    SIGISPlayerController -> AGameLiftPlayerController (ServerAcceptPlayer/ServerRemovePlayer(PlayerSessionId));
    the exe carries the GameLift server SDK (AcceptPlayerSession). URL options the exe parses (UTF-16 strings near
    0x40998c8): PID UPN SHIP CREW CPT PNAME NUM EOS GUILD player_id player_battle_session_id code error (no `psid`).
    Game mode chain ShootingRangeGameMode_C -> RaidGame_Space -> RaidGameMode -> SIGISGameMode -> GameMode adds no
    script login functions: PreLogin/Login logic is all native. Tried, all bounce the same: CREW=solo1?CPT=0 (join the
    host's crew), host reopened with NUM=2, client NUM=1/2.
  * NATIVE PASS (2026-11-07, 21:55-22:11). Tools: native/pveudp.c (IAT sendto/recvfrom logger -> capture/udp-<pid>.log,
    optional per-path send stacks; decode with scripts/udpstr.py), native/pveeac.c (logs EOS anti-cheat SERVER calls via
    the exe's GetProcAddress import; pass-through), bridge/t_trace.lua (lean hooks: name + time only, never params ->
    no freeze), bridge/t_kick2.lua.
    - Not a PreLogin reject: the client sends a plain NMT_Login (URL options + Name=Marauder1 + net id `Hay-<hex>` from
      the NULL subsystem), gets its welcome, loads Spaceport's persistent level, joins, receives ClientSetHUD(MainHUD_C),
      and ~0.4 s later the HOST closes the connection: its keepalives (every ~0.2 s) stop at that moment. Client lands
      on MainMenu with options `?closed`. Other packets (both directions, except the login) are high-entropy:
      some packet transform; not decoded.
    - No kick RPC reaches the client (ClientWasKicked / ClientReturnToMainMenu* / Client_EACAction / ClientEACAction
      never fire), host never runs ServerChallenge/ServerAcceptPlayer as UFunctions. The close is flushed by the
      normal per-tick send path, so the deciding code isn't on the sendto stack.
    - EOS anti-cheat ruled out: EOSSDK is loaded but no EOS_AntiCheatServer_* function is ever looked up.
    - Options player_battle_session_id / player_id, CREW=solo1?CPT=0, NUM=2: no change.
    - Both copies have denuvo-anti-cheat-runtime.dll loaded, and SIGISPlayerController has
      ServerChallenge(TokenReturn, TokenReturn2): an anti-cheat challenge/response between host and joiner is a
      plausible remaining cause (unproven). NOT pursued: working around the game's anti-cheat is out of bounds (and
      the Denuvo anti-cheat components are never to be touched). Other unproven candidate: a native GameLift
      AcceptPlayerSession check in the host's login (server SDK statically linked; can't be IAT-hooked).
  Co-op status: host side works; joining is blocked by a native, host-side close right after login.
- (older) options for a driveable second instance (co-op client):
  (a) Fix with UE4SS present: identify the quit UFunction (C++ impl exe+0x9fafd0, a blueprint-callable reached via
      ProcessEvent from exe+971c1b nakama callback) and RegisterHook it in Lua to no-op / early-return. UE4SS is both
      the cause and the tool. Needs identifying the UFunction (log ProcessEvent around the quit, or hook candidates
      like a GameInstance OnDisconnect/ReturnToMainMenu/Quit).
  (b) Keep the client WITHOUT UE4SS (survives) and drive its join another way: a UE4 map URL on the command line
      (`RaidGame-Win64-Shipping.exe 127.0.0.1:7777?PID=..`) or a minimal injected helper calling open; host stays the
      FIRST instance with UE4SS+bridge (first instance never quits). Open: client needs a PID, normally from login.
  The listen server itself (`open ...?listen`) is already known to work for a single instance.

## Co-op join: who drops, and what never fires (2026-11-15; tools/coop/coop_hooks.lua)
Follow-up to "Co-op host+join attempt". Same setup as there: host = launch-offline.ps1, splash Play, then from the lobby
`open /Game/Maps/Raids/Spaceport_01?listen<RAID_OPTS>`; client = second exe with its own TEMP/TMP (tmp2) and
PVE_BRIDGE=bridge2/, deployed Mods/mods.txt PvEDirector 0 (PvEBridge only), `open 127.0.0.1:7777?PID=offline2...`.
Both copies ran tools/coop/coop_hooks.lua: logging-only hooks (name, time, object address; no params) on 21 UFunctions:
SIGISPlayerController ServerCheck / ServerChallenge / Server_SendEAC / OnAntiCheatCheck / ClientEACAction /
Client_EACMessage / Client_EACAction / Client_Loaded, GameLiftPlayerController ServerAcceptPlayer / ServerRemovePlayer,
RaidPlayerController ClientStartOnlineGame / ClientGameStarted / ClientDissconnectedFromServer, PlayerController
ServerNotifyLoadedWorld / ClientSetHUD / ClientRestart / ClientWasKicked / ClientReturnToMainMenuWithTextReason,
GameModeBase K2_PostLogin / K2_OnLogout, MainPlayerController_C ReceiveBeginPlay; plus Actor:ReceiveEndPlay logged
for PlayerController classes only. Two joins (21:05, 21:14), same result both times.
- The connection IS dropped about 3 s after the join (corrected later the same day). A first poll counted objects
  (FindAllOf IpConnection / MainPlayerController_C) and saw them stay for 30 s, which looked like the host keeping the
  joiner. Those are leftovers waiting for garbage collection: the host's live list, world.NetDriver.ClientConnections
  (GetArrayNum), went 0 -> 1 at the join and back to 0 about 3 s later. Count connections with that list, not objects.
- Client timeline (join 21:14:23): host spawns the joiner's MainPlayerController (ReceiveBeginPlay 21:14:27.2); client
  gets ClientSetHUD 21:14:28.8; client is back on MainMenu by ~21:14:30 (its menu re-login hits the stand-in's
  GET /v2/account at 21:14:30). The client's own ReceiveBeginPlay never fired, no ClientRestart, no ServerNotifyLoadedWorld.
- Never fired on either side, both joins: ServerChallenge, ServerCheck, OnAntiCheatCheck, Server_SendEAC, every
  Client_EAC*/ClientEACAction, ServerAcceptPlayer, ServerRemovePlayer, ClientWasKicked, ClientDissconnectedFromServer,
  ClientReturnToMainMenuWithTextReason. A host-side hook at a native RPC's exec thunk should fire on receipt even if
  its _Validate then fails (inferred, not verified). Whether a client-side hook fires when the client SENDS a Server
  RPC is not verified either.
- No backend traffic at the join: stand-in server.log has nothing between the join and the client's menu re-login.
  pvenet.log (needs a capture/ folder to exist, else it logs nothing) shows only the usual blocked lookups
  (api.gameanalytics.com every ~4 s from the exe, marauderea2...nakamacloud.io from nakama-cpp.dll), before and after.
- Gotcha: UE4SS 3.0.1 can't run a Lua hook for a function with an FText param: "Error executing hook pre-callback
  /Script/Engine.PlayerController:ClientReturnToMainMenuWithTextReason: [push_textproperty] Operation::GetParam is not
  supported" in UE4SS.log, and the Lua callback never runs. So a "never fired" for an FText RPC only holds if that error
  line is absent from UE4SS.log too (it was, for both joins). Earlier passes that hooked this RPC couldn't have seen it.
- Seen once, after the joiner crashed (below): ~17 s after the client died, the HOST called
  ClientReturnToMainMenuWithTextReason (the UE4SS error line above) and went back to its own MainMenu. That's the host
  ending its session on losing a player, not the join bounce.
- Crash, our tooling: a client-side RegisterLoadMapPreHook that read the URL (url:get().Map / .Op) killed the client
  during travel (0xe06d7363, a C++ exception inside UE4SS.dll frames, minidump in %LOCALAPPDATA%\RaidGame\Saved\Crashes).
  Don't read LoadMap params from Lua.
- Denuvo, passive OS view only: "Denuvo Anti-Cheat Update Service" (Manual start) is Running while the game is up, process
  denuvo-anti-cheat-update-service; EasyAntiCheat and EasyAntiCheat_EOS services Stopped. Nothing else looked at.

What this means for the candidates (desk research, same date):
- A, Denuvo anti-cheat challenge: no longer the best fit. The suspected path was SIGISPlayerController ServerChallenge
  (TokenReturn, TokenReturn2) failing on the host; no hook on either side ever saw it, and no kick arrives. Not
  ruled out: a check entirely inside the Denuvo runtime on the CLIENT that makes it leave (we don't and won't look there).
- B, GameLift accept: no sign of it. ServerAcceptPlayer never runs on the host and is never seen leaving the client.
- New lead, client side: the client leaves ~1-2 s after ClientSetHUD, before its controller's BeginPlay, without any
  kick RPC: the shape of an engine-level client network failure (UNetDriver/PendingNetGame error -> HandleDisconnect ->
  travel with `?closed`), e.g. a replication/package-map problem while the joiner's world starts, or game code on the
  client calling a disconnect natively. Desk research: `?closed` comes from UEngine::HandleDisconnect
  (https://forums.unrealengine.com/t/network-error-force-loads-entry-map-for-client-when-server-shuts-down/405257/11).
- Second session, same day (upstream master 92fde2d; native/pveudp.dll built with MinGW, -D_WIN32_WINNT=0x0602, loaded
  into both copies with package.loadlib from the bridge):
  * PvEDirector OFF on the host too (deployed mods.txt edited between mode.ps1 offline and the launch): same bounce.
    The director is not the cause.
  * 28 more client-side name-only hooks on everything that sounds like leaving: SIGIS_ExampleGameInstance_C
    Return_NakamaDisconnected / Return_Nakama_Error / Return_LostInternetConnection / ExitGame_ForceDisbandOrLeaveCrew /
    OnCanceled, SIGISGameInstance LoadMainMenu / BeenKickedFromLobby / CancelSearch, ...Nakama CaptainBackInMainMenu /
    AwsN_BeenKicked, ...PGOS CancelMatchmaking / DirectlyTravelToServer, GameLiftGameInstance QuitGame / ServerTravel,
    GameInstance HandleTravelError / HandleNetworkError, RaidPlayerController DeathToMainMenu, SIGISPlayerController
    HasLostConnection / TravelToMap / PGOSTravelToMap / OfficeTravelToMap / Client_ReturnPushMessage, PlayerController
    ClientReturnToMainMenu / ClientWasKicked. Only ClientSetHUD fired; no "Error executing hook" lines. Afterwards the
    client's world is MainMenu with no NetDriver.
  * UDP (both sides, same join): handshake and NMT_Login at 0-160 ms; host keepalives every ~200 ms while the client
    loads (the client sends nothing for 2.5 s); at ~2.6 s the client's first packet after loading, a few exchanges
    (ClientSetHUD arrives here), last client packets at ~2.70 s, last host packet at ~2.73 s, then nothing either way.
    No new send stack on either side at the end, so neither side's last packet came from a separate close path.
  * Not settled: which side ends it. Reading the client world's URL (.URL.Op) from the bridge errored.
- Out of bounds, unchanged: nothing that bypasses, patches, spoofs, emulates or hooks Denuvo anti-cheat/anti-tamper or
  answers a challenge; no modded client near a live match.
- Wire, third join (both captures merged on the shared GetTickCount clock): the last exchange is client 18 + 10 bytes,
  host 19 + 11 bytes within ~15 ms, then silence both ways. Who closes can't be read from the packets: after the
  handshake even the 12-byte keepalives look random (67027b5d5bb81ccde4bdd901, 67027b5d7c534de695f57301, ...), so a
  packet transform is on (encryption/obfuscation, not just bit-packing). Decrypting it is not pursued (it may belong to
  the anti-cheat protection; out of bounds). What's left, observation only: an engine-side signal on the client (which
  network failure, if any) or a client-side NotifyOnNewObject trace of what arrives in the final packets.

## Your crew: AI teammates (2026-11-07, night; mods/PvEDirector/Scripts/crew.lua)
Co-op joining is blocked (see above), so teammates are AI stand-ins.
- Roster (CFG.SIZE, default 2, F3 menu tab "Your crew", 0-3): rival-style people (rivals.newMember) kept for the game session.
  Same names every raid, kit re-rolled each raid. The dead are replaced by new recruits at the next raid.
- Bodies: rivals.startBody/finishBody, then TeamNumber = PLAYER_TEAM (3) and faction "player", so neither side can hurt the
  other, and every other faction fights them. e.rival is cleared, so they never count as rival kills. e.follow replaces patrol/investigate in
  main.lua updateBots; e.followRun makes animate() sprint. Spawn SPAWN_DELAY s after you're on foot somewhere with
  navmesh (space: playerPlace ~= nil; land raids always); farther than REJOIN (5000: you docked/breached) -> teleported
  near you; fights farther than LEASH from you are dropped. defend(): every 0.5 s a crewmate not fighting goes for the
  nearest bot whose foe is you (boarders only ever target you). gearCatalog works without rivals' S (land raids).
- Gunner (first crewmate, CFG.GUNNER): while you fly (pc.Pawn == your hull) there's no body. Crew.frame (per frame) fires
  your hull's own turrets (rivals.shipTurrets = SpawnedTurretArray, non-camera) through fireTurrets at rivals.hostileShips():
  crews attacking you, or the ship you just fired at (inYourSights). Reaction GUN_REACT, spread x GUN_SPREAD (rolled once per gunner). Counts as you firing (playerFired).
- Verified 22:28 (bridge/cr_test.sh): 2 crewmates spawned aboard 3 s after the raid started, following. At the helm: "Teague mans 1 turret(s)",
  "engaging the Long Odds", turret shots. First run: Fennec ignored 2 boarders for 30 s+ (follow dropped the heard noise) -> defend() added.
- Second run: defend() fired, but the crewmate sat at TeamNumber 2. updateBots' re-arm calls arm(), which sets BOT_TEAM.
  It now keeps the team of any entry with a faction, which fixes rival bodies too. crew.lua also re-asserts the team every update
  and logs it. A crewmate fighting out of sight gets e.lastSeen refreshed from the foe every 2 s (combatHints closes in on it).
- Third run (22:41): crewmate on team 3 took a boarder 160 -> 33 hp in 40 s. Crew names are now their own list (a crewmate
  and a boarder were both "Grub"); that change has only been syntax-checked.
- Not yet seen: crewmates on screen, land raids, docking at a station with them, a crewmate's death, a real F at the helm
  (bridge t_helmown's second call doesn't take you out of the helm).

- Pod breach (2026-11-08): your crew comes through your hole with you. rivals.lua breachInto records S.breach (R.lastBreach:
  spot, time, ship, breachSpots of the interior) and now picks the first breach point with navmesh around it. crew.lua keys on
  that breach (not on "you were nowhere": a short pod flight can start and end between two crew updates, and then they stayed
  on your ship): bodies removed and rebuilt on the floor where you landed (breach points sit ~5 m up the hull wall; the
  navmesh nearest the hole itself was the deck above yours), first 1.5 s after you, the rest 1.2 s apart, "Your crew follows
  you into the X". Old catch-up teleport needed navmesh around you and left them 458 m away on your ship at a Capital interior.
- Verified (bridge/bp_test.sh <screens> [design]; t_bpod flies a pod in from 60 m with your body parked at 0,0,0, t_podin
  brings it to the hull, t_crewpos/t_breachpts/t_navship probe): Black Tallow, Nell and Hollis 2-3 m from you on your floor
  4 s after the breach, then both went for the defender fighting you. Facing into the ship on screen. Not seen: a real F
  pod launch, a Capital interior with the fix (prep picked scouts). Test launches pay wages: the stand-in keeps state in
  memory, so restore state.json/crew.lua with it stopped.

## Hiring your crew, nametags (2026-11-07, late night; hire.lua, crew.lua)
Replaces the free random crew above: crewmates are now hired, persistent and optional.
- hire.lua: pool of 8 recruits, each a set person: name (by sex), voice set (voicelines key), head + body mesh paths (gear.lua),
  personality, level 1-5, lifelong aimRoll and turret spread. Saved in backend/crew.lua (`return {...}`, delete for a fresh pool;
  one file for every save slot). Crew max 3. Hire fee 1000/2500/5000/9000/15000 and wage 300/600/1000/1600/2500 a raid by
  level, both through the controller's own GetCash/TakeCash (the game then PUTs playerstats/cash itself: verified in
  server.log). Wages are paid in launchMatch; a crewmate you can't pay stays home. Each launch records D.raid = paid ids. Back in the lobby
  (Hire.lobby, every MainMenu update) they get +1 raid (promotion at 3/7/12/20), and 2 pool recruits are swapped for new ones.
  Death in a raid (crew.lua bodyOf) -> Hire.died: removed for good, kept in D.fallen. A raid killed by quitting still counts as survived.
- Level = AI profile between ai.lua's soldier (1) and rival (4), extrapolated at 5 (miss 0.6 -> 0.35 -> 0.27), kit tier
  budget/mid/geared, +10 hp a level. Set as e.mind.profile after rivals.finishBody (which now takes m.headPath/bodyPath).
- Optional: no hires = no crew; "Crew comes on raids" ON/OFF; per crewmate Comes along / Stays home; pick the gunner.
- F6 menu (lobby and raid; changes only in the lobby). The lobby's director tick runs on the MM_CoreMissions widget: the
  controller comes from GameplayStatics.GetPlayerController (GetCash on the widget failed; the menu couldn't be created).
  A raid's controller reads 0 cash. The PGOS overlay covers viewport widgets even at Z 5000: opening the menu hides it.
  bridge/crew_cmd takes "menu", "list", "hire N|name", "dismiss", "bring", "gunner", "toggle".
- Nametags (crew.lua C.tags, every raid frame): TextBlock + health bar per crewmate in a DebugInfo_Widget host at Z -2,
  placed by WidgetLayoutLibrary.ProjectWorldLocationToWidgetPosition, fading past 15 m, hidden past 60 m.
  TextBlock:SetColorAndOpacity({SpecifiedColor=...}) left the text dark; writing ColorAndOpacity.SpecifiedColor fields works.
- Verified (bridge/hr_test.sh, 23:01-23:05): hired 2 then 1 (4th refused: full), cash 19591 -> 14491 written to the backend,
  wages paid, the saved crew came back after a game restart with their raid counted, 3 crewmates in the raid, green nametags
  on screen; lobby menu above the PGOS overlay (23:10). Test save restored and backend/crew.lua deleted afterwards. Not yet seen: a promotion or a death in game (simulated offline with lupa: scratchpad hire_sim.lua), clicking
  the menu's buttons with the real mouse.

## Lobby crew hooks found (2026-11-07, 23:18; bridge/t_lobbychars.lua)
- The hangar has 4 character stands, MM_PlayerChar_C: id 0 = you (isPlayer, at -328,-118,-13) and ids 1-3 inactive beside
  you (-438,-274 / -216,-399 / -172,-248). They're the live crew's stands: full rigs (SkelMesh_Head/Body/BodyArmour/Helmet/Bag,
  weapons + attachments), GetSetPlayerItem(mesh comp, item row, ...), `members` TArray<FPlayerInfo>.
- 5 MM_GuildChar_C elsewhere (-2900,-500,-397: the guild hall).
- Crew slot widgets Crew_member_MM_Widget_C Slot01-04 (two sets): Img_CrewMembAvatar, Txt_CrewMembName, Btn_InviteToCrew (the "+"),
  Btn_ViewProfile, isSlotFull; Update_CrewSlot/Clear_CrewSlot take FPlayerInfo/FClientPartyInfo structs (not tried).
- CRASH: the first probe called GetVisibility on every Crew_member_MM_Widget_C FindAllOf returned, the class default object
  included -> game crashed (UE4CC report). Skip Default__ objects; read properties only.

## Crew in the lobby: stands, slots, portraits, hiring page (2026-11-08, ~00:00; crewlobby.lua, hire.lua menu)
- Hired crew stand on the hangar's crew stands (MM_PlayerChar_C CharID 1-3) in their own look and kit; the crew slots
  (Crew_member_MM_Widget_C Slot02-04 under /Engine/Transient) show "Name  Lv N" and a portrait; "+" opens HIRE, a filled slot
  opens YOUR CREW. The hiring page is a left panel in lobby colours with the lobby's font (copied from a slot's TextBlock);
  clicking a recruit row puts them on a free stand, right-hand first. F6 still opens it.
- Each recruit has a fixed kit (hire.lua giveKit: rivals.rollKit on their level's tier, re-rolled on promotion); crew.lua uses
  the same kit in raids (fresh ammo/meds). Not yet run in a raid since this change.
- Dressing: head/body by mesh path; helmet/armour/bag/gun rows -> meshes learned once from a hidden donor raider dressed by
  pve_roll_kit, saved in config/crew_meshes.lua. Refresh_PlayerLookActor/GetSetPlayerItem can't be called with a look from Lua
  (struct with FStrings fails; names-only "succeeds" and does nothing). Cached paths can have odd object names
  (M1_Helmet_Skel_01.M1_Helmet_Skel_01_M1_Helmet_Skel_01); LoadAsset of that full path works.
- FREEZE (fixed): K2_DestroyActor on a donor raider (SpawnActor'd, no controller) hangs the game thread forever (found by a
  flushed per-call trace: capture/crewlobby_trace.txt). Donors are now hidden and kept, never destroyed. An earlier hang
  before Play was my own bridge probe (t_ufuncs.lua StaticFindObject on 24 paths while assets were loading).
- The lobby's own crew refresh after Play hides the stands, empties their gear slots and puts "+" back: crewlobby re-checks
  every 0.5 s (hidden, wearing() per part, slot border visible) and re-dresses.
- Portraits: photo booth = our own MM_PlayerChar_C 3000 under the floor, two point lights, SceneCapture2D with
  PrimitiveRenderMode show-only (ShowOnlyActorComponents) and fixed exposure, 256px RGBA8 render targets (FinalColorLDR);
  the face is on the stand's RIGHT side (mesh +Y; -forward gave profiles), camera aimed along the head bone's +Y. All 8 recruits + crew filled within ~30 s on a fresh lobby.
- Kill switch: config/crewlobby_off containing "all" (or "stands"/"slots") turns the lobby part off, read every 2 s.
- Tests: bridge/lb_test.sh (hire two, preview, tabs), lb2_test.sh (saved crew after restart).
- Slot clicks (2026-11-08): the user's real "+" clicks didn't open HIRE: polling Btn_InviteToCrew:IsPressed misses quick clicks and
  only watches the slot set findSlots kept (there are two). crewlobby now hooks the slot's own events
  (Btn_InviteToCrew ..._4_OnButtonPressedEvent, Btn_ShowHideOptions ..._6_OnButtonClickedEvent) and maps the widget's name
  (Crew_member_Slot0N) to the slot; polling stays as a fallback.
  The lobby only SHOWS Slot01-03 (Slot04 is collapsed, vis=1), and the "+" you see first is Slot01: the crew used Slot02-04, so
  the visible "+" was never watched and a 3rd crewmate landed in the hidden slot. Crew now fills Slot01-03.
  Verified by the user clicking "+" in game (2026-11-08): HIRE opens. Their first launch-offline run that night came up
  without UE4SS (stock folder, "+" opened the real social menu); the second launch was fine. Cause not looked into.

## Pod gun and ramming a rival (2026-11-08, ~13:00)
- User: their gun still showed on the pod (Pistol Training loadout), and ramming a rival with a pod never breached. Log: the Brass Monkey's
  interior loaded at 12:51:59, then about a minute of pod flight with no breach. breachInto needed the pod within PLAYER_BOARD_RANGE (1800)
  of the hull's CENTRE; the hull stopped the pod farther out. Now the pod also breaches within PLAYER_BOARD_TOUCH (600) of the hull's
  collision surface (rivals.lua hullGap, ship.Mesh:GetClosestPointOnCollision).
- Pod guns: main.lua hidePodGuns hides every RaidWeapon whose MyPawn is your body or that sits within 8 m of the pod, plus Inventory and
  CurrentWeapon. Hidden flags are re-applied every update (the old fix hid once), FindAllOf scans run at 0/1/4/10 s into the flight,
  and each gun hidden is logged once as "pod: hid <name> (carried|held|yours|on the pod)". Any pawn whose class name has "Pod" counts as a pod
  too (escape pods). NOT verified in game yet: copied into the game's Mods folder while the user was at the menu.
- Gun attachments on the pod (issue #18, 2026-11-15): a gun's attachments are actors of their own in its slots
  (RaidWeapon MuzzleSlot / SightSlot / LowerRailSlot / UpperRailSlot / MagSlot / StockSlot / SpecialSlot, e.g. a Mat49's
  Attach_Mat49_Wooden_Stock_C and Mat49_Default_Magazine_C), so SetActorHiddenInGame on the gun left them drawn. hide()
  now hides the slot actors too and keeps them in raid.podGuns, so the on-foot pass shows them again. Test save: a
  stash string with the stock in the 6th attachment slot (`<id>-Mat49Rifle-32-100-0-0-0-Prim-0!0!0!0!0!Mat49WoodenStock!0`)
  spawns the gun with StockSlot = Attach_Mat49_Wooden_Stock_C (so the 7 slots run Muzzle, Sight, LowerRail, UpperRail,
  Mag, Stock, Special, and a slot holds the attachment's row). Launched by InteractionDetection + ServerUse on
  RaidUseableComp_DropPod01: before, the hidden guns' StockSlot/MagSlot actors were still visible; after, all hidden
  (held, carried and the pod's own copy). Not seen: showing them again back on foot (the pod never landed in the test).

## Ship damage visuals / incapacitated state (2026-11-08, FIXED, see end of section)
- Measured in game (Space_Solo_01, Starter, bridge/t_shiphit.lua = real GameplayStatics:ApplyDamage on your hull; t_shipdmg.lua reads state):
  the server side works offline. Interior TotalShipHullHealth is a fraction (575 -> 425 = 0.739). At 0 hull the ship is NOT sunk:
  LifeSupportDestroyed turns on (interior and hull bLifeSupportDestroyed), i.e. the incapacitated state. Systems held only PrimGun=100.
- Nothing shows: the hull AnimBP's b_HullIsDamaged / f_isHullDamaged / b_*IsDamaged stay false at every hull level, and the interior
  BP's reactions (FrigateInside_*: ShipHullHealthChangeEvent, OnLifeSupportDestroyed, CriticalDamage_AmbientLighting,
  TakeDamage_MakeLightsOnShipFlicker, ShipHealthIsCompletelyDamaged, components P_Damage_LifeSupportComp/HelmGunComp/TurretComp,
  Audio_ShipAlarm, Audio_LifeSupportFlames_Part1, Widget_ShipOverallHealth) are only reached from RaidSpaceshipInside::OnRep_*
  (OFFLINE_AUDIT item 8), which nothing calls offline. Same bug class as OnRep_WeaponHasBroken (main.lua).
- Calling ins:OnRep_ShipHullHealthChange(old) and ins:OnRep_LifeSupportDestroyed(false) by hand runs without error, but the AnimBP flags
  stayed false and one screenshot pair showed no clear change; whether they light the interior was NOT confirmed (the component probe
  crashed the game, see below). The hull's BPI_ShipAnimations Frigate_Damage_* calls are likely made from another path (CheckFrigClientDamaged?).
- Fix plan: per update, for S.homeInside and each rival c.inside, remember TotalShipHullHealth and the 4 *Destroyed flags; on change call
  the matching OnRep_* with the old value, and call the hull AnimInstance's Frigate_Damage_Hull/Engine/Turret/HelmGun(bool) if still off.
- Probe hazard: reading ins[comp]:IsActive()/.Template on the interior crashed (AV 0x18 in UE4SS; pcall does not catch it). Check
  comp:IsValid() first. Also hit the known load crash (UE4SS +0x555046 -> game +0x1c3574e) once at raid load.
- FIX (rivals.lua damageFxStep, run each R.update): for S.homeInside and every crew's c.inside, remembers TotalShipHullHealth and the 4
  *Destroyed flags (first look starts from undamaged); on change calls OnRep_ShipHullHealthChange(old) / OnRep_*Destroyed(old), and
  calls Frigate_Damage_Hull/Engine/Turret/HelmGun(on) on the hull's and its CurrentWeapon's AnimInstance. Logs each system flip.
- Verified (Space_Solo_01, Starter, bridge/t_fxstate.lua = read-only component check with IsValid first): after 300 damage the AnimBP's
  b_HullIsDamaged turned true (was always false). At 0 hull (life support destroyed): Audio_ShipAlarm and P_Damage_TurretComp went
  active (were off at 48%). P_Damage_LifeSupportComp / Audio_LifeSupportFlames_Part1 were already active at 48% (baseline unknown).
  Screenshots showed only a subtle lighting change from the corridor. Engine/turret/helm-gun destruction and rival ships not tested.
- Rival hulls (2026-11-14): they still looked pristine when disabled. The hull pawn BPs (Ship_*Frigate01_Pawn_C) carry their own
  exterior emitters P_HullDamage01-04, P_EngineDamage, P_TurretDamage, P_HelmGunDamage and events DamageEffects_ShipHull(DamageAmount_Percent)
  / DamageEffects_Engine/Turret/HelmGun(TurnOn), also only reached from replication, and damageFxStep only covered ships with an interior.
  FIX: rivals.lua hullDamageFx runs on every crew's c.ship and your hull: one more P_HullDamage emitter lit per quarter of hull lost, all four
  plus engine/turret/helm-gun fires at 0 hull (or life support destroyed), a destroyed system lights its own fire. Activate(true) +
  SetVisibility after comp:IsValid(). Also calls DamageEffects_* (scale of DamageAmount_Percent unknown; we pass hull left 0-100).
  Verified (Space_Delta, Patrol Scout, bridge/t_hullfx.lua via ApplyDamage): 650 pristine, 450 -> 1 emitter, 250 -> 2, 0 -> all 7 on and
  "[rivals] hull fx: ... disabled" logged; screenshots show the wreck burning. Not moving at 0 hull is the game's own disabled state.
- Testing note: a bare `open <map>` from the menu has no PID and asserts "Couldn't spawn player: PlayerID is null" (or crashes in UE4SS
  at the splash). Start test raids with bridge/mm_launch.sh (waits for login, Play, lobby launch).

## Manning a turret yourself; crew gunner owns the turrets (2026-11-08, gunseat.lua + crew.lua)
- What works natively offline: F on a gunner seat (RaidUseable_TurretControl01; the camera turret seats too) moves your view to
  the turret's camera, which follows your mouse, and sets pawn.MYTurret + turret.ControllerHere = your controller. Missing:
  the turret never turns, the fire button reaches none of the turret's fire functions, F doesn't stand you up, and
  TurretControlUsing / OnRep_SetGunning (sitting anim) never happen (SendGunnerSeatOnRep is Role-gated, audit item 9). The
  native code reading MYTurret sits in Denuvo-moved code (no plain [reg+0x6c8] reads in the RaidGame range), so no patch.
- gunseat.lua (per frame on space maps, Gunseat.frame from main's frame block): when MYTurret appears it calls
  SendGunnerSeatOnRep(LastInteractionComp) + OnRep_SetGunning, marks the turret IsOccupied; each frame TurretLocalRot =
  camera direction relative to the hull (verified: barrel socket yaw = camera yaw); left mouse (IsInputKeyDown) fires the
  turret's own ServerFireProjectile along the camera from its barrel sockets at FireRate, magazine TotalAmmo, ReloadTime
  (AmmoLeft kept in step), and calls pc:ClientFiredTurret (what rivals hook as "you fired"); a fresh F press after 0.5 s
  stands you up (view back to the body, MYTurret/TurretControlUsing/ControllerHere cleared, TurnOffTheGunner).
  Bridge tests: bridge/gunseat_fire (exists = fire held), bridge/gunseat_leave (one F). Driver: gs_test.sh then gt_run.sh.
- Helm vs crew gunner: RaidFrigate::ServerFireFrigate_Implementation (0x183d160) fires SpawnedTurretArray[0] (vfunc +0x668)
  whenever that turret's ControllerHere (+0x2b0) is null, i.e. the pilot also works an unmanned turret. Online a gunner
  in the seat filled it; our crew gunner never did, so you and the gunner both fired it. crew.lua holdTurrets() puts your
  controller in ControllerHere of every turret the gunner works while it does (view unaffected, its direct
  ServerFireProjectile still fires), releaseTurrets() takes it back when you leave the helm, the gunner is down or the hull
  dies (not a turret you sit at yourself). With no gunner the pilot still fires the turret, as the game does solo.
- Verified (bridge only, no real input): pilot ServerFireFrigate fired the turret with ControllerHere null and not with it
  held (only rival turrets in the counts); released to nil after leaving the helm; seated at the gun turret, 6 shots in 4 s
  (ServerFireProjectile + NetMultiFire + ClientFiredTurret each 6), seat registered, occupied, barrel follows the camera; F
  test stood up cleanly. NOT verified: a real mouse click / real F at the seat, whether the body's own gun also fires on
  that click while seated, shells hitting a rival, the turret HUD (TurretFirstTimeOpen/RefreshTurretInfo called, nothing
  visible seen), camera-turret seats' shots.

## Ship gunnery: variable rival aim, crew gunner by level (2026-11-08, rivals.lua gunAim + crew.lua gunnery)
- Before: every turret shot used a perfect lead and only the turret type's own spread, so every rival crew aimed the same,
  and your gunner's spread was rolled once at hire (a promotion never changed it).
- Now each rival crew rolls a gunnery skill (GUN_SKILL 0.3-0.9, logged in "engages ... gunnery 0.xx"). fireTurrets
  keeps their aim per target (c.aim): a new target starts off by GUN_FIRST_MISS deg (crack: 30%) with the lead misjudged
  by up to GUN_LEAD_ERROR; each volley walks GUN_SETTLE of it off (green: half); the target turning puts GUN_JINK deg per
  10 deg back; a green gunner drifts GUN_WANDER deg per volley; spread = type spread x TURRET_SPREAD x GUN_SPREAD_SKILL.
- Your gunner: crew.lua gunnery(m) = GUN_SKILL[1]..[2] (0.2 at level 1 to 0.9 at level 5, linear, read live so promotions
  count) - aimRoll x GUN_TALENT (lifelong, +/-0.1). Passed through R.gunnerFire(turrets, tgt, now, S.gun). hire.lua's old
  gunSpread is no longer rolled (old saves keep a harmless field).
- F3 menu: new "Ship guns" tab (all rivals.lua GUN_* above) and three rows on "Your crew". Tabs are now split evenly over
  two rows (14 tabs; the third row used to run into the Difficulty buttons). The difficulty presets don't touch ship guns.
- Defaults picked offline (scratchpad gunsim.py, frigate hit box ~900 x 540): at 7000 units a green gunner (0.0) lands ~12%
  of its first 3 volleys and ~24% after, mid (0.5) 31% / 70%, crack 83% / 100%; at 4000 roughly double for the poor ones.
  The old model hit ~100% at both ranges, so rivals are weaker at long range now unless set to high gunnery.
- Verified in game (bridge/gn_test.sh after gs_test.sh): no errors, crews logged gunnery 0.43-0.86, Nell (level 1) 0.14,
  169 turret shots in the raid, both menu tabs on screen. NOT measured in game: actual hit rates on your ship / rivals.

## Turret barrels: the gunner aims them, shells leave along them (2026-11-08, rivals.lua aimTurret + crew.lua)
- Bug: at the helm with a crew gunner your mouse still swung your hull's turret, and the gunner's shells flew at the
  target whatever way the barrel pointed. Rival turrets idled sideways (Yaw_Delayed -90) while firing ahead.
- What moves a barrel (probed with bridge/t_turaim, t_turforce, t_turall): NOT TurretLocalRot (writing it does nothing
  visible). Every frame the turret AnimBP's CameraRotation(worldRot, -80, 80, 10) event turns a world rotation into
  Yaw_Delayed (deg off the hull's nose) and NewPitch, which the bone reads. Your hull's turret gets the pilot's view
  there from the ship itself; rival turrets get GetTheRequiredrotation() (ControllerHere's view). Lua hooks on BP
  functions run AFTER the event (UE4SS: "both callbacks act as post"), so setting its param does nothing, and
  overwriting RotationFromCamera is too late; writing Yaw_Delayed / NewPitch in that hook does move the barrel, on all
  7 turret AnimBPs (LightTurret, Dual25mm, Flak, 75mm, Artillery, LargeTurret, TorpedoLauncher). Barrels showed
  pitch -15..+10 or more (anim clamp) whatever TurretMin/MaxPitch (0..15) says. The 75mm's barrel socket is turned
  90 deg in its own frame, so shot headings come from the commanded yaw/pitch, not the socket rotation.
- rivals.lua: AIMED (AnimBP address -> fireTurrets entry); swingBarrel (the hook) steps yaw/pitch toward
  wantYaw/wantPitch at TURRET_SWING x TurretYawSpeed/PitchSpeed (20/10) and writes them. fireTurrets runs every frame:
  sets want from the gunner's aim (gunAim errors included; TURRET_ARC, TURRET_PITCH), fires a loaded turret only when
  its barrel is within TURRET_ON_AIM deg, along the barrel (+ spread). Rival turrets registered when fitted (retried
  per second until the AnimBP exists), dropped with the ship; AIMED cleared per raid.
- crew.lua: holdTurrets also takes the barrels (R.aimTurrets on), releaseTurrets gives them back (off: the pilot aims
  and fires the first turret again, as solo); no target = R.restTurrets (nose). Tuning: "Turret traverse", "Fires
  within" on the Ship guns tab.
- Verified 17:10 (Starter, Nell gunner): at the helm view +45 -> barrel stayed 0. Provoked fight: 32 gunner shots,
  each within -1.9..+1.7 deg of the barrel's yaw (= spread), barrel at -30 on the target while the view sat at +45;
  175 turret shots in the raid, no errors, 84-90 FPS. NOT verified: barrel handed back on leaving the helm, targets
  below -15 deg (now never fired at), rival turret hits, the gunner seat (gunseat.lua still fires along the camera).

## Public release build; no more hardcoded paths (2026-11-08, tools/release/)
- `python tools/release/build_release.py` -> release/MaraudersOffline/ + release/MaraudersOffline-<date>.zip (~88 MB).
  Allow-list: launcher, stand-in + backend/seed.json (the capture seed with Steam id/name/avatar/user id/social removed),
  PvEDirector, a release PvEBridge (tools/release/PvEBridge_main.lua: only loads pvenet.dll, no bridge/cmd.txt),
  pvenet.dll + pvepatch.dll, UE4SS minus dumper/profiler mods, art minus female/src and unused stills, mode.ps1,
  launch-offline.ps1, and install.ps1 / uninstall.ps1 / README.txt / Install.bat / Uninstall.bat. It fails if any
  shipped text file still has a dev path or the Steam name/id in it.
- Install.bat: checks the path is plain ASCII (Lua io.open), finds Python 3.9+ with tkinter (py, python, the usual
  per-user folder; offers winget), pip-installs Pillow, finds the game in every Steam library (libraryfolders.vdf; else a
  folder picker) -> config/game_path.txt, makes desktop + Start menu shortcuts to pythonw launcher.pyw.
- Paths, dev tree included: the Lua mods `require("pveproject")` (mode.ps1 offline writes Mods/PvEDirector|PvEBridge/
  Scripts/pveproject.lua = the project folder); mode.ps1, launch-offline.ps1 and launcher.pyw read config/game_path.txt,
  default still E:\...\PHtest; pvenet.dll / pvepatch.dll find the project from their own path (<project>\native\x.dll)
  and pvenet's "game's own modules" filter is now the exe's folder, not "\PHtest\". The launcher passes its interpreter
  to launch-offline.ps1 as PVE_PYTHON (a bare "python" can be the Store stub) and stops python%.exe stand-ins.
- Verified: DLL rebuilt and loaded by a / path finds bridge\ and capture\; release saves + stand-in serve "Marauder";
  installer detection finds Python and E:\...\PHtest; release mode.ps1 offline/online on a fake game folder restores it
  byte for byte. NOT verified: an actual game session on the new DLLs / pveproject.lua (the game was left in offline
  mode, so it wasn't switched for the test).
- Dev setup (2026-11-15): scripts/setup-dev.ps1 [-Research] does a dev checkout's setup: requirements.txt
  (requirements-research.txt with -Research), config/game_path.txt via Find-Game, UE4SS v3.0.1 into tools/ue4ss.
  UE4SS_v3.0.1.zip (GitHub release, 5,523,402 bytes) SHA-256 4B47D4BCEDDD2F561A4E395BFA00924CCFC945AF576A2D0C613E6537846C57EC;
  dwmapi.dll, UE4SS.dll and Mods/ sit at the zip's root. Find-Game now lives in scripts/find-game.ps1, dot-sourced by
  install.ps1 (build_release.py ships it next to it in scripts/).

## Bot-on-bot damage, armour, aiming walk speed, your gunner's arc (2026-11-08, pvepatch.c + main.lua + rivals.lua)
- Measured (bridge/t_bothit.lua = health drop between a bot's shots on its MyEnemy, t_phit.lua = the same on you with god
  mode off and 5000 hp): bots hit YOU for the gun's full damage (20 / 30 flat), bots hit BOTS for ~1/6 (Mac-10 24 -> 3.3
  x13 in a row, Grease Gun 25 -> 4.2 x12). Client_WeaponHit, PawnTakenDamage, ReceiveAny/PointDamage never fire offline.
- Why (disassembly, scratchpad vt.py / scan9f0.py): the character damage function 0x181a8a0 (health -= at 0x181baf4) first
  calls the game mode's ModifyDamage (vtable +0x940 = 0x17e1870), then armour. ModifyDamage zeroes a hit CanDealDamage
  (+0x950) refuses and x DamageSelfScale (0x4fc, 0.3) when the instigator controller's PlayerState == the victim pawn's.
  Bots have no PlayerState: bot on bot is null == null, so every bullet counted as self-damage.
- Armour (same function): per hit zone (hit capsule's AreaHitType +0x460), damage = clamp(damage - armour, 0, damage) for
  the equipped helmet (head, then x HeadDamageMulitplier 3.5 bots / 3.25 you) or chest piece (body); legs x
  LegDamageMulitplier 0.5, no armour. The armour amount is the item's ARaidArmourActor.ArmourDamageMitagation (+0x228;
  +0x22c concussion for blast damage, 0x181f570). FLAT, not a share: M1FlakVest 7, Helmet_Brodie 7 (CDO values). So 24 x
  0.3 = 7.2 minus a ~4 vest = 3.3. Applies to every shooter, bots included. EquipmentComp.EquipmentIDs reads empty on every
  pawn (the lookup 0x8fd2c0 goes by slot name elsewhere); TMap ForEach fails from Lua.
- Fix (pvepatch.c selfScaleFix, "Bot-on-bot self-damage scale @ +0x17e194a"): cmp rbx,rdi ; jne -> call to a stub near
  the game: same AND non-null PlayerState returns to the mulss, else skips it. Your own self-damage keeps 0.3.
  After (Space_Charlie, Colony Cruiser): a 30-damage gun at 0 m hit a soldier 19.0 x4 (30 - 11 armour), both crewmates
  died in the fight, soldiers 21 -> 19. The interim Lua x6 scaling (scaleBotHits) is gone: it scaled after armour.
- Armour health bonus removed: rival and crew bodies got BASE_HP + HELMET_HP 15 + CHEST_HP 45 ("armour isn't simulated on
  bots"), but their kit goes through the game's kit step (equipKit -> pve_roll_kit -> 0x17cae70) and the armour works.
  Measured with the patch on (bridge/t_vict.lua, hits between a bot's shots on its MyEnemy, Rebel Base): a 160 hp rival
  (helmet + chest bonus) took 14 from 24 x11, 11 / 21, 8 / 18 (chest ~10 a hit); a 115 hp one (helmet only) took 28 / 28
  x5 on the body. Now rivals' maxHp = BASE_HP 100, your crew 100 + HP_PER_LEVEL 10 per level above 1 (in game: level 3
  crew 120 hp, no errors). Rival bodies' 100 not seen in game (none near). A hand-made ApplyPointDamage on a hit capsule
  (bridge/t_ptdmg.lua) crashed the game (access violation 0x38, under UE4SS): don't use it as is.
- Aiming walk (t_fightmove.lua): the game runs an aiming bot at MaxWalkSpeed x 0.5 forward, x 0.5 x MaxMoveBackAndStrafeSpeed
  sideways (TargetingSpeedModifier reads 1.0 on bots, so it isn't that field). Fights were walked at 75-95 and strafed at
  114-143 (you walk 280). animate() now divides MaxWalkSpeed by AIM_SLOWDOWN 0.5 while targeting, standing, not running
  (crouch untouched); profile strafe caps up (rival .9, boss .85, guard .8, soldier .75). After: 226-343 moving, 257-309
  strafing, anim 1.4-2.2x.
- Your crew gunner's arc: rivals.lua GUNNER_ARC 120 deg either side of the nose (rivals stay TURRET_ARC 60); fireTurrets
  takes c.arc, R.gunnerFire passes it. F3 Ship guns "Your gunner's arc". bridge/t_turarc.lua: barrels follow a written
  Yaw_Delayed past their TurretMin/MaxYaw (60): rocket artillery reached 120 / 139 / -120 / -140. NOT seen in a helm fight.
- A launch from the menu by bridge (t_play + t_launch) right after the user's own raid crashed in UE4SS Lua during Space_Beta's
  load (EXCEPTION_ACCESS_VIOLATION 0xffff..., RaidGame+0x1a605d0 from a Lua call); the relaunch was fine. Cause not found.

## F3/F9 in the lobby, borderless fullscreen (2026-11-09)
- F3/F9 did nothing in the lobby: they looked up FindFirstOf("MainPlayerController_C"), and the lobby's controller is
  MenuPlayerController_C (in a raid it could also be the last map's). Now F3/F6/F9 all use Hire.lastPc() (the ticking
  controller), each closes the other two, and Tuning/Debug tick from every ticker like the crew menu. Closing in the lobby
  gives the lobby its mouse UI back (menuClosed in main.lua); Z-order 5000/5010 so they draw over the lobby pages.
  Bridge-flag path (bridge/menu_toggle, debug_cmd) unchanged. Real key presses still NOT tested after this change.
- Launcher "Borderless fullscreen" box -> config/window_mode.txt (borderless|windowed). launch-offline.ps1: borderless
  writes FullscreenMode=1 (+ desktop resolution from Win32_VideoController) into %LOCALAPPDATA%/RaidGame/Saved/Config/
  WindowsNoEditor/GameUserSettings.ini and drops -windowed/-ResX/-ResY; windowed keeps the old 1600x900 args.

## Crew missing, boarding misses, wall spawn, stutter (2026-11-13; user report after the 11-09 runs)
- Crew "never showed up": not a bug in spawning. Save had $166, wages were 1000 + 600: payWages left both at home, and its
  ClientMessage went to the lobby controller a moment before travel, so nobody ever saw it. Now hire.lua keeps the unpaid
  list (H.unpaidNote) and crew.lua says it 6 s into the raid: "Nell and Hollis stayed home: wages of $1,600 unpaid (you
  have $166)". Seen in the log of both test raids. The rule itself (no pay, no crew) is unchanged.
- Boarding misses (11-09 log: three interiors loaded during one pod flight, then "That hull had no way in"):
  playerBoarding ran every 0.5 s from update and gave EVERY ship within 150 m an interior, up to PLAYER_BOARD_MAX 4 a
  raid; after that nothing was boardable, and a pod could reach a hull between two looks or before its interior was in,
  so the game's own impact left you at 0,0,0. Now: per frame (R.frame) while pc.Pawn.bADropPod; only the ship the pod flies
  at (PLAYER_BOARD_AIM 25 deg within PLAYER_BOARD_PREP 16000, or anything within PLAYER_BOARD_CLOSE 4000), one interior
  loading at a time, max 6; free interior slots listed once a raid. The pod's last nearest hull is remembered (S.podShip):
  if you end up in the void within VOID_BOARD_RECENT of that, rescueFromVoid boards THAT ship (loading its interior if
  needed, VOID_BOARD_WAIT 12 s) instead of sending you home.
- Wall spawn: breachInto put you AT the breach transform, which is in the hull wall ~5 m up. Now breachLanding: navmesh
  floor by a breach point that joins up with the inside (joined), else floor at the dock starts; with no navmesh yet and
  the pod at the hull (PLAYER_BOARD_FORCE 250) or from the void after 2 s, the ShipDockOnePlayerStart spot. The home rescue
  uses the same landing.
- Verified (bridge/bx_test.sh <screens>, t_voidhit.lua, t_onfloor.lua; t_podto now keeps its hull in _G.POD_HULL): pod
  stepped at a hull -> boarded the Crow's Due (Capital interior), standing on floor in a room, walking mode; void after an
  "impact" 2500 from the Widowmaker -> out inside it 6 s later, on navmesh, in front of the cockpit door. BOTH came in at
  the dock start ("navmesh isn't ready"): the breach fires the moment the interior is paired, before its navmesh builds, so
  the breach-point floor path (breachLanding's first branch) has NOT been seen in game. Not seen: a real F pod flight.
- Stutter: not the director (ticks over 25 ms: 0-4 per 10 s, none at rest) while frame gaps over 200 ms came 8-19 times
  per 10 s. Measured during the test: 31.6 GB RAM, 0.48 GB free, commit 57.1 of 58.2 GB, 100-1900 pages/s; the game had
  15 GB private but 7.8 GB resident, WoW 12.7 GB private. The machine was paging. Likely what "most runs, not all" was
  (WoW open or not); NOT confirmed on the user's own runs. Small director costs removed anyway: addInteriorNav's two
  scans (~90 ms per interior) are cached per raid. bridge/profile_on + profile.txt is the way to check a real run.
- release/ rebuilt with these changes: MaraudersOffline-20261113.zip (322 files, 88 MB; the 20261108 zip is still beside it). Save restored from backend/state.before-board-fix-test.json after the tests.

## Target switching, crew left behind at airlocks, stutter check (2026-11-13, evening; user report after a Navy Outpost raid)
- Ignoring the enemy beside you: main.lua updateBots only perceived while NOT fighting, so a bot locked on a far foe never
  looked again (a crewmate and a soldier side by side, each shooting someone across the room). Now, while fighting, every
  RETARGET_EVERY 1 s a bot switches to a hostile within RETARGET_NEAR 15 m and under RETARGET_RATIO 0.5 x the current
  foe's distance that is in its line of sight or fighting it ("X turns on Y at 6 m (was fighting someone 16 m off)").
  Applies to everyone (soldiers, rivals, your crew). Seen in game: a soldier turned on Sputnik at 6 m from a foe 16 m off.
- Crew stuck behind airlock doors: airlock chambers are off the navmesh, so a follower can't path through one at all;
  the old catch-up only fired past REJOIN 50 m. crew.lua cutOff: a follower more than STUCK_SLACK 4 m past their follow
  distance who hasn't moved STUCK_MOVE 1.5 m for STUCK_SECONDS 4 s is brought to you out of your sight (or after
  STUCK_SEEN_SECONDS 12 s regardless). Both catch-ups wait while YOU stand in a chamber (rivals.lua R.inAirlock, the
  chamber box turned by its yaw; lock entries now keep box), because the floor nearest you could be either side of the
  doors. Verified (bridge/st_test2.sh + t_crewto.lua + t_meaway.lua): crewmate put in Navy Outpost's chamber, you 26 m
  away -> "Tova was left behind 28 m back (4 s without getting anywhere): catching up", 4 m from you after. Not seen: a
  real docking cycle with the crew (expect them to appear behind you a few seconds after you step out).
- Stutter: bridge/st_test.sh (profiler on). Director stays small in a raid (a few ticks over 10 ms per 10 s, no object
  scans after the load), but the run is NOT a clean measurement: WoW was started mid-test (17:35, foreground, ~85% GPU)
  and fps fell to 4-10. The user's own raid (17:24-17:31) had Roblox started at 17:27 and 14 GB free RAM (no paging this
  time). Lobby: PgosOverlay_BP_C + MM_PlayerChar_C FindAllOf ~20 ms each, 6-8 per 10 s (lobby only). Next: a profiled
  raid with no other game open, or have the user turn on bridge/profile_on for one of their own raids.
- Save restored from backend/state.before-stutter-test.json / crew.before-stutter-test.lua (test hires Vera and Tova
  died/were hired only in the tests). Game folder left online.
- Stutter, second look (same evening; user: it happens with no other game open, Navy Outpost was a station both times,
  worst while flying). bridge/st_test3.sh (aboard 30 s, helm 60 s, then a station). WoW still open, so most windows ran
  at 5-25 fps; the one window the game had the machine (17:51:05, 89 fps, at the helm with the gunner firing) had NO
  gaps over 100 ms (worst 64) and the director never over 10 ms (rivals.frame ~0.8 ms/frame with the gunner).
  The profiler now also writes: Lua heap range and garbage collections, per-section ms + max (aim, minimap,
  rivalsFrame, gunseat, crewFrame, tags, update, rivalsUpdate), the turret swing hook's call count, the time of each
  gap over 100 ms within the window, and where you were (pawn class = on foot / flying, rivals.where, nearest station
  + distance, fps). Seen: swing hook ~45 calls a frame (every turret of the 7 hooked AnimBP classes in the world calls
  CameraRotation each frame; only AIMED ones do work), Lua heap 90-200 MB with a collection every ~20-30 s. Neither
  showed as a hitch in the clean window. bridge/profile_on left ON for the user's next raid (profile.txt);
  the test run's output is in bridge/profile.test-17-51.txt.
- crew.lua cutOff: only for followers within REJOIN, logs "caught up" only when rejoin found a spot (it spammed the
  line with you at 0,0,0 after a test teleport), and waits the full STUCK time again after a failed try.
- Stutter, third look (same evening, "keep testing"; stopped by the user, who will report when they see it again).
  WoW held ~90% of the GPU through every run, so frame numbers are not usable. Found:
  - Game-thread sampling (tools/profile/threadsample.py, now also prints "active" samples and UE4SS hot spots;
    tools/profile/threadcpu.py = per-thread CPU over a window): under WoW the game thread waits ~85% of the time.
    Of its active samples, UE4SS is on the stack in ~40-45%, with or without the turret swing hook
    (bridge/no_swing_hook skips registering it, test only): the hook is not what costs.
  - Flying with no station visited there was only 1 bot (garrisons spawn when you walk in), so the
    distant-bot animation idea was not testable: wake() sets every bot AlwaysTickPose + URO off. main.lua
    animDistance puts bots past ANIM_FAR 60 m from the camera back on OnlyTickMontagesWhenNotRendered + URO; it is
    OFF unless bridge/anim_far_on exists (not tested with a garrison alive).
  - Test hooks added: bridge/autofly ("<station name>" or "x y z": flies your hull there by AddMovementInput, every
    frame, facing it; untested: both runs' maps had no Navy Outpost in the survey); bridge/map_pin pins the map.
    Space_Solo_01 surveyed only Merchant x2 + Spaceport in one run; Navy Outpost was found in an earlier random map.
  - profile.txt now lists wakes, animSwitch, bots count. bridge/profile_on is ON for the user's next raids.

## Cover map and cover-first fighting (2026-11-13)
- Problem (user): too much strafing in the open; earlier cover attempts sprinted around exposed, and peeks were slow and
  predictable. Causes: random-point cover search (24 random navmesh points rarely sit behind anything), COVER_SEEK_CHANCE
  0.5 / aggression (half the decisions chose the open on purpose), long open-fight strafing, and a hold timer that made
  bots "move" to the spot they were already in (3-60 units away).
- cover.lua (new): bakes cells (1600 x 1600 x 400 floor band) of 100-unit navmesh grid points, each traced in 8
  directions at +100 (crouched eye) and +160 (standing eye) within 90 units: full / low / corner masks (corner = a
  step of 120 sideways is clear and sees 200 past). Visibility channel via LineTraceSingle (LineTraceSingleForObjects
  with an object-type table from Lua hits nothing). Pawn hits ignored. 2 ms per frame, ~47 us per trace; cells around
  you on foot (COVER_BAKE_RADIUS) and around fighting soldiers. Saved per map in cover/<map>.txt (empty cells never
  saved, re-baked after 60 s in case a sublevel wasn't loaded). Spaceport_01 around the spawn: ~2000 points.
- main.lua: findCover tries the 6 best baked spots facing the player (score = distance + low penalty + aggression
  pull towards/away from the player) through probeCover, then a few random points. probeCover tries lean-out steps
  PEEK_STEPS {60,100,140} (60 alone failed 1110 of 1126 baked spots: "no peek"). Seek chance = 0.95 ^ aggression
  (hurt 0.99), OPEN_FIGHT 1.5 s, strafes 100-250 every 2.5-4.5 s. No hold timer (user: no reason to leave cover that
  still works): a spot is left only when flanked or after COVER_BLIND_PEEKS (2) peeks in a row without sight of you,
  then only for a spot >= COVER_MOVE_MIN (300) away, else it stays. No sprinting under 300.
- Status line logs cover stats, fighting samples (hiding/peeking/moving/open in sight/open unseen) and why baked spots
  fail. Test: bridge/cv_test.sh [nobake] (FLANK=1 moves you to a new angle 12-20 m from the nearest soldier every
  12 s via t_flank.lua; t_provoke.lua starts the fight); bridge/cover_nobake = random search only.
- Results (Spaceport, 5 soldiers provoked, 90 s, flanking on): open in sight 12 of ~1100 fighting samples; 37 moves
  (15 angle lost, 10 flanked, 7 move ended short), 25 to baked spots. Random-only with the same new decisions: about the
  same open time, more "flanked" exits (10 of 21 vs 4 of 11 in the comparable run). Most of the open-fight cut comes
  from the decision changes; the bake makes picks reliable and faster. Not checked by eye in play.
- Open: 7 "move ended short" (baked spot maybe unreachable/other floor: filter by path?); minimap.lua:135 errors every
  frame on raid maps (valid(home) with home = false, pre-existing). Next steps from the plan: exposure-scored routes,
  cover-to-cover advancing (the "open unseen" approach samples), reactive peeks (read your aim, keep aim between peeks).

## Stutter found: PGOS friends refresh; mid-flight freeze: pilot names ran out (2026-11-13, ~19:30, live in the user's raid)
- First clean measurement (game in front, no WoW/Roblox, 10 GB RAM free, ~85 fps): 10-13 frame gaps of 50-100 ms per
  10 s while the director tick stayed under 5 ms on almost every frame. Not memory, not our per-frame Lua.
- Cause: a hitch every 1.00 s exactly (~70 ms). External sampling (scratch hitchcatch/walk scripts, same approach as
  tools/profile/threadsample.py plus dbghelp StackWalk64 on the suspended game thread): during each gap the game
  thread blocks in steamclient64 IPC under GAME+0x9590xx (ISteamFriends vtable +0x18/+0x20/+0x30/+0x38/+0x40 =
  GetFriendCount/ByIndex/PersonaState/PersonaName/GamePlayed, "%llu" ids) = native
  SIGISGameInstanceNakama::GetAdditionalSteamFriendsPGOS (thunk 0xa4b760), called from Blueprint
  PgosFriendsPanel_FriendsView_WBP_C:StartGetFriends -> GetSteamFriends. A hook counted StartGetFriends 8x in 8 s,
  no PGOS success/failure callbacks. Driver: native looping FTimerManager timer, rate 1.0 s (InternalSetTimer 0x348fba0,
  handle at panel+0x408, bound at 0x15aa446/0x15b40d0 to 0x15a50d0). Not a named timer (K2_IsTimerActive false).
  The overlay lives on hidden in raids (and the menu), so it hitched everywhere; cost scales with Steam friend count.
- Fix (UNTESTED in game): pvepatch.c `pve_bp_stub_return(UFunction)` turns the BP StartGetFriends stub
  (18 bytes: 46 <ExecuteUbergraph> 1d <1259> 16 04 0b 53) into an immediate Return (bytes checked first); main.lua
  `patchFriendsRefresh` applies it per world. Offline the friends panel only says "social service unavailable".
  Built as native/pvepatch.new.dll (the running game locks pvepatch.dll): rename it over pvepatch.dll with the game
  closed. Verify: profile.txt gaps over 50 ms should drop to ~0 at rest.
- Freeze at 19:38:59 (game Not Responding, one core spinning, memory flat): game thread inside the director's
  ReceiveTick hook in an endless Lua loop. rivals.lua newMember did `repeat name = pick(PILOTS) until not used[name]`;
  PILOTS has 52 names, and this raid had 11 crews + 5 skirmish pairs = 21 crews (~52 people + ship watches). The 6th
  skirmish (SKIRMISH_MAX 6) could never get a name. Fixed: pick from the free names, else a numbered name (Vex2).
- Also seen, not looked into: the director's Lua heap grew 58 MB -> 1.2 GB in 9 minutes of flying (profile.txt
  "lua heap"), ~100 MB/min, with few collections. Turret swing hook ~3500 calls/s. Worth a look before long raids.

## Frame drops to ~50 fps: Lua heap leak + GC stalls, FIXED (2026-11-13, ~20:00-20:25)
- User's raid (19:52, nothing else open, ~85 fps average): the drops were single frames of 190-430 ms, and every one
  lined up with a Lua garbage collection (7 of 9 windows with a collection had a >100 ms gap; 0 of 19 without one).
  The director's heap grew ~10 MB/s in fights to 1.7 GB, and stayed at 2.2 GB in the lobby afterwards.
- Cause: a UE4SS leak. Every UFunction call with an out-parameter (LineTraceSingle's hit result, navmesh projection,
  random reachable point, GetActorBounds, the SweepHitResult of K2_SetActorLocation...) takes a registry reference
  (luaL_ref) to the out table and never releases it: +1 registry slot per call, fresh or reused table, through a full
  collection (bridge/t_reftest3.lua). Cover baking traces thousands of times a second, so every hit result (11
  sub-tables) ever made stayed live; a census (bridge/t_census.lua) showed 484 -> 1503 of them under R/[n] in 2 min.
  Each GC cycle had to mark all of it.
- Fix: outref.lua. `Out.call(obj, "Method", ...)` notes the registry free-list head (registry[3] in Lua 5.4.4, lauxlib
  `freelist`) and length, makes the call, then releases (exactly as luaL_unref) only the new slots holding one of the
  call's table arguments. All ~30 out-param call sites go through it (main.lua uses a global `Out`: it's at the
  200-locals limit). Verified: registry stays at 58 slots, ~48k refs released in 2 min of fighting; live heap 2-3 MB flat
  (was 7 -> 75 MB in the same test, 2 GB in a long raid).
- GC is also driven from the frame now (main.lua `gc`): incremental pause 200, stepmul 400, plus up to 1 ms of
  collectgarbage("step") per frame (3 ms while the heap is over 2x live). Longest single GC step now 1-2 ms (was
  100-430 ms). bridge/gc_gen switches to generational mode (testing only, untested).
- Less garbage: cover.lua reuses its trace argument tables and looks up the engine objects once; animate() keeps each
  bot's Mesh/CharacterMovement on the entry (reapDead clears them); trackTargets reads the foe's location only when it
  sets LastKnownPlayerPosition; the turret swing hook allocates nothing past ctx:get() (UE4SS itself still makes ~1 KB
  per hook call, ~1.5 MB/s in space with ~45 turrets; now plain garbage, not a leak).
- Profiler (bridge/profile_on) now also writes: MB allocated in director ticks vs between them (hooks) and per section,
  GC cycles / live size after the last cycle / time spent stepping / longest step, registry size and refs released.
  bridge/dir_eval.lua (profiler on only): the director runs it once in its own Lua state, result in dir_eval.out.
- Tests: bridge/gc_test2.sh (Spaceport, 8 provoked, flanking), gc_test3.sh (same + census at start/end). WoW was in front
  for all of them (5-45 fps), so no frame-time numbers from these; memory/GC numbers don't depend on that.
  NOT yet seen: a clean-fps raid with the fix (profile.txt "frame gaps over 100 ms" should stay ~0).
- Save/crew restored from backend/state.before-gc-test.json / crew.before-gc-test.lua; folder left online.
- One call site was missed (found 2026-11-15): crew.lua C.tags called ProjectWorldLocationToWidgetPosition (out param
  ScreenPosition) directly, every frame per crewmate on screen. Through Out.call now. Checked in game through the
  bridge, 1,000 calls each way: direct +1,000 registry slots, Out.call +1 (1,000 released).

## Kill list, airlock crew, interiors from space, proportions (2026-11-13, ~20:30-20:55; user report)
- Kill list: the end screen lists your kills from PlayerState.InMatchStats ({StatName, StatAmmount}, +0x410), named by
  BFL_UI_Functionality:Translate_K_ForKillList (kdis): K_AIRaider Raider, K_AICommando Commando, K_AISAS SAS Operative,
  K_AISASCaptain, K_AICommandoMajor, K_AISecurity, K_AIPrisoner, K_AIMiner, K_AIBaron "Red Baron", K_AIMarine, K_AIWarden,
  K_AIRaiderBoss, K_AIBandit, K_AISASMajor, K_AIUACommander; K_Human = "Marauder", the only isPlayerKill (counts for
  AddKillToLeaderBoard). Rivals wear soldier bodies, so they were filed as guards. New killstats.lua: rivals.lua calls
  rivalDied() at a rival's death, update() (end of R.update) moves each new K_* addition to K_Human (pending 3 s; a
  rival killed by your crew files nothing and expires). UE4SS can rename/recount an element but not append (arr[n+1]
  and whole-array assignment both fail): pvepatch `pve_array_grow(TArray addr, elem size)` adds a zeroed element in the
  spare room (Num < Max; first allocation is Max 4), never reallocates. Verified: rename path, increment path, grow path
  (K_AISAS=2, K_AIRaider=1, K_Human=1), and the end screen showed "#4 Marauder". Calling Translate_K_ForKillList from
  the bridge at the splash crashed the game (out params of a BP library function): read bytecode with kdis instead.
- Crew vanishing in the airlock transfer: crew.lua put bodies away whenever rivals.where() was nil, and a station's
  airlock chamber can lie outside its navmesh box (+MATERIALIZE_MARGIN), so mid-transfer they were removed and rebuilt
  3+ s later somewhere near you. Now: playerPlace counts a station's chamber as that station; crew keep their bodies for
  TRANSIT_GRACE 15 s while "nowhere" on foot; standing in a station chamber with a follower > LOCK_BRING 15 m off (still
  aboard), they're put in the chamber behind you (ship side, clamped to the turned box) and walk out with you; arriving
  back aboard your ship, anyone > 15 m off rejoins at once. NOT tested in game (needs hired crew + a real docking cycle).
- Floating geometry: hiding the black shells (2026-11-06) left the interiors themselves exposed. Each interior has a few
  hundred meshes that never cull (CachedMaxDrawDistance 0) and up to ~9000 drawn past 100 m (rest cull at <= 100 m).
  New interiors.lua replaces main.lua's levelShells: per LevelStreamingVolume, shell cubes + the interior level's
  visible meshes with draw distance 0 or > 10000 (not the space map's own level). Camera inside (+1500): all shown at
  once (~67 ms for Navy Outpost's 8.6k, covered by the transfer); outside: hidden 1000 per frame. Space_Solo_01: 53
  shell pieces + 21302 meshes. Verified: from 300 m off Navy Outpost and Fortress only asteroids; camera inside Navy
  28203 visible, back out 20077. Not looked at: the interior by eye right after an airlock transfer.
- Female proportions (user): bust 8.3 -> 7.5, waist width 0.91/0.925 -> 0.93/0.94, depth 0.885/0.915 -> 0.905/0.93,
  seat 3.8 -> 4.5. 113 meshes rebuilt. Not looked at in game.
- native/pvepatch.dll rebuilt (old one: pvepatch.before-kills.dll). Save restored from state.before-kills-test.json; the
  test stand-in stopped; folder left online.

## Crew worth their price (2026-11-13; hire.lua H.profile/H.maxHp, crew.lua, tuning.lua)
- User: even the lowest-level crewmate should fight quite a bit better than enemy AI and have a good deal more health.
  Before: level 1 = the station soldier profile (the weakest enemy), level 4 = rival, 100 + 10 hp a level.
- Now H.profile(level) starts from the LIVE rival profile (difficulty preset and tuning included, so crew stay ahead on
  Very Hard too) and applies hire CFG.EDGE, level 1 -> level 5: miss x0.65 -> x0.4, reaction x0.65 -> x0.35, spot time
  x0.75 -> x0.45, hearing error x0.75 -> x0.45, sight x1.1 -> x1.3, hearing x1.15 -> x1.4, field of view +5 -> +15 deg,
  strafe >= 0.95. Health H.maxHp = BASE_HP 200 + HP_PER_LEVEL 25 a level (300 at 5); rivals/soldiers 100.
- Normal difficulty, offline (lupa): rival miss 0.35, reaction 0.15-0.35; crew L1 miss 0.23, reaction 0.10-0.23, 200 hp;
  L5 miss 0.14, reaction 0.05-0.12, 300 hp. The profile is taken when the body spawns (a preset change mid-raid applies
  to the next body). F3 "Your crew" tab: health at level 1 / per level, and aim/reaction/spotting edge at levels 1 and 5.
- Not yet seen in game: whether Health above 100 survives the game's own healing/med use on a bot (an earlier run showed
  a crewmate at 160 hp, so values over 100 do stick).

## Gear follows your level (2026-11-13; rolls checked offline with lupa, in game 2026-11-15)
- `gearscale.lua`: rivals (`newMember`), station top-up guards and crew kits (`hire.lua` `H.tier`) roll a gear grade
  0..1 = position in each price-sorted gear.lua list. Centre = 0.15 at player level 1 -> 0.80 at `LEVEL_MAX`; 70% of rolls
  land below it (up to 0.35 under), the rest above (squared, up to 0.25), 6% anywhere. Helmet/chest/bag chances rise
  with the grade. Offline at lvl 1 / 20 / 40: budget-mid-geared 93/5/2, 45/51/5, 2/43/55 %; avg gun $1.9k / $4.5k / $8.5k.
- Player level: only the menu controller knows it; main.lua reads `pc:GetPlayersLevel()` every 5 s in the menu and
  writes `config/player_level.txt` ("level max"); raids read that. Cap = last level `GetXPForLevel` still rises at,
  else 40. Default level 1 until the menu has been seen.
- Crew: + `KIT_BIAS` (0.05) per crew level; a promotion never lowers the grade (`r.kitG`). Pool recruits from before
  this get re-kitted once at load; hired crew keep their kit until promoted.
- Off switch: `Rivals.CFG.SCALE_GEAR = false` = old fixed TIERS odds. Raid-map soldiers/guards keep the game's own gear.
- Station top-up guards do NOT follow your level: `adopt` records each placed guard's kit rows (`wornRows`: Weapon/Pistol/
  Helmet/Armour/BackPackToSpawn) and its head + gear meshes before female.lua dresses it. A top-up copies one template
  guard's helmet/chest/bag/pistol rows and meshes (set again in `finishTopUp` once the kit has arrived) and takes a gun
  some guard of that station carries. Unreadable rows -> the old mid-tier roll.
- Level off by one, and level 0 dropped (2026-11-15, tested in game): the game counts from 0 (a new player's lobby
  shows "LVL 0"; GetXPForLevel(0) = 0, (1) = 525, (20) = 29070), so GetPlayersLevel() returned 0 for a new save and
  setLevel ignored it: a new save kept the previous save's level (and its geared enemies), and the dev tree kept the
  tracked config/player_level.txt "8 40". main.lua now passes GetPlayersLevel() + 1; player_level.txt is per-player
  (gitignored, no longer tracked). The XP table keeps rising past 200, so the cap stays LEVEL_MAX 40 (mod levels).
- Checked in game, rolls sampled inside the director (bridge/dir_eval.lua, 4000 GearScale.roll()):
  game LVL 0 -> "player level 1 of 40", centre 0.15: budget 92% / mid 5% / geared 2%, helmet 41%, chest 32%;
  game LVL 20 (XP 29080) -> level 21, centre 0.48: 41 / 52 / 6 %, helmet 59%, chest 54%. Live raid at level 21
  (GearScale.roll wrapped for 3.5 min): 5 new rivals rolled 0.48 0.19 0.35 0.66 0.61 (4 mid, 1 budget).
- F3 "Gear" tab (2026-11-15, after a tester asked for it to be switchable): "Gear follows your level" (Rivals.CFG.SCALE_GEAR,
  now 1/0 instead of true/false: a slider writes numbers, and 0 is true in Lua, so rivals.lua and main.lua's
  rivals_scale test `~= false and ~= 0`), "Typical gear at level 1 / at the top level" (gearscale CFG.TARGET[1]/[2]),
  "Share of people below the typical gear" (DOWN_SHARE) and "Chance of any gear at all" (OUTLIER). Read when a kit is
  rolled, so changes show from the next crews/recruits. Checked in game: the tab draws (169 settings), `set
  Gear:SCALE_GEAR 0` through bridge/menu_toggle -> the director reads 0 (gear no longer follows the level) and
  ai_tuning.txt saves "Gear:SCALE_GEAR=0"; back to 1 removes it. bridge/menu_toggle is only read in raids.

## Share of women (2026-11-13)
- Launcher slider "Female enemies and crew" (0-100 %, steps of 5, default 35) writes `config/female_share.txt` (a percent).
  `Rivals.femaleShare()` reads it into `Rivals.CFG.FEMALE` (default 0.35) at init and every 5 s from `R.update`; used for
  rivals, adopted/top-up station guards, director soldiers (main.lua spawnBot) and new crew recruits (hire.lua). People
  already made (hired crew, the saved recruit pool) keep who they are. Your own character stays the separate toggle.

## Plain wording (2026-11-13)
- Settings text is written for anyone: plain words, units named (cm, seconds, degrees), "1 = normal" style hints.
  Launcher and the F3 menu (now titled "Enemy and crew settings") were rewritten. F3 tabs renamed: Fighting -> Moving,
  Spawns -> How many, Crews -> Rival ships, My presets -> Saved setups; personalities show as Fearless/Reckless/... .
  Saved values are keyed on a tab's `id` (its old name), so config/ai_tuning.txt still loads.
- Fixed: Personalities rows used to share one id per setting (`Personalities:aggression`), so a saved value landed on
  every personality. Now `Personalities:<AI name>:<setting>`; the old id is still read (`stored`, `r.oldId`) from settings,
  presets and `set` commands, and the next save writes the new ids. Checked offline with lupa.

## Station NPCs spread out; live-like spawn counts (2026-11-14)
- User: station NPCs often got into one big fight at once and all died. Cause: every "random" station spot (stationPoint)
  is within 30 m of an airlock or a guard's post, so guards (POST_RADIUS 9 m around where the level put them), crews
  spawning in and crews picking an area to search all ended up in the same few rooms, within PERCEIVE_RANGE (70 m).
- rivals.lua spreadPoint: each station keeps a pool of walkable points (st.spots, up to SPREAD_POOL 160, SPREAD_GROW 4 per
  update) that creeps outward: each new point is searched for SPREAD_STEP 25 m around the earlier point furthest from the
  airlocks/posts (best of 3), kept within SPREAD_REACH 150 m of one. A pick scores SPREAD_TRIES 16 pooled points by distance
  to the nearest other living bot (and where it's headed), plus `visited`, and takes the best.
- Used for: top-up guard spawns (defenderSpot), crews already inside when you arrive (stationSpawnSpots), crews picking a
  new area every ROAM_SECONDS (crewmates excluded, c.searched avoided).
- roamGuards (every update in a garrisoned station): idle station-faction bots (adopted, top-ups, garrison soldiers; not
  crewmates) leave their posts within GUARD_FIRST_ROAM 10 s, then move to a new spread point every GUARD_ROAM 60-150 s,
  walking about within ROAM_PATROL 12 m of it. A bot is tied to the station it was near when first seen (e.roamSt).
- Spawn defaults lowered to a typical live solo raid (estimate, not measured): CREWS 0 (11) -> 5, CREW_SIZE 2-3 -> 1-4,
  MIN_DEFENDERS 14 -> 6 (the levels place 25 across Space_Solo_01's stations, Navy Outpost 7), SKIRMISH_MAX 6 -> 3,
  main.lua GARRISON fallback 14 -> 6. CREWS 0 still means every free slot.
- Not tested in game yet. Look for guards walking away from posts and fewer "spotted ... at N m" lines right after arrival.

## Rivals scraping stations and docking inside hulls (2026-11-14; shipnav.lua, rivals.lua)
- Seen live (asteroid-field raid): a ScoutFrigate rival flew into a station, dragged along its underside, turned, slid into
  its berth and then showed above it. Probably Widowmaker at the Capital Ship (docked 01:29:04 in that run, no stuck or
  lifted lines in the log).
- Cause 1, the scraping: shipnav's obstacle sweeps never hit anything. `SphereTraceSingleForObjects` with an object-type
  list from Lua returns false every time, even through a BlockAll rock (the enum array doesn't get through; cover.lua had
  found this for line traces). The status line always read "detours 0". `ActorsToIgnore` arrays don't get through either:
  only the world-context actor is skipped (bIgnoreSelf). Checked with dir_eval probes: by channel (Visibility, 0) the same
  sweeps hit rocks, the Rebel Base, the Capital Ship node and its turrets, and other ships.
  Fix (shipnav.lua `blocked`): `SphereTraceSingle` on CFG.TRACE_CHANNEL 0, ship as world context; a hit on an actor in the
  ignore list (target, turrets, gun) counts as clear; a sweep that starts touching something counts as blocked only when
  heading into it, so a ship along a hull can still be steered off.
- Cause 2, no idea of the station: the move goes straight to the berth's approach point. rivals.lua `dockRoute`: each
  station berth keeps its node's bounds (`b.hull`: owner GetActorBounds plus the berth; an AI frigate's live bounds).
  A docking ship flies to the lane's entry (out along the approach lane to where it leaves the bounds + HULL_MARGIN 2000),
  going round the bounds' corners/edges/faces when the way is blocked (straight out the nearest face first when it's
  inside them), and only heads for the approach point once it's on the lane (within LANE_WIDTH 1500 of its line, past
  BERTH_APPROACH / 2). The glide in starts only within DOCK_ARRIVE of the approach point AND DOCK_LANE 900 of the lane's
  line, never beside or under the station. Checked offline (lupa, rivals.lua's own functions): from 12 points around
  each of Rebel Base berths 1 and 3, the Capital Ship and the Mini Mine every ship docked without entering the bounds;
  from under the hull it leaves through the nearest face first.
- Cause 3, sitting in the hull: nodes with no berth transform (Capital Ship, Mini Mine, Merchant, Fortress) dock at the
  volume's middle. The Capital Ship's is 1.3 m off the hull's side, beside a rocket turret: a sphere of 500 there
  penetrates the node by about 290, so a ScoutFrigate (bounds 737 x 737 x 600) sat half inside the hull and stuck out of
  its top. A sweep from the docked Bad Penny's middle started inside the Capital Ship node. `clearOfHull` (survey, volume
  berths only) moves the berth sideways along the hit normal, in steps, till a BERTH_CLEAR 500 sphere fits (at most
  BERTH_CLEAR_MAX 3000; height kept; stops at a ship or a floor or roof). Once it's pushed back the way it came (wedged
  between hull and turret), it moves straight out along the lane. Dry run on the live map: the Capital Ship berth moved
  from -101564,17395 to -102132,18815 (15 m out along its lane), its other dock 724, Mini Mine 0. Game berths (ReturnAreaEntranceMoveToLocation: Rebel Base, Spaceport) are
  kept: they put your ship in docking clamps that any sphere overlaps (Rebel Base berth 1: 684 deep, normal straight up).
  Pushing those out would lift ships above their berths.
- The glide and the hold agree: both use berthPose's `at`. Three moored ships measured 0 from it (one 28, under the
  hold's 30 tolerance), with zero velocity and the actor, capsule and mesh all at one point. No Z offset between them;
  station nodes don't move.
- Another way to see a ship jump up: shipnav lifts a ship stuck 3 times 2500 away (up-weighted) when it's NUDGE_FAR
  25000 from your ship, but a trailer camera can be right there. Now it must be that far from your ship and from the
  camera (`S.watchers`: your ship, PlayerCameraManager location).
- In game (01:48-01:51, hot-swapped into the running director, S kept): two leaving ScoutFrigates were sent back in.
  Bad Penny went to the Capital Ship from far out along its lane, never inside the bounds, and the glide started on
  the lane. Moored at the moved berth: 0-1 off in Z, sitting in open space between the station's turret towers, nose to
  the hull. Brass Monkey came at the Rebel Base from behind, took a waypoint round the station, came onto the lane,
  glided in and sat centred in the docking tunnel (dz 0). The steering line went from "detours 0" to "detours 32"
  in 3 minutes. Stucks went on (mostly Grey Mare and Iron Gull, as before the swap: Red Herring was stuck 41 times
  before): not looked into.
- The game process vanished at about 01:51:10, when the raid timer ran out: the log just stops, there's no crash
  report, and the hot-swapped code and two test crews held back from extracting were live. Cause unknown; watch the
  end of the next raid with this code installed.
- Hot-swap tool (scratch, not in the repo): load the new rivals.lua/shipnav.lua with loadfile in dir_eval,
  debug.upvaluejoin every non-function upvalue to the old module's cell (S, X, Nav, CFG...), add new CFG keys to the
  old table (the tuning menu keeps a reference to it), and copy the new functions into the module table.

## TODO: boarder corpse legs explode into spikes (seen 2026-11-14, not investigated)
A Rusty Mule boarder killed on your ship (Space_Alpha, MG42) lay with its legs/feet stretched into a fan of black spikes
(skinned mesh blowing up on the ragdoll). Torso, pack and helmet fine. Probably a rival kit's lower-body part on a body
it doesn't fit, or the ragdoll of a pod-spawned body; check rollKit leg pieces vs the female/male body. Bad for footage.

## Pod breach input lock (2026-11-14, fix untested)
- After a pod breach into the Rusty Mule you could pitch and shoot but not turn or walk. ResetIgnoreInputFlags,
  EnableInput, SetInputMode_GameOnly and SetCinematicMode(false) from the bridge gave back pitch and fire only.
- breachInto now logs which flight-state fields your body still has after the pod ("breach: your body after the pod: ...")
  and clears IsFlyingShip, HelmControlUsing, TurretControlUsing and MYTurret, then resets input and walking mode.
  Check the log line on the next breach to see which one it was.
- Do NOT run bridge/t_props.lua props() on the player pawn or its CharacterMovement: reading every property crashed
  the game outright (05:13:26, no UE4SS error). Read named fields only.

## Stray geometry floating in open space on Space_Solo_02 (user, 2026-11-14; airlocks of absent stations, fixed 2026-11-15)
- Seen from the open middle of the map: long flat girder/hull-like pieces and a dark flat shape, in view from a ship.
  Possibly interior levels at the free interior slots (makeInterior) or station parts out of place; check what actors
  sit there before deciding. Keep it out of trailer shots meanwhile.
- 2026-11-15 (also "dark flat slabs near stations"), still not reproduced. On Space_Charlie the user saw none; there a
  probe found no stray visible meshes and your own ship interior (a level instance, no streaming volume) culls at
  100 m with one far-drawn Cube. Streaming volumes whose interior hiding collects 0 parts (interiors.lua): MoonBaseWhitebox
  and AsteriodWhitebox_1 on Space_Solo_02, NavyOutpost on Space_Alpha, Capital_Ai_Interior_2 on Space_Charlie.
  Those two Solo_02 stations are the likeliest source (their shell/far meshes are never hidden). Next: on Space_Solo_02,
  aim at a slab and list the largest visible meshes in view (material, level, owner, scale, draw distance).
- FOUND (2026-11-15, issue #9): the "0 parts" volumes are stations that aren't on this run's map, and their airlock
  chambers are what floats. Space_Solo_02 picks its stations per run; on a run without the Asteroid Mine its box held only
  36 meshes, all from the space map's own level: six StationAirlockDockingAreaAbility_AsteriodWhitebox2..10 actors
  (RaidFrigateStationDock), each with SM_MERGED_Airlock_01 (MI_Shuttle_Metal_Dark_01, drawn to 72 m), SM_Hangar_
  Computer_01 (100 m) and never-culled meshes. Seen on screen as a dark chamber in open space with more dark slabs
  beyond. interiors.lua leaves the space map's own meshes alone, so nothing hid them. Fix: collect counts each volume's
  meshes from other levels ("foreign"); a volume with none is a station that isn't here, and its RaidFrigateStationDock
  actors are hidden with collision off for the raid. Log: "... N airlocks of absent stations (AsteriodWhitebox_1 0, not
  here: 6 airlocks hidden, ...)". Verified: all six hidden, collision off; the spot shows empty space. Present stations
  keep their airlocks (they are the station's own exterior). Girder-like pieces from the report not separately seen.

## Pod boarding rework (2026-11-14, tested)
- Tested in game: after a pod, your body is fixed by afterPod (log "your body after the pod had yaw=false tick=false
  grav=0.0: walking again"); the old teleport breach and the void rescue both left you able to walk and look.
- PLAYER_BOARD_GAME = true: the game's own breach (F prompt near a hull, or ramming) does the boarding; the mod only
  preloads and pairs the interior as your pod heads for a ship. The old proximity teleport fired the moment a pod
  launched beside a ship pulled alongside. Not yet seen working on a rival: the one try hit a wreck (no interior) and
  the void rescue sent the user home.
- Wrecks (hull shot to 0, crew dead with it) are state "wreck" and boardable while the hull actor exists (hullThere).
  Ships whose crew is wiped out are "derelict" and boardable with or without an interior already in.
- Void wait: the camera looks at the hull you hit (or your own ship) instead of the dark, and the check runs every
  frame. Untested.
- Confirmed in game 05:50: pod + the game's breach into the Long Odds with its interior preloaded; no void, no void
  camera needed, walking and looking fine. User: "it worked perfectly".
- Fixed 2026-11-15 (issue #11): the status line said "you: in space" while the user was inside the Long Odds.
  playerPlace() returns "rival" there, and the status line only knew "ship", a station table, or else "in space". It
  now says "you: aboard the <ship name>" (S.aboard.shipName). Checked by running the expression in lupa for all five
  cases; not re-seen in game (needs a pod boarding of a rival).
- TODO: "no breach point joins up with the inside: boarders come in nearer the middle" fired for the Long Odds.

## Station fights end too fast; AI legs too fast (2026-11-14, fix untested)
- Footage station_fight2.mkv, Moon Base: three rival crews (10) and 8 defenders appeared within 6 s of arriving; two
  crews came out of neighbouring airlocks (Moon_11, Moon_12) at the same moment and fought on the spot. Gunshots carried
  100 m, so every bot heard every fight and went to look. All 10 rivals were dead in two minutes.
- Fix: ARRIVAL_STAGGER (rivals.lua, 45 s): one crew through a station's airlocks at a time. BOT_GUNSHOT_SCALE
  (main.lua, 0.4): bots' own shots carry 40 m; the player's still carry the full GUNSHOT_RANGE.
- Legs: animate() sped the whole body up to 2.4x to match speed (strafing 2.2x, peek steps 450 = 3.4x of the aiming
  walk's 130). User: "very silly rapid leg movement". Now LEG_RATE_MAX = 1.6 caps the rate and holds top speed to
  match, so strafing and peeking are a bit slower. Both new settings are in the AI menu.
- Second cause (station_fight4, Rebel Base, CREWS 0 = 11 crews): three crews that had docked before you arrived all
  materialized in the same update you walked in, before the station's guards were adopted (spreadPoint only avoids
  bodies that exist), and 5 of 7 died within 9 s. Fix: MATERIALIZE_GAP (3 s): one crew at a time, and only once the
  adopt queue, top-ups and every earlier body are done.
- Blue gaps at corners in that footage line up with hitches (18 freezes of 4+ frames a minute with 11 crews, 3 with
  the default 5): after a freeze the view jumps and occlusion culling is a frame behind. Not fixed; fewer crews helps.
- Launch crash at Play (twice, same stack hash, null read): Play pressed before the login reached the stand-in.
  mm_launch.sh now waits for "rpc getbuildinfo" in backend/server.log instead of a fixed 12 s.

## Crews and guards by station size (2026-11-14, untested)
- User: bigger stations should have more people, and fewer crews should go to the small ones. Station size = its
  navmesh box floor area, logged in "[rivals] stations:" (Space_Solo_01: ~4k to ~107k m2).
- chooseStation is a weighted pick: capacity = area / STATION_AREA_PER_CREW (15k m2, at least 1), weight =
  capacity x STATION_CROWD (0.35) ^ (crews docked/heading there / capacity).
- Guards: MIN_DEFENDERS is for a STATION_AREA_MID (35k m2) station; small ones get as few as half, big ones up to
  DEFENDERS_MAX_SCALE (1.5x). STATION_AREA_PER_CREW and STATION_CROWD are in the AI menu.

## Asleep guards at stations you haven't entered (2026-11-14)

The soldiers that stand still with no AI controller, frozen until shot, are the placed guards of a station you haven't walked into yet. That's by design: garrisonStation takes a station's guards over the first time you enter it. On Space_Beta and Space_Delta the volume at about 61000,-5000 is the Asteroid Mine (LevelStreamingVolume_AsteriodWhitebox_1), not part of Moon Base. bridge/t_volnames.lua prints, for each navmesh volume, its streaming volume, its area, and its raiders with and without AI. A "join the station's wing" fix based on the wrong reading went into 21fab81 and was taken out again.
- Messed-up heads under helmets after entering a station (tester report, 2026-11-15): placed NPCs carry a hidden
  second head, DecalMesh_* (always Raider_Head_Skel_01, attached to CharacterMesh0), for blood decals. wake()'s
  `mesh:SetVisibility(true, true)` propagates to it, so every guard adopted on your first visit drew that head over
  its own; a helmet (LeatherCap, Civilian_Helmet...) showed it poking through. Seen live: adopted 10 of 10 with it
  visible, never-adopted 0. wake() now hides DecalMesh* after the propagation; after: 11 adopted, 0 visible.
- Bridge crash to avoid: reading `bot.Helemt.SkeletalMesh` on a bot without a helmet component crashed the game twice
  (AV in UE4SS, not catchable by pcall). Read gear through K2_GetComponentsByClass and check each object first.
- Women's heads (2026-11-16): the DecalMesh fix covers them as is. female.lua dress() swaps the decal head for its HeadF
  copy too, but SetSkeletalMesh leaves visibility alone, and wake() hides it by name whatever mesh it holds. headfit.lua
  (measured on the men's heads) is also safe for women: each HeadF head run through make_female.female_head against
  every helmet, with make_headfit's own test and limits, fits wherever the man's does (never worse; 0-20 more fits per
  helmet). Women share the men's list, so they're kept to the stricter one. Checked offline, not watched in game.
- Still seen after that fix (2026-11-16, user screenshot: skin showing through a woman's gas mask). Live, 3 of 12 awake
  bots (2 men, 1 woman) had the decal head visible again: something after wake() shows the body with propagation once
  more. wake() now also sets SetHiddenInGame(true) on it, which propagation doesn't touch. Checked through the bridge
  on one affected bot: after that, Mesh:SetVisibility(true, true) left it hidden. Not yet watched over a whole raid.
- Streaky "odd texture" on a head (2026-11-16, user screenshot: a woman in goggles and mask under a garrison cap). Not
  the female reshape: the man's version of the same head looked the same. The head was drawing Raider_01_Head_MIC
  (as a MaterialInstanceDynamic the bot made from its starting head) over Outlaw_Head_Skel_01, whose own material is
  Outlaw_Head_01_MIC: wrong textures on the new head's UVs. A spawned raider keeps that MID when rivals.lua or a
  station top-up puts another head on. female.lua's SetSkeletalMesh hook now rebuilds the MID from the new mesh's
  own material on raider bots (the old one had no parameters, so nothing is lost). Live: 1 of 15 bots was wrong,
  0 after; the screenshot showed the proper leather mask. The hook itself takes effect from the next launch.

## Ship stuck after undocking (2026-11-14)

After undocking from Penal Colony on Space_Beta, the player's ship took thrust (CurrentThrust 1) but didn't move. It wasn't disabled: bDocked was false, the controller was the player, and input wasn't ignored. Its CharacterMovement component had simply stopped ticking. Nothing in the mod turns that off, so it's the game's own docking. Turning the tick back on from the bridge freed the ship at once. rivals.lua's keepShipMoving now does this automatically: if you're flying, undocked, and the tick has been off for 2 s, it turns it back on and logs "your ship's movement had stopped ticking after undocking". This isn't tested on a fresh run yet.

The tuning menu also failed to open ("bad argument #2 to 'format' (number expected, got table)"). FLEE_HULL had become a per-crew range { 0.1, 0.25 }, but the menu row still treated it as a single number. It's now two rows, one for each end of the range.

## Guards ignoring your fire while fighting through a wall (2026-11-14)

In Penal Colony a guard kept shooting a rival through a wall while the player shot it. Mid-fight retargeting only looked at foes much closer than the current one (RETARGET_NEAR, RETARGET_RATIO), and only counted rivals and crewmates as "shooting at me", never the player. Now, in main.lua, a soldier that takes damage while its current foe is out of its line of sight turns on the nearest hostile it can see, within PERCEIVE_RANGE. Not tested in game yet.

Kill list check from the same raid: KILLS showed Commando, Commando, Prisoner. Both Commandos were stray guards adopted at 17:36:10, not rivals, so the names were right. A rival you kill is renamed "Marauder" (killstats.lua, logs "[kills] a rival's kill moved").

## Stash capped at 25 rows: the game's grid wraps past 256 cells (2026-11-14)

On a 50-row save, the green drop highlights never lined up, and once (17:45, while the menu was being driven from the bridge) a bag-to-stash drag left copies showing in the bag although the save had the items in the stash. The stash grid widget positions its slots with a byte index. Of the 500 slots, the first 244 sat on rows 25 to 49, on top of the right ones, and rows 0 to 24 had no slot widgets under them. bridge/t_slotmap.lua maps slot index to grid cell. Re-placing the slots from Lua didn't stick: the game re-placed them with the same wrap. Highlights and the space checks look slots up by cell index, so no layout works past 256 cells. Item drops themselves land right, because they come from the mouse position.

Fix: 25 rows at most (250 cells). launcher/saves.py STASH_MAX = 25, and stash_rows() caps saves made when up to 100 was allowed. main.lua caps config/stash_rows.txt at STASH_ROWS_MAX and logs "stash: N rows asked for". Live check after shrinking to 25: 250 slots, none out of place, 26 items kept. A save with items below row 25 would need them moved up first. None of the current saves have any (the lowest is row 21).
- Prestige stash upgrades: DT_PrestigeUnlockInfo rows i1 to i4 (InventorySpace, costs 1 to 4 prestige) each have StashSizeIncrease 0x2: 2 rows, 8 for all four. Owned unlocks are in SIGISPlayerController.PrestigeUnlocks (FStrings). On a 25-row save they would push the stash to 33 rows, past the wrap. main.lua now counts them: rows = min(save rows + 2 x owned, STASH_ROWS_MAX). It rewrites the component size every 2 s in the menu and rebuilds the grid widget when its height differs. It logs "stash: N rows (save S, B prestige upgrade(s))", plus ", capped from X" when it caps. Saves without config/stash_rows.txt are left to the game: 15 + 8 = 23 fits. Buying an upgrade isn't tested yet (no prestige on the test save). It's unknown whether the game adds the rows to the current size or recomputes 15 + 2n; the absolute rewrite covers both.

## Rival crews dying in a heap at one airlock; rivals' edge over station guards (2026-11-14)

Walking into Penal Colony with four crews docked there: the director spawned all of them (8 guard top-ups too) within
ten seconds, each 1-6 m from guards and from each other, and 14 rivals died in about 20 s by one airlock door. Causes:

- A station's spread pool (the walkable points spawns and roaming pick from) starts as a few points by the airlocks and
  grew 4 per update, so on arrival every "far from everyone" pick was in the same few rooms.
- Guard top-ups spawned but not yet armed (S.pendingDefenders) and rival bodies still being built weren't counted as
  "everyone", and crews didn't wait for the top-ups to finish.
- Nothing kept a spawn away from a body that already stood near the best spot.
- Freshly docked crews used the airlock tied to their berth, so successive crews came through the same door.

Fixes (rivals.lua):
- Crews already inside wait until the pool holds SPAWN_POOL_READY (60) points, grown SPAWN_POOL_BURST (16) a update;
  top-ups grow it the same way before picking.
- spreadPoint counts bodies being built and pending top-ups; a crew spawns only SPAWN_CLEAR (20 m) from everyone,
  waiting up to SPAWN_WAIT_MAX (20 s), then takes the best spot and logs
  "[rivals] <crew>: no clear spot in <station> after 20 s, spawning N m from the nearest body".
- Crews don't materialize while top-ups are still arming.
- pickLock: the free airlock used longest ago, not the berth's own.
- STATION_AREA_PER_CREW 15000 -> 25000: big stations count as busy sooner, so crews spread over more of the map.
- The pool grown outward from the airlocks clustered anyway (Asteroid Mine: 112 of its 160 points within 5 m of
  another, the first test's 30 m clearance found 1 of 160), so it's now seeded first from the level's own markers
  (loot spawners, AI start nodes, contract actors) inside the station, spread 208 x 168 m there, and pooled points keep
  SPREAD_GAP (6 m) apart. Look for "[rivals] <station>: spread pool seeded with N points (M candidates)".
- Too many crews in one place: Colony Cruiser (30k m2) is the only station on its map, so 11 crews docked there; walking
  in, all of them spawned inside at once, every one fell back to 10-16 m from someone, and 23 rivals died in about three
  minutes, mostly shooting each other at 2-13 m (guards got about 4). Now at most insideCap crews walk a station at once,
  one per INSIDE_AREA_PER_CREW (10,000 m2, at least INSIDE_MIN 2); the rest wait aboard ("[rivals] <crew> waits aboard:
  <station> already holds N crews") and, as a place frees, come in through the airlock furthest from everyone (their
  berth's chamber if they have one, else the station entry furthest from any body). Waiting crews still undock on time.

Rivals' edge (main.lua CFG, ai.lua perceive's new spotMul): against station guards and soldiers only, never against each
other, you or your crew. A guard aiming at a rival misses EDGE_GUARD_MISS (1.6x) more and spots one EDGE_GUARD_SPOT
(1.8x) slower; a rival aiming at a guard misses EDGE_RIVAL_MISS (0.7x) as much.

Docked ships hidden (rivals.lua showShip, run from glideShips): ships held in a berth showed wedged into the airlock
frame, and breached-in crews' ships (no free berth) idled in a clump at their hold points while Colony Cruiser flew on.
A docked ship and its turrets are now hidden with collision off from the end of the glide in until it glides out,
leaves, or you're aboard it. Trade-off: you can no longer see a docked rival ship to pod-breach it and raid its watch.

Tested (2026-11-14, Moon Base, 3 crews): pool seeded with 36 points (69 candidates); no "no clear spot" fallbacks; the
two late crews came in through different airlocks (Moon_7, Moon_8); docked ships read bHidden. The cap didn't trigger
there (Moon Base allows 10); the "waits aboard" path is untested in game.

Performance: on Colony Cruiser with 27 bots inside the director ran over 5 ms on 416 of 433 frames in 10 s (aim 1.2 s,
update 1.1 s, cover 0.9 s and 64 MB allocated, single FindAllOf calls ~55 ms); the user saw ~20 fps with stutters. With
~20 bots at Moon Base it's 64-80 fps, still over 5 ms on a third of frames. Per-bot aim and cover cost is the next thing
to cut.

Also seen this session: the load crash at RaidGame+0x1a605d0 (UE4SS hook dispatch, see 2026-11-09) again, once, loading
Space_Charlie after a bridge launch; the relaunch was fine.

## Director frame cost: perception, garbage collector, far animation, stray sweep (2026-11-14, tested)

Follow-up to the Colony Cruiser numbers above (27 bots, ~20 fps with stutters):
- ai.lua AI.perceive: the target's velocity, facing, crouch and address are read once per body record (targetInfo), and
  the bot's own position and facing once per frame, instead of again for every check (each read is an engine call and
  garbage).
- main.lua gc.frame: incremental collection only starts once the heap is gc.START (1.25x) over the live size after the
  last cycle, instead of stepping every frame. The stepping went from ~2480 ms to ~360-500 ms per 10 s.
- main.lua trackTargets: bots that aren't fighting and are over ANIM_SLOW_FAR (4000) from the camera animate at
  ANIM_SLOW_HZ (10) instead of every frame. animate() reads crouch and targeting once.
- main.lua updateBots: the soldier's log name is built only when a line is logged.
- rivals.lua sweepStrays: one PLACED class per pass in rotation (~43 ms) instead of all of them (~100 ms).

Tested (Space_Alpha, Rebel Base, 8-11 bots, recording at the same time): 100-130 fps inside the station (88-92 at Moon
Base with 11 bots before, without recording); the user says it seemed good. Still there: a one-off hitch on entering a
station (worst frame 212 ms, the entry FindAllOf scans). Not yet tried with 20-27 bots.
- Station entry (issue #12, 2026-11-15; Space_Beta, teleported on foot into the Asteroid Mine, profiler on): the entry
  window had 9 FindAllOf (~480 ms): SIGISContractActor, SIGISLootSingleSpawner and RaidAINodeStart twice each (rivals.lua
  seedSpots and main.lua Aux.rescan scan the same classes within a second), RaidUseableAirLockComponent, and the two
  CFG.PLACED classes (placedDefenders). Worst director update 368 ms (rivals 286), interior show-all 148 ms.
  Now: Aux.findAll caches a class's FindAllOf for 3 s per world, used by Aux.scan and (as X.findAll) seedSpots; and
  placedDefenders takes the NodeBots spawn hook's list when it's on ("6 ... from the spawn hook"; the cross-check log
  had shown 6 = 6), FindAllOf only as the fallback. After: 4 scans (~195 ms), worst update 255 ms (rivals 177); same 6
  adopted, same 108 spread candidates, same marker counts. Left: the interior show-all (148-160 ms, I.frame shows
  every part at once by design: the airlock transfer covers it); when it lands in the same frame as the garrison update
  the frame is ~460 ms. Spreading the show over frames would trade that for a visible pop-in after a transfer.

## Baked cover never used inside Rebel Base; soldiers out of sight backpedal (2026-11-14, fix untested)

Watching the footage, the user saw a soldier slowly backstrafing that never went for cover. In the log, every cover pick
that raid was "random", and the baked-spot probe count stopped at 39 (all "no peek") after 18:49:15, so no baked spot
was even tried for the rest of the raid, with 6978 baked points on the map. From 18:51:36 to 18:52:16 the two fighting
soldiers spent every sample "open unseen": fighting a target their LineOfSightTo said they couldn't see.
- Likely why baked spots were dropped: findCover filters baked candidates with offLimits, and offLimits treats a point
  inside a station's box as off limits unless a play marker (loot spawner, contract object, AI node, airlock) is within
  18 m. mapPlayAreas scans for markers once, when the raid is ready, while you're still 430 m out; Rebel Base streams in
  later, so its loot and AI nodes may be missing. Random cover points skip offLimits, which is why those still worked.
  Not confirmed: check how many markers mapPlayAreas found per station box.
- Out of sight, probeCover can't find a spot either: it needs a step out that sees the target, and nothing nearby does.
  So the soldier fights in the open, walking to a random point within ADVANCE_RADIUS (400) of where it last saw its
  target while keeping its focus on the target. When that point is behind it, it's a slow walk backwards.
- The "no cover" and "chose not to" paths log nothing, which is why this was hard to see.
Fix (main.lua, untested in game):
- mapPlayAreas counts loot, contract and AI-node markers per station box and logs "play areas: markers per station
  box: ...". offLimits treats a box with none as unmapped and rules nothing out in it.
- Aux.rescan: the first time you're on foot inside a station box, the markers are scanned again, one class per frame,
  and the new map swapped in: "play areas: rescanned on boarding <station>: ...".
- Open fights are logged, per soldier at most every OPEN_LOG_SECONDS (10): "<bot> fighting in the open: <why>, in
  sight / target unseen (baked N, off N, out of range N, no peek N, random N, random no peek N, ...)". Reasons: chose not
  to look for cover, no cover found, nearest cover too far to run in sight. The status line adds "| open fights: ...".
- Out of sight, a soldier picks the nearest of 3 points around the last-seen spot and moves only if that's at least 1 m
  nearer than where it stands; otherwise it holds and watches.
To check: the per-box counts at raid start and after boarding, whether "cover probes of baked spots" keeps rising
inside the station, and "sprinting to baked ..." lines.
First test (Space_Solo_02, Penal Colony, 2026-11-14): at raid start Asteroid and Moon Base boxes had 0 markers (so the
problem is real); the rescan on boarding ran ("rescanned on boarding PenalColony"). 9 of 53 cover picks were baked
(none the raid before), but most searches still dropped every baked spot as off limits ("baked 40, off 40"). The floor
being fought on had no loot or AI node within 18 m on its level (nearest ~12 m higher), so offLimits ruled the whole
floor out though the soldiers stood on it. Fix: findCover only filters baked spots by offLimits when the soldier's own
spot passes it (untested). bridge/t_off.lua checks the rule on baked spots around the player.

## Fight hitches and garbage: stray sweep, turret swing hook, per-frame aim (2026-11-14, untested)
Space_Solo_02 at Penal Colony and Moon Base, 17-21 bots. profile.txt showed a ~50 ms FindAllOf every stray sweep (a
steady hitch every few seconds). The Lua collector was stepping 0.5-2.4 s per 10 s, fed by the aim section (~31-34 MB per
10 s, 1.2-1.3 s of Lua) and by hook garbage between ticks (54-75 MB per 10 s, with ~50k turret swing hook calls).
- rivals.lua: placed NPCs come from a NotifyOnNewObject hook on /Script/RaidGame.RaidNodeBot (NodeBots, hookedPlaced).
  The stray sweep no longer calls FindAllOf; without the hook it falls back to the old one-class-per-sweep scan. The
  garrison sweep keeps its FindAllOf and logs "spawn hook knows N live placed NPC(s) in the box, FindAllOf found M
  unmanaged" as a cross-check.
- rivals.lua: the turret CameraRotation hooks come off after SWING_UNHOOK_AFTER (5) s with no turret aimed
  (swingHooksIdle, "turret swing hook(s) off"); aimTurret registers them again.
- main.lua: animate() and the aim upkeep (targeting pose, focus) run ANIM_HZ (30) times a second per bot instead of
  every frame; a change in what the bot should do applies at once. Hide/peek timing is still checked every frame.

## Every baked cover spot "off limits": integer vs float cell keys (2026-11-14, fix untested)
After 12ffc4a soldiers in Rebel Base (Space_Alpha, 101 markers) still fought in the open: every cover search logged
"baked 40, off 40". bridge/t_off2.lua ran the same rule from the bridge on one of those soldiers: all 97 baked spots
near it passed. The difference was the play-area cell key: offLimits built it with //, which gives a float for a float
("26.0", the engine's marker and soldier positions) and an integer for an integer ("26", baked spots loaded from
cover/*.txt). Baked spots never found their markers. Both keys now use math.floor (an integer either way).

## Soldiers backpedalling instead of taking cover (2026-11-14)

In a Space_Beta fight a soldier mostly walked backwards away from the player and rarely reached cover. The log showed
"firing on the way to ... cover ~600-800 away" followed seconds later by "left cover (move ended 500-2278 short)", and
the fighting samples were mostly "moving" (335) against hiding 17. Two causes:

- Walking to cover keeps the focus on the enemy so it can shoot on the way. For a spot behind the soldier that's a
  backwards walk, and backwards is capped at the strafe factor (~0.6) on top of the aiming slowdown: a slow backpedal.
  Now a spot whose direction is more than ~107 degrees from the enemy (cosine below -COVER_BACK_RUN, 0.3) and farther
  than COVER_MOVE_MIN is run to, weapon down ("turning to run back to ... cover").
- Moves to cover ended early (the tree, or the stuck check's StopMovement) and the soldier dropped the spot and
  started over. Now the move is sent again up to COVER_MOVE_RETRIES (2) times while it still gains 100+ units
  ("move to cover ended N short: sent again", with "(stuck)" when the stuck check stopped it).

## Cover a long walk away; melee soldiers swinging at nothing (2026-11-14)

Cover on Space_Beta was still rare. One soldier was "sprinting to baked lean-right cover 611 away" and "move ended
2727 short" six seconds later: the spot was near in a straight line but the navmesh route went round through other
rooms, so he ran away from the fight. findCover now asks the navigation system for the walk's length
(FindPathToLocationSynchronously, about 1 ms) on the spot it picks, and skips it when the path is partial or longer
than COVER_PATH_STRETCH (1.8) x the straight line + COVER_PATH_SLACK (300). These show as "long way round" (baked)
and "random long way round" in the probe counts and "fighting in the open" lines.

Knife and truncheon soldiers (weapons under Weap_Knife_C; Penal Colony top-ups copy guards that carry them) got the
gunman's hints: cover and strafing, with an Enemy set, and the tree swings at its Enemy at any range. They walked
around swinging at the air. Aux.isMelee walks the held weapon's class chain (cached per weapon); Aux.meleeHints makes
them charge the target (or where it was last seen), running past MELEE_RUN (450), with no Enemy set (setEnemy returns
early) until within MELEE_REACH (230), and it lets go past MELEE_LET_GO (330).

## Stuck in a shaft after docking at Fortress by pod (2026-11-14)

Flying a pod into Fortress's docking arm put the player at the game's Pod_Spawner_Fortress6 (57354,119225,-914), inside
a sealed vertical shaft between two decks (rounded wall pieces from -1179 up to a lid at -745; no navmesh at that level;
floors at -1532 below). The body was also still parked for the flight: CharacterMovement not ticking, so "falling"
with no velocity. afterPod only ran after a pod brought you into a rival's ship. Fixed live from the bridge: moved
to the floor below and unparked the body (afterPod's steps).

playerBoarding now runs podExitCheck POD_EXIT_CHECK (1.5 s) after any other pod exit (not in the void, which
rescueFromVoid handles): no navmesh under your feet means a search downwards (then around) for floor and a move there
("out of the pod with no floor under you at ...: moved to the floor at ..."), and a parked body gets afterPod
("your body after the pod had ...: walking again").

Crew prices halved for testing how useful crew are: hire fee 500/1250/2500/4500/7500 and wage 150/300/500/800/1250 a raid
by level (were 1000/2500/5000/9000/15000 and 300/600/1000/1600/2500). hire.lua CFG.FEE / CFG.WAGE.

Faster into the lobby and raids (user report 2026-11-16): the PGOS social overlay scan runs every 1 s for a map's first
30 s (was every 10 s; it sat over the fresh lobby up to 10 s); test found it 5.5 s in. MM_SEARCH_SECONDS 4 -> 1, LOAD_TIME_DILATION
10 -> 20 (engine cap). Start to aboard went from ~22 s to ~18 s (Space_Charlie 18 s, Space_Beta 18 s); rivals launched normally.

Shotguns (user report 2026-11-16): the player's shotgun did nothing offline. FireWeapon (0x1884b80) handles guns with a
pellet count (+0x460 > 0) apart: when MyPawn is a RaidBot or RaidNodeBot (0x188f3a0) each pellet is traced and damaged on
the server (0x1895dc0), so soldiers, rival bodies (GOAPNodeBot) and crew should be fine; every other pawn, the player
included, goes to the multi-pellet client trace 0x18a1990, which traces the pellets, spawns their impacts (0x18a1c70) and
sends ServerTraceFireProjectiles, but starts `cmp byte [rcx+0xF0],3 ; jae return` (OFFLINE_AUDIT item 6). Offline the
player's pellets were never traced. Fix: pvepatch "Shotgun pellets trace RPC" NOPs that jae (0x18a19be), like the
single-shot "FireWeapon trace RPC". Found by static disassembly of the exe. Tested in game
2026-11-16 (bridge/t_sgive.lua hands a TrenchShotgun, bridge/t_sshoot.lua aims and fires): patch applied 21/21, one
shell at 4 m took a raider from 100 HP to dead (clip 30 to 29). Impact FX not checked by eye. Bot shotgun pellets get no impact FX (0x1895dc0
never calls 0x18a1c70); not fixed.

## Missing prompts, salvage, objective sounds (2026-11-16)
User report: interaction prompts (contracts, doors) missing; objective sounds repeat before an objective is done;
space salvaging doesn't work.
- **Hidden main HUD (fixed in main.lua ensureHud, needs a play-test)**: two SIGIS_HUDOverlay_C are in the viewport:
  the director's own (made early for the loadout, then Collapsed) and the game's "In Game Overlay Match". But
  MatchHUD_C.HUD_Widget (the HUD_Main_Widget every prompt goes to: Show_Interact_Prompt, SetAbleToDockPrompt, the
  frigate panel Border_FrigateHUD) still pointed at the one inside OUR collapsed overlay, so prompts were set on an
  invisible widget. ensureHud now also sets hud.HUD_Widget = hud.InGameOverlay.HUD_Main_Widget when it collapses ours
  (retries until that widget exists). Verified live by repointing it by hand: frigate panel and "KEY: SALVAGE" showed.
  Probably also the cause of the missing door prompts (doors tested earlier "had prompts" only because the probe read
  the hidden widget's state). Probes: bridge/t_hudp.lua (border parent chain), t_hudref.lua / t_hudref2.lua.
- **Salvage (fixed, pvepatch "Salvage scan timer a/b/c")**: RaidFrigate BeginPlay (0x1824550) only starts the looping
  salvage-scan timer (0x182e430: 1500-unit trace, wreck kept at frigate+0xD08, SalvageEvent -> CheckifAbleToDock ->
  HUD SetAbleToDockPrompt) on the non-Authority branch (0x18246a1). The three Authority exits now jump there.
  Salvage key = R (InputSettings action "Salvage"; key handler 0x1838f90 -> ServerOnSalvage 0x183d4c0 -> 0x185e800,
  spawns DefaultShipInsideSalvage in the interior). Verified in Space_Solo_01: R took a wreck aboard (SalvageFull,
  Industrial_InsideSalvage_01_C spawned in the hold). Not yet tested: looting it, unloading (0x182e990).
  OnSpaceSalvageChange (from OnRep_HasSpaceSavage) has no Blueprint implementation, so nothing lost there.
- **Contract inspect prompt (pvepatch "Contract inspect prompt")**: ShouldShowContractInteraction (0x8fc9c0)
  `jae` at 0x8fc9f6 NOPed so InteractionDetection offers inspect objects. Patch applies (25/25 on a fresh launch);
  the on-screen prompt is not yet seen (also depended on the HUD fix above).
- **Objective sounds (NOT fixed)**: MainPlayerController_C OnUpDateMission / OnUpDateChapterMission play the
  Completed cue when progress == max; Inspect (type 5) plays the progress cue on every +1; native IncrementMission
  (0x9ca2c0) fires the event only when it increments. Suspects: (1) with two HUD overlays alive, a widget-played cue
  plays twice (both HUD_Main_Widget copies get mission updates); (2) missions.lua re-sending Client_CheckMissionEvent
  for inspects while Use is held; (3) both bInMissionVolume and bInChapterVolume set together. Probe
  bridge/t_mis.lua logs both events. CAUTION: hooking GameplayStatics:PlaySound2D/SpawnSound2D from Lua and then
  calling pc:OnUpDateMission crashed the game (AV inside UE4SS's hook; probe t_snd.lua, don't reuse as is).
- Bridge tips: globals set in a bridge command don't reach a dofile'd script; pass args with
  `pcall(loadfile("<absolute path>"), a, b)` (relative paths fail). Read widget `.Visibility` instead of calling
  GetVisibility (errors as "function: 0x..." on some instances).

## Quit Game in the pause menu (2026-11-16, tested in a raid; mods/PvEDirector/Scripts/quit.lua)
Testers had no way to quit from inside the game and force-closed it. SIGIS_Exit_Widget_C (Esc in a raid) has Resume,
Guide, Report Abuse, Settings and Main Menu. Its EXIT button belongs to the "are you sure?" panel behind Main Menu and
leaves the raid. Its REPORT BUG button is collapsed and opens a web page.
- A QUIT GAME button is added under Main Menu the first time each menu opens: a new MM_GenericSmallBtn01 (Main Menu's
  class) in a new SizeBox, appended to VerticalBox_161. The button gets Main Menu's designer variables (WidthOverride
  200, HeightOverride 35, b_TexOnlyVersion, fill material, opacities, sounds), then PreConstruct(false) again. The slot
  gets Main Menu's padding (top 10) and centre alignment. Struct copies need a plain Lua table: passing `from.Padding`
  failed silently. Border_MainMenuOptions sits in a canvas with a fixed size (290 x 341.6), so it grows by one row
  (+50) with SetSize.
- The hook on ExitMenu_Open must be a pre-callback. Its post-callback never ran (counted pre 1, post 0). The widgets
  already exist in pre.
- Clicks: UMG delegates can't be bound from Lua, so Btn_Main:IsPressed() is polled from the director's tick while the
  menu is visible, and a release counts as a click. The first click relabels the button "CLICK AGAIN TO QUIT" for 4 s.
  In a raid it also sends a ClientMessage saying the gear you brought in counts as lost. That message is not seen
  behind the menu; Alt+F4 loses it the same way. A second click within 4 s calls
  KismetSystemLibrary:QuitGame(pc, pc, Quit, false).
- Tested on Space_Solo_01 with real mouse clicks. The button looks like the others. Click 1 armed it, and it was back
  to QUIT GAME after 4 s. Clicks 1 and 2, 1 s apart, logged "quit: Quit Game from the pause menu" and the process
  exited with no crash reporter. Synthetic clicks need a real mouse move over the button (SetCursorPos alone isn't
  hovered by Slate).
- The lobby has no Esc menu: MenuPlayerController's InGameMenu action opens nothing. SIGIS_MainOverlay_C has an
  MM_SecondaryOptionsBtn_Exit, but it is inside Border_BottomBar_Old, which is collapsed. That's a possible follow-up.
