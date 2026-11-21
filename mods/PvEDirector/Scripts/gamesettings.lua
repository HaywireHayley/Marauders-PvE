-- The game's Settings (video, audio, gameplay, controls...) outside a raid (issue #293). Players could open them only
-- from the pause menu in a raid: the lobby's own Settings button sits in the overlay's old bottom bar
-- (Border_BottomBar_Old), which is collapsed, and the title screen has none.
-- * Title screen: a SETTINGS button after EXIT and PLAY, a copy of EXIT (MM_GenericSmallBtn01).
-- * Lobby: a SETTINGS tab after SOCIAL in the top bar, a tab of the bar's own kind (MM_CoreMM_TabBtns), as quit.lua
--   adds QUIT.
-- Both show the Settings widget the lobby overlay already holds (SIGIS_MainOverlay_C.SIGIS_Options). Its tabs and its
-- X work as they do in a raid; the X collapses it again. Called from Lua, neither the overlay's SwitchToOptions nor
-- the hidden button's click handler opened it, so it's shown directly: the widget made visible, and on first opening
-- the VIDEO page, whose InitializeVideoSettings fills the resolution, window mode and UI scale lists (empty until
-- then). The overlay lives on the game instance, so it lasts the whole session.
-- Widgets are kept as object paths, never as objects (see quit.lua): each frame looks them up again.
local M = {}
local X -- log, valid, pc (function: the controller the director ticks on)

local LABEL = "SETTINGS"
local PAGES = { "WB_Options_Video", "WB_Options_Audio", "WB_Options_Gameplay", "WB_Options_Social",
    "WB_Options_Controls", "WB_Options_Misc" }
local COPY = { "WidthOverride", "HeightOverride", "b_TexOnlyVersion", "Material_ShapesFillLayer",
    "ShapeLayerOpacity_Unhovered", "ShapeLayerOpacity_Hovered", "Sound_OnClick", "Sound_OnHover" }
local VISIBLE, COLLAPSED, SELF_HIT_TEST_INVISIBLE = 0, 1, 4

local overlayPath
local title = {} -- btnPath, loginPath, down
local tab = {}   -- btnPath, down
local nextFind, findEvery = 0, nil

function M.init(ctx) X = ctx end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end -- (the class name comes first)
local function live(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
end
local function setLabel(btn, text)
    pcall(function() btn.Txt_Main:SetText(FText(text)) end)
end
-- The live copy of a widget class, not its Blueprint's template.
local function transient(class)
    for _, w in ipairs(FindAllOf(class) or {}) do
        if w:GetFullName():find("/Engine/Transient", 1, true) then return w end
    end
end

-- Puts a widget into a horizontal box at an index. UPanelWidget::InsertChildAt and ShiftChild aren't Blueprint
-- functions (UE4SS can't call them), so the children from there on are taken out and added back after it, each with
-- its slot's padding, alignment and size. They stay the same widget objects. Only for our own widgets (the lobby: at
-- most quit.lua's QUIT tab, which is polled, so it keeps working): a game button moved this way (PLAY on the title
-- screen) stopped working.
local function insertAt(box, index, widget)
    local after = {}
    while box:GetChildrenCount() > index do
        local c = box:GetChildAt(index)
        local saved = { widget = c }
        pcall(function()
            local sl, p = c.Slot, c.Slot.Padding
            saved.pad = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom }
            saved.h, saved.v = sl.HorizontalAlignment, sl.VerticalAlignment
            saved.size = { SizeRule = sl.Size.SizeRule, Value = sl.Size.Value }
        end)
        after[#after + 1] = saved
        box:RemoveChildAt(index)
    end
    local slot = box:AddChildToHorizontalBox(widget)
    for _, a in ipairs(after) do
        local sl = box:AddChildToHorizontalBox(a.widget)
        if X.valid(sl) then
            pcall(function()
                if a.pad then sl:SetPadding(a.pad) end
                if a.h then sl:SetHorizontalAlignment(a.h) end
                if a.v then sl:SetVerticalAlignment(a.v) end
                if a.size then sl:SetSize(a.size) end
            end)
        end
    end
    return slot
end

local function open(where)
    local ov = live(overlayPath)
    if not ov then
        ov = transient("SIGIS_MainOverlay_C")
        if not X.valid(ov) then return X.log("settings: no lobby overlay to open them in") end
        overlayPath = pathOf(ov)
    end
    local s = ov.SIGIS_Options
    if not X.valid(s) then return X.log("settings: the overlay has no Settings widget") end
    local shown
    for _, name in ipairs(PAGES) do
        local page = s[name]
        if X.valid(page) and page:GetVisibility() ~= COLLAPSED then shown = name break end
    end
    local video = s.WB_Options_Video
    if not shown and X.valid(video) then
        video:SetVisibility(SELF_HIT_TEST_INVISIBLE)
        shown = "WB_Options_Video"
    end
    -- (current values each time: the window mode or resolution may have changed since, e.g. with Alt+Enter)
    if shown == "WB_Options_Video" then pcall(function() video:InitializeVideoSettings() end) end
    s:SetVisibility(VISIBLE)
    X.log("settings: opened from the " .. where)
end

-- A click is a release after a press (like a real button).
local function clicked(state, btn)
    local inner = btn.Btn_Main
    if not X.valid(inner) then return false end
    local down = inner:IsPressed()
    local click = state.down and not down
    state.down = down
    return click
end

-- Title screen: SETTINGS at the end of the EXIT / PLAY row, after a spacer like the one between them. Not between
-- them: that means taking PLAY out of the row and adding it back, and PLAY then no longer started the game.
local function buildTitle(pc, login)
    local exit = login.MM_GenericSmallBtn01_Exit
    if not X.valid(exit) then return end
    local row = exit:GetParent()
    if not X.valid(row) or row:GetChildrenCount() < 2 then return end
    local gap = row:GetChildAt(1)
    local btn = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, exit:GetClass(), pc)
    local sp = StaticConstructObject(StaticFindObject("/Script/UMG.Spacer"), login.WidgetTree)
    if not (X.valid(btn) and X.valid(sp)) then return end
    for _, k in ipairs(COPY) do pcall(function() btn[k] = exit[k] end) end
    pcall(function() btn:PreConstruct(false) end)
    pcall(function() sp:SetSize({ X = gap.Size.X, Y = gap.Size.Y }) end)
    row:AddChildToHorizontalBox(sp)
    local slot = row:AddChildToHorizontalBox(btn)
    pcall(function()
        slot:SetVerticalAlignment(exit.Slot.VerticalAlignment)
        slot:SetHorizontalAlignment(exit.Slot.HorizontalAlignment)
    end)
    title = { btnPath = pathOf(btn), loginPath = pathOf(login), down = false }
    setLabel(btn, LABEL)
    X.log("settings: SETTINGS button added to the title screen")
end

-- Lobby: a SETTINGS tab right after SOCIAL (so before quit.lua's QUIT, whichever is added first).
local function buildTab(pc)
    local social
    for _, t in ipairs(FindAllOf("MM_CoreMM_TabBtns_C") or {}) do
        local name = t:GetFullName()
        if name:find("Transient", 1, true) and name:find("MM_CoreMM_TabBtns_Social", 1, true) then social = t break end
    end
    if not X.valid(social) then return end
    local bar = social:GetParent()
    if not X.valid(bar) then return end
    local btn = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, social:GetClass(), pc)
    if not X.valid(btn) then return end
    pcall(function() btn.WidthToUse, btn.HeightToUse = social.WidthToUse, social.HeightToUse end)
    pcall(function() btn.Which_CoreMenuState = 99 end) -- none of the lobby's pages: the bar never selects it
    pcall(function() btn:PreConstruct(false) end)
    -- Right after SOCIAL when all that follows is our own tabs (state 99: QUIT), else at the end.
    local at, ours = bar:GetChildIndex(social) + 1, true
    for i = at, bar:GetChildrenCount() - 1 do
        local c = bar:GetChildAt(i)
        local ok, state = pcall(function() return c.Which_CoreMenuState end)
        if not (ok and state == 99) then ours = false break end
    end
    local slot = ours and insertAt(bar, at, btn) or bar:AddChildToHorizontalBox(btn)
    local from = social.Slot
    if X.valid(slot) and X.valid(from) then
        pcall(function()
            local p = from.Padding
            slot:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
            slot:SetVerticalAlignment(from.VerticalAlignment)
        end)
    end
    tab = { btnPath = pathOf(btn), down = false }
    setLabel(btn, LABEL)
    X.log("settings: SETTINGS tab added to the lobby's top bar")
end

-- Every frame from the director's tick; only while the menu controller is up (title screen and lobby).
function M.tick()
    local pc = X.pc()
    if not (X.valid(pc) and pc:GetClass():GetFName():ToString() == "MenuPlayerController_C") then return end
    local now = os.clock()
    local tb, lb = live(tab.btnPath), live(title.btnPath)
    if not tb or not lb then
        if now >= nextFind then
            findEvery = math.min(60, (findEvery or 1.5) * 2)
            nextFind = now + findEvery -- (FindAllOf costs ~50 ms): 3 s, up to 60 s
            if not lb then
                local login = transient("SIGIS_LoginWidget_C")
                if X.valid(login) and login:IsVisible() then
                    local ok, err = pcall(buildTitle, pc, login)
                    if not ok then X.log("settings: title button failed: " .. tostring(err)) end
                end
            end
            if not tb then
                local ok, err = pcall(buildTab, pc)
                if not ok then X.log("settings: lobby tab failed: " .. tostring(err)) end
            end
        end
    end
    if tb and lb then findEvery = nil end
    if tb and clicked(tab, tb) then open("lobby") end
    if lb then
        local login = live(title.loginPath)
        if login and login:IsVisible() and clicked(title, lb) then open("title screen") end
    end
end

return M
