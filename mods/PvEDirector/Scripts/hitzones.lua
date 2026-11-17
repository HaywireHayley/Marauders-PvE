-- Hit zones on bots (issue #123). The game's damage function (0x181a8a0) reads the hit capsule's AreaHitType: head
-- x3.5 against bots and the helmet's armour, body the chest piece's armour, legs x0.5. The player pawn has 17
-- RaidHitCapsuleComponents for that; the mod's bot pawns (BotPawn_C, BotPawnGuard_C, BotPawnMilitary_C) have none (the map's node bots do),
-- so every player bullet that hit a bot did the gun's flat damage (STG44: 34 to the head of a helmeted soldier).
-- ensure() gives a bot the player's capsules (same bones, sizes and offsets, measured from PlayerPawn_C; made natively, see
-- pve_hit_capsule in pvepatch.c) and makes its body mesh let traces through on the two channels where the player's mesh
-- does (3 Visibility, 15), so shots reach them.
--   require("hitzones").ensure(bot)   --> number of capsules added (0 if it had them, or nil, err)
local H = {}

-- { socket, AreaHitType (1 head/neck, 2 body, 3/4 arms, 5/6 legs), radius, half height, relative location, rotation }
local CAPSULES = {
    { "head", 1, 10.0, 14.0, { 2.9, 0.5, 0.0 }, { 90, -355, -695 } },
    { "neck_01", 1, 7.0, 8.8, { 6.1, -0.3, 0.0 }, { 90, 0, 0 } },
    { "spine_03", 2, 13.0, 20.0, { 18.8, -5.9, 0.4 }, { 0, 10, 0 } },
    { "spine_02", 2, 15.7, 23.7, { 9.0, -2.2, 1.1 }, { 39, 91, 93 } },
    { "pelvis", 2, 13.0, 19.1, { -2.3, -1.1, 0.0 }, { 0, 10, 0 } },
    { "upperarm_r", 4, 6.5, 16.0, { -16.2, 0.3, -0.8 }, { 81, -1, -6 } },
    { "lowerarm_r", 4, 5.7, 16.0, { -14.5, -0.4, 0.2 }, { 86, -160, -163 } },
    { "Hand_R", 4, 4.9, 7.9, { -6.2, 0.7, 1.6 }, { 88, -24, -25 } },
    { "upperarm_l", 3, 6.5, 16.0, { 16.5, -0.3, 0.6 }, { 81, -1, -6 } },
    { "lowerarm_l", 3, 5.7, 16.0, { 15.1, 0.0, -0.4 }, { 85, -16, -15 } },
    { "hand_l", 3, 4.9, 7.9, { 5.6, -0.6, -1.7 }, { 88, -24, -22 } },
    { "thigh_r", 6, 8.8, 23.1, { 23.8, -0.2, -0.7 }, { 90, -46, -54 } },
    { "calf_r", 6, 7.9, 22.4, { 21.5, 2.4, 0.1 }, { 88, -171, -170 } },
    { "Foot_R", 6, 4.9, 13.5, { 6.7, -7.0, 0.7 }, { 86, 82, 166 } },
    { "thigh_l", 5, 8.8, 23.1, { -24.1, 0.4, 0.6 }, { 90, -46, -54 } },
    { "calf_l", 5, 7.9, 22.4, { -21.6, -2.6, 0.7 }, { 88, -171, -170 } },
    { "foot_l", 5, 4.9, 13.5, { -6.6, 6.6, -0.4 }, { 86, 82, 166 } },
}
-- The player's body mesh ignores these two, where a bot's blocks them (so a bullet stopped on the bot's mesh, no zone).
local MESH_IGNORES = { 3, 15 }

local capClass, hitInit, hitCapsule

-- The capsules are made in pvepatch.dll (pve_hit_capsule): from Lua, UE4SS left them unregistered or crashed (NOTES).
H.dll = require("pveproject") .. "native/pvepatch.dll"

local function setup()
    capClass = StaticFindObject("/Script/RaidGame.RaidHitCapsuleComponent")
    if not (capClass and capClass:IsValid()) then return "no RaidHitCapsuleComponent class" end
    hitInit, hitCapsule = package.loadlib(H.dll, "pve_hit_init"), package.loadlib(H.dll, "pve_hit_capsule")
    if not (hitInit and hitCapsule) then return "pvepatch.dll has no pve_hit_capsule" end
    local fns = {}
    for _, path in ipairs({ "/Script/Engine.Actor:AddComponentByClass", "/Script/Engine.Actor:FinishAddComponent",
        "/Script/Engine.CapsuleComponent:SetCapsuleSize", "/Script/Engine.PrimitiveComponent:SetCollisionEnabled",
        "/Script/Engine.PrimitiveComponent:SetCollisionObjectType",
        "/Script/Engine.PrimitiveComponent:SetCollisionResponseToAllChannels",
        "/Script/Engine.PrimitiveComponent:SetCollisionResponseToChannel" }) do
        local f = StaticFindObject(path)
        if not (f and f:IsValid()) then return "missing " .. path end
        fns[#fns + 1] = math.tointeger(f:GetAddress())
    end
    hitInit(fns[1], fns[2], fns[3], fns[4], fns[5], fns[6], fns[7], math.tointeger(capClass:GetAddress()))
end

local function x100(f) return math.floor(f * 100 + 0.5) end

function H.ensure(bot)
    if not (bot and bot:IsValid()) then return nil, "no bot" end
    local mesh = bot.Mesh
    if not (mesh and mesh:IsValid()) then return nil, "no mesh" end
    if not hitCapsule then
        local err = setup()
        if err then return nil, err end
    end
    if #bot:K2_GetComponentsByClass(capClass) > 0 then return 0 end
    local at, meshAt = math.tointeger(bot:GetAddress()), math.tointeger(mesh:GetAddress())
    for _, z in ipairs(CAPSULES) do
        local socket = FName(z[1])
        if mesh:DoesSocketExist(socket) then -- (a mesh with other bone names gets the zones it has)
            hitCapsule(at, meshAt, socket:GetComparisonIndex(), z[2], x100(z[3]), x100(z[4]),
                x100(z[5][1]), x100(z[5][2]), x100(z[5][3]), x100(z[6][1]), x100(z[6][2]), x100(z[6][3]))
        end
    end
    local added = #bot:K2_GetComponentsByClass(capClass)
    if added > 0 then
        for _, ch in ipairs(MESH_IGNORES) do mesh:SetCollisionResponseToChannel(ch, 0) end
    end
    return added
end

return H
