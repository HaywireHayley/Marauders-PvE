-- Hiring your crew: a pool of recruits, each a set person (name, look, voice, personality) with a level of ability, whom you
-- hire with your in-game cash. Hired crewmates come on raids for a wage, paid at launch, and get promoted for the raids
-- they survive; one who dies in a raid, or whom you dismiss, is gone for good. Crew and pool are saved in SAVE_FILE, so they last between
-- sessions. The crew is optional: hire nobody, or switch "Crew comes on raids" off, and you raid alone.
--
-- F11 opens the menu (built and polled like the debug menu: plain widgets in a DebugInfo_Widget). Hiring, dismissing and
-- who comes along are changed in the lobby; in a raid the menu only shows the crew. crew.lua runs them in the raid.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local H = {}
local X -- context from main.lua: log, valid, lib, AI, tiers (rivals' loadout tiers)
local Gear = require("gear")
local GearScale = require("gearscale") -- kits follow your player level
local Lines = require("voicelines")

local SAVE_FILE = require("pvebackend") .. "crew.lua"
local CMD_FILE = PROJECT .. "bridge/crew_cmd" -- testing: a menu action per line

local CFG = {
    MAX_CREW = 3,                               -- you + 3: a full live crew
    POOL = 8,                                   -- recruits looking for work
    TURNOVER = 2,                               -- after each raid this many of them have moved on and new ones turned up
    LEVEL_ODDS = { 35, 30, 20, 10, 5 },         -- how often a new recruit is level 1..5
    -- Halved while we test how useful crew are (was 1000/2500/5000/9000/15000 and 300/600/1000/1600/2500)
    FEE = { 500, 1250, 2500, 4500, 7500 },      -- to hire, by level
    WAGE = { 150, 300, 500, 800, 1250 },        -- per raid they come on, by level (a promotion raises it)
    PROMOTE = { 3, 7, 12, 20 },                 -- raids survived for level 2, 3, 4, 5
    -- Worth their price: even a level 1 hire fights clearly better than the best enemy (a rival raider, after the
    -- difficulty preset) and takes a lot more killing. Rivals and soldiers have 100 hp.
    BASE_HP = 200,                              -- health at level 1
    HP_PER_LEVEL = 25,                          -- extra health per level above 1 (300 at level 5)
    -- Their edge over the live rival profile at level 1 and level 5 (straight line between). Multipliers on the
    -- rival's value, except halfAngle (degrees added). Below 1 = better for miss/reaction/spotTime/dispersion.
    KIT_BIAS = 0.05,                            -- gear grade added per crew level above 1 (gearscale.lua; +0.2 at level 5)
    EDGE = {
        miss = { 0.65, 0.4 }, reaction = { 0.65, 0.35 }, spotTime = { 0.75, 0.45 }, dispersion = { 0.75, 0.45 },
        sight = { 1.1, 1.3 }, hearing = { 1.15, 1.4 }, halfAngle = { 5, 15 },
    },
}
H.CFG = CFG
local TITLES = { "Green", "Trained", "Veteran", "Elite", "Ace" }
-- The personality names, as you'd describe the person
local TEMPER = { GigaChad = "fearless", Wreckless = "reckless", Chad = "aggressive", SnappingTurtle = "defensive",
    Normal = "steady", Rat = "sneaky", Timmy = "timid", Coward = "cowardly" }
-- Names by the recruit's sex (their voice and body follow it); the neutral ones go to either.
local NAMES = {
    female = { "Cass", "Dagny", "Iska", "Juno", "Lotte", "Nell", "Piper", "Tamsin", "Ulla", "Wren", "Zora", "Birdie",
        "Della", "Greta", "Imogen", "Lenka", "Noor", "Odette", "Rhea", "Tova", "Vera", "Yara" },
    male = { "Bricks", "Gus", "Hob", "Murdo", "Otto", "Rosco", "Sully", "Vance", "Yusuf", "Abel", "Corvin", "Ezra",
        "Fitz", "Jasper", "Milo", "Pavel", "Silas", "Uri", "Wade", "Zeke" },
    either = { "Ash", "Echo", "Finch", "Kip", "Quinn", "Hollis", "Kit", "Xan" },
}

local D -- the saved state: { pool = { recruit }, crew = { recruit }, enabled, nextId, raid = { ids paid for } }

-- Saving -----------------------------------------------------------------------------------------------------------
local function ser(v, ind)
    local t = type(v)
    if t == "string" then return ("%q"):format(v) end
    if t ~= "table" then return tostring(v) end
    local parts, pad = {}, ind .. "  "
    for k, x in pairs(v) do
        local key = type(k) == "number" and ("[" .. k .. "]") or (k:match("^[%a_][%w_]*$") and k or ("[%q]"):format(k))
        parts[#parts + 1] = pad .. key .. " = " .. ser(x, pad)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
end

local function save()
    local f = io.open(SAVE_FILE, "w")
    if not f then return X.log("crew: couldn't write " .. SAVE_FILE) end
    f:write("-- Your crew and the recruit pool (hire.lua). Delete this file for a fresh pool and no crew.\nreturn ",
        ser(D, ""), "\n")
    f:close()
end

-- Recruits ---------------------------------------------------------------------------------------------------------
local function weighted(odds)
    local total = 0
    for _, w in ipairs(odds) do total = total + w end
    local r = math.random() * total
    for i, w in ipairs(odds) do
        r = r - w
        if r <= 0 then return i end
    end
    return #odds
end

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- Their kit, rolled once from your player level and their own (H.tier) and kept (they look the same in the lobby and every
-- raid); a promotion re-rolls it, never to a lower grade than they had.
local function giveKit(r)
    local tier = H.tier(r.level, r.kitG)
    r.kit = X.rollKit(tier, math.random() < tier.helmet, math.random() < tier.chest, math.random() < tier.backpack)
    r.kit.helmet = Gear.helmetFor(r.kit.helmet, r.head, true) -- fits over their face, and no boss cap (#195)
    r.kitTier = tier.name
    r.kitG = tier.g
end

local function newRecruit()
    local used = {}
    for _, list in ipairs({ D.pool, D.crew }) do for _, r in ipairs(list) do used[r.name] = true end end
    local female = math.random() < X.femaleShare() -- the launcher's "Women among others" (rivals.lua)
    local free = {}
    for _, list in ipairs({ female and NAMES.female or NAMES.male, NAMES.either }) do
        for _, n in ipairs(list) do if not used[n] then free[#free + 1] = n end end
    end
    local voices = keys(female and Lines.female or Lines.male)
    local level = weighted(CFG.LEVEL_ODDS)
    D.nextId = (D.nextId or 0) + 1
    return {
        id = D.nextId, name = free[math.random(math.max(1, #free))] or ("Hand " .. D.nextId), female = female,
        voice = voices[math.random(#voices)], head = Gear.heads[math.random(#Gear.heads)],
        body = Gear.bodies[math.random(#Gear.bodies)], level = level, raids = 0,
        personality = X.AI.pickPersonality(40 + level * 60 + math.random(0, 80)),
        -- their own aim (ai.lua aimFor: below 0 is better than the profile), for life; also their talent on the ship's
        -- guns (crew.lua gunnery)
        aimRoll = math.random() * 0.8 - 0.4,
    }
end

local function recruit()
    local r = newRecruit()
    giveKit(r)
    return r
end

local function load()
    local ok, t = pcall(dofile, SAVE_FILE)
    D = ok and type(t) == "table" and t or { pool = {}, crew = {}, enabled = true, nextId = 0 }
    D.pool, D.crew = D.pool or {}, D.crew or {}
    if D.enabled == nil then D.enabled = true end
    while #D.pool < CFG.POOL do D.pool[#D.pool + 1] = recruit() end
    local kitted = false
    for _, list in ipairs({ D.pool, D.crew }) do
        for _, r in ipairs(list) do
            if not r.kit then giveKit(r) kitted = true
            elseif not Gear.fits(r.kit.helmet, r.head) or Gear.SIGNATURE[r.kit.helmet] then
                -- hired before helmets were matched to faces, or wearing a boss's cap (#195): the same grade of
                -- helmet, one that fits
                r.kit.helmet = Gear.helmetFor(r.kit.helmet, r.head, true)
                kitted = true
            end
        end
    end
    -- Recruits from before kits followed your level: the ones still looking for work get a kit that does (your crew keep
    -- theirs until a promotion).
    for _, r in ipairs(D.pool) do if not r.kitG and X.rivals_scale() then giveKit(r) kitted = true end end
    if not ok or kitted then save() end
    X.log(("crew: %d hired, %d recruits in the pool (%s)"):format(#D.crew, #D.pool, ok and "loaded" or "new"))
end

-- What a level means in a fight: the rival raider's profile as it is right now (difficulty preset and tuning
-- included, so crew stay ahead on any difficulty), made better by CFG.EDGE: clearly better at level 1, much better at 5.
function H.profile(level)
    local b = X.AI.PROFILES.rival
    local t = (math.max(1, math.min(5, level or 1)) - 1) / 4
    local function edge(k) local e = CFG.EDGE[k] return e[1] + (e[2] - e[1]) * t end
    local p = {}
    for k, v in pairs(b) do p[k] = v end
    for _, k in ipairs({ "miss", "spotTime", "sight", "hearing", "dispersion" }) do
        if type(b[k]) == "number" then p[k] = b[k] * edge(k) end
    end
    p.halfAngle = math.min(120, (b.halfAngle or 80) + edge("halfAngle"))
    local r = edge("reaction")
    p.reaction = { math.max(0.05, b.reaction[1] * r), math.max(0.08, b.reaction[2] * r) }
    p.strafe = math.max(b.strafe or 0.9, 0.95)
    p.typeMod = math.max(b.typeMod or 1, 1)
    return p
end

-- Health by level (CFG.BASE_HP, HP_PER_LEVEL).
function H.maxHp(level)
    return CFG.BASE_HP + (math.max(1, math.min(5, level or 1)) - 1) * CFG.HP_PER_LEVEL
end

-- Their kit tier. Following your level (rivals' SCALE_GEAR): a gear grade rolled like a rival's around your level, plus
-- KIT_BIAS per crew level, and at least `floor` (their old grade, on a promotion). Otherwise by their level alone:
-- budget at 1, mostly mid at 2-3, geared from 4.
function H.tier(level, floor)
    if X.rivals_scale() then
        local g = math.min(1, GearScale.roll((math.max(1, level) - 1) * CFG.KIT_BIAS))
        return GearScale.spec(math.max(g, floor or 0))
    end
    local tiers = X.tiers()
    local i = level >= 4 and 3 or level == 3 and 2 or level == 2 and (math.random() < 0.5 and 2 or 1) or 1
    return tiers[i]
end

function H.voice(r) return (r.female and Lines.female or Lines.male)[r.voice] end

local function nextLevelAt(r) return CFG.PROMOTE[r.level] end

local function find(list, key)
    for i, r in ipairs(list) do
        if r.id == key or (type(key) == "string" and r.name:lower() == key:lower()) then return r, i end
    end
end

-- Money ------------------------------------------------------------------------------------------------------------
-- In the lobby the director ticks on a menu widget (MM_CoreMissions), not the controller: find the controller from it,
-- as main.lua's onTick does.
local function owner(pc)
    if not X.valid(pc) or pc:GetClass():GetFName():ToString():find("PlayerController", 1, true) then return pc end
    local ok, o = pcall(function()
        return X.lib("/Script/Engine.Default__GameplayStatics"):GetPlayerController(pc, 0)
    end)
    if ok and o and X.valid(o) then return o end
    return pc
end

local function cashOf(pc)
    local ok, c = pcall(function() return pc:GetCash() end)
    return ok and tonumber(c) or nil
end

local function spend(pc, amount)
    local cash = cashOf(pc)
    if not cash or cash < amount then return false, cash end
    pc:TakeCash(amount)
    X.log(("crew: paid %d (cash %d -> %s)"):format(amount, cash, tostring(cashOf(pc))))
    return true
end

local function money(n)
    local s, k = tostring(math.floor(n)), 1
    while k > 0 do s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") end
    return s
end

-- Actions (menu buttons and bridge/crew_cmd) -------------------------------------------------------------------------
local inLobby = false

local function hire(pc, key)
    local r, i = find(D.pool, key)
    if not r then return "No such recruit" end
    if #D.crew >= CFG.MAX_CREW then return ("Your crew is full (%d)"):format(CFG.MAX_CREW) end
    local fee = CFG.FEE[r.level]
    local ok, cash = spend(pc, fee)
    if not ok then return ("%s wants %s to sign on; you have %s"):format(r.name, money(fee), cash and money(cash) or "?") end
    table.remove(D.pool, i)
    r.bring = true
    local gunner = false
    for _, m in ipairs(D.crew) do gunner = gunner or m.gunner end
    r.gunner = not gunner
    D.crew[#D.crew + 1] = r
    D.pool[#D.pool + 1] = recruit()
    save()
    return ("%s signed on for %s"):format(r.name, money(fee))
end

local function dismiss(key)
    local r, i = find(D.crew, key)
    if not r then return "No such crewmate" end
    table.remove(D.crew, i)
    if r.gunner and D.crew[1] then D.crew[1].gunner = true end
    -- Gone for good, like a crewmate who dies (#303). They used to go back to the top of the pool, and the pool was cut
    -- back from the bottom: the recruit who'd just appeared (the one you were making room for) was the one pushed out.
    save()
    return r.name .. " left the crew for good"
end

local function bring(key)
    local r = find(D.crew, key)
    if not r then return "No such crewmate" end
    r.bring = not r.bring
    save()
    return r.name .. (r.bring and " comes along" or " stays home")
end

local function gunner(key)
    local r = find(D.crew, key)
    if not r then return "No such crewmate" end
    for _, m in ipairs(D.crew) do m.gunner = (m == r) and not r.gunner end
    save()
    return r.gunner and (r.name .. " works the turrets while you fly") or "Nobody on the turrets"
end

local function toggle()
    D.enabled = not D.enabled
    save()
    return D.enabled and "Your crew comes on raids" or "You raid alone"
end

-- Raids ------------------------------------------------------------------------------------------------------------
-- At launch: everyone coming along is paid; who can't be paid stays home.
local unpaid -- this launch: { names = {...}, owed = total wages, cash = what you had } or nil (crew.lua tells you in the raid)
function H.payWages(pc)
    pc = owner(pc)
    D.raid = {}
    unpaid = nil
    if not D.enabled then return end
    for _, r in ipairs(D.crew) do
        if r.bring then
            local wage = CFG.WAGE[r.level]
            if spend(pc, wage) then
                D.raid[#D.raid + 1] = r.id
                X.log(("crew: %s paid %s for this raid"):format(r.name, money(wage)))
            else
                -- (a message here is never seen: the lobby is about to be replaced by the raid's loading screen)
                unpaid = unpaid or { names = {}, owed = 0, cash = cashOf(pc) }
                unpaid.names[#unpaid.names + 1] = r.name
                unpaid.owed = unpaid.owed + wage
                X.log(("crew: %s stays home, wage %d unpaid"):format(r.name, wage))
            end
        end
    end
    save()
end

-- Who stayed home this raid because you couldn't pay them, as a line for the screen (nil: nobody).
function H.unpaidNote()
    if not unpaid then return nil end
    local n = unpaid.names
    local who = #n == 1 and n[1] or (table.concat(n, ", ", 1, #n - 1) .. " and " .. n[#n])
    return ("%s stayed home: wages of $%s unpaid%s"):format(who, money(unpaid.owed),
        unpaid.cash and (" (you have $" .. money(unpaid.cash) .. ")") or "")
end

-- Who's in this raid (crew.lua): the paid crewmates, gunner flag and all.
function H.raidCrew()
    local out = {}
    for _, id in ipairs(D.raid or {}) do
        local r = find(D.crew, id)
        if r then out[#out + 1] = r end
    end
    return out
end

-- A crewmate killed in a raid: gone for good.
function H.died(id)
    local r, i = find(D.crew, id)
    if not r then return end
    table.remove(D.crew, i)
    if r.gunner and D.crew[1] then D.crew[1].gunner = true end
    D.fallen = D.fallen or {}
    D.fallen[#D.fallen + 1] = { name = r.name, level = r.level, raids = r.raids, date = os.date("%Y-%m-%d") }
    save()
    X.log(("crew: %s (level %d, %d raids) died"):format(r.name, r.level, r.raids))
end

-- Back in the lobby after a raid: the survivors get the raid on their record (and maybe a promotion), and the pool
-- turns over a little.
function H.lobby(pc)
    pc = owner(pc)
    inLobby = true
    if not D.raid then return end
    local news = {}
    for _, id in ipairs(D.raid) do
        local r = find(D.crew, id)
        if r then
            r.raids = r.raids + 1
            local at = nextLevelAt(r)
            if at and r.raids >= at then
                r.level = r.level + 1
                giveKit(r) -- better pay, better gear
                news[#news + 1] = ("%s is now %s (level %d)"):format(r.name, TITLES[r.level], r.level)
            end
        end
    end
    D.raid = nil
    for _ = 1, CFG.TURNOVER do
        if #D.pool > 0 then table.remove(D.pool, math.random(#D.pool)) end
    end
    while #D.pool < CFG.POOL do D.pool[#D.pool + 1] = recruit() end
    save()
    for _, s in ipairs(news) do X.log("crew: " .. s) end
    if #news > 0 then pcall(function() pc:ClientMessage(table.concat(news, "; "), FName("Event"), 8.0) end) end
end

function H.leftLobby() inLobby = false end

-- Menu -------------------------------------------------------------------------------------------------------------
-- A panel on the left of the lobby (the crew stands stay in view on the right): HIRE lists the recruits, each with a
-- portrait (crewlobby.lua's photo booth), and the one you click steps onto a free stand in the hangar; YOUR CREW has
-- each crewmate's card. Fonts are borrowed from the lobby's own crew slots; colours follow the lobby.
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local PX, PY, PW, PH = 36, 96, 680, 800
local RH, CH = 80, 150          -- recruit row / crew card height
local C_PANEL = { R = 0.035, G = 0.04, B = 0.045, A = 0.93 }
local C_ROW, C_SEL = { R = 0.09, G = 0.1, B = 0.11, A = 0.9 }, { R = 0.55, G = 0.27, B = 0.1, A = 0.95 }
local C_ACCENT, C_DIM = { R = 0.95, G = 0.55, B = 0.25, A = 1 }, { R = 0.7, G = 0.72, B = 0.75, A = 1 }
local C_WHITE = { R = 0.93, G = 0.93, B = 0.9, A = 1 }
local C_GREY = { R = 0.3, G = 0.32, B = 0.35, A = 1 }
local ui

local function make(cls) return StaticConstructObject(X.lib("/Script/UMG." .. cls), ui.tree) end
local function color(t, c)
    pcall(function()
        local s = t.ColorAndOpacity.SpecifiedColor
        s.R, s.G, s.B, s.A = c.R, c.G, c.B, c.A
        t.ColorAndOpacity.ColorUseRule = 0
    end)
end
local function text(s, size, c)
    local t = make("TextBlock")
    if ui.font then
        pcall(function()
            t.Font.FontObject = ui.font.FontObject
            t.Font.TypefaceFontName = ui.font.TypefaceFontName
        end)
    end
    t.Font.Size = size
    t:SetText(FText(s))
    color(t, c or C_WHITE)
    return t
end
local function place(widget, x, y, w, h)
    local slot = ui.root:AddChildToCanvas(widget)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
    return slot
end
local function box(c, x, y, w, h)
    local b = make("Border")
    b:SetBrushColor(c)
    place(b, x, y, w, h)
    return b
end
local function tint(b, c) pcall(function() b.b:SetBackgroundColor(c) end) end
local function button(label, x, y, w, h, c)
    local b = { b = make("Button") }
    tint(b, c or C_GREY)
    b.text = text(label, 12)
    b.b:AddChild(b.text)
    place(b.b, x, y, w, h or 28)
    return b
end
local function quiet(w) w:SetVisibility(4) end -- shown, never takes the mouse (clicks reach the row button below)
local function show(w, on) w:SetVisibility(on and 4 or 1) end
local function showB(b, on) b.b:SetVisibility(on and 0 or 1) end

local function pretty(row) return row and (row:gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2")) or nil end
local function accent(r) return (r.voice:gsub("Female%d*$", ""):gsub("Male%d*$", ""):gsub("V%d+$", "")) end
local function kitLine(r)
    local k, parts = r.kit or {}, {}
    if k.gun then parts[#parts + 1] = pretty(k.gun[1]) end
    for _, slot in ipairs({ "helmet", "chest", "bag" }) do -- (not ipairs over the rows: a missing helmet ended the list)
        if k[slot] then parts[#parts + 1] = pretty(k[slot]) end
    end
    return table.concat(parts, "  /  ")
end
local function who(r)
    return ("Lv %d %s   %s   %s, %s voice"):format(r.level, TITLES[r.level], TEMPER[r.personality] or r.personality,
        r.female and "woman" or "man", accent(r))
end

-- A portrait frame: the photo when it's ready, the initial meanwhile.
local function portrait(x, y, size)
    local p = { frame = box({ R = 0.02, G = 0.02, B = 0.025, A = 1 }, x, y, size, size) }
    p.letter = text("", math.floor(size * 0.45), C_DIM)
    place(p.letter, x + size * 0.3, y + size * 0.18, size, size)
    p.img = make("Image")
    place(p.img, x, y, size, size)
    p.img:SetVisibility(1)
    return p
end
local function setPortrait(p, r)
    p.letter:SetText(FText(r and r.name:sub(1, 1) or ""))
    local rt = r and inLobby and X.lobby.portrait(r)
    local addr = rt and rt:GetAddress()
    if addr ~= p.addr then
        p.addr = addr
        if rt then
            p.img:SetBrushResourceObject(rt)
            quiet(p.img)
        else
            p.img:SetVisibility(1)
        end
    end
end

local function build(pc)
    local cls = X.lib(HOST)
    if not X.valid(cls) then
        pcall(LoadAsset, (HOST:match("^[^.]+")))
        cls = X.lib(HOST)
    end
    if not X.valid(cls) then return X.log("crew menu: no host widget") end
    local host = X.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not X.valid(host) then return X.log("crew menu: couldn't create it") end
    ui = { host = host, tree = host.WidgetTree, root = host.WidgetTree.RootWidget, pool = {}, crew = {}, tab = "hire" }
    local ref = inLobby and X.lobby.fontRef()
    ui.font = ref and ref.Font
    ui.root:ClearChildren()
    box(C_PANEL, PX, PY, PW, PH)
    box(C_ACCENT, PX, PY, PW, 3)
    place(text("CREW", 24), PX + 20, PY + 14, 200, 34)
    ui.cash = text(" ", 14, C_ACCENT)
    place(ui.cash, PX + PW - 230, PY + 22, 180, 24)
    ui.close = button("X", PX + PW - 44, PY + 14, 28, 28)
    ui.tabHire = button("HIRE", PX + 20, PY + 58, 140, 30)
    ui.tabCrew = button("YOUR CREW", PX + 168, PY + 58, 170, 30)
    ui.enabled = button("", PX + PW - 260, PY + 58, 240, 30)
    local y = PY + 104
    for i = 1, CFG.POOL do
        local x = PX + 16
        local row = { bg = button("", x, y, PW - 32, RH - 6, C_ROW) }
        row.pic = portrait(x + 6, y + 5, RH - 16)
        row.name = text(" ", 16)
        place(row.name, x + RH + 4, y + 6, 330, 22)
        row.who = text(" ", 11, C_DIM)
        place(row.who, x + RH + 4, y + 30, 340, 18)
        row.kit = text(" ", 11, C_DIM)
        place(row.kit, x + RH + 4, y + 48, 520, 18)
        row.fee = text(" ", 15, C_ACCENT)
        place(row.fee, x + PW - 32 - 232, y + 8, 120, 22)
        row.wage = text(" ", 10, C_DIM)
        place(row.wage, x + PW - 32 - 232, y + 32, 124, 18)
        row.hire = button("HIRE", x + PW - 32 - 100, y + 20, 88, 32, C_ACCENT)
        for _, w in ipairs({ row.name, row.who, row.kit, row.fee, row.wage, row.pic.frame, row.pic.letter }) do quiet(w) end
        ui.pool[i] = row
        y = y + RH
    end
    y = PY + 104
    for i = 1, CFG.MAX_CREW do
        local x = PX + 16
        local card = { bg = button("", x, y, PW - 32, CH - 8, C_ROW) }
        card.pic = portrait(x + 8, y + 8, CH - 24)
        local tx = x + CH
        card.name = text(" ", 18)
        place(card.name, tx, y + 8, 300, 26)
        card.who = text(" ", 11, C_DIM)
        place(card.who, tx, y + 36, 440, 18)
        card.kit = text(" ", 11, C_DIM)
        place(card.kit, tx, y + 54, 440, 18)
        card.rec = text(" ", 11, C_ACCENT)
        place(card.rec, tx, y + 72, 440, 18)
        card.bring = button("", tx, y + CH - 52, 140, 30)
        card.gunner = button("", tx + 148, y + CH - 52, 140, 30)
        card.dismiss = button("DISMISS", tx + 296, y + CH - 52, 120, 30, { R = 0.45, G = 0.16, B = 0.14, A = 1 })
        for _, w in ipairs({ card.name, card.who, card.kit, card.rec, card.pic.frame, card.pic.letter }) do quiet(w) end
        ui.crew[i] = card
        y = y + CH
    end
    ui.empty = text("Nobody hired yet. Recruits are on the HIRE tab.", 14, C_DIM)
    place(ui.empty, PX + 24, PY + 120, 600, 24)
    ui.status = text(" ", 12, C_DIM)
    place(ui.status, PX + 20, PY + PH - 34, PW - 40, 20)
    host:AddToViewport(5000) -- above the lobby's own pages and the PGOS overlay
    return true
end

local function refresh(pc)
    local cash = cashOf(pc)
    ui.cash:SetText(FText(inLobby and ("$ " .. (cash and money(cash) or "?")) or "in a raid"))
    ui.tabCrew.text:SetText(FText(("YOUR CREW  %d/%d"):format(#D.crew, CFG.MAX_CREW)))
    tint(ui.tabHire, ui.tab == "hire" and C_ACCENT or C_GREY)
    tint(ui.tabCrew, ui.tab == "crew" and C_ACCENT or C_GREY)
    ui.enabled.text:SetText(FText(D.enabled and "CREW COMES ON RAIDS: ON" or "CREW COMES ON RAIDS: OFF"))
    ui.enabled.b:SetIsEnabled(inLobby)
    local hiring = ui.tab == "hire"
    for i, row in ipairs(ui.pool) do
        local r = hiring and D.pool[i] or nil
        row.r = r
        showB(row.bg, r ~= nil) showB(row.hire, r ~= nil)
        for _, w in ipairs({ row.name, row.who, row.kit, row.fee, row.wage, row.pic.frame, row.pic.letter }) do show(w, r ~= nil) end
        if not r then row.pic.img:SetVisibility(1) row.pic.addr = nil end
        if r then
            row.name:SetText(FText(r.name))
            row.who:SetText(FText(who(r)))
            row.kit:SetText(FText(kitLine(r)))
            row.fee:SetText(FText("$ " .. money(CFG.FEE[r.level])))
            row.wage:SetText(FText(("then $%s a raid"):format(money(CFG.WAGE[r.level]))))
            row.hire.b:SetIsEnabled(inLobby and #D.crew < CFG.MAX_CREW and (cash or 0) >= CFG.FEE[r.level])
            tint(row.bg, ui.sel == r.id and C_SEL or C_ROW)
            setPortrait(row.pic, r)
        end
    end
    for i, card in ipairs(ui.crew) do
        local r = not hiring and D.crew[i] or nil
        card.r = r
        showB(card.bg, r ~= nil) showB(card.bring, r ~= nil) showB(card.gunner, r ~= nil) showB(card.dismiss, r ~= nil)
        for _, w in ipairs({ card.name, card.who, card.kit, card.rec, card.pic.frame, card.pic.letter }) do show(w, r ~= nil) end
        if not r then card.pic.img:SetVisibility(1) card.pic.addr = nil end
        if r then
            local at = nextLevelAt(r)
            card.name:SetText(FText(r.name))
            card.who:SetText(FText(who(r)))
            card.kit:SetText(FText(kitLine(r)))
            card.rec:SetText(FText(("%d raid%s survived%s   |   wage $%s a raid"):format(r.raids, r.raids == 1 and "" or "s",
                at and (", promotion at " .. at) or ", top rank", money(CFG.WAGE[r.level]))))
            card.bring.text:SetText(FText(r.bring and "COMES ALONG" or "STAYS HOME"))
            card.gunner.text:SetText(FText(r.gunner and "ON THE GUNS" or "MAKE GUNNER"))
            card.dismiss.text:SetText(FText(card.confirm and "SURE?" or "DISMISS"))
            tint(card.bring, r.bring and { R = 0.25, G = 0.45, B = 0.3, A = 1 } or C_GREY)
            tint(card.gunner, r.gunner and C_ACCENT or C_GREY)
            tint(card.bg, ui.selCrew == r.id and C_SEL or C_ROW)
            for _, b in ipairs({ card.bring, card.gunner, card.dismiss }) do b.b:SetIsEnabled(inLobby) end
            setPortrait(card.pic, r)
        end
    end
    show(ui.empty, not hiring and #D.crew == 0)
end

function H.isOpen() return ui ~= nil and ui.open == true end

local tickPc -- the controller the director's tick runs on (H.lastPc)

-- A new world: the menu's widgets and the lobby's stands went with the old one; H.tick runs every frame, before the
-- director's update has noticed (see main.lua onTick).
function H.reset()
    ui, inLobby = nil, false
    -- (and the old world's controller: quit.lua and invkeys.lua ask H.lastPc() before this frame's H.tick, and checking a
    -- freed controller reads freed memory)
    tickPc = nil
    if X and X.lobby and X.lobby.reset then X.lobby.reset() end
end

function H.close(pc)
    pc = owner(pc)
    if not H.isOpen() then return end
    ui.open, ui.sel = false, nil
    ui.host:SetVisibility(1)
    local wbl = X.lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    if inLobby then
        -- the lobby is a mouse screen: give the game its UI back
        pcall(function() wbl:SetInputMode_GameAndUIEx(pc, nil, 0, false) end)
    else
        pc.bShowMouseCursor = false
        wbl:SetInputMode_GameOnly(pc)
    end
end

local function open(pc, tab, crewmate)
    if ui and not X.valid(ui.host) then ui = nil end -- the world it was built in is gone
    if not ui and not build(pc) then return end
    ui.open, ui.pc, ui.tab = true, pc, tab
    ui.selCrew = crewmate and crewmate.id or nil
    ui.sel = nil
    -- the PGOS "social service unavailable" overlay draws over every viewport widget in the lobby: hide it (as main.lua's
    -- sweep does; one object scan, only when the menu opens)
    for _, w in ipairs(FindAllOf("PgosOverlay_BP_C") or {}) do
        if X.valid(w) and w:GetVisibility() ~= 1 then w:SetVisibility(1) end
    end
    refresh(pc)
    ui.host:SetVisibility(0)
    pc.bShowMouseCursor = true
    X.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, ui.host, 0)
end

function H.toggle(pc)
    pc = owner(pc)
    if H.isOpen() then return H.close(pc) end
    open(pc, #D.crew > 0 and "crew" or "hire")
end

local function pressed(b)
    local down = b.b:IsPressed()
    local click = b.down and not down
    b.down = down
    return click
end

local function did(pc, said)
    X.log("crew menu: " .. tostring(said))
    if ui and X.valid(ui.host) then
        ui.status:SetText(FText(said))
        refresh(pc)
    end
end

-- Testing without the mouse: bridge/crew_cmd lines like "hire 2" (pool row), "hire Juno", "dismiss Juno",
-- "bring Juno", "gunner Juno", "toggle", "menu", "open hire", "open crew", "pick 3" (preview pool row 3), "list".
local function command(pc, line)
    local verb, arg = line:match("^(%S+)%s*(.-)%s*$")
    if verb == "menu" then return H.toggle(pc) end
    if verb == "open" then return open(pc, arg == "crew" and "crew" or "hire") end
    if verb == "pick" then
        local r = D.pool[tonumber(arg) or 0]
        if ui and r then ui.sel = r.id refresh(pc) end
        return
    end
    if verb == "list" then
        for _, r in ipairs(D.crew) do X.log(("crew: hired %s, %s | %s"):format(r.name, who(r), kitLine(r))) end
        for _, r in ipairs(D.pool) do X.log(("crew: pool %s, %s | %s"):format(r.name, who(r), kitLine(r))) end
        return
    end
    if not inLobby then return did(pc, "Crew changes happen in the lobby") end
    local n = tonumber(arg)
    local key = n and D.pool[n] and D.pool[n].id or arg
    if verb == "hire" then return did(pc, hire(pc, key)) end
    if n and D.crew[n] then key = D.crew[n].id end
    if verb == "dismiss" then return did(pc, dismiss(key)) end
    if verb == "bring" then return did(pc, bring(key)) end
    if verb == "gunner" then return did(pc, gunner(key)) end
    if verb == "toggle" then return did(pc, toggle()) end
    X.log("crew menu: unknown command " .. line)
end

local nextCmd, nextPics = 0, 0
function H.lastPc() return tickPc end -- the controller the director's tick runs on (lobby or raid)

local function preview()
    if not (H.isOpen() and ui.tab == "hire" and ui.sel) then return nil end
    return (find(D.pool, ui.sel))
end

function H.tick(pc)
    pc = owner(pc)
    tickPc = pc
    local now = os.clock()
    if now >= nextCmd then
        nextCmd = now + 0.5
        local f = io.open(CMD_FILE, "r")
        if f then
            local lines = {}
            for l in f:lines() do if l:match("%S") then lines[#lines + 1] = l end end
            f:close()
            os.remove(CMD_FILE)
            for _, l in ipairs(lines) do
                local ok, err = pcall(command, pc, l)
                if not ok then X.log("crew command failed: " .. tostring(err)) end
            end
        end
    end
    -- the hangar: crew on their stands, the picked recruit on a free one, the crew slots; a slot click opens the menu
    if inLobby then
        local ok, click = pcall(X.lobby.tick, pc, D.crew, preview())
        if not ok then X.log("crew lobby failed: " .. tostring(click))
        elseif click and not H.isOpen() then
            if click.crewmate then open(pc, "crew", click.crewmate) else open(pc, "hire") end
        end
    end
    if not H.isOpen() then return end
    if not X.valid(ui.host) then ui = nil return end
    if now >= nextPics then -- portraits arrive from the photo booth one by one
        nextPics = now + 0.3
        refresh(pc)
    end
    if pressed(ui.close) then return H.close(pc) end
    if pressed(ui.tabHire) then ui.tab = "hire" refresh(pc) return end
    if pressed(ui.tabCrew) then ui.tab, ui.sel = "crew", nil refresh(pc) return end
    if inLobby and pressed(ui.enabled) then return did(pc, toggle()) end
    for _, row in ipairs(ui.pool) do
        if row.r then
            if inLobby and pressed(row.hire) then
                ui.sel = nil
                return did(pc, hire(pc, row.r.id))
            end
            if pressed(row.bg) then
                ui.sel = (ui.sel ~= row.r.id) and row.r.id or nil
                return refresh(pc)
            end
        end
    end
    for _, card in ipairs(ui.crew) do
        if card.r and inLobby then
            if pressed(card.bring) then return did(pc, bring(card.r.id)) end
            if pressed(card.gunner) then return did(pc, gunner(card.r.id)) end
            if pressed(card.dismiss) then
                if card.confirm and now - card.confirm < 4 then
                    card.confirm = nil
                    return did(pc, dismiss(card.r.id))
                end
                card.confirm = now
                return did(pc, "Click again to dismiss " .. card.r.name)
            end
            if card.confirm and now - card.confirm >= 4 then card.confirm = nil refresh(pc) end
            if pressed(card.bg) then ui.selCrew = card.r.id refresh(pc) end
        end
    end
end

function H.init(ctx)
    X = ctx
    load()
end

return H
