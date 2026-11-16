-- tools/coop/coop_hooks.lua: the co-op join trace from NOTES.md "Co-op join: who drops, and what never fires".
-- Copy into bridge/ (or bridge2/) and load from each copy: scripts/bsend.sh <dir> "lua return dofile(\"<project>/bridge/coop_hooks.lua\")"
-- Observation only: each hook logs a name, a time and an object address. It never blocks, changes or answers a call, and
-- never reads RPC params (heavy hooks freeze the join; FText params can't be read by UE4SS 3.0.1 at all).
local dir = os.getenv("PVE_BRIDGE") or (require("pveproject") .. "bridge/")
if not dir:match("[/\\]$") then dir = dir .. "/" end
local LOG = dir .. "coop_trace.txt"
local t0, c0 = os.time(), os.clock()
local function stamp() local c = os.clock() - c0 return os.date("%H:%M:%S", t0 + math.floor(c)) .. ("%.3f"):format(c % 1):sub(2) end
local function log(s) local f = io.open(LOG, "a") if f then f:write(stamp(), " ", s, "\n") f:close() end end
local FNS = {
    "/Script/SIGISPlugin.SIGISPlayerController:ServerCheck",
    "/Script/SIGISPlugin.SIGISPlayerController:ServerChallenge",
    "/Script/SIGISPlugin.SIGISPlayerController:Server_SendEAC",
    "/Script/SIGISPlugin.SIGISPlayerController:OnAntiCheatCheck",
    "/Script/SIGISPlugin.SIGISPlayerController:ClientEACAction",
    "/Script/SIGISPlugin.SIGISPlayerController:Client_EACMessage",
    "/Script/SIGISPlugin.SIGISPlayerController:Client_EACAction",
    "/Script/SIGISPlugin.SIGISPlayerController:Client_Loaded",
    "/Script/GameLiftFramework.GameLiftPlayerController:ServerAcceptPlayer",
    "/Script/GameLiftFramework.GameLiftPlayerController:ServerRemovePlayer",
    "/Script/RaidGame.RaidPlayerController:ClientStartOnlineGame",
    "/Script/RaidGame.RaidPlayerController:ClientGameStarted",
    "/Script/RaidGame.RaidPlayerController:ClientDissconnectedFromServer",
    "/Script/Engine.PlayerController:ServerNotifyLoadedWorld",
    "/Script/Engine.PlayerController:ClientSetHUD",
    "/Script/Engine.PlayerController:ClientRestart",
    "/Script/Engine.PlayerController:ClientWasKicked",
    "/Script/Engine.PlayerController:ClientReturnToMainMenuWithTextReason",
    "/Script/Engine.GameModeBase:K2_PostLogin",
    "/Script/Engine.GameModeBase:K2_OnLogout",
    "/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:ReceiveBeginPlay",
}
local ok, bad = 0, {}
-- EndPlay of player controllers only (the class name is read only on this rare event)
pcall(RegisterHook, "/Script/Engine.Actor:ReceiveEndPlay", function(ctx)
    pcall(function()
        local o = ctx:get()
        local c = o:GetClass():GetFName():ToString()
        if c:find("PlayerController", 1, true) then log("ReceiveEndPlay " .. c .. " @" .. ("%x"):format(o:GetAddress())) end
    end)
end)
for _, fn in ipairs(FNS) do
    local short = fn:match(":(.+)$")
    local r = pcall(RegisterHook, fn, function(ctx)
        local a = "?"
        pcall(function() a = ("%x"):format(ctx:get():GetAddress()) end)
        log(short .. " @" .. a)
    end)
    if r then ok = ok + 1 else bad[#bad + 1] = short end
end
log(("hooks on: %d, failed: %s"):format(ok, table.concat(bad, ",")))
return ("hooks on: %d, failed: %s"):format(ok, table.concat(bad, ","))
