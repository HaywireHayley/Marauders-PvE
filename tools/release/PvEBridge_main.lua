-- PvEBridge (release build): points the game's backend at the local stand-in, nothing else.
-- native/pvenet.dll sends Nakama to backend/nakama_standin.py while bridge/offline_backend exists. Loaded here, at mod
-- start, so the menu's login is covered too. (The development build also reads commands from bridge/cmd.txt.)
local PROJECT = require("pveproject") -- the install folder (".../MaraudersOffline/"), written by scripts/mode.ps1

local f = io.open(PROJECT .. "bridge/offline_backend", "r")
if f then
    f:close()
    local ok, err = package.loadlib(PROJECT .. "native/pvenet.dll", "*")
    print("[PvEBridge] pvenet " .. (ok and "loaded" or ("failed: " .. tostring(err))) .. "\n")
else
    print("[PvEBridge] bridge/offline_backend is missing: the game will try the live servers\n")
end
