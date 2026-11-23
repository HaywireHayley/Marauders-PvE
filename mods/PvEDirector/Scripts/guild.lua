-- An offlfne gufld (issue #68). Guilds live on PGOS (membership, members, chat) and Nakama (guild XP), and offline
-- PGOS never answers: the lobby's SOCIAL > GUILD page stayed an empty hall, and the TRADE page's GUILD shopkeeper
-- (First Mate Calico) stayed locked behind "join a guild".
-- * The shop: SIGIS_InventoryWidget's Shopkeeper_CheckFactionGuildRankBlocker only asks the game instance's
--   GetMyGuilds for at least one guild (SIGIS_ExampleGameInstance.MyCurrentGuilds, filled by PGOS's guild list). One
--   entry is put there (and put back if anything empties it); buying and selling then go through the usual shop path.
-- * The page: Guild_Widget's GUILD_Widget_OPENED collapses everything and asks PGOS for the guild list; the answer would
--   fill MyCurrentGuild_Info, the info panel and the member rows. Its PGOS answer events can't be called from Lua (their
--   structs hold TMaps, which UE4SS 3.0.1 can't build), so the same fields, texts and rows are set here directly. The
--   Nakama half (GUILD_Get_NakamaGuild_Info / GetGuildProgressionStuff: rank and XP bar) takes a plain struct and is
--   called as is. The hideout panel, guild chat, leave button and the owner's edit panel need PGOS and are hidden.
--   Filled only once the game has opened the page (GUILD_Widget_OPENED): behind the login screen it counts as visible.
-- * Members: you captain it; Haywire Hayley and Lilykoi are officers, and a random handful of the Discord community
--   (drawn once per game start) are crew mates, some shown online.
-- * Editing (EDIT GUILD tab, the captain's): announcement, public or not, join type, patch and tags. Each button's own
--   handler runs (its PGOS request goes nowhere), then a hook applies the change to the page here and keeps it in
--   config/guild.txt. Disband stays hidden.
-- Widgets are kept as object paths and looked up each time (never held: the lobby goes away with each raid).
local G = {}
local X -- log, valid, project (path prefix)

local GUILD_ID, GUILD_NAME = "offline-guild", "Marauders"
local GUILD_TAGS = "Casual,TeamPlayers" -- (E_GuildTags names, as the game keeps them)
local GUILD_DESC = "Marauders flying together offline."
local GUILD_XP = 500 -- rank 5 (GuildXpToLevel)
local MAX_MEMBERS = 50
local CAPTAIN = "Haywire Hayley" -- (when your name can't be read; otherwise an officer)
local OFFICERS = { "Lilykoi" }
local JOIN_TYPES = { [0] = "OPEN TO ANYONE", "INVITE ONLY", "CLOSED TO ALL" } -- (CombList_MyGuild_Edit_JoinType's order)
-- the crew mate pool (the Marauders Discord, 2026-11-16)
local POOL = {
    "Alec-Wan_Kenobi", "AtomicSheriff", "Camo Hat Man", "ChurchOfHusk", "Geneysis", "H1tSc4n", "IvanTheThicc",
    "Karporatuv", "KKACHI", "METTCtheDoc", "Nightstream", "no_portobello", "Seventh Wook", "SuperChicken",
    "tarzanjannik", "Why Is Discrud Free?", "Yung Shino", "[DQ] Swat", "Anthony Hulse", "Chadmango", "djbonesdeuce",
    "donmish13", "DouglaSAS", "ElectroRequiem7", "HeartCoded", "Herr Specht", "Jibboo", "Johnny Rico Utah", "Koz",
    "Lzy1", "NEO", "NebulA", "Rico_C", "spork", "The Devil", "Void Vix", "YummyBunny",
}
local CREW_MIN, CREW_MAX = 10, 16
local ONLINE_CHANCE = 0.3
local ONLINE = 1 -- EClientOnlineStatus: 0 offline, 1 online
local DAY = 86400

local CLASS_ROW = "/SIGISPlugin/Widgets/MainMenu/Guild/Guild_Member_Row_SubWidget.Guild_Member_Row_SubWidget_C"
local ROW_BUTTONS = { "Btn_ViewProfile", "Btn_SendMessage", "Btn_InviteToCrew" } -- (all PGOS)
local OFFLINE_ONLY = { "Border_GuildHideOut", "SizeBox_GuildChat", "Btn_TEMP_Guild_MyGuild_Member_Leave",
    "Border_Permissions_OwnerOnly_Disband" } -- (PGOS: hideout servers, chat, leaving, disbanding)
local OWNER_TABS = { "Btn_GuildTab_EditGuild", "MM_GuildTab_EditGuild", "SizeBox_ApperanceSubTabsDivide" }

-- The edit panel's buttons (Guild_Widget_C bound events) and what each applies.
local EV = "/SIGISPlugin/Widgets/MainMenu/Guild_Widget.Guild_Widget_C:BndEvt__Guild_Widget_"
local EDITS = {
    announce = EV .. "Btn_TEMP_Guild_MyGuildEdit_Announcement_K2Node_ComponentBoundEvent_16_OnButtonPressedEvent__DelegateSignature",
    clear = EV .. "Btn_TEMP_Guild_MyGuildEdit_Announcement_Remove_K2Node_ComponentBoundEvent_27_OnButtonPressedEvent__DelegateSignature",
    patch = EV .. "Btn_TEMP_Guild_MyGuild_Edit_PatchLook_K2Node_ComponentBoundEvent_35_OnButtonPressedEvent__DelegateSignature",
    -- (APPLY NEW TAGS: the designer's name for that button is a copy of the visibility one)
    tags = EV .. "Btn_TEMP_Guild_MyGuildEdit_PubliclyVisible_1_K2Node_ComponentBoundEvent_4_OnButtonPressedEvent__DelegateSignature",
    public = EV .. "CB_TEMP_MyGuild_Edit_isPublic_K2Node_ComponentBoundEvent_44_OnCheckBoxComponentStateChanged__DelegateSignature",
    join = EV .. "CombList_MyGuild_Edit_JoinType_K2Node_ComponentBoundEvent_45_OnSelectionChangedEvent__DelegateSignature",
}

-- What the captain has set, kept in config/guild.txt (key=value lines; "\\n" for a new line in the announcement).
local saved = { announcement = "", public = "0", join = "1", patch = "0-0-0", tags = GUILD_TAGS }
local hookedAt = {} -- hook name -> the UFunction address it was registered on

local members  -- { name, role ("owner" / "admin" / "crew"), online, joined (unix seconds) }, drawn once
local giPath, pagePath
local nextFind, nextLogin, hookAt, findEvery = 0, 0, 0, nil
local dressed = {} -- page path -> true once its rows are built
local opened = {}  -- page path -> true once the game has opened it (GUILD_Widget_OPENED)
local loggedIn = false
local OPENED = "/SIGISPlugin/Widgets/MainMenu/Guild_Widget.Guild_Widget_C:GUILD_Widget_OPENED"

local function configFile() return X.project .. "config/guild.txt" end

local function load()
    local f = io.open(configFile(), "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.*)$")
        if k and saved[k] ~= nil then saved[k] = (v:gsub("\\n", "\n")) end
    end
    f:close()
end

local function save()
    local f = io.open(configFile(), "w")
    if not f then return end
    for _, k in ipairs({ "announcement", "public", "join", "patch", "tags" }) do
        f:write(k, "=", (tostring(saved[k]):gsub("\r?\n", "\\n")), "\n")
    end
    f:close()
end

function G.init(ctx)
    X = ctx
    pcall(load)
end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function live(path)
    local o = path and StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local function draw(me)
    local now = os.time()
    local function m(name, role)
        return { name = name, role = role, online = math.random() < ONLINE_CHANCE,
                 joined = now - math.random(3, 200) * DAY - math.random(0, DAY) }
    end
    members = {}
    if me and me ~= "" then
        local you = m(me, "owner")
        you.online, you.joined, you.me = true, now - 200 * DAY, true
        members[1] = you
        members[2] = m(CAPTAIN, "admin")
    else
        members[1] = m(CAPTAIN, "owner")
    end
    for _, n in ipairs(OFFICERS) do members[#members + 1] = m(n, "admin") end
    local pool = {}
    for i, n in ipairs(POOL) do pool[i] = n end
    for i = #pool, 2, -1 do local j = math.random(i) pool[i], pool[j] = pool[j], pool[i] end
    for i = 1, math.random(CREW_MIN, CREW_MAX) do members[#members + 1] = m(pool[i], "crew") end
end

local function captain()
    for _, m in ipairs(members) do if m.role == "owner" then return m end end
end

-- Your name as the stand-in knows it (its save's display_name: what the game shows for you, getsteaminfo's nick).
local function myName()
    local f = io.open(require("pvebackend") .. "state.json", "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text:match('"display_name"%s*:%s*"([^"\\]*)"')
end

-- The game instance's guild list: one guild, so the GUILD shopkeeper opens.
local function keepGuild()
    local gi = live(giPath)
    if not gi then
        gi = FindFirstOf("SIGIS_ExampleGameInstance_C")
        if not X.valid(gi) then return end
        giPath = pathOf(gi)
    end
    local list = gi.MyCurrentGuilds
    if list:GetArrayNum() > 0 then return end
    list[1] = { unread_count = 0 }
    local g = gi.MyCurrentGuilds[1].group_brief
    g.group_id, g.Name, g.Icon = GUILD_ID, GUILD_NAME, saved.patch
    X.log("guild: offline guild set (the GUILD shopkeeper opens)")
end

local function setText(w, s)
    if X.valid(w) then w:SetText(FText(s)) end
end

local function count(role)
    local n = 0
    for _, m in ipairs(members) do if m.role == role then n = n + 1 end end
    return n
end

-- The member rows, made like the page's own (Guild_Member_Row_SubWidget, its GroupMemberInfo filled before it's added,
-- so its Construct shows the name, status and "Member For").
local function buildRows(w, pc)
    local cls = StaticFindObject(CLASS_ROW)
    if not X.valid(cls) then return false end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local boxes = { owner = w.VerticalBox_MembersList_Owner, admin = w.VerticalBox_MembersList_OFFICER,
                    crew = w.VerticalBox_MembersList_CREWMATE }
    for _, b in pairs(boxes) do if X.valid(b) then b:ClearChildren() end end
    for _, m in ipairs(members) do
        local row = lib:Create(w, cls, pc)
        if X.valid(row) then
            local g = row.GroupMemberInfo
            g.nickname = m.name
            g.player_info.display_name = m.name
            g.player_info.player_id = "offline-" .. m.name
            g.is_owner, g.is_admin = m.role == "owner", m.role == "admin"
            g.joined_time = m.joined
            g.player_presence.Status = m.online and ONLINE or 0
            local box = boxes[m.role]
            if X.valid(box) then box:AddChildToVerticalBox(row) end
            for _, k in ipairs(ROW_BUTTONS) do pcall(function() row[k]:SetVisibility(1) end) end -- Collapsed
        end
    end
    setText(w.Txt_HowManyGuildMembers, ("(%d/%d)"):format(#members, MAX_MEMBERS))
    setText(w.Txt_NumberOfOfficers, ("( %d )"):format(count("admin")))
    setText(w.Txt_NumberOfCrewmates, ("( %d )"):format(count("crew")))
    return true
end

local function patchParts()
    local d, p, c = saved.patch:match("^(%d+)-(%d+)-(%d+)$")
    return tonumber(d) or 0, tonumber(p) or 0, tonumber(c) or 0
end

-- The texts the edit panel changes, from `saved`.
local function showSaved(w)
    -- (the tags' own names, "HelpingHand": spaced as their buttons show them)
    local shown = saved.tags:gsub("(%l)(%u)", "%1 %2"):gsub(",", ", ")
    setText(w.Txt_PGOS_MyGuild_Tags, shown ~= "" and shown or "-")
    setText(w.Txt_PGOS_MyGuild_invites, JOIN_TYPES[tonumber(saved.join) or 1] or JOIN_TYPES[1]) -- (JOIN TYPE)
    setText(w.Txt_PGOS_MyGuild_isPublic, saved.public == "1" and "YES" or "NO")
    setText(w.Txt_PGOS_MyGuild_AnnouncmentMessage, saved.announcement)
    pcall(function() w.Border_GuildAnnouncment:SetVisibility(saved.announcement ~= "" and 4 or 1) end)
    local d, p, c = patchParts()
    w.MyCurrentGuild_Info.Icon = saved.patch
    pcall(function() w:Refresh_MyCurrentGuild_Patch(d, p, c) end) -- (the badge next to the guild's name)
end

-- The guild page, as the PGOS answers would leave it.
local function dress(w, pc)
    local cap = captain()
    local i = w.MyCurrentGuild_Info
    i.group_id, i.Name, i.Description = GUILD_ID, GUILD_NAME, GUILD_DESC
    i.member_count, i.max_members = #members, MAX_MEMBERS
    i.owner_info.display_name = cap.name
    w.Border_MyCurrentGuildInfo:SetVisibility(0)      -- Visible
    w.VerticalBox_MyGuildCurrent_Info:SetVisibility(4) -- SelfHitTestInvisible
    w.Border_MyGuildCurrent_NotInGuild:SetVisibility(1) -- Collapsed
    for _, k in ipairs(OFFLINE_ONLY) do pcall(function() w[k]:SetVisibility(1) end) end
    -- you're the captain: the EDIT GUILD tab (the game shows it from its member-details answer)
    local mine = cap.me == true
    pcall(function() w.MyCurrentGuild_AmIOwner = mine end)
    pcall(function() w.MyOwnGuildMemberDetails.is_owner = mine end)
    for _, k in ipairs(OWNER_TABS) do pcall(function() w[k]:SetVisibility(mine and 0 or 1) end) end
    -- the SUMMARY tab's layout (as its button leaves it)
    for k, v in pairs({ SizeBox_GeneralGuildInfo = 4, SizeBox_Guild_Extrabits = 4, SizeBox_MemberList = 4,
                        SizeBox_PermissionBasedStuff = 1, SizeBox_GuildProgression = 1 }) do
        pcall(function() w[k]:SetVisibility(v) end)
    end
    pcall(function() w:SetGuildTabsVisuals(w.Btn_GuildTab_Summary) end)
    setText(w.Txt_PGOS_MyGuild_Name, GUILD_NAME)
    setText(w.Txt_PGOS_MyGuild_Owner, cap.name)
    setText(w.Txt_PGOS_MyGuild_ID, GUILD_ID)
    setText(w.Txt_PGOS_MyGuild_Desc, GUILD_DESC)
    setText(w.Txt_PGOS_MyGuild_NumMembers, ("%d / %d"):format(#members, MAX_MEMBERS))
    setText(w.Txt_PGOS_Guild_HowManyGuildsPartOf, "1")
    -- the badges' materials (set by Initialise_Guild_My_Info, which only the PGOS path runs): without them the patch
    -- refreshes draw nothing new
    pcall(function()
        w.MyCurrentGuild_Patch_DMAT = w.Border_TEMP_MyGuild_PatchLook_:GetDynamicMaterial()
        w.MyCurrentGuild_Patch_Edit_DMAT = w.Border_TEMP_CurrentPatchLook_EditPatch:GetDynamicMaterial()
    end)
    showSaved(w)
    -- the edit panel starts from what's saved
    pcall(function() w.CB_TEMP_MyGuild_Edit_isPublic:SetIsChecked(saved.public == "1") end)
    pcall(function() w.CombList_MyGuild_Edit_JoinType:SetSelectedIndex(tonumber(saved.join) or 1) end)
    pcall(function() w.MultiLineEditableTextBox_TEMP_PGOS_GuildEdit_Announcement:SetText(FText(saved.announcement)) end)
    local d, p, c = patchParts()
    pcall(function()
        w.Edited_Current_Patch_Design, w.Edited_Current_Patch_PrimColour, w.Edited_Current_Patch_SecColour = d, p, c
        w:Refresh_MyCurrentGuild_Edit_PatchLook(d, p, c)
    end)
    pcall(function() -- (the tag buttons the saved tags select: each button's label is its tag's name, spaced)
        local want, n = {}, 0
        for tag in saved.tags:gmatch("[^,]+") do want[tag] = true end
        local box = w.WrapBox_GuildEditTags
        for k = 0, box:GetChildrenCount() - 1 do
            local b = box:GetChildAt(k)
            local on = X.valid(b) and want[(b.txt_GuildTagName:GetText():ToString():gsub("%s", ""))] == true
            if X.valid(b) then
                b["Is Selected"] = on
                b:isTagSelected(on)
                if on then n = n + 1 end
            end
        end
        w.GuildTagsActive_EditGuild = n
        setText(w.Txt_GuildEdit_TagCurrentMax_EditGuild, n .. " / 5")
    end)
    local nak = { GuildXP = GUILD_XP, GuildUnlocks = {}, numOfActiveServer = 0 }
    pcall(function() w:GUILD_Get_NakamaGuild_Info(nak) end)
    pcall(function() w:GetGuildProgressionStuff(nak) end)
    local path = pathOf(w)
    if not dressed[path] then dressed[path] = buildRows(w, pc) end
end

-- An edit button was used (its handler has run): take the new value from the panel, show it, keep it.
local APPLY = {
    announce = function(w)
        local t = w.MultiLineEditableTextBox_TEMP_PGOS_GuildEdit_Announcement:GetText():ToString()
        if t:match("^%s*$") then return end
        saved.announcement = t
    end,
    clear = function() saved.announcement = "" end,
    public = function(w) saved.public = w.CB_TEMP_MyGuild_Edit_isPublic:IsChecked() and "1" or "0" end,
    join = function(w)
        local n = w.CombList_MyGuild_Edit_JoinType:GetSelectedIndex()
        if JOIN_TYPES[n] then saved.join = tostring(n) end
    end,
    patch = function(w)
        saved.patch = ("%d-%d-%d"):format(w.Edited_Current_Patch_Design, w.Edited_Current_Patch_PrimColour,
            w.Edited_Current_Patch_SecColour)
        local gi = live(giPath)
        if gi and gi.MyCurrentGuilds:GetArrayNum() > 0 then gi.MyCurrentGuilds[1].group_brief.Icon = saved.patch end
    end,
    tags = function(w)
        local t = {}
        w.EditGuild_Tags:ForEach(function(_, e) t[#t + 1] = e:get():ToString() end)
        saved.tags = table.concat(t, ",")
    end,
}

local function edited(what, w)
    if not (X.valid(w) and members and captain().me) then return end
    APPLY[what](w)
    save()
    showSaved(w)
    X.log("guild: " .. what .. " changed (config/guild.txt)")
end

-- Every frame in the lobby (from lobbylabel.lua): the page collapses its panels each time it opens; they're put back
-- in the same frame. Cheap: one lookup and a visibility check.
function G.frame()
    if not members then return end
    -- (only once the game has opened the page: behind the login screen it counts as visible too, and filling it there
    -- crashed the game at Login)
    if not (pagePath and opened[pagePath]) then return end
    local w = live(pagePath)
    if not w then
        -- The page is gone (a raid took the lobby down). Forget it: a StaticFindObject of a path that doesn't exist
        -- walks every object in the game, and this ran each frame for the rest of the session: raids at 10 fps after
        -- opening the GUILD tab once (issue #112). G.tick finds the next lobby's page.
        opened[pagePath], dressed[pagePath], pagePath = nil, nil, nil
        return
    end
    if not w:IsVisible() then return end
    -- (Visible info, Collapsed "not in a guild" and hideout panel: already dressed)
    if w.Border_MyCurrentGuildInfo:GetVisibility() == 0 and w.Border_MyGuildCurrent_NotInGuild:GetVisibility() == 1
        and w.Border_GuildHideOut:GetVisibility() == 1 then return end
    local pc = require("cache").menuPc()
    if X.valid(pc) then dress(w, pc) end
end

-- Every check (once a second) in the lobby, from lobbylabel.lua.
function G.tick()
    local now = os.clock()
    -- Nothing before Login: the lobby ticks behind the login screen, before the game has set itself up.
    if not loggedIn then
        if now < nextLogin then return end
        nextLogin = now + 2
        loggedIn = true
        for _, w in ipairs(FindAllOf("SIGIS_LoginWidget_C") or {}) do
            if w:GetFullName():find("Transient", 1, true) and w:IsVisible() then loggedIn = false end
        end
        if not loggedIn then return end
    end
    keepGuild()
    if now >= hookAt then
        hookAt = now + 2
        -- (pre-callbacks: these Blueprint events' bodies have already run; registered again if the class reloads)
        local function hook(name, path, fn)
            local f = StaticFindObject(path)
            if not (f and f:IsValid()) or f:GetAddress() == hookedAt[name] then return end
            if pcall(RegisterHook, path, function(ctx)
                local ok, err = pcall(fn, ctx:get())
                if not ok then X.log("guild: " .. name .. " failed: " .. tostring(err)) end
            end) then hookedAt[name] = f:GetAddress() end
        end
        hook("opened", OPENED, function(w) opened[pathOf(w)] = true end)
        for what, path in pairs(EDITS) do hook(what, path, function(w) edited(what, w) end) end
    end
    if not live(pagePath) and now >= nextFind then
        findEvery = math.min(60, (findEvery or 2.5) * 2)
        nextFind = now + findEvery -- (a FindAllOf, ~50 ms: only until the lobby's page exists; 5 s backing off to 60 s)
        pagePath = nil
        for _, w in ipairs(FindAllOf("Guild_Widget_C") or {}) do
            local name = pathOf(w)
            if name:find("Transient", 1, true) then pagePath = name findEvery = nil end -- (the overlay's own page, not its class's template)
        end
    end
    if not members and pagePath then
        local ok, me = pcall(myName)
        draw(ok and me or nil)
    end
end

return G
