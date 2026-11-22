-- Field of view (issue #328): the launcher's "Field of view" setting, config/fov.txt, lines "base=<degrees>" (or
-- "base=default") and optionally "ads_zoom=<factor>" (read, not yet applied: see NOTES.md, "Field of view").
-- No file, or "default": the game is left alone.
-- How: the player pawn's CameraComponent.FieldOfView (UE4 UCameraComponent, set through its SetFieldOfView UFunction)
-- plus the camera manager's DefaultFOV as a fallback. Applied once per pawn (respawn, helm, map change): not re-forced
-- every frame, so whatever the game does to the FOV while aiming isn't fought. NOT tested in game.
local M = {}
local PROJECT = require("pveproject")
local SETTING = PROJECT .. "config/fov.txt"

local X
local cfg -- {base = number|nil, ads = number|nil}, read once per raid
local lastPawn -- address of the pawn last set up (an address, not a kept reference)

function M.init(ctx) X = ctx end

local function readSetting()
    local c = {}
    local f = io.open(SETTING, "r")
    if not f then return c end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
        if k == "base" then
            local n = tonumber(v)
            if n and n >= 60 and n <= 130 then c.base = n end
        elseif k == "ads_zoom" then
            local n = tonumber(v)
            if n and n > 0 and n <= 2 then c.ads = n end
        end
    end
    f:close()
    return c
end

-- a new raid: read the file again (the launcher may have changed it)
function M.setRaid() cfg, lastPawn = nil, nil end

local function apply(pc, pawn, fov)
    local cam = pc.PlayerCameraManager
    if X.valid(cam) then pcall(function() cam.DefaultFOV = fov end) end
    local comp
    pcall(function() comp = pawn.FirstPersonCamera end)
    if not X.valid(comp) then pcall(function() comp = pawn.Camera end) end
    if not X.valid(comp) then
        local cls = StaticFindObject("/Script/Engine.CameraComponent")
        if X.valid(cls) then pcall(function() comp = pawn:GetComponentByClass(cls) end) end
    end
    if not X.valid(comp) then return false end
    local cur
    pcall(function() cur = comp.FieldOfView end)
    if type(cur) == "number" and math.abs(cur - fov) < 0.01 then return true end
    pcall(function() comp:SetFieldOfView(fov) end)
    return true
end

function M.frame(pc)
    if not cfg then cfg = readSetting() if cfg.base then X.log("fov: base " .. cfg.base) end end
    if not cfg.base or not X.valid(pc) then return end
    local pawn = pc.Pawn
    if not X.valid(pawn) then lastPawn = nil return end
    local addr = pawn:GetAddress()
    if addr == lastPawn then return end
    lastPawn = addr -- once per pawn even when no camera was found: no per-frame lookups
    if not apply(pc, pawn, cfg.base) then X.log("fov: no camera component on the pawn") end
end

return M
