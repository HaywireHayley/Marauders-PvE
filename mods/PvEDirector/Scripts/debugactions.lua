-- The debug menu's buttons (debugmenu.lua, F9) and god mode (moved out of main.lua).
local PROJECT = require("pveproject")
local Debug = require("debugmenu")
local Holes = require("bulletholes").CFG -- the bullet holes switch (bulletholes.lua, also F10 Effects)
local Give = require("debuggive") -- the gun and ammo picker and bottomless mags
local Unstuck = require("unstuck") -- unstuck and no collision (#198; main.lua runs its update)
local Outfits = require("outfits") -- the two outfits the Appearance pages never list (#229)
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

-- God mode is no stamina drain either: while it is on, the player pawn's Stamina is put back to its maximum four times a second
-- (PlayerPawn_C has Stamina and MaxStamina; a pod or ship pawn has neither, which the pcall and the type check skip).
local staminaSaid = false
local function holdStamina(pawn)
    if not Aux.due("godStamina", 0.25) or not godMode() then return end
    local ok, st, mx = pcall(function() return pawn.Stamina, pawn.MaxStamina end)
    if ok and type(st) == "number" and type(mx) == "number" and mx > 0 and st < mx then
        pcall(function() pawn.Stamina = mx end)
        if not staminaSaid then
            staminaSaid = true
            log(("god mode: stamina held at its maximum (%.0f of %.0f when first read)"):format(st, mx))
        end
    end
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
        -- (it was F2, one of the game's voice-line keys F1-F8: pressing it also played a line)
        { id = "body", label = function() return "Your body: " .. (require("female").playerOn() and "woman" or "man") end,
          help = "Play as a woman or a man (also a launcher setting)",
          run = function()
              local F = require("female")
              F.togglePlayer()
              return "Your body: " .. (F.playerOn() and "woman" or "man")
          end },
        { id = "bulletholes", label = function() return "Bullet holes: " .. (Holes.BULLET_HOLES ~= 0 and "ON" or "off") end,
          help = "Holes where shots land. Old ones stay until they fade",
          run = function()
              Holes.BULLET_HOLES = Holes.BULLET_HOLES ~= 0 and 0 or 1
              log("bullet holes " .. (Holes.BULLET_HOLES ~= 0 and "ON" or "OFF") .. " (debug menu)")
              return "Bullet holes " .. (Holes.BULLET_HOLES ~= 0 and "on" or "off")
          end },
        { id = "keys", label = "Key list", help = "The mod's keys on screen (press again to hide)", closes = true,
          run = function(pc) require("keyhelp").toggle(pc) return "Key list" end },
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
    Debug.addActions(Unstuck.actions(function() return onFootIn("any") and (raid.navReady or raid.space) end))
    Debug.addActions(Give.actions()) -- pick a gun or ammo type and get it, bottomless mags (F9)
    Outfits.init({ log = log, valid = valid })
    Debug.addActions(Outfits.actions())
end

M.godMode = godMode
M.holdStamina = holdStamina
M.frame = Give.frame -- bottomless mags, every frame in a raid (main.lua)

return M
