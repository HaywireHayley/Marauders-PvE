-- The folder of this player's offline save: the stand-in's state.json, loadout.json, checkout.txt and the ship files,
-- and the crew save. Normally <project>/backend/; a co-op joiner started by scripts/launch-joiner.ps1 has its own
-- (env PVE_BACKEND), so it neither takes gear out of the host's stash nor writes its raid back into the host's save.
local dir = os.getenv("PVE_BACKEND")
if not dir or dir == "" then return require("pveproject") .. "backend/" end
dir = dir:gsub("\\", "/")
if not dir:match("/$") then dir = dir .. "/" end
return dir
