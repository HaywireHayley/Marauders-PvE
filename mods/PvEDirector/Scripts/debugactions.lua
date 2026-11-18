-- The debug menu's buttons (debugmenu.lua, F9) and god mode (moved out of main.lua).
local PROJECT = require("pveproject")
local Debug = require("debugmenu")
local M = {}

local log, valid, Aux -- from main.lua (M.init)
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)

function M.setRaid(r) raid = r end

-- Test immunity: on while bridge/god.txt exists (survives raids and restarts); the debug menu toggles it.
local GOD_FILE = PROJECT .. "bridge/god.txt"
local function godMode()
    if Aux.due("god", 2) then
        local f = io.open(GOD_FILE, "r")
        if f then f:close() end
        Aux.god = f ~= nil
    end
    return Aux.god == true
end

local function toggleGodMode()
    if godMode() then os.remove(GOD_FILE) else
        local f = io.open(GOD_FILE, "w")
        if f then f:write("player can't be damaged while this file exists\n") f:close() end
    end
    Aux.dueAt.god = 0 -- read the file again now, not up to 2 s later
    log("player damage immunity " .. (godMode() and "ON" or "OFF"))
end

-- The debug menu's buttons (they used to be F4-F9). when() says whether one can be used where you are.
local function onFootIn(kind)
    local pc = FindFirstOf("PlayerController")
    return valid(pc) and valid(pc.Pawn) and (kind == "land" and raid.navReady or kind == "any")
end

function M.init(ctx)
    log, valid, Aux = ctx.log, ctx.valid, ctx.aux
    local lib, CFG, RAID_OPTS, Rivals = ctx.lib, ctx.CFG, ctx.RAID_OPTS, ctx.rivals
    local Bots, Loadout = ctx.bots, ctx.loadout
    Debug.init({ log = log, valid = valid, lib = lib, menuClosed = ctx.menuClosed, actions = {
        { id = "god", label = function() return "God mode: " .. (godMode() and "ON" or "off") end,
          help = "You can't be hurt. Stays on until you turn it off",
          run = function() toggleGodMode() return "God mode " .. (godMode() and "on" or "off") end },
        { id = "extract", label = "Extract now", help = "Leave with everything you carry",
          when = function() return raid.navReady or raid.space end, unusable = "Not available here", closes = true,
          run = function() Loadout.extractNow() return "Extracting" end },
        { id = "gates", label = "Open the gates now", help = "No waiting for the escape gates",
          when = function() return raid.space end, unusable = "Not available here",
          run = function()
              local t = FindFirstOf("UA_SpaceGateTrigger01_C")
              if not valid(t) then return "No gate console on this map" end
              t:TriggerSpaceEvacReady()
              return "Gates opening"
          end },
        { id = "attack", label = "Send a rival crew at me", help = "The nearest crew attacks your ship",
          when = function() return raid.space end, unusable = "Not available here",
          run = function() Rivals.provoke() return "A crew is coming" end },
        { id = "soldier", label = "Spawn a soldier", help = "Appears 15 m in front of you",
          when = function() return onFootIn("land") end, unusable = "Not available here",
          run = function()
              local pc = FindFirstOf("PlayerController")
              local l, r = pc.Pawn:K2_GetActorLocation(), pc.Pawn:K2_GetActorRotation()
              local y = math.rad(r.Yaw)
              Bots.spawnBot(pc, { X = l.X + 1500 * math.cos(y), Y = l.Y + 1500 * math.sin(y), Z = l.Z }, r.Yaw + 180)
              return "Soldier spawned"
          end },
        { id = "gun", label = "Give me a gun", help = "A soldier's gun, with ammo",
          when = function() return onFootIn("land") and not raid.donor end, unusable = "Not available here",
          run = function() Loadout.startGiveGun(FindFirstOf("PlayerController")) return "Gun on its way" end },
        { id = "testraid", label = "Start a test raid on " .. CFG.MAP, help = "A land raid, without your stash gear",
          closes = true,
          run = function()
              local pc = FindFirstOf("PlayerController")
              lib("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc,
                  "open /Game/Maps/Raids/" .. CFG.MAP .. RAID_OPTS, pc)
              return "Loading " .. CFG.MAP
          end },
    } })
    Debug.addActions(require("debuggive").actions()) -- pick a gun or ammo type and get it (F9)
end

M.godMode = godMode

return M
