# Changelog

Public test builds are on [GitHub Releases](https://github.com/HaywireHayley/Marauders-PvE/releases).

## Public test, 16 Nov 2026, build 3 (`public-test-20261116.3`)

### New in this build

- **Quit Game in the pause menu.** Press Esc in a raid and there's now a QUIT GAME button under Main Menu. Click it
  once and it asks again ("CLICK AGAIN TO QUIT"). Click again within 4 seconds to close the game. Quitting mid-raid
  counts the gear you brought in as lost, just like Alt+F4 (the launcher's Undo last raid brings it back).
- **French female voice free from the start.** You could play as a woman from the first launch, but every female
  voice cost credits. FRENCH 02 is now unlocked on every save. Pick it under Loadout > Appearance > Voice.
- **Gear tab in the F3 menu:** switch level-scaled enemy gear off, or make it tougher.
- **Launcher option to skip the 60 s intro video**, and the launcher now checks what PLAY needs before it starts and
  tells you why a launch failed.

### Fixed in this build

- **Captain's key card missing.** Sometimes you started a raid without your ship's key card and couldn't get back
  aboard after docking (seen with an empty loadout). If no card shows up a few seconds after you board, the mod now
  asks the game for one.
- **Your crew gunner ignored station turrets.** A bug made every stationary turret look already destroyed, so your
  gunner never shot them, whether on its own or when you clicked one. Now they engage turrets that are shooting at
  you. Your hull's guns reach less far than station turrets (about 6,000-9,500 vs 13,500 units), so close in, and
  point your nose at the turret.
- **Space salvage and missing HUD prompts.** Interaction prompts (doors, contracts, the ship panel) were drawn on a
  hidden copy of the HUD, and salvaging in space never started. Both work offline now. Please report any prompt that's
  still missing.
- **Stray floating airlocks** from stations that aren't on the map this run are hidden (stray
  geometry seen floating in open space on Space_Solo_02).
- **Health lost at the start of a raid:** you now spawn at normal speed, with no damage on arrival.
- **Bot heads:** the hidden decal head stays hidden when bots wake, for men and women, and swapped heads get their own
  material.
- **Pod guns:** the attachments (stock, magazine) of the guns hidden on your escape pod are hidden too.
- **Gear by level** counts levels the way the game does, and a new save stays at level 1.
- **Station entry hitch is shorter:** the mod shares object scans when you first walk into a station.
- **Land raids:** the minimap is skipped there, where it threw an error every frame.
- **Status line** says "aboard the <ship>" when you're on a rival's ship.

### For contributors

- CI checks Lua syntax and Python compile on every push and PR.
- `scripts/setup-dev.ps1` sets up a dev checkout in one command.
- NOTES.md has the co-op join findings and the station survey log.

## Public test, 16 Nov 2026, build 2 (`public-test-20261116.2`)

The only change from the 16 Nov build is the Mini Mine fix below. (The first 16 Nov zip had been replaced in place
with one carrying this fix; build 2 gives it its own release, so anyone holding an early download can tell.)

### Fixed: crash after taking a pod to the Mini Mine

**What happened:** if you took a pod to a station you have to board, like the Mini Mine, the game could crash a few
moments after you got out. It happened twice in testing (15 Nov, and on 16 Nov with the Just Deserts contract), both
with the same crash signature.

**Why:** this wasn't the pod itself. It was the mod's contract tracking. At the start of each raid the mod
(`mods/PvEDirector/Scripts/missions.lua`) scans the map once for contract objects (the things you inspect, hold or
deliver to for a contract) and used to keep a direct reference to each one. The game can delete and replace those
objects later in the raid, for example when a station's contents load in as you arrive. The mod's reference then
pointed at memory that had already been freed. When you came within range of the contract, the mod checked whether
the object was still valid, and that check read the freed memory and crashed the game. A pod drops you right next to
the station's contract objects, which is why it showed up there.

**The fix:** the mod no longer holds on to the objects. The scan now saves each contract object's *name in the
game's world* (its object path) instead. Every time the mod needs the object, to check whether you're standing in a
hold area, inspecting something, or pressing Use on it, it looks the object up again by that name. If the game has
replaced or removed the object, the lookup returns nothing or the new live copy, and the mod never reads stale memory.

- Changed: [`missions.lua`](mods/PvEDirector/Scripts/missions.lua): the scan stores `path` instead of `actor`, and a
  new `live()` helper finds the current object with `StaticFindObject` on each use (hold-area check, inspect, Use).
- Contracts behave as before. Only how the mod finds their objects changed.
- Status: in this build. The exact Mini Mine pod run hasn't been repeated in game since the fix, so please report it
  in the Discord if it still crashes there, with `backend\last_game.log` and `backend\server.log`.

## Public test, 16 Nov 2026 (`public-test-20261116`)

### Fixed in this build

- Your shotguns work. Before, the player's shotgun fired but its pellets did no damage.
- The social overlay is hidden within a second or two of the lobby loading.
- Start Matchmaking gets you into your ship about 4 s sooner.
- Bots' heads fit their helmets, with no merged or clipping headgear.
- Berths held by wiped-out crews are freed for other ships.
- You get camera control as soon as you arrive in a raid, without pressing Tab.
- Rival ships no longer circle their exit point forever.
- Crashes on raid load, space stutter, fight hitches and a stash overflow past 25 rows are fixed.

### New in this build

- Crew hiring and wages cost half as much while we test how useful crew are.
- Left-click while flying to send your crew gunner after the ship or space turret nearest the middle of your view.
  Click empty space to send them back to whoever is attacking you.
