-- F9 debug menu: pick a gun or an ammo type and get it, in a raid, on foot. Guns come loaded, into the first free gun
-- slot (primary, then secondary; pistols into the pistol slot); ammo comes as one full stack (its own size) into a free pocket cell.
-- Both go through the game's own loadout path, SIGISPlayerController:Server_AwsN_EquippedItemsReturned (as main.lua
-- applyLoadout does at the start of a raid): it registers the item, spawns the weapon, loads its magazine and equips it.
-- A second gun sent to a slot that's taken left the first in your hands with its item hidden behind the new one, so a
-- full set of slots is refused instead.
-- Rows, kinds and magazines from assets/saves/items.json (type 0 = long gun, 1 = pistol; max = magazine / stack), minus
-- test items, throwables, mines, shields and tools.
local G = {}
local Pockets = require("pockets")

local GUNS = {
    { "STG44Rifle", "STG44", 0, 30 }, { "Mat49Rifle", "Mat 49", 0, 36 }, { "MP40Rifle", "MP40", 0, 30 },
    { "StenSMG", "Sten", 0, 32 }, { "ThompsonSMG", "Thompson", 0, 30 }, { "M45CarlSMG", "Carl Gustav m/45", 0, 36 },
    { "PPSHSmg", "PPSh", 0, 36 }, { "UziSmg", "Uzi", 0, 20 }, { "Mac10Rifle", "MAC-10", 0, 30 },
    { "KlobbSMG", "Klobb", 1, 20 }, { "GreaseGun", "Grease Gun", 0, 30 }, { "SterlingRifle", "Sterling", 0, 20 },
    { "M50ReisingRifle", "Reising", 0, 12 }, { "BARRifle", "BAR", 0, 20 }, { "JohnsonRifle", "Johnson", 0, 10 },
    { "SVT40Rifle", "SVT-40", 0, 10 }, { "M1ParaRifle", "M1 Carbine Para", 0, 15 }, { "Mas44Rifle", "MAS 44", 0, 10 },
    { "DeLisleRifle", "De Lisle", 0, 11 }, { "EM2Rifle", "EM-2", 0, 20 }, { "FALRifle", "FAL", 0, 20 },
    { "M16Rifle", "M16", 0, 20 }, { "StonerRifle", "Stoner", 0, 30 }, { "DaewooK1Rifle", "Daewoo K1", 0, 20 },
    { "KrasaRifle", "Krasa", 0, 20 }, { "AC14Rifle", "AC14", 0, 30 }, { "SVURifle", "SVU", 0, 10 },
    { "MG42Rifle", "MG42", 0, 50 }, { "BrenMk2Rifle", "Bren", 0, 20 }, { "DP28Rifle", "DP-28", 0, 47 },
    { "LiberatorShotgun", "Liberator", 0, 4 }, { "TrenchShotgun", "Trench gun", 0, 5 },
    { "SawedOffDouble", "Sawed-off", 1, 2 }, { "LongDoubleBarrel", "Double barrel", 0, 2 },
    { "Jackhammer", "Jackhammer", 0, 10 }, { "LPOFlamethrower", "LPO flamethrower", 0, 100 },
    { "ChinaLake", "China Lake", 0, 3 }, { "BlowTorch", "Blowtorch", 0, 250 },
    { "TerminatorShotgun", "Terminator", 0, 1 }, { "HeavyLiberatorShotgun", "Heavy Liberator", 0, 4 },
    { "HeavyMG42Rifle", "Heavy MG42", 0, 50 }, { "HeavyThompsonSMG", "Heavy Thompson", 0, 30 }, { "ThompsonSpecial", "Thompson Special", 0, 30 },
    { "APSRifle", "APS", 0, 20 }, { "CustomMat49", "Custom Mat 49", 0, 30 }, { "M712SpecialSMG", "M712 Special", 0, 20 },
    { "SterlingSpecial", "Sterling Special", 0, 20 }, { "SterlingRifle_Short", "Sterling (short)", 1, 20 }, { "ViperMk1", "Viper Mk1", 0, 32 },
    { "MiniThumper", "Mini Thumper", 1, 1 }, { "1911GPistol", "M1911 G", 1, 8 },
    { "P08Pistol", "Luger P08", 1, 8 }, { "1911Pistol", "M1911", 1, 7 }, { "M712Pistol", "M712", 1, 10 },
    { "WebleyPistol", "Webley", 1, 6 }, { "WelrodPistol", "Welrod", 1, 6 }, { "SPP1Pistol", "SPP-1", 1, 4 },
    { "MosinObrezPistol", "Obrez", 1, 5 }, { "Flaregun01", "Flare gun", 1, 1 },
}
local AMMO = {
    { "9mmAmmo", "9mm", 60 }, { "45Ammo", ".45 ACP", 60 }, { "762Ammo", "7.62mm", 60 }, { "556Ammo", "5.56mm", 60 },
    { "300Ammo", ".30-06", 60 }, { "54RAmmo", "7.62x54R", 60 }, { "32Ammo", ".32", 60 }, { "10mmAmmo", "10mm", 60 },
    { "12GaugeAmmo", "12 gauge", 20 }, { "40mmAmmo", "40mm", 3 }, { "FlareAmmo", "Flares", 5 }, { "FlameFuel", "Flame fuel", 100 },
    { "DartAmmo", "Darts", 40 },
}

local gi, ai = 1, 1

local function controller()
    local pc = FindFirstOf("MainPlayerController_C")
    if not (pc and pc:IsValid()) then return nil end
    local pawn = pc.Pawn
    if not (pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then return nil end
    return pc
end

-- What the player's inventory holds, by container: { Prim = true, ..., cells = { ["PocketLeft 0 1"] = true } }, every
-- cell an item covers (pockets.lua), not just its corner.
local function taken()
    local out = {}
    out.cells = Pockets.cells(FindFirstOf("SIGISInventoryComponent"), function(_, con) out[con] = true end)
    return out
end

local function give(pc, row, stack, col, line, con)
    local id = tostring(math.random(10000000, 99999999))
    pc:Server_AwsN_EquippedItemsReturned(('[{"value":{"equip":true,"value":"%s-%s-%d-100-%d-%d-0-%s"}}]')
        :format(id, row, stack, col, line, con))
end

local function inRaid() return controller() ~= nil end

-- Bottomless mags (F9): a toggle that puts back every round a shot takes. No game flags: bInfiniteClip and bInfiniteAmmo change how
-- the clip reads (the code that watches it for shots never sees one), and finding the flags searched the world twice a second.
-- Each frame, after whatever reads the clip has seen it drop, what the shot took is put back. For the player the loaded rounds are
-- the StackAmount of the gun's own SIGIS item (found by UniqueItemGUID == gun.UUIDSIGIS); the weapon's CurrentAmmoInClip only
-- follows it, so putting that property back alone changes nothing. Both are put back. One property read a frame, nothing searched.
local bottomless = false
local last = {} -- the gun's address and item, the item's stack and the clip as of the last frame

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v
end

local function findItem(gun)
    local guid = gun.UUIDSIGIS:ToString()
    for _, it in ipairs(FindAllOf("SIGISInventoryItem") or {}) do
        if valid(it) and it.UniqueItemGUID:ToString() == guid then return it end
    end
    return nil
end

-- Every frame in a raid (main.lua, after the section that reads the clip for shots).
function G.frame(pc)
    if not bottomless then return end
    local pawn = pc.Pawn
    if not valid(pawn) then return end
    local gun = pawn.CurrentWeapon
    if not valid(gun) then last = {} return end
    local addr = gun:GetAddress()
    if last.addr ~= addr then -- a different gun: find its item once, then count from what it holds now
        last = { addr = addr, item = findItem(gun), at = os.clock() }
    elseif not valid(last.item) and os.clock() - last.at > 1 then
        last.item, last.at = findItem(gun), os.clock()
    end
    local clip = gun.CurrentAmmoInClip
    local item = last.item
    local stack = valid(item) and item.StackAmount or nil
    if type(clip) == "number" and type(last.clip) == "number" and clip < last.clip then
        gun.CurrentAmmoInClip = last.clip
        clip = last.clip
    end
    if type(stack) == "number" and type(last.stack) == "number" and stack < last.stack then
        item.StackAmount = last.stack
        stack = last.stack
    end
    last.clip, last.stack = clip, stack
end

function G.actions()
    return {
        { id = "bottomless", label = function() return "Bottomless mags: " .. (bottomless and "ON" or "off") end,
          help = "Guns never run dry: every shot is put back", when = inRaid, unusable = "In a raid, on foot",
          run = function()
              bottomless = not bottomless
              last = {}
              return bottomless and "Bottomless mags on" or "Bottomless mags off"
          end },
        { id = "gunpick", label = function() return ("Gun: %s   (click for the next one)"):format(GUNS[gi][2]) end,
          help = "Choose the gun the Give me button below gives", when = inRaid, unusable = "In a raid, on foot",
          run = function() gi = gi % #GUNS + 1 return "Gun: " .. GUNS[gi][2] end },
        { id = "gunback", label = "Previous gun", help = "Back one in the list", when = inRaid, unusable = "In a raid, on foot",
          run = function() gi = (gi - 2) % #GUNS + 1 return "Gun: " .. GUNS[gi][2] end },
        { id = "givegun", label = function() return "Give me the " .. GUNS[gi][2] end,
          help = "Loaded, into a free gun slot", when = inRaid, unusable = "In a raid, on foot",
          run = function()
              local pc = controller()
              local row, name, kind, mag = table.unpack(GUNS[gi])
              local t = taken()
              local slot = kind == 1 and (not t.Pistol and "Pistol")
                  or kind == 0 and (not t.Prim and "Prim" or not t.Sec and "Sec") or nil
              if not slot then
                  return ("No free %s slot: drop one first"):format(kind == 1 and "pistol" or "gun")
              end
              give(pc, row, mag, 0, 0, slot)
              return ("%s, %d rounds, in your %s slot"):format(name, mag,
                  ({ Prim = "primary", Sec = "secondary", Pistol = "pistol" })[slot])
          end },
        { id = "ammopick", label = function() return ("Ammo: %s   (click for the next one)"):format(AMMO[ai][2]) end,
          help = "Choose the ammo the Give me button below gives", when = inRaid, unusable = "In a raid, on foot",
          run = function() ai = ai % #AMMO + 1 return "Ammo: " .. AMMO[ai][2] end },
        { id = "giveammo", label = function() return ("Give me %d %s"):format(AMMO[ai][3], AMMO[ai][2]) end,
          help = "Into a free pocket cell", when = inRaid, unusable = "In a raid, on foot",
          run = function()
              local pc = controller()
              local pocket, col, line = Pockets.find(taken().cells, AMMO[ai][1])
              if not pocket then return "Your pockets are full" end
              give(pc, AMMO[ai][1], AMMO[ai][3], col, line, pocket)
              return ("%d %s in your %s pocket"):format(AMMO[ai][3], AMMO[ai][2],
                  pocket == "PocketLeft" and "left" or "right")
          end },
    }
end

return G
