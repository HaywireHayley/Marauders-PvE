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
- `docs/internals/`: how the game works inside, read out of the running game: chains of calls with flowcharts, number
  tables, what is still unknown (index: `docs/README.md`). Start there before probing a system again; the research log
  with the reasoning stays in this file.
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

- Esc and lean with the inventory open (2026-11-16, issues #60/#61; invkeys.lua). There's no "inventory open" flag:
  between open and closed only pc.bShowMouseCursor / bEnableClickEvents / bEnableMouseOverEvents change (property diff
  of controller, pawn and both SIGIS_HUDOverlay_C). It counts as open when the cursor is shown with neither the pause
  menu (SIGIS_Exit_Widget_C IsInViewport and IsVisible; its .Visibility reads 4 even when closed) nor F3/F6/F9 up.
  Esc = MainPlayerController_C InpActEvt_InGameMenu_K2Node_InputActionEvent_3: it opened the pause menu behind the
  inventory. UE4SS runs the "pre" callback of this input event after the event's Blueprint body (a probe at the
  first press, nothing open, already saw the menu up and the cursor on), so the hook reads the previous frame's
  state; the tick then calls CloseTheMenu once the menu is up, and SIGISPlayerController:CloseInventory on the
  frame after (inside the key press it didn't stick). The hook is re-registered when the UFunction's address changes:
  the controller Blueprint is loaded again for each raid map, and a hook placed in the lobby never fired in the raid.
  Lean: RaidCharacter.Lean (0/1/2) is zeroed with RaidCharacter:ZeroLean while the inventory is open.
  Tested with real keys (Space_Solo_02): Tab+Esc -> inventory closed, no menu; Esc -> menu; Esc -> closed; Tab+hold Q
  -> Lean 0; hold Q with nothing open -> Lean 1.

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

- 2026-11-22 (build/native-ci): build.sh now builds every shipped DLL: `build.sh pvepatch|pvenet|pvenative|all
  [suffix] [outdir]` (`build.sh 2` still means pvenative2). pvepatch.dll and pvenet.dll had no recorded build line.
  Verified: WinLibs x86_64-w64-mingw32-gcc builds all three; the rebuilt pvepatch.dll (16 exports) and pvenet.dll (no
  exports, loaded with "*") have the same export and import-DLL lists as the committed ones (objdump -p); pvenet needs
  only `-lws2_32` (WinHTTP goes through the import tables it patches). Not verified: byte-identical output, or the
  rebuilt DLLs in game (the committed ones were not replaced). CI (check.yml) now cross-compiles all three on ubuntu.
- 2026-11-22 (refactor/native-audit, stacked on #375): audit of the shipped native files. Shared helpers moved to
  `native/pvecommon.h` (pve_readable, pve_project_dir, PVE_COUNT). pvenet: path/log snprintf truncation checked (the
  -Wformat-truncation warnings are gone), sprintf/strcpy replaced, malloc/realloc/calloc and VirtualProtect results
  checked (a failed allocation now passes the call through untracked instead of crashing), pvenet.log writes all go
  through the lock, EnumProcessModules count clamped, thread handle closed, start() stops early if the project or game
  folder path is unreadable (before: an empty game path matched every module). pvepatch: the bridge path no longer uses
  strcat, stub allocation/call writing deduplicated (allocNear, writeCall), duplicate constants merged, object-array
  layout named; patch table offsets and bytes unchanged (diff checked). pvenative: custom fill names no longer leak.
  Verified: all three build with -Wall -Wextra and no warnings; objdump -p export names and import DLLs equal the
  committed pvepatch.dll/pvenet.dll (and a build of the old pvenative.c), so the rebuilt pvepatch.dll and pvenet.dll
  were committed. Not verified: anything in game. Left: Conn/Cb lists in pvenet are never freed (closing callbacks
  arrive after WinHttpCloseHandle, so freeing them on close could lose the HANDLE_CLOSING callback; small and bounded).
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
  - 2026-11-24 (#458): the lobby news (public `titleNews`, "title!DEL!body") is rewritten at every stand-in start by
    `set_news()` from version.txt (release only; dev falls back to the changelog heading) and the newest CHANGELOG.md
    section's first 4 bullets, plain text, plus a key tip; `titleNewsImage` (was "youtube-embed-url!DEL!caption") becomes
    "!DEL!". Seed text stays if CHANGELOG.md can't be read; the release now ships CHANGELOG.md. Tested by
    tools/test_standin_flow.py only; NOT checked in game (does "\n" break lines? does an empty embed URL show blank?).
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

- **What else the game reaches offline (2026-11-18).** Menu plus a Space_Alpha raid, capture_on, pvenet.log and the
  WinHTTP log. pvenet only blocked raw DNS lookups (getaddrinfo & co.); WinHTTP resolves inside winhttp.dll, so a
  WinHTTP host other than Nakama went **live**: sentry.dll posted a session envelope (`{"type":"session",
  "status":"abnormal"...}`, 314 bytes) to o293983.ingest.sentry.io and got 200. Fix: offline, pvenet sends every
  non-local WinHTTP host to the stand-in, others as `/_ext/<host>/<path>`; the stand-in answers `{}` and counts them in
  coverage.json under "other services". Verified: the envelope arrives as `/_ext/o293983.ingest.sentry.io/api/.../envelope/`,
  answered, counted. Blocked lookups (raw sockets, still blocked, nothing needs them so far): api.gameanalytics.com from
  the exe every ~8 s (analytics over its own TLS stack: redirecting it would need a fake certificate, not worth it), and
  marauderea2...nakamacloud.io from nakama-cpp.dll (the realtime socket: parties, matchmaker, notifications; the mod
  does matchmaking itself). Not seen this run: Vivox, EOS, the AWS GraphQL ApiUrl, the PGOS overlay (libcef). Those
  modules are hooked, so a lookup would show in pvenet.log; matchmaking through the lobby button wasn't exercised.
  pvenet.log only exists if a capture/ folder does.
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
- Gear back from raids that end without extraction or death (2026-11-16, issue #49, Hayley's option 2): the stand-in
  keeps what a raid took out of the stash as state.raid_out {items, ended}. ship_lost.txt (death, or out on foot /
  by pod) and ship_gate.txt = 1 (into a space gate) mark it ended; = 0 (back out of the gate) unmarks it. If it isn't
  ended, return_unfinished_raid() puts the items back (same keys, still equipped) when the stand-in starts, at the
  next login (/v2/account/authenticate), or when the next raid starts: QUIT GAME, Alt+F4, a crash or leaving through
  the menu. Loot picked up in that raid is lost. The raid QUIT GAME warning says so now.
  Tested: equipped Stahlhelm + 1911 by drag -> raid start "took ['99255929', '68933336']" -> QuitGame mid-raid -> next
  login "raid ended without an extraction or death (login): [...] back in the stash", both still equipped on the
  Loadout screen. Death (ApplyDamage on your pawn) -> "ship lost", raid_out ended -> next login returned nothing.
  Editing equip flags into state.json by hand didn't reach the raid: the game's first lobby load re-saves the stash.

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

- 2026-11-25 (#390): raid summary in the lobby after a raid (raidsummary.lua, feature RAID_SUMMARY): outcome (extracted:
  `raid.extractedAt` was set; died: on-foot pawn Health <= 0), map, time, kills by kind from InMatchStats K_* (read every
  2 s), crew that came (hire.raidCrew at raid start) and died (hire.died), and missions.version() as "contract/chapter
  events". The tally is plain Lua module state carried over the travel (the director's Lua state survives it, as
  hire.lua's D.raid does) and closed on the first lobby frame; panel = deathscreen.lua's layout, 12 s or Esc, plus a
  "raid summary:" log line. Not counted: loot out vs in, ship deaths in space. NOT tested in game.

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
- 2026-11-16 (issue #55): offline the button reads START RAID (lobbylabel.lua). The label is TextBlock_31 of
  Crew_LaunchToMatchBtn_SubWidget_C (Captain and Crewmember copies), with no variable of its own;
  UWidgetTree::FindWidget isn't callable from Lua, so it's found as StaticFindObject("<button path>.WidgetTree.TextBlock_31").
  Paths are kept, not objects, and looked up again each second. It's set again whenever it
  differs (in case the game rewrites it). Text_CoreState (CANCEL MATCHMAKING, shown for the 1 s "search") is left alone. Tested: "lobby: launch
  button relabelled START RAID (2)" at boot; a raid starts from it as before.
- Lobby QUIT tab (2026-11-16, issue #50): quit.lua adds a tab of the top bar's own kind (MM_CoreMM_TabBtns_C,
  WidthToUse/HeightToUse from SOCIAL, Which_CoreMenuState 99 so the bar never selects it) to HorizontalBox_Core_MM_Tabs
  after SOCIAL; it lays itself out. Same click-twice confirm ("SURE?"), then QuitGame. A button added to the
  overlay's MainCanvas didn't show (CanvasPanelSlot:SetAnchors with a Lua table was ignored, the position landed off
  screen), and probing that canvas crashed the game: calling a method on a null UObject wrapper (a root canvas's
  .Slot) is an access violation inside UE4SS that pcall can't catch, so check IsValid() before every call there.
- quit.lua keeps both menus' widgets as object paths now, not objects (the pause menu's were held across raids and
  checked with IsValid each frame after a map change). hire.lua H.reset() also clears the tick controller
  (H.lastPc): quit.lua and invkeys.lua ask for it before the frame's H.tick, so on a new world's first frame they got
  the old world's controller. (tickPc was declared below H.reset; moved up so the reset clears the real local.)
- Tested: lobby "QUIT tab added", one click -> SURE?, two clicks -> "Quit Game from the lobby", the game exited, no
  crash reporter; same boot through a raid: pause menu QUIT GAME -> CLICK AGAIN TO QUIT -> quit.
- Choosing the map (2026-11-16, issue #54; mappick.lua): the lobby's REGION picker (Crew_MatchmakingTypeSelect_Widget,
  WrapBox_RegionList) holds six SIGIS_MatchmakingRegion_Subwidget_C, region 1..5 and 0 (USA WEST, USA SOUTH, EU
  CENTRAL, ASIA NORTH, ASIA SOUTH, USA EAST) -> SOLO 1, SOLO 2, ALPHA, BETA, CHARLIE, DELTA, plus a RANDOM button of
  the same class (region 99) added to the WrapBox. Findings: the game re-creates the six each time the picker opens
  (the old ones stay valid, hidden), so new ones are caught with NotifyOnNewObject and dressed on the next frame;
  it disables "bad ping" regions and offline every ping is 999, so only two were clickable (Btn_MatchmakingSetting /
  widget SetIsEnabled(true)); the ping row "(999ms)" is a HorizontalBox around Txt_PingValue (collapsed); a click on
  the region already selected doesn't fire, hence the RANDOM button; the choice is stored in
  SIGISGameInstancePGOS.ActiveMMRegion, whose default 0 can't mean "untouched", so the click is read from a hook on
  the button's own BndEvt ... OnButtonPressedEvent instead. RANDOM closes the picker itself
  (Crew_MatchmakingTypeSelect_Widget_C:FORCE_CLOSE_MatchmakingAndRegionSelect: the game's buttons close it through a
  delegate their parent binds). The box (SIGIS_MenuMain Txt_PGOS_Matchmaking_WhichRegion and _CrewMember) and the
  settings widgets' copies show the pick or RANDOM MAP. onStartMatchmaking uses PveMapPick.map() before map_pin.
  Lua pitfall hit: `(a == b) and nil or c` is always c. Tested: ALPHA picked -> raid on Space_Alpha; remembered over
  a restart ([ CHARLIE ], box CHARLIE); RANDOM -> picker closed, box RANDOM MAP, config/raid_map.txt removed; BETA ->
  raid on Space_Beta.
  Details (2026-11-16, later): each button shows "solo map" / "crew map" in its ping row (its "(" and "ms)"
  emptied) and a hover tooltip, UMG's own (UserWidget:SetToolTipText, set once per button address): the map, its kind
  and the stations seen there (from the "[rivals] stations:" log lines and the NOTES survey); RANDOM's says it picks
  any of the six. Checked: tooltip shown on hover over CHARLIE, three lines.

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
- Gunshot range by calibre and suppressor (#317 first pass, 2026-11-21, NOT tested in game): the shot radius was one flat
  CFG.GUNSHOT_RANGE (x BOT_GUNSHOT_SCALE for bots), not per weapon class as AI_DESIGN says. ai.lua AI.gunshotRadius(gun, base,
  strength, suppMul), called from the ServerMultiSimulateWeaponFire hook, multiplies by CALIBRE_MUL[gun.BulletType]
  (EBulletType order of loadout.lua AMMO_ROWS: 12ga 1.1, .30-06 1.25, .32 0.6, .45 0.75, 9mm 0.7, 10mm 0.8, 7.62 1.3, 7.62x54R 1.35,
  5.56 1.15, 40mm 1.5, flare/flame/dart small) and 1.5 for MG42/Bren/DP28 (by class name; BulletType can't tell an MG from a
  rifle). F3 Senses: CALIBRE_EFFECT blends it in (mult = 1 + s*(m-1); 0 = old flat range) and SUPPRESSED_GUNSHOT (0.35) scales
  down when the gun's MuzzleSlot actor (property read, as space.lua hide() does) has a class name containing supp/supr/silenc.
  Not verified: that suppressors really sit in MuzzleSlot (the Mat49/Sten suppressor items may use another slot), the exact
  actor class names, and which BulletType values each gun reports. Wrong guesses fall back to x1.
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
- Loot density settings (2026-11-21, #325, first pass, NOT tested in game; luacheck only). F3 tuning "Loot" tab:
  `CFG.FLOOR_LOOT` (main.lua) and `Rivals.CFG.BODY_LOOT` (rivals.lua), 0-3, default 1 = the old code path exactly (no
  extra random draws). Floor: below 1 each spawner is skipped with chance 1-x; above 1 a spawner whose TriggerSpawn
  left no ActiveActorHere gets `HasCompletedASpawn = false` and TriggerSpawn again (floor(x-1) times + fraction). Unverified:
  that resetting HasCompletedASpawn lets TriggerSpawn re-roll, and that the pickup pool has enough free actors; the
  floor-loot log line now prints both multipliers plus skipped/reroll counts to check this. Body: scales the meds and
  CARRY_BAG pick counts in rivalbodies.lua rollCarried (and below 1, the chance a bagless body's pocket item exists);
  gun ammo is untouched. Container loot has no setting: the game fills containers itself at map load (above).
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
- **Per-gun recoil scale (2026-11-24, #371, NOT tested in game)**: recoil.lua scales the held gun's
  WeaponConfig.VerticalRecoil (the per-burst climb cap, per spork) by fire rate: automatic Rifle_ classes faster than
  REF_INTERVAL 0.12 s get interval/0.12 (min MIN_SCALE 0.55; PPSh/MAC-10 0.72, Klobb 0.63, Uzi/Mat-49/M16 0.83), x
  RECOIL_MULT for all guns (settings tab "Recoil"). HorizontalRecoil and TimeBetweenShots are guessed property names;
  not verified that a write to the instance's WeaponConfig struct changes the climb (look for "recoil:" lines in the log).
- **ADS recoil setting (2026-11-24, #453, NOT tested in game)**: since the aim kick from VerticalRecoil/HorizontalRecoil
  only applies while bIsTargeting (above), hip "recoil" is the arm shake and VerticalRecoil is effectively the ADS
  recoil. Added RECOIL_ADS_MULT (Recoil tab) multiplied into the same scale, plus a one-time per-class log line
  "recoil fields:" of guessed WeaponConfig names (VerticalRecoilADS, RecoilRecovery... property reads only). Not
  determined: whether an ADS-only field is read, and whether the per-burst cap or the per-shot kick feels off.
- **Why recoil 0 still kicked (2026-11-25, #453, read from the game in the lobby):** the vertical recoil getter 0x188a260
  = WeaponConfig.VerticalRecoil (weapon +0x4c0) + MuzzleSlot (+0x8f8) and StockSlot (+0x920) attachments'
  VerticalRecoilAdjustment (RaidWeaponAttachment +0x234; HorizontalRecoilAdjustmentMin/Max +0x238/+0x23c). WeaponConfig
  @0x410: RecoilBlendSpeed +0xac, VerticalRecoil +0xb0, VerticalRecoilADS +0xb4, HorizontalRecoilMin/Max +0xb8/+0xbc,
  RecoilRecoveryDelay/Rate +0xcc/+0xd0; the per-tick 0x189f890 reads +0x4bc (blend) and +0x4e0 (recovery). recoil.lua
  scaled only VerticalRecoil, and wrote "HorizontalRecoil", which doesn't exist. Also checked: `local cfg =
  gun.WeaponConfig` is a live reference in UE4SS (a write through it reads back from a fresh gun.WeaponConfig; tested on
  Default__RaidWeapon, restored). Now the total (own + attachments) is scaled, horizontal through Min/Max. The hip
  arm-shake animation is still untouched. NOT tested on a held gun (no raid this session).

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
  Later found missing and added by the mod: see "Bullet holes (2026-11-18)" at the end.
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
- 2026-11-24 (#440): F9 "Skip Zero to Hero step" (missions.skipChapterStep) reads the current chapter row (type, need,
  tags) and sends Client_CheckMissionEvent(tags[1], type) need - progress times (Guard: sets bInChapterVolume and sends
  once, the game's 1 s timer counts it up; Inspect and tagless steps are refused). Never writes +0x1160. NOT tested in
  game: unverified whether the chapter half counts these outside a raid (lobby) or whether the step advances at once.
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

- 2026-11-24 (#333, NOT tested in game): Destroy events (type 3). missions.lua reads the active Destroy rows' tags
  (GetAllMissionsForRaid + the chapter step, ContractType == 3, as minimap.lua reads them), and on the native
  RaidSubNodeActor_Turret:NetOnDeathEvent or Actor:K2_DestroyActor (NodeMine only with its mesh hidden, as spacefx.lua)
  of an actor whose Tags hold one, sends Client_CheckMissionEvent(tag, 3) once per actor (full name in S.fired; no
  native-event detection). Assumptions: mines/turrets carry the contract tag in Tags (unverified), candidates are
  RaidSubNodeActor + MineStaticActor_C. Double-count risk if the native CheckMissionActor path also fires: look for
  "[missions] destroyed" in the log and compare the contract progress. Also: a "Hold F to inspect" line (defuse.lua's
  DebugInfo_Widget prompt) while an inspect object is targeted; Destroy targets join missions.actors() so the minimap
  marks them (M.version() makes it rebuild its task markers; ones in a Space_* level get no place, so no marker).

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
- 2026-11-21 (#313, first pass, NOT tested in game): leaderless guards run. rivalbodies.lua routGuards (called from
  rivals.lua next to roamGuards) takes a station's guards as roamGuards groups them (raid.bots entries with no faction,
  not crew/follow, e.roamSt == st), and once 2+ are up picks a leader: profile "boss", else the first adopted defender
  (S.adopted order), else the first found; logged "[rivals] X: guards' leader is Y". When the leader entry is dead
  (reapDead's e.dead) every other guard of the group gets e.routUntil (rivals CFG ROUT_SECONDS {25,40}) and
  e.routNear (ROUT_FIRE_RANGE 600) and is sent with MoveToLocation to the reachable point (of 5, within ROUT_DIST
  4000) furthest from you; logged "guards at X run: their leader Y is down". bots.lua updateBots: while routed (and
  you're not within routNear) it drops combat/alert/investigation, holds fire, skips perception and patrol. Once per
  station per raid; a leader killed by a rival crew counts too. F3 > How many: ROUT_SECONDS and ROUT_FIRE_RANGE
  (ROUT_SECONDS max 0 = off). Only luacheck run; unverified: that the RaidAIController's tree doesn't override the
  move or re-acquire on its own while MyEnemy/Enemy are clear, and that the leader is picked before you kill it
  (a group whose first two guards aren't up yet has none).

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

## Event: the Red Baron in every raid (2026-11-16, #78; rivals.lua R.baron, F3 > Rival ships)
- Hayley on #78: event presets are welcome, guaranteed bosses first, reachable from the lobby, more loot when a preset
  makes raids harder. This is the first slice: one setting, BARON (0/1, off by default), in the F3 Rival ships tab. F3
  works in the lobby, and the value is saved with the other tuning (config/ai_tuning.txt, id Crews:BARON).
- The map's own Red Baron (Ship_RedBaron_StrikeFrigate01_Pawn_Ai_Child_C with AiFrigateController_RedBaron_C and a
  GOAPNodeBot_Boss_C captain) is rolled by the game per run and its GOAP brain doesn't run offline, so the guarantee is
  one of our crews: makeCrews turns crew 1 into the Baron's (at least one crew even with CREWS 0 / no slots).
  R.baron.make: the Strike Frigate design (no turret refit), a full crew (CREW_SIZE max), diehard, never a rusher,
  aggression 1, gunnery = GUN_SKILL max; captain "Red Baron" with the game's Baron_Head_Skel_01 / Baron_Body_Skel_01
  (headPath/bodyPath, as hired crew use), GearScale.spec(1) gear, helmet/chest/bag worn, 2x BASE_HP. He keeps the
  "rival" AI profile: ai.lua "boss" is weaker than "rival" (typeMod .75, miss .4).
- rivals.lua's main chunk is at exactly Lua's 200-local limit (adding even one top-level local fails scripts/luacheck.py),
  so the helpers are fields of R.baron. Check with luacheck before adding any local there.
- Tested in game (2026-11-16, Space_Solo_01, BARON set to 1 from bridge/dir_eval.lua, mod scripts from the branch laid
  over the offline copy): "solo map, 12 player slots: 5 rival crews"; "Red Baron's Strike Frigate (4) launched in a
  Strike Frigate (RocketArtillery): heading for Navy Outpost"; a Ship_RedBaron_StrikeFrigate01_Pawn_C in the world
  (bridge find); docked at Navy Outpost a minute later; no Lua errors. Not seen yet: the captain's Baron look in
  person, and a fight with him.
- Red Baron impostors (2026-11-21, #319 first pass, NOT tested in game): lore "three men have been brought in as the Red
  Baron. None of them was." makeCrews (rivalcrews.lua) rolls CFG.IMPOSTOR_CHANCE (rivals.lua, default 0.25; F3 Rival
  ships "Chance a crew's captain poses as the Red Baron", 0 = off) once per raid, never when BARON >= 1 (the Baron
  hunt condition sets Crews:BARON = 1). One crew with no condition hull and not the Baron's is picked; R.baron.impostor
  puts its captain in the Baron's head and coat (headPath/bodyPath, male, male voice) and sets c.captain to
  `"Red Baron" <his name>`. Crew, ship, health, gear roll, helmet and AI profile stay the crew's own (normal "rival"
  profile), so his cap is whatever he rolled, "not quite right". Shown only in the log: a launch-time line "a man calling
  himself the Red Baron (an impostor)" and the kill line "(a man calling himself the Red Baron: not the Baron)"; the
  game's kill list (killstats.lua) has no names, so nothing there. The Baron has no unique drop (BaronCap is an ordinary
  priced item in gear.lua), so nothing to withhold. Not done: other named bosses of #319, a nameplate.
- Progressive Baron chance (2026-11-21, #322 first pass, NOT tested in game): SPT's ABPS. makeCrews asks R.baron.roll():
  chance = BARON + BARON_RISE x (raids since he last flew), capped at BARON_MAX (never below BARON; BARON >= 1 or the
  Baron hunt condition = always). BARON_RISE defaults to 0 (off, so nothing changes until it is set; 0.05 suggested),
  BARON_MAX 0.6. BARON itself may now be a fraction (F3 step 0.05) = his base chance per raid. Log at raid start:
  `[rivals] Baron: base chance 0.00, +0.15 after 3 raids without him = 0.15: not this raid`. The count lives in a file the
  mod writes (R.baron.streak): backend/saves/<active save id>/baron_streak.txt, the id from backend/active_save.txt (only
  when that save's meta.json exists); without the launcher, or for a co-op joiner (PVE_BACKEND), baron_streak.txt in the
  backend folder. Chosen over the stand-in / state.json because the launcher only copies state.json between saves, so a
  file in the save's own folder follows the save (copy copies it, delete deletes it) and Lua never touches state.json.
  Caveat: the count moves in makeCrews, so a raid that never builds rival crews doesn't count. F3 Rival ships: BARON_RISE
  (0 = off), BARON_MAX. Not checked in game: the file is written, switching saves in the launcher, the F3 rows.
- Next (#78): event presets (config/event.txt or a lobby picker) bundling map + overrides, loot scaling for harder
  presets, other bosses.

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

- 2026-11-24 defaults softened (Discord: insta-kills through heavy armour, bots rush every reload). Base miss rates
  left alone (damage per shot is flat below ~0.45, so a base change mostly hits guards and soldiers); instead more
  near misses on first sight and on the move: AIM_SETTLE_SECONDS 1.5 -> 2.5, AIM_SETTLE_PENALTY 1.4 -> 1.8,
  AIM_MOVING 1.2 -> 1.4, AIM_TARGET_MOVING 1.1 -> 1.3; Easy raised to stay above Normal. BOT_PUSH_SECONDS 4 -> 2.
  Players who set these in F3 keep their values (ai_tuning.txt stores changed values only). NOT tested in game.

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
- 2026-11-18 (#143): the "montage check" ones ARE a sound. `AnimNotify_ReturnedToIdle` / `_ReturnedToIdleRun` (fired when
  you stop walking / running) enter the ubergraph at 17347: `if IsServer: stop`, else (no montage playing) the crouch or
  walk step via `Force_*FootstepSound` -> the normal step path at 13545. So stopping was silent offline, for you and the
  bots (their copy: 14327). Patched both (player 17368, bots 14327: the JumpIfNot offsets; the notes' 17357/14316 are
  the IsServer calls before them), plus the landing camera shake (27802; your own camera only). 16650 in the bots' graph
  only stores IsServer into IsServerVersion: not a branch, left alone.
  Verified (Space_Alpha): kdis shows all three as plain jumps after a relaunch; firing AnimNotify_ReturnedToIdle and
  _ReturnedToIdleRun on your anim instance each produced a new Footstep_Metal_walk01_Cue AudioComponent. Not checked by
  ear; the landing shake not checked (needs a real fall). Counting footstep AudioComponents "attached to the player"
  missed them: count them anywhere, by address, before and after.
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

- 2026-11-25 (#473): boarders came in on top of your cockpit. rivalbodies.lua breachSpots now skips spots within BREACH_HELM_CLEAR (600) of the interior's RaidUseableFrigateHelmComponent(s) and spots more than BREACH_FLOOR_Z (250) above/below the breach point (or anchor) they were searched around (up to 4 tries per breach point); if nothing qualifies it falls back to the old spots and logs "[rivals] no boarder spot clear of the helm". Luacheck only: NOT tested in game (helm component lookup via K2_GetComponentsByClass on the inside actor, BreachTransforms' height relative to the floor, and the thresholds are all unverified).

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
- Parent first (2026-11-19, #192): a player crash was the fatal `Could not find SuperStruct FrigateInside_DefaultScout_C
  to create FrigateInside_AssaultScout_C` (hash 5EB5779D...). Probed with GetSuperStruct: every Scout_Insides/* interior
  is a child of FrigateInside_DefaultScout_C, every Capital/* one of FrigateInside_Capital_C; DefaultScout, Starter,
  Capital and Strike derive from native RaidSpaceshipInside, and every hull pawn from Base_Frigate_Ship_C (your own
  ship's, always loaded). A plain LoadAsset of AssaultScout with DefaultScout not loaded worked (the engine loaded the
  parent), so the crash needs the parent part-way through the game's async loader at that moment; then a sync load of
  the child doesn't flush it but a sync load of the parent package does. makeInterior now loads CFG.INSIDE_PARENTS'
  entry first (and falls back to your interior class if the parent won't load). Tested: fresh game, Space_Alpha,
  bridge/rivals_prep -> "interior for the Rusty Mule (Assault Scout) loading" and "ready", no crash. The race itself
  was not reproduced, so this is the fix by reasoning, not a before/after.

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
- Extra markers (2026-11-21, #326 first pass; luacheck only, NOT tested in game): grey X where enemies you killed fell,
  a bag where you dropped an item with J, blue dots for living crewmates. On foot only, only marks made in the place
  you're in, only inside the map (no edge clamping); CFG SHOW_KILLS / SHOW_DROPS / SHOW_CREW, MAX_KILLS 40,
  MAX_DROPS 20 (oldest dropped). Copied vectors only, kept per raid.world in minimap.lua's `marks`. Sources: kills =
  main.lua's Multi_Deathevent hook (RaidBot deaths, rival bodies included) calls M.noteDeath(location); killstats.lua's
  K.update calls K.onKills(n) (= M.noteKills) when the K_ totals in InMatchStats grow, and the newest n deaths of the
  last KILL_WINDOW (3) s become kills. A guess at attribution: a crew kill at the same moment as yours can swap which
  body gets the X. Drops = the player pawn's location when invqol.lua's J runs Server_DropInHud (the game picks the
  exact spot; dropping by drag in the game's own UI is not caught). Crew = crew.lua C.positions() (K2_GetActorLocation
  of each living roster bot, the same read its nametags already do every frame). New art assets/minimap/cross.png and
  bag.png (written with stdlib zlib; the same shapes added to tools/make_minimap_art.py); missing art falls back to
  the dot instead of failing build().
- **Blank panel watchdog (2026-11-21, #334; NOT tested in game, not reproduced).** Reported: the small map a solid dark
  rectangle for a whole clip, no plan, marker or text. Found in the code: the backdrop (panel + map Border) went on
  screen at build(), while every piece of text and the plan is only written once `think` returns ready, so anything
  keeping think, locate or the survey from finishing left the empty box up; an error anywhere in M.tick (stepScan,
  command, think, draw) left through main.lua's "minimap failed", logged every frame, and skipped the rest of that
  frame (a throwing floor scan blocked text and draw for the whole raid); a build() that threw part-way left a half
  `ui` with no `ui.pc`, never retried; `S.failed` was permanent; `ui` survived an `S` rebuild if main's reset never
  came; `ui.pc:GetAddress()` ran on a pc without a valid() check. Now: the host is collapsed until `S.ready`; each step
  runs under `guard` (one log line per distinct message, 20 per raid); a failed floor scan marks the place noPlan; and
  `watch` (end of M.tick) sees "no successful think+writeText, or no successful draw, for CFG.STALL = 20 s" while the
  panel is on, logs the reason once (`minimap: panel stalled ...: no valid pawn / widget freed / no places / tasks
  unreadable / no task / no floor plan / plan texture failed / last error: ...`) and rebuilds the widget (`dropUi`:
  valid() first, RemoveFromParent on a live host so no stale rectangle stays under the new one; at most 3 per raid, 30 s
  apart; not for a missing pawn, which just waits). Look for `minimap: panel stalled` and `minimap: rebuilding` in
  last_game.log. Not verified: that this is the cause of the clip (the overlay of the stream was never ruled out),
  RemoveFromParent on the host in game, and the collapsed-until-ready start.

## Stutter, lighting, bot aim, kit looks (2026-11-06, written; NOT yet run in game)
Measured live in a Navy Outpost raid, with WoW in front for all of it, so frame numbers are only rough: p50 11 ms, 100-400 ms hitches several times a second. The render thread was busy and the game thread mostly waiting.
- Minimap think() ran FindAllOf + FindFirstOf twice per think (gates, game state, game instance), every second and on every ROUTE_MOVED step. Now cached; gates only scan once the timer is out, every GATE_RESCAN s.
- The only world light is Node_Background_06's DirectionalLight: intensity 10, movable, DynamicShadowDistance 650000. Hiding it live visibly darkened the Navy Outpost and the held gun (mean brightness 39 -> 35). There is no world skylight (the one SkyLightComponent lives in /Engine/Transient). main.lua updateSun keeps it on only while not on foot. Effect on frame time not measured: all tests ran with WoW in front.
- tools/profile/threadsample.py samples the busiest threads from outside. bridge/profile_on makes the director write scan counts and slow ticks to bridge/profile.txt.
- 2026-11-16: bridge/profile_on is looked for every 3 s (main.lua profiler), not only when the director starts, so it
  can be dropped in or taken out mid-raid ("profiler on (bridge/profile_on)" / "profiler off" in the log; off puts the
  plain FindAllOf/FindFirstOf back and clears PVE_PROF). bridge/dir_eval.lua runs while it's on. Tested in the lobby:
  "profiler on" 5 s after creating the flag, then dir_eval ran (used it to debug lobbylabel.lua, issue #55). Before,
  every look inside a running raid cost a quit and a relaunch.
- Shot probe (bridge/t_shots.lua, 80 shots): bots shooting while not bIsTargeting keep the gun level (shotgun gun -3 deg, bullets +19). bIsTargeting bots track it within ~5 deg and play the arms' montage (rc_Mat49_Aim_Shoot_Mon); from the hip the arms play nothing while the gun runs Mon_*_Shoot on its own mesh. trackTargets now sets ServerSetTargeting while fighting (not sprinting or hiding). Forcing it live raised hand_r 41-55 from 43-50 above the capsule; no shots landed in that test window.
- GlobalAnimRateScale (0.6-2.4, for the legs) also scaled the arms' montage while the gun's ran at 1.0; animate now counters it with Montage_SetPlayRate.
- anim.Bend: non-zero (2.8-8.5) only on three top-up copies, which sit lower (head 46-53 vs 64). A Lua write doesn't stick (the BP rewrites it each update). Cause unknown; check whether these still point low once aiming is forced.
- bridge/t_kit.lua: placed raiders' looks match their loot. Mismatches were top-ups (template gear, donor loot) and takeKit missing Beret/Cap/Vest/Rig rows. wearKit now shows the donor's piece only for armour in its loot. Rival gear no longer uses the catalog pool, so it's less varied. Assumes donors wear their loot: check on the first run. Donors' ammo can mismatch the gun (M1Para or 1911 with 762Ammo; placed raiders carry 32Ammo): not fixed.

## Native bot kits, tested (2026-11-07, supersedes the donor notes above)
- 2026-11-24 (#413): flamethrower bots fired without stopping. Our code never holds a bot's trigger (the game's tree
  fires; bots.lua M.botShot only counts ServerMultiSimulateWeaponFire calls against AmmoPerClip to force a reload), so
  no stuck release was found in the code. Likely the flame stream doesn't call that once per shot, so the count never
  reaches the clip: unverified. Fix: rolled kits draw from Gear.botGuns (Gear.guns without LPOFlamethrower). The
  prisoners' double barrel is the game's own prisoner kit, not our pool: not changed, still open. Not tested in game.
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
- Gear on the lobby character (2026-11-16, issue #29): putting gear on or taking it off on LOADOUT didn't change
  the lobby character until you switched tabs. A tab switch runs SIGIS_InventoryWidget_C OPENED_GearMenu,
  Switch_EquipmentState and RefreshMenuPlayerActor (x4), then MM_PlayerChar_C Refresh_PlayerLookActor /
  PGOS_OnChangedMyEquipment / NEW_PGOS_PlayerLookRefresh (x4, one per lobby character; they take a 104-byte look
  struct). Calling Force_RefreshPlayerLook, RefreshMenuPlayerActor or OPENED_GearMenu alone changed nothing;
  SIGIS_MainOverlay_C:CoreMM_Tab_Pressed(1) (LOADOUT's Which_CoreMenuState) on the page you're already on does it.
  lobbylabel.lua: while the LOADOUT tab isSelected, once a second, the equipped items (StashedItems whose
  MotherItemGUID is a plain slot name, not Stash / pockets / loot / shop / KeyCard / RigSlot*) are compared, and on a
  change it presses LOADOUT that way. Overlay, tab and inventory are kept as paths. Tested by dragging a Brodie
  helmet on and off: "lobby: gear changed, character redressed" each time and the helmet appeared / went at once.
- Vertex explosions on women's outfits (2026-11-20): parts of some female bodies stretched to the floor while the
  character moved (user screenshot: a strip from the arm to the feet). make_female.py's buffers() found vertex buffers
  by their header alone (12, n, 12, n). Skin weights are 4 bone bytes + 4 weight bytes per vertex, so two vertices in a
  row held wholly by bone 12 read 12, 255, 12, 255: a "buffer" of 255 vertices, reshaped as positions. That zeroed every
  third uint32 of ~3 KB of LOD1 weights (bone 12 -> 0, the root at the feet; some weights -> 0). 11 meshes had it:
  Commando_Body (+Blue), Outlaw_Body 01-03, Security_Body (+Army, +Prison), Space_Pirate_Body, Commando_Skel_01,
  Security_Skel_01. buffers() now also requires the floats to look like centimetres (finite, under 2000, no
  subnormals: packed bytes read as floats are subnormal, NaN or huge). Checked over all 113: the 11 false hits gone,
  every real buffer still found; rebuilt Outlaw_Body_Skel_01 differs from the original only inside its two position
  buffers. Checked in the lobby at LOD1 (SetForcedLOD(2)), old and new Outlaw_Body_Skel_01 side by side on two stands:
  the old one hangs a flap from the crotch to the floor, the new one doesn't. Not checked: a character moving in a
  raid. Issue #10 (boarders' legs into spikes) is this bug (the user confirmed it). The release builder remakes the
  meshes and the updater fetches the changed female deps zip (#257), so the next build carries it.
- Clipping through vests and plates (2026-11-20): a lobby screenshot showed the chest coming through a plate in two
  ovals. That stand had a woman's body under a man's plate (my test swapped only the body). Measured over every body
  x vest/plate/rig pair in the bind pose, LOD0: triangles of the gear rasterised to front and back height fields over
  x,z, and a body vertex counts if it sat under the gear on the man and is 3 mm or more through it on the woman (same
  topology, so vertex for vertex). Woman's body + man's gear: 957 of 1032 pairs come through at the bust, up to 3.5 cm
  on the Outlaw + Half_Plate, exactly the screenshot. Woman's body + woman's gear: 35 pairs with more than 3 vertices,
  all single vertices at hems, collars and pauldron rims (worst Baron + M1_Flak_Vest, 14), where the man's gear
  already lets the body show. Nothing to change in make_female.py's shape. The thing to avoid is a woman's body
  with gear that wasn't swapped too. Not measured: poses other than the bind pose, gear over gear (rig over vest).

## Launcher and saves (2026-11-07)
- launcher/launcher.pyw (tkinter, trailer style) + launcher/saves.py. Marauders Offline.lnk here and on the desktop. backend/saves/<id>/{state.json, meta.json, before-last-raid.json}. Play copies a save to backend/state.json (stand-in and scripts still use that path), backend/active_save.txt names it, and closing the game copies it back, stops the stand-in and goes to stock (backend/last_game.log keeps the UE4SS log). Started by launcher: cleanup waits until the game has been seen, or it kills the backend during boot (first version did: "connecting to backend" crash).
- New save: capture seed with stats, XP, factions, skills, cosmetics and stash reset, keeps Body01/Head01/voice gifts, adds a P08, ammo, bandages, 10,000 cash. Seed's contracts stay as they were. Cheat: state["cheat"], stand-in forces cash to 999999999 on every write; stash from assets/saves/items.json (tools/offline-audit/itemsizes.py; row+0x14 is u8 col,row).
- Contract board refresh (2026-11-24, #333, not tested in game): once per stand-in run, masterstartfunction moves playerstats contractstarttime back 8 days (nakama_standin.refresh_board) so the client should roll a new board; skipped when the board's fields after the six rows aren't all zero (their meaning isn't decoded: maybe progress/payout), and when config/contract_refresh.txt says "off". New saves get the same backdated start time instead of the seed's (the ContractTable dump, bridge/contracts_table.txt, isn't in the repo, so the board itself isn't rolled here). Unverified: that the client re-rolls on an old start time at all. Tests: tools/test_standin_flow.py.
- Kits (2026-11-24, #385, not tested in game): launcher KITS button (beside Give items) sells the presets in config/kits.json. saves.kits() prices each kit as the sum of gear.lua prices (parsed in Python from its `{ "Row", price` entries, so gear.lua stays the one price list; ammo, which gear.lua doesn't list, uses items.json's price) x KIT_MARKUP 1.15; VENDOR_PRICE and faction-level unlocks are not applied. saves.buy_kit places every item with the give() grid code into the in-memory state first and writes once, taking cash last: short cash, a full stash or the save being active (active_save.txt) cost nothing. Cheat saves don't pay. Tests: launcher/test_ui.py Kits (enough/short cash, full stash, in play, every row real and priced). Unverified: that the game shows the bought items at the next login (it should: same strings give() writes).
- Double stash: config/stash_rows.txt (written on activate, per save). pve_stash_rows sets the InventoryContainerSizes TMap (32-byte elements at comp+0x128, size at +0x10); the grid widget has its own InventoryGridSize and builds at menu start, so main.lua rebuilds it (ClearChildren, InventorySlots:Empty, InitializeGrid) before items land. 59 items, 28 below row 15, all placed.
- Voice lines must not load during map travel: crash at bad RIP through UE4SS hook, in raid load. They now load only in the menu, 3 a frame, not while a match is pending. Lines not loaded are skipped.
- bridge/menu.sh waits for the splash before Play (fixed sleeps crash in nakama-cpp). rt.sh/zone_test.sh use backend/state.before-voice-model-work.json.
- Waist: width 0.885 at z108, 0.905 at z120, depth 0.86/0.9. Not looked at in game.

- Arms (2026-11-07): ANSUR II medians (ergoassessment.cam ANSUR II explorer), taken at equal height: biceps/forearm 0.92, wrist 0.95, neck 0.90, calf 1.03. make_female slims each arm around its bind-pose centreline (ARM_Z/ARM_Y), 0.88 at the shoulder to 0.97 at the hand; neck 0.9-0.96; calf 1.03. Checked on the lit lobby character, male vs female.
- Hands (2026-11-20, #35): the women's fingers were mangled. Two causes, both in make_female.female(). (1) The arm
  branch only took z > 100, but the hands hang across it (bind pose: hand mesh at |x| 52-69, z 93-112), so the top of a
  hand got the arm shift (+2.2 across) and the bottom the waist/hip WIDTH (-1.4 .. +2.0): fingers torn up to 3.6 apart.
  (2) Any move of a hand vertex at all: the skeleton is the man's, so moved skin sits off its finger bones (fingers looked
  longer and missed the weapon grips in first person). Now WRIST fades the whole reshape out from |x| 36 to 52, and the
  hands are the man's vertices exactly (checked on Bandit: every hand vertex unmoved). Wrist width is now male; the
  forearm takes back the arm's 2.2 shift over 16 units. Scanned every listed mesh: below z 100 nothing but the hands
  reaches past |x| 30. Verified by the user in first person (fingers on the rifle match the man's). Not looked at: the
  lobby stands (#151 may be a different cause), bots up close.
- Not changed: `math.copysign(TORSO * (shoulder - 1), x)` drops the sign, so the arms move OUT 2.2 where the comment
  says in. The shoulders were tuned by eye with it in place; fixing it moves the arms in ~4.4.
- Bust 8.3, waist width 0.91/0.925, depth 0.885/0.915 (user, 2026-11-07).
- PLAY preflight (2026-11-15): launch-offline.ps1's output used to be thrown away, so a wrong config/game_path.txt, a
  missing tools/ue4ss or Steam not running all showed as "The game didn't start" after START_TIMEOUT (90 s). launcher.pyw
  preflight() checks the game exe, tools/ue4ss (dwmapi.dll, UE4SS.dll, Mods) and steam.exe first; if the script still
  fails, the status line shows its first error line and the launcher tidies up at once.
- Update check (2026-11-16): the release zip now ships `version.txt` (`public-test-<build>`, written by
  build_release.py). launcher/update.py asks `api.github.com/repos/HaywireHayley/Marauders-PvE/releases/latest` (6 s
  timeout, background thread, fixed User-Agent, nothing about the player) and compares tags as (YYYYMMDD, .N; no suffix
  = 1). Newer -> a "! UPDATE TO BUILD ..." badge top right; same/older, offline, rate-limited or no version.txt (dev
  checkout, builds 1-3) -> nothing. Toggle "Check for new builds" -> config/update_check.txt (missing = on). UPDATE
  downloads the MaraudersOffline-*.zip asset to %TEMP%, checks it against the asset's `digest` (sha256 from the GitHub
  API; no digest -> no UPDATE button, only "What's new"), then writes the zip's files over the folder. Kept if they
  already exist: config/* except mods.txt and UE4SS-settings.ini (shipped, not player settings), bridge/*,
  backend/saves/*, backend/state*.json, cover/* (cover.lua appends the player's own points). Files the zip doesn't
  hold (saves, logs, loadout) aren't touched. Every replaced file is backed up first and restored if a write fails
  (tested with a read-only UE4SS.dll). Files removed from a later release stay behind (harmless so far). Builds 1-3
  have no update.py, so those players update by hand once.
  - Dependencies (2026-11-20, after #35): since build 20261119 UE4SS.dll and the female meshes are only in the
    `-deps-*.zip` assets, so an update never brought a remade mesh (the #35 hand fix would have reached nobody who
    updates). The release zip now holds `deps.json` (part name -> {file: sha256}, written by build_release.py
    package()). The updater reads it from the downloaded zip, hashes the files here and downloads only the parts that
    differ (each checked against its GitHub digest), then installs them all as one (shared backup and rollback). The
    launcher's startup check also repairs: if the installed deps.json doesn't match the files (a build-15-or-older
    launcher installed the main zip only, or files went missing) it fetches those parts from the installed build's own
    release (`releases/tags/<tag>`), with PLAY off meanwhile. So the first release with deps.json reaches players in
    two steps: the old launcher installs the main zip, the restarted new one fetches the parts. Tested with fake
    releases (file:// URLs: changed part only, unchanged build = main zip only, repair, damaged and missing part) and
    the real 20261120.15 release's asset list; not yet against a real published release or in the launcher window.
- Launcher audit fixes (2026-11-16):
  - One launcher at a time: a named mutex (Local\MaraudersOfflineLauncher, single_instance() in launcher.pyw). Before,
    a second launcher opened between PLAY and the game appearing ran settle(): it filed state.json away before the
    raid and removed active_save.txt, so when the game closed the first launcher had nothing to put back, and the
    next activate() overwrote that raid. A second launch now brings the first window forward and exits. The updater's
    restart passes --after-update, which waits up to 15 s for the old launcher to exit.
  - Closing the launcher while the game runs asks first, and while it's saving it's refused. If it was closed anyway,
    the next start finishes the job: with the game still running it watches it as if PLAY had started it, otherwise
    it settles the save, keeps the log and runs mode.ps1 online, with PLAY off until that's done. Before, the game
    folder stayed in offline mode.
  - Save names that are Windows device names (con, prn, aux, nul, com0-9, lpt0-9) get "-save" on their folder:
    "Nul" made the folder but no files, and the new-save dialog closed with nothing made. Create errors now show
    in the dialog.
  - Copies into a save slot (settle, activate, undo, adopt) go through saves._copy (.tmp + os.replace), so a
    crash mid-copy can't cut a save off. A save whose meta.json or state.json can't be read is listed as DAMAGED
    (only Delete works) instead of silently vanishing from the list.
  - Settings boxes write through App.write_setting, which says so on the status line if the file can't be written.
  Tested outside the game: saves.py and the launcher with stubbed game/PowerShell (26 checks), and real launcher
  processes for the single-instance cases.
- Stand-in start and windowed size (2026-11-16, issue #75): launch-offline.ps1 started the stand-in with
  `Start-Process python -ArgumentList '-I', <path>`. Windows PowerShell joins -ArgumentList with plain spaces and no
  quotes, so with a space anywhere in the install path Python got a cut-off path and exited. Nothing checked, so the
  game sat on CONNECTING TO BACKEND forever. Reproduced on a folder named "with space"; re-extracting to a plain
  path "fixed" it, as the reporter found. Now scripts/launch-helpers.ps1 Start-Standin quotes the path, waits up to
  15 s for 127.0.0.1:7350 to accept a connection, and otherwise fails PLAY with a reason. The reason is the last line
  of backend/standin_err.log, where nakama_standin.py now writes a startup crash (port, state.json, no write access),
  or a timeout. Don't use Start-Process -Redirect* for it: that turns on handle inheritance, the stand-in keeps the
  launcher's stdout pipe, and the launcher's ps() call never returns. The stand-in now starts before mode.ps1 offline,
  so a failed start leaves the game stock.
  Windowed mode was a fixed -ResX=1600 -ResY=900, which ran off a 1366x768 screen. Get-WindowedSize uses 1600x900 when
  it fits, else the biggest 16:9 within 90% of the width and (height - 120) for the title bar and taskbar, in steps of 16,
  960x540 at least (1366x768 -> 1152x648). It reads the first video controller, so on two monitors it's sized for the
  first.
- New saves start as a new live account did (2026-11-16, issue #56). On the first login of an account with no
  social/created (the seed has none, so every fresh save), the game runs its new-player setup: it writes
  social/created + accouttype, adds 65,000 credits (statChangeArray TotalCash) and a 34-item kit (2 KlobbSMG, 3
  Mat49Rifle + 2 wooden stocks, 3 BrodieHelmet, M1FlakChest, 2 LeatherJerkinChest, 2 LightBag, SmallContainer,
  BasicSupplyDrop, 2 HuntingKnife, a P08, 9 x 32Ammo, 2 x 9mmAmmo, 7 BandageAid), and opens the Guide (its YouTube
  video can't load offline). The launcher used to add START_CASH 10,000 and its own P08 kit as well: the lobby showed
  10,000, then 75,000 after the first stash refresh. Now START_CASH = 0 and the launcher kit is gone (saves.py), so a
  normal save gets exactly the game's start; cheat saves are marked as set up (_set_up_already) so the kit doesn't land
  on their packed stash. Tested: fresh normal save 0 / 3 items -> after login 65,000 / 37 items, lobby shows 65,000
  straight away; fresh cheat save 999,999,999 / 32 items -> unchanged, no setup writes in server.log.
  Gear and money apart (2026-11-19, #204): NEW SAVE has two boxes, "Start with lots of gear" and "Infinite money".
  saves.create(name, gear, money, rows): gear = packed stash + _set_up_already, and since that also skips the
  setup's 65,000 credits, saves.NEW_PLAYER_CASH is written instead; money = state["cheat"] + CHEAT_CASH (the stand-in
  forces cash on every write, so the setup's own cash write on a money-only save's first login is overwritten too).
  meta "cheat" still means infinite money (CHEAT tag, panel toggle); meta "gear" is a record only. pvemode.py new
  takes --gear / --money (--cheat = both). Tested: launcher/test_ui.py makes all four combinations through the dialog
  and checks stash, cash, setup marker, meta and the list tag. Not run in game (the stand-in path is unchanged).
  The new-player Guide (Guide_Widget_C:FreshAccount_RunGuide; a popup on the game instance, not the lobby's embedded
  Guide_Widget) is closed by lobbylabel.lua with ForceCloseTheGuideWidget if it shows within 60 s of the session's
  first lobby (it opened ~15 s in). Tested on a fresh save: "lobby: closed the new-player guide", clean lobby.

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
- Unstuck and No collision (2026-11-19, #198; unstuck.lua, two F9 buttons, on foot in a land raid or in space).
  Unstuck: back at the newest spot you walked through on solid ground (MovementMode 1) at least 6 s ago and > 1 m
  away; a spot is kept each time you've walked 1.5 m (so standing wedged doesn't push the good ones out), 10 kept.
  No such spot: the nearest navmesh (K2_ProjectPointToNavigation, 4x4x5 m), unless that's where you stand. 30 s
  cooldown. Spots before navmesh because under the map the nearest navmesh can be a lower floor: Spaceport_01 has
  walkable floor with navmesh at Z -1441, 17 m below the play area (the first version put me there). A navmesh point
  sat 108 cm above the feet there, so "where you stand" is 1 m across and 2 m up or down.
  No collision: SetActorEnableCollision(false) + MOVE_Flying, MaxFlySpeed 1200, BrakingDecelerationFlying 4000 (the
  game's is 0: you drifted on after letting go). The game's input only moves you level, so each frame the camera
  pitch adds Velocity.Z = flat speed x tan(pitch). Off: collision on, MOVE_Falling, old values back. Kept by pawn
  address (two Lua wrappers of one pawn are not ==, which cleared it the next frame in the first version).
  Tested in game (Spaceport_01, real F9 clicks): sunk 3 m under the floor, fell to Z -1459, Unstuck -> "Back where
  you stood, 18 m" onto the floor I'd walked on; no collision on, flew level ~12 m/s, climbed at pitch 25, stopped
  within 0.2 m on letting go (braking set by bridge, same value), off -> fell and landed on a roof (walking).
  Not tested: space interiors and stations (navmesh can be missing there; the spots still work), a real stuck spot in
  level geometry, co-op (a joiner's body would need the host to move it), mantling (the issue's part 3, separate).

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
- TEST HAZARD: RegisterHook from a bridge command mid-raid crashed the game in UE4SS's hook dispatch (13:15), and GetAttachedActors with a Lua table out-param crashed it (13:09). Don't do either. Same for DataTableFunctionLibrary:GetDataTableRowNames (an FName array out-param, through
  Out.call too): crashed in UE4SS's out-param write-back (UE4SS +0x3a1e55 / +0x3a49bb -> Lua +0x9bd9ad, AV reading 0x8;
  2026-11-20, the probe's own source was still on the crashing thread's stack). Read a table's rows another way.

## Rivals arrive through airlocks (2026-11-07, later)
- Every station with RaidFrigateStationDock airlocks (StationAirlockDockingAreaAbility_*: Navy Outpost, Spaceport, Asteroid Mine, Penal Colony, Rebel Base, Moon Base, Colony Cruiser, Planet Killer) gets st.locks in survey(): chamber floor (InSideComp box), station-side button (OpenButton). Fortress, Merchant, Mini Mine have none: old arrival (pop in at an entry point).
- A docking crew takes c.lock = pickLock: berth i -> airlock i (sorted by name), skipping one your ship is docked at (DockedShips) or another docked crew holds. Docking while you're inside (FRESH_DOCK 25 s): bodies are built in that chamber (door closed, out of sight), crewArrival holds them (no rehome/patrol) for ARRIVAL_MIN 6 s and until armed (ARRIVAL_WAIT 12 s cap), then StartDoorEvent(true): the game's own hatch sequence (wheel, steam, opens in ~8 s; the passage unblocks at once, so they wait DOOR_OPENING 7 s), then walk to lockExit (past the button) and search as before. The door closes (StartDoorEvent(false)) ARRIVAL_CLOSE 10 s after, once nobody stands in the chamber. Leaving: they walk back to the same airlock.
- Verified: Asteroid Mine (2 of 2 and 3 of 3 in the chamber), Penal Colony (1 of 1), Navy Outpost on Space_Solo_01 (2 of 2); frames show DOCK-3C open and a rival stepping out. Open/close checked by eye from inside a chamber. bIsOpen stays false through StartDoorEvent; DoorMesh / bone reads don't show the animation (and GetBoneName/GetSocketLocation from Lua crashed the game once).
- Not done: a cue before the door (the hatch sequence itself is the warning: ~6 s cycle + 7 s opening); linking the ship's real dock to the airlock (the berth -> airlock map is a fixed assignment, not what the game would pick).
- Tools: bridge/t_lockprobe.lua (doors, chambers, paths; LOCK_OPEN/CLOSE), t_inchamber.lua, t_watchlock.lua, t_arrivals.lua. backend/state.before-airlock-test.json.

## Pods, parked ships, the Mini Mine berth (2026-11-07, evening)
- Black void after a pod breach (user): the pod hit a rival ship parked at the Mini Mine (state "docked"). playerBoarding only made interiors for flying crews, so the hull had no MyShipInside and the game left your on-foot body where it parks during a pod flight, at 0,0,0. Docked ships are boardable now. rescueFromVoid: on foot within VOID_NEAR (3000) of 0,0,0 for VOID_RESCUE (3 s) -> moved to your own ship's first entry point, with a message. (The user's stuck game was rescued by bridge/t_rescue.lua.)
- Guard on parked ships (user: no easy cheese): a docking crew gets c.watch = SHIP_WATCH 1-2 extra members (setWatch, newMember, crew team, rolled like the crew, kept for the raid). Boarding a docked ship materializes the living watch at breach spots other than yours (mode "boarding", alert). The docked branch no longer dematerializes boarding bodies (it did every update: the watch was rebuilt over and over). Verified: Stray Dog, 2 of the watch aboard, 26 and 30 m from you, team 20, armed; logged once.
- **Unguarded hulls (2026-11-24, #429; NOT tested in game).** When a docked crew's raiders all died (simulated "died raiding", or killed in the station), `crewAlive` (members only) went false and the ship became a "derelict" with its living watch never materialized: an undamaged hull, often parked in the open at a breached-in hold point, free to take. Now the living watch becomes the crew (log "raiders dead, N of the watch keep the ship"), and boarding a docked ship with no watch left materializes its crew. Not verified: that this is the case players hit (capital ships with no crew ever spawned weren't ruled out).
- Grease Gun on the pod (user: the gun they carried): while pc.Pawn.bADropPod, main.lua hides the on-foot body's Inventory guns (SetActorHiddenInGame) and shows them again on foot. Verified hidden=true in the pod, false after.
- Ship flying into the Mini Mine rock: (1) its one berth was the 0.8 m RaidDocking00 marker 7 m under the real RaidDocking01 dock (dedupe kept the first): now the biggest volume of overlapping ones, and BreachVolume components are not berths (the biggest-volume rule had picked the Colony Cruiser's). (2) Crews waiting for a full station held at approach + c.id x 900 in X, + 1500 Z: now HOLD_OUT 2500 + spacing straight out along the approach lane. Verified: docked ship 5 m over RaidDocking01 at rest; three waiting ships 115-180 m out, drifting in open space. Each berth is logged at survey. The Mini Mine's position differs per run.
- **Quick deploy (2026-11-24, #459; NOT tested in game).** F9 "Quick deploy to the nearest station" (debugactions.lua, rivals.lua R.quickDeploy): in space, on foot aboard your own ship (not at the helm: leaving the helm by Possess wasn't verified safe), puts your body on a projected walkable entry of the station whose box centre is nearest your ship, fades in from black over 1.5 s, and sets S.podSeen so playerBoarding's podExitCheck runs 1.5 s later as after a pod exit. Not the game's pod launch (hatch:OnUsed from Lua starts the pod at garbage coordinates, see "Pods" above). Log "[rivals] quick deploy: <station>, N m from your ship, at x,y,z". Unverified: the landing spot is on the floor, the fade call's colour struct, crewmates catching up (no S.breach: crew.lua's breach follow is for rival ships only), and stations near 0,0,0 (void rescue range).
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

- You and your crew walk through each other (2026-11-16, issue #62): passThrough() in crew.lua, called when a body
  is finished, sets PrimitiveComponent:IgnoreActorWhenMoving both ways (crewmate capsule ignores your on-foot pawn,
  your capsule ignores the crewmate). Enemies still collide with both; shots are separate traces. Tested on
  Space_Solo_01 aboard the ship with bridge/t_walk.lua (sweep the player 300 units forward, Noor placed 150 ahead):
  Noor out of the way 197 (a wall), ignore turned off 62 (stopped at Noor), with the fix 197 (through Noor to the
  wall).
- e.stuckAt meant two things (2026-11-16): crew.lua kept the crewmate's stuck position in it (cutOff), main.lua's
  cover code the time a soldier's move stalled. A crewmate in a cover fight made main.lua:1480 do arithmetic on a
  position: "update failed: main.lua:1479: attempt to perform arithmetic on a table value (field 'stuckAt')", which
  ended that whole update() pass (seen 3 times in a player's log, 16 Nov, Space_Beta). crew.lua's is e.stuckPos now.

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

- 2026-11-24 (#411, crew missing on the first raid after starting the game, later raids fine): no start-up ordering
  bug found (crew.lua is read in H.init; D.raid is built in payWages at launch). One way it could happen only on the
  first raid: pc:GetCash() not readable yet, so spend() failed and everyone "stayed home" (no message is seen, the
  lobby is going). Now an unreadable cash lets them come unpaid, logged "wage N not taken (your cash couldn't be
  read)". Unconfirmed: needs the reporter's first-raid log (crew: ... paid / stays home / comes along). Not tested in game.
- 2026-11-25 (#391, first part): crew health readout. One more TextBlock on the nametag host (crew.lua buildTags,
  so no new widget and it dies with the world like the tags), refilled by updateHud from C.tags every 0.25 s and only
  SetText when the text changes: "Name  87%" per crewmate (body Health / maxHp; m.hp while bodiless), "down" once dead.
  Position CFG.HUD_X/HUD_Y (24, 320). Switch features CREW_HUD (Tuning > Features). On-foot orders not done yet.
  Passes luacheck; NOT tested in game (placement may overlap game HUD).

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

- Gunner callouts (2026-11-16, issue #52): fireTurrets leaves the reason in c.held ("range" or "arc") when no turret
  of the hull can bear on the target at all (any turret in arc, reloading, swinging or pitching = nil). crew.lua
  heldCall: after HELD_SAY (3) s on the same target and reason, the gunner says it once: "<name>: the <target> is too
  far, close in" / "<name>: can't swing onto the <target>, turn us toward it". Tested on Space_Solo_01 at a flak node:
  11000 away facing it -> the range line; 5000 away facing away -> the arc line, each a few seconds after "engaging".
- Sniping station turrets (2026-11-16, issue #47, Hayley's option 2): CFG.TURRET_RANGE_STATION = 13500 (the node
  turrets' FireDistance). gunnerFire sets gun.reach for a target whose class has "NodeTurret" in its name, and
  fireTurrets uses max(type range, reach); ship-to-ship ranges (TURRET_TYPES) are unchanged, so rival duels behave as
  before. Tested on Space_Solo_01, starter hull 12000 from a Flak_NodeTurret facing it: "Noor: engaging the turret",
  150 -> 21 -> dying in ~15 s (the shells do carry that far). Two earlier test crashes (UE4SS, read of
  0xffffffffffffffff) were the bridge probe reading the turret after the gunner destroyed it: probe by path
  (StaticFindObject) and stop at bIsDying.

## F3/F9 in the lobby, borderless fullscreen (2026-11-09)
- F3/F9 did nothing in the lobby: they looked up FindFirstOf("MainPlayerController_C"), and the lobby's controller is
  MenuPlayerController_C (in a raid it could also be the last map's). Now F3/F6/F9 all use Hire.lastPc() (the ticking
  controller), each closes the other two, and Tuning/Debug tick from every ticker like the crew menu. Closing in the lobby
  gives the lobby its mouse UI back (menuClosed in main.lua); Z-order 5000/5010 so they draw over the lobby pages.
  Bridge-flag path (bridge/menu_toggle, debug_cmd) unchanged. Real key presses still NOT tested after this change.
- Launcher "Borderless fullscreen" box -> config/window_mode.txt (borderless|windowed). launch-offline.ps1: borderless
  writes FullscreenMode=1 (+ desktop resolution from Win32_VideoController) into %LOCALAPPDATA%/RaidGame/Saved/Config/
  WindowsNoEditor/GameUserSettings.ini and drops -windowed/-ResX/-ResY; windowed keeps the old 1600x900 args.
  Superseded 2026-11-20 (#292), see "Window mode lives in VideoSettings.sav" below.
- Window mode lives in VideoSettings.sav (2026-11-20, issue #292; scripts/videosettings.py, launch-offline.ps1).
  Players: loading into a raid put the game back into a small window, and fullscreen picked in the raid's Settings
  reverted. Cause: the game keeps its own video settings in Saved/SaveGames/VideoSettings.sav (SG_VideoSettings_C:
  ScreenResolution IntPoint, EWindowMode as a ByteProperty holding the enum's name, MotionBlur, FovModifier, UIScale,
  VideoVersion) and applies them over GameUserSettings.ini at start-up (it rewrote the borderless box's ini values to
  FullscreenMode=0 1920x1080 from the save, so that box likely never did much once a save existed). The only thing that
  made the window windowed was -windowed -ResX -ResY, and UE4 re-applies command-line overrides whenever settings are
  applied. Now launch-offline.ps1 passes no window switches; videosettings.py rewrites those two properties in the save
  (exact round trip checked on a real save) and only when the launcher's choice ("<mode> <W>x<H>") differs from
  config/window_applied.txt, so a choice made in the game's Settings afterwards stays. No save yet (first run): the
  game's default, applied from the next launch. launch-joiner.ps1 (second instance on one PC) keeps the switches: both
  instances share the one save.
  Tested in game: launch -> UnrealWindow 1616x939 with a caption, GameUserSettings FullscreenMode 2 1600x900;
  SetFullscreenMode(1) + ApplySettings(false) -> 1920x1080 popup, still so after `open /Game/Maps/MainMenu`.
  Same steps with the old `-windowed -ResX=1600 -ResY=900`: the map load put it back to the 1616x939 captioned window
  while GameUserSettings still said FullscreenMode 1 (the bug, reproduced).
  Not tested: a real raid load, the game's own Settings menu by mouse, a fresh install with no save.
- F9 gun and ammo picker (2026-11-16, debuggive.lua; Debug.addActions appends its rows): Gun: <name> (click = next),
  Previous gun, Give me the <gun>; Ammo: <name> (click = next), Give me <stack> <ammo>. In a raid, on foot. Rows,
  kinds (0 long gun, 1 pistol) and magazines / stacks are from assets/saves/items.json (12 of 45 magazines I had
  typed from memory were wrong; Klobb and Sawed-off are type 1, so pistol slot). Both go through
  SIGISPlayerController:Server_AwsN_EquippedItemsReturned, the loadout path: one item string
  "<id>-<Row>-<Stack>-100-<Col>-<Row>-0-<Container>" registers the item, spawns the weapon, loads it and equips it,
  mid-raid too. Guns: first free of Prim, Sec (Pistol for type 1), read from StashedItems' MotherItemGUID; a second
  gun into a taken slot (tried by bridge) left the first in your hands with its item hidden behind the new one, so
  a full set is refused. Ammo: first free PocketLeft/PocketRight cell (ItemInSlot.Column/Row).
  Tested via bridge/debug_cmd: M45 36 -> Prim, Thompson 30 -> Sec, third gun "No free gun slot", SPP-1 4 -> Pistol,
  second pistol refused, 60 9mm and 60 .45 in separate left-pocket cells; the inventory screen showed all of it.

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

## Boarder corpse legs explode into spikes (seen 2026-11-14, fixed 2026-11-20, #10)
A Rusty Mule boarder killed on your ship (Space_Alpha, MG42) lay with its legs/feet stretched into a fan of black spikes
(skinned mesh blowing up on the ragdoll). Torso, pack and helmet fine. Probably a rival kit's lower-body part on a body
it doesn't fit, or the ragdoll of a pod-spawned body; check rollKit leg pieces vs the female/male body. Bad for footage.
The female skin weight damage found 2026-11-20 ("Vertex explosions on women's outfits"); the user confirmed it is this.

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
- 2026-11-24 (#365, #367, NOT tested in game): the void rescue (rivalcombat.lua rescueFromVoid) is the only mod code that
  puts you back in your own ship, which matches #365 ("teleported back to my cockpit" on a second breach). It fired
  after VOID_RESCUE 3 s on foot near 0,0,0, barely above the game's own ~2.5 s breach park there, and always when the
  hit ship had no interior (wreck not boardable, PLAYER_BOARD_MAX reached, interior slower than VOID_BOARD_WAIT). Now
  VOID_RESCUE 6, no rescue while pc.ShipBreachingTo is valid (property name from RVA 0x183da40 notes, not read live),
  and a log line with why ("void rescue after ..."). #367 (stuck in the Merchant breach tube) is not explained:
  podExitCheck only acts with no floor under you or a parked body; likely another offline-only Blueprint branch like
  Fortress's shaft. Next report: check the log for "void rescue" / "out of the pod" lines.

## Station fights end too fast; AI legs too fast (2026-11-14; arrival stagger tested 2026-11-16)
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

- Tested (Space_Alpha raid, Rebel Base, god mode, 2 min fight with its guards, 2026-11-16): three crews docked at Rebel Base came in through its airlocks at 22:49:03, 22:49:49 and 22:50:34,
  45-46 s apart; the later two waited 31 s and 41 s in the chamber. Leg speed was not watched on screen.
## Crews and guards by station size (2026-11-14; guard counts tested 2026-11-16)
- User: bigger stations should have more people, and fewer crews should go to the small ones. Station size = its
  navmesh box floor area, logged in "[rivals] stations:" (Space_Solo_01: ~4k to ~107k m2).
- chooseStation is a weighted pick: capacity = area / STATION_AREA_PER_CREW (15k m2, at least 1), weight =
  capacity x STATION_CROWD (0.35) ^ (crews docked/heading there / capacity).
- Guards: MIN_DEFENDERS is for a STATION_AREA_MID (35k m2) station; small ones get as few as half, big ones up to
  DEFENDERS_MAX_SCALE (1.5x). STATION_AREA_PER_CREW and STATION_CROWD are in the AI menu.

- Tested: Rebel Base (96k m2) got 8 of its own guards plus 1 = 9, the 1.5x cap on MIN_DEFENDERS 6. Fortress (48k m2,
  a tester's log the same day) got 7 + 1 = 8, about 6 x 48/35. All three crews of the run went to Rebel Base, the
  largest station; one run says little about the weighting.
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

## Director per-frame cost: ships off the helm, calm bots, fewer engine reads (2026-11-17, tested)
- rivals.lua R.frame: on foot (S.onFoot, set in R.update: your character is the pawn, not the helm, a turret seat or a
  pod), glideShips, fireControl and swingAimed run CFG.SHIP_FRAME_HZ_FOOT (15) times a second with the real time
  since the last pass (glides go by the clock; gunnery and swing scale by dt, capped at 0.25 s). Pods and boarding
  still run every frame. At the helm: every frame, as before.
- main.lua trackTargets: bots at peace (not fighting, in cover, investigating or running) run animate() and their aim
  upkeep at CFG.ANIM_PEACE_HZ (15) instead of ANIM_HZ (30); a change of what they should be doing is still caught at
  once. The two per-frame loops after reapDead no longer re-check valid(bot) and Health (reapDead just did, and
  nothing is freed mid-frame): four engine calls per bot per frame fewer. Parked bots are skipped in both.
- updateBots reads each bot's location once per update (o.updAt) for the perception list, Aux.parked and its own
  loop; it used to read it three times (each read is a new table).
- Test: Space_Solo_01, Fortress, 14-16 guards and 8 crews, everyone's senses off (ai.lua PROFILES sight 1, hearing 0,
  from bridge/dir_eval.lua) so both runs are at peace; master's scripts vs this branch's, 120 s in the station.
  Per 10 s: rivals frame 554 -> 134 ms, aim 276 -> 233 ms, director total ~1000 -> ~550 ms, allocated 16.6 -> 11.3 MB.
  Frame rate unchanged on this PC (~76-80, not director-bound). Runs with fights aren't comparable: fights are
  random and fighting bots keep the full rate (cover alone went 34 -> 386 ms when 4 bots fought).
- Which stations have a docking node (and so a "station" in rivals' list) differs per run of the same map: test
  scripts should retry until the station they want is there.

## Build 4 quick wins: looting stutter, far animation, hot reload (2026-11-17)
- invkeys.lua menuWidget() ran FindAllOf("SIGIS_Exit_Widget_C") every 2 s while the inventory was open, until the pause
  menu had been opened once in that raid (44-101 ms each in bridge/profile.txt): a stutter while looting. Now it only
  looks once ExitMenu_Open's hook has run in this world (menuOpened, reset when the old world's widget is gone). The
  stuck-inventory check also needs the widget in the viewport (IsInViewport), not only flagged visible.
- Far animation (animDistance, ANIM_FAR): on by default; bridge/anim_far_off turns it off for testing (it used to need
  bridge/anim_far_on, so release never had it). In game: animSwitch counts in profile.txt, no errors, 14-16 bots.
- config/UE4SS-settings.ini EnableHotReloadSystem = 0: UE4SS 3.0.x reloads every mod on Ctrl+R, which is crouch +
  reload in a fight. Developers who want hot reload can set it back locally.
## Parking far-off guards, a cap on bodies awake, fps in the status line (2026-11-17, tested)
- Build 4 testers report 10-15 fps in raids. Found: every station you enter adds its guards (own NPCs adopted, plus
  top-ups to MIN_DEFENDERS) to raid.bots, and nothing ever put them back to sleep: updateBots even wakes any bot the
  game had put to sleep. After a few stations, dozens of guards far away kept their per-update AI, sized up every other
  body within PERCEIVE_RANGE (n^2), and ticked skeleton and movement every frame. Rival crews were fine (they go back to
  simulation 20 s after you leave).
- main.lua Aux.parked (main.lua and rivals.lua are both at Lua's 200-local limit, hence Aux / R fields): a guard or
  soldier at peace (not a rival, not your crew, not fighting, alerted or investigating) farther than CFG.PARK_RANGE
  (15000) from your on-foot character gets time dilation 0 (body and controller), movement and pose ticks off, and is
  skipped by updateBots, the perception candidate list and trackTargets' animate loop. Back within 85% of PARK_RANGE,
  or hurt, e.parked is cleared and updateBots' existing wake() branch (dilation < 1) brings it back.
- rivals.lua CFG.AWAKE_MAX (16), R.awakeCount(): a crew about to materialize in your station waits aboard (the same
  waitingRoom path as insideCap) while that many bodies are awake around you (parked and your crew don't count), and a
  station's top-ups stop at the cap ("N more guards wanted, room for M"). Both settings are in F3 > How many; 0 = off.
- The 10 s status line now has "parked N" and "fps N" (frames counted in onTick's aim step), so testers' last_game.log
  carries frame data without the profiler.
- Test (Space_Solo_01, MIN_DEFENDERS 14 and CREWS 8 set from bridge/dir_eval.lua, t.MaxFPS 0, god mode; teleport into
  Navy Outpost for 60 s, back aboard your ship for 120 s; master's scripts vs this branch's, same route):
  master 67-77 fps, director over 10 ms on 10-16 frames per 10 s; branch 89-96 fps, 0-3 frames over 10 ms, 12 of 14
  guards parked (the 2 still fighting stay awake). Back in Navy Outpost: parked 0, patrolling and fighting again, no
  Lua errors. Not measured: a slower PC, and a full raid of several stations (should gain more, as nothing piles up).
- Testing tips learned: splash PLAY doesn't always take its bound event from Lua (real click instead);
  Crew_LaunchToMatchBtn_SubWidget_C:BndEvt__Btn_Main_..._OnButtonPressedEvent__DelegateSignature() starts a raid from the
  bridge. A test raid appends to cover/<map>.txt (tracked): check it out again afterwards.

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

## Baked cover never used inside Rebel Base; soldiers out of sight backpedal (2026-11-14; tested 2026-11-16)

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

- Tested (Space_Alpha raid, Rebel Base, god mode, 2 min fight with its guards, 2026-11-16): play areas found RebelBase 101 markers. Soldiers took baked cover ("firing on the way to baked
  lean-left cover 521 away", "baked low cover 109 away") as well as random cover. Fighting samples: hiding 39,
  peeking 37, moving 94, open in sight 10, open unseen 27.
## Fight hitches and garbage: stray sweep, turret swing hook, per-frame aim (2026-11-14; tested 2026-11-16)
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

- Tested (Space_Alpha raid, Rebel Base, god mode, 2 min fight with its guards, 2026-11-16, profile_on, 10 bots): frame gaps over 100 ms 0 in every 10 s window during the fight, worst 27-35 ms.
  GC stepping 56-82 ms per 10 s (was 0.5-2.4 s). Hook garbage 0.5 MB per 10 s (was 54-75 MB). Placed NPCs came from
  the spawn hook ("8 placed NPC(s) to adopt (from the spawn hook)"). Turret swing hook calls still ran at ~400 a
  second (was ~5000) with your own ship's turrets in the world.
## Every baked cover spot "off limits": integer vs float cell keys (2026-11-14; tested 2026-11-16)
After 12ffc4a soldiers in Rebel Base (Space_Alpha, 101 markers) still fought in the open: every cover search logged
"baked 40, off 40". bridge/t_off2.lua ran the same rule from the bridge on one of those soldiers: all 97 baked spots
near it passed. The difference was the play-area cell key: offLimits built it with //, which gives a float for a float
("26.0", the engine's marker and soldier positions) and an integer for an integer ("26", baked spots loaded from
cover/*.txt). Baked spots never found their markers. Both keys now use math.floor (an integer either way).

- Tested (Space_Alpha raid, Rebel Base, god mode, 2 min fight with its guards, 2026-11-16): cover searches logged "baked 40, ... off 6" and "baked 40, ... off 18", no longer all 40. Baked
  spots were picked and reached.
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
  OnSpaceSalvageChange (from OnRep_HasSpaceSavage) has no Blueprint implementation, so nothing lost there. **Wrong for
  FrigateInside_Starter_C**: it does implement it (door, lever panel), see issue 134 below.
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

## Crew gunner never shot stationary turrets (2026-11-16, tested; rivals.lua nodeTurretAlive)
Issue #40. nodeTurretAlive tested `t.bIsDying == 0`, but UE4SS returns bIsDying as a Lua boolean, and `false == 0` is
false. So every RaidSubNodeActor_Turret counted as dead: hostileShips never listed the ones aiming at you, and
pickShip (left-click orders) never offered them. It now treats only `true` or a non-zero number as dying.
- Before (Space_Solo_01, gunner Noor level 1, hull parked 11000 and then 5000 from a flak node that was aiming at the
  hull, CurrentAimingActor = your ship): no "engaging" call, and the flak's health stayed at 150 while the hull went
  575 -> 495.
- After (Space_Charlie): "Noor: engaging the turret" 1 s after parking 5000 away. Four MovingFlak nodes killed the
  hull in about 18 s, and all shots were held by arc: SetControlRotation doesn't turn the hull, and the starter has
  one front turret (GUNNER_ARC 120).
- After, Space_Solo_01, hull set to face the flak 6000 away (hull health topped up each second): flak 150 -> 110 -> 22
  -> -21 (bIsDying true) within about 12 s, then "Noor: engaging the Widowmaker" (a crew attacking you), so a dying
  turret is dropped.
- Test path: hire with bridge/crew_cmd "hire 1" in the lobby, then pc:Possess(Ship_StarterFrigate01_Pawn_C) from the
  bridge; F at the helm from the bridge didn't take. Node turrets' FireDistance is 13500, beyond every hull turret's
  range (6000-9500, TURRET_TYPES), so between those distances they can hit you and you can't hit back.
## French female voice free from the start (2026-11-16, tested; backend/nakama_standin.py)
Issue #27. You can play as a woman from the first launch, but the cheapest female voice cost credits.
- DT_PlayerAppearance (row struct UnlockCosmeticData: ItemName, slot 0/1/2 = head/body/voice, UnlockRequirementStatName
  + Amount, UnlockCostAmount, PrestigeUnlock, ChapterUnlock) has these voice rows: enM01 0, frM01 3500, frF01 3500,
  plM01 4200, duM01/duF01 58000 (L_7), usaM01/usaF01 65000 (L_10), roM01 70000, huM01 76000, itF01 80000 (L_18),
  auM01 95000, itM01 115000, str01 prestige. Rows were read from memory with a scratch reader modelled on
  offline-audit/voicerows.py.
- SIGIS_InventoryWidget isThisCosmeticUnlocked (kdis) treats enM01, head "1" and body "6" as always free. Anything else
  must be in InventoryMenuWidget:GetUnlockedCosmetics (native 0x9f52e0). That reads
  SIGISPlayerController.UnlockedCustomisations (+0x8a0) plus the prestige unlocks.
- Storage format: playerstats/cosmeticsunlocked holds row names joined by "-" (seen after
  pc:SetPlayerUnlockCos(FName("frF01")) then "usaF01": "frF01-usaF01"). SetPlayerUnlockCos is the purchase. It also
  charges UnlockCostAmount (cash PUT plus statChangeArray). "!"-joined values are not parsed: the list stays empty.
- Fix: the stand-in's masterstartfunction adds FREE_COSMETICS ("frF01") to cosmeticsunlocked in what it sends. The
  save file is not changed. The game holds it in its list from then on, so a later purchase writes it back with the
  rest.
- Tested on a fresh boot with an empty cosmeticsunlocked: UnlockedCustomisations = {frF01}. Loadout > Appearance >
  Voice shows FRENCH 02 without a lock. Selecting it wrote only cosequipped/voice = frF01 (no cash write).
- Crashes while probing (don't repeat): calling InventoryMenuWidget:UnlockCosmetic("frF01") with a guessed signature,
  and appending to pc.UnlockedCustomisations from Lua (`a[#a+1] = "x"` on an FString TArray in UE4SS 3.0.1).
- Unlock all looks and voices (2026-11-16, issue #48, Hayley: a toggle): launcher checkbox -> config/unlock_all_looks.txt
  (on/off). The stand-in's with_free_cosmetics adds ALL_COSMETICS (every DT_PlayerAppearance row: heads/bodies 1-56,
  61-72, 84-90, 92-95 and the 14 voices; Pirate/Mod 57-60 left out, cost 1, likely dev placeholders) to what it sends
  at login, never to the save. Tested: on -> UnlockedCustomisations 93, Appearance > Voice all unlocked; off ->
  1 (frF01) and the save's cosmeticsunlocked still "". With everything unlocked nothing can be bought, so the game
  never writes the full list back into the save.
## A taken ship's key card (2026-11-21, #311; NOT tested in game)
Reported: a player took a rival capital ship, left through a station airlock and couldn't get back in; no crew member or
captain carried a card. Nothing in the mod ever made cards for rival ships (bodies get loot through `X.addItem`, which
takes no Attachments, so a card can't go on the captain's body that way).
- Fix: `rivalcombat.lua checkStolen` (the moment the game hands you the rival's hull) calls `space.lua cardForShip`. It
  removes the KEYCARD in your KeyCard slot (`Server_RemoveItem`), adds one for the taken ship with
  `Server_AddItem(KEYCARD, 1, 100, "KeyCard", ..., att)` where att = `<your name>!<ship name>!<interior KeyCardUUID>!<hull row>`,
  and sets `raid.card` to it so guardKeyCard guards the new card, not the old one.
- Not verified: that the station airlock accepts a card made this way for a rival interior (the UUID is read from
  `c.inside.KeyCardUUID`), and that removing the old card mid-raid has no side effects.

- 2026-11-24 (#410, the user: cards should be on the bodies, so you can collect several ships'): every rival crew body
  gets its ship's KEYCARD in its loot as it's built (rivalbodies giveShipCard, from rivals.lua finishBuilding; corpses
  before they're killed, since death copies the loot). The native add-item takes a row only, so the Attachments
  (space.lua shipCardAtt: you!ship!interior KeyCardUUID!hull row; UUID 0 when the interior isn't loaded) are written on
  the new item and read back, logged once if they don't take. cardForShip (taking the helm) now does nothing when you
  already carry that ship's card, so your other cards stay. Verified in game: UE4SS writes an FString property and reads
  it back (PlayerState.PlayerNamePrivate in the lobby, restored after). NOT verified: a body's card in a raid, the card
  being turned away by a full pocket, a station airlock accepting a looted card, UUID 0 cards.

## No captain's key card at raid start (2026-11-16, tested; main.lua guardKeyCard)
Issue #33. Reproduced on Space_Beta with the test save's empty loadout: the player's inventory had no items and no
KEYCARD 35 s after boarding, and guardKeyCard logged nothing, because it only puts back a card it has seen.
- SIGISInventoryComponent:Server_ReadyforKeyCard (no params, server RPC) makes the card. Called by bridge, KEYCARD
  appeared in the KeyCard slot a second later, Attachments "<captain>!USS Oberon!75312034!FrigateStarter_Ship" (the
  interior's KeyCardUUID). A second call doesn't add another card (still 1).
- guardKeyCard now calls it when no card has turned up 6 s after boarding (CARD.GRACE, at most CARD.ASKS = 3 tries,
  every CARD.CHECK = 2 s). The card it gets is then remembered and guarded as before. CARD is a table because main.lua
  is at the 200-locals limit.
- Tested on a fresh launch, empty loadout: "none 6s after boarding; asked the game for one (1)" at +6 s, then
  "key card: Vanquisher!16368391!FrigateStarter_Ship" at +8 s; 1 card. Not tested: using this card at a station airlock
  (it is the game's own card, the same kind the 2026-11-07 tests used), and which normal-start step fails to ask with
  an empty loadout.
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
## Settings on the title screen and in the lobby (2026-11-21, issue #293; mods/PvEDirector/Scripts/gamesettings.lua)
Players could reach the game's Settings only from the pause menu in a raid.
- The Settings widget already exists outside a raid: SIGIS_MainOverlay_C ("In Game Overlay Menu", on the game instance,
  so it lasts the session) holds SIGIS_Options (collapsed) with tabs MM_GenericTabBtn_Video/Audio/Gameplay/Social/
  Controls/MISC and pages WB_Options_Video/Audio/Gameplay/Social/Controls/Misc. Its lobby button,
  MM_SecondaryOptionsBtns_Settings (Which_SecondaryOptions = 1), is in the collapsed Border_BottomBar_Old.
- Called from Lua (bridge), none of these opened it: overlay SwitchToOptions (Lua error, a UE4SS error object),
  OptionsPressed (ran, nothing shown), SIGIS_MasterMenu_C:SwitchToOptions (error), the hidden button's
  BndEvt__Btn_Main_..._OnButtonClickedEvent (ran, nothing), Switch_Options_State with 0 or 1 args (error). UFunction
  ForEachProperty also failed on these functions, so their parameters weren't read.
- What works: SIGIS_Options:SetVisibility(0), the Video page SetVisibility(4) and
  WB_Options_Video:InitializeVideoSettings() (until then Resolution, Window Mode and UI Scale are empty dropdowns).
  Then real clicks on its tabs switch pages, and its X (BndEvt__BACKBTN_...) collapses it. A change made there
  (Motion Blur) was written to SaveGames/VideoSettings.sav when it closed.
- gamesettings.lua: a SETTINGS button on the title screen (SIGIS_LoginWidget_C, a copy of MM_GenericSmallBtn01_Exit
  plus a Spacer, after PLAY), and a SETTINGS tab after SOCIAL in the lobby's top bar (as quit.lua's QUIT,
  Which_CoreMenuState 99). Clicks are polled (Btn_Main:IsPressed, a release after a press).
- UPanelWidget InsertChildAt / ShiftChild aren't Blueprint functions, so UE4SS can't call them. Putting a widget
  mid-row means taking the later children out and adding them back. Done to the title row, PLAY then no longer
  started the game; so the title button goes at the end, and the lobby tab only moves our own QUIT tab (state 99).
- A synthetic click needs the cursor already over the button (a first click right after moving there did nothing)
  and a press held long enough for a poll to see it (250 ms worked, 80 ms was missed). The helper process must be
  DPI-aware (SetProcessDPIAware) or its cursor coordinates are scaled; Slate also wants real mouse-move events
  (mouse_event MOVE), SetCursorPos alone isn't seen.
- The lobby top bar (HorizontalBox_Core_MM_Tabs) is centred, and the money readout starts right where its five 180-wide
  tabs end: QUIT alone already ran into the "$", and with SETTINGS too, QUIT went under the money. All tabs in the bar
  are now 130 wide (WidthToUse + PreConstruct(false)). PreConstruct and a take-out-and-add-back both clear our tabs'
  labels (the designer text is empty), so labels are read first and set again.
- Tested in game, 2026-11-21, on a throwaway save (stutter-test-295): title row EXIT · PLAY · SETTINGS and PLAY
  starts the lobby; lobby bar LOADOUT TRADE PLAY CONTRACTS SOCIAL SETTINGS QUIT, all labelled, clear of the money;
  SETTINGS opens Settings over the blurred lobby, X closes it, TRADE works after; QUIT's first click still arms it
  (SURE?). Not tested: Settings in the lobby after a raid, gamepad.

## Offline guild: guild page and guild shop (2026-11-16, tested; mods/PvEDirector/Scripts/guild.lua, issue #68)
Guilds live on PGOS (membership, members, chat, hideouts) and Nakama (guild XP). Offline, PGOS never answers, so
SOCIAL > GUILD stayed an empty hall and the TRADE page's GUILD shopkeeper (First Mate Calico) stayed locked.
- Shop gate: SIGIS_InventoryWidget_C:Shopkeeper_CheckFactionGuildRankBlocker. For WhichFaction 4 (guild) it only checks
  that SIGIS_ExampleGameInstance_C:GetMyGuilds returns at least one entry in MyCurrentGuilds
  (TArray<PgosSDKCpp.ClientGroupItem>). Lua can grow it (`list[1] = { unread_count = 0 }`), then set
  `[1].group_brief.group_id/Name`. Then the shopkeeper opens. Buying (Guild Beret, $630) and selling go through the
  usual stand-in path. Side effect: the lobby's crew card label reads GUILD instead of FREEBOOTER.
- Page flow (Guild_Widget_C, /SIGISPlugin/Widgets/MainMenu/Guild_Widget):
  - GUILD_Widget_OPENED collapses its panels and calls gi:GetMyGuildList(onError, CheckOveralState).
  - The PGOS_MyGuildLists answer calls GetGuildInfo, then PGOS_MyCurrentGuild, which sets MyCurrentGuild_Info.
  - From there the page asks GetGuildMember, GetNakGuildInfo (GUILD_Get_NakamaGuild_Info) and GetGuildMembers.
  - PGOS_SuccessGetMembersList creates a Guild_Member_Row_SubWidget per member: GroupMemberInfo is set, then the row
    is added to the Owner, OFFICER or CREWMATE box.
- UE4SS 3.0.1 can't pass the PGOS answer structs: anything holding a TMap fails, with a function as the pcall error.
  So guild.lua sets the same widget fields and texts directly. NakamaGuildInfo {GuildXP, GuildUnlocks,
  numOfActiveServer} has no map, so GUILD_Get_NakamaGuild_Info and GetGuildProgressionStuff are called as they are
  (XP 500 = rank 5, 35/155).
- Rows: Create, fill GroupMemberInfo (nickname, player_info.display_name, is_owner/is_admin, joined_time in unix
  seconds, player_presence.Status 1 = Online), then AddChildToVerticalBox. Construct draws them. Rows with no GuildInfo
  show no PROFILE/MESSAGE/CREW INVITE buttons; those are collapsed anyway, since they're PGOS.
- Hidden, because they need PGOS or online servers: Border_GuildHideOut (hideout regions, START/JOIN),
  SizeBox_GuildChat, the leave button, and SizeBox_PermissionBasedStuff (the owner's edit panel: announcement,
  visibility, patch, tags, disband). The SUMMARY/PROGRESSION sub-tabs work as they are.
- Members: Haywire Hayley (captain), Lilykoi (officer), and 10-16 crew mates drawn at random per game start from the
  Discord member list, about 30% shown online. You are added too, with the stand-in save's display_name.
- Timing: the page counts as visible behind the login screen, so it is filled only after the game has fired
  GUILD_Widget_OPENED (pre-hook, re-registered when the UFunction moves). The guild entry is only set once the login
  widget is gone.
- Test harness gotcha (not the mod): pressing the login screen's PLAY before the stand-in has seen
  authenticate/getbuildinfo (a few seconds after the splash shows) crashed the game every time: a C++ exception, the
  same stack 4 times. The test helper now waits for getbuildinfo.
- Tested on fresh launches: the page fills on the first open and on reopening. Summary/Progression clicks work, the
  shopkeeper opens by mouse, the beret bought, and raids started fine (Space_Solo_01; Space_Delta with the module off
  for comparison). One raid load on Space_Delta exited silently with no dump and didn't repeat.
- kdis.py now decodes the delegate opcodes (0x5C, 0x5D, 0x61-0x63) and set/map/array literals (0x39, 0x3B, 0x3D,
  0x3F, 0x65).
## Offline guild: editing it (2026-11-16, tested; guild.lua)
You now captain the offline guild, and Haywire Hayley and Lilykoi are officers. The page's EDIT GUILD tab
(Btn_GuildTab_EditGuild, MM_GuildTab_EditGuild, SizeBox_ApperanceSubTabsDivide) is shown, MyCurrentGuild_AmIOwner is
set, and the tab's own handler shows SizeBox_PermissionBasedStuff.
- Each control's bound event runs its own body first: checks and warnings, then a PGOS request (SetGuildIcon,
  SetGroupTags, ...) that goes nowhere. A pre-hook then reads the panel, applies the value to the page, and writes
  config/guild.txt (key=value).
  - Announcement Confirm (event 16) and Clear Message (27): Txt_PGOS_MyGuild_AnnouncmentMessage, shown in
    Border_GuildAnnouncment above the tabs. Collapsed when empty.
  - Is Public checkbox (44): YES/NO.
  - Join Type combo (45): index 0-2 is Open To Anyone / Invite Only / Closed To All. The combo's FStrings from
    GetOptionAtIndex came back as garbage; DefaultOptions reads fine.
  - APPLY NEW PATCH DESIGN (35): Edited_Current_Patch_Design/PrimColour/SecColour, saved as "d-p-c" (the PGOS Icon
    format). Also written to the game instance's guild entry (group_brief.Icon).
  - APPLY NEW TAGS (event 4, the button named ..._PubliclyVisible_1): EditGuild_Tags holds the E_GuildTags names, e.g.
    "HelpingHand". They are shown spaced.
- Badges: Refresh_MyCurrentGuild_Patch(d, p, c) and Refresh_MyCurrentGuild_Edit_PatchLook(d, p, c) draw nothing until
  MyCurrentGuild_Patch_DMAT and MyCurrentGuild_Patch_Edit_DMAT are set. Initialise_Guild_My_Info sets them, but only
  on the PGOS path. guild.lua sets them from Border_TEMP_MyGuild_PatchLook_ and
  Border_TEMP_CurrentPatchLook_EditPatch with GetDynamicMaterial().
- Restoring the panel when the page fills: checkbox, combo index and announcement text are set back, plus the
  Edited_Current_Patch_* values. Tag buttons (Guild_GuildTag_SubWidget_C in WrapBox_GuildEditTags) get "Is Selected"
  and isTagSelected(true) when their label (txt_GuildTagName) minus spaces is a saved tag. GuildTagsActive_EditGuild and
  the "n / 5" text are updated too. LoadCorrectTagLook_ForEditGuild(TArray<FString>) didn't work: the Lua table
  arrived empty.
- Disband (Border_Permissions_OwnerOnly_Disband) stays hidden. Guild name and description have no controls on this
  panel and stay fixed.
- Tested with real clicks and typing: each control logged "guild: ... changed" and wrote config/guild.txt. The Summary
  showed the announcement, YES, OPEN TO ANYONE, the tags and the new badge. After a relaunch all of it came back,
  including the edit panel's controls (3 / 5 tags selected). Clear Message removed the banner.
## Stuck in a loot window after rotating an item (2026-11-16, tested; invkeys.lua)
Tester report: with Use rebound to R (also Rotate's key), rotating an item in a container left the loot window drawn
over the game, while the game took mouse and keys again ("could move and shoot but couldn't see"). Reproduced with
default keys: in an open loot window, pressing Use (F) opens the pause menu (SIGIS_Exit_Widget_C:ExitMenu_Open fires
with no InGameMenu input action). Closing that menu leaves In Game Overlay Match's InventoryMenu (SIGIS_HUDWidget_C)
visible (visibility 4) with bShowMouseCursor false. This is the game's own behaviour; no mod code opens the menu.
- invkeys.lua now also hooks ExitMenu_Open (pre, re-hooked when the class reloads). If the inventory was open on the
  previous frame, it does what Esc does: the menu is closed, then the inventory on the next frame. So Use in a loot
  window closes it.
- Safety net: if InventoryMenu is visible with the cursor off, no pause menu and no mod menu, for 0.5 s,
  pc:CloseInventory() runs (visibility goes to 1). It logs "inventory was drawn without the cursor; closed it".
- Tested on Space_Charlie at a station crate (SIGIS_Container_Common5_2), with real key presses.
  - Before: F opened the crate, F again brought up the pause menu, and Resume left the window drawn with the cursor
    off.
  - After: F again closes the window and the "F Search" prompt is back.
  - Tab open/close and Esc in the inventory work as before. Esc outside the inventory still opens the pause menu.
  - Forcing InventoryMenu visible with the cursor off got it closed within 0.5 s, with the log line. The net never
    fired on its own.
## Your look and voice in raids (2026-11-16, tested; nakama_standin.py write_cosmetics, main.lua applyLoadout)
Tester report: "no voices or cosmetics actually appear to change in raid". The lobby showed the chosen head, body and
voice (cosequipped), but raids always had Raider_Head_Skel_01, Raider_Body_Skel_01 and the English male voice.
- Online, the raid server gets them as it gets the loadout:
  SIGISPlayerController:Server_AwsN_EquippedplayerCosmeticsReturned(FString). Offline nobody calls it, so the
  controller's EquippedHead/Body/Voice stay "". The pawn's ActiveVoice stays "" too, and PlayEmoteVoice falls back
  to enM01 when GetInGameActiveVoice() is empty.
- Shape: a JSON array of {"key": "head"|"body"|"voice", "value": "<row>"}. Passing the stored string as it is
  ({"value":"20"}) put that whole string into EquippedHead. A {"collection",...} storage-list shape and a flat
  object did nothing.
- The call sets EquippedHead/Body/Voice and the pawn's ActiveVoice. It resolves the rows to meshes in the pawn's
  replicated R_FaceMesh / R_BodyMesh (head 20 = Hunter_Head_Red_Skel_01, body 48 = Raider_Body_RedWhite_Skel_01;
  R_HeadMesh stays null). Nothing replicates offline, so the character only changes after pawn:OnRep_SetHead(), which
  applies both.
- The stand-in writes backend/cosmetics.json (gitignored) next to loadout.json, on startup and every save. applyLoadout
  feeds it to the controller right after the loadout, then calls OnRep_SetHead, and logs "cosmetics: [...]".
- Tested: save set to head 20, body 48, voice frF01. The lobby showed the red Hunter head and the red/white body. On
  Space_Charlie, CharacterMesh0 = Hunter_Head_Red_Skel_01, CharacterBody0 = Raider_Body_RedWhite_Skel_01,
  ActiveVoice = frF01. A real F1 (Voice01) sent RunOnServerVoice with DT_VoiceSet_FrenchFemale01. Not watched in third
  person.
## Pod breach into Fortress put you in a wall (2026-11-16, logic tested at the spot; rivals.lua podExitCheck)
Tester report with log (build 3, Space_Alpha): "out of the pod with no floor under you at 60356,114798,-1038: moved
to the floor at 60230,114665,-1203", inside a wall.
- At that spot the pod leaves you above a round hatch. The room below has its floor at -1626 (SM_Floor_400x3278,
  navmesh at -1623 straight under you). podExitCheck searched the navmesh 300, 600, ... below with a +-200 box, so it
  found -1203 first, 180 to the side. A trace from the exit to that point hits SM_WallRoundedCorner, and the point
  itself is on SM_Wall_Hole_9.
- Now: trace straight down first (Visibility channel, your body ignored, up to 1500) and land on the navmesh at the
  hit, or on the hit point itself when no navmesh is built there yet (it's built around you as you arrive; right
  after a teleport there was none). Any other candidate must be in sight from where you came out (a trace to it, 60
  above its floor, hits nothing). The helpers are R.Ground (trace / below / inSight): rivals.lua is at Lua's 200-locals
  limit, so they're on the module table.
- Tested in a Space_Alpha raid through bridge/dir_eval.lua, at the reporter's coordinates: below = -1626, nav =
  60356,114798,-1623, in sight = true. The old pick (60230,114665,-1203) is not in sight (rejected). Not tested: a
  real pod flight into Fortress with the new code.

## Mouse stutter in the menu, loadout and market (2026-11-17, tested; main.lua lobby tick, patchFriendsRefresh)
- bridge/profile.txt in the lobby: every 10 s window had exactly 10 frame gaps of 150 to 180 ms, one a second, while the
  frame rate between them was 120+. Raids had none. patchFriendsRefresh (the PGOS overlay's 1 s friends timer walking the
  Steam friends list, ~70 ms and up) was only applied from updateSpace, i.e. inside raids.
- Now the lobby tick applies it too, every 5 s while there is no raid (the stub is idempotent: the DLL checks the
  bytes), and logs "lobby: friends refresh stubbed" once. The overlay appears a few seconds after the menu, so the
  first seconds can still hitch.
- Tested by the reporter in the menu, loadout and market: no stutter.

## Menu hitches after a raid and on the title screen (2026-11-17; main.lua lobby tick and menu helper, mappick.lua, lobbylabel.lua)
- After a raid the menu hitched once a second again (150 ms). mappick.lua kept the widget paths of the old lobby
  (the START RAID label boxes, the map picker buttons) and looked each one up every check: a StaticFindObject of a path
  that no longer exists walks every object, ~15 ms apiece, ~10 paths. The list was not empty, so the new lobby's own
  widgets were never looked for either. Now lobbylabel.lua resets mappick's lists while a raid is on, and mappick's checks
  drop any path that has gone.
- The friends refresh stub keyed on `not raid.world`, which is only true until update() first runs in the menu; after a
  raid it never ran again. It now keys on the world: PveTickMenu is set once per world (its name has /Maps/MainMenu) and
  the stub is repeated every 5 s there, logged once per world, with a line if the function is not found.
- The title screen stuttered while the mouse moved: the voice lines (3 a frame) and other menu loads are 15 to 50 ms
  hitches. Voice.step now runs one a frame, and for the first 25 s of the menu only while the mouse is still for half a
  second (PveMenuBusy, APlayerController:GetMousePosition gives its numbers as out parameters that don't come back to Lua
  here, so it reads WidgetLayoutLibrary:GetMousePositionOnViewport, 5 microseconds). If the position can't be read nothing
  is held back, and a line says so. A raid started inside the 25 s still gets its voices.
- Log lines: "menu: mouse position read (x, y); ..." once per game start, "lobby: friends refresh stubbed" once per
  world.
- Checked: the title screen stutter was gone about 25 s in, when the startup loads finish. Not yet confirmed in game:
  the post raid hitch with the new mappick lists, and the mouse gating on the title screen.

## Player shots: no hit zones on the mod's soldiers (issue 123; pvepatch.c pve_hit_capsule, hitzones.lua, ai.lua tuneBody)
- Reported: every STG44 hit on a BotPawn_C or BotPawnMilitary_C did a flat 34, helmet or not, head or not.
- Confirmed in game (Space_Solo_01): STG44 head shot on a helmeted BotPawnMilitary_C = 34.0; Mat 49, 10 hands-on hits
  anywhere on one = 22.0 each (the gun's flat damage).
- Cause: the damage function reads the hit capsule's AreaHitType (see "Bot-on-bot damage" above). PlayerPawn_C and the
  map's own node bots (GOAPNodeBot_Raider_C) have 17 RaidHitCapsuleComponents (head/neck 1, body 2, left arm 3, right arm 4,
  left leg 5, right leg 6). The pawns the mod spawns (BotPawn_C, BotPawnGuard_C, BotPawnMilitary_C: soldiers, guards,
  rivals, crew) have none, and their body mesh blocks channels 3 (Visibility) and 15, which the player's and node bots'
  meshes ignore so a trace reaches the capsules. So the bullet stops on the mesh with no zone: raw damage.
- Player capsules (measured): query only, object type Pawn, block only channels 3 and 9-15, attached to the mesh at the
  bone of the same name with an offset. Table (socket, area, radius, half height, rel. location, rel. rotation):
  head 1 10/14 (2.9,0.5,0) (90,-355,-695); neck_01 1 7/8.8 (6.1,-0.3,0) (90,0,0); spine_03 2 13/20 (18.8,-5.9,0.4) (0,10,0);
  spine_02 2 15.7/23.7 (9,-2.2,1.1) (39,91,93); pelvis 2 13/19.1 (-2.3,-1.1,0) (0,10,0); upperarm_r 4 6.5/16 (-16.2,0.3,-0.8)
  (81,-1,-6); lowerarm_r 4 5.7/16 (-14.5,-0.4,0.2) (86,-160,-163); Hand_R 4 4.9/7.9 (-6.2,0.7,1.6) (88,-24,-25);
  upperarm_l 3 6.5/16 (16.5,-0.3,0.6) (81,-1,-6); lowerarm_l 3 5.7/16 (15.1,0,-0.4) (85,-16,-15); hand_l 3 4.9/7.9
  (5.6,-0.6,-1.7) (88,-24,-22); thigh_r 6 8.8/23.1 (23.8,-0.2,-0.7) (90,-46,-54); calf_r 6 7.9/22.4 (21.5,2.4,0.1)
  (88,-171,-170); Foot_R 6 4.9/13.5 (6.7,-7,0.7) (86,82,166); thigh_l/calf_l/foot_l 5 as the right side with x negated
  (-24.1,0.4,0.6) (-21.6,-2.6,0.7) (-6.6,6.6,-0.4). BotPawn* meshes carry every bone named here.
  Mesh responses to channels 0-17: player 220022020222222022, node bot 220022020222222020, BotPawn* 220222020222222222.
- Fix: AI.tuneBody (every director bot passes through it once) calls hitzones.ensure, which calls pvepatch.dll's
  pve_hit_capsule once per capsule, then sets the body mesh to ignore channels 3 and 15. pve_hit_capsule does what the
  engine does for a component added at run time, all through ProcessEvent (vtable +0x218) with hand-built parameter blocks:
  AddComponentByClass deferred (Class @0, bManual @8, FTransform @0x10, bDeferred @0x40, return @0x48), SetupAttachment by
  writing AttachParent (+0xc0) and AttachSocketName (+0xc8), AreaHitType (+0x460, 1 byte), SetCapsuleSize and the
  collision setters, then FinishAddComponent (Component @0, bManual @8, FTransform @0x10) with the offset from the bone,
  which registers it; OnRegister attaches it to the socket. Layouts were read from the UFunctions' property chains in
  memory (UStruct.ChildProperties +0x50, FProperty.Next +0x20, Offset_Internal +0x4c, ElementSize +0x3c): UE4SS's
  ForEachProperty fails here. Bots that already have capsules (node bots) are left alone.
- Measured with the fix (Space_Solo_01, Mat 49 on a BotPawnMilitary_C): head 80.5 (23 x 3.5), body 23, legs 11.5 (x 0.5);
  the same gun on one without zones did 22 anywhere. STG44 body hits 34 on both. Bodies of zoned soldiers loot normally.
  Not yet seen through AI.tuneBody on a director soldier at a station (the tests called hitzones.ensure from the bridge).
- Why not from Lua (tried, failed): AddComponentByClass from Lua leaves the component unregistered (UActorComponent flags at
  +0x88 read 0; a registered one with physics reads 0x07), whatever bDeferredFinish says; FinishAddComponent from Lua
  registers it, but a capsule attached before that never follows its bone (the body stays where it was registered), and
  K2_DestroyComponent / AddComponentByClass(bManualAttachment false) from Lua crashed inside UE4SS twice.
- Testing traps: bots spawned with the bridge `bot` verb aren't the director's: it hides their mesh and unpossesses them
  (floating guns); loading a renamed test copy of pvepatch.dll re-points the bot-death hook to that copy, so no body can be
  looted until a restart; ShootingRangeGameMode (bridge `raid`, F9 test raid) applies no damage to bots at all; a FindAllOf
  every frame from a bridge hook took the game to 5 fps.
- More bridge notes: test in Space_Solo_01 (F9 "Give me the STG44"). An AI-controlled bot moved with K2_SetActorLocation is put back: UnPossess it
  first. SimulateInputKey fires only while the game window has focus, and setting CurrentAmmoInClip by hand left the gun
  refusing to fire (CurrentAmmo read -30). KismetSystemLibrary:LineTraceSingle's bool works from Lua (start the trace in
  front of the camera, the ignore list didn't seem to apply); its hit result doesn't come back.
- Not looked at: Liberator pellets doing no damage (the multi-pellet path, 0x18a1990).

## Airlock crash in UE4SS: IsValid() on a freed object (issue 53, build 6; pvepatch.c pve_alive, main.lua valid)
- Report (Taki, 17 Nov, public-test-20261117.6, Space_Beta): crash 1 s after `level effects: Asteriod_Mine_Large_01`, on
  going into the mine. `EXCEPTION_ACCESS_VIOLATION reading 0x1abccabc04c` in UE4SS: `+4baaaf` <- `+3b23fc` <- Lua
  (`+87a0d4`) <- lua_pcall <- UE4SS's ProcessEvent hook (`+555046`) under `RaidGame+1c3574e`, i.e. the director's tick.
  This is the first signature in #53; build 4's fix (#114) was the other one (Slate paint, `RaidGame+2bc825b`).
- UE4SS.dll disassembled: `+3b23c0` is a UObject method that takes the wrapper's pointer (`[ud+0x70]`), calls `+4baa20`
  (reads an int at a lazily resolved member offset from the object: InternalIndex) and looks it up in the object array:
  IsValid. So `o:IsValid()` dereferences the object; once the game has freed it and the allocator has given the page back
  (a station's contents streaming out), the check itself faults, and pcall can't catch an access violation.
- Fix: `pve_alive(address)` (pvepatch.c) reads InternalIndex only after VirtualQuery says the page is committed and
  readable, then checks the GUObjectArray item holds that pointer (+0, 24-byte items, NumElements at Objects+0x14) and
  isn't PendingKill (1<<29) or Unreachable (1<<28). It returns its result by pushing an integer onto the Lua stack (the
  first export that returns a value: pushInt). main.lua's valid() calls it before IsValid(); every module's X.valid is
  that. rivals.lua's `p.ship:IsValid()` (a kept reference) now goes through valid().
- Checked in game (menu): live controller 1, spawned actor 1, destroyed 0, after `obj gc` 0; Taki's fault address, 0,
  odd and pc+8 all 0 without a crash. 0.30 us per call, same as IsValid().
- Not covered: a direct `:IsValid()` or any other method on a kept reference elsewhere (shipnav/cover/killstats ones are
  CDOs or fresh reads). Not reproduced in a raid yet.

## Your shots at bots: armour, shotguns, meshes (2026-11-18; botdamage.lua, issue #123 follow up to the hit zones)
- Every number below, and the full per piece tables (all 24 vests, all 30 helmets, damage per zone, base damage per gun, shotgun volleys, how it was measured, what is still unknown), is in docs/internals/DAMAGE_REFERENCE.md at the repo root. Update that file when a rating or a base damage changes.
- hitzones.lua gives a bot the player's capsules, so the game's damage function reads a zone. Three things were still missing on a bot, and botdamage.lua does them. main.lua requires it, passes it the raid's bots and calls `BotDamage.frame(ticker)` every frame after the aim section (profiler section "damage"). CFG.PLAYER_DAMAGE = false turns all of it off and leaves the game's flat damage.
- Armour. The function takes the victim's armour rating off each hit, flat, before the zone multiplier: ((shot damage minus armour) x projectiles) x limb multiplier. A bot has no armour items, only a helmet mesh (component "Helemt") and a vest mesh ("ChestSlot"), so every hit did the full damage. The game's own rifle damage cannot be changed from Lua, so a hit that did exactly a known gun's base damage times 4, 3.5 or 1 (tolerance 0.03) gets min(rating, base) x that multiplier handed back as health. Head is 3.5 on soldiers and raiders, 4.0 was seen on guards. A hit times 0.5 (a leg) is never refunded, see the zones below.
- Ratings were measured, not taken from guides (2026-11-18, test install). A raider dummy wearing ONE piece (dressed through the game's kit step, pve_roll_kit), 100000 health, 5 m ahead, shot with the STG44 (34 a hit) with the view locked on the part under test; only hits whose line trace met that zone counted, 5 per zone. Vest rating = 34 minus the torso damage; helmet rating = 34 minus the head damage divided by 3.5. Every set of 5 hits was identical and every rating came out a whole number. All 24 vests and 30 helmets in the item table were measured, and the table in botdamage.lua names each by the mesh it puts on (the row it comes from is the comment). A mesh that is not listed is matched by the longest listed name inside it, else counted as 0 and logged once. Vests: 13 (BAHeavyVest, Full Panzer chest and rig), 12 (Full Sherman, Heavy Pilot), 11 (Panzer, Sherman), 10 (CE Full Plate, Full Plate, Pilot Armour), 9 (CE Plate, Half Plate, Plate Rig), 8 (BA Flak, Mk3 Flak), 7 (M1 and M2 Flak), 6 (Leather Jerkin), 5 (Pouch Rig). Helmets run from 14 (Warden Riot) and 13 (Custom PSH) down to 3 (Cloth Cap). The community guide numbers this replaces were 9 for Panzer and 11 for Full Panzer (measured 11 and 13); Heavy Stahlhelm 12 and Security Helmet 7 matched. The raw test output (rows, hits, meshes) is the file armour_test.txt of the test install, not in the repo.
- Zones, measured the same way. A vest covers the torso and the arms (arm damage equalled torso damage for every vest). A helmet covers only the head. Nothing covers the legs: a leg hit did the same damage whatever was worn, so no armour is handed back for legs and pellets that hit a leg are not reduced. On these raider dummies a leg hit did 8.5 of 34 (x0.25), while the value dump lists LegDamageMulitplier 0.5 for BotPawn_C and the player pawn; ZONE in botdamage.lua still uses 0.5 for pellets and was not re-measured on soldiers. A bare head took 416.5 on every hit (34 x 3.5 x 3.5), so a head with no helmet seems to take the head multiplier twice, which makes an unarmoured headshot a one shot kill; a helmeted head takes it once (the only reading that gives whole ratings). An earlier run showed 119 (34 x 3.5) on some bare head hits; not explained.
- Base damage is per weapon class (BASE_DAMAGE), read off logged hits in testing, with a family match for variants of a gun (Thompson, Sterling, MG42, 1911, M712). A wrong or missing base means no refund, never a wrong one, because a refund needs the hit to be exactly base x a zone multiplier. A rifle or pistol with no base logs one line with its first hit. Shotguns, launchers, flares and melee are not refunded by this path. The F9 "Dump game values" run (192 rows, 2026-11-18) holds no damage, recoil, spread or pellet property for any gun, only fire rate, stamina, durability, ADS and ammo, so it cannot replace this table. Heavy MG42 and Heavy Thompson still use their base gun's number.
- Only a hit within 0.5 s of your gun's clip dropping is refunded, so damage from a crewmate or another bot is not. In the test logs 1278 of 1609 hits landed within 0.2 s of the shot.
- Not covered: a hit that killed the bot is not refunded (the death has run). Pistols and some SMGs lose damage with range, so a far hit is below base and gets no refund (SPP1: 32 at 127 to 616 cm, 22 at 1635 cm). The real fix is to read the hit zone from the damage function.
- Shotguns. Offline a shotgun's own pellets never reach the damage function (Liberator: 8 shots, 0 hits). Each shot (the clip dropping, up to 2 volleys a frame) fires 10 pellets of 18 from botdamage.lua: a line trace from 150 cm in front of the camera inside a cone, each hit dealt with GameplayStatics.ApplyDamage using the base DamageType class, with the armour taken off and the zone multiplier applied in the script (ApplyDamage carries no zone). The vest rating applies to the body and arms and the helmet to the head, as measured; legs get none. ApplyDamage was the one way of three that lowered health; point damage with and without a component both errored. A pellet that hits a mesh and not a capsule does 18 flat.
- Shotgun check, 2026-11-18: a Liberator fired at raider dummies 5 m away. The game's own part did 0.0 to them, so the pellets here are the only damage. On a bare torso a volley took 126 to 180 (7 to 10 pellets of 18), and in a Pouch Rig (rating 5) 91 to 130 (7 to 10 pellets of 13), so armour comes off each pellet as designed. The test's own per shot sums were mixed up with its health resets and are not used. The real pellet count and damage cannot be read this way; 10 x 18 is still the Guilds 1.0 notes.
- The cone half angles are guesses: Trench gun 2.0, Liberator 3.0, Sawed off 4.5, Jackhammer 3.0, Long double 1.5, Terminator 3.0, anything else 3.0 degrees. The weapon's own spread properties were looked for and not found. Not checked: if the game's own pellets ever do land now that bots have capsules, a shot would count twice.
- The throw. A volley throws the bots it hits: 900 cm/s base (x1.25 sawed off, x1.15 Terminator), scaled by the share of pellets that hit and falling to nothing at 1000 cm, over 14 steps 0.12 s apart. A ragdolled or dead bot gets the velocity on all bodies below the pelvis, a live one a nudge (30% sideways, 120 up, once). The numbers are a stand in: the exe has FireImpulse, DamageImpulse and bHasKnockback strings, but the properties read back empty.
- Meshes. A bot's helmet, vest and backpack are skeletal meshes of their own, and they block the weapon traces like the body does. hitzones.lua frees only the body mesh, on channels 3 and 15, so a bullet that met a helmet first, or a trace on another channel (projectile guns use 9 to 14), stopped on a mesh and did the flat damage: a guard in a Security helmet took 34 and 136 from the same shot. Once a bot has its capsules, every skeletal and static mesh on it ignores the channels the capsules block (3 and 9 to 15). Three bots a second at most; a bot that has no capsules after 5 looks is left alone.
- Raw findings, kept because they are odd. Bare head, STG44: 416.5 a hit, which is 34 x 3.5 x 3.5, so the head multiplier is applied twice when no helmet is worn (an earlier run mixed in 119, which is 34 x 3.5, never explained). A helmeted head applies it once, the only reading that gives whole number ratings. It may be deliberate (so an unarmoured headshot always kills) or a bug on our side. Bare leg: 8.5 of 34 on the raider dummies (x0.25), and every one of the 54 pieces left it at 8.5. Bare arm and bare torso: 34. Vest rating = 34 minus the torso damage (arm damage was identical); helmet rating = 34 minus the head damage divided by 3.5; arm and leg damage under a helmet matched the bare values.
- Rating tiers. Vests: 13 BAHeavyVest, FullPanzerChest, FullPanzerRig; 12 the Full Sherman pair and HeavyPilotArmourChest; 11 Panzer and Sherman chests and rigs; 10 CEFullPlate, FullPlateChest, PilotArmourChest; 9 CEPlate, HalfPlateChest, PlateRig; 8 BAFlakVest and the Mk3 flak pair; 7 M1 flak chest and rig, M2 flak chest; 6 LeatherJerkinChest; 5 PouchRig. Helmets run from 3 (Cloth Cap) to 14 (Warden Riot Helmet); the full list by mesh is in the VESTS and HELMETS tables of botdamage.lua and in docs/internals/DAMAGE_REFERENCE.md.
- How a bot's rating is found. The helmet is the skeletal mesh component named "Helemt" and the vest the one named "ChestSlot" (the game's own spelling). The mesh asset name is looked up in the exact tables, then by the longest listed name contained in it, else the piece is rated 0 and one line is logged. Some meshes carry a doubled name (Full_Plate_Skel_01_Full_Plate_Skel_01); the tables hold them as the game reports them. The result is cached per bot (e.armour).
- Health and head multipliers from the value dump: you 100 HP with head 3.25; BotPawn_C 80 HP, head 3.5; BotPawnMilitary_C 200 HP, head 3.5; guards 200 HP and head 4.0 (from logs, not the dump). Rival and crew bodies get 100 HP (crew plus 10 a level) from rivals.lua. The refund accepts 4, 3.5 and 1 as the multiplier because of the guards.
- What the value dump holds. The F9 dump of 192 rows is complete: fire rate, stamina, durability, ADS and ammo values per item, and attachment adjustments (all zero except two). It holds NO damage, recoil, spread or pellet property for any gun, which is why base damage comes from logged hits and the patch notes. The Terminator shotgun failed to spawn for the dump.
- The test method, so it can be repeated. An F9 test spawned a hidden GOAPNodeBot_Raider_C and dressed it with one item through pve_roll_kit(bot, itemTable, gun, pistol, helmet, armour, bag); 100000 health put back after every hit; hit capsules from hitzones.ensure; its AI and ticks off; the next dummy built 3 m to the side while the current one was shot, then swapped in. The view was locked onto the part under test (FindLookAtRotation and SetControlRotation, run before and after the game's frame, which removes recoil), only hits whose line trace met the wanted zone counted, 5 per zone, median kept. Every other AI was killed at the start and every 5 s. Bottomless mags were on and the STG44 was in slot 1, the Liberator in slot 2. A no shooting pass first read every piece's helmet and vest mesh off the dressed dummy. Each set of 5 hits came out identical. The test code lived only in a test install and is not in the repo.
- Still unknown: why a bare head takes the multiplier twice; the soldier's leg multiplier (0.5 in the dump, 0.25 on the raider dummies); the guard head multiplier from the dump; each shotgun's real pellet count, damage and spread (10 x 18 is from the Guilds 1.0 notes for all of them); range falloff for guns other than the SPP1; base damage of the Heavy MG42 and Heavy Thompson (they use their base gun's family number); explosions, fire and melee against armour. This code has not run in game on build 8 yet.
- Tested: the ratings, the zone coverage and the shotgun armour above were measured in game on a test install of an earlier build with the same logic as this file. This file is that logic without the test code, rebuilt on build 8's modules, and has passed scripts/luacheck.py and a stubbed load only. Not yet run in game on build 8: the first things to look at are a rifle hit on a helmeted soldier (the refund), shotguns counting twice, looting a body, and a helmet shot doing zone damage.
- Left out on purpose (a second pass): launchers and grenades (the 40mm shell explodes at the muzzle offline), mines, melee, shields, the blow torch, the fire extinguisher, and damage to the player from bots.

## Crew gunner reach, swing and click (issue 88; rivals.lua GUNNER_*, crew.lua ORDER_CONE)
- Reports: a level 3 and a level 4 gunner "only kept shooting ahead and not turning the turret", clicking a target didn't
  make them attack it, nothing to answer a stationary turret with. Hayley: mainly radius/range.
- What limited them: each turret type's crew range (60-95 m), GUNNER_ARC 120 deg, and the barrels' pitch (-15..10 deg)
  with TURRET_PITCH_SLACK 6: a target a little above or below was held ("pitch"), one past the arc or range was "arc" /
  "range", and an ordered ship out of range just got "too far, close in".
- Shells don't run out of range: every ship turret's shell (ProjSmallShell, Proj25mm, Proj75mmShell, ProjSmallMissile,
  ProjTorpedo) has InitialLifeSpan 0 (probed from the CDOs). The turrets' own limits: yaw +-60, pitch 0..15.
- Now for your gunner only (gunnerFire passes them to fireTurrets; rival crews unchanged): GUNNER_RANGE 1.75 x the type's
  range, GUNNER_ARC 170, GUNNER_PITCH_SLACK 30 (past the barrel's tilt the shell keeps the true pitch instead of the
  barrel's). A click picks the ship nearest your view within ORDER_CONE 25 deg (was 15). Both new settings are on the
  F3 "Ship guns" tab.
- In a fight (Pavel, level 2, gunnery 0.46, Starter Frigate): "engaging the Lucky Strike" a second after it attacked,
  held only for range at first (57% of checks while it closed), then firing (reload 99% of held checks), and it was a
  wreck 38 s later. A click on a stationary turret 103 m off (well below the ship) got "ordered onto turret", but your
  hull was disabled a second later, so nothing fired (right: the gunner stands down with the hull).
- Then: GUNNER_PITCH_SLACK 30 -> 45 (a turret below you as you pass over is 40-60 deg down), and the gunner now says when
  height is what stops them ("can't get the guns on the ..., too far above or below us"); before, a pitch hold was silent.
- Not done: a second gunner (only one crewmate is the gunner; they already work every turret on the hull).

## F9 gun list: the rest of the guns (2026-11-17; debuggive.lua)
- The F9 picker only had the base guns, so the variants could not be given for testing. Added 13 rows: Terminator, Heavy Liberator, Heavy MG42, Heavy Thompson, Thompson Special, APS, Custom Mat 49, M712 Special, Sterling Special, Sterling (short), Viper Mk1, Mini Thumper, M1911 G.
- Kind (0 long gun, 1 pistol) and magazine size for each are checked against assets/saves/items.json (type and max), the same source as the rest of the list. Sterling (short), Mini Thumper and M1911 G are type 1, so they go in the pistol slot.
- Only the GUNS table changed. No row was removed or edited, and the give path is untouched. These rows were used from the F9 menu in game while testing guns against armoured bots.

## F9 bottomless mags (2026-11-18; debuggive.lua, debugactions.lua, main.lua)
- A toggle in the F9 menu, first of the gun rows: "Bottomless mags: ON / off". While it is on, every round a shot takes off the clip is put back, so no gun runs dry and nothing needs a reload. It is usable in a raid, on foot, like the gun picker; turning it on or off starts the count again from what the gun holds. It resets with the game (nothing is saved).
- Done in Lua with no game flags. bInfiniteClip and bInfiniteAmmo change how the clip reads, so code that watches the clip for shots (the damage code on the player to bot damage branch) never saw one, and finding the flags searched the world twice a second.
- How it works: for the player the loaded rounds are the StackAmount of the gun's own SIGIS item (found by UniqueItemGUID equal to gun.UUIDSIGIS, searched once per gun and again at most once a second while it is missing). The weapon's CurrentAmmoInClip only follows that stack, so putting the clip back alone changed nothing. Each frame, a clip or a stack lower than last frame's is set back to last frame's. One property read a frame, nothing searched.
- Order matters: main.lua calls it (`DebugActions.frame`, profiler section "mags") after the aim, cover and ragdoll sections, so anything that reads the clip for shots earlier in the frame has seen it drop before it is put back. A later change that reads the clip must run before this call.
- Logic lives in debuggive.lua (`G.frame` and the action); debugactions.lua exposes it as `M.frame`, which keeps main.lua's local count flat. Used while measuring armour (the armour test needs neither gun to run dry); the measurement itself is not part of this change.
## Bots animate at the display's rate (2026-11-17; main.lua trackTargets and animate)
- Before: animate() ran CFG.ANIM_HZ (30) times a second for a fighting or busy bot, ANIM_PEACE_HZ (15) for one at peace,
  and ANIM_SLOW_HZ (10) past ANIM_SLOW_FAR (4000) from the camera. On a 120 or 144 Hz display that is a fraction of the
  frame rate, so gait, posture and the leg rate stepped. (This replaces the rates in the 2026-11-14 performance notes above.)
- Now every bot, near or far, runs animate() CFG.ANIM_HZ_LOW (60) times a second, or CFG.ANIM_HZ_HIGH (120) while the
  game's smoothed frame rate is over CFG.ANIM_HI_FPS (120) plus 5; it drops back to 60 under 115, so it doesn't flip
  between the two. 120 is the ceiling. The frame rate is measured in trackTargets (the gap between its calls, smoothed).
- CFG.ANIM_BUDGET (14) caps the animate() calls in one frame. Bots over it wait for the next frame, and the next frame
  starts where this one stopped (raid.animFrom), so no bot starves and a crowd can't stall one frame. A bot's next time is
  on a grid of 1/hz (due + step, not now + step), so a rate close to the frame rate isn't halved by rounding up to a
  whole frame.
- animate(e, now): crouch is read once; the leg rate smoothing is by time (k = 1 minus 0.5 to the power of dt x 30, dt
  capped at 0.2 s), so it settles in about 0.1 s at any rate (it was a fixed half step per call, tuned for 30 Hz); the
  top speed is worked out in a local and written once at the end (it was up to four writes and two reads). The aim
  upkeep of a fighting bot runs at the same rate; one at peace keeps ANIM_PEACE_HZ.
- Removed from CFG: ANIM_SLOW_FAR, ANIM_SLOW_HZ, ANIM_HZ. The engine's own cheaper animation past ANIM_FAR (6000) is
  unchanged.
- Cost to watch: a call is about a dozen engine reads and writes. With every bot animating every frame the 2026-11-14
  profile showed about 1.2 ms a frame and 3 MB of garbage a second for 20 bots; the budget bounds it. The cost at 60
  and at 120 Hz in a full raid was not measured separately: bridge/profile_on puts the aim section in profile.txt.

## Crash on leaving a raid: the lobby world leaked through a rooted portrait (issue 133, builds 6-7; crewlobby.lua photoStep)
- Reports (17 Nov, builds .6 and .7): pod extraction (Space_Delta), death (Space_Solo_01), Esc → quit to main menu
  (Space_Beta). All three have the same `PCallStackHash` 7952771C…, null read at 0x268 on the game thread.
- Static disassembly of the exe: `+30bca7b` is in UGameInstance::CreateGameModeForURL (references "GAME=",
  "LoadForAllGameModes"), reading `[WorldSettings + 0x268]` (DefaultGameMode) right after `World->GetWorldSettings(false,
  true)` (`+3502970`) returned null. The callers are UWorld::SetGameMode (`+350f8e0`, calling the game instance's virtual
  at +0x338) and UEngine::LoadMap. The UE4SS frame (`+554abd`) is UE4SS's LoadMap hook passing the call through: no Lua
  on the stack.
- Why WorldSettings was null: the main menu world loaded was the old one. d9a3ec1 rooted the crew portraits' render
  targets, made with `CreateRenderTarget2D(B.stand, …)`. That function makes its world context object the new object's
  outer, and a rooted object keeps its outer alive, so the photo stand, its level and the whole lobby world outlived the
  raid. Tearing a world down marks its actors for kill and the GC nulls UPROPERTY references to them (ULevel's
  WorldSettings among them). LoadMap then found the leaked package, and the shipping build has no stale-world check.
- Fix: the portraits are made inside the game instance (it lives for the session). Rule for anything passed to
  pve_root: its outer chain must not reach a world (assets, transient textures from ImportFileAsTexture2D and objects
  made inside the game instance are fine).
- Not checked in game yet.

## Salvage in the hold stayed behind a shut door (issue 134; main.lua relaySalvage)
- Report (Taki, build .6, confirmed live 17 Nov on master, Space_Solo_01, starter frigate): after R the hold's airlock
  stays shut, the lever panel reads "LOCKED / NO SALVAGE DETECTED", yet the lever offers "F" PURGE SALVAGE.
- Read live: the wreck's inside salvage (Industrial_InsideSalvage_01_C) spawns right at the interior's SalvageSpawn
  (child of SalvageComp tagged "Salvage", which 0x17d9dd0 looks up), not hidden; the interior's SalvageFull (+0x3c8),
  HadSpaceSalvageAlready and the frigate's SalvageFull (+0xc38) are all true, CurrentSalvageActor (+0x3d0) set.
- What's missing is FrigateInside_Starter_C's Blueprint OnSpaceSalvageChange (door open, panel), which only the native
  OnRep_HasSpaceSavage calls. Replication callbacks don't run on the authority, and offline the game is it.
  Calling `inside:OnRep_HasSpaceSavage()` by hand opened the door and the salvage could be looted.
- Fix: main.lua relaySalvage watches your interior's SalvageFull in updateSpace and calls OnRep_HasSpaceSavage on each
  change (pickup and purge). Same pattern likely behind #74 (salvage gone on docking): check the other OnRep_* there.
- Careful in bridge probes: calling methods on a possibly-null object wrapper inside pcall crashed the game in UE4SS
  (null read 0x18); check `o ~= nil and o:IsValid()` first.

## Purging salvage while docked is refused (space.lua guardPurgeWhileDocked)
- The original game never let you purge the hold's salvage while docked (the space door would open into the station).
  Offline nothing stopped it. Tester report: purge worked while docked.
- Read live: F on the purge object is SIGISCharacter::ServerInteractComp with the hold's component named "SalvageComp"
  (RaidUseableDockedSalvageComponent, the prompt) or "SalvageControlLever" (same class, the lever mesh). StartInteraction,
  ProcessInteraction and ServerInteract did not carry that press. A RegisterHook pre callback that calls `comp:set(nil)`
  cancels the interaction, so the press does nothing and the prompt stays on screen as in the original.
- Fix: hook ServerInteractComp once in Space.init. While the player's hold (raid.home) has is_Currently_Docked true and the
  component belongs to that hold and is one of the two names above, the press is cancelled. Undocked, purging is untouched.
- Feedback: the same thing a full inventory gives. The HUD overlay's HUD_Main_Widget_C (instance "In Game Overlay Match") has
  Txt_NotEnoughSpace; set its text, call hud:NoSpaceForItem() (plays Anim_NotEnoughSpace and the error sound), put the
  original text back after 4.5 s. Rate limited to one per second. Reached natively as SIGISInventoryComponent
  Client_NoSpaceInInventory -> SIGISHUD BP_NoSpaceForItem -> MatchHUD_C / HUD_Main_Widget_C NoSpaceForItem.
- Tried and dropped: switching the lever's collision off (the F prompt vanished; tester wanted it kept) and
  PlayerController:ClientMessage (text did not show). HUD_Message_SubWidget_C works but sits small in the top right
  with no sound.
- Also learned while testing salvage: a destroyed actor still passes IsValid and shows in FindAllOf until garbage
  collection (about every 60 s) and reads location 0 0 0, so check the location when watching wrecks.
  K2_TeleportTo returns false without an error when the destination overlaps geometry; use
  K2_SetActorLocationAndRotation(loc, rot, false, {}, true) and verify the new position.
  Salvage survived docking for menu spawned and level wrecks (issue 74 not reproduced there).
- Tested in game: docked press shows the warning and sound and does nothing, undocked purge works.

The whole chain (pickup, purge, docking, the Blueprint findings, the HUD refusal route and how it was dumped) has its own
reference with flowcharts: [docs/internals/SALVAGE_CHAIN.md](docs/internals/SALVAGE_CHAIN.md).

## Linux / Steam Deck via Proton (issue 127; scripts/pvemode.py, linux/)
- Design (the issue's option B): Marauders' Steam launch option `"<project>/linux/marauders-offline.sh" %command%`
  runs `pvemode.py steam-run`, which does what the launcher's PLAY does: settle/activate the save (config/linux_save.txt
  or the last played), start the stand-in, switch the folder offline (same files as mode.ps1), then run Steam's command
  with RaidGame.exe (EAC bootstrapper) swapped for RaidGame-Win64-Shipping.exe plus -nosplash, and
  `WINEDLLOVERRIDES=dwmapi=n,b` so Wine loads UE4SS's proxy instead of its own dwmapi. On exit: stand-in stopped,
  folder back to stock, save settled. Steam supplies Proton, its prefix and steam_api.
- Unclean exits: offline() writes backup/offline_applied; every pvemode command (and steam-run first thing) puts the
  folder back when it's there and no game is running. SIGTERM/SIGINT/SIGHUP (Steam's stop) tidy up in a finally.
- Safety: `pvemode.py steam off` (config/linux_offline.txt) makes the same launch option exec Steam's command unchanged.
- pveproject.lua gets the Wine form of the project path (`Z:/home/...`): the Lua runs inside the game. pvenet.dll finds
  the project from its own module path, which Wine reports in the same form.
- Tested: scripts/test_pvemode.py on Windows and on Linux (WSL Ubuntu, Python 3.12), with a fake game folder and a fake
  Proton: play and tidy up, SIGTERM mid-game, switched off, unclean-exit recovery, libraryfolders.vdf with an SD-card
  library with a space in its path; linux/install.sh and the wrapper on a copy of the project.
- **Not tested: anything under real Proton.** Open questions in #127: does UE4SS 3.0.1 load with dwmapi=n,b, does
  pvenet's WinHTTP redirect work under Wine, does the Shipping exe start without EAC under Proton, where the prefix keeps
  Saved/ (crash reports, GameUserSettings.ini). Not done: a Linux GUI launcher (the Tk one is Windows-only), report.py
  in the prefix, a Steam Input layout.

## main.lua and its modules (refactor, 2026-11-17)
- Why: main.lua had 200 active locals in its chunk, Lua 5.4's limit, so new helpers went in as globals (addInteriorNav,
  relaySalvage for #134, godMode, PveResetRaid, PVE_patchFriends, PveMenuBusy...) or into the `Aux` table. Measured by
  appending locals until load() refuses: 200 before, 101 after.
- Moved verbatim (comments with their code) into modules with the usual shape (`local M = {}`, `M.init(ctx)`, `return M`):
  - `bots.lua`: sections 2-6 (KINDS, wake/arm/spawnBot, factions and foes, reapDead, parking, patrols, noises, cover,
    combatHints, updateBots, animate, trackTargets) and station garrisons (spawnGarrison, spawnQueued). The old
    `Aux.parked/openLog/botShot/advancePoint/isMelee/meleeHints/pathLen/longWay` are `M.*` there.
  - `playareas.lua`: where bots may go (sealed, offLimits) and the old `Aux.inBox/findAll/scan/mapPlayAreas/rescan`.
  - `loadout.lua`: ensureHud, applyLoadout, the donor-soldier gun, floor loot, extractNow, the extraction hooks and the
    back-to-menu step (`returnAfterExtract`, called where that block sat in update).
  - `launch.lua`: matchmaking (onStartMatchmaking, the captain button, launchMatch, its mm/launching/launchShip state)
    and the space-map loading veil (veilUntilAboard). onTick asks `Launch.busy()` and `Launch.fire()`.
  - `space.lua`: pod guns, docking hooks, level effects, key card, sun, the interior navmesh (addInteriorNav,
    startSpaceNav), relaySalvage and updateSpace (`Space.update`).
  - `debugactions.lua`: god mode and the F9 buttons (Debug.init).
- The per-raid table: resetRaid replaces `raid`, so every module keeps its own reference and main's `shareRaid()` hands
  the new table to each (`M.setRaid`) right after the reset. A new module that reads `raid` needs adding to that list.
  (The older modules still take a `raid = function() return raid end` getter; both work.)
- Kept in main.lua: CFG, valid/log/dist helpers, the patch DLL entry points, ragdoll settling, gc and the profiler,
  onTick, the land navmesh (startNav, navMesh, navReadyAt), footstep/friends patches, resetRaid, update (lobby stash
  rows, input on arrival, flag files), the gunfire/whizz/death hooks and the keys. `Aux` now only holds `due` (shared
  with the modules as `ctx.aux`) and `unlessTyping`.
- Globals made locals again: Out, GearScale, the menu helpers (Quit, InvKeys, LobbyLabel, InvQol), onTick's state
  (`tick.world/menu/menuSince/...`), resetRaid, patchFriendsRefresh, the mouse check, godMode, addInteriorNav,
  relaySalvage. Still globals on purpose: PveMapPick and PveGuild (lobbylabel.lua reads them), Hire, Crew, CrewLobby,
  Missions (other modules read them), PVE_PROF/PVE_ALLOC/PVE_GC (profiler, bridge/dir_eval.lua).
- Verified: luacheck on every file; a scan for names each module reads but doesn't declare (only the globals above);
  every line of the old main.lua is in the new files apart from the renamed call sites; main.lua and every module load
  under lupa with UE4SS stubbed, registering the same 27 hooks, key binds and loops and logging the same lines as before
  (only the order of hook registration differs).
- In game (2026-11-17, throwaway cheat save, the branch's Lua copied over the game's): login and lobby; lobby launch
  button -> matchmaking -> Space_Alpha, veil, loadout, floor loot, key card, play areas, space navmesh, aboard after 19 s;
  a rival boarded (bridge/rivals_board), took cover, peeked, switched to the crewmate, was killed; F9 extract -> main
  menu. Spaceport_01 land raid: navmesh, 8 soldiers, donor gun and ammo, god mode on/off, F9 spawn soldier, a fight with
  cover and a bot reload, F9 extract with 3 items. No Lua errors in UE4SS.log. Note: bridge/debug_cmd is only read in
  a raid (update returns early in the lobby), so its "testraid" does nothing from the menu, as before.

## Lua and launcher practices made into checks (2026-11-17)
- `scripts/luacheck.py` measures each file's headroom under Lua's 200-locals limit (as many extra top-level locals as
  still compile, put in front of the file) and fails CI under 20. It found **rivals.lua at exactly 200 (0 to spare)**:
  allowed as a named exception until #149 splits it. main.lua: 99 to spare after #146.
- main.lua `pveRoot(object)` replaces the raw `pve_root(address)`: it walks the object's outers and refuses (logged:
  `root: refused ... (a world owns it: Level ...)`) anything a World or Level owns, the #133 leak. Callers (crewlobby,
  female, loading, rivals, voice) pass the object. Checked with lupa stubs: a stand-owned render target refused, a game
  instance one and an asset rooted, nothing rooted without pvepatch.dll.
- Audit of raw `:IsValid()` calls: nearly all are on fresh lookups (StaticFindObject/FindFirstOf, class objects, CDOs,
  hook contexts). The exceptions were a game-held pointer, `turret.ControllerHere` (crew.lua twice, gunseat.lua), which
  can point at a freed controller: now `valid()`.
- Launcher (#147, PR #148): background threads go through `App.ui(fn)` and a 50 ms pump; grid layout with wrap widths in
  points; font fallback; dialogs are owned windows that grab only once visible; keyboard focus and Enter/Space on
  buttons; Tk option-database theme; `launcher/test_ui.py` (12 headless tests). Tk's font cache is per process on
  Windows: a scaling test must run in its own process or it leaks into the others.

## rivals.lua and its modules (issue 149, 2026-11-17)
- rivals.lua had all 200 of Lua's top-level locals (found by luacheck's headroom check). Its sections moved verbatim:
  `rivalcrews.lua` (Crews), `rivalships.lua` (Berths, Docking route, Ships), `rivalbodies.lua` (Bodies, Spreading
  out, Station defenders), `rivalcombat.lua` (Breaching pods, Ship combat, You boarding a rival's ship). rivals.lua
  keeps the header (CFG, helpers), World survey, Crew brain and Public: 60 locals now, 140 to spare.
- Sharing: rivals.lua builds a table H of the header's names and puts it at `package.loaded["rivalshared"]`; each
  module reads what it uses from it into its own locals at load, so moved code is unchanged. Modules load in
  dependency order (crews, ships, bodies, combat) and the functions a later module uses are added to H as each loads.
  `X` (main's context) and `S` (per-raid state) change at runtime, so they reach the modules through `M.bind(X, S)`,
  called by `shareState()` after `R.init` sets X, after a new raid's S, and in `R.reset`. Ships' `AIMED` table is reset
  per raid through `Ships.resetAimed()`.
- In rivals.lua, uses of moved names go through the module (`Ships.flyTo`, `Combat.engage`...): 152 call sites, found by
  scope analysis so locals of the same name were left alone. Note the Breaching pods section has its own
  `weighted(w)` (a map of weights), which shadows the header's `weighted(list)`; it stays inside rivalcombat.lua.
- Checked: luacheck (all 5 files 120+ spare); a scope-aware free-name scan (no name became a global; `package` is new
  and intended); every line of the old file is in the new ones, apart from the rewritten call sites and R.reset's
  shareState(); under lupa with UE4SS stubbed, old and new export the same 254 `R` keys, register the same 4 hooks,
  and run R.init / R.reset cleanly.

## Linux launcher window and Deck controls (issue 127, 2026-11-18; launcher.pyw IS_WIN, pvemode.desktop_entry)
- The launcher runs on Linux. There it doesn't switch the folder or run the stand-in: Steam's launch option
  (pvemode.py steam-run) does. Its PLAY writes config/linux_save.txt, switches config/linux_offline.txt back on, and
  opens steam://rungameid/1789480 (app id from steamapps/appmanifest_1789480.acf). watch() then sees the game through
  pvemode.game_running (/proc cmdlines), and finish() waits for backup/offline_applied to go (steam-run's tidy-up),
  calling pvemode.recover() after 60 s if it's still there.
- linux_launch_option() reads every Steam user's userdata/*/config/localconfig.vdf: if Marauders' block (until its
  first "}") has no marauders-offline.sh, PLAY says to paste the launch option instead of starting the stock game. No
  config found = can't tell, PLAY goes ahead.
- Startup on Linux never settles a save (steam-run may be starting a game right then). It only recovers when the dirty
  marker is older than START_TIMEOUT (90 s) and no game runs.
- Also Linux-only: a flock in /tmp for the single instance, xdg-open for folders and steam:// links, the .ico through
  PIL + iconphoto, and no "Borderless fullscreen" box (launch-offline.ps1 applies it; on Linux the game's own video
  settings do).
- install.sh (pvemode install) adds ~/.local/share/applications/marauders-offline.desktop when Tk and Pillow import,
  else says which packages are missing.
- Deck controls: README table (back grips F6 / F3 / N / M, D-pad down B, View + D-pad K / J, right trackpad as
  mouse), set up by hand in Steam's layout editor. No .vdf layout file shipped: can't make or check one without a Deck.
- Tested: test_pvemode.py in WSL Ubuntu (15 tests, 2 new: desktop entry, launch-option check). The real launcher
  window in WSLg: opens, says why PLAY can't start with the Windows game path. Full PLAY cycle against a fake game and
  fake Steam (the dirty marker and a process named like the game for 6 s): "Steam is starting the game" -> "Saving..."
  -> "Saved", save written, launch option switch back on. Windows: launcher/test_ui.py 12/12.
  NOT tested: a real Steam / Proton / Deck, the window on a real desktop (WSLg wouldn't give a screenshot), Game Mode.
## Blueprint authority branches: bpbranch.py (issue 143, 2026-11-18; tools/offline-audit/bpbranch.py, kdis.py)
- kdis.py is importable now: `decode(code(func))` -> [(offset, text)]; the CLI is unchanged.
- bpbranch.py <out.json>: for each loaded Blueprint function, every `if not HasAuthority/IsServer/IsStandalone jump T`
  (and the Not_PreBool form) -> the side that never runs offline, walked through jumps, branches and push/pop, minus
  whatever the authority side also reaches; the calls there, flagged when they look visible. ~14 s for 988 classes.
  Results and triage: OFFLINE_AUDIT.md "Blueprint branches that never run offline". It found the pod breach timer (#77)
  by itself, and the same shape on every frigate pawn (ShipHealthCheck, 1 s: DamageEffects_ShipHull/Engine/Turret).
- ShipHealthCheck test (Space_Solo_01, your Starter hull cut to 25 %, timer started from the bridge, looked at from a
  pod 18 m off): no difference seen; the hull already trailed smoke before. Not shipped, and not needed: rivals.lua
  hullDamageFx (2026-11-14, "Rival hulls" above) already lights those emitters and calls DamageEffects_* itself.
- Gotcha: IsDedicatedServer is false offline (standalone), unlike IsServer; the first version of the scan had it the
  wrong way round.
## Offline backend: coverage tally, tournaments, the gift box (issue 80, 2026-11-18; backend/nakama_standin.py)
- Writes were already crash-safe (state.json, loadout.json, cosmetics.json go through a .tmp + os.replace). Write
  coalescing NOT done: state.json is ~18 KB, and the launcher stops the stand-in by killing it, so a delayed write
  could lose a purchase. Not worth that risk for now.
- Coverage: the stand-in counts what nothing answers, by kind: "unknown rpcs", "unhandled endpoints" (ids replaced by
  <id>), "empty collections" (listed while empty: twitch on every login). backend/coverage.json, count + first/last
  time, added to across sessions, written by the 1 s watcher thread only when something new was counted. REPORT zips
  it. Seen so far: `guild_getinfo` (the guild page's Nakama half; guild.lua fills that widget itself, so answering it
  isn't needed), twitch empty, and GET /v2/tournament, which is now answered as "no tournaments" (the live list was
  empty in the capture too).
- Gifts work offline already: the lobby's GIFT tab (MainOverlay Btn_TEMP_MainBtn_Gift) lists the gifts collection
  sent in masterstartfunction. Claiming is the client's own delete gifts + put inventory (captured online), which the
  generic storage path handles. A gift is only an item row ({"value": "Mat49Rifle"}); the game picks the stack when it
  shows it: a gun with a full magazine, 9mmAmmo 30/60, BandageAid 1/3. Some showed the Twitch badge (which ones
  depends on the client, not the stand-in).
- backend/gifts_in.txt: item rows, one per line; the stand-in moves them into the gift box within a second (new
  5-digit keys, never one already in gifts or the stash). For the mod or the launcher to hand out rewards (#78's loot
  for harder raids). The client reads gifts at login, so they show from the next login.
- Tested in game (2026-11-18, throwaway save gifts-test, MainMenu): 2 x (Mat49Rifle, BandageAid, 9mmAmmo) queued
  through gifts_in.txt, all six shown in GIFTS. NOT tested: claiming a gift into the stash by dragging (no input
  from the bridge), whether ED_CheckForGiftsNow can make the lobby re-read gifts without a new login.
  tools/test_standin_gaps.py covers the tally, the tournament answer and the gift hand-off.
- Windows dev note: `pvemode.py steam-run` started the Shipping exe without its working directory, and Steam
  relaunched the stock game (folder already back to stock). It's meant for Linux, where Steam supplies the
  environment; on Windows use the launcher or launch-offline.ps1.
## Pod breach prompt (issue 77, 2026-11-18; rivalcombat.lua playerBoarding)
- Cause: Ship_DropPod_Pawn_C's BeginPlay (ubergraph 10670: `if not HasAuthority() jump 7935`) starts its looping
  0.1 s timer `K2_SetTimer(self, 'Timed_BreachCheck', 0.1, true)` (at 8781) only on the non-authority branch.
  Timed_BreachCheck = BreachCheck() -> SetAbleToBreach(it) -> MatchHUD.HUD_Widget.SetUIAbleToPodBreach(bool), which shows
  HUD_Main_Widget's Border_isAbleToBreach ("... BREACH BOOST READY ..."). Offline we're the authority, so the border
  stayed Collapsed while BreachCheck was true. F (and ramming) still breached, since they call BreachCheck themselves.
  Same pattern as the salvage scan timer (#134 / pvepatch) and issue #143.
- Fix: playerBoarding (every frame while you're in a pod) starts the same timer once per pod through
  KismetSystemLibrary:K2_SetTimer(pod, "Timed_BreachCheck", 0.1, true, 0, 0); the game runs it from there.
- Tested in game (2026-11-18, Space_Solo_01, gifts-test save, pod from RaidUseableComp_DropPod01 via
  pawn:ServerInteractComp): pod parked 1200 off your own hull, nose on it: BreachCheck true, border 1 -> 4 within a
  tick, "BREACH BOOST READY" on screen (screenshot); moved to open space: false, border back to 1. No errors. NOT
  tested: a real flight onto a rival hull with a real F press, the escape pod after your ship dies.
- Bridge: pawn:ServerInteractComp(comp) (with pawn.LastInteractionComp = comp) uses a seat, pod bay etc. like F does.

## Raid length from the launcher (issue 159, 2026-11-18; raidtime.lua, launcher "Raid length")
- The raid's countdown: RaidGameState.RemainingTime (seconds) and bTimerPaused; RaidGameMode (gs.AuthorityGameMode,
  also for the SpaceGameMode_C subclass) RoundTime 1500 (25 min), WarmupTime 15, GameOverideTime 0,
  TimeTillEvacSpawn 300 (space gate). GameState.ElapsedTime doesn't match the round (128 vs 175 s gone), don't use it.
- During the warmup RemainingTime holds the warmup's 15 s countdown, and the round then restarts it from RoundTime.
  Writing RemainingTime or pausing in the warmup is wrong: a length came out wrong, and a pause would hold the warmup.
- raidtime.lua: config/raid_length.txt = minutes (5-240) | "default" | "none". Sets gm.RoundTime at once; once
  RemainingTime > WarmupTime + 1 the round is running: "none" sets bTimerPaused; a raid first seen already running
  gets the time gone carried onto the new length. Once per raid (raid.lengthSet).
- Launcher: a "Raid length" slider (25 min default, 15, 30, 45, 60, 90, 120, no limit). Both sliders are one row now
  (label, slider, value): with the new one the settings column clipped at 150 % scaling.
- Tested in game (Space_Solo_01, relaunched each time): 60 -> "raid length: 60 min", 3541 s left a minute in, RoundTime
  3600; 15 -> 883 s left at the round start, RoundTime 900; none -> paused at 1488 s and still 1488 ten seconds later,
  raid started normally. Hand-written RemainingTime 2700 counted down (2693 after 7 s). launcher/test_ui.py 12/12.
  NOT tested: a land map, what happens when a set length runs out (#159 noted one process exit at timer end), whether
  the space gate's arrival depends on the round time.

## Level props: fans, reels, ambience and sparks start offline (2026-11-18, issue #143)
- Cause (decompiled with tools/offline-audit/kdis.py): `MA_RotatingParent_Simple` / `_WithAmbience` start
  `K2_SetTimer(self, "LoopThisActor", Frequency, true)` from BeginPlay only `if not IsServer()`, and `_WithAmbience` also
  `Audio.FadeIn(1, 1, 0)` there when `ShouldPlaySound`. `Base_Broken_OneShots_Parent` does `PickARandomGoalNumber()` and
  `K2_SetTimer(self, "DoAnEvent", FrequencyOfCheck, true)` (every few checks: SpawnSoundAtLocation + particle burst) on
  the same side. Offline the game is the server, so none of it ran: fans and tape reels stood still and were silent.
  (The Simple one also starts in MainMenu, which is why lobby props turned.) `LoopThisActor` only turns the mesh while
  `WasRecentlyRendered(1)`, so running timers on unseen props costs next to nothing.
- Fix: `levelprops.lua` makes the same calls once per prop, 4 s and 30 s into a raid (one class per update: each is a
  FindAllOf), tracked by address in the per-raid table. The game runs the timers from then on.
- Verified (Space_Alpha): "level props: 44 started", `K2_IsTimerActive` true on 26/26 rotating, 17/17 ambience and 1/1
  broken props, 17 ambience Audio components playing, and a rendered fan's yaw going -30 -> -45 between two reads.
  Not checked by ear or eye in normal play; land raids and station interiors not checked.

## God mode: unlimited stamina (2026-11-18; debugactions.lua holdStamina, main.lua update)
- Problem: god mode (bridge/god.txt, the F9 button) only set `bCanBeDamaged = false` on the player's pawn. Sprinting and swinging
  still drained stamina, so a long test run kept stopping to wait for it to refill. An earlier test copy of main.lua held
  stamina, but that never reached the repo.
- Fix: `holdStamina(pawn)` in debugactions.lua, called from the main.lua update right after the immunity line. While god mode is on,
  four times a second (Aux.due), if the pawn's `Stamina` is below its `MaxStamina` it is set to `MaxStamina`. Both are properties of
  `PlayerPawn_C` (hud_dump.txt lists Stamina, MaxStamina, StaminaRegainRate). A pod or ship pawn has neither, so the guarded read
  gives nil and nothing happens there. The game log gets one line the first time it acts ("god mode: stamina held at its maximum").
- Left alone: the weapon values (StaminaADSModifier, StaminaRechargeRate) and the HUD stamina bar's own burn display.
## Blowtorch locks: the vault door could not be opened (2026-11-18; blowtorch.lua, BLOWTORCH.md; reported on Discord, no issue)
- Symptom: the vault door says "F requires blowtorch"; firing the torch at its three metal pieces (top, middle, bottom lock)
  changes nothing. The torch does hurt soldiers.
- Cause (decompiled with tools/offline-audit/kdis.py, live logs from a test raid): `Base_BlowTorch_C` only plays flame, light and
  sound; its damage is native (`RaidWeapon_Tool`). `Door_BlowTorch_C` has no damage code: three `RaidLockVolumeComponent` boxes
  (`RaidLockVolume_Top / _Middle / _Bottom`, native Health 300, hidden, about 14 x 7 x 11 cm either side of the middle, 60 cm
  apart in a column) and the event `LockDamaged(LockName, HealthPercent)`, which the native weapon code is meant to call. Offline
  nothing reaches the boxes: no health change, no `LockDamaged`. When a lock reaches 0 the door waits `Delay(10)`, scales the
  latch down (about 5 s), and after the last latch the vault door opens.
- Fix: `blowtorch.lua` (`frame(pc)` from the director's per-frame section). While the torch fires (`BurstCounter` above 0), every
  0.1 s, on each door near you the lock whose box middle is nearest your aim line (camera, up to 3 m, within 30 cm) loses
  50 health a second of 300, and the door is told with its own `LockDamaged(FName, share 0 to 1)`. When a door's three locks are at 0
  it sets `bIsUnlocked`, which the "F requires blowtorch" prompt checks. State is `raid.torch`, new each raid. The boxes are looked
  for every 10 s while firing only.
- Also: the Blowtorch is in the F9 gun list (`debuggive.lua`, 250 charge), so it can be spawned for testing.
- Mistakes on the way: testing points along the aim against the boxes burned all three locks at once (the box test counted the
  camera as inside all three), so the nearest line to the aim is used. The door takes the share as 0 to 1 (it stored 0.9667 for
  290 of 300). The latch's fall starting exactly 10 s after its lock hits 0 is the door's own Delay, not lag.
- Verified (the test copy of this logic, 2026-11-18): the three locks burned one at a time, only the aimed one glowing and falling;
  the latches fell 10 s after each lock reached 0; `Door_OpenClose01` finished about 1 s after the last latch (the vault door
  opened). blowtorch.lua itself: [fill in after the test run].
- Not done: explosive barrels and gas cans. Their Blueprint (`00_UA_Exploder_Base`) only takes damage from a flamethrower or fire
  grenade area (`ReceiveAnyDamage`), from explosion damage as a radial hit (`ReceiveRadialDamage`), or from `GenTakenDamage(Amount)`,
  which looks like what a gun's hit calls. A plain damage hit and an explosion-type hit sent to a gas can (10 health) and a barrel
  (42) changed nothing. It is not known that the real torch sets them off, so they are left alone; if it does, calling
  `GenTakenDamage` from the burn loop is the likely fix (separate change). The decompiled flow is drawn in BLOWTORCH.md.
- 2026-11-23 (#374, reported not burning on build 24): not traced to a cause from code (the repair code runs after
  burn() and can't stop it). One weak spot fixed: findVolumes kept only the first 24 lock volumes in FindAllOf order,
  before the 15 m check, so on a map with more than 8 lock doors yours could be missing. Now keeps all. NOT tested in game.
- 2026-11-24 (#374, fuel and the storage crate): players measured over 100 fuel a lock; live, a whole vault was about 90.
  Fuel rate from the #70 repair test (250 charge ran dry after 14.4 s): about 17.3 a second, which matches 6 s x 17.3 = 104
  a lock at the old 50 DPS. DPS is now 175 (300 health: 1.7 s a lock, 5.1 s and about 89 fuel a vault). Storage crate door:
  no cause found from code; lock boxes whose names are not Top/Middle/Bottom are now burned too (LockDamaged gets the box's
  own name, guarded by pcall; bIsUnlocked when all of that door's boxes are down) and logged once as "lock box ... (not
  Top/Middle/Bottom)", so a test shows the crate's names if that was it. NOT tested in game.

## Raid conditions (issue 78, 2026-11-18; conditions.lua, config/raid_conditions.txt)
- A condition is a named set-up applied while a raid map is loaded: F3 settings by their ai_tuning.txt id
  (`Crews:BARON`, `Spawns:CREWS`...), `ships` (rival crews guaranteed in those hulls, boss-like: diehard, aggression 1,
  no rushing; rivalcrews.lua makeCrews sets `c.hullRow`, rivalships.lua honours it), `map` (wins over the lobby pick,
  launch.lua), `loot` (multiplies rivals CFG CARRY_BAG, MEDS max, CARRY_CAP_MIN/SHARE and CARRY_JACKPOT: bodies'
  carried loot, rivalbodies.lua rollCarried; floor and container loot are the game's and unchanged).
- Applied in onTick on a new non-menu world, restored on the menu world. Original values are kept per table slot;
  tuning.lua's save() asks `X.base` so F3 never saves a condition's value as yours.
- Picked from the launcher ("Raid conditions" row: click cycles, right-click back, status line says what it does) or
  the lobby's REGION picker: an eighth button (region 98) cycles. The game ignores a click on the region it holds as
  chosen, so after a conditions click mappick.lua puts SIGISGameInstancePGOS.ActiveMMRegion back to the last region
  clicked (or the picked map's). The pick is config/raid_condition.txt.
- Verified in game (Space_Charlie via START RAID, "Baron's last stand"): log "raid conditions: Baron's last stand (3
  settings, loot x2, ships CapitalDreadnought_Ship, map Space_Charlie)"; the lobby button's matchmaking chose
  Space_Charlie; five crews launched incl. "Red Baron's Strike Frigate" and a Dreadnought; in the raid BARON=1,
  CARRY_BAG 4-10 (2-5), CARRY_CAP_MIN 3000, JACKPOT 0.1, ATTACK_CHANCE 1, RUSHERS 0; back in the menu all back to the
  user's values and config/ai_tuning.txt unchanged. "Hunted" on a later launch: 4 settings, loot x1.5, map from the
  lobby pick. Launcher: test_ui.py passes; the row fits at 150 % after Cash and XP share a line.
- Not verified: the lobby picker button with a real mouse (the picker couldn't be opened from code: its widget stays
  collapsed), including the ActiveMMRegion reset; loot on a killed body by eye; Linux launcher.
- The bridge mod has its own Lua state: probe the director's globals (Conditions...) with bridge/profile_on plus
  bridge/dir_eval.lua, not `send.sh "lua ..."`.

## #143 leftovers: ship hum, pod hint, camera turrets, hold contracts (2026-11-18)
- Ship interiors: FrigateInside_Starter BeginPlay `if not IsServer jump 3976`; the client side is only
  `Audio_EngineAmbience.FadeIn(2, 1, 0)`. Verified silent offline (IsPlaying false in your Starter). levelprops.lua
  now fades it in per RaidSpaceshipInside (every 15 s, for interiors spawned later); verified IsPlaying true in your
  FrigateInside_Starter_C and a rival's FrigateInside_Fast_Ai_C. Not checked by ear.
- Pod hint: Base_RaidNode / Base_RaidMovementNode PopupWarning_CantEnterAsPod @20 and their ubergraphs @288 return
  early `if HasAuthority()`. The gate is `1C <FinalFunction HasAuthority> 16 07`, not the `68 <CallMath> 17 16 07`
  pve_bp_jump knew, so the first try logged "patched" and changed nothing (kdis showed it): pvepatch.c now also accepts
  a no-argument FinalFunction on self before the JumpIfNot. main.lua CLIENT_BRANCHES patches the four, retried every
  10 s (station classes load later). Verified: both decode as `jump`; calling PopupWarning_CantEnterAsPod on a node
  with your pawn made a new Popup01_Widget_C in the viewport. Not checked: a real pod flying into a docking area, and
  what PlayerIsInPodVisuals changes on screen.
- Camera turrets (Base_CameraTurret01, ship periscopes): authority side turns the barrel anim and plays the turning
  sound; the skipped side only turns SpringArmNewOne to the controller's view, which already follows the mouse offline
  (see "Manning a turret yourself"). No change.
- Base_Contract_Hold overlaps: covered by missions.lua (flags + Client_CheckMissionEvent); opening the gate too would
  start a second Guard timer. No change.

## Space object explosions and sounds (2026-11-18, issue #15)
- Symptom: turrets (flak, rocket, triple, radar dishes) and mines (small, nuclear) died or went off with no blast and no sound.
  Their damage and removal worked.
- Cause (decompiled with tools/offline-audit/kdis.py): `SubNodeActorTurret_C`'s OnDeathEvent (ubergraph offset 591) and
  `SubNodeActorMine_C`'s ubergraph build the blast (`Exploder Class`, spawned deferred then finished) and play the sound
  (`Destroyed_Sound`, `Sound_Explode`) only behind `if GetLocalRole() != 3`, the client half. Offline our role is 3. The mine's
  radial damage comes before the gate (offset 43; the `JumpIfNot` is at 221 to 459) and ran fine, which is why mines still hurt.
  The exploder Blueprints (`/Game/Blueprints/Exploders/`) have particles and a destructible but no audio: the sound is always the
  dying object's own.
- Not fixable with `pve_bp_jump`: the gate is `NotEqual_ByteByte(GetLocalRole, 3)`, not the `CallMath(self)` or no argument
  `FinalFunction` shapes it patches. `bpbranch.py` does not list `GetLocalRole` compares either, so this one never showed in its
  output (a search of dumped bytecode for `GetLocalRole` finds them).
- Fix: `spacefx.lua` (loaded from `Space.init`) hooks the native `RaidSubNodeActor_Turret:NetOnDeathEvent` (it fires offline; native
  hooks on OnDeathEvent, HealthChanged and OnRep_Health did not) and `Actor:K2_DestroyActor` for a `*NodeMine*` whose mesh is
  already hidden. Each reads `Exploder Class` and its sound off the actor, spawns the blast at its place and plays the sound with
  `SpawnSoundAtLocation` (`PlaySoundAtLocation` and `PlaySound2D` from a probe seemed silent). Once per actor, pcall everywhere. A
  first mine hook on `ApplyRadialDamageWithFalloff` was followed by a game crash on the nuclear mine, so it is not used.
- How it was tested: the F9 spawner and Log explosions showed no effect near a killed turret; kdis read the gate; then each effect
  was made by hand from the probe runner, one at a time with a countdown, asking the tester what they saw and heard (radar dish and
  flak turret: blast and sound; small and nuclear mine: blast and sound, no crash; the rocket turret had no live instance); then
  the real hooks were registered from a probe and every turret type was killed in play: all work, naval base turrets included.
  The mine hook through a real trigger is not separately reported yet.
- The test tools are in `tools/space_test/` (F9 rows: Start a space raid, the space object, exploder and salvage spawners, Kill, Poke,
  Log explosions, Log salvage; `install.py` puts them into a test copy). The full chain, class and property table, flowcharts, the
  probe and the order of the testing: [docs/internals/SPACE_OBJECT_DEATH.md](docs/internals/SPACE_OBJECT_DEATH.md).
- Open: mines through a real trigger in play; the rocket and triple turret by hand; a turret's hit sparks and a mine's
  `Sound_Triggered` were not checked for the same gate.
## Civilians (issue 81, 2026-11-18; civilians.lua)
- Miners (Mini Mine, Asteroid Mine, Moon Base), prisoners (Penal Colony) and workers (Spaceport, Colony Cruiser, Navy
  Outpost): CFG.COUNT per matching station (F3 How many "Civilians at mines, ports and prisons", default 3, 0 = off),
  spawned when you first walk into the station (rivalbodies.lua garrisonStation -> R.onStation). Body: raider body
  with an empty kit (R.civilianBody: equipKit with no rows gives no gun and no armour) and 1-3 trade items in pockets.
- Kept out of raid.bots: no soldier, rival or crewmate targets or protects them. Woken with Bots.arm, then the
  behaviour tree is stopped every update; all movement is MoveToLocation from civilians.lua (space-map branch of
  main's update). States: work (wander WANDER around home), flee (you in sight within FEAR_RANGE, your gunfire within
  SHOT_RANGE in the last 3 s via the ServerMultiSimulateWeaponFire hook's raid.playerShotAt, or hurt: run to the
  farthest of 5 reachable points, Help line), cower (you within CORNER_RANGE while fleeing: stop, crouch, plead).
  Killed near you: station guards (no faction, not crew) within ALERT_RANGE get e.alert (they come for you).
- Pitfalls hit: spots taken at random across a station's box were all off limits (12 of 12 at Penal Colony): they
  start at the station's RaidAINodeStart nodes like a garrison (the nodes are gone once used: a second batch found
  none). The stray sweep and the placed-NPC spawn hook adopted civilians as armed defenders: R.civilianAt (by address,
  cleared in R.reset) keeps them out of both. The space-map update returns early: Civilians.update sits there.
- Verified (Space_Solo_02, Penal Colony, god mode): "3 prisoners", each unarmed with 1 pocket item, 200 hp,
  wandering; you 8 m away in sight -> flee (23 m off a few s later); you 2.5 m away -> cower; ApplyDamage from you ->
  "you killed a prisoner ...: 1 guard(s) come for you" and that guard "knows where the player is".
- Not verified: by eye (animations, crouch, voice), looting a civilian's body, mines and ports (only Penal Colony
  tested), fleeing from real gunfire.
- Dressed by trade (2026-11-19, #196; Discord: they all wore the raider's green). civilians.lua LOOKS: per trade a
  list of head and body mesh names (gear.lua heads/bodies), one of each picked apart, from the rival look catalog
  (rivalbodies gearCatalog: loaded, rooted, female versions made). Miners: Miner, Steel Worker, Colonist, Nomad Yellow
  heads; Miner, Steel Worker, Nomad Yellow bodies. Prisoners: Prisoner, Outlaw 1-3, Bandit heads; Prisoner body only.
  Workers: Colonist, Steel Worker, Nomad (plain, Green, Crimson). Meshes only, no helmet or chest row: no armour.
  R.civilianBody puts the look on at spawn and returns it; civilians.lua puts it on again when it wakes them (the
  empty kit lands after the spawn), before the female dress.
  Tested (Space_Alpha, Civilians.station called through bridge/dir_eval.lua with three AI-node clusters named
  Spaceport, Mini Mine, Penal Colony): 9 spawned, all awake ("work"), all 200 hp; worn meshes read back after waking:
  workers Steel Worker/Steel Worker, Steel Worker/Nomad, Nomad Crimson/Colonist; miners Miner/Miner, Steel
  Worker/Nomad Yellow, Steel Worker/Miner; prisoners Prisoner, Bandit, Outlaw 2 heads in the prison suit. Seen on
  screen: two workers side by side in a tan suit and a red quilted one. Not checked: the female versions by eye,
  whether a later gear change puts the raider body back (nothing changes their gear), the helmets/caps idea.

## Bullet holes (2026-11-18; bulletholes.lua, docs/internals/BULLET_IMPACTS.md)
- Symptom: shots at walls and floors gave particles and sound but no bullet hole (a few marks on metal and blood on a bot
  came from the game itself). The earlier note above ("DecalComp is nil, so bullet-hole decals are unconfirmed") was right:
  all 500 pooled impact actors (`RaidPlayerController.PooledImpactActors`, `BasePoolHitEffect_C`) have no decal component, and the
  Blueprint's ubergraph is empty (kdis), so the pool can never draw one. The decal materials exist and are loaded (38
  `BulletImpactDecal_<family><n>_MIC`: Concrete, MetalSolid, MetalThin, Wood, Snow, Glass_BulletProof, Sandbag, Wall, Brick, Water,
  Blood).
- Not hookable: a Lua hook on `RaidPoolImpactEffect:OnPoolActive` saw 0 activations (native calls it directly). The pool actors
  carry a `bInUse` flag, so the mod reads that.
- Fix: `bulletholes.lua`, called every frame from main.lua (`BulletHoles.frame`). Every 0.1 s it looks at the pool; an actor
  that just became in use, or moved while in use, is a new impact. Its rotation faces along the surface normal, so a 15 cm line
  trace each side of it along that direction gives the exact point and normal. `GameplayStatics:SpawnDecalAtLocation` then puts a
  decal of the matching family there (size is half extents, `{ 12, 5, 5 }`, rotated to face into the surface, random roll and
  variant, 60 s). Surface comes from the name of the actor's `EffectForHit` (`PS_BulletHit_<name>`): Concrete, MetalSolid, Tinplate
  (MetalThin), Wood, Glass, Snow. Ground, Water, Fabric and Blood get none. Holes are kept in a list and the oldest are destroyed
  past `MAX_HOLES`. F3, tab "Effects": `BULLET_HOLES`, `HOLE_SECONDS`, `MAX_HOLES`, `HOLE_SIZE`. F9 has a "Bullet holes" on or off button (debugactions.lua).
- First attempt traced from the camera to the impact point and rejected everything (bots' shots are off your view line); the
  actor's own forward vector fixed it. First decals were too big (half extents, not full size).
- How it was tested: the live tracer listed the pool and its properties; a probe watched the actors and logged surface, normal
  and rotation; then stamped decals while the tester shot walls, floors, metal, wood and glass with a rifle and a shotgun (concrete
  221, metal 70, wood 30, glass 31, no errors); then the module itself from a harness: no hitch on the first shot, a cap of 10
  left about 10 holes with the oldest gone.
- Open: Tinplate, snow and ground impacts (no map tried; the log names any surface that has no hole once); whether the game's own
  marks double up with ours on some surface (none reported); some shotgun gunshot sounds are silent from one spot (the weapon's
  own sound, not looked at); the F3 Effects tab and the main.lua wiring are only checked by luacheck until the next restart.

## Co-op join: the login never creates a player (2026-11-18; native/pvetrace.dll, tools/profile/dump_image.py)

**Superseded - see "Correction: the server DOES create a PlayerState" below.** The measurements
here were taken inside the ~3 s window before PostLogin, so "no PlayerState, the gate is in
PreLogin/Login" is wrong: the server does create the PlayerState, PreLogin and Login both pass,
and the client is what gives up. Kept because the probe hazards and the correction to the
CEF-parameter theory still hold.

The joining client's connection is accepted and dropped ~3 s later. Measured on the host with
array-length-only probes (10 Hz), reproduced many times:
- `world.NetDriver.ClientConnections` 0 -> 1 -> 0 in ~3 s; `GameState.PlayerArray` **stays 1**,
  so the server never creates a PlayerState for the joiner. Map load, the bare `PlayerController`
  the client spawns at +5 s, and the bounce to MainMenu are all consequences, not causes.
- `GameModeBase:HandleStartingNewPlayer` fires for the host's own entry every raid but **never**
  for a joiner (control is the same hook). `RestartPlayer` registers but never fires even for the
  local player, so a non-firing `RestartPlayer` proves nothing: UE4SS only sees ProcessEvent calls.
- Never fire either: `GameLiftPlayerController:ServerAcceptPlayer` / `ServerRemovePlayer`,
  every EAC/SIGIS RPC, `K2_OnLogout`, any kick RPC.
- Tried and did NOT change it: `player_battle_session_id=<the host's MatchSessionID>`, `player_id`,
  `UseDebugLogin=true` on the client's game instance, and filling `SIGISGameMode.ConnectedPlayerIds`
  (@gamemode+0x3D8, empty on a listen host, MaxPlayers 50) from native code before the join.
  The last one is "very likely not the gate", not disproven: UE4SS cannot stringify array elements,
  so the ids the engine sees were never verified.
- Next instrument: the login lives in native code with no UFunction wrapper. The vtable route is
  mapped (below); a trampoline hook on the candidate is what will confirm it, because the login
  rejection leaves no observable RPC.

**Correction to "Co-op host+join attempt" above:** the UTF-16 option strings at 0x40998c8 are NOT
join options the exe parses. They sit next to `...erController::HandleOnUrlChanged` with `?code=` and
`?error=` beside them, and nothing in the loaded image references them - no rip-relative reference in
`.xtext`/`.xcode`/`.arch` (2- and 3-byte forms) and no absolute pointer in any data section. They are
the CEF login page's result parameters. Experiments varying PID/psid/CREW/CPT/NUM could not have worked.

## Reading this exe (2026-11-18)

- **The file is packed; only memory has code.** `.xtext`/`.xcode`/`.arch` are encrypted on disk:
  disassembling a known code RVA in the file gives nonsense (`and al,0x88`), the same RVA in the
  live process gives real code. All analysis must read the running process (or a dump of it).
- **`.data2` holds code too** - not just data. Small stubs like `ret 0` (0x7e0290, the shared empty
  override), `mov al,1; ret` (0x7e0320), `xor al,al; ret` (0x7e0330) live there, so "section name"
  does not tell you thunk vs body.
- **UFunction + 0xD8 is `Func`,** and it points at a `.data2` thunk (`jmp <abs>`) that jumps to the
  real implementation in `.xcode`. `HandleStartingNewPlayer`: UFunction -> 0x3588a80 -> **0xd7b8ab0**.
  UFunction objects are allocated 0xE0 apart, so +0xE0 is the *next* object's vtable, not a field.
  This converts "find a function in a 246 MB blob" into "read one pointer".
- **GameMode vtable map** (`ShootingRangeGameMode_C`, instance vtable RVA **0x4599ed8**, 420 slots):
  396 resolve; most are tiny `.data2` overrides. Only slots **0** (0xa0518f0) and **23** (0xc9f9b10)
  reach substantial `.xcode` code. `PreLogin`/`Login` are not identified yet; shape-matching by
  argument registers was inconclusive (a first pass gave a false positive at slot 96 because the
  scanner ran past the function's `ret` into the next function - bound the scan at `ret`/`int3`).
- **Tools fixed:** `tools/profile/refs.py` and `strfind.py` only scanned `.data2`/`.xcode` for
  references, so they found nothing on this build; both now include `.xtext` and `.arch`.
  `procmem` opens its process handle at import - reload it after the game restarts or reads fail at
  the old base. New: `tools/profile/dump_image.py` writes the live image to a PE (ImageBase patched
  to the runtime base) for Ghidra.

## Probing hazards that cost crashes (2026-11-18)

- **Do not dereference a fresh `UNetConnection`.** Reading `conn.State` / `conn.OwningActor` at the
  moment a client connects killed the host twice (crash dumps 15:16:09 and 15:18:56,
  `EXCEPTION_ACCESS_VIOLATION`, 37 UE4SS frames above the game's). `pcall` cannot catch it.
  Reading only array *lengths* (`ClientConnections:GetArrayNum()`, `GameState.PlayerArray:GetArrayNum()`)
  is safe and was enough for every measurement above.
- **Never assign a Lua table to a `TArray` UPROPERTY** (`gm.ConnectedPlayerIds = {...}` kills the
  game instantly). Filling such an array needs native code (`native/arrwrite.c` pattern: point the
  array's Data at a static block, set Num/Max).
- **A probe calling `FindFirstOf` at 1 Hz during a load kills or freezes the second client** (full
  object scan, 30-45 ms each). Re-run with the probe off before blaming the game.
- Harness: the host is shot by its own AI if left alone - `bridge/god.txt` makes it immune.
  `PvEBridge` goes permanently deaf after a world change (its LoopAsync stops after the first
  successful hook), and at the splash it only answers with PvEDirector enabled.

## Correction: the server DOES create a PlayerState (2026-11-18; live GameMode probe)

The section "Co-op join: the login never creates a player" is wrong on both of its conclusions,
and the measurements behind it were taken inside the ~3 s window, before PostLogin ever ran.

Instrument: a native DLL that patches the GameMode's **vtable entries** (not function prologues,
so no instruction is relocated) and logs each slot's first call with rcx/rdx/r8/r9 and any
plausible string among them. Loaded through a Lua mod's `package.loadlib`, because this UE4SS
build has no C++ mod support (`strings UE4SS.dll | grep StartMod` is empty) and bridge command
chunks are sandboxed. Slots used, all verified live:

- **slot 233 = PreLogin**, RVA **0x17E5320**. Logged with `rdx` = the full join options
  (`?PID=offline2?PNAME=Marauder2?...?Name=Marauder1?SplitscreenCount=1`) and `r8` = `127.0.0.1`,
  which is the `(Options, Address, UniqueNetId, ErrorMessage&)` signature.
- **slot 234 = Login**, RVA **0x30D0060**. Fires *after* PreLogin, so **PreLogin returns true**.
- Neither writes anything into any ErrorMessage argument (the candidates were watched for 6 s
  after each call), so **neither call rejects the join**.
- After Login the host walks the options string character by character (slots 237/257 show UTF-16
  fragments `Spli`/`eenC` from `SplitscreenCount=1`) and slot 240 receives `"Marauder1"`.

What the server actually holds afterwards, read through the bridge's `lua` verb:
`FindAllOf("PlayerState")` = **2** while `PlayerController` = 1. So the server created the joiner's
PlayerState, reached **PostLogin**, and destroyed the PlayerController when the client left.

**Therefore the drop is client-side:** the client loads the map, spawns a bare PlayerController,
and travels itself back to `/Game/Maps/MainMenu`. The login gate is not the server's PreLogin or
Login; it is whatever the client decides after it has the map. Next instrument: wrap the client's
own GameInstance/PlayerController vtable and find the slot that runs immediately before the travel.

String constants recovered from the dump, for the record: `"incompatible_unique_net_id"`
(PreLogin's uid-mismatch branch, not taken), `"Failed to spawn player controller, GameSession is
null"` and `"Failed to spawn player controller"` (Login; GameSession is non-null at gm+0x278),
`"SpectatorOnly=1"` (a post-login branch).

## Reading the bridge with the `lua` verb (2026-11-18)

A bridge line that is not a known verb is run as Lua and answered with `ran: <code>`, which hides
both the result and any error. The `lua <code>` verb is different: it runs the chunk on the game
thread and replies `= <return value>`. Use it for every query.

    bsend.sh bridge 'lua return #(FindAllOf("PlayerState") or {})'
    bsend.sh bridge 'lua local t=FindAllOf("PlayerState") or {} return #t'

`FindAllOf` and `FindFirstOf` work from there; `tostring(obj)` prints `UObject: 0x<address>`, which
is the object address, and the first qword at that address is its vtable - the cheap way to get a
class vtable in a process whose base you have not resolved.

Two probe bugs worth keeping: an empty `FString` is `Data=0 Num=0 Max=0`, so a filter that
requires `Num >= 1` never watches the error buffer it is meant to watch; and re-wrapping a vtable
whose slots still point at your own stubs fails the "does this look like a vtable" check until the
stubs are restored first.

### Client side: the GameInstance vtable is not where the bounce is decided (2026-11-18)

Same probe, pointed at the client (VTH_DIR per instance, because both copies share one DLL). The
client's GameInstance vtable was found without resolving a base: bridge2's `lua` returns
`UObject: 0x...` for `FindFirstOf("GameInstance")`, and the first qword at that address is the
vtable - 245 slots wrapped, 173 of them executable.

Only **12** virtual calls ran during the join, and none is a travel: slots 192/124 are the console
`open` command itself (they receive the URL string), and the rest are ordinary engine plumbing. So
the decision to return to MainMenu happens on another object - the client's PlayerController or
the engine - not on the GameInstance.

Decompiling those 12 targets without a full analysis does not work: Ghidra bounded three of them
as 46-50 KB blobs (no analysis means no function boundaries), so the output is unusable. Any
further client-side work wants either the analysed project or a different measurement, not more
targeted decompiles.

Two process facts learned the hard way: `Get-Process ... Modules[].BaseAddress` returned the
HOST's base for both PIDs, so RVAs computed from it were nonsense - `VirtualQueryEx`'s
`AllocationBase` gave the real one (`0x7FFF0BCF0000` for that client, versus the host's
`0x7FF765060000`, so ASLR really does differ per instance). And the probe's own module-range
check reads 0 "in module" in the client while still finding 173 executable entries, so the gate
now trusts executable pages and a two-thirds ratio rather than my range arithmetic.

## Night two: the probe grew teeth, and one address fact that explains the dead ends (2026-11-18/19)

Reached with the same native vtable probe, now with four verbs on its command file:

- `obj=0x<address>` - wrap the vtable **of that object**; the deref happens in-process, so the
  caller needs no module base. Trusted: an address that came from an object's first qword is a
  vtable by construction, so the executable-ratio gate is skipped for this path.
- `vt=0x<address> [trust=1]` - wrap a caller-supplied address, gate on by default.
- `read=0x<address>:<hex bytes>` - log qwords from that address, page-checked first.
- `base=1` - log `GetModuleHandleA(NULL)` for the process.

**The address fact.** On a live listen host, `FindFirstOf("MainPlayerController_C")` gives an
object whose first qword is `0x7FFF0E596C80`, while `base=1` reports the module at
`0x7FF765060000`. Subtracting gives a 32 GB "RVA", so **that object's vtable is not at
`gbase + rva`**. The GameMode wrap that worked was measured the other way round - `gbase + 0x4599ED8`
came out 420/420 executable - so both statements are true and the two classes are not in the same
mapping. Until this is understood, do not derive a vtable address by adding an RVA to
`UE4SS.log`'s MainExe base for an arbitrary class; use `obj=` and let the process read its own
memory.

**Bridge reply parsing.** Replies are `HH:MM:SS = <value>`, so `line.startswith("=")` never
matches and every lookup silently reads as "not found". That one bug invalidated a whole round of
"the object does not exist" conclusions (the client PC, the class vtable). Match `=\s*(.+)$`.
`tostring()` of an actor prints `AActor: 0x...`, not `UObject: 0x...`.

**Where the join stands.** Unchanged from the correction above: the server accepts, creates the
PlayerState and reaches PostLogin; the client gives up ~3 s later. New this round: the client's
`GameInstance` and `GameEngine` vtables were wrapped and show only travel/URL plumbing, none of it
a decision to leave. Re-arming the wrap *after* the `open` command is required, since those slots
disarm on the first hit and the command itself consumes them.

**Not fixed.** No patch is in place. The next instrument is the client's PlayerController class
vtable armed before it connects, which needs the `obj=`/`base=` question above settled first.

## The address puzzle is solved: UE4SS's tostring() is not the UObject (2026-11-19)

`tostring(actor)` in this UE4SS build returns a **wrapper** object, not the UObject. Proof from one
live host, same process:

- `FindFirstOf("ShootingRangeGameMode_C")` and `FindFirstOf("MainPlayerController_C")` both
  stringify to distinct addresses, but **the first qword at both is the same value**
  (`0x7FFF0E766C80`), and `VirtualQueryEx` + `GetMappedFileNameW` put it in **UE4SS.dll**, not in
  the game. That is why every shape check reported "0 in module" and why `obj=` wraps of those
  addresses produced nonsense tables.
- `obj:GetAddress()` returns the real UObject. For the same PlayerController it gives a different
  address, whose first qword is `0x7FF769608738` - allocation base `0x7FF765060000`, file
  `RaidGame-Win64-Shipping.exe`. So the real class vtable is at **RVA 0x45A8738** and everything
  derived from `gbase + rva` was correct all along.

Rules that follow: use `GetAddress()` (or `obj=` with an address that came from `GetAddress`),
never `tostring()`, when a vtable is wanted. `GetClass()` stringifies as `UClass: 0x...` and is
fine for identity, not for addresses.

## Bridge chunks must be one line (2026-11-19)

`bsend`/the probe inbox read a single line, so a Lua chunk containing newlines is truncated at the
first one and the reply is just the echoed code. Multi-statement chunks have to be joined with
spaces. Replies are `HH:MM:SS = <value>`; match `=\s*(.+)$`, and remember actor `tostring` prints
`AActor: 0x...`.

## Client PlayerController trace, with a real vtable this time (2026-11-19)

With `vt = client_base + 0x45A8738` (the class vtable, wrapped before connecting), one join logs
**78** virtual calls on the client's PlayerController, including a console command
`ENABLEALLSCREENMESSAGES` and a `"Maar..."` name string - and **not one travel call**. The client
does not decide to leave at the game layer; the give-up is beneath it (engine network failure).

Server side of the same join: `ps=3 pcs=2 pawns=1`. The joiner's PlayerController exists and its
`Pawn` is a pointer whose object is already invalid by the time it is inspected, i.e. the server
completed the join and then tore the pawn down when the client left. `SpectatorPawn` count is 0, so
"the joiner is made a spectator" is not supported by this evidence.

Open lead for next time: the client fails *after* `ClientSetHUD` and *before* its controller's
`BeginPlay`, with no game-level travel, so the failure is in the engine's pending-netgame/connection
path. That is below every vtable wrapped so far; the next instrument wants
`UNetDriver`/`UPendingNetGame` state (or the connection's close reason) rather than more game
classes.

## UNetDriver / PendingNetGame from Lua: reachable only while the join is live (2026-11-19)

Tried to read the engine's pending-netgame state from Lua, since the game-layer vtables showed no
travel and the failure must be below them.

- `FindFirstOf("NetDriver")` and `FindFirstOf("PendingNetGame")` both return objects **at the menu
  after a failed join**, so the objects survive the failure - but `:GetAddress()` on the
  PendingNetGame, on its `NetDriver` and on `NetDriver.ServerConnection` all return **0**. They are
  stale: the wrapper still resolves, the UObject behind it is gone. Any read taken after the
  fallback is meaningless, which is why an earlier "state" read looked plausible and said nothing.
- Property reads return `userdata` wrappers, not primitives: `p.bFailedToConnect` is a userdata
  whose `tostring` is `UObject: 0x...`, and `v:get()` returns a *function*. So this build does not
  let Lua read a bool or an enum property directly; state has to be read from memory at known
  offsets (the probe's `read=`), sampled during the live join window.
- Consequence for the next attempt: poll while the join is in flight (the client's bridge is alive
  until the world change), not afterwards, and read `UNetConnection::State` and
  `UPendingNetGame::bFailedToConnect` by offset rather than by property name.

## One join window per client launch (2026-11-19)

The client's bridge answers until the join's world change and then never again, so a launch gives
exactly **one** attempt at measuring. Polling from outside loses that attempt to a race: the
`open` command and the first poll compete for the same one-command-at-a-time inbox, and by the time
the poll is answered the client is already travelling.

What that means for the connection-state experiment: do not poll. Pre-arm a **hook**
(`RegisterHook` on a function that runs during connect) so the capture happens on the game thread
at the moment the object exists, and have it hand the address to the probe's `read=`. A fresh
client launch is required per attempt, so a failed run costs a full 50 s cycle.

Dead ends confirmed this round, in order: `PendingNetGame`/`NetDriver`/`ServerConnection`
`GetAddress()` is 0 after the fallback (stale wrappers); property reads return `userdata`, and
`v:get()` returns a function; polling the client's bridge during the join gets no reply at all.

## Client RPC hooks fire; the connection is still unreachable from Lua (2026-11-19)

A Lua mod that registers `RegisterHook` on `PlayerController:ClientRestart`, `ClientSetHUD`,
`ClientGotoState` and `ClientTravel` proves two things and closes one door:

- **The hooks fire on the client**, including `ClientRestart` - so the client does receive the
  restart RPC, it just never reaches `BeginPlay`. That is a sharper statement than "before BeginPlay".
- **`GetAddress()` on the connection is 0 even during connect.** Inside the hook, while the join is
  live, `PendingNetGame.NetDriver.ServerConnection:GetAddress()` returns 0, so the probe has nothing
  to read. The Lua route to `UNetConnection::State` is therefore closed in this UE4SS build, not
  merely awkward: every property wrapper either reads 0 or returns a function.

Getting the connection's pointer needs C++ (a mod DLL walking `UPendingNetGame`/`UNetDriver`
directly), not Lua. That is a bigger build than anything so far and is the honest next step.

Design note for whoever reuses the trick: the hook mod writes its probe command into
`bridge2/vth_cmd.txt` with `io`, which works from a mod's script (unlike a bridge chunk) and needs
no bridge round-trip. But both game instances load the same mod, so the hook log must be namespaced
per instance or it interleaves host and client lines - the run above muddied itself that way.

## Server side: the client goes silent, the server only cleans up (2026-11-19)

Server-side sampler: probe command `drv=0xADDR` walks `UNetDriver::ClientConnections` (offset
`0x90`, TArray) and byte-diffs each connection's first `0x200` bytes at 10 Hz. Offsets come from
the game's own reflection dump (884 headers, `sdk` verb):

| field | offset |
|---|---|
| `UPendingNetGame::NetDriver` | `0x30` |
| `UNetDriver::ServerConnection` | `0x88` |
| `UNetDriver::ClientConnections` | `0x90` |
| `UNetDriver::World` | `0x140` |
| `APlayerController::Player` | `0x298` |
| `APlayerController::NetConnection` | `0x418` |
| `UNetConnection::Driver` | `0x58` |
| `UNetConnection::LastReceiveTime` | `0x1D0` |

One join, 70 samples at 10 Hz:

- `ClientConnections` num: `0` (29 samples) -> **`1` (41 samples)** -> `0`. So a join connection
  exists server-side for about 4 s.
- `LastReceiveTime`: `85.371` -> `85.622` -> **`85.702`, then frozen for 39 samples (3.9 s)** while
  the connection was still in the array. The client's last packet arrives ~0.33 s after the
  connection is first observed, and then nothing.
- Byte diffs at the drop touch only `0x168..0x172` and `0x1D2..0x1F5`, which look like ack/hash
  counters. **Nothing in `0x00..0x168` changes**, so `UNetConnection::State` (not reflected) is
  either outside that range or not a plain byte - the earlier assumption that it sits just before
  `Children` (`0x48`) is unsupported by this data.

**What this settles:** the client stops sending and the server does not close the connection - it
lingers ~4 s and is then cleaned up. Together with #24 (traffic stops both ways with no close
packet) the initiator is the client's send path, not a server kick. That is a different conclusion
from "the server rejects the joiner", and it is the first time the drop has been located on the
wire with a timestamp rather than inferred.

**Also confirmed:** the client's `NetConnection` is 0 and it only ever holds `MenuPlayerController_C`
during `ClientSetHUD`, so it never materialises a controller for the join at all.

Next: widen the server dump past `0x200` to place `State`, and instrument the client's send path
(`UNetConnection::SendRawBunch`/`FlushNet`) to see whether the client stops sending because its own
connection object died or because it is waiting for something.

### Widening to 0x600: the server still ticks the connection while the client is silent (2026-11-19)

Second server-side run with the diff range widened from `0x200` to `0x600`. `UNetConnection::State`
still shows no `3 -> 1` transition, and no single byte in `0x00..0x600` behaves like a state enum.

What the widened dump did show, and it is worth more than the enum would have been: with
`LastReceiveTime` **frozen from the first sample** (`86.889` for the whole window), fields at
`0x1EA..0x1F5`, `0x1F8`, `0x248` and `0x480..0x48B` **kept changing every 100 ms**. Those look like
outgoing ack/timer/hash bookkeeping, which means the server is still actively ticking the
connection - it believes the connection is alive - while the client transmits nothing.

So the drop is not a close at all. Nobody sends a close: the server keeps an open, ticking
connection, and the client simply stops transmitting. That tightens the earlier reading ("the
client goes silent and the server only cleans up") into "the server never even notices anything is
wrong until the connection is eventually reaped".

Practical note on the sampler: the `State` hunt has now cost two runs. A cleaner way to place it is
to watch a value that must move - send one packet and diff - rather than looking for an enum that
may be bitfielded or living outside the dumped range.

### Client-side vtable scan: no coherent UNetConnection exists to sample (2026-11-19)

`scan=0xVT[:secs]` walks commit-private memory looking for objects whose first qword equals VT.
The vtable address is the class RVA `0x41A9050` (measured from a live server-side connection)
plus the client's own module base, which the probe reports via `base=1`.

Two 12-second scans spanning a join, on the client, found only:

- `obj=656ad0ddb0 cls=0 drv=7fff9a4c1836 lrt=0.000` - Class pointer is not a heap address, so not
  a UObject at all: a coincidental 8-byte match.
- `obj=1f4661b9d10 cls=1f45bdf8b00 drv=0 lrt=0.000` - plausible Class pointer, but `Driver` at
  `0x58` is 0 and `LastReceiveTime` never moves, so it is not a live connection.

So the client never holds a constructed `UNetConnection` anywhere in its private heap during the
join - which fits the rest of the evidence (no join PlayerController, `NetConnection` 0,
`PendingNetGame.NetDriver.ServerConnection:GetAddress()` 0). Either the object is never built, or
it exists for less than one scan pass and is freed.

Tell-tale detail worth remembering: a scan for a vtable is only as good as the vtable. A wrong
or truncated address yields plausible-looking hits, and the fields at `0x10`/`0x58` are what
separate a real object from a coincidence - so check `Driver` and `LastReceiveTime`, not just the
first qword.

**Better next step than more connection scanning:** scan for the *NetDriver* vtable instead (the
client definitely has a live NetDriver - `FindFirstOf("NetDriver")` resolves one) and read
`ServerConnection` at `0x88` from it. That reaches the connection through a pointer rather than by
hunting for it, and the driver object exists from boot.

### NetDriver route: found a driver, but the connection's layout does not match the dump (2026-11-19)

`ndscan=0xVT[:secs]` finds an object by vtable, takes `*(obj+0x88)` as `ServerConnection`, then
diff-samples that pointer at 10 Hz. This is the first route that does not need a race window: the
NetDriver exists from boot.

Measured on the host first, so the client can be armed with only its own module base:

- `FindFirstOf("NetDriver"):GetAddress()` works (unlike the pending-netgame wrappers).
- Host NetDriver vtable = `0x7ff769209428`, module base `0x7ff765060000` -> **RVA `0x41a9428`**
  (the connection class vtable sits 0x3d8 below it, at `0x41a9050`).

One client cycle:

- `NDHIT obj=f966a5db78 ServerConnection=f966a5dcb0` - a driver instance **was** found, and
  `+0x88` was non-null, which is what a client's driver should hold.
- But sampling that pointer gave `lrt` values like `5.7e300`, i.e. **garbage as a double**, and
  140 samples of churn at `0x18`, `0x60/0x61`, `0x70..0x87`, `0xf8`, `0x100`, `0x120..0x148`.

So one of two assumptions is wrong: either the object found is not the game's NetDriver (some other
class with that vtable is unlikely, but a *different driver* - demo/replication - is possible), or
`0x88` is not `ServerConnection` for the connection class on this build. The dump that gave the
offsets was generated from this same build, so the more likely error is the first: the scan hits the
first matching object in memory, which may not be the driver in use.

**Next:** before trusting `+0x88`, verify the object really is a `UNetDriver` - log `*(obj+0x10)`
(Class) and compare it against the Class pointer of the driver that `FindFirstOf` returns on the
host, and log `*(obj+0x190)` (NetDriverName, an FName) which should spell `GameNetDriver`.

### The NetDriver scan was finding its own stack; the dump offsets are right (2026-11-19, later)

Verified on a single offline instance, menu map opened with `?listen`, probe loaded from the bridge
with `lua package.loadlib("<repo>/native/vtprobe.dll","*")` (no loader mod needed: `package` is
reachable from a `lua` chunk, and `"*"` loads the DLL without calling an export).

- **At the main menu there is no NetDriver at all.** `FindAllOf` returns 0 for `NetDriver`,
  `IpNetDriver`, `DemoNetDriver`, `SteamNetDriver` and the beacon classes, and
  `FindFirstOf("NetDriver")` is nil. The earlier "the client has a live NetDriver from boot" was
  wrong (it was most likely read after a failed join, from a stale wrapper). A client's game driver
  only exists during the join.
- **A listen host holds exactly one**: `IpNetDriver_<n>`, `NetDriverName` = `GameNetDriver`, the
  same address as `World.NetDriver`. The `Default__IpNetDriver` CDO shares its vtable **and** its
  Class pointer; only the object flags at `+0x08` tell them apart (`0x40` instance vs `0x31` CDO).
- **`ndscan` on that host hit `0x19c7e0dbc8`, not the driver at `0x1c128338100`.** The "connection"
  it then sampled was `obj+0x138`, and the bytes changing there were the probe's own strings
  (`.../bridge/vth_cmd.txt`, `ndscan=0x...`, its log text). The scanner matches the copy of the
  vtable value on **its own thread's stack** and stops at the first hit. The client NDHIT in the
  section above had the same shape (`ServerConnection = obj + 0x138`, a low non-heap address), so
  that run measured the probe, not the game. The `lrt=5.7e300` garbage is explained; no layout
  mismatch exists.
- **The dump offsets hold on the real driver** (`read=` of `0x198` bytes): `+0x00` vtable
  (RVA `0x41a9428`), `+0x10` Class (= Lua `GetClass():GetAddress()`), `+0x88` ServerConnection = 0
  and `+0x90` ClientConnections empty (right for a server with nobody joined), `+0x140` World (=
  Lua's World address exactly), `+0x190` NetDriverName = FName index `0x2e8` (`GameNetDriver`).

Same suspicion applies to the earlier client connection scan ("no coherent UNetConnection"): its
low-address hit was very likely the same self-match and the heap hit with `Driver=0` looks like the
`IpConnection` CDO. Its conclusion still stands (nothing live was found), but it says nothing about
whether a scan *could* have found one.

**Not done:** the scanner was not fixed. `vtprobe.c` lived in a session scratch folder that has
since been cleared, so only the built `native/vtprobe.dll` (gitignored) remains. A rewritten scan
must accept a hit only if it lies in a heap region (not a thread stack: skip `MEM_PRIVATE` regions
that hold a TEB-listed stack, or simply skip the scanning thread's own stack range), has
`*(obj+0x10)` equal to the IpNetDriver UClass (read from Lua before joining), lacks the CDO flag
(`0x10`) at `+0x08`, and has `+0x190` = `0x2e8`. It must keep scanning past the first hit. Then
`+0x88` on the client during the join is the next real measurement.

## Co-op join works: the host refused a PNAME that isn't Base64 (2026-11-19; native/vtprobe.c, PvEBridge `join`, #26)

**Cause, measured end to end:** the host's GameMode `InitNewPlayer` override (exe RVA `0x98cba0`) reads the joiner's
`PNAME` option through `FBase64::Decode` (RVA `0x19e5db0`). `Marauder2` is not valid Base64 (9 characters), decodes to
nothing, and the function returns the error **`"PlayerNick is null"`**. Login fails, the host sends `NMT_Failure` with
that text, and the client closes. `PNAME=TWFyYXVkZXIy` (Base64 of `Marauder2`) joins: the client spawns its
`MainPlayerController_C` and `PlayerPawn_C` in the host's Spaceport_01, the host's bots replicate in (client pawn count
9 -> 33), and the connection stays Open (checked for over a minute, three joins, the last from a fresh client with no
probes). The host's own `PNAME=Marauder` passed all along only because 8 letters happen to be valid Base64.

The same function also requires a `PID` (`"PlayerID is null"`) and skips both checks only when the world type is
3/4 (PIE / editor preview, by the look of it). It parses `PID SHIP CREW CPT NUM EOS UPN PNAME psid`; only PNAME is
Base64-decoded.

How it was found (one session, all on the client unless said):
- **No NetDriver exists at the main menu** (`FindAllOf` 0 for every driver class). A listen host has exactly one,
  `IpNetDriver` named `GameNetDriver`. The old scan's "driver" was its own stack (section above).
- `NotifyOnNewObject("/Script/OnlineSubsystemUtils.IpNetDriver", cb)` from a bridge `lua` chunk fires on the game
  thread with the real object; `cb` writes `watch=0x<addr>` into the probe's command file. No scanning: a scan pass
  over a 5.6 GB heap takes ~10 s, longer than the join. `io` and `package.loadlib` are reachable from bridge chunks.
- **The client does build a UNetConnection** (vtable RVA `0x41a9050`, its `Driver` points back). The earlier "no
  coherent UNetConnection" was the broken scan.
- `+0x134` behaves as `UNetConnection::State`: the host's connection is 3 (Open); the client's stays 2 (Pending) until
  it closes (1). After the fix it goes 2 -> 3.
- **The "silence" was the client's map load.** The client's driver has `World=0` and its connection does not change
  at all for ~3.7 s (not even the per-tick field at `0x1f3`); the host's LastReceiveTime is frozen for the same time.
  "The server keeps ticking while the client is silent" (above) is this load, not a drop.
- With both instances logging on QueryPerformanceCounter (system-wide), 1 ms sampling: the client went to Closed in
  the same 2 ms as receiving a host packet; the host was still Open ~9 ms later and closed only on the client's close.
  So the host answered the Join without closing (UE4's join-failure path sends NMT_Failure and flushes) and the
  client closed.
- A hardware write-watch (DR0) on the client's `conn+0x134` caught the closing write with a clean unwind:
  `UWorld::Tick` -> `ReceivedRawPacket` (`"Packet failed PacketHandler processing."`) -> `UChannel::ReceivedRawBunch`
  -> control channel `ReceivedBunch` -> `NotifyControlMessage` NMT_Failure (`"NetworkErrors"`,
  `"GenericConnectionFailed"`) -> `UNetConnection::Close` (RVA `0x31ea2dc`). FStrings copied off the stack in the
  handler gave `"?failed"` and **`"PlayerNick is null"`**.
- An execute breakpoint on the host at `InitNewPlayer` captured the Options it received, PNAME included:
  `?PID=offline2?PNAME=Marauder2?CREW=solo2?...?Name=Marauder233?SplitscreenCount=1`, called from Login (RVA
  `0x30d0254`) <- SpawnPlayActor <- NMT_Join. The decode function's shape (decoded-size, decode returning bool,
  UTF-8 to TCHAR) is UE4's `FBase64::Decode(const FString&, FString&)`.

Setup that worked: host = `launch-offline.ps1`, bridge `raid Spaceport_01?listen`, `bridge/god.txt`. Client = same exe
with its own `TEMP`/`TMP`, `PVE_BRIDGE=<repo>/bridge2/` (holding `offline_backend`), deployed `Mods/mods.txt`
PvEDirector 0, then `bsend.sh bridge2 join`. Host and client had the same module base this time (`0x7FF765060000`).

**Not done / not tested:**
- The client ran with PvEDirector **off**, as in every earlier co-op run; earlier notes say its hooks froze a joining
  client. Co-op with the director on both sides is the next thing to try.
- Nothing played beyond spawning: no movement, combat, looting or extraction checked on the client, and no second
  PC. Both instances used the same stand-in account.
- ~~Every player's displayed name reads `伸Хɯ`~~ **Not a bug (20 Nov, #200):** that name was never on screen. It came
  from the probe itself, `PlayerState:GetPlayerName():ToString()` in Lua, and UE4SS returns junk for every FString a
  UFunction returns (`KismetStringLibrary:Concat_StrStr("ab","cd")` gave junk too). Property reads are fine: offline
  the PlayerState has `PlayerNamePrivate` = `Marauder<n>`; `PlayerNickName`, `UniqueUserName`, `EOS_ID` are empty.
  Checked in co-op (host + joiner aboard one Rustbucket, Space_Alpha): no TextBlock on either screen holds garbled
  text, and the game draws no name over the other player. Read text through properties (`TextBlock.Text`), never
  through a function's FString return.
- No launcher or in-game co-op UI: joining is the bridge `join` verb only.

### Co-op with PvEDirector on both sides (2026-11-19, later; main.lua onTick)

Both instances with every mod on (the client too), host Spaceport_01 listen, client `join`: **no freeze**. The
earlier freeze came from diagnostic hook scripts, not the director. The client gets its controller and pawn, and all
16 of its `BotPawn_C` are replicated (`HasAuthority` false), so the client's director spawns no soldiers of its own.

**Bug found and fixed:** the host's director restarted the raid when the joiner arrived. A second batch of soldiers
(8 -> 16), floor loot placed again, the stash checked out again. Cause: the director ticks on
`MainPlayerController_C:ReceiveTick`, which on a host also fires for the joiner's server-side controller, and
`update()` keys the raid on `world@addr/pc@addr`, so every switch between the two controllers ran `resetRaid`. Fix: at
the top of `onTick`, a controller whose `IsLocalController()` is false is skipped (remembered per address, cleared per
world). Tested: host 6 bots before the join, 6 after, one `co-op: ignoring a joining player's controller` line, no
second spawn or floor-loot line, joiner has its pawn.
- 2026-11-21 (#297): `onTick` also ticks on the lobby widget `MM_CoreMissions_C:ReceiveTick`, and the check asked it
  `IsLocalController()` too. A widget has no such function: UE4SS hands back a null object, and calling it logs
  "Tried calling a member function but the UObject instance is nullptr / in method 'IsLocalController'" natively,
  pcall or not (seen once per session at lobby start in a build 18 player report). Now only objects whose class name
  holds "PlayerController" are asked (class looked up once per address, cleared per world with `tick.remote`).
  Tested: title screen, lobby (PLAY pressed from the bridge) and a Spaceport_01 raid, 0 of those errors in UE4SS.log,
  no "co-op: ignoring" line, the director ran (soldier status lines). The widget call failing was confirmed from the
  bridge (pcall false). Not tested: a co-op host with a joiner after this change.

Telling the two instances apart in the log: both append to the same `UE4SS.log`. Raid lines carry the world address
(`navmesh generation started for World ...@<world>/<pc>`); match it against `FindFirstOf("MainPlayerController_C")
:GetWorld():GetAddress()` on each bridge.

**Still open:**
- The client's director still runs its arrival steps: navmesh, HUD, cosmetics, and `loadout: ... checked out of it`
  from the stand-in stash. Both instances use the same stand-in account here, so a joiner with real gear would take it
  out of the host's stash, and its extraction/death would write back to the same save. A joiner needs its own
  stand-in account (or its own stand-in), or the director should skip loadout/extraction when it is not the authority.
- Not played: moving, fighting, looting, extracting on the client; whether the host's bots target the joiner.

### A joiner with its own save (2026-11-19, later; scripts/launch-joiner.ps1)

`powershell -File scripts\launch-joiner.ps1 [-N 2] [-Name Marauder2]` after the host is up, then
`scripts/bsend.sh bridge2 join`. Player N gets:

- **its own stand-in**: `nakama_standin.py --port 7349+N --dir backend\joiners\<N> --name <Name>`. `--dir` moves
  every per-player file (state.json, loadout/cosmetics/checkout, ship files, gifts, coverage, server.log) into that
  folder; a new account there starts from the anonymous `seed.json` (never this PC's private capture) with a new user
  id and the given name. The old default (`backend\`, port 7350) is unchanged.
- **pvenet.dll pointed at it**: env `PVE_STANDIN_PORT` (pvenet.dll rebuilt, `gcc -shared -O2 -s ... -lws2_32`, same
  imports and size as before).
- **the director pointed at it**: `mods/PvEDirector/Scripts/pvebackend.lua` returns env `PVE_BACKEND` or
  `<project>/backend/`; main.lua (loadout, cosmetics, checkout, ship lost/gate), rivals.lua (ship stolen), hire.lua
  (crew save) and guild.lua (your name) use it.
- its own `bridge<N>\` (with the `offline_backend` flag copied in) and `tmp<N>\` as TEMP.

Tested in game (host Spaceport_01 listen, every mod on in both copies): the joiner logged in to its own stand-in on
7351, its raid start took **its own** equipped kit (flak vest, Brodie helmet, MAT-49, ammo) out of its own save, and
it spawned **holding the MAT-49**: the director's `Server_AwsN_EquippedItemsReturned` is a server RPC, so on a client
it asks the host, which equips the joiner. The host's stash was byte-identical before and after (33 items, same
hash), and the host's stand-in logged no request from the joiner. `tools/test_standin_flow.py` and
`test_standin_gaps.py` pass.

Not tested: the joiner extracting or dying (whether loot and losses land in its own save the way they do for the
host), a joiner on another PC (the scripts assume both copies on one machine), N > 2.

## Ship speed: a faster Rustbucket and a boost at the helm (#207, 2026-11-19; shipspeed.lua)
- Measured (Space_Alpha, `pc:Possess(Ship_StarterFrigate01_Pawn_C)` from Lua, W held through keybd_event): the top
  speed is `CharacterMovement.MaxFlySpeed` exactly (1000 cm/s, reached in ~4 s). Class defaults (GetCDO): Rustbucket,
  Scout, Frigate 1000 / MaxAcceleration 256; Fast and VIP 1100 / 512; Red Baron strike frigate 1200 / 512; Capital
  1000 / 512; drop pod 800 / 1024. Rival Rustbuckets are Scout pawns, so `Ship_StarterFrigate01_Pawn_C` is only ever
  the player's ship.
- The pod's boost is native on ARaidSpaceship (`ServerBoost`, BoostLength 4, CooldownBoostLength 12, IsBoosting);
  frigates are ARaidFrigate and have none.
- Base: the Rustbucket gets MaxFlySpeed x1.25 and MaxAcceleration x1.5 while you fly it (shipspeed.lua, every director
  update). Measured after: top speed 1250, MaxAcceleration 384.
- Boost: Space at the helm of any frigate (this UE4SS has no Shift key in `Key`, only `ModifierKey.SHIFT`; Space and X
  did nothing at the helm, checked). 4 s at MaxFlySpeed x1.8, then a 12 s cooldown. Raising MaxFlySpeed alone was
  nearly useless (1250 -> 1440 cm/s over 4 s: the speed builds slowly, not by MaxAcceleration), so the boost also sets
  `CharacterMovement.Velocity` to the new top speed along the direction of travel. Measured: 1250 -> 2204 at once,
  ~2000 at the end of the 4 s, back to 1250 within ~4 s after. A second press during the cooldown does nothing (a
  "recharging" message).
- Testing pitfall: the director's own 0.5 s update puts the speeds back, so hand-written values in a probe are undone.
- Not checked: how it feels with a real pilot (by eye, turning at 2200), docking or breaching right after a boost, the
  `ClientMessage` notices, co-op (a joiner's boost would be undone by the host's movement), crew AI flying.
- 2026-11-24 (#459): the CFG values here are F10 rows now (Rival ships tab: RUSTBUCKET_SPEED/ACCEL, BOOST_SPEED/ACCEL/SECONDS/COOLDOWN, read live by apply()). New Features switch BUSY_START (default 1): rivalcrews.lua uses rivals CFG.BUSY_ARRIVAL {0,15} instead of ARRIVAL_SPREAD, skirmishStep BUSY_SKIRMISH_FIRST {5,15} instead of SKIRMISH_FIRST, and R.busyStep calls R.provoke() (the F9 "Send a rival crew at me" path) once after BUSY_HUNT_AFTER 15 s of flying your ship. luacheck only: NOT tested in game.
## J and K in a raid (#209, 2026-11-19; invqol.lua raidHotkey)
- The stash hotkeys returned at once outside the lobby (no stash bar, no stash panel), so in a raid they did nothing.
- Found by probing a looted bag (Spaceport_01, `inv:Server_StartLooting(LootableCon_BagPlastic01_C)` opens the real
  loot screen): the looted container is an `InventoryContainerWidget` with ContainerID `LootCon`, SlotMasterType 3
  (Loot; a body's pockets are 4, LootEquipment); your pockets are type 0. **Every container widget exists twice** in a
  raid: the `SIGIS_HUDOverlay_C` copy has a hidden parent, the "In Game Overlay Match" copy is the one on screen; only
  a widget whose whole GetParent chain is visible counts.
- Calls (CXXHeaderDump SIGISPlugin.hpp, the `sdk` bridge verb writes it to the game's Win64/CXXHeaderDump):
  your item to the container: `Server_MoveItem(guid, "LootCon", {Column, Row}, 3, 0, rot)` (worked);
  `Server_CtrlClickItem(guid, "LootCon"|"", 0)` from your side does nothing; the container's item to you:
  `Server_CtrlClickItem(guid, "", 3)` (the game picks the spot; the item gets a new guid); drop:
  `Server_DropInHud(guid)` (a SIGIS_ExamplePickUP_C appears ~1 m away).
- Tested in game with the real mouse hover and key presses: K on a pocket item put it in the bag, K on the bag's item
  took it, J on a pocket item dropped it (pickup 100 cm away, log "raid: dropped Fabric"), J on the bag's item left it.
  A synthetic cursor jump can leave the game's hover on the previous item for a moment (one K moved the wrong item that
  way); a real mouse doesn't jump. The `ClientMessage` notices don't show over the inventory screen.
- Not tested: a body's pockets (type 4), a full container ("No room"), K with nothing being looted, bags and rig.
- Side find: Spaceport_01 has 33 `UA_Mine_Spawner_C` (station mines; #197).
## Crew all wore the Baron Cap (#195, 2026-11-19; gear.lua helmetFor, hire.lua)
- Report (Discord): recruits like "Rosco, Lv 3, Trench Shotgun / Baron Cap / Medic Bag", over and over; boss gear on
  recruits with starter guns.
- Cause: `Gear.helmetFor` swapped a helmet that didn't fit the recruit's face for **the single fitting helmet nearest
  in price**. BaronCap (3250) is mid-priced and fits every face in headfit.lua, so for bulky faces (UA masks, Hunter,
  Steel Worker) it was the answer to almost every mid-grade helmet. Simulation (lupa, every mid-band helmet 1500-4500 x
  every face): BaronCap was 14.5 % of crew helmets, 19.5 % of the swaps.
- Fix: helmetFor picks at random among the 4 fitting helmets nearest in price and never offers `G.SIGNATURE` pieces
  (BaronCap, WardenRiotHelmet); with `plain` (hire.lua) a rolled boss piece is swapped too. hire.lua's load swaps a boss
  cap already on a recruit or hired crewmate. Same simulation after: BaronCap 0 %, every result fits the face.
- Rivals don't use helmetFor (rivalbodies.lua picks a face to fit the helmet), so a rival can still wear one (1 of 31).
- Verified in game: a BaronCap planted on a pool recruit (Rosco, Hunter_Head_Artic) came back as BAHeavyHelmet in
  crew.lua after the mod loaded. Not looked at by eye in the lobby or in a raid.
### Direct host and join from the launcher (2026-11-19, evening; launch.lua, launcher CO-OP, #201)

Decision (#201): direct host/join first; the game's own lobby and party flow later, if ever.

- Launcher: **CO-OP** button in the saves header (the settings column is full at 150 %, #147) opens a dialog: "Host:
  friends can join my raids" writes `config/coop_host.txt` (on/off); it lists this PC's IPv4 addresses
  (`socket.getaddrinfo(gethostname())`, LAN and virtual adapters); "Join a friend's raid" + JOIN writes the one-shot
  `config/coop_join.txt` (and `coop_last.txt` to refill the box) and starts the selected save like PLAY. A plain PLAY
  deletes a leftover join file.
- Director, launch.lua: `launchMatch` adds `?listen` to the raid URL when hosting (log "co-op: hosting this raid").
  `M.update` at the main menu: with `coop_join.txt` present for 4 s, deletes it and runs `open <addr>[:7777]?PID=
  offline-<random>?PNAME=<base64 of the stand-in's display_name>?CREW=coop-<random>...` (log "co-op: joining").
  Deleted before connecting, so a failed join or the return from the raid doesn't loop.
- Tested in game (one PC, two copies, host on a throwaway save): host clicked PLAY on the splash, closed the Guide,
  START RAID -> "co-op: hosting this raid", Space_Alpha, UDP 0.0.0.0:7777 owned by the game. Joiner started with
  `coop_join.txt` = `127.0.0.1`: "co-op: joining 127.0.0.1:7777 as Marauder2" on its splash screen, file gone, the host
  sees a remote controller at once; the joiner's pawn came ~50 s later, **aboard its own ship** about 330 m from the
  host's, veil "YOU'RE ABOARD", ping 14 ms, gate countdown on its HUD. Launcher: `test_ui.py` covers the dialog (opens
  centred with the grab), the Host box, JOIN writing the file and starting with the address, PLAY clearing a leftover.
- Not tested: the launcher's JOIN button with a real game start (the file it writes was used by hand), a second PC or
  a virtual LAN, the Windows firewall prompt on the host, a join while the host is still in its lobby (it should fail
  back to the joiner's menu), whether the two players should share one crew (each gets its own: CREW=coop-<random>),
  playing the space raid together.
- Both copies of the game on one PC read the same `config/`: start the host's raid before writing a join file, or the
  host joins itself from its menu.
### A joiner's raid ends in its own save; the gate hooks were the host's (2026-11-19, evening; loadout.lua, #200)

Setup: host on a throwaway save (stand-in started first with `--dir backend\joiners\1 --name HostTest`, env
`PVE_BACKEND` pointing there, then `launch-offline.ps1`; `Start-Standin` sees the port taken and leaves it), raid
`Spaceport_01?listen`; joiner `launch-joiner.ps1 -N 2`, `bsend.sh bridge2 join`. Every mod on in both.

- **Extraction, joiner (works):** the host called the joiner's `SIGISInventoryComponent:Client_GetOutWithLoot()` (the
  server-to-client RPC the game sends when a player gets out). The joiner's director logged "extracted with 4 item(s)",
  went to its menu, and its own stand-in wrote the 4 kit items back plus XP. The host stayed in its raid; its backend
  got no request. A client RPC called on the host for a remote controller does **not** run the host's Lua hook.
- **Death, joiner (works):** `GameplayStatics:ApplyDamage(joinerPawn, 5000)` on the host: the game's own death flow
  sent the joiner to its menu, its stand-in logged "ship lost", the kit stayed out of its stash (lost). Host unaffected.
- **Bug, fixed:** `Server_EnterEvacRaidVolume` is a server RPC, so a joiner entering a space gate runs it **on the
  host**, and the host's hook wrote `ship_gate.txt` = 1 into the **host's** backend: the host's `raid_out.ended` became
  true (state.json rewritten one second after the joiner's call). A host who then quit or crashed lost their kit
  instead of getting it back (#49); seen happen to the test host after a restart ("raid start: took []").
  Fix: the gate hooks (`Server_EnterEvacRaidVolume`, `LeaveEvacRaidVolume`) act only when `ctx:get():IsLocalController()`
  isn't false. A joiner's client never executes the server RPC, so `EnterEvacRaidVolume` (which clients run, and the
  host runs too thanks to pvepatch "Space gate extraction") is hooked as well, same filter.
- Verified after the fix (relaunch of both): joiner's `Server_EnterEvacRaidVolume` -> host state.json untouched,
  `ended` stays false; the host's own `Server_EnterEvacRaidVolume` -> host `ended` true as before.
- Lua-initiated calls of a native UFunction did not visibly fire its native hook in one test (the host calling
  `LeaveEvacRaidVolume` on the joiner's controller left no trace); the RPC that arrived over the network did.
- **Not verified:** the joiner flying or walking into a real gate (so the `EnterEvacRaidVolume` hook on the joiner is
  unexercised), a joiner's own ship (one ship, two players is undefined), the host's bots fighting the joiner, the
  joiner looting, two PCs.

### A joiner aboard the host's ship (#214, 2026-11-19; launch.lua joinPending, veilUntilAboard)
- The host's ship interior (`RaidSpaceshipInside`, FrigateInside_Starter_C) carries `ShipCrew` = the host's `CREW`
  option (`solo1`); `RaidPlayerController.Crew` is empty offline. Joining with `CREW=solo1?CPT=0` (the host's crew, not
  its captain) puts the joiner **aboard the host's ship**: spawned 8-9 m from the host, one player interior, one
  Rustbucket. With its own crew id (the #201 join) the host's game made the joiner a ship of its own 330 m away.
- launch.lua's join now sends the crew from RAID_OPTS (the same in every install) and CPT=0.
- The joiner's loading veil waited for `world.AuthorityGameMode`, which only the host has, so it timed out ("aboard
  after 90s (gave up waiting)") and ran the client at 20x time dilation meanwhile. Now a joiner (no game mode) is ready
  once its pawn exists and the level has streamed, and never touches time dilation. Tested: "aboard after 13s"; the
  joiner's screen shows the ship interior and the gate countdown.
- Seen, not looked into: the joiner's minimap panel draws as an empty dark box.
- Not tested: both players flying / manning turrets, docking and breaching together, extracting through the gate
  together (which save gets the ship), the host's hired crew with a second player aboard, rivals treating the joiner as
  the ship's crew.

## Space gate time (2026-11-18; raidtime.lua, docs/internals/SPACE_GATE.md)
- Request (Discord, ChurchOfHusk_Enjoyer): choose when the space gate arrives (instant, 5, 10, 15 minutes), because the custom
  raid length also moved the gate's countdown. Launcher: "Space gate" slider under "Raid length" (default, instant, 5, 10, 15),
  config/gate_time.txt (default, instant, or minutes up to 240).
- Cause: the real gate comes TimeTillEvacSpawn (300 s) into the raid whatever the raid's length, but the HUD's "Spacegate
  arrives in" counts to the last 20 minutes of the raid (fixed 20), so a 60 minute raid said about 40 minutes and the gate came
  at 5. The two agree only in the stock 25 minute raid.
- Fix: raidtime.lua writes gm.TimeTillEvacSpawn in the warmup (a write in the raid does nothing; measured), and M.frame writes
  the countdown text every frame as TimeTillEvacSpawn minus the time gone, on the two live text blocks named
  Txt_SpacegateTimeArriveIn (the third, under /SIGISPlugin/, is the unused template). The HUD rewrites its text about once a
  second and its functions never reach a Lua hook, so a per frame write is the way. Found once, never searched for again.
- Verified (Space raid, length 60, gate 10): log "space gate: set to arrive 600 s"; EvacSpawned false at 585 s, true at 600 s;
  countdown read 06:23 at 229 s, 00:09 at 591 s, no flicker (live test from a probe).
- Not verified: the countdown as the mod's own code from launch (the first launch with it is the next test), instant, 15
  minutes, a raid shorter than the gate time, no limit raids, the launcher slider on screen (no Tk on the test machine).
- A game crash happened while live tests of the text scan were running; the log shows no error and the cause is not proven.

## Minefield raid condition (2026-11-19, no issue)
- `mines = N` in a raid condition (conditions.lua M.mines) has minefield.lua copy each space mine the map placed
  (RaidSubNodeActor classes with `NodeMine` in the name: Small_NodeMine_C, Nuclear_NodeMine_C) N - 1 times, scattered
  up to 90 m around it (at least 15 m away), with `world:SpawnActor(mine:GetClass(), at, rot)`. Once per world, 8 s
  into the space map, looking for up to 90 s; at most 400 copies. Shipped condition: [Minefield], mines = 20, loot 1.25.
- Verified: Space_Alpha, twice: "14 mines on the map, 266 more spawned", then "20 mines, 380 more" (the cap).
- Not verified: the copies seen, triggered or exploding in play. Another tool was driving the same game install during
  the test (opening Spaceport_01 on every bridge load and restarting the game), so whether the game stays up with 400
  extra mines is unknown. Test this first: a raid with Minefield picked, fly around a field for a few minutes.

## Crash after a turret dies in space (#191, 2026-11-20; rivals.lua nodeTurrets / nodeTurretAlive)
- Report: Space_Charlie, AV reading 0xffffffffffffffff, PCallStackHash 99326A2899B85B5ACD9EAF8A543913AFA3D2CCC2, 1 s
  after a moving flak turret died with "[crew] gunner's ordered target out of play: turret" just before. Same UE4SS
  frames as the dead-bot crash (+0x4bddae <- +0x380bb0 <- +0x37f6fe <- +0x87b9d0: Lua reading a property of a FREED
  UObject, from onTick).
- Cause: the gunner's list of stationary turrets (S.nodeTurrets) is built once and refreshed only on a click after
  60 s, so destroyed turrets stayed in it. nodeTurretAlive read `t.bIsDying` before `valid(t)`. A destroyed turret is
  harmless to read until the next GC frees it; then hostileShips (the gunner's look round, run at once after an order
  goes out of play) read freed memory. The first moving flak that died earlier in that raid was the one read.
- Note: right after K2_DestroyActor, pve_alive already says 0 while IsValid still says true; a CollectGarbage straight
  away doesn't free it (FindAllOf still lists it); a second GC a few seconds later does.
- Fix: valid(t) before any property in nodeTurretAlive; nodeTurrets drops invalid entries on every call; crew.lua
  clears S.gunTarget with the order when the ordered target goes out of play.
- Verified on Space_Beta from bridge/dir_eval.lua: cache the list (pickShip), K2_DestroyActor a Flak_NodeTurret_C, GC,
  wait, GC again (the flak count drops: freed), then R.hostileShips(). Old code: crashed with the reported hash
  99326A2899B85B5ACD9EAF8A543913AFA3D2CCC2. New code: 3 rounds of hostileShips + pickShip, no crash.
- Not verified: the reported path itself (a crew gunner ordered onto a moving flak turret on Space_Charlie).

## Minimap: the space gate task (#223, 2026-11-20; minimap.lua stage, gateIn)
- Found in #42's log (Space_Delta, 19 Nov): `minimap.lua:469: attempt to index a nil value (local 'place')`, 488 times.
  Following "Leave through a space gate" once a gate exists, on foot in your ship and not docked: the gate target has no
  place, so `docked == place` was nil == nil and the line read place.name. Now `place and docked == place`; on foot it
  says "Go to the helm and press F to fly".
- The minimap's gate countdown was `RemainingTime - 1200` (the stock HUD's rule), which only holds in a 25 minute raid
  with the stock gate; it also doesn't look for gates until that reaches 0. With config/gate_time.txt "instant" the gate
  was there 1 s in (EvacSpawned true, TimeTillEvacSpawn 1.0, 2 EscapeZoneSpaceGate_C) while the minimap counted down
  4 minutes and pointed nowhere. Now gateIn() uses the game mode as raidtime.lua does (EvacSpawned -> 0, warmup ->
  TimeTillEvacSpawn, else TimeTillEvacSpawn - (RoundTime - RemainingTime)), rounded up to whole seconds (the text
  formats it with %d); a joiner (no AuthorityGameMode) keeps the stock rule.
- Verified on Space_Beta, gate and task picked through config/gate_time.txt and bridge/minimap_cmd "next":
  - on foot in your ship with the gate there: "Go to the helm and press F to fly", 0 errors;
  - "instant": the minimap followed the gate about a minute in, with the HUD on "SPACE GATE HAS ARRIVED" (before: "Gate
    arrives in 3:50" counting down);
  - 10 minutes: the minimap read 8:43 when the HUD read 08:44.
- Not verified: the piloting text toward the gate with a custom time, a joiner's minimap.
## Crew update failed on a hurt crewmate (#224, 2026-11-20; crew.lua, rivals.lua)
- #42's log: `[crew] update failed: crew.lua:208: bad argument #5 to 'format' (number has no integer representation)`.
  The "is with you" line formatted m.hp with %d, and m.hp is copied from the bot's live Health (a float), so a hurt
  crewmate following you into a new place threw there and cut that crew update short. Rivals' "is in" line had the same
  %d hp. Both are %.0f now. Lua's %d refuses any float with a fraction: keep it for counts, never for game floats.
- Verified with lupa: the old format string with 212.4 throws that exact error; the new one prints "212 hp". Not run in
  game (the test save has no crew).

## The lobby flashed on every gear change (#233, 2026-11-20; lobbylabel.lua gearTick)
- Report (The Wang, Discord, with a clip): on LOADOUT the menu's panels blinked out and faded back in, sometimes, while
  moving items; after equipping something bought, not on the trader drag. Cause: the mod's own #29 fix. While LOADOUT
  is selected, a change in the equipped set "presses" LOADOUT again (SIGIS_MainOverlay_C:CoreMM_Tab_Pressed(1)) to
  redress the lobby character, and that press starts SIGIS_InventoryWidget_C's Anim_SwitchGearAppear (0.5 s) and
  Anim_RefreshOpenState (0.35 s), which hide the page's panels and fade them in, and the menu camera's switch, which
  fades the 3D backdrop up from dark. Pocket moves and moves into stash boxes don't change the equipped set (pockets are
  excluded, box contents have a GUID container), so it looked intermittent.
- Fix: right after the press, both animations get SetAnimationCurrentTime(anim, GetEndTime()) and the controller's
  PlayerCameraManager:StopCameraFade(), in the same frame. The press (the redress) itself is unchanged.
- Measured with bursts of window captures (PrintWindow ~ every 60 ms) and pixel sums over the panels and the backdrop:
  the press alone took the panels from ~1240 to 171 for 2-3 frames and the backdrop from its 504-1149 range (moving
  smoke) to 178-249; with the fix, a real gear change (Server_MoveItem into and out of "Sec") logged "2 page
  animation(s) skipped, camera fade stopped", panels min 1222, backdrop min 513.
- Learned on the way: UE4SS hooks on SIGIS_MasterMenu_C's Blueprint functions (SwitchToWidget, SwitchToInventory) never
  fire for Blueprint-to-Blueprint calls; IsAnimationPlaying from a tick hook didn't catch these animations either, but
  reading it straight after the press does. Synthetic drags (SetCursorPos + mouse_event) don't move items in the menu;
  Server_MoveItem from bridge/dir_eval.lua does, like a drag.
- Also verified: the helmet off the head (into the empty secondary slot) and back: the character lost it and got it
  back, each with the redress line, panels min 1223 / 1224, backdrop min 495 / 522.
- Not verified: the reporter's exact case by hand (a drag after buying from a trader).

## Hidden outfits: rows 57-60 (#229, 2026-11-20; outfits.lua, debugmenu.lua, stand-in FREE_COSMETICS)
- DT_PlayerAppearance rows 57-60 ("Pirate"/"Mod", cost 1) were left out of "unlock all" as dev placeholders. They're
  real: worn through cosequipped they're two outfits, 57 body + 58 head a long brown coat with a brass mask, 59 + 60 the
  same coat in black with a dark goggled mask (meshes Dev_Pirate_Body_Skel_01 / Dev_Pirate_Head_Skel_01 for 59/60, read
  off your pawn in a raid). Owned (UnlockedCustomisations had them), the Appearance pages still don't list them: they
  aren't in the menu's lists, so unlocking alone can't offer them. Rows 73-83 and 91 don't exist.
- Wearing them: SIGISPlayerController:SetPlayerCosBody(FName) / SetPlayerCosHead(FName) (one NameProperty each, read
  from the UFunction's ChildProperties at +0x50 with tools/offline-audit/kdis.py's reader: UE4SS ForEachProperty fails on
  functions). They PUT cosequipped like an Appearance click, but the lobby character only changes at the next page
  switch, so the selected tab is pressed again (CoreMM_Tab_Pressed with its Which_CoreMenuState).
- F9 in the lobby: "Hidden outfit: wear the brown/black coat" cycles the two. The stand-in owns 57-60 for every account
  (FREE_COSMETICS). Picking any listed look in Appearance changes back.
- The F9 menu was one column of 17 buttons (~1100 px): past the bottom of a 900 or 1080 px window, the last ones
  (ammo picker, this button) couldn't be reached. Over 10 buttons it now uses two columns; help lines over ~58
  characters ran into the second column and were shortened.
- Verified: real F9 clicks in the lobby (1600x900 window) put on each outfit, PUT cosequipped body and head, and showed
  it at once; a Spaceport_01 raid after that wore 59/60 (cosmetics.json -> applyLoadout).
- Not verified: the brown coat in a raid (only the black one was loaded), a woman's body with these rows, the crew
  stands in the lobby wearing them (they're dressed from a donor).

## Defusing station mines (#197 part 1, 2026-11-20; defuse.lua)
- The Raid maps' UA_Mine_Spawner_C (00_UA_ObjectSpawner_Base: ItemToSpawn MineStaticActor_C, 0to1_ChanceForBlockerToSpawn
  0.15; Spaceport_01 has 33, so 3-5 mines a raid) place MineStaticActor_C: mesh Wpn_APmine_Pickup, a 30 cm Sphere
  trigger. Bytecode (kdis, ExecuteUbergraph_MineStaticActor): on overlap, with authority and Active, Active = false, the
  APmine_Triggered_Cue, lights off, 0.25 s, then the Explosion particles, APmine_explosion_large_07 and
  ApplyRadialDamageWithFalloff(60, 30, r 200-500), mesh hidden, collision off. MultiExpo() runs the same path. Both
  trigger paths check Active first: Active = false disarms it. They go off offline as they did live (we're the authority).
- defuse.lua: on foot within REACH (170 cm) of an armed mine, a prompt (bottom middle); with a ToolKit carried (row
  ToolKit in any container but Stash/Lobby/Shop/LootCon...), F opens a Minesweeper board (6 x 6, 6 charges, 75 s; the
  charges are laid on the first reveal, never under it or next to it). Win: Active false, lights off, the actor
  destroyed, AP_Mine x1 and Gunpowder x2 into free pocket cells (Server_AwsN_EquippedItemsReturned, like the F9 ammo
  button). Lose (a charge, or time): the board closes and mine:MultiExpo() sets it off. The ToolKit is kept either way.
  "Back away" closes the board, the mine stays armed. Built and polled like the F9 menu; flags through a Flag mode
  button. F is bound with RegisterKeyBind and only acts while the prompt is up (the game's own F carries on).
- Mines are found by FindAllOf every SCAN_EVERY (20 s) while on foot in a raid.
- UMG from Lua: CanvasPanelSlot:SetAnchors with a table didn't take (the prompt sat in the top-left corner); positions
  are worked out from WidgetLayoutLibrary GetViewportSize / GetViewportScale instead.
- Verified on Spaceport_01 (god mode on, real key presses and clicks, the layout read through Defuse.peek from
  bridge/dir_eval.lua to click every safe cell): the prompt without and with a ToolKit; F without one does nothing; a
  cleared board defused the mine (3 -> 2 mines, AP_Mine and Gunpowder x2 in the right pocket, ToolKit kept); hitting
  a charge set the mine off (blast, shrapnel, mine hidden and inactive); Back away left it armed; flag mode flags.
- Not verified: the damage on a loss without god mode (it's the mine's own, unchanged); a full pocket set; mines in
  station interiors on space maps (the same actor; the scan runs there too); a joiner (co-op).
- Still to do for #197: space mines (Small_NodeMine_C in place, Nuclear_NodeMine_C towed to the hold), from the ship.

## Items stacked on top of each other in saves (#239, #240, 2026-11-20; nakama_standin.py repair_inventory)
- Reports (build 10): items moved into gear or the stash vanish or freeze and can't be moved, even after a relaunch
  (#239); in a raid, discarding a helmet dropped it but it stayed equipped, and each discard dropped another (#240).
- Both reporters' saves had items on top of each other. #240: three helmets with MotherItemGUID "Head" (a BAHelmet and
  two RedStahlhelms); the game shows one per slot (`SIGIS_DefaultEquipmentSlotWidget_C` Head had 4 canvas children:
  three item widgets stacked), so discard dropped the top one and the next showed in its place. #239: a KlobbDrumMag at
  the same cell as an M45CarlSMG and a FAL over the M45's lower half (footprints from assets/saves/items.json; the
  game had let new items land on the M45's cells, as if it wasn't there). Every other save here: no overlaps.
- Item string fields: guid-Row-stack-durability-**column-row**-rotated-mother[-attachments]; column 0-9 in the stash,
  rotated swaps items.json's w and h. The item object's position is `ItemInSlot` (Column, Row), and `bRotated`.
- Fix: the stand-in repairs a save at startup. A one-item equipment slot holding more than one keeps the newest
  (update_time; the one the game showed) and moves the rest to free stash space; stash items whose footprint overlaps
  an older one's move too (rotated if that's what fits; rows from config/stash_rows.txt, else 15). The save is copied to
  state.before-repair.json first and the moves are logged ("inventory repair: ..."). Item too big for any free spot:
  left where it is, logged.
- Verified in game with a copy of the #240 save (20 stash rows): before, Head showed one Stahlhelm with two hidden
  helmets under it; after the repair, Head held one, the BAHelmet and the other Stahlhelm lay in the stash, the stash
  grid's slot widgets matched every stash item's ItemInSlot, and in a raid the game's own Discard emptied Head with one
  pickup on the floor. The #239 save (25 rows) offline: the drum mag and the FAL moved, a second pass finds nothing.
- **Not found: how the items got on top of each other.** Ruled out on a clean save: the game's Discard on an equipped
  vest and Server_DropInHud on an equipped helmet (both leave the slot), Server_SwapItem stash helmet <-> equipped
  helmet, Server_MoveItem into an equipment slot, and the #29/#233 LOADOUT press (it doesn't rebuild the item widgets:
  same 53 widget objects before and after). The #240 save's second Stahlhelm came back from a raid already in Head
  next to the BAHelmet, so it may start in a raid (dropping a picked-up helmet on a filled slot?). Synthetic drags still
  don't move items (SetCursorPos or absolute mouse_event, even with virtual-desktop coordinates), so a real drag couldn't
  be tried. Server_SwapItem(GUIDFrom, GUIDTo, MovetypeTo, MovetypeFrom, RequiresMove) and Client_SwapItem(..., MovedToSlot)
  read from the UFunctions' property chains.

## Space mines defused from the helm (#197 part 2, 2026-11-20; defuse.lua)
- Small_NodeMine_C is a SubNodeActorMine_C (RaidSubNodeActor): `Active?` (the name has the question mark), a trigger
  `Box` (extent 79 cm: a ship has to touch it), `DelayBeforeExplodes` 1 s, Base Damage 500, Damage Radius_Inner 400,
  Damage Radius_Maximum 1500 (nuclear: 1000 / 1000 / 2500, box 79 x 79 x 100). Space_Alpha had 14 small, 18 nuclear.
- Its event graph (kdis on ExecuteUbergraph_SubNodeActorMine): **entry 15 is the explosion**: ApplyRadialDamageWithFalloff
  from its place, the client-only blast/sound (skipped offline, spacefx.lua makes them), StaticMesh hidden,
  K2_DestroyActor. The Box overlap with a RaidSpaceship/RaidFrigate plays Sound_Triggered, TriggeredEffects and a Delay
  that re-enters at 15. `TriggeredEffects()` alone only sets Active? false and plays the warning; ApplyDamage and
  ApplyRadialDamage on the mine do nothing.
- A ship's hull is `MainHullHealth` (575 on the starter frigate); its `Health` stays 575 whatever happens. Plain
  ApplyDamage on the ship doesn't touch the hull; the mine's radial damage does.
- At the helm the controller's pawn is the ship (Ship_StarterFrigate01_Pawn_C) with `MyShipInside` set. For tests,
  `pc:Possess(home.SpaceshipToPairTo)` puts you at the helm (F by teleport didn't take, nor ServerInteractComp on
  FrigateHelm), and `pc:Possess(foot)` back.
- Fix/feature: at the helm within SPACE_REACH (30 m) of an armed small mine, the prompt "R   Defuse the mine" (R is the
  ship's salvage key; it only opens the board while the prompt is up). The same Minesweeper board. Win: Active? false,
  lights off, the mine destroyed with its mesh shown (so spacefx makes no blast); Fuse, Gunpowder x3, Chemicals into
  your pockets. Lose: Damage Radius_Maximum stretched to your ship + 5 m and entry 15 (blast, sound, the hull damage).
  Leaving the helm (or falling) with the board open now closes it and gives input back (it used to just forget it).
- **Two bugs in the build 10 station version, fixed here:** (1) the ToolKit check compared `ItemData:ToString()` with
  "ToolKit", but an FName keeps the case it was first made with in the session: in one session the row read "Toolkit"
  and the prompt said you needed a ToolKit you had. Now compared without case; itemdata.lua `get` falls back to a
  lowercase index for the same reason. (2) loot went into "free" pocket cells found from each item's top-left cell
  only, all as 1 x 1: the 2-cell AP_Mine could land on another item (stacked items break the inventory, #239). Now
  every item's real footprint (items.json size, rotation) is mapped and loot only goes where it fits.
- `bRotated` reads as a number (0) from Lua, and 0 is true to Lua: test it with `== true or == 1`.
- Verified in game (real R, F and clicks; Space_Alpha, at the helm by Possess): prompt with and without a ToolKit; a won
  board (loot Fuse at PocketLeft 0,0, Gunpowder 0,1, Chemicals 1,1 beside a ToolKit in PocketRight; no blast); a lost
  board (blast and sound, hull 575 -> 75); leaving the helm with the board open (board gone, cursor off). Spaceport_01
  station mine again after the changes: won, AP_Mine into PocketLeft's free bottom row, Gunpowder into PocketRight 1,0.
- Not verified: taking the helm by a real F (tests used Possess); a ship bigger than the starter; nuclear mines (not
  done: towing to the hold is still open in #197); co-op.

## The mod's own pocket items landed on top of each other (#239, 2026-11-20; pockets.lua, loadout.lua, debuggive.lua)
- Found while looking for what stacks items (#239): `loadout.lua giveAmmo` (ammo for the soldier's gun you get when you
  enter a raid with no gun) put its stacks into PocketLeft's four cells (0,0 1,0 0,1 1,1) whatever was there, as 1 x 1.
  But **7.62, .30-06, 5.56, 7.62x54R, flame fuel and darts are 2 x 1** (items.json), so a 7.62 gun's ammo lay two-deep
  on itself: seen live this round as `762Ammo@PocketLeft 0,0; 762Ammo@PocketLeft 1,0`. Anything already in the left
  pocket got covered too. Extraction saves it as it is. The F9 ammo button and defuse.lua's loot had the same flaw
  (free cells from each item's top-left cell only, everything treated as 1 x 1).
- Fix: pockets.lua maps every cell each item covers (items.json sizes, `bRotated` compared with 1: it reads as a number
  and 0 is true to Lua) and finds a spot an item fits, rotated if need be. giveAmmo, the F9 ammo button and the defuse
  loot all use it; giveAmmo stops (and logs "no room for the rest") when the pockets are full.
- The stand-in's startup repair (#240 section) now also checks PocketLeft and PocketRight (2 x 2) for overlapping items
  and moves the newer ones to free stash space. Dry run: a copy of a save with two 7.62 stacks at 0,0 and 1,0 got the
  second moved; every healthy local save, unchanged.
- Verified in game (Spaceport_01, no gun, a 2 x 1 Fuse put in PocketLeft 0,0 through the save): "put 2 stacks of 762Ammo
  in free pocket cells", at PocketLeft 0,1 and PocketRight 0,0, the Fuse untouched.
- Still not found for #239: how the Head slot (#240's three helmets) and the stash cells got doubled. Picking up a
  dropped helmet while wearing one was the lead, but neither a synthetic F (prompt "F Light Stahlhelm" up) nor
  `pawn:ServerInteract(pickup)` picked anything up from the bridge, so it couldn't be tried.

## Rebel Base's terrain and stray pieces floating in space (#9, 2026-11-20; interiors.lua collect)
- Seen on Space_Alpha: thin lit girders hanging in space, and from Rebel Base's east side a big flat slab of beige
  ground in the sky (the #9 screenshot of 16 Nov looks like the girders).
- Found with a probe that casts a ray through a screen pixel (DeprojectScreenPositionToWorld; out-params need
  pre-filled tables) and lists every recently rendered mesh whose bounds it crosses:
  - the girders: SM_RebelBase_Map_Ceiling_01, SM_Penal_Bridge_01, SM_RebelBase_Supports_01/02, RebelBase_Launch_Pipe
    of level Rebel_Base_01, never culled (CachedMaxDrawDistance 0), 1.1-1.5 km off. 202 of Rebel_Base_01's 25878 meshes
    lie outside its LevelStreamingVolume box + MARGIN: ceilings 44-60 m above it, bridges out to 220 m past its sides,
    a few shack walls ~1 km away. interiors.lua matched far-drawn meshes to a volume by the 3D box only, so these were
    never hidden.
  - the slab: Rebel Base's Landscape (Landscape_Main, Landscape2: 128 LandscapeComponents), which interiors.lua never
    collected (StaticMeshComponents only).
- Fix: in collect, each foreign level's in-box meshes vote for their volume; a far-drawn mesh of that level outside
  every box, and every LandscapeComponent of that level, joins the winning volume's parts (hidden from outside, shown
  when the camera is in, like the rest). Log: "... hidden from space (201 of them outside their volume, 128 terrain
  pieces) ...". Verified on Space_Alpha: all 202 outside meshes hidden; from 300 m east of the old slab spot, empty
  sky; with the camera inside Rebel Base's volume the 128 terrain pieces are visible again, outside hidden.
- Probe hazard (again): `owner:GetLevel()` inside a pcall on a component whose owner was null crashed the game
  (PCallStackHash 99326A2899B85B5ACD9EAF8A543913AFA3D2CCC2, AV reading 0x18, all UE4SS frames: the generic "method
  on a null wrapper" crash, same hash as #191). Read the level from GetFullName instead.
- Not checked: other maps' interiors with terrain (the code is generic), walking into Rebel Base through an airlock.

## Inventory grids keep stale cells (#249, 2026-11-20; invsync.lua, pockets.lua, stand-in repair)
- Report (Discord, build .12, report zip): moving items sometimes leaves their old cells "occupied"; moving more can
  duplicate or lose items. The raid (Space_Alpha, Rebel Base) ended by Quit Game; the save was clean (no overlaps, the
  #241 repair had nothing to do); the mod's own inventory actions don't appear in that raid's log.
- How a grid works: an InventoryContainerWidget's InventorySlots are InventoryGridSlotWidgets (SIGIS_DefaultSlotWidget_C)
  with `Item` (the item covering the cell), `WasRotatedOnPlace`, SetItem/GetItem. A cell whose Item points at an item
  that isn't in that container any more, or at a freed one, counts as taken.
- Measured: the drag's call, Server_MoveItem(guid, toCon, {Column,Row}, 0, from, rot), pocket -> bag and loot box (from
  Loot 3) -> bag both left the grids right (a cross-container move makes a new item object under the same guid). But the
  game does leave stale cells: 7 stash cells pointing at freed items in a freshly loaded lobby (every real stash item
  still fully covered: 51 items, 143 cells, matching items.json sizes), and at raid start the pocket grid still pointing
  at the last loadout's items. Server_ValidateEquippedInventory (no params; the server sends the list back through
  Client_ValidateEquippedInventory(ItemsToAdd)) left a stale cell stale. Client_ValidateInvCon(ToCon, ItemsToAdd) and
  Client_ValidateStashInventory(ItemsToAdd) exist too (params read from the UFunctions' property chains).
- Fix: invsync.lua, once a second, for each shown (whole parent chain visible) grid of your own containers (pockets,
  Stash, and any grid whose ContainerID is an item id in your inventory: bags, rigs, boxes; loot/shop/gift are left
  alone), clears cells whose Item is freed or whose MotherItemGUID isn't this container. Cells are never filled in.
  Widget and inventory paths are found once per world (FindAllOf) and resolved with StaticFindObject after that.
  **An empty cell reads as a wrapper around a null pointer, which Lua counts as true:** check GetAddress() ~= 0 (the
  first version "cleared" every empty cell every second).
- Rig grids: each rig sub-grid's ContainerID is the rig's item id, the same as its items' MotherItemGUID (their columns
  encode the sub-slot: 0/10/20), so the container check works for them as is.
- Verified in game: lobby and 15 s of raid with the inventory open, no clears; an item moved into a bag with its two
  old pocket cells pointed back at it: "inventory: 2 stale cell(s) in PocketLeft cleared (they still pointed at
  762Ammo)" within a second, grids matching the inventory after.
- PocketRight: InventoryGridSize 1 x 2 but its grid is never built (0 slots in every copy) and the game shows only the
  left pocket: anything there is invisible and stuck. No player save had anything there; the mod's pockets.lua (and the
  F9 ammo button, defuse loot, soldier's-gun ammo) used it as overflow in builds 10-14, and the test save had a 32Ammo
  in it. pockets.lua now uses PocketLeft only; the stand-in repair moves anything in PocketRight to the stash (log
  "... on top of others or out of sight moved: ...").
- Not reproduced: the real drag that leaves a stale cell (synthetic drags don't move items). Not verified: invsync on a
  stale cell the game made by itself in a raid (only the lobby's, and hand-made ones).
- 2026-11-24 (#369, freezes after looting): Walmarx's report (build 28) has the director's worst frame jump from ~15 to
  ~175 ms about once a second right after dragging a Light Backpack on, with no timed section accounting for it.
  invsync ran in a plain pcall (untimed) once a second; shown() can't tell a closed inventory (a grid's parent chain
  ends at its own widget's root, and an off-screen copy stays flagged visible, the trap invkeys.lua already notes), so
  after a swap it likely walked the whole inventory every second all raid. Now: skipped unless the controller's
  bShowMouseCursor is on (a menu open), and timed as section "invsync" in the frames line. Cause inferred from the log,
  NOT reproduced; next report's frames line will show invsync's share.

## Places you board with a pod had no guards handling (#187, #42; 2026-11-20; rivals.lua pointsOfInterest)
- A station (S.stations) needs a named interior AND docking nodes under its name, or an AI frigate. The Capital Ship on
  Space_Beta (Capital_Ai_Interior_2, boarded with a pod) has neither, so standing in it R.where() was nil: no garrison,
  no adoption of the NPCs the level spawns there (their GOAP brains don't run offline: idle, or stuck where they spawned),
  no stray sweep, no guard roaming. #187's report had "four Capital Ship defenders" spawned by the game there, then
  stuck moves; #42 is idle AI aboard a POI.
- Also measured: the Capital Ship has navmesh (floors at Z -740..460, its box centre at Z 1140), but
  K2_GetRandomReachablePointInRadius from the box centre finds nothing (0/6, every other interior 6/6): the centre is off
  the navmesh. K2_GetRandomPointInNavigableRadius from points spread over the box's height finds floor points (6/6).
- Fix: after the survey, named interiors that aren't stations, AI frigates or your own ship become S.pois, with entries
  (their own, RaidAINodeStart inside, else navigable points from K2_GetRandomPointInNavigableRadius) and no berths.
  playerPlace checks them after stations, so garrisonStation / sweepStrays / roamGuards run there; crews never dock at
  them (they aren't in S.stations). Log: "[rivals] boardable places without a dock: Scout Frigate (4k m2, 7 entries),
  Capital Ship (10k m2, 8 entries), Moon Base (107k m2, 8 entries)".
- Verified (Space_Beta, teleported into the Capital Ship): "you: in Capital Ship"; "Capital Ship: none of its own
  defenders, 3 soldiers", "garrison: 3 soldiers coming (2 at AI nodes)", spread pool seeded with 13 points; the three
  (2 BotPawn_C, 1 BotPawnGuard_C) visible, on the navmesh, controlled and patrolling.
- Not verified: them fighting you there (no fight came in a minute; the bridge's LineOfSightTo read false at every spot
  tried, so the test was inconclusive; and god mode sets bCanBeDamaged false, which they may ignore), and the game's own
  Capital crew being adopted (it didn't spawn on these runs: "0 placed NPC(s) to adopt").

## Nuclear mines defused in place (#197 part 3, 2026-11-20; defuse.lua)
- Nuclear_NodeMine_C is the same SubNodeActorMine_C as the small one (Base Damage 1000, Damage Radius_Inner 1000,
  Maximum 2500; Space_Alpha has 18). Same prompt and key (R at the helm, within 30 m; "R   Defuse the nuclear mine"),
  a bigger board: CFG.BOARDS = station 6x6/6/75 s, small 6x6/6/75 s, nuclear 8x8/12/120 s.
- Win: a Fuse (2x1) and 3 HiGunpowder (1x2, rotated into the free row) into the pocket; NuclearMaterial (3x3, too big for
  any pocket) appended to the stand-in's gifts_in.txt (require("pvebackend") .. "gifts_in.txt"); the stand-in puts it
  in the gift box within a second ("gifts: ['NuclearMaterial'] in the gift box").
- Lose: the mine's own explosion (ExecuteUbergraph entry 15) with Damage Radius_Maximum AND Damage Radius_Inner
  stretched to your ship + 5 m. With only the outer radius stretched, a nuclear mine 20 m off did 0 hull damage (its
  falloff past the 10 m inner radius); with both, hull 575 -> 0, LifeSupportDestroyed, the ship disabled and burning
  (the issue's "ship death").
- **Test hazard: god mode (bridge/god.txt) sets bCanBeDamaged false on whatever you control, which at the helm is your
  ship:** with it on, no mine blast hurt the hull (that's why a later small-mine test read 0). Test ship damage with it
  off.
- Verified in game (Space_Alpha, real R and clicks, ToolKit in a bag): nuclear board 8x8 "Cleared 0 of 52", won (loot
  and gift as above), lost (hull 0). Not done yet for #197: towing a nuclear mine home to the hold.

## Co-op joiner stuttered every 1-2 s (#254, 2026-11-20; raidtime.lua, main.lua pgos overlay)
- Report: since the 19 Nov builds, a co-op joiner's game stutters every 1-2 s; the host and solo play are smooth.
- Measured with the profiler on a host + joiner on this PC (both instances write the shared bridge/profile.txt; the
  joiner's blocks are the ones whose "you:" line reads "-, nearest station nil"): FindFirstOf RaidGameState x18-20 per
  10 s (~60 ms each) and frame gaps of 110-170 ms about once a second. RaidTime.update (#159, the launcher's raid length
  and space gate) looked the game state up on every update until it could set both, and that needs
  gs.AuthorityGameMode, which only the host has: on a joiner it never finished.
- Fix: the game state is cached in the raid table (found once), and with no game mode for 20 updates (~10 s) the module
  stops: "raid length and space gate: the host's (no game mode here: joined a co-op raid)". Also the PGOS overlay search
  (FindFirstOf PgosOverlay_BP_C, every 10 s while not found) stops in a raid map after its first minute: a joiner never
  has the overlay. (In a map's first 30 s it runs every second, by design; don't read that as the bug.)
- Verified (host + joiner, Space_Alpha): after the fix the joiner's 10 s windows had no RaidGameState or overlay scans;
  one window had no frame over 33 ms (worst 26), the next one 141 ms gap from the level-prop and mine scans everyone has.
- Still there for everyone, smaller: defuse.lua's station-mine scan (FindAllOf MineStaticActor_C, ~70 ms every 20 s on
  foot), level props' FindAllOf passes.

## Mine scans backed off (2026-11-20, #254 follow-up; defuse.lua)
- defuse.lua scanned every object for station mines (FindAllOf MineStaticActor_C, 45-77 ms) every 20 s on foot, and for
  space mines every 60 s at the helm, on every map: a small hitch everyone had (seen in the #254 profiles).
- Now each kind keeps its own list (walking to the helm and back doesn't rescan): 3 looks SCAN_EVERY apart, then every
  SCAN_LATER (90 s) to drop gone ones; a kind found nowhere after 3 looks isn't looked for again on that map ("defuse: no
  station mines on this map").
- Found on the way: Space_Alpha's station interiors have 10 station mines (MineStaticActor_C), and the on-foot prompt
  works there ("A mine. You need a ToolKit to defuse it", 2026-11-20): station mines on space maps, listed as not
  verified in the #197 part 1 section, are verified for the prompt.

## A co-op joiner's minimap was an empty box (#214, 2026-11-20; main.lua space branch, minimap.lua known/homeInside)
- Three causes, found with probes that run on the joiner only (both copies read bridge/dir_eval.lua: a probe that lands
  on the host writes itself back for the joiner and returns):
  1. The joiner's loading veil gave up on streaming (`revealed` true, `readyAt` nil), and everything in the space branch
     waits for readyAt: Missions.update never ran, so the minimap's survey (which starts from the contract actors) found
     no places. The joiner has all 57 contract actors, tagged.
  2. The joiner has no Node_* station actors at all (0; RaidDockingComponent 0), while its airlocks (18), contract actors
     and the AI ship interior are there: far stations' exteriors aren't sent to the client. A place counted only with a
     docking node or an AI frigate hull.
  3. "Your ship" comes from raid.home, which space.lua (host only) sets: the joiner was told to get back to its ship
     while aboard it.
- Fix: a joiner (no AuthorityGameMode) runs Missions.update once revealed, and nothing else from that block (floor loot,
  mines, civilians, rivals are the host's); the minimap counts interior-only places for a joiner (known(p): floor plans
  and tasks, no flying route) and takes the nearest player ship interior as its ship (homeInside, looked up once).
- Verified (host + joiner on this PC, joiner with the host's crew, CPT=0): "[missions] 57 contract actors", "minimap: 3
  places here: Rebel Base, Fortress, Spaceport", panel showing "Weapons Intel 0/30 / Go to the helm and press F to fly,
  8 m to go" with the helm marked.
- Not verified: a joiner's floor plans (they're scanned once raid.navReady, which a joiner doesn't set either), its
  route inside a station, flying routes (no nodes: by design none).
- Test tooling note: config/minimap.txt (N's on/off) is shared by both copies; bridge/minimap_cmd too.
- Extracting together (20 Nov, later; #214's "done looks like"): host + joiner aboard the host's Rustbucket (Space_Alpha, joiner CREW=solo1 CPT=0), gate spawned early (UA_SpaceGateTrigger01_C:TriggerSpaceEvacReady on the host), the host at the helm (Possess) teleported into EscapeZoneSpaceGate_C. Both left the raid within 3 s. Joiner, on foot in the interior and never touching the gate: "extracted with 4 item(s)", its own stand-in wrote the 4 kit items back, XP 14 -> 35, Escapes 3 -> 4, nothing taken from its save. Host: raid_out ended, Escapes 1 -> 2. The joiner's stand-in logs "ship lost" for this: that's the marker for leaving on foot or by pod (no ship of its own out), not a loss. Not tested: the joiner at the helm or a turret (lining a client up with the helm by teleport and SetControlRotation didn't get the F prompt in a few tries), the joiner flying the gate, the host's hired crew aboard.
- Floor plans for a joiner (20 Nov, later): the scan waited for raid.navReady, which only the host's director sets, so a joiner never even read the plans already on disk. Now a joiner (S.joiner) loads cached plans (assets/minimap/<key>.png, shipped for the stations and the Starter/Strike ships) and never scans (nextScan(true)): no navmesh is assumed on a client. Verified on Space_Alpha (host + joiner on this PC, CREW=solo1 CPT=0): the joiner's panel shows the Rustbucket's plan with the helm and its own arrow. Not verified: a station's plan on the joiner, and a place with no cached plan (it stays blank, as before).

## The Blood Raider, and listing the pak without its key (#228, #230, #231; 2026-11-20; outfits.lua, female.lua)
- **The pak's file list is in memory.** The game keeps its decrypted pak index loaded, so every packed path is plain
  ASCII in its memory, relative to Content (`Characters/MainPlayer/Meshes/Bodies/...`; a `/Game/` prefix finds
  nothing). `tools/offline-audit/paknames.py <pid> Characters/ out.txt` lists them: 4907 under Characters/, no pak key.
  The asset registry route crashed the game (`AssetRegistryImpl:GetAssetsByPath` with a Lua out table: out TArray of
  structs, same family as GetDataTableRowNames).
- **DT_PlayerAppearance rows carry their mesh** (`Cosmetic`, ObjectProperty at +24). `tools/offline-audit/approws.py`
  lists them. Every body and head mesh in the pak has a row (1-72, 84-95), except one:
  `Bodies/Steam/Raider_Body_Blood_Skel_01`, a bloodied Raider suit in a "Steam" folder, which matches row 72 "Nomad Blood
  Head" (cost 0, no unlock stat): a platform reward set, probably. No "Ranger", EA or pre-order meshes exist: the UA looks
  in the game are UA Marine (64-67), UA Medic (70-71) and UA Commander (94-95). The hangar crewman is
  Characters/Crewman (own skeleton, #227); traders Greybeard, Overlord, Rosie, Wolff, Pirate_Trader have their own too.
- **Wearing it:** F9 in the lobby, "Hidden outfit" now cycles brown coat, black coat, Blood Raider. The Blood Raider is
  rows 6 + 72 through the game's setters, and female.lua's `setPlayerSwap` puts the bloodied body over
  Raider_Body_Skel_01 on your own character only (lobby stand with isPlayer, your PlayerPawn_C), the women's copy
  (BodieF/Steam, already built) when F2 is on. In the lobby the SetSkeletalMesh hook does it; in a raid the game puts the
  body on natively (the hook never fires), so `Female.dress` applies the swap too and `playerDue()` is true while a swap
  is set: main.lua's per-update pass does it. Saved in `config/outfit_body.txt`. The swap holds while the controller's
  `EquippedBody`/`EquippedHead` read 6/72; empty values (start-up, before the look loads) count as unchanged (a first try
  switched itself off at start-up). The stand-in owns row 72 for everyone (FREE_COSMETICS).
- Verified: lobby (F9 action run through a director probe), after a restart, and in a Spaceport raid: CharacterBody0 and
  R_BodyMesh (what the corpse wears) both Raider_Body_Blood_Skel_01, head Nomad_Blood_Head. Switching (setters 6/1 and a
  tab press) logged "the Blood Raider is off" and saved none.
- Not verified: a real Appearance click (the setters were called from Lua), the women's version on screen, co-op (the
  hook swaps any PlayerPawn_C wearing row 6 on the host, as female.lua already does for every player pawn).
- Probe pitfalls hit: calling GetFName on an empty SkeletalMesh of a lobby stand crashed the game (check
  GetAddress() ~= 0 first); a bridge `raid` with no god mode ends in death after ~2 minutes in Spaceport (guards), which
  looks like the raid "bouncing" to the lobby.

## Wrecks hold their dead, and sometimes survivors (#251, 2026-11-20; rivals.lua updateWreck, rivalbodies.lua materialize)
- Before: a rival ship shot to 0 hull marked every member dead and the wreck stayed empty when boarded. Hayley on #251:
  downed ships should have dead bodies, plus maybe 1 or 2 survivors, not always.
- Now, when a flying crew's ship goes down: with chance `CFG.WRECK_SURVIVORS.chance` (0.5), 1 to `most` (2) of its living
  members survive, at 25-60 % of their health; the rest are marked `sankWith`. Log: "went down with their ship (alive
  in the wreck: ...)".
- Boarding the wreck (place "rival", S.aboard == c) runs `updateWreck`: the first time, `materialize(c, spots,
  "boarding", nil, true)` builds the survivors and the `sankWith` dead; finishBuilding kills each dead one as soon as
  it's armed (GameplayStatics ApplyDamage 100000, no instigator, so no kill credit or mission count). The game then
  swaps the pawn for its lootable SIGIS_ExampleDeathActor_C (pvepatch pve_bodies), so the pawn itself reads 0,0,0
  afterwards: look for the death actors, not the pawns. Leaving puts the survivors back into the simulation after
  DEMATERIALIZE_AFTER; later visits bring only the living back (`c.wreckDressed`).
- Verified (Space_Alpha, survivors forced to chance 1 through a director probe, the Rusty Mule given an interior and its
  hull set to 0, boarded with rivalcombat's breachInto): "alive in the wreck: Tinker, Mercer", "aboard the wreck of the
  Rusty Mule: 2 dead, 2 alive", Tinker 55 hp and Mercer 29 hp up and hunting; two death actors 4 and 8 m from the
  breach, a body lying on the floor with its gear (7 and 2 loot items on the pawns before the swap). No Lua errors.
- Not verified: looting those corpses by hand, a second visit, a wreck from a real fight (the test zeroed the hull),
  the 50 % roll in normal play.

## Nuclear mines towed to the hold (#197, the last part; 2026-11-20; defuse.lua tow, holdBlast)
- At the helm by a nuclear mine the prompt is now "R   Take the nuclear mine aboard" (no ToolKit needed to tow). R: the
  mine's Active? goes false, MineRotation stops (its light keeps pulsing), collision off, scale CFG.HOLD_SCALE (0.35: it
  fits the starter's hold), set down 60 cm above the interior's `SalvageSpawn` component (looked up by name among the
  interior's SceneComponents; the interior's middle if it's missing). One at a time ("Your hold already has a nuclear
  mine in it"). Small mines are still defused in place from the helm. The in-place nuclear board (#256) is gone.
- On foot within CFG.HOLD_REACH (3.5 m, 3D) of it: "F   Defuse the nuclear mine", the 8x8 nuclear board (kind "hold";
  `where(kind)` maps hold and station to on foot, space to the helm). Win: Fuse + HiGunpowder into the pocket,
  NuclearMaterial to the gift box, the mine destroyed. Lose: its own explosion with both radii set to CFG.HOLD_BLAST (30 m:
  everyone in the hold), plus ApplyDamage 100000 on your body and on your ship (inside.SpaceshipToPairTo).
- Verified (Space_Alpha, at the helm by Possess, real R and F presses, ToolKit given by a probe): prompt shown; tow logged
  "set down in the hold at -110620,-247526,3194"; the mine stood in the hold at 0.35 scale (screenshot); F opened the
  board; a won board (finish(true) through a probe) gave a Fuse and the gift ("gifts: ['NuclearMaterial']"); a second mine
  run out of time: "failed (out of time), it goes off", YOU DIED straight away.
- Not verified: the hull after the hold blast (the raid ended on the death), clicking a board to a win by hand, a ship
  other than the starter, extracting with a live mine aboard (it's left behind with the map), crew in the hold.
- Test note: an R tapped right after taking the helm can arrive before the prompt's update has picked the mine; hold it
  0.3-0.4 s.

## A taken ship's turrets for your gunner; the interceptor walls (#70, 2026-11-20; rivalcombat.lua checkStolen, rivals.lua shipTurrets)
- "Your gunner mans 0 turret(s)" after you take a rival's ship: R.shipTurrets reads the hull's SpawnedTurretArray, but a
  rival hull's turrets are the mod's own (rivalships.lua fitTurrets destroys the hull's default turret and keeps the
  design's in c.turrets). checkStolen now hands c.turrets to S.stolenTurrets { ship address, list } (and empties the
  crew's list), and shipTurrets falls back to it for that hull. Verified (Space_Alpha, the Bad Penny, a Galaxy
  Interceptor with 1 turret, breached and piloted by Possess): "you took the Bad Penny", shipTurrets -> 1 (0 before).
  Not verified: a hired gunner actually firing them (no crew on the test save), a hull taken in a later raid (ownHull
  spawns the design's pawn, whose own default turret is in SpawnedTurretArray, not the design's turrets).
- Interceptor walls: a Light Interceptor (borrows FrigateInside_DefaultScout) breached by probe looked complete in four
  directions, and its interior actor has the same 36 StaticMeshComponents / 26 hidden (interaction areas, collision,
  pod hatch area) as a Raider Scout's and a Marauder Scout's. interiors.lua collects only levels present at raid start
  (rival interiors spawn later into the persistent level), so it doesn't hide their pieces. Not reproduced.
- Ship damage and repair, first look (for #70's "disabled but nothing to repair" on a taken wreck): the starter frigate has MainHullHealth 575 and flags bEngineDestroyed / bLifeSupportDestroyed / bTurretDestroyed / bHelmGunDestroyed (the interior mirrors them: EngineDestroyed, LifeSupportDestroyed, ...). Its interior has two RaidUseableFrigatePartComponents: LifeSupport_PIPE01 (Health 1, MaxHealth 0) and the helm gun (100/100). ApplyDamage 700 on the hull: hull 0, the pipe 1 -> 0, LifeSupportDestroyed true on both (engine untouched). So a disabled ship is one with its life support pipe broken. A rival wreck's interior is made later (when your pod comes near), with a fresh pipe at 1: disabled with nothing broken to fix, which fits the report. Repair offline: a Wrench (items.json, a 2x1 tool) in the pocket, holding real F 6 s by the pipe, and SIGISCharacter:ServerInteractComp(pipe) all left the pipe at 0 and the hull at 0. The real repair path (wrench in hand? an ability?) is not found yet. Classes: RaidUseableFrigatePartComponent has only Onrep_HealthChange; RaidSpaceshipInside has OnRep_LifeSupportDestroyed, OnLifeSupportDestroyed, OnRep_ShipHullHealthChange, ShipHullHealthChangeEvent; RaidFrigate GetSystemsHealth.
- Test recipe (director probes): `R.prepBoard("Interceptor")` gives the nearest such flying crew an interior; to force a
  design, destroy a crew's ship and set `c.hullRow = design.row, c.state = "waiting", c.launchAt = 0` (spawnShip reads
  hullRow); board with rivalcombat's `breachInto(c, true)` (an upvalue of Combat.playerBoarding).

## Ship repairs with the blowtorch (#70, 2026-11-20; blowtorch.lua repair, rivalcombat.lua pairInterior)
- The game's repair tool is the Blowtorch (the Wrench is scrap). Like the vault locks, its repair is native
  (RaidWeapon_Tool) and never reaches the ship offline: 8 s of real torch fire on a broken life-support pipe left it at 0.
  FrigateInside_Starter_C.SetupTheRepairParts is an empty stub in this build.
- What the interior listens to: OnLifeSupportDestroyed(JustFixed) and ShipHullHealthChangeEvent(OldAmount, NewAmount)
  (the latter sets ShipCurrentHealth and drives the lights and damage effects; decompiled with kdis.py, ubergraph 16596).
- Fix, blowtorch.lua: while the torch fires (BurstCounter > 0), the part of your ship nearest your aim line within 3 m
  and 80 cm of it (its RaidUseableFrigatePartComponents: the life-support pipe, the helm gun; and the
  ShipEngineRepairInteractArea) is mended: a broken part first (4 s to full; the pipe then clears LifeSupportDestroyed on
  interior and hull and calls OnLifeSupportDestroyed(true)), then the hull rises 25 a second to Curr Max Health, each step
  told through ShipHullHealthChangeEvent. "Your ship" is rivals.lua's playerShip (your own or one you took) or raid.home.
  Logs "your ship's life support is mended", "hull is patched, it can fly again", "hull is back to full". The torch's
  own charge drains while firing, so repairs aren't free.
- A wreck whose interior is made after its hull hit 0 now has its pipe broken at pairing (rivalcombat.lua pairInterior),
  so taking it means repairing it.
- Verified (Space_Alpha, real torch fire with the mouse, on foot by the pipe, god mode on):
  - Own ship: ApplyDamage 700 -> hull 0, pipe 0; torch: pipe 1 in about 4 s, LifeSupportDestroyed false, hull 0 -> 361 in
    ~22 s (ShipCurrentHealth followed), the engine room's fire glow gone. At the helm, W for 4 s: 21 m. Wrecked again:
    1 m (a hull-0 ship doesn't fly).
  - A rival shot to 0 before its interior existed (the Widowmaker): interior made -> pipe 0, LifeSupportDestroyed true;
    boarded, taken ("you took the Widowmaker"), W: 3 m; torch -> mended, hull 345; W: 38 m.
- The wreck's fire effects (20 Nov, later): rivals.lua hullDamageFx already lights one smoke/fire emitter per quarter of hull lost (all of them, plus the engine fire, at 0 or with life support broken) and puts them out as the hull rises. The fire seen on the repaired Widowmaker was its hull still low. The real gap: repair stopped at the interior's Curr Max Health, while the effects count against the hull's own full (S.playerShipMaxHull, the hull at launch). A taken Light Interceptor read interior 575, hull 700: the old cap would have left it short. Repair now goes to the larger of the two (R.playerShipMaxHull). Verified: the taken Rusty Mule (Light Interceptor) torched from 0: at 361/700 one emitter left and the engine fire out; at 700/700 fx level 0, every emitter inactive, a clean hull from the helm view. The first torch ran dry at 361 (250 charge): repairs cost charge.
- Not handled (now): the rival wreck's hull fire effects are fine once full; repairing the engine
  or turret flags (only life support and hull were seen broken); a hull mended by someone other than you.

## The slim installer zip (2026-11-20; tools/release/bootstrap.py, install.ps1, build_release.py write_installer)
- Ask (user): a new player shouldn't have to download eight zips; a small launcher-only download with an install option
  should fetch the rest from the latest release. Build 17's assets: the main zip 5 MB, seven -deps- zips 48 MB.
- Already there before this: a folder with only the main zip has its deps.json, and the launcher's start-up check
  (check_update -> stale_deps(installed_deps()) -> start_repair) downloads the missing dependency parts from that
  build's own release. So only "start from nothing" was missing.
- Now: MaraudersOffline-<build>-installer.zip (13 KB: Install.bat, scripts/install.ps1, find-game.ps1, bootstrap.py,
  launcher/update.py, README.txt, CREDITS.md), written by build_release.py's write_installer from the dev tree (no game
  files needed) and listed first among the uploads. install.ps1, once it has Python and the folder has no version.txt,
  runs `python -I scripts/bootstrap.py`: update.latest() -> download_update (the main zip, then every part stale_deps
  finds missing: all of them in an empty folder; each checked against GitHub's SHA-256) -> update.install (rollback on
  failure) -> a final stale_deps check; then the usual Pillow, game path and shortcuts. "-installer" matches neither
  update.ASSET nor DEP_ASSET (checked), so the updater never takes it for a build. bootstrap.py also ships in the full
  build (scripts/bootstrap.py).
- Verified: the installer zip built and extracted into an empty temp folder; bootstrap.py there downloaded build 17's 8
  zips (61 MB), installed public-test-20261120.17 (version.txt, UE4SS.dll, assets/female/ in place) and found no stale
  part. install.ps1 parses. Not tested: Install.bat end to end from the installer zip (it makes desktop and Start menu
  shortcuts and asks questions: not run on this machine), Linux (install.sh doesn't bootstrap: Linux players still take
  the zips by hand), a build published with the installer zip on it (needs the pak key to build).

## The defuse board: a safe start, one spare, a new look (#197, 2026-11-21; defuse.lua open, paint, tint, tick)
- Ask (user): too many deaths, and it looked ugly. A safe starting position, and a better look.
- Safe start: open() picks a cell off the edge, lays the charges around it (lay already keeps the first cell and its
  neighbours free) and reveals it before the board shows, so every board starts with a cleared area (9-12 cells on 6x6,
  30 of 52 on the 8x8 nuclear board in the tests). No more blind first click.
- One spare (CFG.SPARES = 1): the first charge you set off is caught (logged "a charge set off and caught"), shown as a
  dark red "*", and the line under the title says "No spare left: the next one blows". The next charge sets the mine
  off as before. Dense boards (12 in 64) can force a guess even from a clear start; the spare covers one.
- Look: ink panel with the launcher's orange strip and title, a time bar (ProgressBar) that turns red under 25 %,
  raised steel cells, cleared cells sunk dark, numbered cells tinted by the classic colours (1 blue, 2 green, 3 red...)
  behind a white digit, orange flags, matching buttons.
- **UE4SS pitfall:** TextBlock:SetColorAndOpacity({SpecifiedColor = ..., ColorUseRule = 0}) arrives as all zeros: the
  text went transparent. Passing the widget's own ColorAndOpacity back errors. Writing the property's fields
  (t.ColorAndOpacity.SpecifiedColor.R = ...) sticks but only shows if done before the widget is on screen. So text
  colours are set at build time only; anything that changes later is a Button:SetBackgroundColor or
  ProgressBar:SetFillColorAndOpacity (FLinearColor: those work).
- Verified (Space_Alpha, director probes, no real input): small board with 12 and then 9 cells opened at start, numbers
  coloured; a charge pressed through the board's own tick: caught, dark red "*", text updated, board still open; the
  time bar red near the end; out of time -> the mine goes off; the 8x8 nuclear board fits (30/52 opened).
- **Test hazard:** the desktop app can keep focus: SetForegroundWindow then fails silently and simulated clicks and keys
  go to whatever window is in front (here, the Claude app). The R presses that "didn't take" and some board clicks went
  there. Check GetForegroundWindow before sending input (scratchpad safeclick.ps1 pattern), or drive the board from a
  probe: swap a cell's button for one that reads as just released and call tick.
- Not verified: a win clicked by hand on the new board, a station mine (on foot) and the hold board with the new look.

## Dismissed crew leave for good (#303, 2026-11-21; hire.lua dismiss)
- Report (Discord, acidbase): hire a placeholder, the recruit you want appears, dismiss someone to make room, and the
  one you wanted vanishes. Cause: hire() appends a new recruit at the END of the 8-slot pool; dismiss() put the
  crewmate back at the FRONT and cut the pool back from the end, so the newest recruit was the one dropped.
- Fix: a dismissed crewmate is gone for good, like one who dies (the reporter's choice; DISMISS already asks "SURE?").
  The pool is untouched. Message "X left the crew for good".
- Verified (lobby, throwaway save, crew file backed up and restored): recruit 1 (Rosco) moved into the crew with
  hire()'s bookkeeping from a probe (a fresh recruit, Uri, appended at the bottom), then `dismiss Rosco` through
  bridge/crew_cmd: "Rosco left the crew for good", the pool still 8 with Uri last, Rosco gone from crew.lua.
- Seen on the way, not chased: the crew_cmd `hire` test command read the cash as 0 (pc:GetCash() on the controller it's
  given) while the lobby showed 122,086, so hiring through it refused; a real click on HIRE wasn't tried.

## Frame times in every tester's log (2026-11-21, #336; NOT run in game)
Players report stutter that grows over a raid, but the status line only had an average fps (72-87 in a report where the
player felt stutter). main.lua's profiler wrapper now always runs a light mode (`light(tick)`): in a raid, every 10 s
one `frames:` line with the worst gap between frames, frames over 50/100/200 ms, the director's worst and average tick,
the four slowest `ppcall` sections (total and max ms), FindAllOf/FindFirstOf calls (count, ms, the two costliest
classes) and the Lua heap / gc cycles. FindAllOf and FindFirstOf are wrapped once at load for the counts (one
`os.clock` pair each); `bridge/profile_on` still swaps in the full profiler on top. `ppcall` now always times sections.
- raidtime.lua: the gate countdown searched every TextBlock every 3 s until it found its text, with no limit, so a raid
  without that text (no HUD countdown) searched all raid long. Now at most 20 searches, then a log line.
- Not verified: the cost of the light mode itself (expected well under 0.1 ms a frame), and the log line's format in game.


## Key reference (#389)
- 2026-11-24, #389 first pass: `keyhelp.lua`, F1 toggles a panel listing the mod's keys (F1 was unbound; checked every
  `RegisterKeyBind` in the mod). Built like deathscreen.lua's panel (DebugInfo_Widget host, Border + TextBlocks),
  dropped on world change, never rooted. Its KEYS table, README's Controls table and the launcher's CONTROLS list must
  be kept in step by hand. First-use hints (from the issue) not done. NOT tested in game.
- 2026-11-24 update: F1 is the game's Voice01 (F1-F8 are its voice lines, which NPCs react to), so the list opens from
  the F9 menu's "Key list" button instead (debugactions.lua, closes the debug menu). KEYS follows the new layout of the
  key move PR (F9 debug, F10 AI, F11 crew, body in F9). Not tested in game.
- 2026-11-25, #389 first-use hints: `hints.lua`, called from main.lua's update after `Lobby.tick` (no new main local:
  `require("hints")` inline). Five hints (lobby, raid on foot, helm via `ShipSpeed.atHelm`, station mine via
  `Defuse.nearStation()`, crew via `Hire.crewCount()`), queued, one at a time for 8 s in a keyhelp-style panel. Seen ids
  in `<backend>/saves/<active save>/hints_seen.txt` (same save lookup as rivalcrews' baron_streak), else next to the
  backend. Switch `HINTS` (features.lua, Features tab). A failed show isn't written, so it retries next world. NOT tested
  in game: panel position (40,80) over the HUD, that `pc.Pawn` is set on foot in raids, the crew hint firing in the lobby.

## Death screen (#331)
- 2026-11-21, #331 first pass: `deathscreen.lua`. Nothing in the mod saw damage to the player (botdamage.lua and
  hitzones.lua are your shots at bots), so hits are inferred: main.lua's `ServerMultiSimulateWeaponFire` hook calls
  `DeathScreen.botShot` for every bot shot, and `DeathScreen.frame` (director tick) watches your `PlayerPawn_C`'s
  `Health`. A drop is put down to the most recent bot shot within 0.6 s (attacker: a rival's `rival.name` and crew from
  `raid.bots`, else the bot's class name; gun cleaned like rivalbodies `gunName`; distance pawn to pawn). No recent shot:
  "unknown cause (fall, blast, fire?)". At Health 0: a DebugInfo_Widget panel for 10 s (headline, last 3 hits, rough
  damage you'd done to the killer = highest Health it was seen shooting with minus now) and a `death: ...` log line.
  Dropped (not touched) in `resetRaid`. No hit zone: the damage event isn't seen.
- NOT tested in game. Unverified: that the hook fires before the Health drop is visible in the same/next frame; that
  the panel shows over the game's death UI and that the controller keeps ticking after death; attribution with several
  bots firing at once (could name a bot shooting at someone else).

- 2026-11-24 (#412, "armour doesn't protect"): the report added up the three hits shown (11 + 36 + 17 = 64) against a death
  from 100. The screen showed only the last 3 of up to 6 hits kept, and the killing hit reads only the health left.
  Now: up to 16 hits kept, a line with the total taken in the last 15 s and over how long, and the same total in the
  log's "death:" line. Bot hits on you go through the game's own damage function, which takes the armour rating off
  flat before the zone multiplier (head x3.5), so pistol headshots still hurt through a heavy helmet. Whether bot hits
  on the player get the full armour offline is NOT verified. Not tested in game.

## Launcher SETTINGS page and presets (2026-11-21, #324; launcher tested headless, NOT in game)
Inspired by SPT's SVM: every F3 setting before a raid, with presets to save, share and load.
- The mod stays the owner of the settings. `tuning.lua writeSchema` writes `config/settings_schema.json` at every start
  (each tab and row: id, label, min, max, step, default, help; and each difficulty level's values from `presetValue`).
  Defaults are the tables' values taken before the saved file or a raid condition is applied.
- `launcher/settings.py` reads the schema and edits the same files F3 does: `config/ai_tuning.txt` (only values that
  differ from the default; ids the schema doesn't know are kept) and `config/ai_presets.txt` (F3's Saved setups). A
  shared preset is one `[name]` block with a `# Marauders Offline settings preset` header line.
- `launcher.pyw show_settings`: tabs on the left, sliders with a Default button and help on the right, difficulty
  buttons and My presets (Load, Save as, Delete, Export, Import) on top, Reset this tab / Reset all. Each change is
  written at once. The game reads the file when it starts; F3 changes things live in a raid.
- Before the game has run once with this build there is no schema: the page says so.
- Tested: `launcher/test_ui.py` (16 OK, incl. the new settings test and every dialog on screen with the grab); the
  JSON writer checked with lupa. Not tested: a real schema from the game (179 rows) and loading the result in game.
- Feature switches (same day): `features.lua` holds 1/0 switches (death screen, lore on the loading screen and on
  arrival, minimap kill/drop/crew markers, the frames: log line). tuning.lua shows them as a "Features" tab, so F3 and
  the launcher's SETTINGS page both have them; each feature reads its switch where it runs. Not tested in game.


## Bots beg and taunt (2026-11-21, #316 first pass; luacheck only, NOT tested in game)
- New `banter.lua` (called from bots.lua updateBots; settings in main.lua CFG: BEG_HP .25, BEG_CHANCE .4, BEG_RANGE 1500,
  BEG_SECONDS {6,10}, BEG_FLEE_SECONDS 20, TAUNT_CHANCE .4, TAUNT_EVERY 12, TAUNT_GAP 4; F3 Personalities tab has rows
  for BEG_CHANCE, BEG_HP and TAUNT_CHANCE, 0 = off). Only the game's own voice rows (voicelines.lua, played through
  `Voice.say`): "Help" for pleas, "Insult01"/"FuckOff" for taunts.
- Begging: a Rat, Coward or Timmy (not crewmates, not a rival crew's captain (`rival.isCaptain`, set in rivalcrews
  makeCrew), not the Red Baron, not profile "boss") under BEG_HP of its max health (`e.hpMax`, the highest Health seen;
  rivals use `rival.maxHp`), fighting or alerted, within BEG_RANGE of you: one roll per bot (`e.begDone`). If it wins,
  `e.begUntil`: updateBots treats it as "routed" (no fighting, no patrol; holdFire each update), StopMovement, "Help"
  now and again halfway. Hit meanwhile = begging ends, it fights back (the existing "shot by someone" branch engages).
  Time up = `Banter.flee`: sets e.routUntil/routNear (the #313 rout), picks a point with `Rivals.routPoint` (new export
  of rivalbodies routPoint) and walks there; you coming within ROUT_FIRE_RANGE makes it fight.
- Taunts: Chad/GigaChad. When a fight ends with no foe left (`won`, replaces the old 50% generic insult for them only)
  and when your health dropped this update while it fights you (`raid.pHp`; any fighting Chad can claim it, TAUNT_GAP
  keeps them from talking over each other).
- Unverified: that StopMovement plus holdFire really stops the tree shooting; that a "won" fight is always a kill (the
  foe could also have been lost); that rival-crew members' own movement code doesn't override the flee; the plea volume
  and which of the quiet/shout takes plays (Voice.say picks at random). Not done: callouts, answering F7/F8, notes
  dropped by spared bots, security contractors.

## Gate superstitions: Tick's two taps (#332, 2026-11-21, space gate)
- gatetaps.lua (lore: docs/lore/fragments/18_gate_superstitions.md rule 2). A tap is a Space press at a frigate's helm
  (shipspeed.lua's M.boost calls gatetaps.tap, before the cooldown checks, so a recharging boost still counts). When
  your own controller runs EnterEvacRaidVolume / Server_EnterEvacRaidVolume (loadout.lua, the `mine(ctx)` filter), the
  presses in the last TAP_WINDOW s (6) are counted. Exactly 2: a GoldCoin row appended to backend/gifts_in.txt (the
  hand-off defuse.lua's nuclear material uses; the stand-in's watch_checkout puts it in the lobby's gift box) plus a HUD
  line. 1: "Once is rude."; 3+: "Three's greedy."; 0: "You go through without a word." No reward for those.
  HUD line is `pc:ClientMessage(msg, FName("Event"), 5.0)`, as rivals.lua's say().
- Judged once per raid (the hook fires for both RPC names; ShipSpeed.reset also resets it) so re-entering can't farm it.
- CFG: GATE_TAPS (0 = off), TAP_WINDOW; both in F3 > Effects. A cash bonus was not used: a raid controller reads 0 cash
  and the stand-in has no payout hand-off file, whereas the gift box is already wired.
- Not tested in game (luacheck only). Unverified: that the Space bind fires while piloting at the moment of the gate
  overlap, and that ClientMessage shows over the gate's jump cinematic.

## Bots reload and heal in cover, Chads push when you reload (2026-11-21, #314 first pass; luacheck only, NOT tested in game)
- Magazines were already counted (#115): `bots.lua M.botShot` (from the `ServerMultiSimulateWeaponFire` hook) counts shots
  per bot against `WeaponConfig.AmmoPerClip` (fallback 30), keeps `CurrentAmmoInClip` in step, and on empty holds fire and
  calls `ReloadAIWeapon`. (2026-11-24, #413, luacheck only, NOT tested in game: prisoners' double barrels never
  stopped. Suspected cause: the AmmoPerClip read failing to the 30 fallback, and `e.mag` cached once per bot so a gun
  change kept the old clip. Now read per gun (`e.magGun`), any class with "Double" capped at 2, and the first read of
  each class logged as "bots reload: <class> magazine N (AmmoPerClip read X)". Unverified: that bot pellet guns go
  through `ServerMultiSimulateWeaponFire` at all (their pellets take the server path 0x1895dc0); if no such log line
  appears for a shotgun class, they don't, and the count never runs.) New: `selfcare.lua` (`Care.step`, once per update for a fighting bot). When
  `mag - shots <= mag * BOT_LOW_MAG` (0.15) the bot sets `e.careWant`; `coverCycle` then skips its chance roll and open-fight
  timer and goes to cover. Hiding in cover it zeroes `e.shots`, sets `reloadUntil`/`holdUntil` (BOT_RELOAD_SECONDS) and pins
  the cover's `until` so it doesn't peek; the existing frame loop refills the clip. No cover in BOT_CARE_GIVEUP (8 s): it
  carries on and tries again after BOT_CARE_COOLDOWN (12 s); empty still reloads in the open as before.
- Heal: below BOT_HEAL_HP (0.4) of max health (`rival.maxHp` or the highest health seen), not hurt for BOT_HEAL_QUIET (4 s),
  fewer than BOT_HEAL_COUNT (1) heals so far: cover, then `Health` is ramped (set directly, as botdamage.lua's armour
  refund does) from now to BOT_HEAL_TO (0.7) over BOT_HEAL_SECONDS (5). A hit, flanked cover or leaving the fight
  interrupts it (the heal still counts). No animation: `MultiCast_HealingAnim` has no probe anywhere in NOTES or scripts,
  so it was not called (a bad call crashes the game).
- Push: `Care.watchPlayer` polls `pawn:IsHealing()` and `pawn.CurrentWeapon:IsReloading()` (getters listed as callable
  under "Shared AI brain", but never called by the mod before: UNVERIFIED on the player's pawn; both valid-checked and
  pcall'd). While true, a Chad or GigaChad fighting you within BOT_PUSH_RANGE (2500) leaves cover and walks at you
  (`advancePoint`) for BOT_PUSH_SECONDS (4). Not done: reacting to looting or grenade pins, bots using carried meds
  (the med leaving their loot), and a reload animation beyond `ReloadAIWeapon`.
- CFG: BOT_LOW_MAG, BOT_HEAL_COUNT/HP/QUIET/SECONDS/TO, BOT_CARE_GIVEUP/COOLDOWN, BOT_PUSH_SECONDS/RANGE; F3 rows in the
  Cover tab (all but GIVEUP/COOLDOWN/PUSH_RANGE). Log lines: "reloads in cover", "heals in cover", "pushes while the
  player is busy". To check in game: watch for those lines in `backend/last_game.log`, that a reloading bot stays hidden
  and fires again after, and that `IsReloading` ever reports true on your gun.

## Build 23 report: guards frozen, lobby scans, recurring raid scans (2026-11-22; NOT run in game)
From Taki's report (`MaraudersOffline-report-20261121-2335`, build 23: soldiers and guards stop moving, rival crews ignore them).
- `rivalbodies.lua:922` (garrison) and `:1180` (stray sweep) threw "attempt to compare number with UObject": a placed NPC's
  `Health` read back as an object (a stale or reused address from the spawn hook, most likely). One bad entry killed the
  whole pass, so the station's own guards were never taken over and stood still. Fix: `hpOf(b)`, a number or 0.
- The new `frames:` lines showed the lobby calling `FindFirstOf("MenuPlayerController_C")` every frame (x587 per 10 s,
  ~6.9 s of 10 s) and raids calling `FindFirstOf("World")` twice a second (~17 ms each, minefield.lua and spacefx.lua).
  New `cache.lua` keeps both while `valid()` and waits 2 s after a miss; guild, invqol, mappick and outfits use it.
- levelprops `hum` scanned every RaidSpaceshipInside (~70 ms) every 15 s for the whole raid: now backs off to 120 s.
- main.lua's mouse-position log line used %d on a float ("number has no integer representation").
- Seen but not changed: a MineStaticActor_C scan (~70 ms) about once a minute in `defuse`; the game itself ran at a
  steady 30 fps late in the raid with the director at ~3 ms a frame.


## Stash duplicated at a space-gate extraction (#370, 2026-11-22)
- Report (KillSwitch, build 20261122.24): bags and containers showed empty in the lobby. The save held 456 items, 315 still
  pointing at a bag or container that exists: nothing was lost from the file.
- server.log: a raid ended through the space gate (19:04:44 `ship in the gate: True`, `ship lost`); at 19:04:58 the game
  wrote 386 inventory objects in one PUT: the 23 items taken into the raid (22 written twice) plus 324 new keys, 202 of them
  into containers that were already in the stash, 84 onto the stash grid, many exact copies of an item in the same cell.
  Stash 175 -> 499 items; the stacked-item repair (#239) then moved some and found no room for 161.
- Fix (stand-in): `twin_of` refuses a new inventory object whose fields after the key equal an existing item's (same row,
  stack, condition, cell, container): it is acknowledged but not stored, and later writes to that key are ignored
  (`state["dropped_twins"]`). `drop_twins` at start-up removes existing exact copies (oldest stays; a removed container's
  contents move to the kept one and are compared again), backing up `state.before-twins.json`. On the reporter's save:
  456 -> 250 items, 206 removed, a second run removes none; 10 cells still hold two different items (left alone).
- Not found: why the gate extraction's ExtractedLoot held the stash's container contents, and whether the lobby showed
  the containers empty because of the overlapping copies or for another reason (not checked in game). Test: a raid
  ending through the space gate with full bags in the stash, then compare the stash before and after.
- Second guard (2026-11-23): the report's copies went into containers that never left the stash (202 of 324). Raid loot
  can only sit in bags that went into the raid, and those leave the stash at checkout. So when a raid ends (ship_lost or
  ship_gate=1) the stand-in remembers the stash's containers (`home_containers`), and the first PUT with new inventory
  items after that refuses new items placed in one of them (acked, key added to dropped_twins). Later writes aren't
  checked; the mark expires after 30 min. Covers copies that differ from the original (moved by #239's repair, other
  stack), which twin_of misses. The 84 copies onto the stash grid are still only caught when exact. Tested:
  tools/test_standin_flow.py. NOT tested in game, and the root cause (why ExtractedLoot held the stash) is still open.
- Third change (2026-11-24): the stand-in lists the inventory parents first (`parents_first`: nesting depth, then key)
  instead of by key alone; the report's save listed 122 items on an earlier page than their container, a likely
  reason the lobby showed bags empty. Tested: tools/test_standin_flow.py. NOT tested in game: whether the lobby now
  shows those bags filled. Still open: why the gate extraction wrote the stash again (needs server.log PUT lines and
  last_game.log from a gate extraction with full bags in the stash).

## Lua hot paths: lobby scans, owner checks, one AI-start scan (2026-11-22; luacheck only, NOT tested in game)
- main.lua lobby stash grid: the `FindAllOf("InventoryContainerWidget")` (30-45 ms) ran every 2 s while the stash
  menu wasn't built. Now a miss doubles the wait (2 s up to 10 s; `raid.stashGridAt`/`stashGridWait`), and
  `GetFullName` is read once per candidate. No cheap "stash menu open" signal was used: the grid can be resized up to
  10 s late after opening the stash for the first time in a lobby.
- main.lua lobby stand: `FindAllOf("MM_PlayerChar_C")` every 3 s while `Female.playerDue()`; the stand is now kept in
  `raid.lobbyStand` and looked for again only once `valid()` fails (it dressed every matching stand before; there is one).
- invqol.lua `Q.tick`: `valid(ticker)` instead of `IsValid()`, and the class/world lookup is done once per ticker address.
- minimap.lua (home airlocks/helms) and rivals.lua (station airlock owner name, docking node class): the component's
  owner is checked with `valid()` before `GetAddress`/`GetFName`/`GetClass`.
- rivals.lua: `FindAllOf("RaidAINodeStart")` ran once per interior in the station survey and in `pointsOfInterest`;
  now one scan (`aiStarts()`) per call, filtered per interior.
- gamesettings/guild/invqol/lobbylabel/invkeys path lookups use the director's `valid()` (lobbylabel's ctx now gets it).
- Skipped: main.lua's `Default__GameplayStatics` at the time-dilation and controller lookups. `lib()` is not cached
  (it is `StaticFindObject` itself) and is defined below those lines, so it would change nothing.
- To check in game: the lobby `frames:` lines in last_game.log (no 30-45 ms spikes every 2 s), the stash grid's rows
  after opening the stash, the lobby character's outfit, the minimap's home ship, rival crews on space maps.
## Stand-in robustness (2026-11-22, review of the backend)
- Saves: `save_state` writes compact JSON, fsyncs the temp file before the rename (a power cut or blue screen used to be
  able to leave an empty state.json), and keeps the replaced copy as `state.json.bak`; `load_state` falls back to it when
  state.json is missing or doesn't parse (logged). loadout.json and cosmetics.json are only rewritten when their text
  changes (they were rewritten on every stash write).
- The #370 duplicate check builds one {item place: key} index per PUT and updates it as items are stored (it scanned and
  parsed the whole inventory once per item, under the lock). 500 items against a 1000-item stash: 0.02 s (CI test).
- server.log over 1 MB becomes server.log.1 at start-up; the pre-clean-up backup is `state.before-twins-<time>.json`, never
  overwritten; unparseable inventory/cosmetic rows and a failed coverage write are logged instead of skipped silently.
- Tested: tools/test_standin_flow.py (CI), including the timing, a copy inside one request, and the .bak fallback. Not
  tested in game (the stand-in's API is unchanged).

## Lua structure: no module globals, lobby.lua, census.lua (2026-11-22; luacheck and greps only, NOT tested in game)
Stacked on the Lua hot-paths branch (PR #377). Behaviour meant to be unchanged.
- No module globals: main.lua's `CrewLobby, Hire, Crew, PveMapPick, PveGuild, Conditions, Minefield, Civilians,
  Missions` are forward-declared locals now (next to `Quit, GameSettings...`). The modules that read them as globals
  `require` them instead (plain modules, no init-order dependency, no require cycles): launch.lua (mappick, conditions,
  hire), lobbylabel.lua (mappick, guild), mappick.lua (conditions), bots.lua and space.lua (crew). Their `if X then`
  nil guards are kept. `raid` was already local; every reader gets it by setRaid/shareRaid or a `raid()` getter.
  Checked with a small free-name scanner (scratch script: tokenizes each file, tracks local scopes, prints names read
  or written that aren't declared): only the UE4SS API (FindAllOf, FName, RegisterHook...) is left, plus one false
  positive (`taken` in tuning.lua's repeat...until).
- Trivial `local function valid(o) return X.valid(o) end` (and lib/dist) wrappers became locals set from ctx in
  `init` in botdamage, crew, crewlobby, deathscreen, defuse, gunseat, minimap, missions. Not in rivals.lua: its `H`
  table hands `valid/lib/dist` to the rival* modules at load time, before init, so the wrappers stay there.
- lobby.lua: the main-menu block of main.lua's update moved verbatim (captain button hook, player level for gearscale,
  Hire.lobby / Hire.leftLobby, stash rows and grid, the lobby character's outfit, the splash sweep), with the STASH_*
  constants and gearscale's require. Called as `Lobby.tick(pc, age, inMenu)` at the same point in update; it reads
  `raid` via shareRaid and gets pve_stash_rows as `ctx.stashRows`.
- census.lua: per-world (raid.world) lists of FindAllOf results, `all(cls[, maxAge])`, `refresh(cls)`, valid() filtered
  on read. playareas.findAll is now `Census.all(cls, Census.FRESH)` (FRESH = 3 s, its old cache window), and rivals.lua's
  station survey (NavMeshBoundsVolume, airlocks, LevelStreamingVolume, PlayerStart, RaidSpaceshipInside,
  RaidDockingComponent, RaidFrigateStationDock, aiStarts) plus minimap.lua's survey, surveyShip and homeInside use the
  same call. So a class scanned less than 3 s ago is shared, anything older is scanned again: retries (minimap's
  SURVEY_RETRY is 5 s) still see actors that streamed in. One difference: rivals' survey could now reuse a scan up to
  3 s old instead of always scanning fresh (the same window playareas already accepted). Left alone: the gate rescans
  (minimap), RaidFrigateIntSpawn and node turrets (rivals), which keep their own cadence.
- main.lua: 115 of 200 locals in use before, 121 after (luacheck: 85 -> 79 to spare).
- Verified: luacheck on every changed file; the free-name scan above; grep for each module name. NOT run in game.
- In-game checklist: lobby (stash grid height with a stash_rows save, the character's outfit after F2, splash, START
  RAID label, map/condition picker, guild page, crew stands); space map (rival crews launch and dock, minimap stations,
  airlocks and your ship's plan, civilians, mines); a raid start (input on arrival, loadout) and an extraction back to
  the lobby (crew wages).

## Station turret aim (#364, 2026-11-23)
- RaidSubNodeActor_Turret's fire routine (exe 0x18aea60..0x18aec5f, static disasm): direction to CurrentAimingActor
  (+0x268, its current spot, no lead) -> rotator, then pitch, yaw and roll each get rand*2*MissRange - MissRange
  (MissRange +0x294, DEGREES), fire, AmmoLeft (+0x288) -1. Flak_NodeTurret_C: MissRange 3, FireRate 0.75, TotalAmmo 10,
  ReloadTime 8, FireDistance 13500, Health 150. Radar_NodeTurret_C: FireRate 10000, FireDistance 10 (doesn't shoot).
- Measured (Space_Solo_01, starter frigate piloted, hull reset to 5000): MissRange 3 -> ~4800 hull lost in 20 s
  (ship disabled); MissRange 10 -> nothing in 20 s with 2 flak aiming. Later rounds read nothing at either value (the
  turrets had stopped engaging), so this is one clean pair, not a curve. Turrets ignored a hull teleported next to them
  until the player flew it.
- Fix: rivals.lua easeNodeTurrets sets MissRange every 0.5 s: CFG.STATION_TURRET_MISS 7, 14 when the turret aims at a
  pod (bADropPod). Verified after a relaunch: all four Flak_NodeTurret_C read MissRange 7 on Space_Solo_01. Hit rate
  after the change and the pod case not measured.

## Quit from a raid keeps the raid's progress (#361, 2026-11-23)
- Tested from the bridge in Space_Solo_01: pc:ClientReturnToMainMenuWithTextReason(FText("DISCONNECT")) travels to the
  menu, which within 1 s calls rpc statChangeArray and PUTs playerstats xp, contractstarttime, contracts (then
  cosequipped and ship rows): the same bookkeeping as "ESCAPED". No contract was finished in that raid, so whether a
  finished contract's cash/XP is paid on DISCONNECT is NOT verified.
- quit.lua: QUIT GAME in a raid's pause menu now ends the raid as DISCONNECT first, then quits 6 s after the lobby
  appears (45 s at most). Gear: unchanged (#49 returns what you brought). The click path itself was NOT driven in game.
- F9 "Extract now" already went through Client_GetOutWithLoot -> returnAfterExtract -> ESCAPED; Alt+F4 and crashes
  still lose the raid's progress.
- KEEP_PROGRESS_ON_DEATH (2026-11-24, features.lua / F3 Features, default 0): a death (Client_DiedCloseInv) ends the raid
  2 s later with ClientReturnToMainMenuWithTextReason(FText("DISCONNECT")) (loadout.keepProgressAfterDeath, called from
  main.lua's update before the pawn check), ahead of the game's own DeathToMainMenu ("DEATH"). Gear: unchanged, since
  ship_lost.txt is written at the death first. Default OFF: it is NOT known whether "DEATH" already pays contracts (no
  death with a finished contract has been watched), nor whether DISCONNECT pays a finished contract's cash. It cuts the
  death screen short. NOT tested in game: check the log line "KEEP_PROGRESS_ON_DEATH" and playerstats after a death.

## Crew kept per save, and Undo last raid restores it (2026-11-23, Discord report on build 24)
- Report (spacedork_): crewmates stayed dead after the launcher's "Undo last raid". Cause: the mod's crew (hire.lua
  SAVE_FILE, backend/crew.lua: hired crewmates, pool, deaths) lives outside state.json, and save slots only ever
  copied state.json. So one crew was shared by every save, and Undo rolled back only the stash.
- Now: the stand-in copies crew.lua to crew.before-last-raid.lua at raid start (beside state.before-last-raid.json);
  saves.settle files them as the slot's crew.lua / before-last-raid-crew.lua; activate puts the slot's crew.lua in play
  (a slot without one, i.e. every save from before this, keeps the crew in play); undo_last_raid restores the crew with
  the state. Export includes crew.lua (import doesn't read it yet).
- Tested: tools/test_crew_undo.py (CI), test_pvemode.py, launcher/test_ui.py, test_standin_flow.py. NOT tested in game:
  that hire.lua re-reads crew.lua at each launch (it's loaded per launch, so a relaunch is needed after Undo anyway).

## Crew gear from your stash (#418, 2026-11-25; launcher Crew gear, saves.set_crew_gear, hire.lua kitOf, crew.lua)
- Discord ask: give a hired crewmate gear from the stash so they don't go in without a helmet. Done: the launcher's
  CREW GEAR dialog (beside Kits) lists the save's hired crewmates and offers, per slot (gun, helmet, chest, bag), the
  stash items gear.lua lists for that slot (guns only with an ammo row, no LPOFlamethrower: the botGuns rule, #413).
- Storage: the item leaves state.json's stash and its row goes on the crewmate's record in the save's crew.lua as
  r.gear = { gun = row, helmet = row, chest = row, bag = row }. hire.lua H.kitOf(r) lays r.gear over the rolled r.kit
  (a gun row is looked up in Gear.guns for its ammo); crew.lua muster and the hire menu's kit line use it. A promotion
  re-rolls r.kit and leaves r.gear alone. Gear is theirs until they die (H.died drops the record) or are dismissed;
  setting a slot back to "Their own kit" returns the item to the stash (fresh condition: the stash string, condition
  and attachments, isn't kept on the crewmate). Refused while the save is in play; all or nothing (no room to return
  an item = nothing changes). Undo last raid stays consistent: state.json and crew.lua roll back together.
- The launcher reads/writes crew.lua with a small reader for what hire.lua ser() writes (saves._lua_load/_lua_dump);
  checked against real Lua (lupa) for strings with quotes, backslashes and newlines.
- A chosen helmet is worn even when it doesn't fit the face (Gear.fits): the player picked it. May clip (#195 look).
- Tested: launcher/test_ui.py CrewGear (equip, swap, return, refusals, full stash, reader round trip) and the dialog
  (opens with and without crew, APPLY moves a helmet). NOT tested in game: that a crewmate spawns wearing and holding
  the chosen gear (rivalbodies equipKit with the rows), and that the mod keeps r.gear through its own saves.
- Not done from #418: crew roles.

## Linux launch log, first Proton reports (#161, 2026-11-23)
- Report (Pöhlbert, CachyOS): `unable to load library steamclient64.dll` at PLAY with GE-Proton 10-34, 11-3, 11-7,
  Proton Experimental, Proton Stable and CachyOS's Proton; the stock game starts. Install output was correct.
- Ruled out here: pvenet.dll hooks only WinHTTP and name lookups (no LoadLibrary); steamclient64.dll, steam_api64.dll
  and steam_appid.txt (1789480) beside the Shipping exe are stock game files. libsteam_api.so is irrelevant: the game
  is a Windows exe under Proton, whose steamclient64 is Proton's lsteamclient bridge. The difference from a stock start
  is our swap of RaidGame.exe (EAC bootstrapper) for RaidGame-Win64-Shipping.exe in Steam's command: NOT yet known why.
- steam-run now writes backend/linux_launch.log every launch: Steam's command, Steam/Proton env (SteamAppId,
  SteamGameId, STEAM_COMPAT_*, PROTON_*, pressure-vessel paths, WINEDLLOVERRIDES), the command run, the game's and
  Proton's stdout/stderr, and the exit code. Tested by test_pvemode.py (Windows, WSL); not under real Proton.
- Second report (2026-11-23, Proton Experimental 11, CachyOS): Steam's PROTON_LOG shows our command ran
  (RaidGame-Win64-Shipping.exe, WINEDLLOVERRIDES dwmapi=n,b), dwmapi and UE4SS.dll loaded, UE4SS threw two caught C++
  exceptions, SteamAPI_Init loaded steamclient64 OK, then a message box (window class #32770 with a Button) came up and
  the game sat on it. Its text isn't in the log. UE4SS.log would say, but Folder.online() deleted it with the rest:
  it's now copied to backend/last_game.log first (the Windows launcher already did). Still unknown: what the box says.
  No linux_launch.log in the tester's backend/ although steam-run clearly ran: steam-run now prints the log's path to
  stderr (it shows in Steam's log) and creates backend/ if missing; maybe the launch option points at an older copy.
- Same tester: SETTINGS and NEW SAVE "don't open" in the launcher. Dialog.show() blocked in wait_visibility(), which
  waits for a VisibilityNotify a compositing window manager may never send. Reproduced once in three runs under WSLg
  (Wayland); now polled with winfo_viewable() before grab_set(). Also: Tk callback errors go to
  backend/launcher_errors.log (and the status line), and the report zip takes it and linux_launch.log.
  Tested: test_ui.py (Windows, 16 OK), the dialogs under WSLg; not on the tester's KDE.
- Third log, same day: Proton's Command was our Shipping exe followed by Steam's WHOLE chain (steam-launch-wrapper,
  reaper, _v2-entry-point, proton waitforexitandrun .../RaidGame.exe -nosplash): steam-run got %command% twice (the
  launch option as typed, probably) and game_command swapped the first RaidGame.exe, so the game ran with Steam's chain
  as arguments: that's the error box. game_command now runs only the last whole command and says so in the log.
  Tested by test_pvemode.py; not under real Proton.

## Mod keys off the game's voice lines (2026-11-24)
- The game binds Voice01-08 to F1-F8 (Saved/Config/WindowsNoEditor/Input.ini ActionMappings); NPCs react to those lines
  (#417 pity idea). Mod keys on F2, F3, F6 also played a line, and took the keys from players who use the voices.
  F9-F12 are unbound in the game; Steam's screenshot default is F12.
- Now: F10 AI tuning (was F3), F11 crew (was F6), F9 debug unchanged; your body (was F2) is a button in the F9 menu
  ("Your body: woman/man"); bridge/female_toggle still works. Every player-facing mention (in-game labels, launcher
  CONTROLS and settings text, README, release README.txt, raid_conditions.txt) says F10/F11; NOTES and CHANGELOG keep
  the old keys as history. Tested: launcher test_ui (16 OK), luacheck, ruff. Not tested in game: that F10/F11 reach
  UE4SS's RegisterKeyBind in the game window (F11 isn't a fullscreen toggle in a shipping build, per Input.ini; not seen
  run).
- 2026-11-25: the stock UE4SS ConsoleEnablerMod (enabled in config/mods.txt) set the game console's key to F10, so F10
  opened the console as well as the AI settings (log "[ConsoleEnabler] ConsoleKey[1]: F10"). It now uses Tilde (`).
  Fixed in PvEDirector (tools/ue4ss is the downloaded UE4SS, gitignored): keyhelp.lua consoleKey, every 5 s, puts
  InputSettings.ConsoleKeys[1] back on Tilde when it reads F10.

## Vendor stock (#384, 2026-11-24; vendors.lua, pvepatch.c pve_shop_add / pve_shop_price)
- The faction traders' extra stock is /Game/Blueprints/Factions/DT_FactionShops: one row per faction (United, Republic,
  Kingdom, Pirate, Guild), row struct FactionChangePerLevel { TArray<{float ShopDeduction @0; TArray<FName>
  AdditionalItems @8}> @8 }, one element per faction level (41; Pirate 42, Guild 5). Each level's list is the whole
  extra stock at that level; the base stock (Uzi, bandages...) comes from elsewhere. Shipped: 7-10 extras per faction
  by level 6, levels 11-40 copies of level 10, discounts 3% a level to 27% (Pirate and Guild 40% flat). Read live with a
  procmem dumper (RowMap @0x30: sparse array of 24-byte elements; FName pool as in tools/offline-audit/frigdata.py).
- Related UFunctions seen (not used): SIGISInventoryComponent Server_AdjustShopInventory, Client_AddShopItem,
  Client_RemoveShopItem, Client_StartShoppingMenu, Server_BuyItem; RaidPlayerController ClientShowShopInventory.
  ForEachProperty on these UFunctions errored in UE4SS (opaque error), so their parameters weren't read.
- vendors.lua adds 107 rows (guns, armour, helmets, bags from gear.lua, by faction; ammo with its first gun), level by
  price: <2500 -> 1, <5000 -> 3, <8000 -> 5, <11000 -> 7, else 9. Left out: heavy variants, Full Panzer/Sherman, boss and
  signature gear, radios, barrel bags, flamethrower. Arrays grow natively with GMalloc (never from Lua); old buffers
  are leaked, not freed. VENDOR_PRICE (Features, %) rescales every level's ShopDeduction: d' = 1 - (1 - d) x p.
- Verified in game (lobby, throwaway save): "vendors: 107 items added", the table read back with the new rows at
  every level (e.g. United 38 extras by level 7, Republic MG42/DP28/SVU at 9), no crash. NOT verified: the trader screen
  showing and selling them (couldn't open a trader from the bridge), and VENDOR_PRICE in the shop.
- 2026-11-24 (#449, #450, playtest): the Features row KEEP_PROGRESS_ON_DEATH had step 0 (meant as its default), so
  its slider could never leave 0: step is now 1. The key list stayed on screen (the F9 menu closes as it opens): F9 and
  Esc now close it (main.lua toggleDebug / an Esc bind, keyhelp.lua close/isOpen), and its title says so. Not tested
  in game.
- 2026-11-25 (#463): the trader screen is ONE fixed 10 x 11 grid (SHOPMainCon, InventoryGridSize Column 10 / Row 11,
  ~50 px cells, parent chain Overlay_55 < VerticalBox_TraderWindow < ... < CanvasPanel SHOP, no ScrollBox) showing
  every level's items at once (locked ones greyed). The first list needed 173-256 cells a faction, so most of it never
  showed. vendors.lua now orders each list most wanted first and cuts it to BUDGET cells (110 - ~30 base stock - the
  game's own extras - ~15% packing), logging "no room on the shop screen for ...": 27 rows instead of 107. Verified in
  game: the Pirate shop at rank 0 shows the added rows with empty cells to spare (screenshot via PrintWindow, TRADE
  opened with synthetic mouse clicks; computer-use key presses don't reach the game but SetCursorPos + mouse_event
  clicks do). Scroll bar / bigger grid: #464.

## K and J: ammo, ammo crates, equipment slots (#447, #448, #451, #452, 2026-11-24; invqol.lua)
- Written without the game (not run, not tested in game). What changed and what's assumed:
- #448 (K did nothing in ammo box crates, Ctrl+click worked): raidHovered only searched containers with SlotMasterType
  3 or 4, and "put it in the container" only looked for those. Likely cause: the crate's widget has another type. Now
  any shown container with SlotMasterType ~= 0 is loot, and an item that isn't in your inventory component
  (StashedItems) is taken with Server_CtrlClickItem(guid, "", its type; 3 if it reads 0). Not verified: the crate's
  real type or ContainerID (the K log line now names them: "raid: K takes <row> from <con> (type N)").
- #447 (ammo boxes like .32 ACP, row 32Ammo, didn't move): cause not found. Guess: the hovered widget's guid wasn't in
  the grid scan (scan() keys by the grid cells' Item), so K returned silently. The footprint now falls back to
  items.json (pockets.size) and the item under the mouse is also searched over every DraggableItemWidget; each K logs
  "stash: K moves <row> WxH from <con> to <con>" so the next report shows how far it got.
- #451/#452: equipped items (MotherItemGUID in Head, Chest, Legs, Rig, Bag, Prim, Sec, Pistol, Melee, KeyCard, Ship,
  GuildBadge: the stand-in's ONE_ITEM_SLOTS) are found through the generic DraggableItemWidget hover. K worn -> stash
  (lobby) or first pocket/bag grid with room (raid, never the bag's own grid); K on a gear item in a grid -> its empty
  slot via Server_MoveItem(guid, slot, {0,0}, 0, from, 0). Slot by items.json type (assumed from seed.json and row
  names): 0 Prim then Sec, 1 Pistol, 2 Melee, 4 Head, 5 Bag, 7 Rig (vests and rigs: seed has M1FlakChest in "Rig"),
  9 Chest, 11 Legs. Taken slot: K falls back to the old grid move. J on a worn item: Server_RemoveItem after two presses
  (lobby), Server_DropInHud (raid; #240's tests saw it empty Head).

## Stash SORT veil (#468, 2026-11-24; invqol.lua veilOn/veilTick)
- While SORT runs, a DebugInfo_Widget host (keyhelp.lua's pattern) with a full-screen black Border and a centred
  "Sorting..." TextBlock sits at viewport Z 5012, fading in over 0.15 s (SetRenderOpacity). Removed when the sort job
  ends (done, stopped, failed), after 8 s regardless, and dropped untouched on a world change; never rooted.
  `features.lua` SORT_FADE (F10 Features) turns it off. Only luacheck run: NOT tested in game (full-screen anchors via
  SetAnchors/SetOffsets are in a pcall with an 8000 px size as fallback; unverified which one takes).

## Field of view (#328)
- 2026-11-25, NOT tested in game. Features tab: FOV (0 = the game's own, 70-120) and ADS_ZOOM (1 = the game's aim zoom,
  0 = none, between = blend); mods/PvEDirector/Scripts/fov.lua, ticked every raid frame from main.lua (no new main
  local: `require("fov").tick`). ASSUMED: the view is the pawn's UCameraComponent (`FirstPersonCamera`, `Camera`, else
  GetComponentByClass) and the game's aim zoom narrows that component's `FieldOfView`; aiming = pawn `bIsTargeting`
  (+0x9e8, see Recoil). Values in FieldOfView that differ from the one we last wrote are taken as the game's; the hip
  value is remembered while not aiming, zoom = game/hip, written FOV = (FOV or hip) * (1 - ADS_ZOOM * (1 - zoom)).
  At defaults nothing is written (after a change back, the game's last value is restored once). Unverified: whether the
  aim FOV lives on the camera component at all (could be PlayerCameraManager SetFOV / DefaultFOV, or a FovModifier from
  VideoSettings.sav), and whether the helm/ship view uses another camera. Probe: `lua` read of pc.Pawn camera
  FieldOfView while aiming vs PlayerCameraManager.CameraCachePrivate.POV.FOV. Earlier draft: PR #345 (launcher file).
