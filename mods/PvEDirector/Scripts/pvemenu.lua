-- The PvE menu in the lobby's top bar (#388): the mod's menus opened only with function keys, which players didn't
-- find (and laptops need Fn for). A PVE tab, of the bar's own kind (MM_CoreMM_TabBtns, as quit.lua's QUIT tab), opens
-- a tiny chooser: three more tabs beside it, CREW (F11), AI (F10) and DEBUG (F9), each running what its key runs.
-- Clicking PVE again, or one of the three, folds them away. The keys stay as shortcuts.
-- The actions come from main.lua's key block through M.setActions (a table, so main keeps its locals). Buttons are
-- polled each frame (UMG delegates can't be bound from Lua) and kept as object paths, never objects: a lobby torn down
-- by a raid is never touched. Nothing is rooted; the widgets belong to the lobby and die with it.
local M = {}
local X -- log, valid (from quit.lua, which ticks this)

local ENTRIES = { { key = "pve", label = "PVE" }, { key = "crew", label = "CREW" }, { key = "ai", label = "SETTINGS" },
    { key = "debug", label = "DEBUG" } }
local COLLAPSED, VISIBLE = 1, 0 -- ESlateVisibility
local actions = {}  -- crew, ai, debug: functions (main.lua)
local tabs = {}     -- key -> { path, down }
local open = false
local nextFind, findEvery = 0, nil

function M.init(ctx) X = ctx end
function M.setActions(t) actions = t or {} end
function M.action(key) return function() local fn = actions[key] if fn then fn() end end end

local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function live(path)
    if not path then return nil end
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
end

local function setOpen(v)
    open = v
    for i = 2, #ENTRIES do
        local b = live(tabs[ENTRIES[i].key] and tabs[ENTRIES[i].key].path)
        if b then pcall(function() b:SetVisibility(v and VISIBLE or COLLAPSED) end) end
    end
end

local function build(pc)
    local social
    for _, t in ipairs(FindAllOf("MM_CoreMM_TabBtns_C") or {}) do
        local name = t:GetFullName()
        if name:find("Transient", 1, true) and name:find("MM_CoreMM_TabBtns_Social", 1, true) then social = t break end
    end
    if not X.valid(social) then return end
    local bar = social:GetParent()
    if not X.valid(bar) then return end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    tabs = {}
    for _, e in ipairs(ENTRIES) do
        local btn = lib:Create(pc, social:GetClass(), pc)
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
        pcall(function() btn.Txt_Main:SetText(FText(e.label)) end)
        tabs[e.key] = { path = pathOf(btn), down = false }
    end
    setOpen(false)
    X.log("pvemenu: PVE tab added to the lobby's top bar")
end

-- A click is a release after a press.
local function clicked(state)
    local b = live(state.path)
    local inner = b and b.Btn_Main
    if not X.valid(inner) then return false end
    local down = inner:IsPressed()
    local click = state.down and not down
    state.down = down
    return click
end

-- Every frame in the lobby (quit.lua's lobby tick), with the menu's player controller.
function M.tick(pc, now)
    if not live(tabs.pve and tabs.pve.path) then
        tabs, open = {}, false -- (a new lobby: the old paths are gone)
        if now < nextFind then return end
        findEvery = math.min(60, (findEvery or 1.5) * 2)
        nextFind = now + findEvery
        return build(pc)
    end
    findEvery = nil
    if clicked(tabs.pve) then return setOpen(not open) end
    if not open then return end
    for i = 2, #ENTRIES do
        local key = ENTRIES[i].key
        if tabs[key] and clicked(tabs[key]) then
            setOpen(false)
            local fn = actions[key]
            X.log("pvemenu: " .. key .. (fn and "" or " (no action)"))
            if fn then
                local ok, err = pcall(fn)
                if not ok then X.log("pvemenu: " .. key .. " failed: " .. tostring(err)) end
            end
            return
        end
    end
end

-- Left the lobby: forget the paths (a StaticFindObject of a missing path walks every object).
function M.reset() tabs, open, findEvery = {}, false, nil end

return M
