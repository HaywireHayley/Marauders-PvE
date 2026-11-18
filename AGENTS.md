# Guide for AI agents

Start with [README.md](README.md) ("For developers": how it works, folder map, setup) and
[CONTRIBUTING.md](CONTRIBUTING.md) (ground rules). [NOTES.md](NOTES.md) is the project's memory: before changing a
system, search it for that system's section, and add what you learned to the section it belongs to (dated, with the
issue number, what was verified and what wasn't).

## Ground rules (from CONTRIBUTING.md, restated because they're the ones that matter most)
- Offline only. Nothing here may touch live Marauders matches or servers.
- Never commit game files, extracted assets, the pak key, captures, logs, crash dumps or saves. `.gitignore` covers the
  usual paths; if `git status` shows one anyway, leave it unstaged and say so.
- Leave the game folder stock: closing the game through the launcher does it, otherwise
  `powershell -NoProfile -File scripts\mode.ps1 online`.

## Git and GitHub
- `upstream` is HaywireHayley/Marauders-PvE (the parent: PRs and issues go there); `origin` is the contributor's fork.
- Sync before starting: `git fetch upstream && git merge --ff-only upstream/master`, then push master to origin.
- One branch and one PR per issue (`fix/<issue>-<slug>`, `feat/<issue>-<slug>`), opened against upstream `master`
  with `Fixes #N`. The PR body says what was wrong, what changed, and how it was tested, including what was **not**
  tested in game.
- CI (`.github/workflows/check.yml`) runs `scripts/luacheck.py` on every Lua file and compiles every Python file.

## Checks before a PR
- Lua: `python scripts/luacheck.py <files>` (needs `pip install lupa`). It catches Lua's **200-locals limit**:
  `main.lua` is at it. Add new helpers to a module, a table, or as a global function (as `addInteriorNav` does), not
  as another top-level `local`.
- Python: `python -m py_compile <files>`. The launcher can be driven headless the way `launcher/test_launcher.py`
  does it (it screenshots the window and dialogs).
- In game is the real test. Use a throwaway save (the launcher's new-save dialog, "lots of gear" for a cheat save),
  never the user's main save. The game copies `mods/` at launch, so Lua changes need a relaunch.

## Talking to the running game
- `scripts/send.sh "status"` / `"lua <code>"` (Git Bash) go through the PvEBridge mod; replies land in
  `bridge/out.txt`. `"lua"` code runs on the game thread.
- **A bad probe crashes the game.** Calling a method on a null or freed object wrapper faults natively inside UE4SS,
  and `pcall` can't catch it. Check `o ~= nil and o:IsValid()` before any method call, prefer plain property reads,
  and don't call `GetClass()` or `ForEachProperty` on function parameters.
- Logs after a session: `backend/last_game.log` (the mod), `backend/server.log` (the Nakama stand-in).

## Engine pitfalls that already cost crashes
- **Offline the game is the authority.** Native `OnRep_*` callbacks and client-only branches never run, so Blueprint
  effects hung on them (doors, panels, prompts) silently don't happen. Call the `OnRep_*` yourself or patch the branch
  (examples: salvage, #134; salvage scan timer in `native/pvepatch.c`).
- **Kept references go stale.** Objects freed by map travel or streaming crash whatever touches them later; check
  through `valid()` (it uses `pve_alive` before `IsValid`) and drop per-world state on world change (#53).
- **Never `pve_root` anything whose outer chain reaches a world.** A rooted object keeps its outer alive, and
  `CreateRenderTarget2D(ctx)` / `NewObject(ctx)` make the world context object the outer; a leaked world comes back
  broken on the next map load (#133). Use the game instance as the context for anything kept across maps.

## Reading crash reports
- Player reports (`MaraudersOffline-report-*.zip`) hold `crash/CrashContext.runtime-xml`, the minidump and both logs.
  Extract each into its own empty folder. Compare `PCallStackHash` first: the same hash means the same crash however
  the players describe it.
- Frames are `module + offset`; disassemble `RaidGame-Win64-Shipping.exe` (path in `config/game_path.txt`) at that RVA
  with capstone. `tools/profile/disasm.py` reads live memory; static reads map the RVA through the PE section table.
  String references nearby (`"GAME="`, `"Salvage"`) usually name the engine function. A UE4SS frame with Lua frames
  above it is mod code; one with only game frames above it is UE4SS passing a hooked call through.
- Crash reports and logs can contain players' account IDs: don't paste those into issues.
