-- Choose the raid map in the lobby (issue #54). Offline the REGION box next to START RAID means nothing, and its
-- picker has six region buttons (SIGIS_MatchmakingRegion_Subwidget_C, region 0..5): one per space map. They're
-- relabelled with map names, and a seventh, RANDOM, is added (the game ignores a click on the region already picked,
-- so "click it again for random" couldn't work); clicking one picks that map for START RAID. The box itself shows the
-- pick (or RANDOM MAP). The pick is kept in config/raid_map.txt; bridge/map_pin (tests) still overrides it.
-- Widgets are kept as object paths and looked up each time (never held: the lobby goes away with each raid). The
-- click comes from a hook on the button's own pressed event; the game stores the choice in
-- SIGISGameInstancePGOS.ActiveMMRegion, but its default (0) can't tell "untouched" from "picked region 0".
local M = {}
local X -- log, valid, project (path prefix)

-- region -> map (the regions' own order in the picker: USA WEST 1, USA SOUTH 2, EU CENTRAL 3, ASIA NORTH 4,
-- ASIA SOUTH 5, USA EAST 0)
local MAPS = {
-- { map, button, line under the name, stations seen there (UE4SS.log "[rivals] stations:" lines, NOTES survey) }
    [1] = { "Space_Solo_01", "SOLO 1", "solo map", "Spaceport, Fortress, merchant ships" },
    [2] = { "Space_Solo_02", "SOLO 2", "solo map", "Penal Colony, Rebel Base, Mini Mine, Asteroid Mine, Capital Ship" },
    [3] = { "Space_Alpha", "ALPHA", "crew map", "Rebel Base, Spaceport, Fortress" },
    [4] = { "Space_Beta", "BETA", "crew map", "Penal Colony, Asteroid Mine, Capital Ship" },
    [5] = { "Space_Charlie", "CHARLIE", "crew map", "Mini Mine, Colony Cruiser, Planet Killer" },
    [0] = { "Space_Delta", "DELTA", "crew map", "Navy Outpost, Moon Base, merchant ships" },
}
local RANDOM = "RANDOM MAP"
local RANDOM_REGION = 99 -- our seventh button's region: no map, a random pick
local PRESSED = "/SIGISPlugin/Widgets/MainMenu/MatchmakingSettings/SIGIS_MatchmakingRegion_Subwidget.SIGIS_MatchmakingRegion_Subwidget_C:"
    .. "BndEvt__SIGIS_MatchmakingRegion_Subwidget_Btn_MatchmakingSetting_K2Node_ComponentBoundEvent_1_OnButtonPressedEvent__DelegateSignature"
local CLASS = "/SIGISPlugin/Widgets/MainMenu/MatchmakingSettings/SIGIS_MatchmakingRegion_Subwidget.SIGIS_MatchmakingRegion_Subwidget_C"
local BOX_TEXTS = { "Txt_PGOS_Matchmaking_WhichRegion", "Txt_PGOS_Matchmaking_WhichRegion_CrewMember" }

local picked             -- region number, or nil for a random map
local file
local boxes, copies = {}, {}
local nextFind, hookAt, hookedAddr = 0, 0, nil

local function load()
    local f = io.open(file, "r")
    if not f then return end
    local name = (f:read("l") or ""):match("^%s*(.-)%s*$")
    f:close()
    for r, m in pairs(MAPS) do if m[1] == name then picked = r end end
end

local function save()
    if picked == nil then os.remove(file) return end
    local f = io.open(file, "w")
    if f then f:write(MAPS[picked][1], "\n") f:close() end
end

function M.init(ctx)
    X = ctx
    file = X.project .. "config/raid_map.txt"
    load()
end

-- The map START RAID should load, or nil for the usual random pick.
function M.map() return picked ~= nil and MAPS[picked][1] or nil end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function live(path)
    local o = path and StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local lastPress = 0
local function onPressed(ctx)
    local now = os.clock()
    if now - lastPress < 0.5 then return end -- (one click, however many times the event reaches us)
    lastPress = now
    local w = ctx:get()
    local r = w.region
    if r == RANDOM_REGION then
        picked = nil
        -- (the game's own buttons close the picker through a delegate its parent binds to them only)
        for _, sel in ipairs(FindAllOf("Crew_MatchmakingTypeSelect_Widget_C") or {}) do
            if sel:IsValid() and sel:IsVisible() then pcall(function() sel:FORCE_CLOSE_MatchmakingAndRegionSelect() end) end
        end
    elseif MAPS[r] then
        picked = r
    else
        return
    end
    save()
    X.log("map pick: " .. (picked ~= nil and MAPS[picked][1] or "random"))
end

local function setText(t, s)
    if t and t:IsValid() and t:GetText():ToString() ~= s then t:SetText(FText(s)) end
end

-- One picker button: the map's name (the picked one in brackets; RANDOM in brackets when no map is picked),
-- clickable, without the ping line and bad-ping warnings.
local tipped = {} -- button address -> tooltip text set
local function dress(w)
    local name, line, tip
    if w.region == RANDOM_REGION then
        name = picked == nil and "[ RANDOM ]" or "RANDOM"
        line, tip = "any map", "A different map each raid, picked at random from all six."
    elseif MAPS[w.region] then
        local m = MAPS[w.region]
        name = w.region == picked and ("[ " .. m[2] .. " ]") or m[2]
        line = m[3]
        tip = ("%s (%s)\nStations: %s\nWhich stations are there can change from raid to raid."):format(m[1], m[3], m[4])
    else
        return
    end
    setText(w.Txt_RegionName, name)
    local key = w:GetAddress()
    if tipped[key] ~= tip then -- (a hover tooltip, UMG's own: set once per button, and again if the text changes)
        tipped[key] = tip
        pcall(function() w:SetToolTipText(FText(tip)) end)
        pcall(function() w.Btn_MatchmakingSetting:SetToolTipText(FText(tip)) end)
    end
    -- the game disables "bad ping" regions, and offline every ping is 999: all six stay clickable
    local btn = w.Btn_MatchmakingSetting
    if btn and btn:IsValid() and not btn:GetIsEnabled() then btn:SetIsEnabled(true) end
    if not w:GetIsEnabled() then w:SetIsEnabled(true) end
    -- the ping line ("(999ms)": "(" and "ms)" around Txt_PingValue) shows what kind of map it is instead
    local row = w.Txt_PingValue and w.Txt_PingValue:IsValid() and w.Txt_PingValue:GetParent()
    if row and row:IsValid() then
        for i = 0, row:GetChildrenCount() - 1 do
            local t = row:GetChildAt(i)
            if t and t:IsValid() then setText(t, t:GetAddress() == w.Txt_PingValue:GetAddress() and line or "") end
        end
    end
    for _, k in ipairs({ "SizeBox_RegionWarning_Left", "SizeBox_RegionWarning_Left_1", "Border_BadPingArea" }) do
        local x = w[k]
        if x and x:IsValid() and x.Visibility ~= 1 then x:SetVisibility(1) end -- Collapsed
    end
end

-- The game makes the picker's six buttons anew each time it opens: each new one is noted as it's created
-- (NotifyOnNewObject) and dressed on the next frame, before it can be clicked.
local fresh, picker, notified = {}, {}, false -- picker: paths of this opening's buttons (the game's six, then ours)
local ours = {} -- the RANDOM buttons we made (their creation is noticed too: not the game's)
local games = 0 -- the game's buttons in this opening
local addRandom

local function findBoxes()
    boxes, copies = {}, {}
    for _, w in ipairs(FindAllOf("SIGIS_MenuMain_C") or {}) do
        local name = pathOf(w)
        if name:find("Transient", 1, true) then
            for _, t in ipairs(BOX_TEXTS) do boxes[#boxes + 1] = name .. ".WidgetTree." .. t end
        end
    end
    -- the copies inside the matchmaking settings widgets' trees show the current pick, like the box
    for _, w in ipairs(FindAllOf("SIGIS_MatchmakingRegion_Subwidget_C") or {}) do
        local name = pathOf(w)
        if name:find("Transient", 1, true) and name:find("WidgetTree", 1, true) then copies[#copies + 1] = name end
    end
end

-- The seventh button, RANDOM, made like the game's six (it's of their class, so its own pressed event reaches the
-- hook), appended to the picker's WrapBox after them.
addRandom = function(like)
    local box = like:GetParent()
    if not (box and box:IsValid()) then return end
    local pc = FindFirstOf("MenuPlayerController_C")
    if not (pc and pc:IsValid()) then return end
    local b = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, like:GetClass(), pc)
    if not (b and b:IsValid()) then return end
    b.region = RANDOM_REGION
    box:AddChildToWrapBox(b)
    local path = pathOf(b)
    ours[path] = true
    picker[#picker + 1] = path
    dress(b)
end

-- Every frame in the lobby (cheap unless a new picker button is waiting), from lobbylabel.lua.
function M.frame()
    if #fresh == 0 then return end
    local list = fresh
    fresh = {}
    for _, path in ipairs(list) do
        local w = not ours[path] and live(path)
        if w then
            if games >= 6 then picker, games = {}, 0 end -- a new opening: the last one's buttons are gone
            picker[#picker + 1] = path
            games = games + 1
            dress(w)
            if games == 6 then addRandom(w) end
        end
    end
end

-- Every check (once a second) in the lobby, from lobbylabel.lua.
-- A raid takes the lobby down, and its widgets with it. The paths kept for them stay: each check then looked up ~10 dead
-- paths, 15 ms apiece (a StaticFindObject of a path that doesn't exist walks every object), a 150 ms hitch every second in
-- the menu after a raid, and the new lobby's boxes were never looked for (the list wasn't empty). lobbylabel.lua calls this
-- while a raid is on; the checks below also drop any path that has gone.
function M.reset()
    boxes, copies, picker, fresh = {}, {}, {}, {}
end

function M.tick()
    local now = os.clock()
    if not notified then
        notified = pcall(NotifyOnNewObject, CLASS, function(o)
            local name = pathOf(o)
            if not name:find("WidgetTree", 1, true) then fresh[#fresh + 1] = name end
        end)
    end
    if now >= hookAt then
        hookAt = now + 2
        local fn = StaticFindObject(PRESSED)
        if fn and fn:IsValid() and fn:GetAddress() ~= hookedAddr then
            local ok = pcall(RegisterHook, PRESSED, function(ctx)
                local ok2, err = pcall(onPressed, ctx)
                if not ok2 then X.log("map pick failed: " .. tostring(err)) end
            end)
            if ok then hookedAddr = fn:GetAddress() end
        end
    end
    if #boxes == 0 and now >= nextFind then
        nextFind = now + 5 -- (two FindAllOf, ~100 ms: only until the lobby's widgets exist)
        findBoxes()
    end
    local label = picked ~= nil and MAPS[picked][2] or RANDOM
    for i = #boxes, 1, -1 do
        local w = live(boxes[i])
        if w then setText(w, label) else table.remove(boxes, i) end
    end
    for i = #copies, 1, -1 do
        local w = live(copies[i])
        if w then setText(w.Txt_RegionName, label) else table.remove(copies, i) end
    end
    for i = #picker, 1, -1 do
        local w = live(picker[i])
        if w then dress(w) else table.remove(picker, i) end -- (a click moves the brackets)
    end
end

return M
