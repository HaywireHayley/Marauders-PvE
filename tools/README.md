# tools/: research and build tools

Nothing here is needed to play. These are how we find out what the game does, since there's no source code or
documentation: we read its Blueprint bytecode and machine code from the running game and from its paks.

| Folder | What it's for |
|---|---|
| `release/` | `build_release.py` makes the player zip; its install/uninstall scripts and README ship inside it |
| `offline-audit/` | Blueprint bytecode tools. `kdis.py` decompiles a function from live memory; `bpbranch.py` and friends find code that only runs on clients or behind `OnRep_*` callbacks, which never run offline (see its README and OFFLINE_AUDIT.md) |
| `profile/` | Machine-code side: disassembling around a crash address, sampling hot threads, finding string references |
| `armour_test/` | In-game damage and armour measurements (see DAMAGE_REFERENCE.md) |
| `minimap/`, `make_minimap_art.py` | Minimap images, including aligning Ahtu's illustrated maps |
| `female/`, `headfit/` | Build the optional female outfits from your own copy of the game |
| `coop/` | Co-op research hooks |
| `test_*.py` | Tests for the stand-in backend and ship handling |
| `ue4ss/` | Where `setup-dev.ps1` puts UE4SS (downloaded, not committed) |
