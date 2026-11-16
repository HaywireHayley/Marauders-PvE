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

## Play it: download the public test

**[Download the latest release](https://github.com/HaywireHayley/Marauders-PvE/releases/latest)**: open the page and
download `MaraudersOffline-<date>.zip` under **Assets**. The release notes list what's new and the known issues.

**You need:** Windows 10 or 11, Marauders installed through Steam (with Steam running when you play), and Python 3.9 or
newer (the installer can install it for you).

1. **Unzip** the folder somewhere permanent with a plain path, such as `C:\Games\MaraudersOffline`. Avoid Program Files
   and paths with non-English letters. Your saves live inside this folder.
2. **Double-click `Install.bat`.** It finds Python and the game, and adds a "Marauders Offline" shortcut to your desktop
   and Start menu. It doesn't touch the game folder.
3. **Start "Marauders Offline"**, make a save (NEW SAVE), pick it and press **PLAY**. Keep the launcher open while you
   play.

Your online game is safe: the launcher switches the game to offline mode only while you play, and puts every file back
to stock when you close the game. If your PC crashes mid-game, open the launcher once and close it again (or run
`Uninstall.bat`) before starting Marauders from Steam. Full instructions are in `README.txt` in the zip.

### Controls

The game's own controls are unchanged. The mod adds:

| Key | What it does | Where |
|---|---|---|
| **F6** | Your crew: hire, dismiss, and choose who comes on raids | Lobby and raids |
| **F3** | AI tuning: every enemy, rival and crew setting as a slider, including how many spawn | Lobby and raids |
| **F9** | Debug menu: god mode, extract now, spawn a soldier, and more | Lobby and raids |
| **N** | Minimap on or off | Raids |
| **M** | Minimap full overview, and back | Raids |
| **B** | Minimap: follow the next task | Raids |
| **F2** | Play as a woman or a man (also a launcher setting) | Anywhere |
| **Left click** | While flying with a crew gunner aboard: send them after the ship or space turret nearest the middle of your view. Click empty space to send them back to whoever is attacking you | Flying your ship |
| **F** on a turret seat | Man the turret yourself: left click fires, F stands you up | Ships |

### TOO DIFFICULT? Too busy or too quiet?

Every raid's population and difficulty can be tuned to your liking. Press F3 and open the How many tab: rival crews per raid, people in each crew, guards at each station, and how many ship battles break out around you. Rival ships sets how often crews attack and board, and Difficulty at the top picks a preset. Changes save themselves. Crew numbers take effect from your next raid, and guard numbers from the next station you visit. Save setups you like under Saved setups.

**Hold off game updates:** an update to Marauders is unlikely, but if one came it could break the mod. In Steam,
right-click Marauders → **Properties → Updates** and set it to **Only update this game when I launch it**. The mod's
launcher starts the game without going through Steam, so playing offline won't trigger an update.

### Known issues

- Rarely, dark flat slabs hang in space on the solo maps. ([#9](https://github.com/HaywireHayley/Marauders-PvE/issues/9))
- Dead boarders' legs can stretch into odd poses. ([#10](https://github.com/HaywireHayley/Marauders-PvE/issues/10))
- The status line can say "in space" while you're aboard another crew's ship. ([#11](https://github.com/HaywireHayley/Marauders-PvE/issues/11))
- There's a short hitch when you first enter a station. After a hitch, blue gaps can flash at the screen's corners.
  Fewer rival crews (F3) makes it rarer. ([#12](https://github.com/HaywireHayley/Marauders-PvE/issues/12))
- Space_Solo_02 now and then finds no stations, so that raid has no station tasks. ([#13](https://github.com/HaywireHayley/Marauders-PvE/issues/13))
- AI ships can get stuck on rocks or station hulls for a while. ([#14](https://github.com/HaywireHayley/Marauders-PvE/issues/14))
- Some explosion effects and sounds, and some extraction prompts, are missing offline. ([#15](https://github.com/HaywireHayley/Marauders-PvE/issues/15))

Soldiers on a station you haven't reached yet stay asleep until you get close. That's deliberate, to save performance.
All open known issues: [known-issue label](https://github.com/HaywireHayley/Marauders-PvE/issues?q=is%3Aissue+is%3Aopen+label%3Aknown-issue).

**Found a bug?** [Open an issue](https://github.com/HaywireHayley/Marauders-PvE/issues) and attach `backend\last_game.log`
and `backend\server.log` from your install folder, with a line on what you were doing.

---

# For developers

Everything below is for working on the mod itself. To just play, use the download above.

New here? Read [CONTRIBUTING.md](CONTRIBUTING.md) for how to send changes, and `NOTES.md` for how everything works
(it's the full research log, newest findings at the bottom of each section). Credits are in [CREDITS.md](CREDITS.md).

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

## Setting it up on your PC

1. **Have Marauders installed through Steam.**
2. **Install Python 3.9 or newer** from python.org, ticking "Add Python to PATH". Then, in a terminal:

   ```bash
   pip install pillow
   ```

   For the research tools under `tools/` you'd also want `pip install capstone numpy pycryptodome`. Playing doesn't need them.
3. **Get this repository** with GitHub Desktop (File → Clone repository). Put it in a plain folder like
   `C:\Mods\MaraudersPvE`.
4. **Tell it where the game is:** create `config\game_path.txt` containing one line, the folder that holds
   `RaidGame\`, for example:

   ```
   C:\Program Files (x86)\Steam\steamapps\common\PHtest
   ```

   (In Steam: right-click Marauders → Manage → Browse local files shows the folder.)
5. **Get UE4SS v3.0.1** from the [RE-UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v3.0.1)
   (`UE4SS_v3.0.1.zip`) and unzip it into `tools\ue4ss\`, so that `tools\ue4ss\dwmapi.dll`, `tools\ue4ss\UE4SS.dll`
   and `tools\ue4ss\Mods\` exist.
6. **Play:** run `python launcher\launcher.pyw`, make a save and press PLAY. Closing the game puts the game folder
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
