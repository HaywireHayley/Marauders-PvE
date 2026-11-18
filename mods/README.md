# mods/: the UE4SS Lua mods

UE4SS loads these into the game; `scripts/mode.ps1 offline` copies them into the game folder (the game copies
`mods/` at launch, so Lua changes need a relaunch).

| Mod | What it is |
|---|---|
| `PvEDirector/` | The mod itself. `Scripts/main.lua` is the director (settings, the tick, hooks, keys); every system lives in its own module: `bots.lua` soldiers, `rivals.lua` rival crews, `launch.lua` matchmaking, `loadout.lua` gear in and loot out, `levelprops.lua`, `minimap.lua`... AGENTS.md says which owns what |
| `PvEBridge/` | Loads the native DLLs and lets scripts outside the game send commands in (`scripts/send.sh`) |
| `PvEQuitProbe/` | Diagnostic for the game quitting on its own |
