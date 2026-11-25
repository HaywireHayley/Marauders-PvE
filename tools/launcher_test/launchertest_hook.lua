-- Launcher test hook (tools/launcher_test, test installs only). Added by hand (see README.md) as one line at the end of
-- botdamage.lua: require("launchertest_hook")(B). It gives launchertest.lua its tick every frame, from the damage module's frame,
-- and its F9 button (through debugmenu.addActions), without the shipped code knowing about it. If launchertest.lua fails to load,
-- the hook does nothing.
return function(B)
    local test, tried
    local frame = B.frame

    local function load()
        if tried then return test end
        tried = true
        local ok, m = pcall(require, "launchertest")
        if ok and type(m) == "table" then
            test = m
            pcall(function() require("debugmenu").addActions(m.actions()) end)
        else
            print("[PvEDirector] launcher test failed to load: " .. tostring(m) .. "\n")
        end
        return test
    end

    function B.frame(pc)
        local t = load()
        if t then pcall(t.tick, os.clock(), pc) end
        frame(pc)
    end
end
