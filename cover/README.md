# cover/: baked cover maps for the AI, one file per map

`cover.lua` bakes these as you play: a grid of navmesh points, each traced in 8 directions at crouched and standing
eye height, so soldiers know where something solid is beside them (full cover, low cover, lean-out corners). A cell is
baked the first time a fight needs it and saved here, so `git status` often shows one of these changed after a raid:
commit a map's file only when you mean to ship better cover for that map.
