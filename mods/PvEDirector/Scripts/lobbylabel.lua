-- The lobby's START MATCHMAKING button says START RAID offline: there's no search, it loads a raid straight away
-- (main.lua onStartMatchmaking). The label is TextBlock_31 inside Crew_LaunchToMatchBtn_SubWidget_C (Captain and
-- Crewmember copies), a plain widget of its WidgetTree with no variable of its own.
-- The buttons are found once per lobby with a FindAllOf (about 50 ms), and kept as object paths, not objects: each
-- check looks them up again (StaticFindObject, a name lookup), so a lobby torn down by a raid is never touched.
local L = {}
local X -- log, offline (function)

local CHECK_SECONDS = 1
local LABEL = "START RAID"
local paths, nextCheck, nextFind = nil, 0, 0
-- The new-player Guide: a fresh account's first lobby opens it by itself (Guide_Widget_C:FreshAccount_RunGuide, a
-- popup of its own on the game instance, not the lobby's embedded Guide_Widget), and its YouTube video can't load
-- offline. For GUIDE_WATCH s after the session's first lobby, that popup is closed (ForceCloseTheGuideWidget). One
-- you open yourself later (the pause menu's GUIDE) is left alone.
local GUIDE_WATCH, GUIDE_EVERY = 60, 2 -- (it opened ~15 s after the lobby in testing)
local guideUntil, nextGuide = nil, 0
-- Gear put on or taken off on LOADOUT didn't show on your character until you switched tabs (issue #29). While
-- LOADOUT is the selected tab, the equipped items are compared each check, and on a change LOADOUT is "pressed" again
-- through the overlay's own handler, SIGIS_MainOverlay_C:CoreMM_Tab_Pressed(1), which is what a tab click runs (calling
-- its inner refreshes, RefreshMenuPlayerActor or OPENED_GearMenu, alone didn't redress the character).
local LOADOUT_STATE = 1                       -- MM_CoreMM_TabBtns_Loadout.Which_CoreMenuState
local NOT_EQUIPPED = { Stash = true, Lobby = true, Gift = true, scrap = true, Shop = true, LootCon = true,
    LootPocketLeft = true, PocketLeft = true, PocketRight = true, KeyCard = true }
local gear = {}                               -- overlay, tab, inv: paths; seen: the last equipped set

function L.init(ctx) X = ctx end

local function live(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local function findGear()
    gear = {}
    for _, w in ipairs(FindAllOf("SIGIS_MainOverlay_C") or {}) do
        local name = w:GetFullName():gsub("^%S+ ", "")
        if name:find("Transient", 1, true) then gear.overlay = name end
    end
    if gear.overlay then gear.tab = gear.overlay .. ".WidgetTree.MM_CoreMM_TabBtns_Loadout" end
    local inv = FindFirstOf("SIGISInventoryComponent")
    if inv and inv:IsValid() then gear.inv = (inv:GetFullName():gsub("^%S+ ", "")) end
end

-- What's in your equipment slots (head, chest, guns, bag...): the item ids and slots, sorted into one string.
local function equipped(inv)
    local out = {}
    inv.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if it and it:IsValid() then
            local con = it.MotherItemGUID:ToString()
            if con:match("^%a+$") and not NOT_EQUIPPED[con] and not con:find("^RigSlot") then
                out[#out + 1] = con .. "=" .. it.UniqueItemGUID:ToString()
            end
        end
    end)
    table.sort(out)
    return table.concat(out, ",")
end

local function gearTick()
    local overlay, tab, inv = live(gear.overlay), live(gear.tab), live(gear.inv)
    if not (overlay and tab and inv) then
        local t = os.clock()
        if t >= (gear.nextFind or 0) then findGear() gear.nextFind = t + 5 end -- (FindAllOf ~50 ms; the lobby may not be up yet)
        return
    end
    if not tab.isSelected then gear.seen = nil return end
    local now = equipped(inv)
    if gear.seen and now ~= gear.seen then
        overlay:CoreMM_Tab_Pressed(LOADOUT_STATE)
        X.log("lobby: gear changed, character redressed")
    end
    gear.seen = now
end

local function find()
    paths = {}
    for _, w in ipairs(FindAllOf("Crew_LaunchToMatchBtn_SubWidget_C") or {}) do
        local name = w:GetFullName():gsub("^%S+ ", "") -- (the class name comes first)
        if name:find("Transient", 1, true) then
            -- (UWidgetTree::FindWidget isn't callable from Lua; the label's path follows from the button's)
            local path = name .. ".WidgetTree.TextBlock_31"
            local t = StaticFindObject(path)
            if t and t:IsValid() then paths[#paths + 1] = path end
        end
    end
end

-- Every frame from the director's tick (ticker: the object it ticks on, the lobby's MM_CoreMissions there); only does
-- anything in the lobby with the offline backend.
function L.tick(ticker)
    local now = os.clock()
    if PveMapPick then pcall(PveMapPick.frame) end -- (new picker buttons, before they can be clicked)
    if PveGuild then pcall(PveGuild.frame) end -- (the guild page, the frame it opens)
    if now < nextCheck then return end
    nextCheck = now + CHECK_SECONDS
    local inLobby = ticker:IsValid() and ticker:GetClass():GetFName():ToString() == "MM_CoreMissions_C"
    if not (inLobby and X.offline()) then paths, gear = nil, {} return end
    if PveMapPick then
        local okPick, errPick = pcall(PveMapPick.tick)
        if not okPick and not gear.pickErr then gear.pickErr = true X.log("lobby: map picker failed: " .. tostring(errPick)) end
    end
    if PveGuild then
        local okGuild, errGuild = pcall(PveGuild.tick)
        if not okGuild and not gear.guildErr then gear.guildErr = true X.log("lobby: offline guild failed: " .. tostring(errGuild)) end
    end
    local okGear, errGear = pcall(gearTick)
    if not okGear and not gear.err then gear.err = true X.log("lobby: gear refresh failed: " .. tostring(errGear)) end
    guideUntil = guideUntil or now + GUIDE_WATCH
    if now < guideUntil and now >= nextGuide then
        nextGuide = now + GUIDE_EVERY
        for _, w in ipairs(FindAllOf("Guide_Widget_C") or {}) do
            local name = w:GetFullName()
            if name:find("Transient", 1, true) and not name:find("WidgetTree", 1, true) and w:IsInViewport() then
                w:ForceCloseTheGuideWidget()
                X.log("lobby: closed the new-player guide (its video needs the internet)")
                guideUntil = now -- once
            end
        end
    end
    if not paths or #paths == 0 then
        if now < nextFind then return end
        nextFind = now + 5 -- the lobby's widgets may not exist yet
        find()
        if #paths > 0 then X.log(("lobby: launch button relabelled %s (%d)"):format(LABEL, #paths)) end
    end
    for i = #paths, 1, -1 do
        local t = StaticFindObject(paths[i])
        if t and t:IsValid() then
            if t:GetText():ToString() ~= LABEL then t:SetText(FText(LABEL)) end
        else
            table.remove(paths, i) -- gone: found again on the next pass
        end
    end
end

return L
