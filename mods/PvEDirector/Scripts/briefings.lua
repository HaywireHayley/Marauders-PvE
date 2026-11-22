-- Handler briefings (#333, #272 option 7): a line or two in a handler's voice under a contract's description in the
-- lobby's contracts page. Text from docs/lore/contracts.md (the fan-theory briefings, 3, 11 and 12, are left out).
-- NOT TESTED IN GAME: the contracts page's widget class and field names are not known yet (see TARGETS below).
local M = {}

-- Rows of the contract table start with the station the contract is for (Spaceport_C2, Merchant_A15, Fortress_K28).
-- Only these three prefixes are known; Fortress = Navy Outpost is a GUESS, and the other places have no prefix yet:
-- they're matched by a place name in the contract's own text instead (KEYWORDS).
local BY_PREFIX = {
    Spaceport = "Spaceport",
    Merchant = "Merchant Ship",
    Fortress = "Navy Outpost", -- unverified
}
local BRIEFS = {
    ["Spaceport"] = "Rosie: \"Customs took a crate of my radio valves. It's in the cage behind Desk 3. Go loud if you like, security's off the clock.\"",
    ["Navy Outpost"] = "Wolff: \"The armoury watch is empty from 0400: twelve crates of 1911s nobody will miss. Leave the Marines be. Don't walk the east approach: it's mined.\"",
    ["Mini Mine"] = "Ferenc: \"The Company took my claim. Their strongbox is in the shaft-head hut: the deeds, the wages, my brother's watch. Bring me the watch.\"",
    ["Mining Frigate"] = "Calico: \"The escort's off the Ring lane. The strongroom key hangs round the foreman's neck. Don't fall in the crusher. Guild takes ten per cent.\"",
    ["Penal Colony"] = "Pirate Trader: \"The Warden's eleven guards short and the payroll vault's full. Prisoners will beg a lift: your ship, your call.\"",
    ["Rebel Base"] = "Major Ffoulkes: \"Stop the press at the so-called Rebel Base. Keep whatever arms you find. The Kingdom will deny this letter. Burn it.\"",
    ["Capital Ship"] = "Greybeard: \"Guest night in the wardroom. The paymaster's office two decks down has a steward and a lock. Keep away from the wardroom.\"",
    ["Merchant Ship"] = "Rosie: \"The Faithful Margaret: Thompson drums under the tinned fish. Take the drums, leave the lead can unless you're mad.\"",
    ["Colony Cruiser"] = "Calico: \"The cruiser's reserve pods wake on day 270. Fungus jars from Lab 1 and the purser's ration cards. Don't touch the sleepers.\"",
}
local KEYWORDS = { -- (lower case) a place name in a contract's text -> BRIEFS key
    { "spaceport", "Spaceport" }, { "navy", "Navy Outpost" }, { "outpost", "Navy Outpost" },
    { "mini mine", "Mini Mine" }, { "mining frigate", "Mining Frigate" }, { "penal", "Penal Colony" },
    { "rebel", "Rebel Base" }, { "capital", "Capital Ship" }, { "merchant", "Merchant Ship" },
    { "cruiser", "Colony Cruiser" },
}

-- Where the contract cards are. FILL IN after the probe described in NOTES.md ("Handler briefings"), one entry per
-- widget class: { class = "<WidgetClass_C>", desc = "<path under the widget to its description TextBlock>",
-- row = "<property on the widget holding the contract row name>" (optional: without it the text's place name is used) }.
-- Empty: lobbylabel.lua doesn't call tick until there is an entry.
M.TARGETS = {}

-- The briefing for a contract: by its row name's prefix, else by a place name in its text. nil when none fits.
function M.briefingFor(row, text)
    local prefix = row and tostring(row):match("^(%a+)_")
    if prefix and BY_PREFIX[prefix] then return BRIEFS[BY_PREFIX[prefix]] end
    local low = (text or ""):lower()
    for _, k in ipairs(KEYWORDS) do
        if low:find(k[1], 1, true) then return BRIEFS[k[2]] end
    end
end

-- Set a description TextBlock's text to its original plus the briefing below it. Repeated calls change nothing; a
-- widget the game redrew with its own text gets the briefing again. Only plain `Text` property reads.
function M.apply(tb, row)
    if not (tb and tb:IsValid()) then return false end
    local cur = tb.Text:ToString()
    local brief = M.briefingFor(row, cur)
    if not brief or cur:find(brief, 1, true) then return false end
    tb:SetText(FText(cur ~= "" and (cur .. "\n\n" .. brief) or brief))
    return true
end

-- Every check from lobbylabel.lua (lobby, offline): the briefings on the contracts page, once its widgets are known.
-- Widgets are looked up by path each time (StaticFindObject), never kept.
function M.tick()
    if require("features").BRIEFINGS ~= 1 then return end
    for _, t in ipairs(M.TARGETS) do
        for _, w in ipairs(FindAllOf(t.class) or {}) do
            local name = w:GetFullName():gsub("^%S+ ", "")
            if name:find("Transient", 1, true) then
                local tb = StaticFindObject(name .. "." .. t.desc)
                if tb and tb:IsValid() then
                    local row
                    if t.row then
                        local v = w[t.row]
                        row = v and v.ToString and v:ToString() or nil
                    end
                    pcall(M.apply, tb, row)
                end
            end
        end
    end
end

return M
