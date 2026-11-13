-- UE4SS leaks every out-parameter table: calling a UFunction with an out param (a trace's hit result, a navmesh
-- projection's point, a sweep result, actor bounds...) takes a Lua registry reference to the table (luaL_ref) and
-- never releases it. Measured 2026-11-13: +1 registry slot per call, fresh or reused table alike, through a full
-- collection. Cover baking alone traces thousands of times a second, so the hit results (11 sub-tables each) piled up:
-- the director's live heap grew ~0.5 MB/s, to 2 GB in a long raid, and every garbage collection cycle had to mark it
-- all (the 100-430 ms freezes).
--
-- Use: Out.mark() right before the call, Out.free(t1[, t2, t3]) right after it with the out tables passed. It releases
-- the slots the call took that hold exactly those tables, the way luaL_unref does (Lua 5.4.4: the free list head is
-- registry[3], a freed slot holds the next free index). Slots holding anything else are never touched.
local O = {}
local R = debug.getregistry()
local FREE = 3 -- LUA_RIDX_LAST + 1 in 5.4 (lauxlib.c freelist)

-- Free-list head and the next two entries before the call (a call can pop up to three), and the array length.
local h1, h2, h3, len = 0, 0, 0, 0
local function int(v) return math.type(v) == "integer" and v > 0 and v or 0 end

function O.mark()
    h1 = int(R[FREE])
    h2 = h1 > 0 and int(R[h1]) or 0
    h3 = h2 > 0 and int(R[h2]) or 0
    len = #R
end

local released = 0
local function try(k, a, b, c)
    if k <= 0 then return end
    local v = R[k]
    if v ~= nil and type(v) == "table" and (rawequal(v, a) or rawequal(v, b) or rawequal(v, c)) then
        R[k] = R[FREE]
        R[FREE] = k
        released = released + 1
    end
end

function O.free(a, b, c)
    try(h1, a, b, c)
    try(h2, a, b, c)
    try(h3, a, b, c)
    for k = len + 1, len + 4 do try(k, a, b, c) end
end

-- Releases the slots the last call took that hold any of the given values (the call's own arguments).
local function tryArgs(k, ...)
    if k <= 0 then return end
    local v = R[k]
    if type(v) ~= "table" then return end
    for i = 1, select("#", ...) do
        if rawequal(v, (select(i, ...))) then
            R[k] = R[FREE]
            R[FREE] = k
            released = released + 1
            return
        end
    end
end

-- obj:name(...) with its out-param tables released afterwards: Out.call(nav, "K2_ProjectPointToNavigation", pc, at, out, ...).
-- Returns the call's first result (the UFunctions used this way return at most a bool).
function O.call(obj, name, ...)
    O.mark()
    local r = obj[name](obj, ...)
    tryArgs(h1, ...)
    tryArgs(h2, ...)
    tryArgs(h3, ...)
    for k = len + 1, len + 4 do tryArgs(k, ...) end
    return r
end

-- Slots released so far, and the registry's size (for the profiler).
function O.stats() return released, #R end

return O
