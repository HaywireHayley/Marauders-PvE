-- The settings files in config/ (raid length, space gate, share of women, crew switches...): one reader. Modules opened
-- them themselves, each polling on its own timer; here a file is read again only after `maxAge` seconds (default 2),
-- so the launcher's changes still arrive while the game runs, and every reader of a file shares one read.
--   line(name [, maxAge])   the file's first line, lower case and without spaces, or nil when there's no file
--   write(name, value)      writes one line (and the next line() sees it at once)
local PROJECT = require("pveproject")
local M = {}
local cache = {} -- name -> { at = os.clock(), v = string|false }

function M.line(name, maxAge)
    local now = os.clock()
    local c = cache[name]
    if c and now - c.at < (maxAge or 2) then return c.v or nil end
    local v = false
    local f = io.open(PROJECT .. "config/" .. name, "r")
    if f then
        v = (f:read("l") or ""):lower():gsub("%s", "")
        f:close()
    end
    cache[name] = { at = now, v = v }
    return v or nil
end

function M.write(name, value)
    local f = io.open(PROJECT .. "config/" .. name, "w")
    if not f then return false end
    f:write(tostring(value), "\n")
    f:close()
    cache[name] = nil
    return true
end

return M
