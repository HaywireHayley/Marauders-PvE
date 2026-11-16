-- Keys while your inventory (or a loot window) is open in a raid.
-- * Esc: the controller's InGameMenu action opened the pause menu behind the inventory, which stayed up (testers:
--   "Esc opens the menu instead of closing the inventory"). Now Esc closes the pause menu it just opened, then the
--   inventory on the frame after, so Esc in the inventory just closes it.
-- * Lean (Q/E): the pawn still leaned with the inventory up. It's zeroed (RaidCharacter:ZeroLean) while it's open.
-- The game has no "inventory open" flag of its own: only the controller's mouse cursor and click events change. So the
-- inventory counts as open when the cursor is shown in a raid with neither the pause menu nor one of the mod's menus
-- (F3 / F6 / F9) up. That's worked out every frame and the Esc hook reads the previous frame's answer: by the time
-- UE4SS runs the hook's callback, the event's Blueprint has already opened the pause menu.
local K = {}
local X -- log, valid, pc (function: the raid controller or nil), modMenuOpen (function)

local ESC = "/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:InpActEvt_InGameMenu_K2Node_InputActionEvent_3"
local MENU_CLOSE_WINDOW = 1 -- seconds after Esc to look for the pause menu it opened
local hookedAddr, hookAt = nil, 0 -- (the UFunction hooked: a raid map loads a new copy of it)
local invWasOpen = false          -- the inventory was open on the last frame
local closeMenuUntil, closeInvNext
local menuPath, nextMenuFind = nil, 0

function K.init(ctx) X = ctx end

-- The pause menu widget, kept as a path (a name lookup each time, never a held object). Until the game has made one,
-- FindAllOf is tried at most every 2 s.
local function menuWidget()
    if menuPath then
        local m = StaticFindObject(menuPath)
        if m and m:IsValid() then return m end
        menuPath = nil
    end
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
    local pawn = pc.Pawn
    if invWasOpen and X.valid(pawn) and (pawn.Lean or 0) ~= 0 then pcall(function() pawn:ZeroLean() end) end
end

return K
