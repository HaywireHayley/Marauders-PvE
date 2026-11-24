-- Women's versions of outfits: every body, head, vest, rig and bag has a reshaped copy beside it (tools/female/make_female.py),
-- which any character can wear by swapping the meshes it already has on. Used by all bots, and by your own body (the F9 menu's body button).
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local M = {}
local X -- context from main.lua: valid, lib, log, loadLoose, root

local SWAPS = {
    { "/MainPlayer/Meshes/Bodies/", "/MainPlayer/Meshes/BodieF/" },
    { "/MainPlayer/Meshes/Heads/", "/MainPlayer/Meshes/HeadF/" },
    { "/MainPlayer/Meshes/Accessories/", "/MainPlayer/Meshes/AccessorieF/" },
    { "/MainPlayer/Meshes/", "/MainPlayer/MesheF/" }, -- the soldiers' one-piece outfits sit directly in Meshes
}
local SETTING = PROJECT .. "config/female_player.txt"
local known = {} -- path -> mesh, or false when there's no such version

local function other(path, on)
    for _, s in ipairs(SWAPS) do
        local from, to = s[1], s[2]
        if not on then from, to = to, from end
        local at, stop = path:find(from, 1, true)
        if at then return path:sub(1, at - 1) .. to .. path:sub(stop + 1) end
    end
end

local function load(path)
    if known[path] ~= nil then return known[path] end
    local mesh = X.lib(path)
    if not X.valid(mesh) then
        X.loadLoose(FName(path):GetComparisonIndex())
        mesh = X.lib(path)
    end
    if not X.valid(mesh) then
        known[path] = false
        return false
    end
    X.root(mesh) -- the garbage collector can't see this table
    known[path] = mesh
    return mesh
end

-- The woman's (on) or man's version of a mesh; the mesh itself when it has none or is that already.
function M.version(mesh, on)
    if not X.valid(mesh) then return mesh end
    local path = mesh:GetFullName():match("^%S+ (.+)$")
    local to = path and other(path, on)
    if not to then return mesh end
    local out = load(to)
    return out or mesh
end

-- Meshes your own character wears in place of others (outfits.lua's Blood Raider: a body with no appearance row of its
-- own, worn over the plain Raider body). Mesh name -> { path of the mesh to wear instead, when() }: the swap holds
-- only while when() is true. The women's version of the result follows as usual.
local playerSwaps = {}

function M.setPlayerSwap(name, path, when)
    playerSwaps[name] = path and { path = path, when = when } or nil
end

local function swapped(mesh)
    local name = mesh:GetFName():ToString() -- (the women's copies keep the same name)
    local s = playerSwaps[name]
    if not s or (s.when and not s.when()) then return mesh end
    local out = load(s.path)
    return out or mesh
end

local CLASS = "/Script/Engine.SkeletalMeshComponent"
-- What the game remembers a character wearing: its corpse is dressed from these.
local WORN = { CharacterBody0 = "R_BodyMesh", CharacterMesh0 = "R_FaceMesh", ChestSlot = "R_ChestSlot", Backpc = "R_BackPack" }

-- Puts a character in the women's (on) or men's versions of everything it's wearing.
function M.dress(actor, on)
    -- your own character also gets its swaps (the Blood Raider): in a raid the game puts the body on natively, which
    -- the SetSkeletalMesh hook never sees, so main.lua's per-update pass is what dresses it there
    local cls = actor:GetClass():GetFName():ToString()
    local mine = next(playerSwaps) ~= nil and (cls == "PlayerPawn_C" or (cls == "MM_PlayerChar_C" and actor.isPlayer))
    local parts = actor:K2_GetComponentsByClass(X.lib(CLASS))
    for i = 1, #parts do
        local part = parts[i]:get()
        local mesh = X.valid(part) and part.SkeletalMesh
        if mesh and X.valid(mesh) then
            local want = M.version(mine and swapped(mesh) or mesh, on)
            if want:GetAddress() ~= mesh:GetAddress() then
                part:SetSkeletalMesh(want, false)
                local field = WORN[part:GetFName():ToString()]
                if field then pcall(function() actor[field] = want end) end
            end
        end
    end
end

-- Your own body -------------------------------------------------------------------------------------------------
local playerOn, offUntil

local function readSetting()
    local f = io.open(SETTING, "r")
    playerOn = false
    if f then
        playerOn = f:read("l") == "on"
        f:close()
    end
end

function M.playerOn()
    if playerOn == nil then readSetting() end
    return playerOn
end

-- Nothing to do for anyone who's never used it: a male body only needs dressing back for a while after switching off.
function M.playerDue()
    return M.playerOn() or os.clock() < (offUntil or 0) or next(playerSwaps) ~= nil
end

function M.togglePlayer()
    playerOn = not M.playerOn()
    offUntil = playerOn and 0 or os.clock() + 10
    local f = io.open(SETTING, "w")
    if f then
        f:write(playerOn and "on" or "off", "\n")
        f:close()
    end
    X.log("female player model " .. (playerOn and "on" or "off"))
end

-- Seamless: whenever the game itself puts a mesh on your character (the lobby's MM_PlayerChar_C re-dresses on every
-- menu change, your raid body on every gear change), the right version goes on straight after, in the same call, before
-- anything is drawn. The 3 s lobby pass and the per-update raid check in main.lua stay as a fallback.
local PLAYER_CLASSES = { MM_PlayerChar_C = true, PlayerPawn_C = true }
local busy
M.hookCalls = 0 -- read by main.lua's profiler

-- A raider bot makes a dynamic material from its starting head when it spawns, and that material stays on the part when
-- another head is put on (rivals, station top-ups): the old head's textures over the new head's UVs, a streaky smear
-- (testers: "odd texture" on heads; seen as Raider_01_Head_MIC on Outlaw_Head_Skel_01). Its parameters are empty, so a
-- fresh one from the new mesh's own material loses nothing, and the game's later CreateDynamicMaterialInstance calls reuse it.
local BOT_CLASSES = { GOAPNodeBot_Raider_C = true }
local MID = "MaterialInstanceDynamic"

local function baseOf(m)
    while m and X.valid(m) and m:GetClass():GetFName():ToString() == MID do m = m.Parent end
    return m
end

local function refitMaterials(part)
    local mats = part.SkeletalMesh.Materials
    for slot = 0, part:GetNumMaterials() - 1 do
        local drawn = part:GetMaterial(slot)
        local own = slot < #mats and mats[slot + 1].MaterialInterface or nil
        if own and X.valid(own) and drawn and X.valid(drawn) and drawn:GetClass():GetFName():ToString() == MID then
            local was = baseOf(drawn)
            if X.valid(was) and was:GetAddress() ~= own:GetAddress() then
                part:CreateDynamicMaterialInstance(slot, own, FName("None"))
            end
        end
    end
end

local function afterSetMesh(ctx)
    M.hookCalls = M.hookCalls + 1
    local part = ctx:get()
    if not X.valid(part) then return end
    local owner = part:GetOwner()
    local cls = owner and X.valid(owner) and owner:GetClass():GetFName():ToString()
    if cls and BOT_CLASSES[cls] and X.valid(part.SkeletalMesh) then pcall(refitMaterials, part) end
    if busy then return end
    if not (cls and PLAYER_CLASSES[cls]) then return end
    -- the lobby's other stands are your crew's (crewlobby.lua dresses them as themselves)
    if cls == "MM_PlayerChar_C" and not owner.isPlayer then return end
    local mesh = part.SkeletalMesh
    if not (mesh and X.valid(mesh)) then return end
    local want = M.version(swapped(mesh), M.playerOn())
    if want:GetAddress() == mesh:GetAddress() then return end
    busy = true
    pcall(function()
        part:SetSkeletalMesh(want, false)
        local field = WORN[part:GetFName():ToString()]
        if field then owner[field] = want end
    end)
    busy = false
end

function M.init(ctx)
    X = ctx
    local ok, err = pcall(RegisterHook, "/Script/Engine.SkinnedMeshComponent:SetSkeletalMesh", function() end, afterSetMesh)
    if not ok then X.log("female: no SetSkeletalMesh hook (" .. tostring(err) .. "); only the timed re-dress") end
end

return M
