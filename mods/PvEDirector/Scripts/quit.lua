-- Quitting the game from inside it: nothing in the game did (testers force-closed it).
-- * Raid: Quit Game in the pause menu (Esc). The game's menu (SIGIS_Exit_Widget) offers Resume, Guide, Report Abuse,
--   Settings and Main Menu. (Its EXIT button belongs to the "are you sure?" panel behind Main Menu, which leaves the
--   raid; its hidden REPORT BUG button opens a web page.) A button of the menu's own kind (MM_GenericSmallBtn01, taken
--   from its Main Menu button) is added under Main Menu when the menu first opens.
-- * Lobby: a QUIT tab at the end of the top bar (LOADOUT TRADE PLAY CONTRACTS SOCIAL), a tab of the bar's own kind
--   (MM_CoreMM_TabBtns). The lobby has no Esc menu, and the game's own lobby Exit sits in a collapsed old bottom bar.
-- One click asks again (in a raid, with a note that the gear you brought in goes back to your stash, issue #49); a
-- second click within CONFIRM_SECONDS quits. UMG delegates can't be bound from Lua, so the buttons are polled each frame
-- (as tuning.lua does with its own buttons).
-- Widgets are kept as object paths, never as objects: each frame looks them up again (StaticFindObject, a name
-- lookup). A widget held across a map change is freed with its world, and checking a freed object reads freed memory.
local Q = {}
local X -- log, valid, pc (function: the controller the director ticks on), inRaid (function)

local MENU_OPEN = "/SIGISPlugin/Widgets/HUD/SIGIS_Exit_Widget.SIGIS_Exit_Widget_C:ExitMenu_Open"
local CONFIRM_SECONDS = 4
local LABEL, ASK = "QUIT GAME", "CLICK AGAIN TO QUIT"
local TAB_LABEL, TAB_ASK = "QUIT", "SURE?"
local COPY = { "WidthOverride", "HeightOverride", "b_TexOnlyVersion", "Material_ShapesFillLayer",
    "ShapeLayerOpacity_Unhovered", "ShapeLayerOpacity_Hovered", "Sound_OnClick", "Sound_OnHover" }

local ui = {}  -- the pause menu's: menuPath, btnPath, down, armedUntil
local lob = {} -- the lobby's: btnPath, down, armedUntil
local hooked, hookAt, nextTabFind, tabFindEvery = false, 0, 0, nil

function Q.init(ctx) X = ctx end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end -- (the class name comes first)
local function live(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local function setLabel(btn, text)
    pcall(function() btn.Txt_Main:SetText(FText(text)) end)
end

local function quit(where)
    X.log("quit: Quit Game from the " .. where)
    local pc = X.pc()
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):QuitGame(pc, pc, 0, false) -- 0 = Quit
end

-- A click is a release after a press (like a real button). Returns "ask", "quit" or nil.
local function poll(state, btn, now)
    local inner = btn.Btn_Main
    if not X.valid(inner) then return nil end
    local down = inner:IsPressed()
    local click = state.down and not down
    state.down = down
    if not click then return nil end
    if state.armedUntil and now <= state.armedUntil then return "quit" end
    state.armedUntil = now + CONFIRM_SECONDS
    return "ask"
end

-- Raid: into the pause menu's list of buttons, under Main Menu, in a size box like theirs.
local function build(menu)
    local main = menu.MM_GenericSmallBtn_MainMenu
    if not X.valid(main) then return end
    local box = main:GetParent()
    local list = X.valid(box) and box:GetParent()
    if not X.valid(list) then return end
    local pc = X.pc()
    local btn = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, main:GetClass(), pc)
    local sb = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), menu.WidgetTree)
    if not (X.valid(btn) and X.valid(sb)) then return end
    -- The designer sets these on each button (width, text-only look, fill); its PreConstruct applies them.
    for _, k in ipairs(COPY) do pcall(function() btn[k] = main[k] end) end
    pcall(function() btn:PreConstruct(false) end)
    pcall(function() sb:SetHeightOverride(box.HeightOverride) end)
    sb:AddChild(btn)
    local slot = list:AddChildToVerticalBox(sb)
    pcall(function()
        local from = box.Slot
        local p = from.Padding
        slot:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
        slot:SetHorizontalAlignment(from.HorizontalAlignment)
        -- The menu's panel has a fixed size in its canvas: one row taller.
        local cs = menu.Border_MainMenuOptions.Slot
        local o = cs.LayoutData.Offsets
        cs:SetSize({ X = o.Right, Y = o.Bottom + box.HeightOverride + p.Top })
    end)
    ui = { menuPath = pathOf(menu), btnPath = pathOf(btn), down = false }
    setLabel(btn, LABEL)
    X.log("quit: Quit Game button added to the pause menu")
end

-- The menu opened: a new menu gets the button, the same one starts over.
function Q.opened(menu)
    if not X.valid(menu) then return end
    local btn = live(ui.btnPath)
    if btn and ui.menuPath == pathOf(menu) then
        ui.armedUntil, ui.down = nil, false
        setLabel(btn, LABEL)
        return
    end
    build(menu)
end

-- Lobby: a QUIT tab after SOCIAL in the top bar, made once per lobby (found again if the lobby is rebuilt).
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
    local slot = bar:AddChildToHorizontalBox(btn)
    local from = social.Slot
    if X.valid(slot) and X.valid(from) then
        pcall(function()
            local p = from.Padding
            slot:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
            slot:SetVerticalAlignment(from.VerticalAlignment)
        end)
    end
    lob = { btnPath = pathOf(btn), down = false }
    setLabel(btn, TAB_LABEL)
    X.log("quit: QUIT tab added to the lobby's top bar")
end

local function lobbyTick(pc, now)
    local btn = live(lob.btnPath)
    if not btn then
        if now < nextTabFind then return end
        tabFindEvery = math.min(60, (tabFindEvery or 1.5) * 2)
        nextTabFind = now + tabFindEvery -- (the lobby's widgets may not exist yet; FindAllOf costs ~50 ms): 3 s, up to 60 s
        return buildTab(pc)
    end
    tabFindEvery = nil
    if lob.armedUntil and now > lob.armedUntil then
        lob.armedUntil = nil
        setLabel(btn, TAB_LABEL)
    end
    local what = poll(lob, btn, now)
    if what == "quit" then return quit("lobby") end
    if what == "ask" then setLabel(btn, TAB_ASK) end
end

-- Every frame from the director's tick.
function Q.tick()
    local now = os.clock()
    local pc = X.pc()
    if X.valid(pc) and pc:GetClass():GetFName():ToString() == "MenuPlayerController_C" then return lobbyTick(pc, now) end
    -- The menu's class loads with the first world that has it: hook its opening once it exists.
    if not hooked and now >= hookAt then
        hookAt = now + 2
        if X.valid(StaticFindObject(MENU_OPEN)) then
            -- (pre-callback: this Blueprint event's post-callback never runs under UE4SS; the menu's widgets exist already)
            hooked = pcall(RegisterHook, MENU_OPEN, function(ctx)
                local ok, err = pcall(Q.opened, ctx:get())
                if not ok then X.log("quit: adding the button failed: " .. tostring(err)) end
            end)
        end
    end
    if not ui.menuPath then return end
    local menu, b = live(ui.menuPath), live(ui.btnPath)
    if not (menu and b) then
        -- Gone with the last raid: forget them until the menu opens again (Q.opened). A StaticFindObject of a path
        -- that doesn't exist walks every object in the game, each frame (issue #112's cause, in guild.lua).
        ui.menuPath, ui.btnPath = nil, nil
        return
    end
    if not menu:IsVisible() then ui.down = false return end
    if ui.armedUntil and now > ui.armedUntil then
        ui.armedUntil = nil
        setLabel(b, LABEL)
    end
    local what = poll(ui, b, now)
    if what == "quit" then return quit("pause menu") end
    if what ~= "ask" then return end
    setLabel(b, ASK)
    if X.inRaid() then
        pcall(function()
            pc:ClientMessage("Quitting now ends the raid: the gear you brought in goes back to your stash, "
                .. "anything you picked up here is lost.", FName("Event"), CONFIRM_SECONDS)
        end)
    end
end

return Q
