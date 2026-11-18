# scripts/: switching modes, launching, and talking to the running game

| Script | What it's for |
|---|---|
| `setup-dev.ps1` | One-time setup on a new PC (Python packages, finds the game, downloads UE4SS) |
| `mode.ps1 offline / online / status` | Puts UE4SS, the mods and the offline PGOS config into the game folder, or puts every file back to stock. `online` is always the safe way back. `pvemode.py` is the same for Linux |
| `launch-offline.ps1`, `launch-helpers.ps1` | Start the stand-in backend and the game in offline mode without the launcher |
| `send.sh`, `bsend.sh`, `waitfor.sh` | Send a command (`"status"`, `"lua <code>"`) into the running game through the PvEBridge mod; replies land in `bridge/out.txt` |
| `luacheck.py` | Lua syntax check plus headroom under Lua's 200-locals limit (CI runs it) |
| `pvepaths.py` | Tells the Python tools where the game and this repository are |
| `find_aes.py`, `find_aes_mem.py`, `capture_seed.py`, `gbase.py`, `procmem.py`, `udpstr.py`, `quitsite.py`, `find-game.ps1` | Research: the pak key from your own install, a seed from your own capture, reading process memory |

The `.sh` scripts run in Git Bash on Windows; the `.ps1` ones in PowerShell (`powershell -NoProfile -File scripts\mode.ps1 online`).
