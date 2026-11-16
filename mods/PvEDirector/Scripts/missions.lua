-- Missions: makes contract and campaign (chapter) objectives inside raids count offline.
--
-- The mission system is the client's own (ASIGISPlayerController + game instance; see NOTES.md, "Missions offline"):
-- active contracts and their progress live in the game instance (+0x1190, survives travel), the campaign step in
-- +0x1160. Client_CheckMissionEvent(tag, type) advances every active contract / the current chapter step whose type
-- matches and whose ContractRequiredActorTags hold the tag:
--   * Kill / Destroy / Raid: +1 right away. Kills already send it offline (e.g. "AIRaider", Kill).
--   * Guard (hold an area): starts a 1 s timer that adds +1 per tick while bInMissionVolume (contracts) /
--     bInChapterVolume (chapter) is set.
--   * Inspect: sets CurrentTimedMission and starts a timer that adds +1 per tick while the interact key is held.
-- What's missing offline is the server half of the contract actors (Contract_Hold_* / Contract_Int_*, class
-- ASIGISContractActor): their overlap code sets those flags and sends the event, and is skipped when the game is its
-- own server. This module does it: entering a contract actor's area sends the event (the actor's own Tags hold the
-- mission tag, e.g. C2_WeaponIntel, RepoMan) and sets the flags; leaving clears them.

local M = {}
local X -- log, valid

local CFG = {
    RESCAN = 20,        -- space maps stream stations in: look for contract actors again this often until found
    NEAR = 4000,        -- only actors this close are checked for overlap
    INSPECT_RANGE = 350, -- inspecting: this close (the game's own limit is 400)...
    INSPECT_ANGLE = 35,  -- ...and looking within this many degrees of it to start...
    KEEP_ANGLE = 60,     -- ...and within this many to keep inspecting (idle sway, small mouse moves)
    LOOK_GRACE = 1.5,    -- seconds of looking away before an inspect stops (it restarts from zero)
    USE_KEY = "F",       -- the "Use" action's default key (Input.ini ActionMappings)
}

local S -- per-raid state

local function valid(o) return X.valid(o) end

-- The contract actors are found once a raid but never kept as objects: one kept from that scan was freed later (a
-- station's actors replaced, or an old world's still listed), and the first IsValid on it, when you walked up to it,
-- read freed memory and crashed the game (user, 2026-11-16: out of a pod at the Mini Mine; AV in UE4SS's IsValid).
-- Each entry holds the actor's object path; live() looks it up by name, which never touches a stale pointer.
local function live(c)
    if not c or not c.path then return nil end
    local o = StaticFindObject(c.path)
    if valid(o) then return o end
    return nil
end

local function scan()
    local list = {}
    for _, a in ipairs(FindAllOf("SIGISContractActor") or {}) do
        if valid(a) then
            local tags = {}
            pcall(function() a.Tags:ForEach(function(_, e) tags[#tags + 1] = e:get():ToString() end) end)
            local typ = 8
            pcall(function() typ = a.ContractType end)
            local full = a:GetFullName()
            local path = full:match("^%S+ (.+)$") -- "Class /Game/...:PersistentLevel.Name" -> the path
            if #tags > 0 and path then
                local l = a:K2_GetActorLocation()
                table.insert(list, { path = path, tags = tags, type = typ, at = { X = l.X, Y = l.Y, Z = l.Z },
                    level = full:match("([%w_]+):PersistentLevel"),
                    name = a:GetClass():GetFName():ToString():gsub("^Contract_", ""):gsub("_C$", "") })
            end
        end
    end
    return list
end

local function setVolume(pc, on)
    pcall(function() pc.bInMissionVolume = on end)
    pcall(function() pc.bInChapterVolume = on end)
end

local function enter(pc, c)
    setVolume(pc, true)
    if c.type == 5 then
        X.log(("[missions] looking at %s (%s): hold Use to inspect"):format(c.name, table.concat(c.tags, ",")))
        return
    end
    for _, t in ipairs(c.tags) do
        local ok, err = pcall(function() pc:Client_CheckMissionEvent(FName(t), c.type) end)
        if not ok then X.log("[missions] event failed: " .. tostring(err)) end
    end
    X.log(("[missions] entered %s (%s, type %d)"):format(c.name, table.concat(c.tags, ","), c.type))
end

local function leave(pc, c)
    setVolume(pc, false)
    -- An inspect left half done must not block the next one (it only starts while no timed mission is set).
    if c.type == 5 then pcall(function() pc.CurrentTimedMission = FName("None") end) end
    X.log("[missions] left " .. c.name)
end

-- A new world: the last raid's contract actors were freed with it (M.interact runs before M.update rescans).
function M.reset() S = nil end

-- Called from the director's update in raids and space maps. key = the director's per-raid key; pawn = your
-- on-foot character.
function M.update(pc, key, pawn)
    local now = os.clock()
    if not S or S.key ~= key then S = { key = key, list = {}, scannedAt = -1e9 } end
    if not valid(pawn) then return end
    if #S.list == 0 and now - S.scannedAt >= CFG.RESCAN then
        S.scannedAt = now
        S.list = scan()
        if #S.list > 0 then X.log(("[missions] %d contract actors"):format(#S.list)) end
    end
    local l = pawn:K2_GetActorLocation()
    -- Inspect actors (Contract_Int_*): "inside" = the one you're looking at (M.interact). Hold areas
    -- (Contract_Hold_*) = overlapping their GuardArea box.
    local inside
    for _, c in ipairs(S.list) do
        if math.abs(l.X - c.at.X) < CFG.NEAR and math.abs(l.Y - c.at.Y) < CFG.NEAR and math.abs(l.Z - c.at.Z) < CFG.NEAR then
            local a = live(c)
            if a then
                local hit
                if c.type == 5 then hit = S.looking == c
                else hit = a:IsOverlappingActor(pawn) end
                if hit then inside = c break end
            end
        end
    end
    if inside ~= S.current then
        if S.current then leave(pc, S.current) end
        S.current = inside
        if inside then enter(pc, inside) end
    end
end

-- Inspect objects (Contract_Int_*) are never offered by InteractionDetection offline (ShouldShowContractInteraction
-- skips its part when the game is its own server), yet the inspect timer only counts while your character's
-- LastInteractionActor is the object (within 400) and the Use key is held. Called by the director right after each
-- InteractionDetection: if you're close to one and looking at it, make it your interaction target.
function M.interact(pc, pawn)
    if not S or #S.list == 0 or not valid(pawn) then return end
    local l = pawn:K2_GetActorLocation()
    local best, bd
    for _, c in ipairs(S.list) do
        if c.type == 5 then
            local d = math.sqrt((l.X - c.at.X) ^ 2 + (l.Y - c.at.Y) ^ 2 + (l.Z - c.at.Z) ^ 2)
            if d < CFG.INSPECT_RANGE and (not bd or d < bd) then best, bd = c, d end
        end
    end
    local now = os.clock()
    local ok = false
    if best and live(best) then
        local cam, r = pc.PlayerCameraManager:GetCameraLocation(), pc:GetControlRotation()
        local yaw, pitch = math.rad(r.Yaw), math.rad(r.Pitch)
        local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
        local dx, dy, dz = best.at.X - cam.X, best.at.Y - cam.Y, best.at.Z - cam.Z
        local n = math.sqrt(dx * dx + dy * dy + dz * dz)
        local angle = n < 1 and 0 or math.deg(math.acos(math.max(-1, math.min(1, (fx * dx + fy * dy + fz * dz) / n))))
        ok = angle <= (S.looking == best and CFG.KEEP_ANGLE or CFG.INSPECT_ANGLE)
    end
    if ok then
        S.looking, S.lookLost = best, nil
    elseif S.looking then
        S.lookLost = S.lookLost or now
        if now - S.lookLost > CFG.LOOK_GRACE or not live(S.looking) then S.looking, S.lookLost = nil, nil end
    end
    local target = S.looking and live(S.looking)
    if S.looking and not target then S.looking, S.lookLost = nil, nil end
    if target then
        pawn.LastInteractionActor = target
        -- The server sent the inspect event when you pressed Use on the object; its timer stops (clearing
        -- CurrentTimedMission) the first second Use isn't held. So: (re)send it whenever Use is down and no inspect
        -- is running.
        local down = false
        pcall(function() down = pc:IsInputKeyDown({ KeyName = FName(CFG.USE_KEY) }) end)
        local idle = true
        pcall(function() idle = pc.CurrentTimedMission:ToString() == "None" end)
        if down and idle then
            for _, t in ipairs(S.looking.tags) do
                pcall(function() pc:Client_CheckMissionEvent(FName(t), 5) end)
            end
        end
    end
end

-- The contract actors found so far (minimap.lua).
function M.actors() return S and S.list or {} end

function M.init(ctx) X = ctx end

return M
