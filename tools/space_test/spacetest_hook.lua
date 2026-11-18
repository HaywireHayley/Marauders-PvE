-- Space test hook (tools/space_test, test installs only). Installed by tools/space_test/install.py as one line at the end of
-- botdamage.lua: require("spacetest_hook")(B). It gives testtools.lua its tick (which drives explowatch.lua, salvagewatch.lua and the
-- spawner's kill watches) from the damage module's per frame call, without the shipped code knowing about it:
--   - its tick every frame, before the damage code runs;
--   - its afterFrame every frame, after the damage code has run, only in a raid with a live pawn.
-- (The F9 buttons are added by the line install.py puts in debugactions.lua, so they are in the menu from the start, also in the lobby.)
-- Nothing here changes how the damage code works. If testtools.lua fails to load, the hook does nothing.
return function(B)
    local test, tried
    local frame = B.frame

    local function valid(o)
        local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
        return ok and v
    end

    function B.frame(pc)
        if not tried then
            tried = true
            local ok, m = pcall(require, "testtools")
            if ok and type(m) == "table" then test = m end
        end
        if test then pcall(test.tick, os.clock(), pc) end
        frame(pc)
        if test and test.afterFrame and valid(pc) and valid(pc.Pawn) then pcall(test.afterFrame, pc) end
    end
end
