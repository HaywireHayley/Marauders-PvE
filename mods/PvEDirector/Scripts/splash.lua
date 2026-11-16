-- The splash screen after the intro: the trailer's title in place of the game's logo, and our line in the footer. The
-- logo is pre-rendered by trailer/make_menu_logo.py (the trailer's font isn't in the game), as in loading.lua.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local S = {}
local X -- context from main.lua: log, valid, lib

local LOGO = PROJECT .. "assets/menu/logo.png"
local LOGO_W, LOGO_H = 460, 107 -- the game's logo box was 410x80; it grows upward, the buttons stay put
local CREDIT = "Marauders is being developed by a small team from the UK. Offline PvE was created via Claude Code and is not affiliated with the original developer and publisher."

function S.init(ctx) X = ctx end

-- True once the live login widget has both. Widgets aren't kept between calls: they go with their world.
function S.apply(pc)
    for _, w in ipairs(FindAllOf("SIGIS_LoginWidget_C") or {}) do
        if w:GetFullName():find("/Engine/Transient", 1, true) then -- not the Blueprint's template
            local tex = X.lib("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc, LOGO)
            if not X.valid(tex) then
                X.log("splash: no logo at " .. LOGO)
                return true
            end
            local logo = w.Border_Logo
            logo:SetBrushFromTexture(tex)
            local box = logo:GetParent()
            box:SetWidthOverride(LOGO_W)
            box:SetHeightOverride(LOGO_H)
            -- not a Blueprint variable, so it's found by its path under the widget
            local path = w:GetFullName():match("^%S+%s+(.+)$")
            StaticFindObject(path .. ".WidgetTree.TextBlock_59"):SetText(FText(CREDIT))
            X.log("splash: logo and credit set")
            return true
        end
    end
    return false
end

-- PLAY before the game's backend login finishes crashes inside nakama-cpp.dll (a null read under the button's handler).
-- The 60 s startup video used to cover that window; with it skipped (config/skip_intro.txt) the splash is up ~6 s
-- before the login. So PLAY stays hidden (layout kept) until the game instance has its Nakama player id. Called every
-- frame from the director's tick; looks at most 4 times a second, and never again once the login is done (it's once
-- per game session).
local G = { done = false, at = 0 }
function S.gatePlay()
    if G.done then return end
    local now = os.clock()
    if now < G.at then return end
    G.at = now + 0.25
    if not X.valid(G.gi) then G.gi = FindFirstOf("SIGIS_ExampleGameInstance_C") end
    if not X.valid(G.login) then
        G.login = nil
        for _, w in ipairs(FindAllOf("SIGIS_LoginWidget_C") or {}) do
            if w:GetFullName():find("/Engine/Transient", 1, true) then G.login = w break end
        end
    end
    local play = G.login and G.login.MM_GenericSmallBtn01_1
    if not X.valid(play) then return end
    local ready = X.valid(G.gi) and #G.gi.NakamaPlayerID:ToString() > 0
    play:SetVisibility(ready and 0 or 2) -- Visible / Hidden
    if ready then
        X.log("splash: PLAY shown, backend login done")
        G.done, G.gi, G.login = true, nil, nil
    end
end

return S
