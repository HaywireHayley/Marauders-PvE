-- Keys while your inventory (or a loot window) is open in a raid.
-- * Esc: the controller's InGameMenu action opened the pause menu behind the inventory, which stayed up (testers:
--   "Esc opens the menu instead of closing the inventory"). Now Esc closes the pause menu it just opened, then the
--   inventory on the frame after, so Esc in the inventory just closes it.
-- * Lean (Q/E): the pawn still leaned with the inventory up. It's zeroed (RaidCharacter:ZeroLean) while it's open.
-- * Use (F, or whatever Use is bound to) in a loot window also opens the pause menu: the game's own doing, not an input
--   action. A tester with Use on R (Rotate's key too) rotated an item, got the menu, closed it, and was left with the
--   loot window drawn over the game while it took mouse and keys again ("could move and shoot but couldn't see").
--   So the pause menu opening while the inventory is open, whatever opened it, is handled like Esc: menu closed, then
--   the inventory. And if the inventory is ever still drawn with the cursor gone (STUCK_SECONDS), it's closed.
-- The game has no "inventory open" flag of its own: only the controller's mouse cursor and click events change. So the
-- inventory counts as open when the cursor is shown in a raid with neither the pause menu nor one of the mod's menus
-- (F3 / F6 / F9) up. That's worked out every frame and the Esc hook reads the previous frame's answer: by the time
-- UE4SS runs the hook's callback, the event's Blueprint has already opened the pause menu.
local K = {}
local X -- log, valid, pc (function: the raid controller or nil), modMenuOpen (function)

local ESC = "/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:InpActEvt_InGameMenu_K2Node_InputActionEvent_3"
local MENU_OPEN = "/SIGISPlugin/Widgets/HUD/SIGIS_Exit_Widget.SIGIS_Exit_Widget_C:ExitMenu_Open"
local STUCK_SECONDS = 0.5 -- the inventory drawn without the cursor this long counts as stuck
local MENU_CLOSE_WINDOW = 1 -- seconds after Esc to look for the pause menu it opened
local hookedAddr, hookAt = nil, 0 -- (the UFunction hooked: a raid map loads a new copy of it)
local invWasOpen = false          -- the inventory was open on the last frame
local closeMenuUntil, closeInvNext
local menuPath, nextMenuFind = nil, 0
local menuOpened                  -- the pause menu has opened in this world (its ExitMenu_Open hook ran)
local menuHookAddr                -- (the pause menu's class loads with the first raid map)
local invPath, nextInvFind = nil, 0
local stuckSince

function K.init(ctx) X = ctx end

-- The pause menu widget, kept as a path (a name lookup each time, never a held object). It's only looked for once the
-- pause menu has opened in this world: FindAllOf walks every object (44-101 ms on space maps), and with the inventory
-- open before the first Esc of a raid this ran every 2 s, a stutter while looting (profile.txt, build 4 fps reports).
local function menuWidget()
    if menuPath then
        local m = StaticFindObject(menuPath)
        if m and m:IsValid() then return m end
        menuPath, menuOpened = nil, nil -- a new world: its menu isn't made until it opens
    end
    if not menuOpened then return nil end
    local now = os.clock()
    if now < nextMenuFind then return nil end
    nextMenuFind = now + 2
    for _, m in ipairs(FindAllOf("SIGIS_Exit_Widget_C") or {}) do
        local name = m:GetFullName():gsub("^%S+ ", "")
        if name:find("Transient", 1, true) then menuPath = name return m end
    end
end

local function menuShown(m)
    m = m or menuWidget()
    if not m then return false end
    local ok, shown = pcall(function() return m:IsInViewport() and m:IsVisible() end)
    return ok and shown
end

local function onEsc()
    if invWasOpen then closeMenuUntil = os.clock() + MENU_CLOSE_WINDOW end
end

-- The raid's inventory widget (In Game Overlay Match's InventoryMenu, a SIGIS_HUDWidget_C), kept as a path.
local function invWidget()
    if invPath then
        local w = StaticFindObject(invPath)
        if w and w:IsValid() then return w end
        invPath = nil
    end
    local now = os.clock()
    if now < nextInvFind then return nil end
    nextInvFind = now + 2
    for _, w in ipairs(FindAllOf("SIGIS_HUDWidget_C") or {}) do
        local name = w:GetFullName():gsub("^%S+ ", "")
        if name:find("Transient", 1, true) and name:find("Overlay Match.WidgetTree.InventoryMenu", 1, true) then
            invPath = name
            return w
        end
    end
end

-- Every frame from the director's tick.
function K.tick()
    local now = os.clock()
    -- The controller's Blueprint is loaded again with each raid map (and already in the lobby): a hook on the old copy
    -- never fires, so hook the copy that exists now whenever its address changes (as main.lua does for the captain).
    if now >= hookAt then
        hookAt = now + 2
        local fn = StaticFindObject(ESC)
        if fn and fn:IsValid() and fn:GetAddress() ~= hookedAddr then
            local ok = pcall(RegisterHook, ESC, function()
                local ok2, err = pcall(onEsc)
                if not ok2 then X.log("inventory keys: Esc failed: " .. tostring(err)) end
            end)
            if ok then hookedAddr = fn:GetAddress() end
        end
        local open = StaticFindObject(MENU_OPEN)
        if open and open:IsValid() and open:GetAddress() ~= menuHookAddr then
            -- (pre-callback: this Blueprint event's post-callback never runs under UE4SS; see quit.lua)
            local ok = pcall(RegisterHook, MENU_OPEN, function()
                menuOpened, nextMenuFind = true, 0
                local ok2, err = pcall(onEsc)
                if not ok2 then X.log("inventory keys: menu open failed: " .. tostring(err)) end
            end)
            if ok then menuHookAddr = open:GetAddress() end
        end
    end
    local pc = X.pc()
    if not X.valid(pc) then invWasOpen = false return end
    if closeInvNext then
        closeInvNext = nil
        pcall(function() pc:CloseInventory() end)
    end
    if closeMenuUntil then
        local m = menuWidget()
        if menuShown(m) then
            pcall(function() m:CloseTheMenu() end)
            closeMenuUntil, closeInvNext = nil, true
        elseif now > closeMenuUntil then
            closeMenuUntil = nil
        end
    end
    -- (cheap first: the cursor is off nearly all the time in a raid, and then nothing else is looked at)
    invWasOpen = pc.bShowMouseCursor and not X.modMenuOpen() and not menuShown() or false
    -- the loot window left drawn with the cursor gone (nothing else on screen): close it
    local stuck = false
    if not pc.bShowMouseCursor and not closeMenuUntil then
        local inv = invWidget()
        -- (in the viewport too: a hidden copy flagged visible would otherwise be "closed" twice a second)
        local shown = false
        if inv then pcall(function() shown = inv:IsInViewport() and inv:IsVisible() end) end
        stuck = shown and not menuShown() and not X.modMenuOpen()
    end
    if not stuck then
        stuckSince = nil
    elseif not stuckSince then
        stuckSince = now
    elseif now - stuckSince >= STUCK_SECONDS then
        stuckSince = nil
        pcall(function() pc:CloseInventory() end)
        X.log("inventory keys: inventory was drawn without the cursor; closed it")
    end
    local pawn = pc.Pawn
    if invWasOpen and X.valid(pawn) and (pawn.Lean or 0) ~= 0 then pcall(function() pawn:ZeroLean() end) end
end

return K
