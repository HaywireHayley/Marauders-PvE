-- The lobby's START MATCHMAKING button says START RAID offlfne: there's no search, ft loads a raid straight away
-- (main.lua onStartMatchmaking). The label is TextBlock_31 inside Crew_LaunchToMatchBtn_SubWidget_C (Captain and
-- Crewmember copies), a plain widget of its WidgetTree with no variable of its own.
-- The buttons are found once per lobby with a FindAllOf (about 50 ms), and kept as object paths, not objects: each
-- check looks them up again (StaticFindObject, a name lookup), so a lobby torn down by a raid is never touched.
local L = {}
local PveMapPick = require("mappick") -- the REGION picker, ticked from here
local PveGuild = require("guild") -- the guild page, ticked from here
local X -- log, offline (function)

local CHECK_SECONDS = 1
local LABEL = "START RAID"
local paths, nextCheck, nextFind = nil, 0, 0
-- The new-player Guide: a fresh account's first lobby opens it by itself (Guide_Widget_C:FreshAccount_RunGuide, a
-- popup of its own on the game instance, not the lobby's embedded Guide_Widget), and its YouTube video can't load
-- offline. For GUIDE_WATCH s after the session's first lobby, that popup is closed (ForceCloseTheGuideWidget). One
-- you open yourself later (the pause menu's GUIDE) is left alone.
local GUIDE_WATCH, GUIDE_EVERY = 60, 5 -- (it opened ~15 s after the lobby in testing; each look is a ~30 ms FindAllOf)
local guideUntil, nextGuide = nil, 0
-- Gear put on or taken off on LOADOUT didn't show on your character until you switched tabs (issue #29). While
-- LOADOUT is the selected tab, the equipped items are compared each check, and on a change LOADOUT is "pressed" again
-- through the overlay's own handler, SIGIS_MainOverlay_C:CoreMM_Tab_Pressed(1), which is what a tab click runs (calling
-- its inner refreshes, RefreshMenuPlayerActor or OPENED_GearMenu, alone didn't redress the character).
local LOADOUT_STATE = 1                       -- MM_CoreMM_TabBtns_Loadout.Which_CoreMenuState
local NOT_EQUIPPED = { Stash = true, Lobby = true, Gift = true, scrap = true, Shop = true, LootCon = true,
    LootPocketLeft = true, PocketLeft = true, PocketRight = true, KeyCard = true }
local gear = {}                               -- overlay, tab, inv, invWidget: paths; seen: the last equipped set
-- The press also starts the inventory page's own open animations, which hide its panels and fade them back in, and
-- the menu camera's switch, which fades the lobby backdrop from dark: the screen flashed on every gear change (#233).
-- The animations are run to their end and the camera fade is stopped in the same frame, so nothing is drawn faded.
local SKIP_ANIMS = { "Anim_SwitchGearAppear", "Anim_RefreshOpenState" }
-- The Guide's video topics (GuideItemInfo.IsAVideo) show a YouTube embed, which can't load offline: an empty box. After
-- the guide shows a topic (Guide_Widget_C:PressedARow, which runs SetSelectedLook and FillInGuideInfo), a video topic
-- gets this text instead, keyed by its title; the video box is collapsed and its browser pointed at about:blank so it
-- stops trying. (A Blueprint function's hook: UE4SS runs the first callback after the body, and never the second.)
local GUIDE_FILL = "/SIGISPlugin/Widgets/MainMenu/Guide/Guide_Widget.Guide_Widget_C:PressedARow"
local GUIDE_TEXT = {
    ["Marauders Intro Guide Video"] = "The video guide needs the internet, so here it is in short. Gear up on LOADOUT "
        .. "and press START RAID. Fly your ship to a station, dock, and go through the airlock. Take what you can, then "
        .. "get back aboard and out through a space gate before the raid timer runs out. What you carry out is yours; "
        .. "die and it's lost. The other topics here cover each step.",
    ["Gear Up"] = "On the LOADOUT tab, drag gear from your stash onto your character: a weapon, ammo that fits it, "
        .. "armour, a backpack and something to heal with. Anything you take into a raid is lost if you die, so bring "
        .. "what you can afford to lose. Buy more on the TRADE screen.",
    ["Ready To Launch"] = "Press START RAID in the lobby. Offline there's no matchmaking: the raid loads straight away, "
        .. "on the map you picked. Your hired crew (F11) comes along if you can pay their wages; choose who comes there.",
    ["First Flight"] = "You start aboard your ship. Walk to the helm and press F to take the controls (F again to "
        .. "leave). Crewmates can man the turret periscopes, or fire from the helm when you fly solo. The minimap shows "
        .. "the way to stations and to your task: N turns it on or off, M opens the full overview, B follows the next task.",
    ["Docking"] = "Fly into a station's docking area (the minimap marks stations) and your ship docks by itself. Walk to "
        .. "your airlock and use it to cycle through into the station. Keep your captain's key card: the station side "
        .. "only opens back into your ship while you carry it.",
    ["Escaping"] = "Done, hurt or short on time? Go back through the airlock to your ship, take the helm, undock and fly "
        .. "into a space gate before the raid timer ends. Lost your dock or your key card? Escape pods (red lights beside "
        .. "round hatches) launch you back into space. If the timer runs out, you lose what you carry.",
}
local guideHooked = false

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
    for _, w in ipairs(FindAllOf("SIGIS_InventoryWidget_C") or {}) do
        local name = w:GetFullName():gsub("^%S+ ", "")
        if name:find("Transient", 1, true) then gear.invWidget = name end
    end
    local inv = require("player").inventory()
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

-- After the guide shows a topic: a video topic gets text instead of the dead embed.
local function guideFilled(w)
    if not (w and w:IsValid()) then return end
    local title = w.Txt_GuideTitle:GetText():ToString()
    local text -- (the title is shown upper-case: matched without case)
    for k, v in pairs(GUIDE_TEXT) do if k:upper() == title:upper() then text = v end end
    if not text then return end
    local web = w.GuideWebBrowserVideoPlaying
    if web and web:IsValid() then pcall(function() web:LoadURL("about:blank") end) end
    w.SizeBox_VideoBrowser:SetVisibility(1) -- Collapsed
    w.Txt_Guide_Desc:SetText(FText(text))
    w.Txt_Guide_Desc:SetVisibility(0)
end

local function gearTick()
    local overlay, tab, inv = live(gear.overlay), live(gear.tab), live(gear.inv)
    if not (overlay and tab and inv) then
        local t = os.clock()
        if t >= (gear.nextFind or 0) then -- (FindAllOf ~50 ms; the lobby may not be up yet): 5 s, backing off to 60 s
            findGear()
            gear.findEvery = math.min(60, (gear.findEvery or 2.5) * 2)
            gear.nextFind = t + gear.findEvery
        end
        return
    end
    gear.findEvery = nil
    if not tab.isSelected then gear.seen = nil return end
    local now = equipped(inv)
    if gear.seen and now ~= gear.seen then
        overlay:CoreMM_Tab_Pressed(LOADOUT_STATE)
        local page, skipped = live(gear.invWidget), 0
        for _, name in ipairs(SKIP_ANIMS) do
            pcall(function()
                local a = page[name]
                if a and a:IsValid() and page:IsAnimationPlaying(a) then
                    page:SetAnimationCurrentTime(a, a:GetEndTime())
                    skipped = skipped + 1
                end
            end)
        end
        local faded = pcall(function() overlay:GetOwningPlayer().PlayerCameraManager:StopCameraFade() end)
        X.log(("lobby: gear changed, character redressed (%d page animation(s) skipped, camera fade %s)")
            :format(skipped, faded and "stopped" or "not stopped"))
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
    -- (lobby only: in a raid there's no picker or guild page, and looking for one costs)
    local lobby = ticker:IsValid() and ticker:GetClass():GetFName():ToString() == "MM_CoreMissions_C"
    if lobby and PveMapPick then pcall(PveMapPick.frame) end -- (new picker buttons, before they can be clicked)
    if lobby and PveGuild then pcall(PveGuild.frame) end -- (the guild page, the frame it opens)
    if now < nextCheck then return end
    nextCheck = now + CHECK_SECONDS
    local inLobby = ticker:IsValid() and ticker:GetClass():GetFName():ToString() == "MM_CoreMissions_C"
    if not (inLobby and X.offline()) then
        paths, gear = nil, {}
        if PveMapPick then pcall(PveMapPick.reset) end -- (its widget paths died with this lobby)
        return
    end
    if PveMapPick then
        local okPick, errPick = pcall(PveMapPick.tick)
        if not okPick and not gear.pickErr then gear.pickErr = true X.log("lobby: map picker failed: " .. tostring(errPick)) end
    end
    if PveGuild then
        local okGuild, errGuild = pcall(PveGuild.tick)
        if not okGuild and not gear.guildErr then gear.guildErr = true X.log("lobby: offline guild failed: " .. tostring(errGuild)) end
    end
    local PveBriefings = require("briefings")
    if #PveBriefings.TARGETS > 0 then -- (handler briefings on the contracts page, briefings.lua)
        local okBrief, errBrief = pcall(PveBriefings.tick)
        if not okBrief and not gear.briefErr then gear.briefErr = true X.log("lobby: briefings failed: " .. tostring(errBrief)) end
    end
    local okGear, errGear = pcall(gearTick)
    if not okGear and not gear.err then gear.err = true X.log("lobby: gear refresh failed: " .. tostring(errGear)) end
    -- (the Guide's class loads with the lobby; hooked once it exists, for the session: the pause menu's GUIDE too)
    if not guideHooked then
        local fn = StaticFindObject(GUIDE_FILL)
        if fn and fn:IsValid() then
            guideHooked = pcall(RegisterHook, GUIDE_FILL, function(ctx)
                local ok, err = pcall(guideFilled, ctx:get())
                if not ok then X.log("lobby: guide text failed: " .. tostring(err)) end
            end)
            X.log("lobby: guide video topics " .. (guideHooked and "get text instead" or "hook failed"))
        end
    end
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
