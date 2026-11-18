-- Armour test hook (tools/armour_test, test installs only). Installed by tools/armour_test/install.ps1 as one line at the end of
-- botdamage.lua: require("armourtest_hook")(B). It gives armourtest.lua what it needs from the damage module without the shipped
-- code knowing about it:
--   - its tick every frame, before the damage code runs;
--   - its afterFrame every frame, after the damage code has seen the clip (so a bottomless mags module can top the clip up);
--   - its dummy raider in the bots list while it runs, so the shotgun pellets of botdamage.lua see it as a bot;
--   - its F9 button, through debugmenu.addActions (the menu code itself is not changed).
-- Nothing here changes how the damage code works. If armourtest.lua fails to load, the hook does nothing.
return function(B)
    local test, tried
    local init, frame = B.init, B.frame
    local ctxRef

    local function load()
        if tried then return test end
        tried = true
        local ok, m = pcall(require, "armourtest")
        if ok and type(m) == "table" then
            test = m
            pcall(function() require("debugmenu").addActions(m.actions()) end)
        end
        return test
    end

    function B.init(ctx)
        ctxRef = ctx
        local real = ctx.bots
        ctx.bots = function()
            local list = real()
            if not list or not test or not test.entries then return list end
            local ok, extra = pcall(test.entries)
            if not (ok and extra) then return list end
            local merged = {}
            for _, e in ipairs(list) do merged[#merged + 1] = e end
            for _, e in ipairs(extra) do merged[#merged + 1] = e end
            return merged
        end
        return init(ctx)
    end

    function B.frame(pc)
        local t = load()
        if t then pcall(t.tick, os.clock(), pc) end
        frame(pc)
        -- (only inside a raid, and only with a live pawn: nothing of the controller is touched before that)
        if t and t.afterFrame and ctxRef and ctxRef.bots() then
            local valid = ctxRef.valid
            if valid(pc) and valid(pc.Pawn) then pcall(t.afterFrame, pc) end
        end
    end
end
