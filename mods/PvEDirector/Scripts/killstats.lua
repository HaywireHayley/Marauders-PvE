-- The end-of-raid KILLS list. The game files each of YOUR kills in PlayerState.InMatchStats ({StatName, StatAmmount})
-- under the victim's kind, and BFL_UI_Functionality:Translate_K_ForKillList names it: K_AISAS -> "SAS Operative",
-- K_AICommando -> "Commando", K_AIRaider -> "Raider", K_Human -> "Marauder" (the one kind it counts as a player kill).
-- Rivals stand in for other players but wear soldier bodies, so their deaths were filed as station guards. This moves
-- each rival you kill over to K_Human.
--
-- How: rivals.lua calls K.rivalDied() when one dies. Each K.update() looks at what the game added since the last look
-- and moves one of those additions per rival death to K_Human. A death the game files nothing for (your crew or a
-- soldier got the kill) expires after PENDING_SECONDS.
--
-- UE4SS can rename and recount an entry but can't append one; pvepatch's pve_array_grow adds a blank entry in the
-- array's spare room (never reallocates; the engine's allocator owns the buffer). With no room: a zeroed entry is
-- reused, and failing that the kill stays filed as the soldier kind (logged).
local PROJECT = require("pveproject")
local K = {}

local HUMAN = "K_Human"
local PENDING_SECONDS = 3
local STAT_SIZE = 0x18                 -- FPlayerStat: FString StatName, int32 StatAmmount
local IN_MATCH_STATS = 0x410           -- ASIGISPlayerState::InMatchStats
local grow = package.loadlib(PROJECT .. "native/pvepatch.dll", "pve_array_grow") -- (TArray address, element size)

local seen = {}      -- name -> amount at the last look (after our own moves)
local pending = {}   -- os.clock() of each rival death not yet matched to a kill stat
local log = print

function K.init(logFn) log = logFn or print end

-- New raid: forget the last one.
function K.reset() seen, pending = {}, {} end

function K.rivalDied() pending[#pending + 1] = os.clock() end

local function str(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or ""
end

local function read(arr)
    local list = {}
    for i = 1, #arr do
        local el = arr[i]
        list[i] = { el = el, name = str(el.StatName), n = el.StatAmmount or 0 }
    end
    return list
end

-- One kill of this entry's kind becomes a Marauder.
local function move(ps, arr, list, from)
    local human
    for _, s in ipairs(list) do if s.name == HUMAN then human = s end end
    if not human and from.n == 1 then
        from.el.StatName, from.name = HUMAN, HUMAN
        return true
    end
    if not human then
        for _, s in ipairs(list) do
            if s.n == 0 and s.name:sub(1, 2) == "K_" then human = s break end
        end
        if human then
            human.el.StatName, human.name = HUMAN, HUMAN
        elseif grow then
            local before = #arr
            pcall(grow, ps:GetAddress() + IN_MATCH_STATS, STAT_SIZE)
            if #arr == before + 1 then
                local el = arr[#arr]
                el.StatName, el.StatAmmount = HUMAN, 0
                human = { el = el, name = HUMAN, n = 0 }
                list[#list + 1] = human
            end
        end
    end
    if not human then return false end
    human.n = human.n + 1
    human.el.StatAmmount = human.n
    from.n = from.n - 1
    from.el.StatAmmount = from.n
    return true
end

function K.update(pc)
    local ps = pc and pc.PlayerState
    if not (ps and ps:IsValid()) then return end
    local arr = ps.InMatchStats
    local now = os.clock()
    while pending[1] and now - pending[1] > PENDING_SECONDS do table.remove(pending, 1) end
    local list = read(arr)
    if #pending > 0 then
        for _, s in ipairs(list) do
            local added = s.n - (seen[s.name] or 0)
            while added > 0 and #pending > 0 and s.name ~= HUMAN and s.name:sub(1, 2) == "K_" do
                local was = s.name
                if not move(ps, arr, list, s) then
                    log(("[kills] a rival's kill stays filed as %s: no room in the kill list"):format(was))
                    table.remove(pending, 1)
                    break
                end
                table.remove(pending, 1)
                added = added - 1
                log(("[kills] a rival's kill moved from %s to %s"):format(was, HUMAN))
                if s.name == HUMAN then break end -- the entry itself was renamed
            end
        end
    end
    seen = {}
    for _, s in ipairs(read(arr)) do seen[s.name] = (seen[s.name] or 0) + s.n end
end

return K
