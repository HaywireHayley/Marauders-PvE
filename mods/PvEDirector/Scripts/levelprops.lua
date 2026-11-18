-- Level props that sit still and silent offline (issue #143): spinning fans and tape reels, their ambient hum, and
-- broken machinery's random sparks. Their Blueprints start them from BeginPlay only `if not IsServer()` (the client
-- side: a listen or dedicated server has no one to show them to), and offline the game is the server, so it never
-- happens. Decompiled 2026-11-18 (tools/offline-audit/kdis.py):
--   MA_RotatingParent_Simple / _WithAmbience: K2_SetTimer(self, "LoopThisActor", Frequency, looping); _WithAmbience
--     also Audio.FadeIn(1, 1, 0) if ShouldPlaySound. LoopThisActor turns the mesh only while it was recently rendered.
--     (The Simple one also starts in the main menu, which is why props turn there.)
--   Base_Broken_OneShots_Parent: PickARandomGoalNumber(), K2_SetTimer(self, "DoAnEvent", FrequencyOfCheck, looping):
--     every few checks a spark sound and particle burst.
-- This makes the same calls once per prop; the game runs the timers from then on (nothing per frame in Lua).
-- Ship interiors (FrigateInside_*, RaidSpaceshipInside): the engine hum, Audio_EngineAmbience.FadeIn(2, 1, 0), is the
--   client branch of their BeginPlay (`if not IsServer()`, kdis 2026-11-18: FrigateInside_Starter @2115 -> 3976), so
--   your ship was silent inside. Faded in once per interior; checked every HUM_EVERY s, as interiors spawn later too
--   (a rival's, when you board it).
local P = {}
local X -- log, valid, lib
local raid

local KINDS = {
    { cls = "MA_RotatingParent_Simple_C", timer = "LoopThisActor", rate = "Frequency" },
    { cls = "MA_RotatingParent_WithAmbience_C", timer = "LoopThisActor", rate = "Frequency", sound = true },
    { cls = "Base_Broken_OneShots_Parent_C", timer = "DoAnEvent", rate = "FrequencyOfCheck", goal = true },
}
local PASSES = { 4, 30 } -- seconds into the raid: one pass as you arrive, one for anything that loaded later
local HUM_EVERY = 15

function P.init(ctx) X = ctx end
function P.setRaid(r) raid = r end

local function start(a, kind, timers)
    local rate = a[kind.rate]
    if type(rate) ~= "number" or rate <= 0 then return false end
    if kind.goal then a:PickARandomGoalNumber() end
    timers:K2_SetTimer(a, kind.timer, rate, true, 0, 0)
    if kind.sound and a.ShouldPlaySound and X.valid(a.Audio) then a.Audio:FadeIn(1, 1, 0, 0) end
    return true
end

-- From the director's update with this map's age (seconds): each pass looks for one kind per call (a FindAllOf walks
-- every object, ~50 ms), so a pass is spread over three updates.
local function hum(age)
    local h = raid.hum
    if not h then h = { next = 4, done = {} } raid.hum = h end
    if age < h.next then return end
    h.next = age + HUM_EVERY
    for _, a in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if X.valid(a) and not h.done[a:GetAddress()] then
            h.done[a:GetAddress()] = true
            local s = a.Audio_EngineAmbience
            if s and X.valid(s) and not s:IsPlaying() then
                s:FadeIn(2, 1, 0, 0)
                X.log("level props: engine hum on in " .. a:GetClass():GetFName():ToString())
            end
        end
    end
end

function P.update(age)
    if not raid then return end
    local okh, errh = pcall(hum, age)
    if not okh then X.log("level props: hum: " .. tostring(errh)) end
    local s = raid.props
    if not s then
        s = { pass = 1, kind = 1, done = {}, started = 0 }
        raid.props = s
    end
    local due = PASSES[s.pass]
    if not due or age < due then return end
    local kind = KINDS[s.kind]
    local timers = X.lib("/Script/Engine.Default__KismetSystemLibrary")
    local n = 0
    for _, a in ipairs(FindAllOf(kind.cls) or {}) do
        if X.valid(a) then
            local key = a:GetAddress()
            if not s.done[key] then
                s.done[key] = true
                local ok, res = pcall(start, a, kind, timers)
                if ok and res then n = n + 1 elseif not ok then X.log("level props: " .. kind.cls .. ": " .. tostring(res)) end
            end
        end
    end
    s.started = s.started + n
    s.kind = s.kind + 1
    if s.kind > #KINDS then
        X.log(("level props: %d started (fans, reels, ambience, sparks; pass %d)"):format(s.started, s.pass))
        s.kind, s.pass = 1, s.pass + 1
    end
end

return P
