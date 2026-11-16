-- The lobby's START MATCHMAKING button says START RAID offline: there's no search, it loads a raid straight away
-- (main.lua onStartMatchmaking). The label is TextBlock_31 inside Crew_LaunchToMatchBtn_SubWidget_C (Captain and
-- Crewmember copies), a plain widget of its WidgetTree with no variable of its own.
-- The buttons are found once per lobby with a FindAllOf (about 50 ms), and kept as object paths, not objects: each
-- check looks them up again (StaticFindObject, a name lookup), so a lobby torn down by a raid is never touched.
local L = {}
local X -- log, offline (function)

local CHECK_SECONDS = 1
local LABEL = "START RAID"
local paths, nextCheck, nextFind = nil, 0, 0

function L.init(ctx) X = ctx end

local function find()
    paths = {}
    for _, w in ipairs(FindAllOf("Crew_LaunchToMatchBtn_SubWidget_C") or {}) do
        local name = w:GetFullName():gsub("^%S+ ", "") -- (the class name comes first)
        if name:find("Transient", 1, true) then
            -- (UWidgetTree::FindWidget isn't callable from Lua; the label's path follows from the button's)
            local path = name .. ".WidgetTree.TextBlock_31"
            local t = StaticFindObject(path)
            if t and t:IsValid() then paths[#paths + 1] = path end
        end
    end
end

-- Every frame from the director's tick (ticker: the object it ticks on, the lobby's MM_CoreMissions there); only does
-- anything in the lobby with the offline backend.
function L.tick(ticker)
    local now = os.clock()
    if now < nextCheck then return end
    nextCheck = now + CHECK_SECONDS
    local inLobby = ticker:IsValid() and ticker:GetClass():GetFName():ToString() == "MM_CoreMissions_C"
    if not (inLobby and X.offline()) then paths = nil return end
    if not paths or #paths == 0 then
        if now < nextFind then return end
        nextFind = now + 5 -- the lobby's widgets may not exist yet
        find()
        if #paths > 0 then X.log(("lobby: launch button relabelled %s (%d)"):format(LABEL, #paths)) end
    end
    for i = #paths, 1, -1 do
        local t = StaticFindObject(paths[i])
        if t and t:IsValid() then
            if t:GetText():ToString() ~= LABEL then t:SetText(FText(LABEL)) end
        else
            table.remove(paths, i) -- gone: found again on the next pass
        end
    end
end

return L
