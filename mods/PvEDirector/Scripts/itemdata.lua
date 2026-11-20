-- What assets/saves/items.json says about an item row (taken from the game's item table): its type, stack maximum,
-- grid size and price. Read once, on first use. The Lua side can't read the game's DataTable rows itself (UE4SS
-- 3.0.1 has no row access), so this file is the source for stack limits and sizes.
--   local Items = require("itemdata")
--   Items.max("12GaugeAmmo")   --> 20 (nil for a row it doesn't know)
--   Items.get("Mat49Rifle")    --> { type = 0, stackable = 0, max = 36, dur = ..., w = 4, h = 2, price = ... }
local PROJECT = require("pveproject")
local I = {}
local rows, lower

local function load()
    rows, lower = {}, {}
    local f = io.open(PROJECT .. "assets/saves/items.json", "r")
    if not f then return end
    local text = f:read("a")
    f:close()
    for name, body in text:gmatch('"([^"]+)"%s*:%s*(%b{})') do
        local r = {}
        for k, v in body:gmatch('"(%w+)"%s*:%s*(%-?%d+)') do r[k] = tonumber(v) end
        rows[name] = r
        lower[name:lower()] = r
    end
end

-- (An FName keeps the case it was first made with in the session, so a row can read "Toolkit" for "ToolKit".)
function I.get(row)
    if not rows then load() end
    return rows[row] or (row and lower[row:lower()])
end

function I.max(row)
    local r = I.get(row)
    return r and r.max
end

-- n, or the row's stack maximum if that's less (unknown rows: n).
function I.capStack(row, n)
    local m = I.max(row)
    return (m and m > 0 and n > m) and m or n
end

return I
