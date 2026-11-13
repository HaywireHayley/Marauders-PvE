-- PvEQuitProbe: finds the UFunction that quits the SECOND game instance (co-op client).
-- Keeps an in-memory ring of recent ProcessEvent calls and, the first time a quit/exit-looking UFunction is
-- called, dumps the ring (most-recent first) to <PVE_BRIDGE>/quitprobe.log. The top entries are the quit node
-- and the blueprint event the nakama-disconnect callback fired. Diagnostic only; remove once the lever is known.
local PROJECT = require("pveproject") -- the project folder, written by scripts/mode.ps1
local BRIDGE = os.getenv("PVE_BRIDGE") or PROJECT .. "bridge/"
if not BRIDGE:match("[/\\]$") then BRIDGE = BRIDGE .. "/" end
local LOG = BRIDGE .. "quitprobe.log"

local function append(s)
    local f = io.open(LOG, "a")
    if f then f:write(s, "\n"); f:close() end
end
append(os.date("%H:%M:%S ") .. "PvEQuitProbe loading (log=" .. LOG .. ")")

local ring, ri, N = {}, 0, 60     -- ring of recent UFunction objects
local dumped = false

local function fullname(fn)
    local ok, s = pcall(function() return fn:GetFullName() end)
    if ok and type(s) == "string" then return s end
    return tostring(fn)
end

local ok, err = pcall(function()
    RegisterProcessEventPreCallback(function(self, fn)
        ri = ri % N + 1
        ring[ri] = fn                      -- store the object; resolve names only when we dump (cheap per call)
        if dumped then return end
        local n = fullname(fn):lower()
        if n:find("quit", 1, true) or n:find("requestexit", 1, true) or n:find("exitgame", 1, true)
            or n:find("closegame", 1, true) or n:find("forcequit", 1, true) then
            dumped = true
            append("=== QUIT TRIGGER " .. os.date("%H:%M:%S") .. " (most-recent first) ===")
            for i = 0, N - 1 do
                local idx = (ri - 1 - i) % N + 1
                if ring[idx] then append(string.format("  [-%02d] %s", i, fullname(ring[idx]))) end
            end
            append("=== end ===")
        end
    end)
end)
append("hook " .. (ok and "registered" or ("FAILED: " .. tostring(err))))
