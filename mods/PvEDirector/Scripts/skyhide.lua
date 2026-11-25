-- Black behind the interiors, whenever you are on foot.
-- The interiors (ships, stations) are kits of wall and floor pieces standing in the map, and a few seams (the drop pod
-- hatch ring against its wall hole in the Rustbucket, and the same on stations) let the map's sky show through as a
-- blue sliver. The game never hides the sky on foot, so this does: while you walk, the node's background actor has its
-- SM_SkyDome and its ExponentialHeightFog component hidden (the dome alone leaves the fog's colour in a seam, the fog
-- alone leaves the dome). Both come back when you sit at a helm, in a pod or a turret, or look through a viewport or
-- any other camera that is not your own body (the windows should show space then), and when a raid ends.
-- Maps without a Node_Background actor are left alone. Nothing else on the actor is touched, and every change is undone
-- by M.reset().
local M = {}
local log, valid

local PARTS = { "SM_SkyDome", "ExponentialHeightFog" }
local comps = {}   -- part name -> component
local hidden = false
local nextFind = 0
local looks = 0 -- searches this world; FindAllOf("Actor") walks every actor, so a map without the node stops after GIVE_UP
local GIVE_UP = 3
local classes = {} -- RaidFrigate and RaidSpaceship (a helm or a pod: the pilot looks out of windows)

function M.init(ctx) log, valid = ctx.log, ctx.valid end

local function name(o)
    local ok, r = pcall(function() return o:GetFName():ToString() end)
    return ok and r or ""
end

local function find()
    comps = {}
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        if name(a):find("^Node_Background") then
            pcall(function()
                a.BlueprintCreatedComponents:ForEach(function(_, v)
                    local c = v:get()
                    for _, p in ipairs(PARTS) do
                        if name(c) == p then comps[p] = c end
                    end
                end)
            end)
            if next(comps) then break end
        end
    end
end

-- Whether you are at a helm or in a pod rather than walking.
local function piloting(pc)
    local p = valid(pc) and pc.Pawn
    if not (p and valid(p)) then return false end
    for _, path in ipairs({ "/Script/RaidGame.RaidFrigate", "/Script/RaidGame.RaidSpaceship" }) do
        local c = classes[path]
        if not (c and valid(c)) then c = StaticFindObject(path) classes[path] = c end
        if c and valid(c) and p:IsA(c) then return true end
    end
    return false
end

-- Whether your view is some other camera than your own body: a turret's, a viewport's.
local function viewing(pc)
    local ok, r = pcall(function()
        local p, vt = pc.Pawn, pc:GetViewTarget()
        return valid(p) and valid(vt) and vt:GetAddress() ~= p:GetAddress()
    end)
    return ok and r or false
end

local function apply(hide)
    for _, p in ipairs(PARTS) do
        local c = comps[p]
        if c and valid(c) then
            pcall(function()
                if p == "SM_SkyDome" then c:SetHiddenInGame(hide, false) end
                if c:IsVisible() == hide then c:SetVisibility(not hide, false) end
            end)
        end
    end
end

local function set(hide)
    local ok = true
    for _, p in ipairs(PARTS) do
        if not (comps[p] and valid(comps[p])) then ok = false end
    end
    if not ok then
        if os.clock() < nextFind or looks >= GIVE_UP then return end
        nextFind = os.clock() + 10
        looks = looks + 1
        find()
        if looks == GIVE_UP and not next(comps) then log("sky: no Node_Background on this map, not looked for again") end
        if not next(comps) then return end
    end
    if hide == hidden then return end
    local done, err = pcall(apply, hide)
    if done then
        hidden = hide
        log("sky " .. (hide and "hidden: on foot" or "shown again"))
    else
        log("sky change failed: " .. tostring(err))
    end
end

-- Every update (about twice a second): seated = Gunseat.seated() ~= nil.
function M.update(pc, seated)
    set(not seated and not piloting(pc) and not viewing(pc))
end

-- The sky back as it was (leaving a raid, a new world).
function M.reset()
    if hidden then pcall(apply, false) end
    comps, hidden, nextFind, looks = {}, false, 0, 0
end

return M
