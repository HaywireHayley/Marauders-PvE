-- Two outfits the game has but never lists (#229): DT_PlayerAppearance rows 57-60 ("Pirate" and "Mod", cost 1, left out
-- of the Appearance pages). Rows 57/59 are bodies, 58/60 heads: a long brown coat with a brass mask, and the same coat in
-- black with a dark goggled mask (seen on the lobby character, 2026-11-20). An F9 button in the lobby puts one on through
-- the game's own setters, SIGISPlayerController:SetPlayerCosBody / SetPlayerCosHead (one FName each; they save the
-- look like a click in Appearance does: PUT cosequipped body and head), then presses the selected lobby tab again so the
-- character is redressed (the setters alone change nothing on screen until the next page switch). Picking any look in
-- Appearance takes it off again. The stand-in owns these rows for every account (FREE_COSMETICS).
-- The Blood Raider (#228, #230): the game files hold one body with no appearance row at all,
-- Meshes/Bodies/Steam/Raider_Body_Blood_Skel_01 (a "Steam" folder: a platform reward set), which goes with row 72's free
-- "Nomad Blood Head". Found by listing the pak's character meshes from the running game's memory (2026-11-20). Worn as
-- row 6 (the plain Raider body) + row 72, with female.lua swapping the plain body for the bloodied one whenever the game
-- dresses you, in the lobby and in raids, while your controller's EquippedBody/EquippedHead are still 6 and 72. Kept in
-- config/outfit_body.txt; picking any other look in Appearance ends it.
local PROJECT = require("pveproject")
local Female = require("female")
local M = {}
local X -- log, valid

local BLOOD = "/Game/Characters/MainPlayer/Meshes/Bodies/Steam/Raider_Body_Blood_Skel_01.Raider_Body_Blood_Skel_01"
local OUTFITS = {
    { name = "brown coat", body = "57", head = "58" },
    { name = "black coat", body = "59", head = "60" },
    { name = "Blood Raider", body = "6", head = "72", swap = { "Raider_Body_Skel_01", BLOOD }, key = "blood" },
}
local SETTING = PROJECT .. "config/outfit_body.txt"
local TABS = { "Loadout", "Play", "Contracts", "Social" }
local worn -- index of the outfit put on last (this session)

local function save(key)
    local f = io.open(SETTING, "w")
    if f then
        f:write(key, "\n")
        f:close()
    end
end

-- Your own controller (lobby or raid): the local one, not a co-op guest's on the host.
local function myPc()
    for _, cls in ipairs({ "MenuPlayerController_C", "MainPlayerController_C" }) do
        for _, pc in ipairs(FindAllOf(cls) or {}) do
            if X.valid(pc) and pc:IsLocalController() then return pc end
        end
    end
end

-- Asked whenever the game dresses you (female.lua): still wearing this outfit's rows? A different look picked in
-- Appearance changes EquippedBody/EquippedHead, and that ends the outfit for good.
local function stillWorn(o)
    return function()
        local pc = myPc()
        if not pc then return true end
        local ok, body, head = pcall(function() return pc.EquippedBody:ToString(), pc.EquippedHead:ToString() end)
        -- (empty until your look has loaded at start-up: not a change)
        if not ok or body == "" or head == "" or (body == o.body and head == o.head) then return true end
        Female.setPlayerSwap(o.swap[1], nil)
        save("none")
        X.log(("outfits: the %s is off (Appearance has body %s, head %s)"):format(o.name, body, head))
        return false
    end
end

-- The body swap on or off, saved for the next session.
local function setSwap(o)
    for _, x in ipairs(OUTFITS) do
        if x.swap then Female.setPlayerSwap(x.swap[1], o == x and x.swap[2] or nil, stillWorn(x)) end
    end
    save(o and o.key or "none")
end

function M.init(ctx)
    X = ctx
    local f = io.open(SETTING, "r")
    local key = f and f:read("l")
    if f then f:close() end
    for _, o in ipairs(OUTFITS) do
        if o.key and o.key == key and o.swap then Female.setPlayerSwap(o.swap[1], o.swap[2], stillWorn(o)) end
    end
end

local function lobbyPc()
    local pc = require("cache").menuPc()
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
    setSwap(o.swap and o or nil)
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
