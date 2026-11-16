-- Quit Game in the pause menu (Esc). The game's menu (SIGIS_Exit_Widget) offers Resume, Guide, Report Abuse, Settings and
-- Main Menu, and nothing in the game quits it: testers force-closed it. (Its EXIT button belongs to the "are you sure?"
-- panel behind Main Menu, which leaves the raid; its hidden REPORT BUG button opens a web page.)
-- A button of the menu's own kind (MM_GenericSmallBtn01, taken from its Main Menu button) is added under Main Menu when
-- the menu first opens. One click asks again (in a raid, with a note that the gear you brought in counts as lost, as it
-- does with Alt+F4); a second click within CONFIRM_SECONDS quits. UMG delegates can't be bound from Lua, so its inner
-- button is polled each frame while the menu is up (as tuning.lua does with its own buttons).
local Q = {}
local X -- log, valid, pc (function: the controller the director ticks on), inRaid (function)

local MENU_OPEN = "/SIGISPlugin/Widgets/HUD/SIGIS_Exit_Widget.SIGIS_Exit_Widget_C:ExitMenu_Open"
local CONFIRM_SECONDS = 4
local LABEL, ASK = "QUIT GAME", "CLICK AGAIN TO QUIT"
local COPY = { "WidthOverride", "HeightOverride", "b_TexOnlyVersion", "Material_ShapesFillLayer",
    "ShapeLayerOpacity_Unhovered", "ShapeLayerOpacity_Hovered", "Sound_OnClick", "Sound_OnHover" }

local ui = {} -- menu, btn, down, armedUntil
local hooked, hookAt = false, 0

function Q.init(ctx) X = ctx end

local function label(text)
    pcall(function() ui.btn.Txt_Main:SetText(FText(text)) end)
end

-- Into this menu's list of buttons, under Main Menu, in a size box like theirs.
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
    ui = { menu = menu, btn = btn, down = false }
    label(LABEL)
    X.log("quit: Quit Game button added to the pause menu")
end

-- The menu opened: a new menu gets the button, the same one starts over.
function Q.opened(menu)
    if not X.valid(menu) then return end
    if ui.menu ~= nil and X.valid(ui.menu) and X.valid(ui.btn) and ui.menu:GetAddress() == menu:GetAddress() then
        ui.armedUntil, ui.down = nil, false
        label(LABEL)
        return
    end
    build(menu)
end

local function quit()
    X.log("quit: Quit Game from the pause menu")
    local pc = X.pc()
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):QuitGame(pc, pc, 0, false) -- 0 = Quit
end

-- Every frame from the director's tick.
function Q.tick()
    local now = os.clock()
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
    local b = ui.btn
    if not (b and X.valid(b) and X.valid(ui.menu)) then return end
    if not ui.menu:IsVisible() then ui.down = false return end
    if ui.armedUntil and now > ui.armedUntil then
        ui.armedUntil = nil
        label(LABEL)
    end
    local down = b.Btn_Main:IsPressed()
    local click = ui.down and not down -- on release, like a real button
    ui.down = down
    if not click then return end
    if ui.armedUntil then return quit() end
    ui.armedUntil = now + CONFIRM_SECONDS
    label(ASK)
    if X.inRaid() then
        pcall(function()
            X.pc():ClientMessage("Quitting now ends the raid: the gear you brought in counts as lost "
                .. "(the launcher's Undo last raid brings it back).", FName("Event"), CONFIRM_SECONDS)
        end)
    end
end

return Q
