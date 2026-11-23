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
| `vtprobe.c` | no | Co-op research (#26): finds engine objects by vtable, samples a net connection on a shared clock, hardware write/execute breakpoints that log the call stack and any FStrings on it. Commands and build line at the top of the file |

Build with `build.sh` (MinGW-w64 GCC). The two DLLs needed to play are committed so players don't need a compiler.

`build.sh [target] [suffix] [outdir]` builds one target (default `pvenative`) or `all` three, into `native/` unless
`outdir` is given. It uses `$CC`, else `x86_64-w64-mingw32-gcc`, else `gcc` (WinLibs from winget on Windows; on
Linux `apt install gcc-mingw-w64-x86-64`).

| Target | Command line it runs | Links |
|---|---|---|
| `pvepatch` | `gcc -shared -O2 -Wall -Wextra -o pvepatch.dll pvepatch.c` | kernel32 + CRT only |
| `pvenet` | `gcc -shared -O2 -Wall -Wextra -o pvenet.dll pvenet.c -lws2_32` | ws2_32 (WinHTTP is hooked through import tables, not linked) |
| `pvenative` | `gcc -shared -O2 -Wall -Wextra -DPVE_ROOT=... -DPREFIX="native<suffix>" -o pvenative<suffix>.dll pvenative.c` | kernel32 + CRT |

`sh native/build.sh pvepatch` overwrites the committed `pvepatch.dll`; commit it only together with the `.c` change.
CI (`check.yml`) cross-compiles all three to a temp folder on every push, so a `.c` change that doesn't compile fails
there; it never replaces the committed DLLs. The other `.c` files have their build line in their header comment.
