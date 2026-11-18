-- The raid loading screen, in the trailer's style: backdrop, a caption per stage, a progress bar. The art is pre-rendered
-- by trailer/make_loading.py (the trailer's font isn't in the game) and loaded with ImportFileAsTexture2D. It sits over
-- the black veil (main.lua veilUntilAboard), which says what the load is doing; it fades out as the game fades in.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local L = {}
local X -- context from main.lua: log, valid, lib, root

local DIR = PROJECT .. "assets/loading/"
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C" -- as tuning.lua: a Blueprint with a canvas root
local STAGES = { "world", "match", "ship", "ready" }
local ART_W, ART_H = 1920, 1080 -- layout below is in art pixels, scaled to the window
local CAP_X, CAP_Y, CAP_W, CAP_H = 120, 750, 1100, 240 -- where make_loading.py's captions go
local BAR_X, BAR_Y, BAR_W, BAR_H = 152, 970, 640, 4
local SLIDE, CAPTION_IN, FADE_OUT = 60, 0.4, 1.0 -- caption slide (art pixels) and fade seconds, as in the trailer
local BAR_EASE = 0.12 -- the bar closes this share of the gap per frame

local ui

local function ease(x)
    x = math.max(0, math.min(1, x))
    return 1 - (1 - x) ^ 3
end

function L.init(ctx) X = ctx end

local function make(cls)
    return StaticConstructObject(X.lib("/Script/UMG." .. cls), ui.tree)
end

local function image(pc, file)
    local tex = X.lib("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc, DIR .. file)
    if not X.valid(tex) then return nil end
    local img = make("Image")
    img:SetBrushFromTexture(tex, false)
    return img
end

local function place(widget, x, y, w, h)
    local slot = ui.root:AddChildToCanvas(widget)
    slot:SetPosition({ X = ui.x0 + x * ui.scale, Y = ui.y0 + y * ui.scale })
    slot:SetSize({ X = w * ui.scale, Y = h * ui.scale })
    return slot
end

local function bar(r, g, b, a)
    local w = make("Border")
    w:SetBrushColor({ R = r, G = g, B = b, A = a })
    return w
end

function L.show(pc)
    if ui then return true end
    local lib = X.lib
    local cls = lib(HOST)
    if not X.valid(cls) then
        pcall(LoadAsset, (HOST:match("^[^.]+")))
        cls = lib(HOST)
    end
    if not X.valid(cls) then return false end
    local host = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not X.valid(host) then return false end
    ui = { host = host, tree = host.WidgetTree, root = host.WidgetTree.RootWidget, caps = {}, frac = 0, want = 0,
        world = pc:GetWorld():GetAddress() }
    ui.root:ClearChildren()
    local layout = lib("/Script/UMG.Default__WidgetLayoutLibrary")
    local vp, s = layout:GetViewportSize(pc), layout:GetViewportScale(pc)
    local vw, vh = vp.X / s, vp.Y / s
    ui.scale = math.max(vw / ART_W, vh / ART_H)
    -- centred: a window that isn't 16:9 crops the art, it doesn't stretch it
    ui.x0, ui.y0 = (vw - ART_W * ui.scale) / 2, (vh - ART_H * ui.scale) / 2
    local bg = image(pc, "backdrop.png")
    if not bg then
        X.log("loading screen: no art in " .. DIR)
        ui = nil
        return false
    end
    place(bg, 0, 0, ART_W, ART_H)
    for _, key in ipairs(STAGES) do
        local img = image(pc, "cap_" .. key .. ".png")
        if img then
            local cs = place(img, CAP_X, CAP_Y, CAP_W, CAP_H)
            img:SetVisibility(1)
            ui.caps[key] = { img = img, slot = cs }
        end
    end
    local track = bar(1, 1, 1, 0.15)
    place(track, BAR_X, BAR_Y, BAR_W, BAR_H)
    ui.fill = bar(1, 0.3, 0.02, 1)
    ui.fillSlot = place(ui.fill, BAR_X, BAR_Y, 1, BAR_H)
    for _, w in ipairs({ track, ui.fill }) do w:SetVisibility(4) end -- HitTestInvisible: nothing to click
    host:SetVisibility(4) -- HitTestInvisible: never takes the mouse from the game under it
    host:AddToViewport(1000)
    L.stage("world", 0)
    return true
end

-- What the load is doing now, and how far along (0-1).
function L.stage(key, frac)
    if not ui or ui.closingAt then return end
    ui.want = math.max(ui.want, frac)
    if key == ui.key then return end
    if ui.key and ui.caps[ui.key] then ui.caps[ui.key].img:SetVisibility(1) end
    ui.key, ui.keyAt = key, os.clock()
    local c = ui.caps[key]
    if c then
        c.img:SetVisibility(4)
        c.img:SetOpacity(0)
    end
end

-- Every frame while it's up. The widgets die with their world, and a new world's first tick comes before anything else
-- has noticed: reading one then crashes inside UE4SS, so a tick from another world only drops them.
function L.tick(ticker)
    if not ui then return end
    if ticker:GetWorld():GetAddress() ~= ui.world then
        ui = nil
        return
    end
    local now = os.clock()
    ui.frac = ui.frac + (ui.want - ui.frac) * BAR_EASE
    ui.fillSlot:SetSize({ X = math.max(1, ui.frac * BAR_W) * ui.scale, Y = BAR_H * ui.scale })
    local c = ui.caps[ui.key]
    if c then
        local t = ease((now - ui.keyAt) / CAPTION_IN)
        c.img:SetOpacity(t)
        c.slot:SetPosition({ X = ui.x0 + (CAP_X + SLIDE * (1 - t)) * ui.scale, Y = ui.y0 + CAP_Y * ui.scale })
    end
    if ui.closingAt then
        local t = (now - ui.closingAt) / FADE_OUT
        if t >= 1 then
            ui.host:RemoveFromParent()
            ui = nil
        else
            ui.host:SetRenderOpacity(1 - t)
        end
    end
end

-- While a map travels the game thread is stopped and only the game's own loading screen draws (the AsyncLoadingScreen
-- plugin, on its own thread). It takes its picture by path from its settings, and a path resolves to anything in memory,
-- so for a raid launch it's pointed at our art, with its "LOADING" text and pistol moved off screen and the footer strip
-- behind them made transparent. disarm puts it back.
local SETTINGS = "/Script/AsyncLoadingScreen.Default__LoadingScreenSettings"
local saved
-- The travel art, imported once and rooted: the settings only hold its path, so nothing else keeps it from the garbage
-- collector, and the collection map travel runs freed it before the loading screen (on its own thread) looked it up.
local travelTex

function L.arm(pc)
    local s = X.lib(SETTINGS)
    if not X.valid(s) then return end
    local tex = travelTex
    if not tex then
        tex = X.lib("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc, DIR .. "travel.png")
        if not X.valid(tex) then return end
        if not X.root then return end -- unrooted it can be freed mid-travel: keep the game's own picture instead
        X.root(tex)
        travelTex = tex
    end
    local d = s.DefaultLoadingScreen
    d.Background.Images:ForEach(function(_, e)
        local sp = e:get()
        saved = saved or { path = sp.AssetPathName:ToString(), text = d.LoadingWidget.LoadingText:ToString(),
            x = d.LoadingWidget.TransformTranslation.X, strip = s.Classic.BorderBackground.TintColor.SpecifiedColor.A }
        sp.AssetPathName = FName((tex:GetFullName():gsub("^%S+ ", "")))
    end)
    d.LoadingWidget.LoadingText = FText("")
    d.LoadingWidget.TransformTranslation.X = -20000
    s.Classic.BorderBackground.TintColor.SpecifiedColor.A = 0
end

function L.disarm()
    if not saved then return end
    local s, was = X.lib(SETTINGS), saved
    saved = nil
    if not X.valid(s) then return end
    local d = s.DefaultLoadingScreen
    d.Background.Images:ForEach(function(_, e) e:get().AssetPathName = FName(was.path) end)
    d.LoadingWidget.LoadingText = FText(was.text)
    d.LoadingWidget.TransformTranslation.X = was.x
    s.Classic.BorderBackground.TintColor.SpecifiedColor.A = was.strip
end

-- The game is ready behind it: fade out.
function L.finish()
    if ui and not ui.closingAt then
        L.stage("ready", 1)
        ui.want, ui.closingAt = 1, os.clock()
    end
end

-- A new world: the old one took the widgets with it, so they're dropped untouched.
function L.reset() ui = nil end

return L
