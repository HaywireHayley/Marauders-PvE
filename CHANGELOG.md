# Changelog

Public test builds are on [GitHub Releases](https://github.com/HaywireHayley/Marauders-PvE/releases).

## Next build (not released yet)

- **Launcher:** tells you when a newer build is out (an orange **!** top right) and can update itself: it downloads
  the new zip, checks it, and installs it over the folder, keeping your saves and settings. Switch it off with
  **Check for new builds**. It starts working from the build after this one.
- **Launcher:** opening it twice no longer risks losing a raid's progress (the second one just brings the first
  forward). Closing it while you play asks first, and if you do, it saves your game and puts the online game back
  next time it opens. A damaged save shows as **DAMAGED** instead of disappearing, a save can be called "Nul",
  and a setting that can't be saved says so.

## Public test, 16 Nov 2026, build 3 (`public-test-20261116.3`)

A big one: about 25 changes since build 2. The headline fixes are **space salvage**, the **missing key card**, your
**crew gunner ignoring station turrets**, and the **interaction prompts** that went missing. There's also a
**Quit Game** button at last. Please read **Known issues** at the bottom before a long session.

### New in this build

#### Quit Game in the pause menu
**What happened:** there was no way to close the game from inside it. The pause menu's EXIT belongs to the "leave the
raid?" dialog, so testers were force-closing the game.

**Now:** press Esc in a raid and there's a **QUIT GAME** button under Main Menu. Click it once and it asks again
("CLICK AGAIN TO QUIT"). Click again within 4 seconds to close the game. Quitting mid-raid counts the gear you brought
in as lost, the same as Alt+F4; the launcher's **Undo last raid** brings it back.

- The lobby still has no quit button (tracked in #50).

#### START RAID
Offline there's no matchmaking: the lobby's button loads a raid straight away. It now says **START RAID**.

#### French female voice free from the start
**What happened:** you could play as a woman from the first launch, but every female voice cost credits (the cheapest,
FRENCH 02, was 3,500).

**Now:** FRENCH 02 is unlocked on every save. Pick it under **Loadout > Appearance > Voice**. Other voices keep their
prices and level requirements.

#### Your crew gunner tells you why they aren't shooting
If no turret on your ship can bear on the target for 3 seconds, your gunner says why, once:
- "**too far, close in**": the target is out of your guns' range;
- "**can't swing onto it, turn us toward it**": it's outside your turret's arc (the starter ship's single turret
  covers about 120° either side of the nose).

#### Also new
- **Gear tab in the F3 menu:** switch level-scaled enemy gear off, or make it tougher.
- **Launcher:** an option to skip the 60 s intro video. PLAY now checks what it needs before starting, and tells you
  why a launch failed.

### Fixed in this build

#### Space salvage works offline
**What happened:** flying up to a wreck never showed the salvage prompt, and R did nothing.

**Why:** the ship only starts its "is there salvage nearby?" scan on a network client. Offline your game is the
server, so the scan never ran.

**The fix:** the scan now starts offline too. Fly within about 15 m of a wreck and press **R**. The salvage lands in
your hold as a crate you can search with **F**, and the **lever** in the hold purges it so you can take another.
Tested end to end: capture, loot into your loadout, purge.

#### Interaction prompts missing (doors, contracts, ship panel)
**What happened:** "F" prompts on doors and contract objects, and the ship panel, often didn't show.

**Why:** the mod builds a HUD early for your loadout; the game later builds its own. Prompts kept going to the mod's
hidden copy.

**The fix:** once the game's HUD exists, prompts go to it. Please report any prompt that's still missing.

#### Missing captain's key card
**What happened:** sometimes you started a raid with no key card for your own ship, so after docking you couldn't get
back aboard. Reproduced with an empty loadout.

**The fix:** if no card has turned up 6 seconds after you board, the mod asks the game for one, using the same call
the game makes itself. Asking again never gives you a second card.

#### Crew gunner never shot station turrets
**What happened:** your gunner ignored the stationary turrets around stations, even while they shot you, and even if
you clicked one.

**Why:** a one-line bug made every stationary turret look already destroyed.

**The fix:** they now engage turrets that are aiming at you, and ones you click. In testing, a level 1 gunner took
out a flak turret in about 12 seconds. Station turrets outrange your ship's guns (about 13,500 vs 6,000-9,500
units), so close in and point your nose at them. Your gunner will now tell you if you're too far or facing wrong.

#### Also fixed
- **Health lost at the start of a raid:** you now spawn at normal speed, with no damage on arrival.
- **A crash when the intro was skipped:** PLAY now stays hidden until the backend login has finished.
- **Stray floating airlocks** from stations that aren't on the map this run are hidden (seen floating in open space
  on Space_Solo_02).
- **Bot heads:** the hidden decal head stays hidden when bots wake, for men and women, and swapped heads get their own
  material.
- **Escape pod:** the attachments (stock, magazine) of the guns hidden on your pod are hidden too.
- **Gear by level** counts levels the way the game does, and a new save stays at level 1.
- **Shorter hitch on first entering a station:** the mod shares its object scans there.
- **Land raids:** the minimap is skipped there, where it threw an error every frame.
- **Crew name tags** no longer leak memory over a long session.
- **Status line** says "aboard the <ship>" when you're on a rival's ship.

### Known issues

- **Crash using a station airlock after some time in a raid** (#53). Seen by a tester at every station they tried, and reproduced here,
  after some time in a raid or after an earlier raid in the same session; a quick in-and-out at the start doesn't
  trigger it. We've reproduced it and are tracking it down. Until then, **save your progress by extracting
  before long station runs**. If you crash, please share `backend\last_game.log` (written when the game closes) on
  the Discord.
- **A new save shows 10,000 credits, then 75,000** after the first stash change (#56). Harmless; we're deciding the
  intended starting amount.
- **Docking at Planet Killer** (Space_Charlie): the airlock may not take you through (#32).

### For contributors

- CI checks Lua syntax and Python compile on every push and PR.
- `scripts/setup-dev.ps1` sets up a dev checkout in one command.
- `bridge/profile_on` can now be switched on and off mid-raid (it used to be read only at launch), so
  `bridge/dir_eval.lua` works in a running raid.
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
