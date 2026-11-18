# native/: small C helpers loaded into the game

Lua can't touch the game's network calls or machine code, so a few small DLLs do it. The mods load them with
`package.loadlib(path, "*")`, which only runs their `DllMain`. Nothing on disk in the game folder changes; every patch is
in memory and checks the original bytes first, so a game update makes a patch skip itself instead of crashing.

| File | Needed to play? | What it does |
|---|---|---|
| `pvenet.c` → `pvenet.dll` | yes | Redirects the game's Nakama traffic to `backend/nakama_standin.py` and blocks every other live host (see `backend/README.md`) |
| `pvepatch.c` → `pvepatch.dll` | yes | Offline-only code patches: client-only branches the game skips when it's its own server, timers that never start |
| `pvenative.c` | no | Research helper with a command file, for reading and calling things the Lua side can't |
| `pveeac.c`, `pveudp.c`, `pvetrace.c`, `pvestacks.c`, `tracelaunch.c`, `probe.c` | no | Diagnostics (co-op join handshake, a second copy quitting, hung-process stacks). Logs go to `capture/` |

Build with `build.sh` (MinGW-w64 GCC). The two DLLs needed to play are committed so players don't need a compiler.
