-- Into a raid (moved out of main.lua): offline matchmaking from the lobby's buttons, the map travel, and the black
-- loading veil over a space map until you're aboard your ship.
local PROJECT = require("pveproject")
local Loading = require("loading")
local PveMapPick = require("mappick") -- the REGION box's map pick
local Conditions = require("conditions") -- a raid condition's fixed map (#78)
local Hire = require("hire") -- your crew's wages
local M = {}

local CFG, log, valid, lib, RAID_OPTS, Rivals -- from main.lua (M.init)
local raid -- main.lua's per-raid table, handed over again on every reset (M.setRaid)

function M.setRaid(r) raid = r end

local launching -- a raid about to load: { pc, at, cmd } (launchMatch)
local mm -- { at = os.clock() time to launch, map = map name } while an offline search runs
local launchShip -- the active ship's table row, from launchMatch to the moment it's aboard

-- Matchmaking ---------------------------------------------------------------------------------------
-- The lobby's launch button (SIGIS_MenuMain.LaunchGameSolo) starts matchmaking with
-- SIGISGameInstanceGraphQL::AwsWs_StartMatchMaking over the game's own AWS websocket; a live match then connects
-- to a dedicated server running a Space_* map, whose game mode spawns each player inside their ship. Offline that
-- socket never connects (pvenet blocks the lookup), so the lobby would search forever: instead, after
-- MM_SEARCH_SECONDS, load a space map ourselves, unless the search was cancelled meanwhile.

local function offlineBackend()
    local f = io.open(CFG.OFFLINE_BACKEND_FLAG, "r")
    if f then f:close() return true end
    return false
end

local MAP_PIN = PROJECT .. "bridge/map_pin"

local function onStartMatchmaking(kind)
    return function(_, _, config)
        if not offlineBackend() then return end
        local name = ""
        if config then pcall(function() name = config:get():ToString() end) end
        local l = name:lower()
        -- The lobby always asks with an empty configuration offline (you're a crew of one), which would mean solo maps
        -- every time: pick from every map in CFG.MAP_POOL instead. bridge/map_pin (a map name) forces one, for tests.
        local pool = l:find("raider") and CFG.SPACE_MAPS.raider
            or (kind ~= "solo" and (l:find("crew") or l:find("squad") or l:find("team"))) and CFG.SPACE_MAPS.crew
            or CFG.MAP_POOL
        local map = pool[math.random(#pool)]
        local favoured = Conditions and Conditions.maps() -- a raid condition's favoured maps (#398)
        if favoured then map = favoured[math.random(#favoured)] end
        if PveMapPick and PveMapPick.map() then map = PveMapPick.map() end -- picked in the REGION box (mappick.lua)
        if Conditions and Conditions.map() then map = Conditions.map() end -- a raid condition's fixed map (#78)
        local pin = io.open(MAP_PIN, "r")
        if pin then map = pin:read("l") or map pin:close() end
        mm = { at = os.clock() + CFG.MM_SEARCH_SECONDS, map = map, kind = kind }
        log(("matchmaking started (%s, configuration \"%s\"): offline match on %s in %ds")
            :format(kind, name, mm.map, CFG.MM_SEARCH_SECONDS))
    end
end
function M.init(ctx)
    CFG, log, valid, lib, RAID_OPTS, Rivals = ctx.CFG, ctx.log, ctx.valid, ctx.lib, ctx.RAID_OPTS, ctx.rivals
    for fn, kind in pairs({
        ["/Script/SIGISPlugin.SIGISGameInstanceGraphQL:AwsWs_StartMatchMaking"] = "lobby",
        ["/Script/SIGISPlugin.SIGISGameInstanceGraphQL:AwsWs_StartSoloMatchMaking"] = "solo",
    }) do
        if not pcall(RegisterHook, fn, onStartMatchmaking(kind)) then log("couldn't hook " .. fn) end
    end
end


-- The lobby's Start Matchmaking is the crew captain's launch button (you captain a crew of one), which sits on
-- top of the solo button and matchmakes through PGOS crews instead (dead offline). Its press starts an offline
-- search too; pressing it again during the search cancels it. A widget Blueprint is only loaded with the menu, so
-- the hook goes in from update() once the function exists (again if it was reloaded).
local CAPTAIN_PRESS = "/SIGISPlugin/Widgets/MainMenu/Crews/Crew_LaunchToMatchBtn_SubWidget.Crew_LaunchToMatchBtn_SubWidget_C:"
    .. "BndEvt__Btn_Main_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature"
local captainHooked -- address of the hooked UFunction
local function hookCaptainButton()
    local fn = StaticFindObject(CAPTAIN_PRESS)
    if not valid(fn) or fn:GetAddress() == captainHooked then return end
    local ok = pcall(RegisterHook, CAPTAIN_PRESS, function()
        if not offlineBackend() then return end
        if mm then mm = nil log("matchmaking cancelled") return end
        onStartMatchmaking("crew captain")()
    end)
    if ok then captainHooked = fn:GetAddress() else log("couldn't hook the captain's launch button") end
end

-- Co-op, direct host and join (#201) ---------------------------------------------------------------------------------
-- The launcher's CO-OP box writes these. coop_host.txt "on": your raids open as a listen server (?listen), so friends
-- can join on UDP 7777. coop_join.txt "<host[:port]>": once, at the main menu, connect to that host's raid; the file
-- is deleted as it's read, so a failed join (or coming home from the raid) doesn't try again.
local COOP_HOST = PROJECT .. "config/coop_host.txt"
local COOP_JOIN = PROJECT .. "config/coop_join.txt"
local JOIN_AFTER = 4 -- seconds at the menu first: the stand-in login and the menu's own setup
local JOIN_GIVE_UP = 20 -- seconds a join may take to connect before it's cancelled (the engine's own wait is ~3 min, #532)
local joinSeenAt -- os.clock() the menu was first seen with a join pending
local joining -- { at = os.clock(), addr } while a join is connecting

local function firstLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("l")
    f:close()
    return line and line:match("^%s*(.-)%s*$") or nil
end

local function hosting() return firstLine(COOP_HOST) == "on" end

-- The host's GameMode reads PNAME through FBase64::Decode and refuses a join whose PNAME doesn't decode ("PlayerNick
-- is null", NOTES.md "Co-op join works", #26).
local function base64(s)
    local abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        for k = 0, 3 do
            local v = (n >> (18 - 6 * k)) & 63
            out[#out + 1] = (k <= 1 or (k == 2 and b) or (k == 3 and c)) and abc:sub(v + 1, v + 1) or "="
        end
    end
    return table.concat(out)
end

-- Your name as your stand-in knows it (guild.lua reads it the same way).
local function myName()
    local f = io.open(require("pvebackend") .. "state.json", "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text:match('"display_name"%s*:%s*"([^"\\]*)"')
end

-- From M.update at the main menu: the pending join, once it's due.
local function joinPending(pc)
    local w = pc:GetWorld()
    if not (valid(w) and w:GetFullName():find("/Maps/MainMenu", 1, true)) then joinSeenAt, joining = nil, nil return end
    -- A join to a host that doesn't answer (not hosting, wrong address, a firewall) left the menu empty for ~3 minutes
    -- while the engine waited (#532). Still at the menu JOIN_GIVE_UP s later: cancel the pending connection.
    if joining then
        if os.clock() - joining.at >= JOIN_GIVE_UP then
            log(("co-op: %s didn't answer in %d s; join cancelled (is the host in a raid with Host on?)")
                :format(joining.addr, JOIN_GIVE_UP))
            joining = nil
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, "cancel", pc)
        end
        return
    end
    local addr = firstLine(COOP_JOIN)
    if not addr or addr == "" then joinSeenAt = nil return end
    joinSeenAt = joinSeenAt or os.clock()
    if os.clock() - joinSeenAt < JOIN_AFTER then return end
    joinSeenAt = nil
    os.remove(COOP_JOIN)
    if not addr:find(":", 1, true) then addr = addr .. ":7777" end
    local nick = myName() or "Marauder"
    -- PID and the other ids: anything but the host's own (offline1); a fresh one per join. CREW is the host's crew
    -- (every install's RAID_OPTS has the same one) and CPT=0, not its captain: the host's game then puts the joiner
    -- aboard the host's ship, not in a ship of their own (#214; tested: spawned 8 m from the host, one interior).
    local id = ("%08x"):format(math.random(0, 0x7fffffff))
    local crew = RAID_OPTS:match("CREW=([^?]+)") or "solo1"
    local cmd = "open " .. addr .. "?PID=offline-" .. id .. "?PNAME=" .. base64(nick) .. "?CREW=" .. crew
        .. "?CPT=0?NUM=1?EOS=offline-" .. id .. "?UPN=offline-" .. id
    log(("co-op: joining %s as %s"):format(addr, nick))
    joining = { at = os.clock(), addr = addr }
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, cmd, pc)
end

local function launchMatch(pc)
    local m = mm
    mm = nil
    local menu = FindFirstOf("SIGIS_MenuMain_C")
    if m.kind ~= "crew captain" and valid(menu)
        and not (menu.isSearching4Match_Singleplayer or menu.isSearching4Match) then
        log("matchmaking was cancelled")
        return
    end
    log("match found: " .. m.map)
    -- Map travel stops the game thread with the last frame up, so the loading screen goes up first and travel waits for
    -- it to draw; the raid shows its own once it can (veilUntilAboard). Any failure here just means the menu stays up.
    local ok, err = pcall(Loading.show, pc)
    if ok then ok, err = pcall(Loading.arm, pc) end
    if not ok then log("loading screen failed: " .. tostring(err)) end
    -- The active ship is the equipped item with a *_Ship row: the stand-in takes it out of the file once the raid starts.
    local f = io.open(CFG.LOADOUT_FILE, "r")
    launchShip = f and f:read("a"):match('"value":"[^"]-%-([%w_]+_Ship)%-') or nil
    if f then f:close() end
    -- your crew's wages for this raid (hire.lua): who isn't paid stays home
    local okw, errw = pcall(Hire.payWages, pc)
    if not okw then log("crew wages: " .. tostring(errw)) end
    local listen = hosting() and "?listen" or "" -- co-op host (#201): friends can join this raid
    if listen ~= "" then log("co-op: hosting this raid (listen server, UDP 7777)") end
    launching = { pc = pc, at = os.clock() + 0.3,
        cmd = "open /Game/Maps/" .. m.map .. listen .. RAID_OPTS .. Rivals.shipOption(launchShip) }
end

-- Space start: black screen until aboard (see CFG.REVEAL_DELAY).
local BLACK = { R = 0, G = 0, B = 0, A = 1 }
local function streamingDone(world)
    local done = true
    world.StreamingLevels:ForEach(function(_, e)
        local l = e:get()
        if valid(l) and l:ShouldBeLoaded() and not (l:IsLevelLoaded() and l:IsLevelVisible()) then done = false end
    end)
    return done
end

-- Most of the wait for a space map was idle: the map is read in ~20 s, then the player and ship only spawn 45 game
-- seconds into the match, on a native timer (not found; a live server gave players time to connect). Running the game
-- faster behind the black screen gets through those same seconds of simulation in a fraction of the time: the raid
-- clock and the world end up where they would have, rivals haven't started yet, and the map stops loading in 15 s, not 55.
-- The loading screen's stage and progress, from the same things the veil waits for. The match clock measures the long
-- part: the player spawns SPAWN_GAME_SECONDS after the match starts.
local SPAWN_GAME_SECONDS = 45
local function loadProgress(pc, world, gm)
    local levels, loaded = 0, 0
    world.StreamingLevels:ForEach(function(_, e)
        local l = e:get()
        if valid(l) and l:ShouldBeLoaded() then
            levels = levels + 1
            if l:IsLevelLoaded() and l:IsLevelVisible() then loaded = loaded + 1 end
        end
    end)
    if levels > 0 and loaded < levels then return "world", 0.05 + 0.35 * loaded / levels end
    local gs = world.GameState
    if not (valid(gm) and valid(gs) and gm.MatchState:ToString() == "InProgress") then return "match", 0.42 end
    return "ship", 0.45 + 0.5 * math.min(1, (gm.RoundTime - gs.RemainingTime) / SPAWN_GAME_SECONDS)
end

local function setLoadSpeed(pc, rate)
    lib("/Script/Engine.Default__GameplayStatics"):SetGlobalTimeDilation(pc, rate)
end

local function veilUntilAboard(pc, world)
    local now, cam = os.clock(), pc.PlayerCameraManager
    -- A co-op joiner (#214) has no game mode (only the host's game does): the host's clock runs the match, so the
    -- load isn't sped up here, and it's ready as soon as its pawn is in and the level has streamed. Waiting for a game
    -- mode left a joiner under the loading screen for the whole VEIL_MAX.
    local gm = world.AuthorityGameMode
    local joiner = not valid(gm)
    if not raid.veiledAt then
        raid.veiledAt = now
        if not joiner then setLoadSpeed(pc, CFG.LOAD_TIME_DILATION) end
        local ok, err = pcall(Loading.show, pc)
        if not ok then log("loading screen failed: " .. tostring(err)) end
    end
    local ok, stage, frac = pcall(loadProgress, pc, world, gm)
    if ok then pcall(Loading.stage, stage, frac) end
    if not raid.readyAt and valid(pc.Pawn) and (joiner or #gm.ShipsInMap > 0) and streamingDone(world) then
        raid.readyAt = now
        if not joiner then setLoadSpeed(pc, 1) end
        if launchShip then -- still under the loading screen: see Rivals.ownHull
            for _, i in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
                if valid(i) and not i.IsAnAIShip then
                    local fitted, err = pcall(Rivals.ownHull, pc, i, launchShip)
                    if not fitted then log("your ship: " .. tostring(err)) end
                end
            end
            launchShip = nil
        end
        pcall(Loading.stage, "ready", 1)
    end
    -- Also wait for the rival crews' first update (space.lua): it loads every look not loaded in the lobby yet and
    -- surveys the stations, a 0.3-6 s freeze that came just after the world was shown (players' logs, build 40, #336).
    -- A joiner runs no rivals of its own.
    local crewsUp = joiner or raid.rivalsUp
    if (raid.readyAt and crewsUp and now - raid.readyAt >= CFG.REVEAL_DELAY) or now - raid.veiledAt >= CFG.VEIL_MAX then
        raid.revealed = true
        if not joiner then setLoadSpeed(pc, 1) end
        pcall(Loading.finish)
        if valid(cam) then cam:StartCameraFade(1, 0, 1.0, BLACK, false, false) end
        log(("aboard after %.0fs%s"):format(now - raid.veiledAt, raid.readyAt and "" or " (gave up waiting)"))
    elseif valid(cam) then
        cam:SetManualCameraFade(1.0, BLACK, false)
    end
end

-- A raid about to load or a search under way (main.lua's onTick holds back the menu's voice line loads meanwhile).
function M.busy() return launching ~= nil or mm ~= nil end

-- From main.lua's onTick, every frame: travels to the raid launchMatch set up once it's due. True when it did (the
-- tick stops there).
function M.fire()
    if launching and os.clock() >= launching.at then
        local l = launching
        launching = nil
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(l.pc, l.cmd, l.pc)
        Loading.reset() -- it stays on screen, but it goes with this world: nothing may touch it from here on
        return true
    end
    return false
end

-- From main.lua's update: the offline search is over.
function M.update(pc)
    if mm and os.clock() >= mm.at then launchMatch(pc) end
    if not mm and not launching then
        local ok, err = pcall(joinPending, pc)
        if not ok then log("co-op join: " .. tostring(err)) end
    end
end

M.offlineBackend, M.hookCaptainButton, M.veilUntilAboard = offlineBackend, hookCaptainButton, veilUntilAboard

return M
