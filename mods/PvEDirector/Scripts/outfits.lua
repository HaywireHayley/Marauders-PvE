-- Two outfits the game has but never lists (#229): DT_PlayerAppearance rows 57-60 ("Pirate" and "Mod", cost 1, left out
-- of the Appearance pages). Rows 57/59 are bodies, 58/60 heads: a long brown coat with a brass mask, and the same coat in
-- black with a dark goggled mask (seen on the lobby character, 2026-11-20). An F9 button in the lobby puts one on through
-- the game's own setters, SIGISPlayerController:SetPlayerCosBody / SetPlayerCosHead (one FName each; they save the
-- look like a click in Appearance does: PUT cosequipped body and head), then presses the selected lobby tab again so the
-- character is redressed (the setters alone change nothing on screen until the next page switch). Picking any look in
-- Appearance takes it off again. The stand-in owns these rows for every account (FREE_COSMETICS).
local M = {}
local X -- log, valid

local OUTFITS = {
    { name = "brown coat", body = "57", head = "58" },
    { name = "black coat", body = "59", head = "60" },
}
local TABS = { "Loadout", "Play", "Contracts", "Social" }
local worn -- index of the outfit put on last (this session)

function M.init(ctx) X = ctx end

local function lobbyPc()
    local pc = FindFirstOf("MenuPlayerController_C")
    return X.valid(pc) and pc or nil
end

-- The lobby's selected tab pressed again: what a tab click runs, and what redresses the lobby character.
local function redress()
    for _, w in ipairs(FindAllOf("SIGIS_MainOverlay_C") or {}) do
        local name = X.valid(w) and w:GetFullName():gsub("^%S+ ", "")
        if name and name:find("Transient", 1, true) then
            for _, t in ipairs(TABS) do
                local tab = StaticFindObject(name .. ".WidgetTree.MM_CoreMM_TabBtns_" .. t)
                if tab and tab:IsValid() and tab.isSelected then
                    w:CoreMM_Tab_Pressed(tab.Which_CoreMenuState)
                    return true
                end
            end
        end
    end
    return false
end

local function wear()
    local pc = lobbyPc()
    if not pc then return "Only in the lobby" end
    worn = (worn or 0) % #OUTFITS + 1
    local o = OUTFITS[worn]
    pc:SetPlayerCosBody(FName(o.body))
    pc:SetPlayerCosHead(FName(o.head))
    local shown = redress()
    X.log(("outfits: wearing the %s (body %s, head %s)%s"):format(o.name, o.body, o.head,
        shown and "" or "; the character changes at the next page switch"))
    return "Wearing the " .. o.name
end

function M.actions()
    return {
        { id = "outfit", label = function()
              local nxt = OUTFITS[(worn or 0) % #OUTFITS + 1]
              return "Hidden outfit: wear the " .. nxt.name
          end,
          help = "Looks the game doesn't list. Appearance changes you back",
          when = function() return lobbyPc() ~= nil end, unusable = "Only in the lobby", run = wear },
    }
end

return M
