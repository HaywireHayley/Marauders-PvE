-- Field of view (#328): features.lua FOV (0 = the game's own, else 70-120 degrees) and ADS_ZOOM (1 = the game's aim
-- zoom, 0 = none, between = a blend). At the defaults nothing is touched.
-- ASSUMED, NOT tested in game: the view comes from the pawn's CameraComponent (property FirstPersonCamera or Camera,
-- else the first CameraComponent) and the game's aim zoom narrows that component's FieldOfView. Each frame we read
-- FieldOfView; a value that isn't the one we last wrote is the game's own. The game's hip FOV is remembered while not
-- aiming (bIsTargeting false), the game's zoom is its current value / hip, and we write
--   (FOV or hip) * (1 - ADS_ZOOM * (1 - zoom)).
-- Plain property reads and writes only; the component is looked up once per pawn.
local M = {}
local Features = require("features")

local pawnAddr, comp -- the local pawn (address) and its camera component
local hip, game, wrote -- the game's hip FOV, its latest own value, and the value we last wrote

local function findCamera(pawn, valid)
    local c
    pcall(function() c = pawn.FirstPersonCamera end)
    if not valid(c) then pcall(function() c = pawn.Camera end) end
    if not valid(c) then
        local cls = StaticFindObject("/Script/Engine.CameraComponent")
        if valid(cls) then pcall(function() c = pawn:GetComponentByClass(cls) end) end
    end
    if valid(c) then return c end
end

local function restore(valid)
    if wrote and game and valid(comp) then pcall(function() comp.FieldOfView = game end) end
    wrote = nil
end

-- pc: the local PlayerController; valid: main's valid()
function M.tick(pc, valid)
    local base, zoomW = tonumber(Features.FOV) or 0, tonumber(Features.ADS_ZOOM) or 1
    if base ~= 0 then base = math.max(70, math.min(120, base)) end
    zoomW = math.max(0, math.min(1, zoomW))
    local active = base ~= 0 or zoomW < 1
    if not active then
        if wrote then restore(valid) end
        return
    end
    if not valid(pc) then return end
    local pawn = pc.Pawn
    if not valid(pawn) then pawnAddr, comp = nil, nil return end
    local addr = pawn:GetAddress()
    if addr ~= pawnAddr then
        pawnAddr, comp, hip, game, wrote = addr, findCamera(pawn, valid), nil, nil, nil
    end
    if not valid(comp) then return end
    local cur = comp.FieldOfView
    if type(cur) ~= "number" or cur <= 0 then return end
    if not wrote or math.abs(cur - wrote) > 0.01 then game = cur end -- the game wrote it (or first look)
    local aiming = pawn.bIsTargeting == true
    if not aiming or not hip then hip = game end
    local zoom = (hip and hip > 0) and math.min(1, game / hip) or 1
    local want = (base ~= 0 and base or hip) * (1 - zoomW * (1 - zoom))
    if math.abs(cur - want) > 0.01 then
        comp.FieldOfView = want
        wrote = want
    elseif not wrote then
        wrote = cur
    end
end

return M
