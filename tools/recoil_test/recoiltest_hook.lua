-- Recoil test hook (tools/recoil_test, test installs only). Added by hand (see README.md) as one line at the end of
-- botdamage.lua: require("recoiltest_hook")(B). It gives recoiltest.lua what it needs from the damage module without the shipped
-- code knowing about it: its tick every frame before the damage code runs, its afterFrame every frame after the game's own frame,
-- and its F9 button (through debugmenu.addActions; the menu code itself is not changed). If recoiltest.lua fails to load, the hook
-- does nothing.
return function(B)
    local test, tried
    local frame = B.frame

    local function load()
        if tried then return test end
        tried = true
        local ok, m = pcall(require, "recoiltest")
        if ok and type(m) == "table" then
            test = m
            pcall(function() require("debugmenu").addActions(m.actions()) end)
        else
            print("[PvEDirector] recoil test failed to load: " .. tostring(m) .. "\n")
        end
        return test
    end

    function B.frame(pc)
        local t = load()
        if t then pcall(t.tick, os.clock(), pc) end
        frame(pc)
        if t and t.afterFrame then
            local ok, v = pcall(function() return pc ~= nil and pc:IsValid() and pc.Pawn ~= nil and pc.Pawn:IsValid() end)
            if ok and v then pcall(t.afterFrame, pc) end
        end
    end
end
