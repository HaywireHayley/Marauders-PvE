-- An offline guild (issue #68). Guilds live on PGOS (membership, members, chat) and Nakama (guild XP), and offline
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
-- * Members: Haywire Hayley captains, Lilykoi is an officer, and a random handful of the Discord community (drawn once
--   per game start) are crew mates, some shown online, plus you.
-- Widgets are kept as object paths and looked up each time (never held: the lobby goes away with each raid).
local G = {}
local X -- log, valid, project (path prefix)

local GUILD_ID, GUILD_NAME, GUILD_TAGS = "offline-guild", "Marauders", "PVE"
local GUILD_DESC = "Marauders flying together offline."
local GUILD_XP = 500 -- rank 5 (GuildXpToLevel)
local MAX_MEMBERS = 50
local CAPTAIN = "Haywire Hayley"
local OFFICERS = { "Lilykoi" }
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
    "SizeBox_PermissionBasedStuff" } -- (PGOS: hideout servers, chat, leaving; the owner's edit and disband panel)

local members  -- { name, role ("owner" / "admin" / "crew"), online, joined (unix seconds) }, drawn once
local giPath, pagePath
local nextFind, nextLogin, hookAt, hookedAddr = 0, 0, 0, nil
local dressed = {} -- page path -> true once its rows are built
local opened = {}  -- page path -> true once the game has opened it (GUILD_Widget_OPENED)
local loggedIn = false
local OPENED = "/SIGISPlugin/Widgets/MainMenu/Guild_Widget.Guild_Widget_C:GUILD_Widget_OPENED"

function G.init(ctx) X = ctx end

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
    members = { m(CAPTAIN, "owner") }
    for _, n in ipairs(OFFICERS) do members[#members + 1] = m(n, "admin") end
    local pool = {}
    for i, n in ipairs(POOL) do pool[i] = n end
    for i = #pool, 2, -1 do local j = math.random(i) pool[i], pool[j] = pool[j], pool[i] end
    for i = 1, math.random(CREW_MIN, CREW_MAX) do members[#members + 1] = m(pool[i], "crew") end
    if me and me ~= "" then
        local you = m(me, "crew")
        you.online, you.joined = true, now - 2 * DAY
        members[#members + 1] = you
    end
end

-- Your name as the stand-in knows it (its save's display_name: what the game shows for you, getsteaminfo's nick).
local function myName()
    local f = io.open(X.project .. "backend/state.json", "r")
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
    g.group_id, g.Name = GUILD_ID, GUILD_NAME
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

-- The guild page, as the PGOS answers would leave it.
local function dress(w, pc)
    local i = w.MyCurrentGuild_Info
    i.group_id, i.Name, i.Description, i.Icon = GUILD_ID, GUILD_NAME, GUILD_DESC, "0-0-0"
    i.member_count, i.max_members = #members, MAX_MEMBERS
    i.owner_info.display_name = CAPTAIN
    w.Border_MyCurrentGuildInfo:SetVisibility(0)      -- Visible
    w.VerticalBox_MyGuildCurrent_Info:SetVisibility(4) -- SelfHitTestInvisible
    w.Border_MyGuildCurrent_NotInGuild:SetVisibility(1) -- Collapsed
    for _, k in ipairs(OFFLINE_ONLY) do pcall(function() w[k]:SetVisibility(1) end) end
    setText(w.Txt_PGOS_MyGuild_Name, GUILD_NAME)
    setText(w.Txt_PGOS_MyGuild_Owner, CAPTAIN)
    setText(w.Txt_PGOS_MyGuild_ID, GUILD_ID)
    setText(w.Txt_PGOS_MyGuild_Desc, GUILD_DESC)
    setText(w.Txt_PGOS_MyGuild_Tags, GUILD_TAGS)
    setText(w.Txt_PGOS_MyGuild_invites, "INVITE ONLY") -- (JOIN TYPE)
    setText(w.Txt_PGOS_MyGuild_isPublic, "NO")
    setText(w.Txt_PGOS_MyGuild_NumMembers, ("%d / %d"):format(#members, MAX_MEMBERS))
    setText(w.Txt_PGOS_Guild_HowManyGuildsPartOf, "1")
    local nak = { GuildXP = GUILD_XP, GuildUnlocks = {}, numOfActiveServer = 0 }
    pcall(function() w:GUILD_Get_NakamaGuild_Info(nak) end)
    pcall(function() w:GetGuildProgressionStuff(nak) end)
    local path = pathOf(w)
    if not dressed[path] then dressed[path] = buildRows(w, pc) end
end

-- Every frame in the lobby (from lobbylabel.lua): the page collapses its panels each time it opens; they're put back
-- in the same frame. Cheap: one lookup and a visibility check.
function G.frame()
    if not members then return end
    -- (only once the game has opened the page: behind the login screen it counts as visible too, and filling it there
    -- crashed the game at Login)
    if not (pagePath and opened[pagePath]) then return end
    local w = live(pagePath)
    if not (w and w:IsVisible()) then return end
    -- (Visible info, Collapsed "not in a guild" and hideout panel: already dressed)
    if w.Border_MyCurrentGuildInfo:GetVisibility() == 0 and w.Border_MyGuildCurrent_NotInGuild:GetVisibility() == 1
        and w.Border_GuildHideOut:GetVisibility() == 1 and w.SizeBox_PermissionBasedStuff:GetVisibility() == 1 then return end
    local pc = FindFirstOf("MenuPlayerController_C")
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
        local fn = StaticFindObject(OPENED)
        if fn and fn:IsValid() and fn:GetAddress() ~= hookedAddr then
            local ok = pcall(RegisterHook, OPENED, function(ctx)
                local okPath, path = pcall(function() return pathOf(ctx:get()) end)
                if okPath then opened[path] = true end
            end)
            if ok then hookedAddr = fn:GetAddress() end
        end
    end
    if not live(pagePath) and now >= nextFind then
        nextFind = now + 5 -- (a FindAllOf, ~50 ms: only until the lobby's page exists)
        pagePath = nil
        for _, w in ipairs(FindAllOf("Guild_Widget_C") or {}) do
            local name = pathOf(w)
            if name:find("Transient", 1, true) then pagePath = name end -- (the overlay's own page, not its class's template)
        end
    end
    if not members and pagePath then
        local ok, me = pcall(myName)
        draw(ok and me or nil)
    end
end

return G
