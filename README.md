# Marauders Offline (PvE)

**[Join the Discord](https://discord.gg/nfEW8tFJ3b)** to test new builds, report bugs, or help develop the mod.

A fan mod that keeps **Marauders** playable on your own PC, with no live servers: single-player PvE against AI soldiers,
rival crews in their own ships, and a hired crew of your own. Everything runs locally. Nothing talks to the live
Marauders servers.

Marauders is made by a small UK team. This mod is not affiliated with the developer or publisher. You need your own copy
of Marauders on Steam.

> **Heads up:** this mod is vibe coded with [Claude Code](https://claude.com/claude-code). Some of it may not be fully
> efficient or make complete sense. That's where your contributions come in: see [CONTRIBUTING.md](CONTRIBUTING.md), or
> come and talk about it on the Discord.

## What's new compared to the original game

Most of the work so far has gone into getting the original game working offline: its servers, raids, stations,
salvage and docking. Along the way the mod has also added things the live game never had:

**Raids built for PvE**
- **Rival crews run by AI** instead of other players: they fly their own ships, dock at stations, fight each other in
  ship battles, attack your ship, board it, and extract when the raid runs out.
- **Your own hired crew** (F6): hire and dismiss crewmates who come on raids with you, fight alongside you, and man a
  turret as your gunner. Left click while flying picks the gunner's target.
- **Civilians:** unarmed miners, prisoners and port workers at the mines, the Penal Colony and the ports.
- **Defuse mines** with a ToolKit, in a Minesweeper-style minigame: station mines on foot, small space mines from the
  helm, and **nuclear mines you tow home** and defuse in your hold (lose, and it takes the ship with it). Win and you
  keep the parts.
- **Board and take rival ships**, and **repair ships with the blowtorch**: a disabled ship (yours, or a wreck you took)
  comes back to life part by part until it flies again.
- **Wrecks tell a story:** a ship shot down holds the crew who went down with it, as lootable corpses, and sometimes a
  survivor or two who fight on.
- **Smarter soldiers:** they reload, take cover, take head, body and leg damage, and their helmets and vests protect
  them by how good they are. A shotgun volley knocks them back.
- **Guards lose their leader:** when a station's guard leader is shot down, the rest break off and run away from you for
  25 to 40 seconds, and fight only if you get close.
- **A death screen** that says who killed you, with what and from how far, and your last three hits. It's a best guess
  from the shots just before, so it can be wrong when several bots fire at once.

**Make the raid you want**
- **F3 AI tuning:** every enemy, rival and crew setting as a slider: how many crews, guards and ship battles, how hard
  they fight, and difficulty presets.
- **Loot density:** F3's **Loot** tab sets how much floor loot spawns and how much is in each body, from 0 (none) to 3
  times the usual. Ammo in bodies and loot in containers are not changed.
- **Settings before a raid:** the launcher's **SETTINGS** button shows every F3 setting by tab, with the difficulty
  levels and your own presets: save a setup, export it to a file to share, import a friend's. Changes save as you make
  them. The game reads them when it starts, and F3 still works in a raid. (The list fills in after the game has started
  once with this build.)
- **Raid conditions:** one-raid set-ups such as Baron hunt, Hunted, Busy sky, Capital ships and Minefield. Make your own
  and share them.
- **Pick your map** in the lobby's REGION box, and the **raid length** in the launcher (15 minutes to no limit).

**Getting around**
- **A minimap** (N, M, B) with floor plans of the stations, your tasks, and a route to where you're going.
- **Minimap marks:** a grey X where the bots you killed fell, a bag where you dropped an item with J, and blue dots for
  your living crewmates.
- **Lore in raids:** a line from the lore on the raid loading screen, and a line when you first reach a station or ship
  (it shows above the minimap for a few seconds).
- **A faster Rustbucket** and a **boost** (Space) at the helm of any ship.
- **Play as a woman or a man** (F2): women's versions of every outfit, for you and for the soldiers, with voices.
- **Hidden outfits** the menus never listed (two long coats and a bloodied Blood Raider suit): F9 in the lobby.

**Inventory and lobby**
- **Stash tools:** SORT, a search box, and SELL SHOWN at a trader.
- **K and J hotkeys** move or discard the item under the mouse, in the lobby and while looting in a raid.
- **Your gear comes back** if a raid ends without an extraction or death (a crash, Alt+F4, quitting).
- **An offline guild** with its own guild shop, and a launcher option to **unlock every look and voice**.

**Launcher and tools**
- Several saves, **back up and import**, and give items or credits to a save.
- **REPORT** bundles your logs and crash report into one zip for a bug report, with your names and IDs taken out.
- **One small download:** the installer zip fetches the rest, and the launcher **updates itself** when a new build is
  out (only the parts that changed).
- **Co-op (early):** host a raid and let a friend join it, aboard your ship: you fly and fight together and extract
  through the gate together, each into your own save, and the friend gets the minimap too.
- **F9 debug menu:** god mode, unstuck, no collision, extract now, and spawn any gun, ammo or soldier.
- **Linux and Steam Deck** support (experimental).

## Quick start

1. **[Download the latest release](https://github.com/HaywireHayley/Marauders-PvE/releases/latest)**: open the page
   and, under **Assets**, download **`MaraudersOffline-<build>-installer.zip`** (a few KB) on Windows: its installer
   fetches everything else for you. On Linux, or to install by hand, download every other zip instead. The release
   notes list what's new and the known issues.
2. Follow the steps for your system below. Both need **your own copy of Marauders installed through Steam**, and
   **Python 3.9 or newer** (Windows: the installer can get it for you; SteamOS already has it).

Your online game is safe either way: the game folder is switched to offline mode only while you play the mod, and every
file is put back to stock when the game closes.

### Windows 10 / 11

1. **Unzip** the folder somewhere permanent with a plain path, such as `C:\Games\MaraudersOffline`. Not Program Files,
   and no non-English letters in the path. Your saves live inside this folder, so don't delete it. (By hand instead of
   the installer zip: the main zip plus the `-deps-` zips are one folder split up, so extract them all into one place.)
2. **Double-click `Install.bat`.** From the installer zip it first downloads the latest build from GitHub (about
   60 MB, every file checked). Then it finds Python (or offers to install it), finds the game, and adds a
   **Marauders Offline** shortcut to your desktop and Start menu. It doesn't touch the game folder.
3. **Start Steam**, then open **Marauders Offline** from the shortcut.
4. In the launcher, click **NEW SAVE**, give it a name, and click **CREATE**. (Tick "lots of gear and infinite money"
   for a test save with a full stash.)
5. Pick the save and press **PLAY**. **Keep the launcher open while you play**: it saves your game and puts the game
   folder back when the game closes.
6. In the game's lobby, gear up in LOADOUT, pick a map and press **START RAID**. Get out alive through an extraction to
   keep what you carry.

**Updating:** when a new build is out, an orange **!** appears top right in the launcher. Click it and **UPDATE**: it
downloads the new build (and only the big parts that changed), checks every file, installs it over the folder and
restarts. Your saves and settings are kept. Switch it off with **Check for new builds**.

**Back to the online game:** close the offline game, then launch Marauders from Steam as usual. If your PC crashed
mid-game, open the launcher once and close it again (or run `Uninstall.bat`) first.

**Something wrong?** Press **REPORT** in the launcher: it zips your logs (and the crash report, if the game crashed)
for you to attach on the [Discord](https://discord.gg/nfEW8tFJ3b) or in a
[GitHub issue](https://github.com/HaywireHayley/Marauders-PvE/issues). "The game didn't start": check Steam is running,
and run `Install.bat` again if the game moved.

### Linux / Steam Deck (experimental)

Not yet tested under real Proton: if you try it, please say how it went in
[#127](https://github.com/HaywireHayley/Marauders-PvE/issues/127) or on the Discord. Steam's own **PLAY** button starts
the mod through a launch option, so it works from Game Mode on a Deck too. The launcher window (saves and settings) is
optional on Linux: it's there in Desktop Mode if your Python has Tk and Pillow.

1. **Unzip** the folder somewhere permanent, e.g. `~/Games/MaraudersOffline`. Internal storage is safest; spaces in the
   path are fine, non-English letters aren't. On a Deck, do this in **Desktop Mode**.
2. **Open a terminal in that folder** and run:

   ```bash
   sh linux/install.sh
   ```

   It finds the game in your Steam libraries (SD cards included) and prints one line, like
   `"/home/deck/Games/MaraudersOffline/linux/marauders-offline.sh" %command%`.
3. In Steam: **Marauders → Properties → General → Launch options**, paste that line.
4. Press **PLAY** in Steam (Game Mode works). The first time, a save called "Save 1" is made for you. In the game's
   lobby, gear up, pick a map and press **START RAID**.

**The launcher window (Desktop Mode, optional):** if your Python has Tk and Pillow (most desktop Linux does; SteamOS
doesn't: `python3-tk` and `python3-pil.imagetk` on Debian/Ubuntu), `install.sh` adds **Marauders Offline** to your app
menu. It's the same launcher as on Windows: make, back up, import and pick saves, give items, settings, REPORT. Its
**PLAY** picks the save and asks Steam to start Marauders, and the launch option does the rest; it tells you when your
game is saved. Without Tk, use the `pvemode.py` commands below; PLAY in Steam works either way.

**Steam Deck controls:** the mod's keys (see Controls below) are keyboard keys, so give them buttons in Steam Input:
Marauders → **controller icon → Edit layout**. Start from Steam's **Keyboard (WASD) and Mouse** template (or the game's
own controller support if it works for you) and add:

| Deck control | Key | Mod action |
|---|---|---|
| **L4** (back grip, upper left) | F6 | Your crew menu |
| **R4** (back grip, upper right) | F3 | AI tuning menu |
| **L5** (back grip, lower left) | N | Minimap on or off |
| **R5** (back grip, lower right) | M | Minimap overview |
| **D-pad down** | B | Minimap: follow the next task |
| **View (⧉) + D-pad left** (or a radial menu) | K | Move item between stash and bags (in a raid: between you and what you loot) |
| **View (⧉) + D-pad right** (or a radial menu) | J | Discard item (press twice; in a raid: drop it) |
| **Right trackpad** | mouse, click = left click | The F3 / F6 menus and the stash are mouse-driven |

F9 (debug) and F2 fit on a radial menu on the left trackpad if you want them. Not tried on a Deck yet: if you set it
up, please share what worked in [#127](https://github.com/HaywireHayley/Marauders-PvE/issues/127) (Steam can also share
a layout as a community layout).

**Saves** (in a terminal, in the folder):

```bash
python3 scripts/pvemode.py saves
```

```bash
python3 scripts/pvemode.py new "Test save" --cheat
```

`saves` lists them (`*` marks the one PLAY uses), `use <id>` picks one, `new <name>` makes one (`--gear` for a full
stash, `--money` for infinite money, `--cheat` for both).

**Back to the online game:** clear the launch option, or switch the mod off and keep the launch option for later:

```bash
python3 scripts/pvemode.py steam off
```

(`steam on` switches it back.) If the game is killed or the Deck loses power mid-game, the next PLAY puts the game
folder back to stock before anything else.

**Something wrong?** Press **REPORT** in the launcher window and attach the zip it makes. Without the launcher window,
attach `backend/last_game.log` and `backend/server.log` from the folder instead. Post either in
[#127](https://github.com/HaywireHayley/Marauders-PvE/issues/127) or on the Discord.

### Controls

The game's own controls are unchanged. The mod adds (the launcher's CONTROLS button shows the same list):

| Key | What it does | Where |
|---|---|---|
| **F6** | Your crew: hire, dismiss, and choose who comes on raids | Lobby and raids |
| **F3** | AI tuning: every enemy, rival and crew setting as a slider, including how many spawn | Lobby and raids |
| **F9** | Debug menu: god mode, extract now, spawn a soldier, and more | Lobby and raids |
| **N** | Minimap on or off | Raids |
| **M** | Minimap full overview, and back | Raids |
| **B** | Minimap: follow the next task | Raids |
| **K** | Move the item under the mouse between your stash and your pockets or bags; in a raid, between your gear and the crate or body you're looting | Lobby (LOADOUT, TRADE), raid |
| **J** | Discard the item under the mouse (press twice); in a raid, drop it on the floor | Lobby (LOADOUT, TRADE), raid |
| **F2** | Play as a woman or a man (also a launcher setting) | Anywhere |
| **Left click** | While flying with a crew gunner aboard: send them after the ship or space turret nearest the middle of your view. Click empty space to send them back to whoever is attacking you | Flying your ship |
| **Space** | Boost: your ship jumps to nearly twice its top speed for 4 seconds, then needs 12 seconds to recharge (like the drop pod's). The Rustbucket is also a quarter faster than it was | Flying your ship |
| **F** on a turret seat | Man the turret yourself: left click fires, F stands you up | Ships |
| **F** by a mine, with a **ToolKit** | Defuse a station mine, or the nuclear mine in your hold (a Minesweeper board) | On foot |
| **R** by a space mine | Small mine (with a ToolKit): defuse it in place. Nuclear mine: take it aboard into your hold | At the helm |
| **Blowtorch** (fire) at a ship part | Repair your ship: the life-support pipe in the engine room, the helm gun or the engine. Broken parts first, then the hull | Aboard your ship |

### TOO DIFFICULT? Too busy or too quiet?

Every raid's population and difficulty can be tuned to your liking. Press F3 and open the How many tab: rival crews per raid, people in each crew, guards at each station, and how many ship battles break out around you. Rival ships sets how often crews attack and board, and Difficulty at the top picks a preset. Changes save themselves. Crew numbers take effect from your next raid, and guard numbers from the next station you visit. Save setups you like under Saved setups.

### Civilians

Mines, prisons and ports have a few miners, prisoners or workers going about their business. They're unarmed: they
run from you, cower and plead when cornered, and carry things of their trade. Kill one where the guards can see and
they come for you. F3 > How many sets how many (0 turns them off).

### Co-op (early)

Play a raid with a friend: one of you hosts, the other joins and comes aboard the host's ship.

1. Both of you: the same mod build, your own save, and a shared network. Same house: nothing to do. Anywhere else:
   ZeroTier (free, a setup script for Windows and Linux) or Hamachi, see [docs/COOP.md](docs/COOP.md).
2. Host: launcher > **CO-OP** > tick **Host: friends can join my raids**, note the address it shows, then **PLAY**
   and **START RAID**. Allow the game through Windows Firewall (Private and Public) the first time.
3. Joiner, once the host is aboard in the raid: launcher > **CO-OP** > type the host's address > **JOIN**. The game
   connects from the title screen by itself.

The full guide, with troubleshooting, is [docs/COOP.md](docs/COOP.md). Early and lightly tested: tell us how it goes.

### Raid conditions (events)

Want a different raid for one run, or a community event? Pick **Raid conditions** in the launcher (click to cycle), or
in the game's lobby: open the REGION box and click the conditions button under the maps (each click picks the next).
They last the raid; your own F3 settings come back after it.

- **Baron hunt:** the Red Baron is in the raid and goes for any ship he sees.
- **Hunted:** every rival crew attacks any ship it sees and boards when it can.
- **Busy sky:** twice the crews, and bigger battles between them.
- **Capital ships:** a Capital Ship and a Dreadnought, crewed to fight to the end.
- **Baron's last stand:** Charlie, the Baron, a Dreadnought and every crew out for blood.

Harder conditions put more and better loot on bodies. Make your own in `config/my_raid_conditions.txt` and share
the file with friends: `config/raid_conditions.txt` explains the layout.

**Hold off game updates:** an update to Marauders is unlikely, but if one came it could break the mod. In Steam,
right-click Marauders → **Properties → Updates** and set it to **Only update this game when I launch it**. The mod's
launcher starts the game without going through Steam, so playing offline won't trigger an update.

### Known issues

- The airlock may not take you through after docking at Planet Killer (Space_Charlie). ([#32](https://github.com/HaywireHayley/Marauders-PvE/issues/32))
- The map's own AI patrol ships can't be boarded yet (rival crews' ships can). ([#70](https://github.com/HaywireHayley/Marauders-PvE/issues/70))
- Thin gaps of light can show through some walls and airlocks, mostly while the camera turns fast. ([#190](https://github.com/HaywireHayley/Marauders-PvE/issues/190))
- Co-op is early: flying, turrets and boarding as the joiner are still lightly tested. ([#214](https://github.com/HaywireHayley/Marauders-PvE/issues/214))

Soldiers on a station you haven't reached yet stay asleep until you get close. That's deliberate, to save performance.
All open known issues: [known-issue label](https://github.com/HaywireHayley/Marauders-PvE/issues?q=is%3Aissue+is%3Aopen+label%3Aknown-issue).

**Found a bug?** Press **REPORT** in the launcher. It saves one zip to your Desktop with the logs, the crash report if
the game crashed, and your build number. Your Windows user name, Steam ID and in-game name are taken out first.
[Open an issue](https://github.com/HaywireHayley/Marauders-PvE/issues) or post on the Discord with that zip and a line on what you were doing.

**Stutter?** Send the report right after the raid where it happened. During a raid the log gets a `frames:` line every
10 seconds: the worst gap between frames, how many frames ran over 50, 100 and 200 ms, and the slowest parts of the
mod's own work. Stutter that grows over a raid shows up there, where an average frame rate would hide it.

---

# For developers

Everything below is for working on the mod itself. To just play, use the download above.

New here? Read [CONTRIBUTING.md](CONTRIBUTING.md) for how to send changes, and `NOTES.md` for how everything works
(it's the full research log, newest findings at the bottom of each section). Every damage and armour number (health, hit zones, vest and helmet ratings, base damage per gun, shotguns) is in [docs/internals/DAMAGE_REFERENCE.md](docs/internals/DAMAGE_REFERENCE.md). Credits are in [CREDITS.md](CREDITS.md).

## How it works, in one paragraph

[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) loads our Lua mods into the game. `scripts/mode.ps1 offline` copies
UE4SS and our mods into the game folder and points the game's backend at this PC. `backend/nakama_standin.py` is a
small local server that answers what the real backend used to (account, stash, loadouts). `native/pvenet.dll` and
`native/pvepatch.dll` are small helpers the mods load. `mode.ps1 online` puts every game file back to stock.

## Folder map

| Folder | What's in it |
|---|---|
| `mods/PvEDirector/Scripts` | The mod itself: AI (`ai.lua`, `rivals.lua`), crew, missions, minimap, loading screens... `main.lua` is the entry point |
| `mods/PvEBridge` | Dev bridge: lets scripts outside the game send commands into it (`scripts/send.sh`) |
| `backend/` | The local stand-in server. `seed.json` is the anonymous starting account |
| `launcher/` | The launcher window (saves, settings, Play) |
| `native/` | C helpers. Only `pvenet.dll` and `pvepatch.dll` are needed to play; the rest are research tools |
| `scripts/` | Switch online/offline, launch, bridge helpers. `pvepaths.py` tells Python tools where things are |
| `assets/` | Our art: loading screens, minimap images, menu logo |
| `config/` | Mod settings. `game_path.txt` (yours, not shared) says where the game is installed |
| `tools/` | Research and build tools: `release/build_release.py` makes the player zip |
| `cover/` | Cover points per map, for the AI |

Most folders have a short README of their own. `backend/README.md` has diagrams of how the game's online services are
replaced offline, and why that takes so much guessing.

## Setting it up on your PC

1. **Have Marauders installed through Steam**, and **Python 3.9 or newer** from python.org (tick "Add Python to PATH").
2. **Get this repository** with GitHub Desktop (File → Clone repository). Put it in a plain folder like
   `C:\Mods\MaraudersPvE`.
3. **Run the setup script** in a terminal, from the repository folder:

   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-dev.ps1
   ```

   It installs the Python packages (`requirements.txt`), finds the game in your Steam libraries and writes
   `config\game_path.txt`, and downloads UE4SS v3.0.1 into `tools\ue4ss\` (checked against a known SHA-256). It doesn't
   touch the game folder, and it's safe to run again. Add `-Research` to also install what the research tools under
   `tools/` and `scripts/luacheck.py` need (`requirements-research.txt`).

   <details><summary>Doing it by hand instead</summary>

   - `pip install -r requirements.txt` (and `-r requirements-research.txt` for the research tools).
   - Create `config\game_path.txt` with one line, the folder that holds `RaidGame\`, e.g.
     `C:\Program Files (x86)\Steam\steamapps\common\PHtest` (in Steam: right-click Marauders → Manage → Browse local
     files shows it).
   - Unzip `UE4SS_v3.0.1.zip` from the [RE-UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v3.0.1)
     into `tools\ue4ss\`, so that `tools\ue4ss\dwmapi.dll`, `tools\ue4ss\UE4SS.dll` and `tools\ue4ss\Mods\` exist.

   </details>
4. **Play:** run `python launcher\launcher.pyw`, make a save and press PLAY. Closing the game puts the game folder
   back to stock.

If anything goes wrong, this always puts the game back to its normal, online-safe state:

```bash
powershell -NoProfile -File scripts\mode.ps1 online
```

## Not in this repository (on purpose)

The game's own files and anything extracted from them, the pak decryption key, captured traffic from real accounts,
personal saves and settings, and trailer tooling and recordings. `.gitignore` keeps them out. Please never add them.

Optional extras you can make yourself from your own copy of the game: the female outfits
(`tools/female/make_female.py`, which needs the pak key: `scripts/find_aes.py` finds it in your own install).
