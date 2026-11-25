# tools/: research and build tools

Nothing here is needed to play. These are how we find out what the game does, since there's no source code or
documentation: we read its Blueprint bytecode and machine code from the running game and from its paks.

| Folder | What it's for |
|---|---|
| `release/` | `build_release.py` makes the player zip; its install/uninstall scripts and README ship inside it |
| `offline-audit/` | Blueprint bytecode tools. `kdis.py` decompiles a function from live memory; `bpbranch.py` and friends find code that only runs on clients or behind `OnRep_*` callbacks, which never run offline (see its README and OFFLINE_AUDIT.md) |
| `profile/` | Machine-code side: disassembling around a crash address, sampling hot threads, finding string references |
| `recoil_test/` | In-game recoil measurements: the view's climb shot by shot for the automatic guns, single shot guns and pistols, aimed and at the hip, plus the weapon sound test (see NOTES.md, recoil and shotgun sound) |
| `armour_test/` | In-game damage and armour measurements (see DAMAGE_REFERENCE.md) |
| `launcher_test/` | Fires the China Lake and the Mini Thumper by itself and logs whether a round goes off in your hands (see docs/internals/LAUNCHERS.md) |
| `space_test/` | F9 test tools for space maps: start a space raid, spawn turrets, mines, explosions and wrecks, kill them and log what appears, read the salvage chain (see docs/internals/SPACE_OBJECT_DEATH.md) |
| `minimap/`, `make_minimap_art.py` | Minimap images, including aligning Ahtu's illustrated maps |
| `female/`, `headfit/` | Build the optional female outfits from your own copy of the game |
| `coop/` | Co-op research hooks |
| `test_*.py` | Tests for the stand-in backend and ship handling |
| `ue4ss/` | Where `setup-dev.ps1` puts UE4SS (downloaded, not committed) |
