# Offline audit: game code that never runs in singleplayer (2026-10-31)

The shipped client only ever ran as a **network client** of a dedicated server. Offline (standalone) the game is
its own server: every actor is `Role == Authority (3)`, `GetNetMode() == NM_Standalone (0)`, `IsServer()` is true,
and **nothing replicates**, so `OnRep_*` callbacks never fire unless code calls them. Code written as "clients do X"
therefore silently skips X offline. That is what broke recoil and bullet impacts.

This audit scanned the live game (read-only) for every such spot:

| Pass | What it looks for | Found |
|---|---|---|
| Native gates | `Role` compares (`[actor+0xF0]`, `GetOwnerRole`), `GetNetMode` compares, `IsStandalone` early-outs in RaidGame + SIGIS code | 263 gates in ~220 functions (9 already patched) |
| Uncalled OnReps | native `OnRep_*` whose implementation nothing calls | 50 of 60 |
| BP events | which Blueprint events those paths fire, and whether anything else fires them | 22 named |
| Blueprints | authority / net checks in the bytecode of all 691 loaded Blueprint classes | 41 functions |

Raw results and the re-runnable scripts are in `tools/offline-audit/` (see the end).

## Already fixed
pvepatch.dll: FireWeapon trace/projectile RPCs, SimulateWeaponFire cosmetics, recoil ammo gate, trace + projectile
bullet impacts, instant/melee hit reacts, vault/climb animations, the 4 SIGIS loot-copy early-outs, bot death body.
PvEDirector: near-miss whizz (hook on ServerTraceMultiFireProjectile), broken-weapon effect (calls
OnRep_WeaponHasBroken when the held gun breaks).

## Combat-feel pass (2026-10-31): results
- Explosions: **not broken**. Off a client, OnRealImpact calls Explode (0x1883cf0), which spawns the explosion actor
  itself; a summoned Proj40mm showed Pfx_Explosion_40mm active at the impact. OnRep_Exploded is only for remote
  clients. (The scanner listed Explode as "skipped": its skipped-side listing reads linearly and can be wrong.)
- Hit reacts: guns were already covered by the impact patch (base RaidWeapon's simulate-hit slot +0x850 is empty).
  RaidWeapon_Instant and its subclass (melee/tools) un-gated: 0x189b74c, 0x189bbdf. OnProxyHitReact exists on the
  GOAP raider bots (masterNodeBot), not on BotPawn soldiers. Not tested with a melee weapon.
- Whizz: un-gating 0x1898df0 doesn't help (it also requires the shooter pawn to have NO controller: true only for
  other players' pawns on a client; offline every bot has one) and double-runs impacts. The director plays it
  instead: a bot shot whose line passes within 2 m of the camera calls ClientBulletWizzPastHead. Verified with a
  faked bot shot (BulletWizzPastHead fired); not yet heard with a real bot shooting at the player.
- Vault/climb: 0x180c648 un-gated; NetMultiVault(false/true) now fire PlayVaultAnimations / PlayClimbAnimations.
- Broken weapon: verified, BrokenWeaponEvent fires once when bBroke turns on. It really breaks the gun (won't fire).

## Likely broken offline: highest confidence first

Confidence: **certain** = the only code path that triggers it is skipped offline; **likely** = skipped offline, but
server code *might* do the same work some other way; **check** = a gate whose direction/meaning needs a look.

### Combat feel
1. ~~Grenade / 40mm / ship-shell explosions~~ (checked 2026-10-31: they work; see results above). Original note: `RaidGrenadeProjectile`, `RaidProjectile`, `RaidShipProjectile`
   `OnRep_Exploded` and `OnRep_BulletHit` hold the effect code (traces + spawns, ~190 instructions each) and nothing
   calls them. `RaidShipProjectile::OnBulletHit` and `RaidProjectile::OnBulletHit/OnImpact/OnRealImpact` also have
   `NetMode == Client` sections that are skipped. Expect missing explosion FX/sound for grenades and ship guns.
2. **Hit reactions on characters** (certain/likely): `OnProxyHitReact` (flinch/blood on whoever is hit) is only fired from four
   `NetMode == Client` functions; two are now patched (trace + projectile impacts), `0x189b340` and `0x189b800` are
   still gated (probably melee / multi-pellet variants). `RaidCharacter::OnRep_LastTakeHitInfo` (the classic
   ShooterGame "play hit on remote characters") is never called.
3. **Bullet near-miss whizz** (certain): `BulletWizzPastHead` is only fired from the three `WizzVolumeOverlapped`
   (skipped when Authority), two `NetMode == Client` functions and the client RPC. No whizz sounds offline.
4. **Vault / climb animation** (certain): `PlayClimbAnimations` is only fired by `RaidCharacter::NetMultiVault`,
   which skips it when Authority.
5. **Broken-weapon effect** (certain): `BrokenWeaponEvent` is only fired by `RaidWeapon::OnRep_WeaponHasBroken`.
6. **Shotgun multi-trace** (check): `RaidWeapon::ServerTraceMultiFireProjectiles_Implementation` has a `NetMode == Client`
   section (gets the local controller; likely whizz/impact cosmetics for pellets).
7. **Weapon attachments** (likely): all 7 `RaidWeapon::OnRep_Current*Slot` jump to the attachment refresh
   (`0x18799f0`) and are never called. Changing attachments mid-raid may not update the gun.

### Space / ships
8. **Ship system damage** (certain): `OnEngineDestroyed`, `OnHelmGunDestroyed`, `OnTurretDestroyed`, `OnSpaceSalvageChange` are only fired from
   `RaidSpaceshipInside::OnRep_*`, and turret nodes' `HealthChanged` only from `RaidSubNodeActor_Turret::OnRep_Health`.
   Destroyed-engine/turret/helm-gun visuals (and anything the Blueprints disable there) never happen offline.
9. **Manning a turret** (certain): `DrivingTurret` is only fired by `RaidCharacter::OnRep_SetGunning`.
   Done 2026-11-08 by mods/PvEDirector/Scripts/gunseat.lua (aim, fire, stand up); see NOTES "Manning a turret yourself".
10. Ship anim Blueprints (strike/fast/frigate/capital/VIP/starter/drop pod) all call `IsServer`; see the Blueprint section.
    (Doors, hangar state and unlocks are also fired by server-side code, so those look fine.)

### Raid flow / UI
11. **Raider and guild evac** (likely): `RaidPlayerController::EnterEvacRaiderEscape` / `EnterEvacGuildEscape` skip `EvacRaiderRaid` when Authority
    (its only callers). `EnterEvacRaidVolume`, `LeaveEvacRaidVolume`, `LeaveEnterSpaceAtmosVolume`,
    `LeaveSpaceRaidVolume` skip a widget/HUD call when Authority. Expect missing evac prompts/countdowns.
12. **Contracts** (likely): `SIGISContractActor::CharacterOverlapped`, `SIGISGenericActor::ContractCharacter(End)Overlapped`
    and `ShouldShowContractInteraction` skip their client part when Authority. Contract objectives/prompts may not show.
13. **Voice lines** (check): `RaidCharacter::PlayVoiceSound` skips playback when Authority; `RaidPlayerCharacter::PlayVoiceLine`'s
    non-authority side holds `OnPlayVoiceLine`.

### Inventory (SIGIS)
14. **More standalone early-outs like the loot bug** (likely): `Client_AddItem`, `Client_AddLobbyItem`, `Client_BatchAddItems`,
    `SIGISPlayerController::Client_LoadBatchAddItems` (via `0x980f70`) skip creating the client item copy when standalone (the 4 loot
    versions are patched). Items added this way may not appear in the grid.
15. `LootAmountItem`, `LootMoveItem`, `LootCompRemoveItem`, `LootRemoveItem`, `LootRemoveBatchItems`, and two click
    handlers under `PrimClickUnPressed`, each skip one call when standalone (check: probably UI refreshes when moving loot).
16. `Server_MoveItem` / `Server_MoveLobbyItem` helpers (`0x8ed530`, `0x8ed6d0`) have `NetMode == Client` parts.

### Characters
17. **Gear meshes** (likely): `RaidCharacter::OnRep_SetHead / OnRep_ServerSetChest / OnRep_SetBag` (set the helmet/vest/bag mesh)
    and `RaidNodeBot::OnRep_SetBody/SetFace` are never called. Bots' and the player's worn gear may not show.
18. `SetGuildArmBadge` is fired by one other function too, so probably fine.

### Blueprints that check `IsServer` (true offline)
Typically "if IsServer, skip cosmetic work". If so, offline skips it (direction not verified per Blueprint):
- `rc_FPS_AnimBP` (player first-person anim: 7 checks, plus **`PlayFootstepSound`**) and `rc_AI_FPS_AnimBP` (bots: 7)
- `AnimBP_*` for every ship and the drop pod; `ABP_StrikeFrigate`
- `MA_RotatingParent_Simple / _WithAmbience` (rotating props, ambient sound), `Base_Broken_OneShots_Parent`
- `Proj40mm` (grenade launcher round)

`HasAuthority` / `GetLocalRole` appear in ship pawns, turrets, mines, raid nodes, cruisers, camera turret, contract
hold, object spawner and `PlayerPawn`; those usually gate server gameplay, which runs offline, but their "remote"
branch (client cosmetics) does not.

## Limits
- Functions Denuvo moved into `.xcode` were not scanned.
- Inlined OnRep logic, or server code doing the same thing by another route, can make an item a false alarm. That
  is why the "certain" ones are only those whose triggering event has no other caller.
- Identical-code folding makes a few names wrong: e.g. `CraftingWidget::GetRecipeIcon` in the evac functions is
  a shared one-line getter, not crafting.
- Blueprint findings say where a check is, not which way it branches.
- Only classes loaded at scan time were covered (a Spaceport raid). Space-only Blueprints that weren't loaded are missing.

## Fix approach (per item, verify each in game)
- Native gate: NOP the branch in `pvepatch.c` after checking the skipped side contains no Server RPC (un-gating an
  RPC call runs it locally and can double-apply or recurse, e.g. StartFire `0x189c100`).
- Uncalled OnRep: call the OnRep (or its Blueprint event) from the director when the replicated value changes, or
  patch the server-side setter to call it.
- Blueprint `IsServer`: hook the function or patch the bytecode branch per Blueprint.

## Re-running
Game running offline (menu is enough for natives; be in a raid for Blueprints). Scripts take output paths:
`objs.py natives.json` → `impl.py natives.json` → `names.py natives.json names.json` → `gates.py names.json gates.json`
→ `onrep.py natives.json` → `bpev.py bpev.json <addrs>` → `bpauth.py`. They read the module base and
`GUObjectArray` from UE4SS.log and names from `dumps/UE4SS_ObjectDump.txt`; `bpauth.py` reads the live FName pool
(address taken from `FName::ToString`, RVA `0x58ceb40` in this build). `data/review.txt` is the per-function gate
list with the calls each skipped side makes.
