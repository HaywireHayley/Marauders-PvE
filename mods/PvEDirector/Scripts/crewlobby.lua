-- Your crew in the lobby itself: the hangar's three crew stands (MM_PlayerChar_C, CharID 1-3, hidden offline) show your hired
-- crewmates in their own look and kit beside you, and the three crew slots next to FREEBOOTER (Crew_member_MM_Widget_C
-- Slot01-03; the lobby hides Slot04) carry their names and portraits. An empty slot's "+" opens hiring (hire.lua), a filled
-- one opens that crewmate's card. While you browse recruits, the one you pick stands on a free stand.
--
-- How a look gets onto a stand: head and body are mesh paths (gear.lua); helmet, armour, bag and gun are item rows, and the
-- lobby's own dressing call (Refresh_PlayerLookActor) can't be given a look struct from Lua. So a hidden donor raider gets
-- the rows through the game's kit step (pve_roll_kit, as in raids) and the meshes it ends up wearing are noted per row in
-- CACHE_FILE, once ever per row. Portraits: a photo booth (our own MM_PlayerChar_C under the floor, two lights and a
-- SceneCapture2D that renders only the booth) photographs each person into a render target.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local L = {}
local X -- context from main.lua: log, valid, lib, female, root, rollKit (pve_roll_kit)

local CACHE_FILE = PROJECT .. "config/crew_meshes.lua"
local ITEM_TABLE = "/SIGISPlugin/ExampleBlueprints/SIGIS_ExampleItemData.SIGIS_ExampleItemData"
local RAIDER = "/Game/AI/GOAPNodeBot_Raider"
local CFG = {
    UNDER = 3000,            -- the donor and the photo booth stand this far below the crew stands
    DONOR_WAIT = 1.5,        -- seconds for the donor's gun to arrive after its kit step
    DONOR_GIVE_UP = 6,
    POSE_WAIT = 0.3,         -- seconds between dressing the booth and the photo (the pose settles)
    PORTRAIT = 256,          -- render target size
    PHOTO_DIST = 105, PHOTO_FOV = 30, PHOTO_UP = 12,
}

local cache       -- item row -> mesh path (saved)
local W           -- this lobby: { key, stands, slots, booth, donor, queue, photos, portraits, shown }

local valid -- main.lua's helpers, from ctx (init)
local function real(o) return valid(o) and not o:GetFName():ToString():find("^Default__") end
local function pathOf(o) return o:GetFullName():match("^%S+ (.+)$") end

local function loadCache()
    local ok, t = pcall(dofile, CACHE_FILE)
    cache = ok and type(t) == "table" and t or {}
end

local function saveCache()
    local f = io.open(CACHE_FILE, "w")
    if not f then return end
    f:write("-- Item row -> the mesh it puts on a character (crewlobby.lua learns them from a donor). Safe to delete.\nreturn {\n")
    local keys = {}
    for k in pairs(cache) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(("  [%q] = %q,\n"):format(k, cache[k])) end
    f:write("}\n")
    f:close()
end

local meshes = {} -- path -> loaded, rooted mesh
local function mesh(path)
    if not path then return nil end
    local m = meshes[path]
    if valid(m) then return m end
    m = X.lib(path)
    if not valid(m) then pcall(LoadAsset, path) m = X.lib(path) end
    if not valid(m) then return nil end
    X.root(m)
    meshes[path] = m
    return m
end

local function loadClass(path)
    local name = path:match("([^/]+)$")
    local full = path .. "." .. name .. "_C"
    local c = X.lib(full)
    if not valid(c) then pcall(LoadAsset, path .. "." .. name) c = X.lib(full) end
    return valid(c) and c or nil
end

-- A person's kit rows: gun, helmet, armour, bag.
local function rows(r)
    local k = r.kit or {}
    return { gun = k.gun and k.gun[1], helmet = k.helmet, chest = k.chest, bag = k.bag }
end

local function known(r)
    for _, row in pairs(rows(r)) do if cache[row] == nil then return false end end
    return true
end

-- Donor ------------------------------------------------------------------------------------------------------------
local function donorStep(now)
    local d = W.donor
    if d then
        local gun = valid(d.bot) and d.bot.CurrentWeapon
        if not (now >= d.at + CFG.DONOR_WAIT and (valid(gun) or not d.rows.gun)) and now < d.at + CFG.DONOR_GIVE_UP then return end
        W.donor = nil
        if not valid(d.bot) then return end
        local slots = {}
        local parts = d.bot:K2_GetComponentsByClass(X.lib("/Script/Engine.SkeletalMeshComponent"))
        for i = 1, #parts do
            local p = parts[i]:get()
            if valid(p) then slots[p:GetFName():ToString()] = p end
        end
        local function note(row, comp)
            if not row then return end
            local m = comp and valid(comp.SkeletalMesh) and comp.SkeletalMesh
            cache[row] = m and pathOf(m) or false -- false: worn but no mesh of its own (nothing to show)
        end
        note(d.rows.helmet, slots.Helemt)
        note(d.rows.chest, slots.ChestSlot)
        note(d.rows.bag, slots.Backpc)
        if d.rows.gun then
            cache[d.rows.gun] = valid(gun) and valid(gun.Mesh1P) and valid(gun.Mesh1P.SkeletalMesh)
                and pathOf(gun.Mesh1P.SkeletalMesh) or false
            if valid(gun) then pcall(function() gun:K2_DestroyActor() end) end
        end
        -- NEVER destroy a donor: K2_DestroyActor on one froze the game for good (the game thread waits forever inside it).
        -- It stays hidden under the floor; each row is only learned once ever (CACHE_FILE), so there are few.
        pcall(function() d.bot:SetActorHiddenInGame(true) end)
        pcall(function() d.bot:SetActorTickEnabled(false) end)
        saveCache()
        X.log(("crew lobby: learned the meshes of %s"):format(table.concat({ d.rows.gun or "-", d.rows.helmet or "-",
            d.rows.chest or "-", d.rows.bag or "-" }, ", ")))
        return
    end
    local r = table.remove(W.donorQueue, 1)
    if not r or known(r) then return end
    local cls = loadClass(RAIDER)
    local tbl = X.lib(ITEM_TABLE)
    local base = W.stands[1] and W.stands[1]:K2_GetActorLocation()
    if not (cls and valid(tbl) and base) then return end
    local bot = W.stands[1]:GetWorld():SpawnActor(cls, { X = base.X + 400, Y = base.Y, Z = base.Z - CFG.UNDER },
        { Pitch = 0, Yaw = 0, Roll = 0 })
    if not valid(bot) then return end
    local rw = rows(r)
    local function idx(n) return n and FName(n):GetComparisonIndex() or 0 end
    X.rollKit(math.tointeger(bot:GetAddress()), math.tointeger(tbl:GetAddress()), idx(rw.gun), 0, idx(rw.helmet),
        idx(rw.chest), idx(rw.bag))
    W.donor = { bot = bot, rows = rw, at = now }
end

local function needMeshes(r)
    for _, q in ipairs(W.donorQueue) do if q.id == r.id then return end end
    W.donorQueue[#W.donorQueue + 1] = r
end

-- Dressing -----------------------------------------------------------------------------------------------------------
local PARTS = { helmet = "SkelMesh_Helmet", chest = "SkelMesh_BodyArmour", bag = "SkelMesh_Bag", gun = "SkelMesh_PrimWpn" }

local function dress(stand, r)
    local head, body = mesh(r.head), mesh(r.body)
    if head then stand.SkelMesh_Head:SetSkeletalMesh(head, false) end
    if body then stand.SkelMesh_Body:SetSkeletalMesh(body, false) end
    -- a part with no row (or no mesh yet) is emptied (pcall: a nil mesh may not marshal)
    local rw = rows(r)
    for k, comp in pairs(PARTS) do
        local p = rw[k] and cache[rw[k]]
        local m = p and mesh(p) or nil
        pcall(function() stand[comp]:SetSkeletalMesh(m, false) end)
    end
    for _, c in ipairs({ "SkelMesh_SecWpn", "SkelMesh_SideArm", "SkelMesh_MeleeWpn" }) do
        pcall(function() stand[c]:SetSkeletalMesh(nil, false) end)
    end
    pcall(X.female.dress, stand, r.female == true)
    stand:SetActorHiddenInGame(false)
end

-- Still wearing what they should? The lobby's own refresh empties the gear slots (helmet, armour, bag, gun) after Play.
local function wearing(stand, r)
    local rw = rows(r)
    for k, comp in pairs(PARTS) do
        local p = rw[k] and cache[rw[k]]
        if not rw[k] and valid(stand[comp].SkeletalMesh) then return false end -- the refresh's own gear on an empty slot
        if p then
            local want, have = mesh(p), stand[comp].SkeletalMesh
            if valid(want) and not (valid(have) and (have:GetAddress() == want:GetAddress()
                or have:GetFName():ToString():find(want:GetFName():ToString(), 1, true))) then
                return false
            end
        end
    end
    return true
end

-- Photo booth ------------------------------------------------------------------------------------------------------
local function booth()
    if W.booth then return W.booth end
    local s1 = W.stands[1]
    local cls = valid(s1) and s1:GetClass() -- the lobby's own stand class
    if not (valid(s1) and valid(cls)) then return nil end
    local world = s1:GetWorld()
    local l, rot = s1:K2_GetActorLocation(), s1:K2_GetActorRotation()
    local at = { X = l.X - 400, Y = l.Y, Z = l.Z - CFG.UNDER }
    local stand = world:SpawnActor(cls, at, rot)
    if not valid(stand) then return nil end
    stand.isPlayer, stand.CharID = false, 9
    -- the face is on the stand's right side (the mesh's +Y): -forward gave profiles, +forward the back of the head
    local f = stand:GetActorRightVector()
    local head = { X = at.X, Y = at.Y, Z = at.Z + 165 }
    local cam = { X = head.X + f.X * CFG.PHOTO_DIST, Y = head.Y + f.Y * CFG.PHOTO_DIST, Z = head.Z }
    local B = { stand = stand, face = { X = f.X, Y = f.Y }, head = head, cam = cam }
    local function light(dx, up, power)
        local side = { X = -f.Y, Y = f.X }
        local p = world:SpawnActor(X.lib("/Script/Engine.PointLight"), { X = cam.X + side.X * dx, Y = cam.Y + side.Y * dx,
            Z = cam.Z + up }, { Pitch = 0, Yaw = 0, Roll = 0 })
        p.LightComponent:SetIntensity(power)
        p.LightComponent:SetAttenuationRadius(400)
        return p
    end
    B.key, B.fill = light(60, 40, 3000), light(-70, -10, 900)
    B.cap = world:SpawnActor(X.lib("/Script/Engine.SceneCapture2D"), cam, { Pitch = 0, Yaw = 0, Roll = 0 })
    local c = B.cap.CaptureComponent2D
    c.FOVAngle, c.CaptureSource = CFG.PHOTO_FOV, 2
    c.bCaptureEveryFrame, c.bCaptureOnMovement = false, false
    c.PrimitiveRenderMode = 2 -- only what's on the show-only list: the booth stand
    c:ShowOnlyActorComponents(stand, true)
    local p = c.PostProcessSettings
    p.bOverride_AutoExposureMinBrightness, p.AutoExposureMinBrightness = true, 1
    p.bOverride_AutoExposureMaxBrightness, p.AutoExposureMaxBrightness = true, 1
    c.PostProcessBlendWeight = 1
    W.booth = B
    return B
end

-- Which way the face looks (flat, unit): the head bone's +Y axis (the idle pose turns the head a little), or the stand's
-- own face side when the bone reads more than MAX_TURN away from it.
local MAX_TURN = math.cos(math.rad(45))
local function faceDir(B)
    local ok, y = pcall(function()
        local rot = B.stand.SkelMesh_Head:GetSocketRotation(FName("head"))
        return X.lib("/Script/Engine.Default__KismetMathLibrary"):GetRightVector(rot)
    end)
    local n = ok and y and math.sqrt(y.X * y.X + y.Y * y.Y) or 0
    if n > 0.5 and (y.X * B.face.X + y.Y * B.face.Y) / n >= MAX_TURN then return { X = y.X / n, Y = y.Y / n } end
    return B.face
end

local function photoStep(now)
    local s = W.shooting
    if s then
        if now < s.at then return end
        W.shooting = nil
        local B = W.booth
        local hl = B.stand.SkelMesh_Head:GetSocketLocation(FName("head"))
        local aim = (hl and math.abs(hl.Z - B.head.Z) < 80) and { X = hl.X, Y = hl.Y, Z = hl.Z + CFG.PHOTO_UP } or B.head
        local face = faceDir(B)
        local cam = { X = aim.X + face.X * CFG.PHOTO_DIST, Y = aim.Y + face.Y * CFG.PHOTO_DIST, Z = aim.Z - 4 }
        Out.call(B.cap, "K2_SetActorLocation", cam, false, {}, true)
        B.cap:K2_SetActorRotation({ Pitch = 0, Yaw = math.deg(math.atan(-face.Y, -face.X)), Roll = 0 }, true)
        local krl = X.lib("/Script/Engine.Default__KismetRenderingLibrary")
        local rt = W.portraits[s.r.id]
        if not rt then
            -- Made inside the game instance, not the photo stand: CreateRenderTarget2D makes its world context object
            -- the new texture's outer, and a rooted object keeps its outer alive. With the stand (a lobby actor) as
            -- outer, the whole lobby world outlived the raid; the game marks a dead world's actors for kill, so the
            -- leaked level's WorldSettings went null, and loading the main menu again picked that world back up and
            -- crashed reading WorldSettings->DefaultGameMode (issue #133: on extraction, death or quit to menu).
            local gi = FindFirstOf("GameInstance")
            if not valid(gi) then return end
            rt = krl:CreateRenderTarget2D(gi, CFG.PORTRAIT, CFG.PORTRAIT, 2, { R = 0.02, G = 0.02, B = 0.025, A = 1 }, false)
            if not valid(rt) then return end
            -- Rooted: a portrait not shown in any slot or hire row had nothing in the engine holding it (the capture
            -- component lets go at the next photo), so it was freed and showing it again crashed the UI paint, as the
            -- minimap's floor plans did (issue #53). One per crewmate, kept for the session.
            X.root(rt)
        end
        local c = B.cap.CaptureComponent2D
        c.TextureTarget = rt
        c:CaptureScene()
        W.portraits[s.r.id] = rt
        W.photoSig[s.r.id] = s.sig
        W.changed = true
        return
    end
    local r = table.remove(W.photoQueue, 1)
    if not r then return end
    if not known(r) then needMeshes(r) W.photoQueue[#W.photoQueue + 1] = r return end
    local B = booth()
    if not B then return end
    dress(B.stand, r)
    W.shooting = { r = r, at = now + CFG.POSE_WAIT, sig = r.sig }
end

-- A person's look, as a string: a new photo when it changes (a promotion re-rolls the kit).
local function sigOf(r)
    local k = rows(r)
    return table.concat({ r.head, r.body, tostring(r.female), k.gun or "", k.helmet or "", k.chest or "", k.bag or "" }, "|")
end

-- The portrait render target for a person, or nil while it's being taken (it's queued).
function L.portrait(r)
    if not W then return nil end
    r.sig = sigOf(r)
    if W.photoSig[r.id] ~= r.sig then
        local queued = false
        for _, q in ipairs(W.photoQueue) do if q.id == r.id then queued = true end end
        if not queued and not (W.shooting and W.shooting.r.id == r.id) then W.photoQueue[#W.photoQueue + 1] = r end
        return W.photoSig[r.id] and W.portraits[r.id] or nil
    end
    return W.portraits[r.id]
end

-- Slots ------------------------------------------------------------------------------------------------------------
local function findSlots()
    W.slots = {}
    for _, w in ipairs(FindAllOf("Crew_member_MM_Widget_C") or {}) do
        if real(w) and w:GetFullName():find("/Engine/Transient", 1, true) then
            local n = tonumber(w:GetFName():ToString():match("Crew_member_Slot0(%d)$"))
            if n and n <= 3 then W.slots[n] = w end
        end
    end
end

local function setSlot(i, r)
    local w = W.slots[i]
    if not valid(w) then return end
    local rt = r and L.portrait(r)
    local sig = r and (r.name .. "|" .. r.level .. "|" .. tostring(rt and rt:GetAddress())) or "empty"
    if W.slotSig[i] == sig then return end
    W.slotSig[i] = sig
    if r then
        w.Border_InviteToCrew:SetVisibility(1)
        w.Border_NameBG:SetVisibility(4)
        w.Txt_CrewMembName:SetText(FText(("%s  Lv %d"):format(r.name, r.level)))
        w.Txt_CrewMembName:SetVisibility(4)
        if rt then
            w.Img_CrewMembAvatar:SetBrushResourceObject(rt)
            w.Img_CrewMembAvatar:SetVisibility(4)
        else
            w.Img_CrewMembAvatar:SetVisibility(1)
        end
    else
        w.Border_InviteToCrew:SetVisibility(0)
        w.Border_NameBG:SetVisibility(1)
        w.Img_CrewMembAvatar:SetVisibility(1)
        w.Txt_CrewMembName:SetText(FText(""))
    end
end

-- Real clicks: the slot's own Blueprint events for "+" (pressed) and a filled slot (options clicked). Polling IsPressed
-- misses quick clicks and only sees the slot set findSlots kept, so the hooks report the slot by the widget's own name.
-- A widget Blueprint is only loaded with the menu, so the hooks go in from tick() once the functions exist.
local SLOT_FN = "/SIGISPlugin/Widgets/MainMenu/Crews/Crew_member_MM_Widget.Crew_member_MM_Widget_C:"
local SLOT_EVENTS = {
    SLOT_FN .. "BndEvt__Crewmember_MM_Widget_Btn_InviteToCrew_K2Node_ComponentBoundEvent_4_OnButtonPressedEvent__DelegateSignature",
    SLOT_FN .. "BndEvt__Crew_member_MM_Widget_Btn_ShowHideOptions_K2Node_ComponentBoundEvent_6_OnButtonClickedEvent__DelegateSignature",
}
local hooked = {} -- event path -> address of the hooked UFunction
local clicked     -- slot index (1-3) a hook saw clicked, picked up by the next tick
local function hookSlots()
    for _, path in ipairs(SLOT_EVENTS) do
        local fn = StaticFindObject(path)
        if valid(fn) and fn:GetAddress() ~= hooked[path] then
            local ok = pcall(RegisterHook, path, function(ctx)
                local w = ctx:get()
                local n = valid(w) and tonumber(w:GetFName():ToString():match("Crew_member_Slot0(%d)$"))
                if n and n <= 3 then clicked = n end
            end)
            if ok then hooked[path] = fn:GetAddress() else X.log("crew lobby: couldn't hook " .. path) end
        end
    end
end

local function released(key, button)
    if not valid(button) then return false end
    local down = button:IsPressed()
    local was = W.down[key]
    W.down[key] = down
    return was and not down
end

-- Every frame in the lobby. crew = hired crewmates (slot order), preview = a recruit to show on a free stand (or nil).
-- Returns the slot clicked ({ index, crewmate or nil }) or nil.
local OFF_NAME = "crewlobby_off" -- (config/) debugging: "all", "stands" or "slots"
local off, offChecked = nil, -1
function L.tick(pc, crew, preview)
    if os.clock() - offChecked > 2 then
        offChecked = os.clock()
        local v = require("config").line(OFF_NAME)
        off = v and (v ~= "" and v or "all") or nil
    end
    if off == "all" then return nil end
    local world = pc:GetWorld()
    local key = valid(world) and world:GetAddress()
    if not key then return nil end
    if not W or W.key ~= key then
        if not cache then loadCache() end
        -- Portraits carry over: they're rooted (one per crewmate for the session), so a new set per lobby visit would
        -- pile up.
        W = { key = key, stands = {}, slotSig = {}, standSig = {}, down = {}, donorQueue = {}, photoQueue = {},
            portraits = W and W.portraits or {}, photoSig = W and W.photoSig or {}, nextFind = 0 }
    end
    local now = os.clock()
    if now >= W.nextFind then
        W.nextFind = now + 5
        if not (valid(W.stands[1]) and valid(W.stands[2]) and valid(W.stands[3])) then
            for _, a in ipairs(FindAllOf("MM_PlayerChar_C") or {}) do
                if real(a) and not a.isPlayer and a.CharID >= 1 and a.CharID <= 3 then W.stands[a.CharID] = a end
            end
        end
        local ok = true
        for i = 1, 3 do ok = ok and valid(W.slots and W.slots[i]) end
        if not ok then findSlots() W.slotSig = {} end
        hookSlots()
    end
    if not valid(W.stands[1]) then return nil end
    -- Stands and slots are synced ten times a second, not every frame: their signatures are string building, and
    -- nothing here changes faster than a menu click (the hire section was ~12 ms a second in the lobby).
    if now >= (W.nextSync or 0) then
        W.nextSync = now + 0.1
        -- who stands where: the crew in slot order; the preview on a free stand, the right-hand one first (the hiring
        -- page covers the left of the screen)
        local want = {}
        for i = 1, 3 do want[i] = crew[i] end
        if preview then
            for _, i in ipairs({ 3, 2, 1 }) do if not want[i] then want[i] = preview break end end
        end
        -- the lobby's own crew refresh (after Play) hides the stands and puts the "+" back in the slots: noticed and undone
        if now >= (W.nextCheck or 0) then
            W.nextCheck = now + 0.5
            for i = 1, 3 do
                local st = W.stands[i]
                if want[i] and valid(st) and (st.bHidden or (known(want[i]) and not wearing(st, want[i]))) then
                    W.standSig[i] = nil
                end
                local w = W.slots and W.slots[i]
                if crew[i] and valid(w) and w.Border_InviteToCrew:IsVisible() then W.slotSig[i] = nil end
            end
        end
        for i = 1, 3 do
            local s, r = W.stands[i], want[i]
            if valid(s) and off ~= "stands" then
                local sig = r and (r.id .. "|" .. sigOf(r) .. "|" .. tostring(known(r))) or "none"
                if W.standSig[i] ~= sig then
                    W.standSig[i] = sig
                    if r then
                        if not known(r) then needMeshes(r) end
                        dress(s, r)
                    else
                        s:SetActorHiddenInGame(true)
                    end
                end
            end
        end
        if off ~= "slots" then for i = 1, 3 do setSlot(i, crew[i]) end end
    end
    local ok, err = pcall(donorStep, now)
    if not ok then X.log("crew lobby donor: " .. tostring(err)) W.donor = nil end
    if not W.donor then
        ok, err = pcall(photoStep, now)
        if not ok then X.log("crew lobby photo: " .. tostring(err)) W.shooting = nil end
    end
    -- clicks on the crew slots
    if clicked then
        local i = clicked
        clicked = nil
        return { index = i, crewmate = crew[i] }
    end
    for i = 1, 3 do
        local w = W.slots and W.slots[i]
        if valid(w) then
            local hit = released("inv" .. i, w.Btn_InviteToCrew) or released("opt" .. i, w.Btn_ShowHideOptions)
                or released("pro" .. i, w.Btn_ViewProfile)
            if crew[i] and valid(w.VerticalBox_PopupMenu) and w.VerticalBox_PopupMenu:IsVisible() then
                w.VerticalBox_PopupMenu:SetVisibility(1) -- the live crew's kick/message/profile menu
            end
            if hit then return { index = i, crewmate = crew[i] } end
        end
    end
    return nil
end

-- A TextBlock of the lobby's own (a crew slot's name), so the hiring page can use the lobby's font.
function L.fontRef()
    local w = W and W.slots and W.slots[1]
    return valid(w) and valid(w.Txt_CrewMembName) and w.Txt_CrewMembName or nil
end

-- Leaving the lobby: the world (and every actor and widget here) goes with it.
function L.reset() W = nil end

function L.init(ctx)
    X = ctx
    valid = ctx.valid
    loadCache()
end

-- A new world: the stands and slots were the lobby's, freed when it unloaded (W is keyed on the world's address, and a
-- new world can land on the old one's address).
function L.reset() W = nil end

return L
