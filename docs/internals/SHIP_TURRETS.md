# Ship turrets: damage, helm aim and the gun seat

How a ship turret shot becomes damage offline, how a helm shot is aimed, and how every turret kind was checked at the helm. Written
2026-11-22 from measurements in game (offline install, public test build 23), on the branch `fix/ship-turrets`.
The research log with the reasoning is the section "Ship turrets: damage and helm aim" in
[NOTES.md](../../NOTES.md); this file is the lookup. The code is `turretdamage.lua`, `helmaim.lua`, `gunseat.lua`, with hooks
in `rivals.lua`, `rivalships.lua` and `main.lua`.

Every number says where it came from: **Measured** (read in game on a test install), **Game file** (read from the cooked
turret and shell blueprints with `tools/offline-audit/ueprops.py`, or a running game's class defaults), or **Code read**
(the shipping exe, disassembly).

## 1. The ten turret kinds

All are Blueprints under `/Game/Blueprints/Ships_Extras/Turrets/`, class name `<name>_C`, parent `RaidCharacterTurrent`
(C++ `ARaidCharacterTurrent`). A ship holds its turrets in `ship.SpawnedTurretArray` (Lua index 1 is native index 0).

| Kind (class name) | Impact | Explosion | Total set by `turretdamage.lua` | Measured shell reach |
| --- | --- | --- | --- | --- |
| Singular (`InGame_Turret_SingleTurret01`) | 20 | 45 | 65 | hits at every range tested (to 900 m) |
| Dual 25mm (`InGame_Turret_Dual25mm01`) | 20 | 50 | 70 | to 900 m |
| 75mm (`InGame_75mm_Turret01`) | 50 | 120 | 170 | to 900 m |
| Triple (`InGame_Turret_TrippleTurret01`, the game's spelling) | 65 | 90 | 155 | to 900 m |
| Howitzer (`InGame_Turret_Howitzer01`) | 100 | 125 | 225 | to 900 m |
| Flak (`InGame_Turret_FlakCannon01`) | 15 | 70 | 85 | self destructs near 183 m |
| Rocket Artillery (`InGame_Turret_RocketArtillery01`) | 15 | 70 | 85 | to 900 m |
| Dual Rocket (`InGame_Turret_DualRocket01`) | 150 | 85 | 235 | runs out near 820 m |
| Torpedo (`InGame_Turret_TorpedoLauncher`) | 300 | 300 | 600 | slow; tested to 200 m |
| Nuclear (`InGame_Turret_NuclearLauncher`) | | | 3100 | slow; 50 m blast radius |

Impact is the projectile's `HitDamage`, explosion its `ExplosionDamage`. The Impact and Explosion columns are the totals
minus the measured explosion loss in section 2 (what a hull lost per shot offline is exactly the Explosion column).
Nuclear's impact and explosion were not split out: the total 3100 comes from the game's assets, and one shot takes a hull whole either way.

The Rustbucket (`Ship_StarterFrigate01_Pawn_C`) carries exactly one turret, a Singular. Bigger hulls carry more
(`rivals.lua` `CFG.HULLS`, `Soc_Turret01`, `Soc_Turret02`, ...). That is why the helm check mounted its own test turrets
(section 6): the Rustbucket alone would only ever test the Singular.

## 2. Damage: the impact half of a shot never lands offline

Test: a Scout frigate (hull 650) spawned 20 m ahead of the Rustbucket, a turret of each kind fired 5 projectiles one at a
time, the hull reset to 650 before each, the drop read over 3 s. **Measured:** every shot of every kind lost exactly its
explosion part and none of its impact part:

| Kind | Hull lost per shot offline | Listed total |
| --- | --- | --- |
| Singular | 45 | 65 |
| Dual 25mm | 50 | 70 |
| 75mm | 120 | 170 |
| Triple | 90 | 155 |
| Howitzer | 125 | 225 |
| Flak | 70 | 85 |
| Rocket Artillery | 70 | 85 |
| Dual Rocket | 85 | 235 |
| Torpedo | 300 | 600 |

The same at 20 m and 55 m. Every turret's projectile is affected, the AI's too. A first run with a hull of a million read
"lost 999350" on every shot because the game clamps a hit back to the hull's own maximum, so tests use the real hull.

What was ruled out:
- `GameplayStatics:ApplyDamage` straight on a hull works, so the hull side is fine.
- Writing `bDoesExplode = false` on the live projectile changed nothing: still exactly the explosion number, 0.12 s after
  the shot.
- **Code read** (impact function at 0x14188fa20 in `RaidGame-Win64-Shipping.exe`): on an impact the projectile takes the
  hit actor, passes the `NetMode == Client` gate when standalone, then calls the victim's virtual `TakeDamage` (vtable
  +0x590) with an integer damage (`HitDamage` at +0x228, or the value at +0x264 when the byte at +0x249 is set). The call
  is not gated off offline, yet the impact damage does not show up on `MainHullHealth`. Why that native `TakeDamage` never
  lands is still open, and the fix does not wait on it.

### The fix (turretdamage.lua)
The explosion half does land, so `ProjectileConfig.ExplosionDamage` is set to impact plus explosion:
1. On each turret class's default object (`cls:GetCDO().ProjectileConfig.ExplosionDamage`), so every turret made afterwards
   has it, the mod's fitted ones included.
2. On the turrets already on your ship (their own copy), looked at every 5 s because turrets can be fitted a little after a
   raid starts.
3. On the AI's turrets when `rivalships.lua` builds them (`rivals.lua` `TURRET_TYPES` now carries a `damage` per kind, and
   `fitTurrets` writes it), so both sides hit for the same numbers.

Classes nothing has used yet are not loaded; `turretdamage.update` asks for them with `LoadAsset` and sets them a few
seconds later (up to 6 tries). **The game unloads a turret class nothing is using and loads it fresh later, which puts the
class default back.** The aim test hit this: fresh Triple, Howitzer, Flak and Dual Rocket test turrets did only the old
explosion numbers (90, 125, 70, 85). So every 5 s `update` reads the class defaults of the loaded classes and sets any
that read wrong (log line `full turret damage: <name> class set again after a reload`).

Blast radius, fire rate and reload are untouched. `turretdamage.lua` `CFG.FULL_DAMAGE = 0` turns the whole thing off.

Confirmed: fresh turrets landed exactly 65, 70, 170, 85 and 600 after the fix, a Scout shot at the helm dies from the
expected number of hits, and the Nuclear launcher takes a hull whole.

## 3. Helm aim: where a shot goes

At the helm a shot flies a straight line from the barrel (no drop at any tested range, to 900 m).

- **Helm click.** `RaidFrigate:ServerFireFrigate` fires `SpawnedTurretArray[0]` only when that turret's `ControllerHere` is
  null (nobody "controls" it). The mouse moves the control rotation; camera yaw equals control yaw, camera pitch equals
  control pitch minus 10; the ship lags toward the control rotation. The barrel mesh points about 15 to 17 degrees up and
  does not follow the view (visual only, not changed).
- **The error.** The camera sits about 1.5 m above the barrel, so a shell flown parallel to the view line is **1.49 m below
  it at every distance** (measured from 35 m to 136 m): about 11 px low at 222 m on a 2560x1440 screen at 90 degrees of
  field of view, 2 to 3 px at 1 km. The game bends the shot toward whatever its own check finds under the crosshair (about
  1 degree up at 90 m); with nothing under the crosshair the shot stays parallel. So the reticle was right at one distance
  only, and at the distance a player cares about (a ship in front of them) the shell passed under the point they aimed at.
- **The fix (helmaim.lua, v3).** A pre hook on `/Script/RaidGame.RaidCharacterTurrent:ServerFireProjectile(Origin,
  Direction, SocketIndex)`. When the call comes from the helm click (a flag set by a hook on `ServerFireFrigate`, valid
  for 0.05 s, and the controller's pawn is the turret's `MyFrigateOwner`) the **origin is left alone** and the
  **direction** is replaced. A `LineTraceSingle` (channel 0, from 15 m out to 3000 m along the camera ray, your own ship
  excluded) finds what is under the crosshair, and the shell is aimed from the barrel at that point, or at the 3 km point
  on the ray when nothing is hit. The shot therefore passes through the crosshair at the distance of whatever you aim at,
  and its trail still starts at the turret.
- **Rejected: v2.** Moving the origin onto the view line hit dead on, but the trails then started at the reticle.
- Crew gunners and rival ships are not touched: the flag and the controller check make it your helm click only.
- `helmaim.lua` `CFG.ON = false` leaves the game's shots alone.
- The camera's location and rotation come from `pc.PlayerCameraManager:GetCameraLocation()` and `GetCameraRotation()`;
  the view direction is `(cos p cos y, cos p sin y, sin p)` with the camera pitch p and yaw y in degrees.

UE4SS notes learned here: `originP:set({X=,Y=,Z=})` and `dirP:set(...)` work in a pre hook. A hook on a game UFunction is
safe. Hooks on engine sound functions, and probes that sweep every widget or property, crashed the game (the probe that
read every Image brush did).

## 4. The gun seat

Pressing F on a turret seat makes you the turret's controller: `pawn.MYTurret = turret`, `turret.ControllerHere = pc`, and
the view moves to the turret's camera (`pc:SetViewTargetWithBlend(turret, 0.3, 0, 0, false)`). `gunseat.lua` then turns
the camera, fires the turret's own `ServerFireProjectile` at its `FireRate` while the left mouse button is held, and stands
you up on F. Its aim (`shotDir`) asks `helmaim.aimDir` first, so the gun seat shot passes through the crosshair at the
distance of the target like the helm shot; the old fixed convergence point (`CFG.AIM_RANGE`, 600 m) is only the fallback when
the trace fails.

## 5. Firing every turret from the helm (how the test did it)
The helm click natively fires only turret 1. For the check of every kind the test probe (not shipped) fired each turret itself:
1. Turret 1 got `ControllerHere = pc` for the length of the test. That is the same trick `crew.lua` `holdTurrets` uses for a
   gunner, and it stops the native helm click from also firing it. It was put back afterwards (only if still your controller).
2. While the left mouse button was held, the probe called `turret:ServerFireProjectile(origin, direction, socketIndex)`
   directly: origin is the barrel socket (`turret.TurretBarrelMesh:GetSocketLocation(FName(socket))`, the sockets read
   from `turret.FiringSockets`, taken in turn for multi barrel turrets), direction is `helmaim.aimDir(ship, origin,
   cameraLocation, viewDirection)`. The next shot was allowed `turret.FireRate` seconds later.

## 6. Mounting a test turret of every kind
The Rustbucket has one turret, and swapping the hull of the ship you fly mid raid is not supported (a failure at the helm can
drop you out of the raid), so the probe mounted one of each kind: `ship:GetWorld():SpawnActor(class, shipLocation, rotation)`,
`K2_AttachToComponent(ship.Mesh, FName("Soc_Turret01"), 2, 2, 2, false)` (rules 2 are snap to target), scale 1.25,
`MyFrigateOwner = ship` and `SetOwner(ship)`: the recipe `rivalships.lua` `fitTurrets` uses. A class the game has unloaded is
loaded again with `LoadAsset("<path>.<name>")` and looked up as `<path>.<name>_C`. Afterwards the test turrets were destroyed
with `K2_DestroyActor`. Order fired: the ship's own Singular, then Singular, Dual 25mm, 75mm, Triple, Howitzer, Flak, Rocket
Artillery, Dual Rocket, Torpedo, Nuclear (aimed 100 m or more away: 50 m blast).

## 7. In game results

### Aim test (2026-11-22, 240 shots, 0 errors)
A spawned Scout was put on the camera ray at 75, 200, 500 and 900 m in open space (1500 m clear), the view held and the
ship frozen, and every kind was fired along six view directions: level (two headings), up 30 degrees (two), down 30
degrees (two). Kinds: the real helm click, then a fresh turret of each of the ten (Torpedo and Nuclear only to 200 m).
A shot counts as a hit when the Scout's hull drops.
- 216 of 240 hit. All 24 misses are Flak at 200, 500 and 900 m (all 24 shots) or Dual Rocket at 900 m, and they are the
  same on every direction: the shell was seen ending about 183 m short at any range for Flak (it self destructs near
  183 m) and about 82 m short at 900 m for Dual Rocket (it runs out near 820 m). That is the weapons' own reach, not the
  aim: both hit at every shorter range.
- Every other kind, helm click included, hit at every distance and direction.

### Every kind at the helm (2026-11-22)
- On foot, gun seat: seated at the Rustbucket's turret ("you man ... (1 barrel(s), 5 rounds)"), shot, stood up, everything
  back to normal.
- At the helm, 11 turrets: the ship's own Singular plus the ten test turrets (section 6), 5 shots each through the reticle.
  Chandler ran it and every kind worked.

## 8. Test pitfalls

- The game unloads turret classes it is not using, so a plain `SpawnActor` of a cold class throws; load it again and wait.
- The player's mouse moves the camera and slides a target off the ray, so aim tests hold the control rotation.
- A probe that wraps `Space.podFrame` must release it, or it keeps freezing the ship and locks the mouse.
- Live Lua without a restart: while `bridge/profile_on` exists the director runs `bridge/dir_eval.lua` once inside its own
  Lua state, deletes it, and writes the result to `bridge/dir_eval.out`. A probe swaps fields of the live module table
  (`for k,v in pairs(new) do old[k]=v end`) so the running frame loop picks up new code. UE4SS hot reload is off.
- A file written to a staging folder takes a few seconds before a device commit reads the new content; check the copy
  before trusting the run.
- Flak and Dual Rocket shells end early by design (section 1). Do not read that as a miss.

## 9. What is where

| Piece | File |
| --- | --- |
| Full damage, class defaults and turrets on your ship | `turretdamage.lua` |
| AI turret damage | `rivals.lua` `CFG.TURRET_TYPES[*].damage`, `rivalships.lua` `fitTurrets` |
| Helm and gun seat aim | `helmaim.lua`, `gunseat.lua` `shotDir` |
| Hook wiring and reset on a new raid | `main.lua` (`TurretDamage.init/reset`, `HelmAim.init`) |
