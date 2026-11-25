-- Recoil test hook (tools/recoil_test, test installs only). Added by hand (see README.md) as one line at the end of
-- botdamage.lua: require("recoiltest_hook")(B). It gives the tests (recoiltest.lua, recoiltest_auto.lua) what they need from the damage module without the shipped
-- code knowing about it: its tick every frame before the damage code runs, its afterFrame every frame after the game's own frame,
-- and its F9 button (through debugmenu.addActions; the menu code itself is not changed). If recoiltest.lua fails to load, the hook
-- does nothing.
return function(B)
    local tests, tried = {}, false
    local frame = B.frame

    local function load()
        if tried then return tests end
        tried = true
        for _, name in ipairs({ "recoiltest", "recoiltest_auto" }) do
            local ok, m = pcall(require, name)
            if ok and type(m) == "table" then
                tests[#tests + 1] = m
                pcall(function() require("debugmenu").addActions(m.actions()) end)
            else
                print("[PvEDirector] recoil test failed to load: " .. name .. " " .. tostring(m) .. "\n")
            end
        end
        return tests
    end

    function B.frame(pc)
        local ts = load()
        for _, t in ipairs(ts) do pcall(t.tick, os.clock(), pc) end
        frame(pc)
        for _, t in ipairs(ts) do
            if t.afterFrame then
                local ok, v = pcall(function() return pc ~= nil and pc:IsValid() and pc.Pawn ~= nil and pc.Pawn:IsValid() end)
                if ok and v then pcall(t.afterFrame, pc) end
            end
        end
    end
end
