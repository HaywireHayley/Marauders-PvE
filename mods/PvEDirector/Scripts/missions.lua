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
    INSPECT_RANGE = 250, -- inspecting: this close (the game's own limit is 400)...
    INSPECT_RADIUS = 35, -- ...and looking at it: within the angle a target this big (cm) takes up at that distance,
    INSPECT_MIN_ANGLE = 6, -- but never tighter than this (degrees)...
    KEEP_SCALE = 1.8,    -- ...and within this many times that to keep inspecting (idle sway, small mouse moves).
    -- (A flat 35 degrees from 3.5 m took in most of a wall and the doorway, and blocked loot and doors there: #99.)
    LOOK_GRACE = 1.5,    -- seconds of looking away before an inspect stops (it restarts from zero)
    USE_KEY = "F",       -- the "Use" action's default key, if it has no binding (keys.lua reads the player's own)
    RESEND = 1.0,        -- seconds between inspect events sent while Use is held (#20)
    -- Destroy contracts (type 3, #333): classes looked through for actors whose Tags name an active Destroy target.
    -- RaidSubNodeActor covers space mines (Small_/Nuclear_NodeMine) and station turrets; MineStaticActor_C station mines.
    DESTROY_CLASSES = { "RaidSubNodeActor", "MineStaticActor_C" },
    DESTROY_TRIES = 10,  -- ...looked for this many times, RESCAN apart, until some are found
    HINT_STALE = 0.5,    -- seconds without M.interact before the "Hold F" hint is taken down (left the pawn, etc.)
}

local S -- per-raid state

local valid, lib -- main.lua's helpers, from ctx (init)
local hint -- { host, text, slot, shown }: the "Hold F to inspect" line (per world, dropped by M.reset)

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

-- Destroy contracts (type 3, #333) ----------------------------------------------------------------------------------
-- Live, the server's half of a mine or turret sends Client_CheckMissionEvent(tag, Destroy) when it dies; offline
-- nothing does (NOTES: "Not verified: Destroy contracts"). The active Destroy targets' tags are read from the raid's
-- contract rows and the campaign step (as minimap.lua reads them), and death is caught where spacefx.lua catches it:
-- the native RaidSubNodeActor_Turret:NetOnDeathEvent (turrets) and Actor:K2_DestroyActor (mines destroy themselves
-- after going off). An actor counts once (its full name in S.fired) whichever of the two sees it.
local function destroyTags(pc)
    local set, n = {}, 0
    local function add(m)
        if m.ContractType ~= 3 then return end
        pcall(function() m.ContractRequiredActorTags:ForEach(function(_, t)
            local k = t:get():ToString()
            if not set[k] then set[k] = true n = n + 1 end
        end) end)
    end
    for _, e in ipairs(pc:GetAllMissionsForRaid() or {}) do add(e:get()) end
    pcall(function()
        local gi = FindFirstOf("SIGIS_ExampleGameInstance_C") -- (pc:GetGameInstance() throws from Lua)
        local c = gi.PrologueChapter
        local rows = pc:GetAllMissionsForChapters(c.Chapter:ToString())
        local e = rows and rows[c.ChapterStage + 1]
        if e then add(e:get()) end
    end)
    return set, n
end

local function tagsOf(a)
    local tags = {}
    pcall(function() a.Tags:ForEach(function(_, e) tags[#tags + 1] = e:get():ToString() end) end)
    return tags
end

-- Actors that are Destroy targets now, for the minimap (same entry shape as scan()'s, type 3).
local function scanDestroy()
    local list = {}
    for _, cls in ipairs(CFG.DESTROY_CLASSES) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if valid(a) then
                local hit = {}
                for _, t in ipairs(tagsOf(a)) do if S.destroyTags[t] then hit[#hit + 1] = t end end
                local full = #hit > 0 and a:GetFullName()
                local path = full and full:match("^%S+ (.+)$")
                -- (one in the space map's own level gets no place: minimap.lua would make the whole space map a
                -- "station" of it, as loose airlocks once did)
                local level = full and full:match("([%w_]+):PersistentLevel")
                if level and level:find("^Space_") then level = nil end
                if path then
                    local l = a:K2_GetActorLocation()
                    list[#list + 1] = { path = path, full = full, tags = hit, type = 3,
                        at = { X = l.X, Y = l.Y, Z = l.Z }, level = level,
                        name = a:GetClass():GetFName():ToString():gsub("_C$", "") }
                end
            end
        end
    end
    return list
end

-- A mine or turret died: if its Tags name an active Destroy target, count it once.
local function destroyed(a, why)
    if not S or not S.destroyTags or not valid(S.pc) or not valid(a) then return end
    local hit = {}
    for _, t in ipairs(tagsOf(a)) do if S.destroyTags[t] then hit[#hit + 1] = t end end
    if #hit == 0 then return end
    local key = a:GetFullName()
    if S.fired[key] then return end
    S.fired[key] = true
    S.ver = (S.ver or 0) + 1
    for _, t in ipairs(hit) do
        local ok, err = pcall(function() S.pc:Client_CheckMissionEvent(FName(t), 3) end)
        if not ok then X.log("[missions] destroy event failed: " .. tostring(err)) end
    end
    X.log(("[missions] destroyed %s (%s, %s): sent Destroy"):format(key, table.concat(hit, ","), why))
end

-- The "Hold F to inspect" line, bottom middle (defuse.lua's prompt pattern: a DebugInfo_Widget canvas with one text).
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local function say(pc, s)
    if hint and not valid(hint.host) then hint = nil end
    if not hint then
        if not s then return end
        local cls = lib(HOST)
        if not valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = lib(HOST) end
        if not valid(cls) then return end
        local h = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(h) then return end
        h.WidgetTree.RootWidget:ClearChildren()
        local t = StaticConstructObject(lib("/Script/UMG.TextBlock"), h.WidgetTree)
        t.Font.Size = 18
        hint = { host = h, text = t }
        hint.slot = h.WidgetTree.RootWidget:AddChildToCanvas(t)
        hint.slot:SetAutoSize(true)
        hint.slot:SetAlignment({ X = 0.5, Y = 0.5 })
        h:AddToViewport(40)
    end
    if s and hint.shown ~= s then
        local wll = lib("/Script/UMG.Default__WidgetLayoutLibrary")
        local vp, scale = { X = 1600, Y = 900 }, 1
        pcall(function() vp = wll:GetViewportSize(pc) end)
        pcall(function() scale = wll:GetViewportScale(pc) end)
        if not (scale and scale > 0) then scale = 1 end
        hint.slot:SetPosition({ X = vp.X / scale / 2, Y = vp.Y / scale * 0.68 })
    end
    if hint.shown ~= s then
        hint.shown = s
        hint.text:SetText(FText(s or ""))
        hint.host:SetVisibility(s and 4 or 1) -- HitTestInvisible / Collapsed
    end
end

-- A new world: the last raid's contract actors were freed with it (M.interact runs before M.update rescans).
function M.reset() S = nil hint = nil end

-- Called from the director's update in raids and space maps. key = the director's per-raid key; pawn = your
-- on-foot character.
function M.update(pc, key, pawn)
    local now = os.clock()
    if not S or S.key ~= key then S = { key = key, list = {}, scannedAt = -1e9, destroy = {}, fired = {}, tries = 0 } end
    S.pc = pc
    if hint and hint.shown and now - (S.hintAt or 0) > CFG.HINT_STALE then pcall(say, pc, nil) end
    -- Destroy targets: the tags once the contracts can be read, then the actors (stations stream in: a few tries).
    if not S.destroyTags and now - (S.destroyAt or -1e9) >= CFG.RESCAN then
        S.destroyAt = now
        local ok, set, n = pcall(destroyTags, pc)
        if ok and (n > 0 or S.tries >= CFG.DESTROY_TRIES) then
            S.destroyTags = set
            if n > 0 then X.log(("[missions] %d destroy target tag(s)"):format(n)) end
        end
        S.tries = S.tries + 1
    end
    if S.destroyTags and next(S.destroyTags) and #S.destroy == 0 and S.destroyTries ~= CFG.DESTROY_TRIES
        and now - (S.destroyScanAt or -1e9) >= CFG.RESCAN then
        S.destroyScanAt, S.destroyTries = now, (S.destroyTries or 0) + 1
        S.destroy = scanDestroy()
        if #S.destroy > 0 then S.ver = (S.ver or 0) + 1 end
        if #S.destroy > 0 then X.log(("[missions] %d destroy target actor(s)"):format(#S.destroy)) end
    end
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
    if not S or #S.list == 0 or not valid(pawn) then
        if hint and hint.shown then pcall(say, pc, nil) end
        return
    end
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
        local start = math.max(CFG.INSPECT_MIN_ANGLE, math.deg(math.atan(CFG.INSPECT_RADIUS, math.max(n, 1))))
        ok = angle <= (S.looking == best and start * CFG.KEEP_SCALE or start)
        -- The game's own interaction pick (made just before this) wins: loot, a door or a container nearer the
        -- crosshair stays usable, unless you're already inspecting this object.
        if ok and S.looking ~= best then
            local cur = pawn.LastInteractionActor
            if cur and valid(cur) and cur:GetAddress() ~= live(best):GetAddress() then ok = false end
        end
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
        down = require("keys").down(pc, "Use", CFG.USE_KEY) -- (the player's own binding: #103)
        local idle = true
        pcall(function() idle = pc.CurrentTimedMission:ToString() == "None" end)
        -- At most once a second, and not for an object that keeps refusing: each send can play the contract's sound,
        -- and a finished contract refuses to start (no timer) forever, so sending every frame while Use was held
        -- repeated the sound (#20). Two sends in a row that start no inspect = done here for this raid.
        local o = S.looking
        S.refused = S.refused or {}
        if not idle then o.refusals = 0 end
        if down and idle and not S.refused[o] and now - (o.sentAt or 0) >= CFG.RESEND then
            if o.sentAt and now - o.sentAt < CFG.RESEND * 3 then o.refusals = (o.refusals or 0) + 1 end
            if (o.refusals or 0) >= 2 then
                S.refused[o] = true
                X.log("[missions] an inspect object stopped answering (done?): not sending it again this raid")
            else
                o.sentAt = now
                for _, t in ipairs(o.tags) do
                    pcall(function() pc:Client_CheckMissionEvent(FName(t), 5) end)
                end
            end
        end
    end
    -- The "F" prompt the game never shows for these offline (#333): while you look at one it would still take.
    local line
    if target and not (S.refused and S.refused[S.looking]) then
        local idle = true
        pcall(function() idle = pc.CurrentTimedMission:ToString() == "None" end)
        local k = require("keys").name("Use", CFG.USE_KEY)
        line = idle and ("Hold " .. k .. " to inspect") or ("Inspecting... keep holding " .. k)
    end
    if line then S.hintAt = now end
    if line or (hint and hint.shown) then
        local okh, errh = pcall(say, pc, line)
        if not okh then X.log("[missions] hint: " .. tostring(errh)) end
    end
end

-- The contract actors found so far, and the Destroy targets not yet destroyed (minimap.lua: places and task markers
-- by tag). A destroyed target is found by name (live(), never a kept pointer) and dropped.
function M.actors()
    if not S then return {} end
    if #S.destroy == 0 then return S.list end
    local r = {}
    for _, c in ipairs(S.list) do r[#r + 1] = c end
    for _, c in ipairs(S.destroy) do
        if not S.fired[c.full] and live(c) then r[#r + 1] = c end
    end
    return r
end

-- Bumped when the Destroy targets change (found, or one destroyed): minimap.lua rebuilds its task markers then.
function M.version() return S and S.ver or 0 end

-- Skip the current Zero to Hero step (#440, F9 menu): some chapter steps wait on events that never happen offline.
-- The chapter state is never written from Lua: the step's own event goes through Client_CheckMissionEvent, so its
-- progress, the next step and the rewards take the game's own path. Kill / Destroy / Raid and the rest count +1 per
-- event (sent need - progress times); Guard (6) counts 1 a second while bInChapterVolume is set, so the flag is set and
-- one event starts its timer; Inspect (5) only counts while Use is held at the object, so it isn't skipped here.
local function chapterStep(pc)
    local gi = FindFirstOf("SIGIS_ExampleGameInstance_C") -- (pc:GetGameInstance() throws from Lua)
    if not valid(gi) then return nil end
    local c = gi.PrologueChapter
    local chapter, stage, progress = c.Chapter:ToString(), c.ChapterStage, c.Progress
    local rows = pc:GetAllMissionsForChapters(chapter)
    local e = rows and rows[stage + 1]
    if not e then return nil end
    local m = e:get()
    local tags = {}
    pcall(function() m.ContractRequiredActorTags:ForEach(function(_, t) tags[#tags + 1] = t:get():ToString() end) end)
    return { chapter = chapter, stage = stage, progress = progress, type = m.ContractType,
        need = m.ContractMaxAmountNeeded, tags = tags }
end

-- (the menu asks every time it draws: the answer is kept 2 s, a FindFirstOf each draw would hitch)
local readable = { at = -10, ok = false }
function M.chapterReadable()
    if os.clock() - readable.at < 2 then return readable.ok end
    readable.at = os.clock()
    local pc = FindFirstOf("PlayerController")
    local ok, st = false, nil
    if valid(pc) then ok, st = pcall(chapterStep, pc) end
    readable.ok = ok and st ~= nil
    return readable.ok
end

function M.skipChapterStep()
    local pc = FindFirstOf("PlayerController")
    if not valid(pc) then return "No player" end
    local ok, st = pcall(chapterStep, pc)
    if not ok or not st then return "No chapter step to skip" end
    local what = ("chapter %s step %d (type %s, %s/%s, tags %s)"):format(st.chapter, st.stage + 1, tostring(st.type),
        tostring(st.progress), tostring(st.need), table.concat(st.tags, ","))
    local tag = st.tags[1]
    if not tag or tag == "" or tag == "None" then
        X.log("[missions] skip: no tag on " .. what)
        return "This step has no tag: can't skip"
    end
    if st.type == 5 then
        X.log("[missions] skip: inspect step, not skipped: " .. what)
        return "Inspect step: hold Use at it instead"
    end
    if st.type == 6 then
        pcall(function() pc.bInChapterVolume = true end)
        local okE, err = pcall(function() pc:Client_CheckMissionEvent(FName(tag), 6) end)
        X.log(("[missions] skip: Guard %s sent for %s (%s)"):format(tag, what, okE and "ok" or tostring(err)))
        if not okE then return "Event failed (see log)" end
        return ("Holding: done in about %d s"):format(math.max(0, (st.need or 0) - (st.progress or 0)))
    end
    local n = math.max(1, math.min(100, (st.need or 1) - (st.progress or 0)))
    for _ = 1, n do
        local okE, err = pcall(function() pc:Client_CheckMissionEvent(FName(tag), st.type) end)
        if not okE then
            X.log("[missions] skip: event failed: " .. tostring(err))
            return "Event failed (see log)"
        end
    end
    X.log(("[missions] skip: sent %s x%d for %s"):format(tag, n, what))
    return ("Step %d: sent %d event(s)"):format(st.stage + 1, n)
end

local TURRET_DEATH ="/Script/RaidGame.RaidSubNodeActor_Turret:NetOnDeathEvent"
local DESTROY = "/Script/Engine.Actor:K2_DestroyActor"

function M.init(ctx)
    X = ctx valid = ctx.valid lib = ctx.lib
    local okt, errt = pcall(RegisterHook, TURRET_DEATH, function(self)
        local ok, err = pcall(function() destroyed(self:get(), "turret death") end)
        if not ok then X.log("[missions] turret death: " .. tostring(err)) end
    end)
    if not okt then X.log("[missions] turret hook failed: " .. tostring(errt)) end
    local okm, errm = pcall(RegisterHook, DESTROY, function(self)
        if not S or not S.destroyTags or not next(S.destroyTags) then return end -- cheap: most raids have none
        local ok, err = pcall(function()
            local a = self:get()
            if not valid(a) then return end
            -- A space mine cleaned up with the level still shows its mesh; one that went off hid it first (spacefx.lua).
            if a:GetClass():GetFName():ToString():find("NodeMine", 1, true) then
                local mesh = a.StaticMesh
                if not (valid(mesh) and not mesh:IsVisible()) then return end
            end
            destroyed(a, "destroyed")
        end)
        if not ok then X.log("[missions] destroy: " .. tostring(err)) end
    end)
    if not okm then X.log("[missions] destroy hook failed: " .. tostring(errm)) end
end

return M
