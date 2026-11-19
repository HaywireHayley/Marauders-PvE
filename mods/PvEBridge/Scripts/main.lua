-- PvEBridge: lets tools outside the game drive it while we reverse-engineer.
-- Write a command into bridge/cmd.txt; the reply is appended to bridge/out.txt.
--   status            world, game mode, player pawn
--   dump | sdk | usmap | actors    UE4SS dumpers
--   find <Class>      list live objects of a class
--   join [host[:port]] [name] [n]   co-op: join a listen host (PNAME sent Base64, as the host requires)
--   anything else     run as an Unreal console command
-- Per-instance bridge dir so two game copies (co-op host + client) don't share cmd/out files.
-- Set PVE_BRIDGE=<dir>/ in the launching environment; defaults to the single-instance bridge.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local BRIDGE = os.getenv("PVE_BRIDGE") or PROJECT .. "bridge/"
if not BRIDGE:match("[/\\]$") then BRIDGE = BRIDGE .. "/" end
local CMD, OUT = BRIDGE .. "cmd.txt", BRIDGE .. "out.txt"

-- Backend: native/pvenet.dll logs the game's WinHTTP traffic to capture/winhttp-*.jsonl while bridge/capture_on
-- exists, and sends Nakama to the local stand-in (backend/nakama_standin.py) while bridge/offline_backend exists.
-- Loaded here, at mod start, so the menu's login is covered too.
do
    local function exists(name)
        local f = io.open(BRIDGE .. name, "r")
        if f then f:close() end
        return f ~= nil
    end
    if exists("capture_on") or exists("offline_backend") then
        local ok, err = package.loadlib(PROJECT .. "native/pvenet.dll", "*")
        print("[PvEBridge] pvenet " .. (ok and "loaded" or ("failed: " .. tostring(err))) .. "\n")
    end
end

local function reply(msg)
    local f = io.open(OUT, "a")
    if f then
        f:write(os.date("%H:%M:%S "), tostring(msg), "\n")
        f:close()
    end
    print("[PvEBridge] " .. tostring(msg) .. "\n")
end

local function name(o)
    if o and o:IsValid() then return o:GetFullName() end
    return "none"
end

local function status()
    local pc = FindFirstOf("PlayerController")
    local gm = FindFirstOf("GameModeBase")
    local gs = FindFirstOf("GameStateBase")
    local world = pc and pc:IsValid() and pc:GetWorld() or nil
    reply("world=" .. name(world) .. " | gamemode=" .. name(gm) .. " | gamestate=" .. name(gs))
    reply("pc=" .. name(pc) .. " | pawn=" .. ((pc and pc:IsValid()) and name(pc.Pawn) or "none"))
end

-- The host's GameMode reads the joiner's PNAME through FBase64::Decode and refuses the join with NMT_Failure
-- "PlayerNick is null" when it doesn't decode (NOTES.md, "Co-op join works", #26).
local function base64(s)
    local abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        for k = 0, 3 do
            if k <= 1 or (k == 2 and b) or (k == 3 and c) then
                local v = (n >> (18 - 6 * k)) & 63
                out[#out + 1] = abc:sub(v + 1, v + 1)
            else
                out[#out + 1] = "="
            end
        end
    end
    return table.concat(out)
end

local function console(cmd)
    local pc = FindFirstOf("PlayerController")
    if not (pc and pc:IsValid()) then return reply("no PlayerController for: " .. cmd) end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    ksl:ExecuteConsoleCommand(pc, cmd, pc)
    reply("ran: " .. cmd)
end

local function run(line)
    local verb, rest = line:match("^(%S+)%s*(.*)$")
    if not verb then return end
    if verb == "status" then status()
    elseif verb == "dump" then DumpAllObjects(); reply("objects dumped")
    elseif verb == "sdk" then GenerateSDK(); reply("CXX headers generated")
    elseif verb == "usmap" then DumpUSMAP(); reply("usmap dumped")
    elseif verb == "actors" then DumpAllActors(); reply("actors dumped")
    elseif verb == "get" then
        -- get <Class> <Prop> [<Prop> ...]   reads properties of the first live object of a class
        local cls, props = rest:match("^(%S+)%s+(.+)$")
        local o = FindFirstOf(cls)
        if not (o and o:IsValid()) then return reply("no live " .. tostring(cls)) end
        for p in props:gmatch("%S+") do
            local ok, v = pcall(function() return o[p] end)
            if ok and type(v) == "userdata" and v.ToString then v = v:ToString() end
            if ok and type(v) == "userdata" and v.GetFullName then v = name(v) end
            reply(cls .. "." .. p .. " = " .. tostring(v))
        end
    elseif verb == "find" then
        local all = FindAllOf(rest) or {}
        reply(#all .. " x " .. rest)
        for i = 1, math.min(#all, 40) do reply("  " .. name(all[i])) end
    elseif verb == "lua" or verb == "luaq" then
        -- lua <code>   runs a Lua chunk on the game thread (luaq is the same, kept for old scripts); `return x` replies x
        local chunk, err = load(rest, "bridge", "t", setmetatable({ reply = reply, name = name }, { __index = _G }))
        if not chunk then return reply("compile: " .. err) end
        reply("= " .. tostring(chunk()))
    elseif verb == "raid" then
        -- raid <Spaceport_01|MoonBase_01|...>   loads a raid map standalone with the options the raid code needs
        console("open /Game/Maps/Raids/" .. (rest ~= "" and rest or "Spaceport_01")
            .. "?PID=offline1?PNAME=Marauder?CREW=solo1?CPT=1?NUM=1?EOS=offline1?UPN=offline1?psid=1")
    elseif verb == "join" then
        -- join [host[:port]] [name] [n]   joins a listen host as co-op player n (default 127.0.0.1:7777, Marauder2, 2)
        local addr, nick, n = rest:match("^(%S*)%s*(%S*)%s*(%d*)$")
        n = n ~= "" and n or "2"
        addr = (addr and addr ~= "") and addr or "127.0.0.1:7777"
        nick = (nick and nick ~= "") and nick or ("Marauder" .. n)
        console("open " .. addr .. "?PID=offline" .. n .. "?PNAME=" .. base64(nick) .. "?CREW=solo" .. n
            .. "?CPT=1?NUM=1?EOS=offline" .. n .. "?UPN=offline" .. n)
    elseif verb == "bot" then
        -- bot [Normal|Guard|Military] [distance]   spawns an AI soldier in front of the player
        local kind, dist = rest:match("^(%a*)%s*(%S*)$")
        local cls = StaticFindObject("/Game/Blueprints/Pawns/BotPawn" .. (kind == "Normal" and "" or kind)
            .. ".BotPawn" .. (kind == "Normal" and "" or kind) .. "_C")
        if not cls:IsValid() then return reply("bot class not loaded: " .. kind) end
        local pc = FindFirstOf("PlayerController")
        local pawn = pc.Pawn
        local loc, rot = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
        local d, yaw = tonumber(dist) or 600, math.rad(rot.Yaw)
        local helper = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
        local tree = StaticFindObject("/Game/Blueprints/Pawns/BotBehavior.BotBehavior")
        local bot = helper:SpawnAIFromClass(pc, cls, tree,
            { X = loc.X + d * math.cos(yaw), Y = loc.Y + d * math.sin(yaw), Z = loc.Z + 50 },
            { Pitch = 0, Yaw = rot.Yaw + 180, Roll = 0 }, true, pc)
        -- RaidBot's AI-state debug sprite (a smiley) is visible in game; the director hides it on its own bots too
        if bot and bot:IsValid() then pcall(function() bot.Billboard:SetHiddenInGame(true, false) end) end
        reply("bot " .. name(bot) .. " ctrl=" .. ((bot and bot:IsValid()) and name(bot.Controller) or "-"))
    elseif verb == "unwidget" then
        -- unwidget <WidgetClass>   hides every live widget of that class. Collapsed, not removed: the PGOS
        -- overlay is still referenced by its subsystem, and removing it crashed the next map travel.
        local all = FindAllOf(rest) or {}
        for _, w in ipairs(all) do w:SetVisibility(1) end
        reply("hid " .. #all .. " x " .. rest)
    elseif verb == "spawn" then
        -- spawn <ClassPath> [distance]   spawns an actor in front of the player
        local path, dist = rest:match("^(%S+)%s*(%S*)$")
        local cls = StaticFindObject(path)
        if not (cls and cls:IsValid()) then return reply("class not loaded: " .. path) end
        local pc = FindFirstOf("PlayerController")
        local pawn = pc.Pawn
        local loc, rot = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
        local d, yaw = tonumber(dist) or 500, math.rad(rot.Yaw)
        local at = { X = loc.X + d * math.cos(yaw), Y = loc.Y + d * math.sin(yaw), Z = loc.Z + 50 }
        -- Facing back at the player: quaternion for yaw + 180 around Z.
        local half = math.rad(rot.Yaw + 180) / 2
        local xf = { Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
                     Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        -- 2 = AdjustIfPossibleButAlwaysSpawn
        local a = gs:BeginDeferredActorSpawnFromClass(pc, cls, xf, 2, nil)
        if a and a:IsValid() then a = gs:FinishSpawningActor(a, xf) end
        reply("spawned " .. name(a))
    else console(line) end
end

-- Everything runs on the game thread, polled from blueprint functions the game calls every frame
-- (ExecuteInGameThread never fires in this game: UE4SS can't hook its ProcessEvent). Commands used to be
-- read on the LoopAsync thread and queued for the game thread; both threads share this Lua state, and
-- after one game-thread job the LoopAsync thread blocked for good while the game ran on. So the async
-- thread now only registers the hooks and then ends, and nothing in this mod runs on it after that.
-- bridge/heartbeat.txt is rewritten every few seconds while commands are being polled.
local lastPoll, lastBeat = -1, -1

local function poll()
    local work = CMD .. ".work"
    os.remove(work)
    if not os.rename(CMD, work) then return end
    local f = io.open(work, "r")
    if not f then return end
    local text = f:read("a")
    f:close()
    os.remove(work)
    for line in text:gmatch("[^\r\n]+") do
        reply("> " .. line)
        local ok, err = xpcall(run, function(e)
            if type(e) == "function" then e = "(UE4SS error object)" end
            return debug.traceback(tostring(e), 2)
        end, line)
        if not ok then reply("error in '" .. line .. "': " .. tostring(err)) end
    end
end

local function onTick()
    local now = os.clock()
    if now - lastPoll < 0.25 then return end -- several tickers fire per frame
    lastPoll = now
    if now - lastBeat >= 5 then
        lastBeat = now
        local f = io.open(BRIDGE .. "heartbeat.txt", "w")
        if f then f:write(os.date("%H:%M:%S"), "\n"); f:close() end
    end
    local ok, err = pcall(poll)
    if not ok then reply("poll failed: " .. tostring(err)) end
end

local TICKERS = {
    "/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:ReceiveTick",
    "/Game/Blueprints/MainMenu/MM_CoreMissions.MM_CoreMissions_C:ReceiveTick",
}
local hooked = {}
LoopAsync(1000, function()
    local all = true
    for _, fn in ipairs(TICKERS) do
        if not hooked[fn] then
            if StaticFindObject(fn):IsValid() and pcall(RegisterHook, fn, onTick) then
                hooked[fn] = true
                print("[PvEBridge] game-thread hook on " .. fn .. "\n")
            else
                all = false
            end
        end
    end
    return all -- true ends the loop
end)

reply("PvEBridge loaded")
