-- How you died (#331, first pass). The offline game has no kill cam or killer card: you drop and the menu loads. This
-- keeps the last few hits you took and, when you die, puts up a small panel for SHOW_SECONDS (or until the world
-- changes): who killed you (a rival's name and crew, else the soldier's kind), with what gun, from how far, the last
-- hits before that, and roughly how much damage you'd done to your killer. One "death: ..." line goes to the log too.
--
-- Where hits come from: nothing in the mod sees the damage event itself (botdamage.lua/hitzones.lua handle YOUR shots at
-- bots). So: main.lua's ServerMultiSimulateWeaponFire hook (once per bot shot) calls M.botShot, and M.frame watches your
-- pawn's Health each frame. A drop in Health is put down to the bot that fired most recently (within SHOT_WINDOW);
-- with none, it's an unknown/environmental hit (a fall, a mine, fire). The hit zone isn't known this way.
-- NOT tested in game (2026-11-21).
local M = {}
local X -- log, valid, lib
local raid = {}

local CFG = {
    SHOW_SECONDS = 10,
    KEEP = 6,            -- hits remembered
    SHOT_WINDOW = 0.6,   -- s between a bot's shot and your Health dropping for that shot to count as the hit
    SHOTS_KEPT = 12,
}
M.CFG = CFG
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local INK = { R = 0.02, G = 0.022, B = 0.028, A = 0.9 }
local ACCENT = { R = 0.95, G = 0.5, B = 0.12, A = 1 }
local TEXT_LIGHT = { R = 0.92, G = 0.92, B = 0.9, A = 1 }
local TEXT_MUTED = { R = 0.6, G = 0.62, B = 0.65, A = 1 }

local shots = {}   -- recent bot shots: { addr, bot, gun, at }
local hits = {}    -- recent hits on you: { who, side, gun, dist, dmg, at, addr }
local seenHp = {}  -- bot address -> highest Health seen while it was shooting (for "damage you dealt")
local pawnAddr, lastHp, dead, lastPawn
local panel        -- { host, untilAt }

local valid, lib -- main.lua's helpers, from ctx (init)
function M.init(ctx) X = ctx valid, lib = ctx.valid, ctx.lib end
function M.setRaid(r) raid = r or {} end

-- New world: forget everything. The old panel's widgets belonged to the old world: dropped, never touched again.
function M.reset()
    shots, hits, seenHp, pawnAddr, lastHp, dead, panel, lastPawn = {}, {}, {}, nil, nil, nil, nil, nil
end


-- As rivalbodies.lua names a gun: "BP_AK47_Child_C" -> "AK47".
local function gunName(gun)
    if not valid(gun) then return "?" end
    local ok, n = pcall(function()
        return (gun:GetClass():GetFName():ToString():gsub("_Child_C$", ""):gsub("_C$", ""):gsub("^%a+_", ""))
    end)
    return ok and n or "?"
end

-- Who a bot is: a rival's name and crew, else the soldier's kind (its class, cleaned).
local function whoIs(bot, addr)
    for _, e in ipairs(raid.bots or {}) do
        if e.bot == bot or (valid(e.bot) and e.bot:GetAddress() == addr) then
            if e.rival and e.rival.name then
                return e.rival.name, e.rival.crew and ("crew " .. e.rival.crew) or "rival"
            end
            if e.faction == "player" or e.crewmate then return "your crew", "friendly" end
            break
        end
    end
    local ok, n = pcall(function() return bot:GetClass():GetFName():ToString() end)
    n = ok and n:gsub("_C$", ""):gsub("^BP_", ""):gsub("^AI", "") or "soldier"
    return n, "station"
end

-- From main.lua's gunfire hook, once per bot shot (the hook has checked the owner is a valid bot).
function M.botShot(w, owner)
    local addr = owner:GetAddress()
    local hp = owner.Health or 0
    if hp > (seenHp[addr] or 0) then seenHp[addr] = hp end
    table.insert(shots, 1, { addr = addr, bot = owner, gun = gunName(w), at = os.clock() })
    shots[CFG.SHOTS_KEPT + 1] = nil
end

local function onFoot(pc)
    local p = valid(pc) and pc.Pawn
    if not (p and valid(p)) then return nil end
    local ok, n = pcall(function() return p:GetClass():GetFName():ToString() end)
    return ok and n == "PlayerPawn_C" and p or nil
end

local function hit(pawn, dmg, now)
    local h = { dmg = dmg, at = now }
    for _, s in ipairs(shots) do
        if now - s.at > CFG.SHOT_WINDOW then break end
        if valid(s.bot) then
            h.who, h.side = whoIs(s.bot, s.addr)
            h.gun, h.addr, h.bot = s.gun, s.addr, s.bot
            pcall(function()
                local a, b = s.bot:K2_GetActorLocation(), pawn:K2_GetActorLocation()
                h.dist = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) / 100
            end)
            break
        end
    end
    table.insert(hits, 1, h)
    hits[CFG.KEEP + 1] = nil
end

local function describe(h)
    if not h.who then return ("%.0f damage, unknown cause (fall, blast, fire?)"):format(h.dmg) end
    return ("%.0f from %s (%s), %s%s"):format(h.dmg, h.who, h.side, h.gun,
        h.dist and (", %.0f m"):format(h.dist) or "")
end

local function headline(h)
    if not h then return "You died" end
    if not h.who then return "You died: unknown cause (a fall, a blast or fire?)" end
    return ("Killed by %s (%s) with %s%s"):format(h.who, h.side, h.gun, h.dist and (", %.0f m"):format(h.dist) or "")
end

-- Damage you'd done to your killer: the most Health it was seen with while shooting, minus what it has now. Rough
-- (others' damage counts too); nil when it can't be told.
local function dealt(h)
    if not (h and h.addr and seenHp[h.addr]) then return nil end
    local now = 0
    if valid(h.bot) then now = math.max(h.bot.Health or 0, 0) end
    local d = seenHp[h.addr] - now
    return d > 0 and d or nil
end

-- UMG, built like defuse.lua's board: colours written into the TextBlocks before AddToViewport.
local function make(tree, cls) return StaticConstructObject(lib("/Script/UMG." .. cls), tree) end
local function tint(t, col)
    pcall(function()
        local c = t.ColorAndOpacity
        c.SpecifiedColor.R, c.SpecifiedColor.G, c.SpecifiedColor.B, c.SpecifiedColor.A = col.R, col.G, col.B, col.A
        c.ColorUseRule = 0
    end)
end

local function show(pc, lines)
    local cls = lib(HOST)
    if not valid(cls) then pcall(LoadAsset, (HOST:match("^[^.]+"))) cls = lib(HOST) end
    if not valid(cls) then return end
    local h = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not valid(h) then return end
    local tree = h.WidgetTree
    local root = tree.RootWidget
    root:ClearChildren()
    local W, ROW = 640, 26
    local vw = 1600
    pcall(function()
        local wll = lib("/Script/UMG.Default__WidgetLayoutLibrary")
        local vp, sc = wll:GetViewportSize(pc), wll:GetViewportScale(pc)
        if sc and sc > 0 then vw = vp.X / sc end
    end)
    local x0, y0 = math.floor((vw - W) / 2), 120
    local bg = make(tree, "Border")
    pcall(function() bg:SetBrushColor(INK) end)
    local s = root:AddChildToCanvas(bg)
    s:SetPosition({ X = x0, Y = y0 }) s:SetSize({ X = W, Y = 24 + ROW * #lines })
    for i, l in ipairs(lines) do
        local t = make(tree, "TextBlock")
        t.Font.Size = l.size or 13
        t:SetText(FText(l.text))
        tint(t, l.col or TEXT_LIGHT)
        local ts = root:AddChildToCanvas(t)
        ts:SetPosition({ X = x0 + 16, Y = y0 + 12 + ROW * (i - 1) }) ts:SetSize({ X = W - 32, Y = ROW })
    end
    h:AddToViewport(5010)
    panel = { host = h, untilAt = os.clock() + CFG.SHOW_SECONDS }
end

local function died(pc)
    local k = hits[1]
    -- the killing blow may be an unknown tick after a bot's hits: name the last bot that hit you within 3 s
    if k and not k.who then
        for _, h in ipairs(hits) do
            if h.who and k.at - h.at < 3 then k = h break end
        end
    end
    local top = headline(k)
    local d = dealt(k)
    local lines = { { text = top, size = 18, col = ACCENT } }
    local recent = {}
    for i = 1, math.min(3, #hits) do
        recent[#recent + 1] = describe(hits[i])
        lines[#lines + 1] = { text = ("-%d  %s"):format(i, recent[#recent]), col = TEXT_MUTED }
    end
    if d then lines[#lines + 1] = { text = ("You did ~%.0f damage to %s"):format(d, k.who) } end
    X.log("death: " .. top .. "; last hits: " .. (#recent > 0 and table.concat(recent, " | ") or "none")
        .. (d and ("; dealt ~%.0f to killer"):format(d) or ""))
    local ok, err = pcall(show, pc, lines)
    if not ok then X.log("death screen failed: " .. tostring(err)) end
end

-- Every frame from the director's tick, with this raid's player controller.
function M.frame(pc)
    if require("features").DEATH_SCREEN ~= 1 then return end
    local now = os.clock()
    if panel and now > panel.untilAt then
        local h = panel.host
        panel = nil
        if valid(h) then pcall(function() h:RemoveFromParent() end) end
    end
    -- On death the controller may let go of the pawn before a frame sees its Health at 0: keep reading the last one.
    local pawn = onFoot(pc) or (lastPawn and valid(lastPawn) and lastPawn) or nil
    if not pawn then return end
    lastPawn = pawn
    local addr = pawn:GetAddress()
    local hp = pawn.Health or 0
    if addr ~= pawnAddr then pawnAddr, lastHp, dead, hits = addr, hp, hp <= 0, {} return end
    if lastHp and hp < lastHp - 0.5 then hit(pawn, lastHp - math.max(hp, 0), now) end
    lastHp = hp
    if hp <= 0 and not dead then
        dead = true
        died(pc)
    elseif hp > 0 then
        dead = false
    end
end

return M
