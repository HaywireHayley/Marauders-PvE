-- The player's own key bindings (issue #103). The game keeps them in InputSettings.ActionMappings (Input.ini; its key
-- menu saves remaps there), so "is Use held" is asked of whatever keys "Use" is bound to, not of a hard-coded F.
--   local Keys = require("keys")
--   Keys.down(pc, "Use", "F")   -- held? ("F": the default, used if the action has no binding at all)
local K = {}
local REREAD = 5 -- seconds: a remap made in the game's menu shows up within this
local cache, readAt = {}, -1e9

local function keysFor(action)
    local now = os.clock()
    if now - readAt > REREAD then cache, readAt = {}, now end
    local list = cache[action]
    if list then return list end
    list = {}
    pcall(function()
        StaticFindObject("/Script/Engine.Default__InputSettings").ActionMappings:ForEach(function(_, e)
            local m = e:get()
            if m.ActionName:ToString() == action then
                local key = m.Key.KeyName:ToString()
                if not key:find("^Gamepad") then list[#list + 1] = key end
            end
        end)
    end)
    cache[action] = list
    return list
end

function K.down(pc, action, default)
    local list = keysFor(action)
    if #list == 0 and default then list = { default } end
    for _, key in ipairs(list) do
        local down = false
        pcall(function() down = pc:IsInputKeyDown({ KeyName = FName(key) }) end)
        if down then return true end
    end
    return false
end

-- The first keyboard/mouse key bound to an action (for prompts), or the default.
function K.name(action, default)
    return keysFor(action)[1] or default
end

return K
