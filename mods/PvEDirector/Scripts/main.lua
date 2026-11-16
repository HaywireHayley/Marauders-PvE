-- PvEDirector: turns an offline raid into a PvE raid.
-- The shipped client has no AI navigation data (it lived in a server-only "Whitebox" sublevel), and bots
-- spawn frozen (time dilation 0, hidden, movement off) waiting for a server-side significance manager.
-- So on every raid map this mod:
--   1. builds a navmesh at runtime, bounded by the map's CullDistanceVolume
--   2. spawns soldiers at the map's AINodeStart nodes, away from the player
--   3. keeps them awake, and gives them the player as enemy once they see/hear the player or get shot
-- Keys: F3 = AI tuning menu (tuning.lua), F9 = debug menu (debugmenu.lua: god mode, extract now, spawn a soldier, a
--       crew attacks you, open the gates, give a gun, test raid), F2 = your body female or male,
--       N / M / B = minimap on or off / full overview / next task (minimap.lua).
-- With the offline backend, the lobby's Start Matchmaking loads a space map, where you start in your ship
-- (see "Matchmaking"); space maps get the loadout and extraction but no soldiers.
-- Also loads native/pvepatch.dll, which patches out the role checks that stop a standalone player's shots from
-- doing damage and skip all weapon fire effects (see pvepatch.c).
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua); a global: main.lua is at the 200-locals limit
GearScale = require("gearscale") -- rivals' and crew's gear follows your player level (a global for the same reason)
local Interiors = require("interiors") -- interiors seen from open space: hidden while you're outside them

local CFG = {
    BOTS = 8,                -- soldiers per raid (0 = use the game mode's NumberNormal/Guard/MilitaryAI)
    MIN_SPAWN_DIST = 2500,   -- don't spawn closer than this to the player
    GARRISON = 6,            -- soldiers per station on space maps (fallback: rivals passes MIN_DEFENDERS)
    -- Senses, spotting time, reaction and accuracy come from ai.lua's profiles (soldiers "soldier"/"guard").
    POINT_BLANK = 300,       -- a noise this close starts a fight at once
    PERCEIVE_RANGE = 7000,   -- bots size up hostile bodies (you, other factions) within this range
    ANIM_FAR = 6000,         -- bots farther than this from the camera animate the engine's cheap way (not drawn = no pose)
    ANIM_SLOW_FAR = 4000,    -- bots at peace farther than this from the camera run animate() ANIM_SLOW_HZ a second, not every frame
    ANIM_SLOW_HZ = 10,
    ANIM_HZ = 30,            -- every other bot (and every fighting one) runs animate() and its aim upkeep this often
    RETARGET_EVERY = 1.0,    -- while fighting, how often (s) a bot looks for a much closer enemy to switch to
    RETARGET_NEAR = 1500,    -- ...within this range
    RETARGET_RATIO = 0.5,    -- ...and at most this share of the current foe's distance
    GUNSHOT_RANGE = 10000,   -- gunshots carry this far (at hearing 1.0)
    BOT_GUNSHOT_SCALE = 0.4, -- a bot's own shots carry this share of that: at 100 m every bot in a station heard every
                             -- firefight, went to look and died in the first two minutes (2026-11-14, Moon Base)
    LOOK_AROUND = { 3, 6 },  -- seconds spent looking around where a noise came from
    UPDATE_SECONDS = 0.5,
    INTERACT_SECONDS = 0.1,  -- how often to look for what the player can use (see onTick)
    PATROL_RADIUS = 1800,    -- idle soldiers wander between reachable points this far from where they spawned
    PATROL_PAUSE = { 4, 12 },-- seconds to stand around between patrol legs
    ADVANCE_RADIUS = 400,    -- fighting without sight of the player: move to a point this close to where they were seen
    REPOSITION_SECONDS = { 3, 7 },
    STUCK_SPEED = 60,        -- a fighting move this slow for STUCK_SECONDS is cancelled (legs walked on the spot)
    STUCK_SECONDS = 1.0,
    CROUCH_MAX = 1.2,        -- out of cover the tree crouch-peeks constantly: stand up after this long crouched...
    CROUCH_COOLDOWN = 10,    -- ...and stay standing at least this long
    MOVE_ANIM_SCALE = 1.45,  -- top walking speed over the blueprint's leg cycle (walk ~320, aiming walk ~190);
                             -- the animation itself plays at the actual speed (animate)
    LOW_COVER_PENALTY = 500, -- prefer full (lean) cover: low cover counts as this much farther away
    -- Cover: a spot where a standing soldier can't see the player, with a walkable firing point (PEEK_STEPS) to one
    -- side where it can (or, low cover, where crouched it can't see but standing it can).
    COVER_SEARCH = 1100,     -- look for cover this far from the soldier...
    COVER_CANDIDATES = 24,   -- ...testing this many reachable spots
    COVER_RETRY = 1,         -- seconds between cover searches while fighting without cover
    COVER_SEARCH_FAR = 2200, -- nothing close: search this far before ever fighting in the open
    COVER_CANDIDATES_FAR = 28,
    SPRINT_SPEED = 550,      -- running to cover with the real sprint animation (the player's sprint speed)
    SPRINT_ANIM = "/Game/Characters/MainPlayer/Animations/00_BaseMovement/rc_Sprint_FW_New.rc_Sprint_FW_New",
    EXPOSED_COVER_DIST = 1200,-- while the player can see it, only run for cover this close...
    EXPOSED_RUN_SECONDS = 3, -- ...and give up on cover after this long running in sight
    OPEN_LOG_SECONDS = 10,   -- log why a fighting soldier is in the open at most this often per soldier
    OPEN_FIGHT_SECONDS = 1.5,-- no cover or chose not to: fight in the open this long before thinking again (x holdGround)
    COVER_SEEK_CHANCE = 0.95,-- each look for cover: chance to bother at all (to the power of the personality's aggression)
    COVER_HURT_CHANCE = 0.99,-- ...the same right after being shot
    COVER_BAKE_RADIUS = 2400,-- cover.lua bakes the map this far around you on foot (and COVER_SEARCH_FAR around fighters)
    COVER_BAKED_POOL = 40,   -- baked spots considered per search...
    COVER_BAKED_PROBES = 6,  -- ...and how many of the best get the line-of-sight probe
    COVER_RANDOM_SHARE = 0.25,-- random-point probes when baked spots exist (share of COVER_CANDIDATES), else all
    COVER_MOVE_MIN = 300,    -- moving on from a cover spot: the next one at least this far away
    COVER_AGGRESSION_PULL = 0.3, -- per point of aggression over 1: spots nearer the player score better (under 1: farther)
    SPRINT_EXPOSED_CHANCE = 0.15, -- going to cover in the enemy's sight: chance to sprint with the weapon down;
    SPRINT_UNSEEN_CHANCE = 0.5,   -- out of sight. Otherwise it walks there, facing the enemy and firing.
    COVER_BACK_RUN = 0.3,    -- ...unless the spot is behind it (cosine to the enemy below minus this): that walk is a
                             -- slow backpedal (backwards is capped at the strafe factor, ~0.6), so it turns and runs
    COVER_MOVE_RETRIES = 2,  -- a move to cover that ends short is sent again this often, while it still gains ground
    COVER_PATH_STRETCH = 1.8,-- a cover spot whose walk there is longer than this x the straight line (+ COVER_PATH_SLACK)
    COVER_PATH_SLACK = 300,  -- is the long way round (another room, or another floor): skipped
    MELEE_REACH = 230,       -- knife / truncheon soldiers (Weap_Knife_C) charge you and only swing this close...
    MELEE_LET_GO = 330,      -- ...and stop swinging past this
    MELEE_RUN = 450,         -- they run (sprint animation) when farther than this
    HURT_DUCK_SECONDS = 0.6, -- shot this recently: duck back into cover / look for cover now
    -- Aim (AI.aimFor): the profile's miss rate, varied per bot and per moment. Multipliers unless noted.
    AIM_SKILL_SPREAD = 0.3,  -- a bot's lifelong skill: up to this share better or worse than the profile
    AIM_STREAK = 0.25,       -- hot and cold spells: up to this share either way...
    AIM_STREAK_SECONDS = { 1.5, 5 }, -- ...lasting this long
    AIM_SETTLE_SECONDS = 1.5,-- a target just came into sight: aim settles over this long...
    AIM_SETTLE_PENALTY = 1.4,-- ...starting this much worse
    AIM_MOVING = 1.2,        -- the bot moving
    AIM_TARGET_MOVING = 1.1, -- the target moving
    AIM_UNDER_FIRE = 1.25,   -- just got hit...
    AIM_UNDER_FIRE_SECONDS = 1.5, -- ...for this long
    AIM_RANGE_PER_10M = 0.04,-- added to the multiplier per 10 m of range
    AIM_MISS_MAX = 1.0,      -- the worst AIMissRate allowed (past ~0.9 the game's aim doesn't get any worse)
    -- Rival crews against the station's guards and soldiers only (not each other, you or your crew): they came in to
    -- raid the place and know their business; the guards are bored conscripts.
    EDGE_GUARD_MISS = 1.6,   -- a guard shooting at a rival misses this much more...
    EDGE_GUARD_SPOT = 1.8,   -- ...and takes this much longer to spot one
    EDGE_RIVAL_MISS = 0.7,   -- a rival shooting at a guard misses this much less
    STRAFE_DIST = { 100, 250 }, -- open fighting (no cover found): side-step this far across the player's line of fire...
    STRAFE_SECONDS = { 2.5, 4.5 }, -- ...this often
    STRAFE_ANIM_SCALE = 2.2, -- the same while strafing in a fight (aiming legs 0.65): ~290
    AIM_SLOWDOWN = 0.5,      -- the game's own speed factor on an aiming bot (animate divides it back out)
    LEG_RATE_MAX = 1.6,      -- legs never cycle faster than this x their natural rate; top speed is held to match
                             -- (strafing at 2.2x and peek steps at up to 3.4x had "very silly rapid leg movement")
    COVER_PLAYER_DIST = { 350, 4000 }, -- only cover this far from the player
    COVER_BLIND_PEEKS = 2,   -- a cover spot is kept as long as it works: it's only left when flanked, or after this many
                             -- peeks in a row that couldn't see the player (they moved to an angle it doesn't cover)
    HIDE_SECONDS = { 0.7, 1.6 },
    PEEK_SECONDS = { 0.9, 1.8 },
    PEEK_SPEED = 450,        -- stepping out to the firing point and back: a quick lean-out, not a slow side-walk
    PEEK_ACCEL = 6000,       -- (the default acceleration took ~0.2 s to reach walking speed)
    PEEK_STEPS = { 60, 100, 140 }, -- firing point: the first of these that sees, to the side of the cover spot. Leaning alone is cosmetic
                             -- (the AI's ShootEnemy traces from the unleaned eye), so soldiers step out to fire.
    EYE_STAND = 150,         -- eye height above the floor, standing / crouched
    EYE_CROUCH = 85,
    MAP = "Spaceport_01",    -- F7's raid map
    -- Start Matchmaking (offline backend only): after this long "searching", load one of these space maps, where
    -- the game mode spawns the player inside their ship as on a live server.
    MM_SEARCH_SECONDS = 1,   -- was 4: pure waiting, the map load after it is the long part
    -- Live, the matchmaking loading screen hides the space map until you're in your ship (the game mode spawns
    -- the ship and pawn after its warmup). Offline the screen stays black instead, until the pawn and ship exist
    -- and every streaming level is in, then REVEAL_DELAY more; at most VEIL_MAX seconds.
    REVEAL_DELAY = 1.5,
    LOAD_TIME_DILATION = 20, -- game speed behind that black screen (see veilUntilAboard); 1 = off. 20 is the engine's
                             -- cap (WorldSettings.MaxGlobalTimeDilation); was 10
    VEIL_MAX = 90,
    LEVEL_EFFECT_RADIUS = 40000, -- a space map's sublevel fog/post-process only shows this close to it (see below)
    SPACE_MAPS = {
        solo = { "Space_Solo_01", "Space_Solo_02" },
        crew = { "Space_Alpha", "Space_Beta", "Space_Charlie", "Space_Delta" },
        raider = { "Space_Raider_01", "Space_Raider_02" },
    },
    -- What offline matchmaking picks from: solo and crew maps (all tested offline). The raider maps belong to the
    -- game's raider mode and close the game when loaded this way.
    MAP_POOL = { "Space_Solo_01", "Space_Solo_02", "Space_Alpha", "Space_Beta", "Space_Charlie", "Space_Delta" },
    -- The player starts with the stash loadout the local Nakama stand-in keeps (while OFFLINE_BACKEND_FLAG exists).
    LOADOUT_FILE = PROJECT .. "backend/loadout.json",
    CHECKOUT_FILE = PROJECT .. "backend/checkout.txt",
    SHIP_LOST_FILE = PROJECT .. "backend/ship_lost.txt",
    SHIP_GATE_FILE = PROJECT .. "backend/ship_gate.txt",
    EXTRACT_SECONDS = 3,     -- after extracting, back to the main menu this much later
    OFFLINE_BACKEND_FLAG = PROJECT .. "bridge/offline_backend",
    GIVE_GUN = true,         -- no gun in the loadout (or no stand-in): hand the player a soldier's gun...
    START_MAGS = 4,          -- ...and this many magazines of its ammo in the left pocket
}

-- profile: ai.lua difficulty profile; power: gear power bonus over a scav's for picking a personality
local KINDS = {
    { path = "/Game/Blueprints/Pawns/BotPawn.BotPawn_C", weight = 5, profile = "soldier", power = 0 },
    { path = "/Game/Blueprints/Pawns/BotPawnGuard.BotPawnGuard_C", weight = 2, profile = "guard", power = 45 },
    { path = "/Game/Blueprints/Pawns/BotPawnMilitary.BotPawnMilitary_C", weight = 1, profile = "guard", power = 90 },
}
local TREE = "/Game/Blueprints/Pawns/BotBehavior.BotBehavior"
-- Teams: you 3 (the station levels' own NPCs default to 1), soldiers/station defenders 2, rival crews 10+.
local PLAYER_TEAM, BOT_TEAM = 3, 2

-- URL options a raid server reads at login (player id, name, crew...); standalone they just need to be present.
local RAID_OPTS = "?PID=offline1?PNAME=Marauder?CREW=solo1?CPT=1?NUM=1?EOS=offline1?UPN=offline1?psid=1"

local function log(msg) print("[PvEDirector] " .. tostring(msg) .. "\n") end
local function valid(o) return o ~= nil and o:IsValid() end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function rnd(range) return range[1] + math.random() * (range[2] - range[1]) end
local function dist2d(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

local AI = require("ai")
local Cover = require("cover")
local Tuning = require("tuning")
local Debug = require("debugmenu")
local Loading = require("loading")
local Splash = require("splash")
local Minimap = require("minimap")
local Voice = require("voice")
local Female = require("female")
local Gunseat = require("gunseat")
AI.init({ log = log, valid = valid, dist = dist })

-- Weapon role-check patches (native/pvepatch.dll applies them when loaded and reports to patch_out.txt).
local PATCH_DLL = PROJECT .. "native/pvepatch.dll"
local PATCH_OUT = PROJECT .. "bridge/patch_out.txt"
local nativeFireFx = false -- true once SimulateWeaponFire runs for Authority weapons (bots get real effects)
do
    local ok, err = package.loadlib(PATCH_DLL, "*")
    local f = io.open(PATCH_OUT, "r")
    local report = f and f:read("a") or ""
    if f then f:close() end
    nativeFireFx = report:find("SimulateWeaponFire effects @ %S+: a") ~= nil -- "applied" / "already applied"
    log("weapon patches: " .. (ok and report:gsub("\n", "; ") or ("pvepatch.dll failed to load: " .. tostring(err))))
end
-- Bot bodies (pvepatch.c, queueBody): a dead bot's body container copies the pose of the bot's ragdoll once it has come
-- to rest (settleRagdolls below). Called every frame; it takes and returns nothing.
local pveBodies = package.loadlib(PATCH_DLL, "pve_bodies")
local pveBodiesReset = package.loadlib(PATCH_DLL, "pve_bodies_reset")
local pveRollKit = package.loadlib(PATCH_DLL, "pve_roll_kit") -- (bot, item table, gun, pistol, helmet, armour, bag rows)
local pveAddItem = package.loadlib(PATCH_DLL, "pve_add_item") -- (bot, row, stack)
local pveKeepWorn = package.loadlib(PATCH_DLL, "pve_keep_worn") -- (bot): empties its bags and pockets
local pveLoad = package.loadlib(PATCH_DLL, "pve_load") -- (path as an FName index): assets the cooked registry doesn't list
local pveRoot = package.loadlib(PATCH_DLL, "pve_root") -- (object address): keeps it from the garbage collector
local pveStashRows = package.loadlib(PATCH_DLL, "pve_stash_rows") -- (inventory component, rows)
local pveLooseAssets = package.loadlib(PATCH_DLL, "pve_loose_assets")
if pveLooseAssets then pveLooseAssets() end
local pveBpJump = package.loadlib(PATCH_DLL, "pve_bp_jump") -- (UFunction address, bytecode offset)
local pveBpStubReturn = package.loadlib(PATCH_DLL, "pve_bp_stub_return") -- (UFunction address)

-- The ragdolls still falling. A corpse keeps the pose it has when it's swapped in, so the swap waits until every bone
-- has stopped moving, sampled every SETTLE_SAMPLE s. pvepatch.c watches for SETTLED_MARK in the dead bot's AiMissRange
-- (the DLL has no way to take arguments). Entries leave here before the pawn can be destroyed: pve_bodies only retires
-- it after this mark, or after its own, longer limit.
local SETTLE_BONES = { "pelvis", "head", "hand_l", "hand_r", "foot_l", "foot_r" }
local SETTLE_SAMPLE, SETTLE_STILL_UNITS, SETTLE_STILL_SAMPLES = 0.1, 3, 4 -- 0.4 s with no bone moving over 30 u/s
local SETTLE_MIN, SETTLE_MAX = 1.2, 7 -- seconds after the death; a limp collapse starts slowly, so never sooner than MIN
local SETTLED_MARK = -12345
local ragdolls = {}

local function settleRagdolls()
    local now = os.clock()
    for i = #ragdolls, 1, -1 do
        local r = ragdolls[i]
        if not valid(r.bot) then
            table.remove(ragdolls, i)
        elseif now >= r.nextAt then
            r.nextAt = now + SETTLE_SAMPLE
            local moved = 0
            for b, bone in ipairs(r.bones) do
                local at, was = r.mesh:GetSocketLocation(bone), r.pose[b]
                if was then moved = math.max(moved, dist(at, was)) end
                r.pose[b] = at
            end
            r.still = moved < SETTLE_STILL_UNITS and r.still + 1 or 0
            local age = now - r.at
            if age >= SETTLE_MAX or (age >= SETTLE_MIN and r.still >= SETTLE_STILL_SAMPLES) then
                r.bot.AiMissRange = SETTLED_MARK
                table.remove(ragdolls, i)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------
-- Game-thread scheduling. ExecuteInGameThread is unreliable in this game, so work queued from other
-- threads (key binds) runs from blueprint functions the game calls every frame.
local pending = {}
local lastUpdate, lastInteract = 0, 0
local update, trackTargets, Rivals -- forward

local raid -- forward: per-raid state (below)

local launching -- a raid about to load: { pc, at, cmd } (launchMatch)
local mm -- { at = os.clock() time to launch, map = map name } while an offline search runs
local launchShip -- the active ship's table row, from launchMatch to the moment it's aboard

-- Garbage collection, driven from the frame. The director makes ~10 MB of garbage a second in a fight (much of it UE4SS
-- userdata for the objects and structs it reads, each with a finalizer). Left to Lua's defaults the heap ran up to 2 GB
-- and each cycle's non-incremental part (it walks every finalizable object) froze the game for 100-430 ms: the "drops to
-- 50 fps". Now the automatic steps are 4x as big (stepmul 400) and every frame spends up to gc.BUDGET_MS on steps
-- itself, so a cycle finishes before the heap has doubled (pause 200; at 130 cycles ran back to back, each re-marking
-- everything live: 10-20% of frame time) and the heap stays ~2x live instead of 2 GB. bridge/gc_gen (testing): Lua 5.4's generational mode instead.
-- BUDGET_MS per frame, BEHIND_MS while the heap is more than twice the last live size (a burst of garbage).
local gc = { BUDGET_MS = 1.0, BEHIND_MS = 3.0, live = collectgarbage("count"), cycles = 0, stepMax = 0, stepMs = 0, liveHi = 0 }
do
    local gen = io.open(PROJECT .. "bridge/gc_gen", "r")
    if gen then gen:close() collectgarbage("generational", 20, 100) gc.gen = true
    else collectgarbage("incremental", 200, 400) end
end
-- A new cycle starts only once the heap is START x the last live size (a cycle under way is always stepped on): stepping
-- every frame regardless began a new cycle the frame after one ended, ~43 full cycles a second re-marking ~14 MB live,
-- ~2.5 ms of every frame (profile.txt "stepping 2483 ms" per 10 s at Moon Base, 2026-11-14).
gc.START = 1.25
function gc.frame()
    if gc.gen then return end
    local heap = collectgarbage("count")
    if not gc.running and heap < gc.live * gc.START then return end
    gc.running = true
    local t0 = os.clock()
    local stop = t0 + ((heap > gc.live * 2) and gc.BEHIND_MS or gc.BUDGET_MS) / 1000
    repeat
        local t = os.clock()
        local done = collectgarbage("step", 32) -- 32 KB of "allocation" worth of work per step
        local ms = (os.clock() - t) * 1000
        if ms > gc.stepMax then gc.stepMax = ms end
        if done then
            gc.live, gc.cycles, gc.running = collectgarbage("count"), gc.cycles + 1, false
            if gc.live > gc.liveHi then gc.liveHi = gc.live end
            break
        end
    until os.clock() >= stop
    gc.stepMs = gc.stepMs + (os.clock() - t0) * 1000
end
_G.PVE_GC = gc

-- Testing: with bridge/profile_on present, object scans and slow ticks are counted into bridge/profile.txt every 10 s.
local function profiler(tick)
    local on = io.open(PROJECT .. "bridge/profile_on", "r")
    if not on then return tick end
    on:close()
    local scans, slow, frames, flushed = {}, {}, 0, os.clock()
    for _, name in ipairs({ "FindAllOf", "FindFirstOf" }) do
        local real = _G[name]
        _G[name] = function(cls)
            local t = os.clock()
            local out = real(cls)
            local key = name .. " " .. tostring(cls)
            scans[key] = scans[key] or { n = 0, ms = 0 }
            scans[key].n, scans[key].ms = scans[key].n + 1, scans[key].ms + (os.clock() - t) * 1000
            return out
        end
    end
    local last, gaps, worst = nil, {}, 0 -- time between frames (this tick runs once a frame): the whole game's hitches
    _G.PVE_PROF, _G.PVE_ALLOC = {}, {}
    local outKb, inKb, endMem = 0, 0, nil -- KB allocated between director ticks (hooks, other callbacks) / inside them
    local memLo, memHi, drops = math.huge, 0, 0 -- Lua heap (KB) seen each frame; a drop = a garbage collection ran
    local lastMem
    local bigGaps = {} -- the worst gaps' times, to line them up with the log
    return function(ctx)
        local t = os.clock()
        local mem = collectgarbage("count")
        if lastMem and mem < lastMem - 512 then drops = drops + 1 end
        lastMem = mem
        if mem < memLo then memLo = mem end
        if mem > memHi then memHi = mem end
        if last then
            local gap = (t - last) * 1000
            if gap > worst then worst = gap end
            for _, limit in ipairs({ 33, 50, 100, 200 }) do
                if gap >= limit then gaps[limit] = (gaps[limit] or 0) + 1 end
            end
            if gap >= 100 and #bigGaps < 12 then bigGaps[#bigGaps + 1] = ("%.0f@%.1f"):format(gap, t - flushed) end
        end
        last = t
        if endMem and mem > endMem then outKb = outKb + (mem - endMem) end
        tick(ctx)
        endMem = collectgarbage("count")
        if endMem > mem then inKb = inKb + (endMem - mem) end
        local ms = (os.clock() - t) * 1000
        frames = frames + 1
        for _, limit in ipairs({ 5, 10, 25, 50 }) do
            if ms >= limit then slow[limit] = (slow[limit] or 0) + 1 end
        end
        if t - flushed >= 10 then
            local f = io.open(PROJECT .. "bridge/profile.txt", "a")
            if f then
                f:write(("%s frames %d, director over 5/10/25/50 ms: %d %d %d %d; frame gaps over 33/50/100/200 ms: %d %d %d %d, worst %.0f\n")
                    :format(os.date("%H:%M:%S"), frames, slow[5] or 0, slow[10] or 0, slow[25] or 0, slow[50] or 0,
                    gaps[33] or 0, gaps[50] or 0, gaps[100] or 0, gaps[200] or 0, worst))
                for k, v in pairs(scans) do f:write(("  %s x%d %.0f ms\n"):format(k, v.n, v.ms)) end
                f:write(("  SetSkeletalMesh hook calls %d\n"):format(Female.hookCalls or 0))
                local P = _G.PVE_PROF
                f:write(("  lua heap %.0f-%.0f KB, %d collections; turret swing hook calls %d; sections ms:"):format(
                    memLo, memHi, drops, P.swing or 0))
                for k, v in pairs(P) do if k ~= "swing" then f:write((" %s %.0f"):format(k, v)) end end
                f:write((" | bots %d"):format(raid and raid.bots and #raid.bots or 0))
                f:write(("\n  allocated MB: in ticks %.1f, between ticks (hooks) %.1f; by section:"):format(inKb / 1024, outKb / 1024))
                for k, v in pairs(_G.PVE_ALLOC) do f:write((" %s %.1f"):format(k, v / 1024)) end
                f:write(("\n  gc %s: %d cycles, live after last %.0f MB (window high %.0f), stepping %.0f ms, longest step %.1f ms; registry %d slots, %d out-param refs released"):format(
                    gc.gen and "generational" or "stepped", gc.cycles, gc.live / 1024, gc.liveHi / 1024, gc.stepMs, gc.stepMax,
                    select(2, Out.stats()), (Out.stats())))
                gc.cycles, gc.liveHi, gc.stepMs, gc.stepMax = 0, 0, 0, 0
                f:write("\n  gaps over 100 ms (ms@s): " .. table.concat(bigGaps, " ") .. "\n")
                pcall(function() -- where you were: on foot / flying, and the nearest station
                    local pc = Hire and Hire.lastPc()
                    local pawn = valid(pc) and pc.Pawn
                    if not valid(pawn) then return end
                    local l = pawn:K2_GetActorLocation()
                    local st, sd = Rivals.nearestStation(l)
                    f:write(("  you: %s, %s, nearest station %s %.0f m, fps %.0f\n"):format(
                        pawn:GetClass():GetFName():ToString(), tostring(Rivals.where() or "-"),
                        tostring(st), (sd or 0) / 100, frames / 10))
                end)
                _G.PVE_PROF, _G.PVE_ALLOC, bigGaps, memLo, memHi, drops = {}, {}, {}, math.huge, 0, 0
                inKb, outKb = 0, 0
                Female.hookCalls = 0
                f:close()
            end
            scans, slow, frames, flushed, gaps, worst = {}, {}, 0, t, {}, 0
        end
    end
end

-- pcall that adds its time to the profiler's per-section totals (bridge/profile_on)
local function ppcall(name, fn, ...)
    local P = _G.PVE_PROF
    if not P then return pcall(fn, ...) end
    local t, m = os.clock(), collectgarbage("count")
    local ok, err = pcall(fn, ...)
    local ms = (os.clock() - t) * 1000
    P[name] = (P[name] or 0) + ms
    if ms > (P[name .. "Max"] or 0) then P[name .. "Max"] = ms end
    local kb = collectgarbage("count") - m -- allocated (a negative delta = the collector freed more than we made: skipped)
    if kb > 0 then
        local A = _G.PVE_ALLOC
        if A then A[name] = (A[name] or 0) + kb end
    end
    return ok, err
end

local function onTick(ctx)
    -- A new world, seen on its first frame: drop everything held from the old one now. update() notices too, but only
    -- every UPDATE_SECONDS, and until then the per-frame work below (the crew menu, the lobby stands, menus) still held
    -- the old world's freed objects. Keyed on the world's address and name: a new world can reuse the old one's address.
    local w = ctx:get():GetWorld()
    local wk = w and w:IsValid() and ("%x %s"):format(w:GetAddress(), w:GetFName():ToString()) or nil
    if wk ~= PveTickWorld then
        if PveTickWorld ~= nil and PveResetRaid then PveResetRaid(nil) end
        PveTickWorld = wk
    end
    -- Loading a sound crashes while a map travels, so voice lines only load in the menu with no match on the way. Lines
    -- not loaded yet are skipped by the bots, and the rest load next time you're in the menu.
    if Voice.pending() and not launching and not mm and ctx:get():GetClass():GetFName():ToString() ~= "MainPlayerController_C" then
        for _ = 1, 3 do pcall(Voice.step) end
    end
    pcall(Splash.gatePlay) -- PLAY hidden until the backend login is done (splash.lua)
    local shown, shownErr = ppcall("loading", Loading.tick, ctx:get())
    if not shown then
        log("loading screen failed: " .. tostring(shownErr))
        Loading.reset()
    end
    if launching and os.clock() >= launching.at then
        local l = launching
        launching = nil
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(l.pc, l.cmd, l.pc)
        Loading.reset() -- it stays on screen, but it goes with this world: nothing may touch it from here on
        return
    end
    while #pending > 0 do
        local ok, err = pcall(table.remove(pending, 1))
        if not ok then log("queued job failed: " .. tostring(err)) end
    end
    -- Aim tracking runs every frame, before update() has noticed a new world: only from the player controller the
    -- current raid state belongs to, so it never touches the previous raid's (freed) soldiers.
    local ticker = ctx:get()
    if trackTargets and raid.pcAddr and ticker:GetAddress() == raid.pcAddr then
        local ok, err = ppcall("aim", trackTargets)
        if not ok then log("aim tracking failed: " .. tostring(err)) end
        if raid.navReady then
            ok, err = ppcall("cover", function() Cover.setNav(raid.navMesh) Cover.step(ticker) end)
            if not ok then log("cover baking failed: " .. tostring(err)) end
        end
        ok, err = ppcall("ragdolls", settleRagdolls)
        if not ok then log("ragdoll settling failed: " .. tostring(err)) end
        if pveBodies then pveBodies() end
        ok, err = ppcall("minimap", Minimap.tick, ticker)
        if not ok then log("minimap failed: " .. tostring(err)) end
        -- Rival breaching pods fly frame by frame (rivals.lua).
        if raid.space and Rivals then
            ok, err = ppcall("rivalsFrame", Rivals.frame, raid.world)
            if not ok then log("rival pods failed: " .. tostring(err)) end
            ok, err = ppcall("gunseat", Gunseat.frame, ticker)
            if not ok then log("gunner seat failed: " .. tostring(err)) end
            ok, err = ppcall("crewFrame", Crew.frame)
            if not ok then log("crew gunner failed: " .. tostring(err)) end
            ok, err = ppcall("interiors", Interiors.frame, ticker, raid)
            if not ok then log("interiors failed: " .. tostring(err)) end
        end
        -- Testing (bridge/autofly): fly your ship at raid.autofly with real movement input (teleport steps add their own
        -- hitches), facing where it goes.
        local af = raid.autofly
        local hull = af and ticker.Pawn
        if af and valid(hull) and hull:GetClass():GetFName():ToString():find("Frigate") then
            local l = hull:K2_GetActorLocation()
            local dx, dy, dz = af.X - l.X, af.Y - l.Y, af.Z - l.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 1500 then
                ticker:SetControlRotation({ Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))),
                    Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
                hull:AddMovementInput({ X = dx / d, Y = dy / d, Z = dz / d }, 1.0, false)
            end
        end
        ok, err = ppcall("tags", Crew.tags, ticker)
        if not ok then log("crew nametags failed: " .. tostring(err)) end
    end
    -- The crew menu (F6, hire.lua), the AI tuning menu (F3) and the debug menu (F9) work in the lobby too: they're polled
    -- with the controller hire.lua takes from this ticker (in the lobby the ticker is a menu widget).
    if Hire then
        local ok, err = ppcall("hire", Hire.tick, ticker)
        if not ok then log("crew menu failed: " .. tostring(err)) end
        local pc = Hire.lastPc()
        if valid(pc) then
            ok, err = ppcall("tuning", Tuning.tick, pc)
            if not ok then log("tuning menu failed: " .. tostring(err)) end
            ok, err = ppcall("debug", Debug.tick, pc)
            if not ok then log("debug menu failed: " .. tostring(err)) end
        end
    end
    local now = os.clock()
    -- What you're looking at (the "F" prompts, and what F uses: helm, doors, loot) comes from
    -- SIGISCharacter::InteractionDetection, which a timer from the server's player setup runs; offline nothing
    -- starts it, so F did nothing at the ship's helm. Run it here for the on-foot player (not the ship you fly).
    if raid.pcAddr and ticker:GetAddress() == raid.pcAddr and now - lastInteract >= CFG.INTERACT_SECONDS then
        lastInteract = now
        local pawn = raid.pawn
        if pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C" then
            local ok, err = pcall(function() pawn:InteractionDetection() end)
            if not ok then log("interaction detection failed: " .. tostring(err)) end
            if Missions then
                ok, err = pcall(Missions.interact, ticker, pawn)
                if not ok then log("missions interact: " .. tostring(err)) end
            end
        end
    end
    if now - lastUpdate >= CFG.UPDATE_SECONDS then
        lastUpdate = now
        -- The player controller comes from the ticker (the controller itself in raids, its world's player 0 in the
        -- menu): FindFirstOf scans every object (30-45 ms here), and doing that each update made the game hitch
        -- twice a second (flying the ship stuttered).
        local ok, err = ppcall("update", function()
            local pc = ticker
            if ticker:GetClass():GetFName():ToString() ~= "MainPlayerController_C" then
                pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(ticker, 0)
            end
            update(pc)
        end)
        if not ok then log("update failed: " .. tostring(err)) end
        -- Testing (profiler on): bridge/dir_eval.lua runs once in this Lua state (the bridge mod has its own), its
        -- return value goes to bridge/dir_eval.out. E.g. bridge/t_census.lua, a heap census by path.
        if _G.PVE_PROF then
            local path = PROJECT .. "bridge/dir_eval.lua"
            local f = io.open(path, "r")
            if f then
                f:close()
                local ok2, res = pcall(dofile, path)
                os.remove(path)
                local o = io.open(PROJECT .. "bridge/dir_eval.out", "w")
                if o then o:write(tostring(ok2), "\n", tostring(res), "\n") o:close() end
            end
        end
    end
    gc.frame()
end

local TICKERS = {
    "/Game/Blueprints/Player/MainPlayerController.MainPlayerController_C:ReceiveTick",
    "/Game/Blueprints/MainMenu/MM_CoreMissions.MM_CoreMissions_C:ReceiveTick",
}
-- The LoopAsync thread shares this mod's Lua state with the game thread, so it only registers the hooks and then
-- ends (returning true): a game freeze while a raid map loaded, with this loop still running every second, looked
-- like the two threads waiting on each other (the bridge hung the same way; see NOTES.md).
local hooked = {}
onTick = profiler(onTick)
LoopAsync(1000, function()
    local all = true
    for _, fn in ipairs(TICKERS) do
        if not hooked[fn] then
            if StaticFindObject(fn):IsValid() and pcall(RegisterHook, fn, onTick) then hooked[fn] = true
            else all = false end
        end
    end
    return all
end)

-- ---------------------------------------------------------------------------------------------------
local function lib(path) return StaticFindObject(path) end
local function navLib() return lib("/Script/NavigationSystem.Default__NavigationSystemV1") end
local function queryFilter() return lib("/Script/NavigationSystem.NavigationQueryFilter") end
-- The raid's navmesh, remembered per raid (FindFirstOf scans every object, and bots ask on every move).
-- The navmesh to query. On space maps the RecastNavMesh actor spawned for the runtime rebuild (startSpaceNav) is not
-- the one the navigation system uses: queries against it found nothing (spawn/search spots inside stations all
-- failed); the registered one is the map's RecastNavMesh-Common.
local function navMesh()
    if raid.space and not raid.navRegistered then
        for _, n in ipairs(FindAllOf("RecastNavMesh") or {}) do
            if valid(n) and n:GetFName():ToString():find("Common", 1, true) then
                raid.navMesh, raid.navRegistered = n, true
            end
        end
    end
    if not valid(raid.navMesh) then raid.navMesh = FindFirstOf("RecastNavMesh") end
    return raid.navMesh
end

-- Footsteps: the anim Blueprints' events (walk, sprint, jump, land, crouch) quit at once if IsServer, cosmetics being
-- the client's job live, and offline is always the server. These are the offsets of those branches in each ubergraph
-- (tools/offline-audit/bpserver.py); pve_bp_jump makes them always carry on. Patched once per world, as a Blueprint
-- class that gets reloaded comes back unpatched; the DLL checks the bytes, so it's safe to repeat.
-- The player's PlayFootstepSound (walk, sprint, crouch steps) has a second gate: on the server it skips the sound and
-- only does the footprint decals (tools/offline-audit/kdis.py). The bots' copy has no such gate.
local FOOTSTEP_BRANCHES = {
    ["/Game/Characters/MainPlayer/rc_FPS_AnimBP.rc_FPS_AnimBP_C:ExecuteUbergraph_rc_FPS_AnimBP"] =
        { 13585, 14667, 15387, 16022 },
    ["/Game/Characters/MainPlayer/rc_FPS_AnimBP.rc_FPS_AnimBP_C:PlayFootstepSound"] = { 1288 },
    ["/Game/Characters/MainPlayer/rc_AI_FPS_AnimBP.rc_AI_FPS_AnimBP_C:ExecuteUbergraph_rc_AI_FPS_AnimBP"] =
        { 11338, 11609, 12116, 13292, 13409 },
}

-- The PGOS overlay's friends view: a looping 1 s native timer calls StartGetFriends, which walks the whole Steam friends list
-- with blocking Steam calls on the game thread (GetAdditionalSteamFriendsPGOS, ~70 ms): a hitch every second, in the menu
-- and in raids (the overlay lives on, hidden). Offline that panel only says "social service unavailable", so its stub is
-- made to return at once. Per world, like the footsteps (the DLL checks the bytes, so repeating is safe).
local FRIENDS_REFRESH = "/PgosOverlay/BlueprintUI/Friends/Subview/PgosFriendsPanel_FriendsView_WBP.PgosFriendsPanel_FriendsView_WBP_C:StartGetFriends"
local function patchFriendsRefresh()
    if not pveBpStubReturn then return true end
    local fn = StaticFindObject(FRIENDS_REFRESH)
    if not valid(fn) then return false end
    pveBpStubReturn(fn:GetAddress())
    return true
end

local function patchFootsteps()
    local done = true
    for path, offsets in pairs(FOOTSTEP_BRANCHES) do
        local fn = StaticFindObject(path)
        if valid(fn) then
            for _, offset in ipairs(offsets) do pveBpJump(fn:GetAddress(), offset) end
        else
            done = false
        end
    end
    return done
end

-- Per-raid state, reset whenever the world changes. A world is told apart by name and address: loading the same
-- map again keeps the name, and checking the previous raid's soldiers after the old world was freed crashed
-- (IsValid reads the object's memory).
raid = { world = nil }

local function resetRaid(worldKey)
    if pveBodiesReset then pveBodiesReset() end
    ragdolls = {}
    Tuning.reset()
    Debug.reset()
    Minimap.reset()
    Loading.reset()
    pcall(Loading.disarm) -- back to the game's own screen for everything but raid launches
    -- Every module's hold on the old world's objects goes too: their per-frame parts run before their own update has
    -- rebuilt them for the new raid, and IsValid on a freed object reads freed memory (the UE4SS access violations while
    -- a raid loaded: the crew's name-tag widget, the last raid's turrets).
    Gunseat.reset()
    if Rivals then Rivals.reset() end
    if Crew then Crew.reset() end
    if Missions then Missions.reset() end
    if Hire then Hire.reset() end
    raid = { world = worldKey, navStarted = false, navReady = false, spawned = false, bots = {}, hp = {} }
end
PveResetRaid = resetRaid -- for onTick, which is above it (a global: main.lua is at the 200-locals limit)

-- 1. Runtime navmesh --------------------------------------------------------------------------------
local function startNav(pc)
    local world = pc:GetWorld()
    local bounds = FindFirstOf("CullDistanceVolume")
    if not valid(bounds) then bounds = FindFirstOf("PostProcessVolume") end
    if not valid(bounds) then log("no volume to size the navmesh with") return end

    lib("/Script/NavigationSystem.Default__RecastNavMesh").RuntimeGeneration = 2 -- Dynamic
    local ns = FindFirstOf("NavigationSystemV1")
    ns.bGenerateNavigationOnlyAroundNavigationInvokers = false
    if not valid(FindFirstOf("RecastNavMesh")) then
        world:SpawnActor(lib("/Script/NavigationSystem.RecastNavMesh"), { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end

    -- A NavMeshBoundsVolume spawned at runtime has no brush; borrow the bounding volume's collision shape.
    local loc, scale = bounds:K2_GetActorLocation(), bounds:GetActorScale3D()
    local vol = world:SpawnActor(lib("/Script/NavigationSystem.NavMeshBoundsVolume"), loc, bounds:K2_GetActorRotation())
    vol.Brush = bounds.Brush
    vol.BrushComponent.Brush = bounds.BrushComponent.Brush
    vol.BrushComponent.BrushBodySetup = bounds.BrushComponent.BrushBodySetup
    -- Two scale changes force the component to recompute its bounds from the new shape.
    vol:SetActorScale3D({ X = scale.X * 1.01, Y = scale.Y * 1.01, Z = scale.Z * 1.01 })
    vol:SetActorScale3D(scale)
    ns:OnNavigationBoundsUpdated(vol)
    raid.navStarted = true
    log("navmesh generation started for " .. raid.world)
end

local function navReadyAt(pc, at)
    local out = {}
    return Out.call(navLib(), "K2_ProjectPointToNavigation", pc, at, out, navMesh(), queryFilter(),
        { X = 200, Y = 200, Z = 600 })
end

-- 2. Bots -------------------------------------------------------------------------------------------
local function pickKind()
    local total = 0
    for _, k in ipairs(KINDS) do total = total + k.weight end
    local r = math.random() * total
    for _, k in ipairs(KINDS) do
        r = r - k.weight
        if r <= 0 then return k end
    end
    return KINDS[1]
end

-- Bots spawn asleep; this undoes every part of it. Re-possessing refreshes the controller's
-- PathFollowingComponent, which cached "no movement component" while the bot was asleep.
local function wake(bot, ctrl)
    local P = _G.PVE_PROF
    if P then P.wakes = (P.wakes or 0) + 1 end
    bot.CustomTimeDilation = 1.0
    ctrl.CustomTimeDilation = 1.0
    local move = bot.CharacterMovement
    move:SetComponentTickEnabled(true)
    move:SetComponentTickInterval(0)
    move:SetMovementMode(1, 0) -- walking
    move.MaxWalkSpeedCrouched = 132 -- was 220, the full walk speed: crouch-walking slid
    -- Asleep, the skeleton doesn't update either (tick off, 1 s interval, bNoSkeletonUpdate): the bot can
    -- still deal damage but never visibly turns, aims or animates.
    local mesh = bot.Mesh
    mesh:SetComponentTickEnabled(true)
    mesh:SetComponentTickInterval(0)
    mesh.bNoSkeletonUpdate = false
    mesh.VisibilityBasedAnimTickOption = 1 -- AlwaysTickPose
    mesh.bEnableUpdateRateOptimizations = false -- URO skipped animation frames: choppy, sluggish-looking bots
    mesh:SetVisibility(true, true)
    -- Helmet / backpack / chest gear are separate skeletal meshes on the body. They follow its animation
    -- through the master pose, but are asleep like the body (tick off, bNoSkeletonUpdate), so their drawn
    -- pose never refreshed and helmets floated in the rest pose.
    local gear = bot:K2_GetComponentsByClass(lib("/Script/Engine.SkeletalMeshComponent"))
    for i = 1, #gear do
        local c = gear[i]:get()
        local parent = c:GetAttachParent()
        if valid(parent) and parent:GetFullName() == mesh:GetFullName() then
            c:SetComponentTickEnabled(true)
            c:SetComponentTickInterval(0)
            c.bNoSkeletonUpdate = false
            c.VisibilityBasedAnimTickOption = 1
            c.bEnableUpdateRateOptimizations = false
            c:SetMasterPoseComponent(mesh, true)
        end
    end
    bot:SetActorHiddenInGame(false)
    bot.bActiveated = true
    ctrl.bActiveated = true
end

-- Shortly after spawning, the bot's own deactivation also unpossesses it and stops its behaviour tree,
-- so arm() runs again from updateBots whenever that has happened (with the controller we kept).
local function arm(bot, ctrl)
    ctrl = ctrl or bot.Controller
    if not valid(ctrl) then return nil end
    wake(bot, ctrl)
    if valid(bot.Controller) then ctrl:UnPossess() end
    ctrl:Possess(bot)
    ctrl.TeamNumber = BOT_TEAM
    -- A bot that spawned asleep never equipped its gun: ShootEnemy then applies damage straight from the
    -- controller with no muzzle flash, sound or tracer. Equipping makes it go through the weapon's fire effects.
    if valid(bot.CurrentWeapon) then bot:ServerEquipWeapon(bot.CurrentWeapon) end
    ctrl:RunBehaviorTree(lib(TREE))
    ctrl.BlackboardComp:SetValueAsBool(FName("IsDeactivated"), false)
    return ctrl
end

local function spawnBot(pc, at, yaw)
    local kind = pickKind()
    local cls = lib(kind.path)
    if not valid(cls) then kind = KINDS[1] cls = lib(kind.path) end
    local bot = lib("/Script/AIModule.Default__AIBlueprintHelperLibrary"):SpawnAIFromClass(pc, cls, lib(TREE),
        { X = at.X, Y = at.Y, Z = at.Z + 100 }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 }, true, pc)
    if not valid(bot) then return nil end
    local ctrl = arm(bot)
    if not ctrl then return nil end
    local personality = AI.pickPersonality(AI.power({}) + kind.power)
    local e = { bot = bot, ctrl = ctrl, home = bot:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(2, 8),
        mind = AI.mind(kind.profile, personality) }
    AI.tuneBody(e)
    local female = math.random() < Rivals.CFG.FEMALE
    e.voice = Voice.pick(female)
    if female then pcall(Female.dress, bot, true) end
    table.insert(raid.bots, e)
    return bot
end

local function botCount()
    if CFG.BOTS > 0 then return CFG.BOTS end
    local gm = FindFirstOf("GameModeBase")
    local n = (gm.NumberNormalAI or 0) + (gm.NumberGuardAI or 0) + (gm.NumberMilitaryAI or 0)
    return n > 0 and n or 8
end

local function spawnRaidBots(pc)
    local player = pc.Pawn:K2_GetActorLocation()
    local nodes = {}
    for _, n in ipairs(FindAllOf("RaidAINodeStart") or {}) do
        local l = n:K2_GetActorLocation()
        if dist(l, player) >= CFG.MIN_SPAWN_DIST then table.insert(nodes, l) end
    end
    if #nodes == 0 then log("no AI nodes far enough from the player") return end
    local want = botCount()
    for i = 1, want do
        local base = nodes[(i - 1) % #nodes + 1]
        -- Several bots per node get spread out a little.
        local a = math.random() * 2 * math.pi
        local at = { X = base.X + math.cos(a) * 150 * math.floor((i - 1) / #nodes),
                     Y = base.Y + math.sin(a) * 150 * math.floor((i - 1) / #nodes), Z = base.Z }
        spawnBot(pc, at, math.random(0, 359))
    end
    log(("spawned %d soldiers at %d AI nodes"):format(#raid.bots, #nodes))
end

-- 3. Awareness --------------------------------------------------------------------------------------
-- The player's character: on space maps the on-foot pawn, which stays at the helm while you fly the ship.
-- Your guns while you ride a pod (see the space branch of the update): hidden and remembered in raid.podGuns.
local POD_GUN_SCANS = { 0, 1, 4, 10 } -- seconds into the flight to look over every gun in the world
local function hidePodGuns(foot, pod)
    local now = os.clock()
    if not raid.podGuns then raid.podGuns, raid.podScans = {}, { at = now, n = 0 } end
    local guns = raid.podGuns
    local function hide(g, why)
        if not valid(g) then return end
        local key = g:GetAddress()
        if not guns[key] then
            if g.bHidden then return end
            guns[key] = g
            log(("pod: hid %s (%s)"):format(g:GetFName():ToString(), why))
        end
        if not g.bHidden then g:SetActorHiddenInGame(true) end
    end
    for _, g in pairs(guns) do if valid(g) and not g.bHidden then g:SetActorHiddenInGame(true) end end
    pcall(function() foot.Inventory:ForEach(function(_, w) hide(w:get(), "carried") end) end)
    pcall(function() hide(foot.CurrentWeapon, "held") end)
    -- the pod gets its own copy of your gun (MyPawn = the pod), drawn huge over it in the pod's camera
    pcall(function() hide(pod.CurrentWeapon, "the pod's") end)
    pcall(function() pod.Inventory:ForEach(function(_, w) hide(w:get(), "the pod's") end) end)
    local scan = POD_GUN_SCANS[raid.podScans.n + 1]
    if not scan or now - raid.podScans.at < scan then return end
    raid.podScans.n = raid.podScans.n + 1
    local me, at = foot:GetAddress(), pod:K2_GetActorLocation()
    for _, g in ipairs(FindAllOf("RaidWeapon") or {}) do
        if valid(g) then
            local owned = false
            local podAt = pod:GetAddress()
            pcall(function() owned = valid(g.MyPawn) and (g.MyPawn:GetAddress() == me or g.MyPawn:GetAddress() == podAt) end)
            if owned then
                hide(g, "yours")
            else
                local l = g:K2_GetActorLocation()
                local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
                if dx * dx + dy * dy + dz * dz < 800 * 800 then hide(g, "on the pod") end
            end
        end
    end
end

local function targetPawn() return valid(raid.target) and raid.target or raid.pawn end

-- Factions: the station's soldiers, each rival crew (e.faction = "crewN", set by rivals.lua), and you. Every faction
-- is hostile to every other one. A bot's foe is kept as an entry (PLAYER or another bot's entry), never as a pawn:
-- reapDead clears a dead bot's entry.bot, so a foe that died reads as gone instead of a freed object.
local PLAYER = { player = true }
local function factionOf(e) return e.faction or "station" end
-- The rivals' edge over station guards (CFG.EDGE_*): which side of it `mine` is on against `theirs`.
local function edge(mine, theirs)
    if mine == "station" and theirs:sub(1, 4) == "crew" then return "guard" end
    if theirs == "station" and mine:sub(1, 4) == "crew" then return "rival" end
end
local function foeOf(e)
    local f = e.foeEntry
    if f == PLAYER then
        local p = targetPawn()
        return (valid(p) and (p.Health or 0) > 0) and p or nil
    end
    if f and f.bot and not f.dead then return f.bot end
    return nil
end

-- A dead bot's pawn is destroyed ~3 s after its death (pve_bodies) and freed by the next garbage collection, up to
-- a minute later. Its entry used to stay in raid.bots with fighting/cover set from its last fight, and the per-frame
-- peek/hide code kept reading the pawn: once freed, that read crashed inside UE4SS (AV at 0xffffffffffffffff in the
-- UObject __index, walking a garbage class chain; even IsValid reads the object's memory). So each frame, before
-- anything else touches the bots, a dead or destroyed bot's entry drops its object references (other modules see
-- valid(e.bot) == false: rivals marks the member killed) and leaves the list.
local function reapDead()
    for i = #raid.bots, 1, -1 do
        local e = raid.bots[i]
        if not valid(e.bot) or (e.bot.Health or 0) <= 0 then
            e.dead, e.bot, e.ctrl, e.hand, e.mesh, e.move = true, nil, nil, nil, nil, nil
            e.fighting, e.inCombat, e.cover, e.investigate, e.holdUntil = false, false, nil, nil, nil
            table.remove(raid.bots, i)
        elseif e.ctrl and not valid(e.ctrl) then
            e.ctrl = valid(e.bot.Controller) and e.bot.Controller or nil
        end
    end
end

local Aux = {} -- helpers (main.lua is at Lua's 200-locals limit)

local function setEnemy(e, pawn)
    local ctrl = e.ctrl
    -- The controller snaps its rotation (and the body, bUseControllerRotationYaw) to its focal point every
    -- tick. Without a gameplay focus it keeps facing a stale point left by the last patrol move.
    ctrl:K2_SetFocus(pawn)
    -- Reaction time (ai.lua profile): facing the target already, but no shooting until it's over
    -- (trackTargets sets the enemy then).
    if e.holdUntil and os.clock() < e.holdUntil then return end
    -- A knife or truncheon only swings once it's in reach (Aux.meleeHints): with an enemy set the tree swings at any range.
    if Aux.isMelee(e) and not e.meleeClose then return end
    ctrl.BlackboardComp:SetValueAsObject(FName("Enemy"), pawn)
    ctrl.MyEnemy = pawn
end

-- 4. Patrols ----------------------------------------------------------------------------------------
-- The behaviour tree only acts once it has an Enemy (it ignores the "destination" key and cancels other
-- moves), so idle soldiers have their tree paused and walk between reachable points around home instead.
local releaseCover -- forward (section 6)

-- Where bots may go on a station. The runtime navmesh covers everything walkable, roofs and the shell around a station
-- included, and nothing in the map says which parts are for play. What does: loot, contract objects, AI nodes and airlocks
-- only sit in played areas, so a point counts when one of those is near it on the same level (bridge/t_nav.lua maps this).
-- Spaceport's sealed basement has an AI node of its own, by the hidden stash contracts, so it's ruled out by hand.
local PLAY_RANGE, PLAY_LEVEL, PLAY_CELL = 1800, 260, 2000
local SEALED = { { x0 = 66500, x1 = 73500, y0 = 19500, y1 = 27000, z1 = -60 } }
local PLAY_MARKS = { "SIGISLootSingleSpawner", "SIGISContractActor", "RaidAINodeStart", "RaidUseableAirLockComponent" }
local STATIONS = { "NavyOutpost", "Spaceport", "Merchant", "Fortress", "MiniMine", "RebelBase", "PenalColony",
    "Asteriod", "MoonBase", "ColonyCruiser", "PlanetKiller" }

local function sealed(p)
    for _, a in ipairs(SEALED) do
        if p.X >= a.x0 and p.X <= a.x1 and p.Y >= a.y0 and p.Y <= a.y1 and p.Z <= a.z1 then return true end
    end
    return false
end

-- Aux: helpers kept in one table, because main.lua is at Lua's limit of 200 locals in a chunk.
function Aux.inBox(b, p) return math.abs(p.X - b.at.X) <= b.ext.X and math.abs(p.Y - b.at.Y) <= b.ext.Y end

-- One marker class into a cell table. Airlocks don't count towards a box being mapped: they're on the hull and load
-- with the outside of the station, before its insides.
function Aux.scan(cls, cells, boxes)
    for _, a in ipairs(FindAllOf(cls) or {}) do
        if valid(a) then
            local l = cls == "RaidUseableAirLockComponent" and a:K2_GetComponentLocation() or a:K2_GetActorLocation()
            if not sealed(l) then
                local key = math.floor(l.X / PLAY_CELL) .. "," .. math.floor(l.Y / PLAY_CELL) -- integer keys: see offLimits
                cells[key] = cells[key] or {}
                table.insert(cells[key], { X = l.X, Y = l.Y, Z = l.Z })
                if cls ~= "RaidUseableAirLockComponent" then
                    for _, b in ipairs(boxes) do
                        if Aux.inBox(b, l) then b.marks = b.marks + 1 end
                    end
                end
            end
        end
    end
end

-- Once per raid, under the loading veil: five object scans. In space a station's insides stream in only as you come
-- close, so this first scan can miss its loot and AI nodes (Rebel Base, 2026-11-14: every baked cover spot in it was
-- thrown out as off limits). A box with none counts as unmapped, and Aux.rescan() maps it again once you're aboard.
function Aux.mapPlayAreas()
    local play = { boxes = {}, cells = {} }
    for _, v in ipairs(FindAllOf("LevelStreamingVolume") or {}) do
        if valid(v) then
            local name = v:GetFName():ToString()
            for _, key in ipairs(STATIONS) do
                if name:find(key, 1, true) then
                    local at, ext = {}, {}
                    Out.call(v, "GetActorBounds", false, at, ext, false)
                    table.insert(play.boxes, { at = at, ext = ext, name = key, marks = 0 })
                end
            end
        end
    end
    for _, cls in ipairs(PLAY_MARKS) do Aux.scan(cls, play.cells, play.boxes) end
    raid.play = play
    local counts = {}
    for _, b in ipairs(play.boxes) do counts[#counts + 1] = b.name .. " " .. b.marks end
    log("play areas: markers per station box: " .. table.concat(counts, ", "))
end

-- On foot inside a station box for the first time: scan the markers again, one class per frame (each scan is a
-- FindAllOf, ~50 ms on a big map), and swap the new cells in at the end.
function Aux.rescan(at)
    local play = raid.play
    local job = play.job
    if not job then
        for _, b in ipairs(play.boxes) do
            if not b.rescanned and Aux.inBox(b, at) then
                b.rescanned = true
                local boxes = {}
                for i, o in ipairs(play.boxes) do boxes[i] = { at = o.at, ext = o.ext, marks = 0 } end
                play.job = { name = b.name, i = 1, cells = {}, boxes = boxes }
                return
            end
        end
        return
    end
    Aux.scan(PLAY_MARKS[job.i], job.cells, job.boxes)
    job.i = job.i + 1
    if job.i > #PLAY_MARKS then
        play.cells, play.job = job.cells, nil
        local counts = {}
        for i, b in ipairs(play.boxes) do
            b.marks = job.boxes[i].marks
            counts[#counts + 1] = b.name .. " " .. b.marks
        end
        log(("play areas: rescanned on boarding %s: %s"):format(job.name, table.concat(counts, ", ")))
    end
end

local function offLimits(p)
    if not (raid.space and raid.play) or sealed(p) then return raid.space and sealed(p) or false end
    local inside = nil
    for _, b in ipairs(raid.play.boxes) do
        if Aux.inBox(b, p) then inside = b break end
    end
    if not inside then return false end -- ships and everything else off the stations
    if inside.marks == 0 then return false end -- not streamed in when scanned: can't tell, so nothing is ruled out
    -- math.floor, not //: a float's // is a float ("26.0") and an integer's an integer ("26"), so a baked cover spot
    -- (whole numbers from cover/*.txt) never found the markers filed under the engine's float positions. Every baked
    -- spot was off limits on every station (Rebel Base, Space_Alpha, 2026-11-14: "off 40" of 40).
    local cx, cy = math.floor(p.X / PLAY_CELL), math.floor(p.Y / PLAY_CELL)
    for gx = cx - 1, cx + 1 do
        for gy = cy - 1, cy + 1 do
            for _, m in ipairs(raid.play.cells[gx .. "," .. gy] or {}) do
                if math.abs(m.Z - p.Z) <= PLAY_LEVEL and (m.X - p.X) ^ 2 + (m.Y - p.Y) ^ 2 <= PLAY_RANGE ^ 2 then return false end
            end
        end
    end
    return true
end

local function patrol(e)
    local now = os.clock()
    if e.cover then releaseCover(e) end
    if e.ctrl.BrainComponent:IsRunning() then e.ctrl.BrainComponent:StopLogic("patrol") end
    if now < e.nextPatrol or e.ctrl:GetMoveStatus() == 3 then return end -- 3 = Moving
    local dest = {}
    Out.call(navLib(), "K2_GetRandomReachablePointInRadius", e.ctrl, e.home, dest, e.patrolRadius or CFG.PATROL_RADIUS,
        navMesh(), queryFilter())
    if dest.X and not offLimits(dest) then
        e.ctrl:MoveToLocation(dest, 60, false, true, false, true, queryFilter(), true)
    end
    e.nextPatrol = now + math.random(CFG.PATROL_PAUSE[1], CFG.PATROL_PAUSE[2])
end

local function engage(e, pawn, entry)
    e.foeEntry = entry or PLAYER
    e.inCombat = true
    e.investigate = nil
    e.holdUntil = os.clock() + AI.reactionTime(e)
    e.ctrl:StopMovement()
    if not e.ctrl.BrainComponent:IsRunning() then
        e.ctrl:RunBehaviorTree(lib(TREE))
        e.ctrl.BlackboardComp:SetValueAsBool(FName("IsDeactivated"), false)
    end
    setEnemy(e, pawn)
end

-- In combat is tracked here, not by the blackboard: hiding soldiers have their Enemy key cleared so the
-- tree stops shooting into their cover.
local function engaged(e)
    return e.inCombat == true
end

local function reachableNear(e, origin, radius)
    local out = {}
    if Out.call(navLib(), "K2_GetRandomReachablePointInRadius", e.ctrl, origin, out, radius, navMesh(),
        queryFilter()) and not offLimits(out) then return out end
    return nil
end

-- 4b. Noises -----------------------------------------------------------------------------------------
-- A noise heard at peace (footsteps, gunfire; ai.lua gives a position that's off by more the farther it was).
-- The personality decides the heard-from-peace reaction: charge (fight now), or freeze and watch where it came
-- from for a while, then go and look (if it's the kind that looks), look around there, and go back to patrolling.
local function hearNoise(e, pawn, at, kind, now)
    local p = e.mind.personality
    if p.heard == "charge" then
        engage(e, pawn, e.heardEntry)
        e.lastSeen = at
        log(("%s (%s) heard %s and charges"):format(e.bot:GetFName():ToString(), AI.describe(e), kind))
        return
    end
    local inv = e.investigate
    if inv and inv.state ~= "look" then inv.at = at return end -- a newer noise updates where to go
    e.investigate = { at = at, state = "freeze", ["until"] = now + (p.heard == "freeze" and AI.freezeTime(e) or 0) }
    e.ctrl:StopMovement()
    log(("%s (%s) heard %s"):format(e.bot:GetFName():ToString(), AI.describe(e), kind))
end

local function endInvestigation(e)
    e.investigate = nil
    if e.bot.bIsCrouched then e.bot:UnCrouch(false) end
    e.ctrl:K2_ClearFocus()
    e.nextPatrol = os.clock() + math.random(1, 4)
end

local function investigate(e, now)
    local inv, p = e.investigate, e.mind.personality
    if e.cover then releaseCover(e) end
    if e.ctrl.BrainComponent:IsRunning() then e.ctrl.BrainComponent:StopLogic("investigate") end
    if inv.state == "freeze" then
        e.ctrl:K2_SetFocalPoint({ X = inv.at.X, Y = inv.at.Y, Z = inv.at.Z + CFG.EYE_STAND })
        if p.sneaky and not e.bot.bIsCrouched then e.bot:Crouch(false) end
        if now < inv["until"] then return end
        if not p.search then return endInvestigation(e) end
        local dest = reachableNear(e, inv.at, 250)
        if not dest then return endInvestigation(e) end
        inv.state, inv.dest, inv.run = "go", dest, math.random() < p.sprintSearch
        if e.bot.bIsCrouched and not p.sneaky then e.bot:UnCrouch(false) end
        e.ctrl:K2_ClearFocus()
        e.ctrl:MoveToLocation(dest, 80, false, true, false, true, queryFilter(), true)
    elseif inv.state == "go" then
        local d = dist2d(e.bot:K2_GetActorLocation(), inv.dest)
        -- sneaky personalities crouch-walk the last stretch, everyone else walks or runs
        if p.sneaky then
            local want = d < 1200
            if want ~= e.bot.bIsCrouched then if want then e.bot:Crouch(false) else e.bot:UnCrouch(false) end end
        end
        if e.ctrl:GetMoveStatus() ~= 3 then
            inv.state, inv["until"], inv.nextLook = "look", now + rnd(CFG.LOOK_AROUND), 0
        end
    else -- look around where it came from
        if now >= inv.nextLook then
            local here, a = e.bot:K2_GetActorLocation(), math.random() * 2 * math.pi
            e.ctrl:K2_SetFocalPoint({ X = here.X + math.cos(a) * 800, Y = here.Y + math.sin(a) * 800,
                Z = here.Z + CFG.EYE_STAND - 90 })
            inv.nextLook = now + 1 + math.random() * 1.5
        end
        if now >= inv["until"] then endInvestigation(e) end
    end
end

-- The tree's own LoS service, "find point near enemy" and cover EQS all come back empty offline
-- (destination/CoverEQsResult stay at FLT_MAX, HasLosToEnemy false), so it retries a move to nowhere every
-- frame: crouching and walking on the spot. Feed it what it expects.
-- 6. Cover ------------------------------------------------------------------------------------------
-- The game's cover system (CoverGenerator, cover EQS) is server-side content that doesn't exist offline, and a
-- spawned CoverGenerator generates nothing. So cover is found with line-of-sight probes from candidate spots,
-- and soldiers cycle hide → lean out and shoot → hide. ARaidCharacter:ServerLean: 1 = left (-40), 2 = right (+40).
local LEAN_NONE, LEAN_LEFT, LEAN_RIGHT = 0, 1, 2


local function sees(ctrl, pawn, from) return ctrl:LineOfSightTo(pawn, from, false) end

local function claimed(e, at)
    if e.avoidCover and dist2d(e.avoidCover, at) < CFG.COVER_MOVE_MIN then return true end
    for _, o in ipairs(raid.bots) do
        if o ~= e and o.cover and dist2d(o.cover.pos, at) < 150 then return true end
    end
    return false
end

-- Nearest navmesh point to a spot, or nil (a firing point off the walkable area is no use).
local function walkable(e, at)
    local out = {}
    if Out.call(navLib(), "K2_ProjectPointToNavigation", e.ctrl, at, out, navMesh(), queryFilter(),
        { X = 30, Y = 30, Z = 150 }) then return out end
    return nil
end

-- Probes one floor spot; returns a cover description or nil.
local function probeCover(e, pawn, playerLoc, p)
    local d = dist2d(p, playerLoc)
    if d < CFG.COVER_PLAYER_DIST[1] or d > CFG.COVER_PLAYER_DIST[2] or claimed(e, p) then return nil end
    local fx, fy = (playerLoc.X - p.X) / d, (playerLoc.Y - p.Y) / d
    local rx, ry = -fy, fx -- right of "facing the player" (UE: X forward, Y right)
    local stand = { X = p.X, Y = p.Y, Z = p.Z + CFG.EYE_STAND }
    local why = "exposed"
    if not sees(e.ctrl, pawn, stand) then
        local options = {}
        -- The shortest step out on each side that sees the player (the wall's edge is rarely exactly 60 away).
        for _, side in ipairs({ LEAN_LEFT, LEAN_RIGHT }) do
            for _, step in ipairs(CFG.PEEK_STEPS) do
                local o = (side == LEAN_LEFT) and -step or step
                local spot = walkable(e, { X = p.X + rx * o, Y = p.Y + ry * o, Z = p.Z })
                if spot and dist2d(spot, p) > step * 0.6
                    and sees(e.ctrl, pawn, { X = spot.X, Y = spot.Y, Z = spot.Z + CFG.EYE_STAND }) then
                    table.insert(options, { side = side, peekPos = spot })
                    break
                end
            end
        end
        if #options == 0 then return nil, "no peek" end
        local pick = options[math.random(1, #options)]
        return { pos = p, low = false, side = pick.side, peekPos = pick.peekPos }
    end
    if not sees(e.ctrl, pawn, { X = p.X, Y = p.Y, Z = p.Z + CFG.EYE_CROUCH }) then
        return { pos = p, low = true, side = LEAN_NONE }
    end
    return nil, why
end

-- Baked cover spots (cover.lua) that block towards the player come first, nearest (plus personality) first; only a few
-- get the real line-of-sight probe. Random reachable points are the fallback while the cells around are still baking.
-- Bold personalities favour spots nearer the player, timid ones spots farther back.
local function findCover(e, pawn, playerLoc, radius, tries)
    local here = e.bot:K2_GetActorLocation()
    local aggr = e.mind and e.mind.personality.aggression or 1
    local function score(p, low)
        return dist2d(here, p) + (low and CFG.LOW_COVER_PENALTY or 0)
            + (aggr - 1) * CFG.COVER_AGGRESSION_PULL * dist2d(p, playerLoc)
    end
    local list = {}
    -- what the search turned down, for the log when it finds nothing (coverCycle's Aux.openLog)
    local st = { baked = 0, off = 0, ["out of range"] = 0, random = 0 }
    -- offLimits keeps soldiers off roofs and hull shells, but it judges by loot and AI nodes nearby on the same level,
    -- and some played floors have none within reach (Penal Colony, 2026-11-14: the nearest 12 m up). A soldier
    -- already standing somewhere it calls off limits is on such a floor: don't filter the spots around it.
    local filter = not offLimits(here)
    for _, c in ipairs(raid.coverNoBake and {} or Cover.candidates(here, playerLoc, radius, CFG.COVER_BAKED_POOL)) do
        st.baked = st.baked + 1
        if not (filter and offLimits(c.pos)) then
            c.score = score(c.pos, c.low)
            list[#list + 1] = c
        else
            st.off = st.off + 1
        end
    end
    table.sort(list, function(a, b) return a.score < b.score end)
    local probes = 0
    for _, c in ipairs(list) do
        if probes >= CFG.COVER_BAKED_PROBES then break end
        local d = dist2d(playerLoc, c.pos)
        if d >= CFG.COVER_PLAYER_DIST[1] and d <= CFG.COVER_PLAYER_DIST[2] and not claimed(e, c.pos) then
            probes = probes + 1
            local got, why = probeCover(e, pawn, playerLoc, c.pos)
            if got and Aux.longWay(e, here, c.pos) then got, why = nil, "long way round" end
            local pr = raid.coverProbe or {}
            raid.coverProbe = pr
            local k = got and "ok" or why or "?"
            pr[k] = (pr[k] or 0) + 1
            st[k] = (st[k] or 0) + 1
            if got then got.baked = true return got end
        else
            st["out of range"] = st["out of range"] + 1
        end
    end
    local best, bestD
    for _ = 1, math.max(1, math.floor(tries * (#list > 0 and CFG.COVER_RANDOM_SHARE or 1))) do
        local p = reachableNear(e, here, radius)
        if p then
            st.random = st.random + 1
            local c, why = probeCover(e, pawn, playerLoc, p)
            local d = c and score(p, c.low)
            if c and (not best or d < bestD) then best, bestD = c, d end
            if not c then
                local k = "random " .. (why or "out of range")
                st[k] = (st[k] or 0) + 1
            end
        end
    end
    if best and Aux.longWay(e, here, best.pos) then
        best = nil
        st["random long way round"] = (st["random long way round"] or 0) + 1
    end
    return best, st
end

-- Why a fighting soldier is in the open: tallied for the status line, and logged per soldier at most every
-- CFG.OPEN_LOG_SECONDS (st: findCover's counts, nil when it chose not to look).
function Aux.openLog(e, now, why, st)
    raid.openWhy = raid.openWhy or {}
    raid.openWhy[why] = (raid.openWhy[why] or 0) + 1
    if now < (e.openLogAt or 0) then return end
    e.openLogAt = now + CFG.OPEN_LOG_SECONDS
    local parts = {}
    for k, v in pairs(st or {}) do if v > 0 then parts[#parts + 1] = k .. " " .. v end end
    table.sort(parts)
    log(("%s fighting in the open: %s, %s%s"):format(e.bot:GetFName():ToString(), why,
        e.los and "in sight" or "target unseen", #parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""))
end

-- Is the soldier at its cover spot exposed while it should be hidden (the player flanked it)?
local function exposed(e, pawn, c)
    local h = c.low and CFG.EYE_CROUCH or CFG.EYE_STAND
    return sees(e.ctrl, pawn, { X = c.pos.X, Y = c.pos.Y, Z = c.pos.Z + h })
end

releaseCover = function(e, why)
    e.nextCover = nil
    if e.cover then
        e.bot:ServerLean(LEAN_NONE)
        if e.inCombat and foeOf(e) then setEnemy(e, foeOf(e)) end
        if why then log(("%s left cover (%s, was %s)"):format(e.bot:GetFName():ToString(), why, e.cover.state)) end
    end
    e.cover = nil
end

-- The tree shoots at its Enemy regardless of sight, and the controller at MyEnemy: clear both to hold fire.
local function holdFire(e)
    e.ctrl.BlackboardComp:ClearValue(FName("Enemy"))
    e.ctrl.MyEnemy = nil
end

local function strafeTo(e, at)
    e.ctrl:MoveToLocation(at, 15, false, true, true, true, queryFilter(), true)
end

local function hide(e, c, now)
    if c.state == "peeking" then c.blindPeeks = c.peekSaw and 0 or (c.blindPeeks or 0) + 1 end
    c.peekSaw = false
    e.bot:ServerLean(LEAN_NONE)
    holdFire(e)
    if c.peekPos and c.state == "peeking" then strafeTo(e, c.pos) end
    if c.low then e.bot:Crouch(false) else e.bot:UnCrouch(false) end
    c.state, c["until"] = "hiding", now + rnd(CFG.HIDE_SECONDS)
end

local function peek(e, c, now)
    e.bot:UnCrouch(false)
    if foeOf(e) then setEnemy(e, foeOf(e)) end
    if not c.low then
        e.bot:ServerLean(c.side) -- looks right; the step out is what lets it actually fire
        strafeTo(e, c.peekPos)
    end
    c.state, c["until"] = "peeking", now + rnd(CFG.PEEK_SECONDS)
end

-- Runs the cover behaviour; returns false when there's no usable cover (the caller falls back to strafing).
local function coverCycle(e, pawn, playerLoc, now)
    local c = e.cover
    if c and c.state == "hiding" and (c.blindPeeks or 0) >= CFG.COVER_BLIND_PEEKS then
        -- Its peeks keep finding nothing: the player has moved to an angle this spot doesn't cover. Look for a spot
        -- that covers the new angle (a different one: the search used to hand back the one it was in); if there's
        -- none (the player is out of sight from everywhere around), stay put and keep watching.
        e.avoidCover = c.pos
        local ok, alt = pcall(findCover, e, pawn, playerLoc, CFG.COVER_SEARCH, CFG.COVER_CANDIDATES)
        e.avoidCover = nil
        if ok and alt and e.los and dist2d(e.bot:K2_GetActorLocation(), alt.pos) > CFG.EXPOSED_COVER_DIST then alt = nil end
        if ok and alt then
            releaseCover(e, "angle lost")
            e.nextCover, c = alt, nil
        else
            c.blindPeeks = 0
        end
    elseif c and c.state == "hiding" and exposed(e, pawn, c) then
        releaseCover(e, "flanked")
        c = nil
    end
    local justHurt = e.hurtAt and now - e.hurtAt < CFG.HURT_DUCK_SECONDS
    if c and c.state == "peeking" and justHurt then
        hide(e, c, now) -- shot while leaning out: duck back in
        return true
    end
    if not c and e.nextCover then -- moving on to the spot picked when the last one's time ran out
        c, e.nextCover = e.nextCover, nil
    elseif not c then
        if justHurt then e.openUntil, e.nextCoverSearch = 0, 0 end -- shot in the open: think about cover now
        if now < (e.nextCoverSearch or 0) or now < (e.openUntil or 0) then return false end
        e.nextCoverSearch = now + CFG.COVER_RETRY
        -- Does it want cover at all? Bold personalities would rather keep shooting.
        local p = e.mind and e.mind.personality
        local hold = p and p.holdGround or 1
        -- chance ^ aggression: 0.95 is ~0.93 for a GigaChad (1.5) and ~0.86 for a Wreckless (3)
        if math.random() >= (justHurt and CFG.COVER_HURT_CHANCE or CFG.COVER_SEEK_CHANCE) ^ (p and p.aggression or 1) then
            e.openUntil = now + CFG.OPEN_FIGHT_SECONDS * hold
            Aux.openLog(e, now, "chose not to look for cover")
            return false
        end
        -- Cover first, but a soldier in the player's sight only runs for cover close by; out of sight it can
        -- look further. With nothing quick, it strafes and shoots for a while (OPEN_FIGHT_SECONDS).
        local here = e.bot:K2_GetActorLocation()
        local st, why
        c, st = findCover(e, pawn, playerLoc, CFG.COVER_SEARCH, CFG.COVER_CANDIDATES)
        if e.los then
            if c and dist2d(here, c.pos) > CFG.EXPOSED_COVER_DIST then c, why = nil, "nearest cover too far to run in sight" end
        elseif not c then
            c, st = findCover(e, pawn, playerLoc, CFG.COVER_SEARCH_FAR, CFG.COVER_CANDIDATES_FAR)
        end
        if not c then
            e.openUntil = now + CFG.OPEN_FIGHT_SECONDS * hold
            Aux.openLog(e, now, why or "no cover found", st)
            return false
        end
    end
    if not e.cover then -- a new spot: go there
        c.started = now
        c.state = "moving"
        local here = e.bot:K2_GetActorLocation()
        local far = dist2d(here, c.pos)
        c.run = math.random() < (e.los and CFG.SPRINT_EXPOSED_CHANCE or CFG.SPRINT_UNSEEN_CHANCE)
            and far > CFG.COVER_MOVE_MIN -- no sprinting a couple of steps
        -- A spot behind it, walked to while facing the enemy, was a long slow backpedal that rarely got there
        -- (2026-11-14): turn and run instead.
        local toP = dist2d(here, playerLoc)
        if not c.run and far > CFG.COVER_MOVE_MIN and toP > 1 then
            local cos = ((c.pos.X - here.X) * (playerLoc.X - here.X) + (c.pos.Y - here.Y) * (playerLoc.Y - here.Y))
                / (far * toP)
            if cos < -CFG.COVER_BACK_RUN then c.run, c.back = true, true end
        end
        c.left, c.retries = far, 0
        e.cover = c
        -- Sprinting: weapon down, no shooting on the way, facing the path. Otherwise it walks there, still focused on
        -- its enemy, so the tree keeps shooting and the move stays a strafe (trackTargets keeps the focus).
        if c.run then
            holdFire(e)
            e.ctrl:K2_ClearFocus()
        end
        log(("%s %s to %s %s cover %.0f away"):format(e.bot:GetFName():ToString(),
            c.back and "turning to run back" or c.run and "sprinting" or "firing on the way",
            c.baked and "baked" or "random", c.low and "low" or (c.side == LEAN_LEFT and "lean-left" or "lean-right"), far))
        e.bot:UnCrouch(false)
        e.ctrl:MoveToLocation(c.pos, 30, false, true, true, true, queryFilter(), true)
        return true
    end
    if c.state == "moving" then
        if c.run and e.los and now - c.started > CFG.EXPOSED_RUN_SECONDS then
            releaseCover(e, "too long running in sight")
            e.openUntil = now + CFG.OPEN_FIGHT_SECONDS * (e.mind and e.mind.personality.holdGround or 1)
            e.nextHint = 0 -- start strafing right away
            return false
        end
        if e.ctrl:GetMoveStatus() ~= 3 then -- arrived, or the move ended
            local off = dist2d(e.bot:K2_GetActorLocation(), c.pos)
            -- Moves to cover often ended hundreds of units short (the tree, or the stuck check below), and the soldier
            -- gave up and started over somewhere else. Send it again while it's still gaining ground.
            local stuck = e.stuckAt and now - e.stuckAt < 0.5
            if off > 150 and c.retries < CFG.COVER_MOVE_RETRIES and c.left - off > 100 then
                c.retries, c.left = c.retries + 1, off
                log(("%s move to cover ended %.0f short%s: sent again"):format(e.bot:GetFName():ToString(), off,
                    stuck and " (stuck)" or ""))
                e.ctrl:MoveToLocation(c.pos, 30, false, true, true, true, queryFilter(), true)
                return true
            end
            if off > 150 then
                releaseCover(e, ("move ended %.0f short%s"):format(off, stuck and ", stuck" or ""))
                return false
            end
            hide(e, c, now)
        end
        return true
    end
    -- (animate() holds the posture each phase wants, every frame.)
    if now >= c["until"] then
        if c.state == "hiding" then peek(e, c, now) else hide(e, c, now) end
    end
    return true
end

local function soldierSees(e, pawn)
    return e.ctrl:LineOfSightTo(pawn, { X = 0, Y = 0, Z = 0 }, false)
end

-- A side-step across the player's line of fire (a random nearby point is often a single step away).
local function strafePoint(e, playerLoc)
    local here = e.bot:K2_GetActorLocation()
    local d = dist2d(here, playerLoc)
    if d < 1 then return reachableNear(e, here, CFG.STRAFE_DIST[2]) end
    local rx, ry = -(playerLoc.Y - here.Y) / d, (playerLoc.X - here.X) / d
    local side = math.random(0, 1) == 0 and -1 or 1
    for _ = 1, 4 do
        local step = rnd(CFG.STRAFE_DIST) * side
        local p = walkable(e, { X = here.X + rx * step, Y = here.Y + ry * step, Z = here.Z })
        if p and dist2d(p, here) > 150 and not offLimits(p) then return p end
        side = -side
    end
    return reachableNear(e, here, CFG.STRAFE_DIST[2])
end

-- Out of sight: close in on where the target was last seen. The soldier keeps its focus on the target while it walks,
-- so a point behind it is a slow walk backwards (seen 2026-11-14): of a few points near that spot take the nearest to
-- it, and only if it's actually nearer than where the soldier stands; otherwise hold and watch.
function Aux.advancePoint(e, goal)
    local here = e.bot:K2_GetActorLocation()
    local cur = dist2d(here, goal)
    local best, bestD
    for _ = 1, 3 do
        local p = reachableNear(e, goal, CFG.ADVANCE_RADIUS)
        local d = p and dist2d(p, goal)
        if d and (not best or d < bestD) then best, bestD = p, d end
    end
    if best and bestD < cur - 100 then return best end
    return nil
end

-- Knife and truncheon soldiers (weapons on Weap_Knife_C): cached per held weapon.
function Aux.isMelee(e)
    local w = e.bot and e.bot.CurrentWeapon
    if not valid(w) then return e.melee end
    local a = w:GetAddress()
    if a ~= e.meleeW then
        e.meleeW, e.melee = a, false
        pcall(function()
            local c = w:GetClass()
            for _ = 1, 10 do
                if not valid(c) then break end
                if c:GetFName():ToString() == "Weap_Knife_C" then e.melee = true break end
                c = c:GetSuperStruct()
            end
        end)
    end
    return e.melee
end

-- The tree swings at its Enemy at any range, and the gunman's hints (cover, strafing) only walked melee soldiers
-- around swinging at the air (seen 2026-11-14). They charge instead: run at the target (or where it was last seen),
-- with no Enemy set until within CFG.MELEE_REACH. Returns true when it handled the soldier.
function Aux.meleeHints(e, pawn, playerLoc, los, now)
    if not Aux.isMelee(e) then
        e.meleeClose, e.meleeRun = nil, nil
        return false
    end
    if e.cover then releaseCover(e, "melee") end
    local here = e.bot:K2_GetActorLocation()
    local d = dist2d(here, playerLoc)
    local close = math.abs(here.Z - playerLoc.Z) < 200 and d < (e.meleeClose and CFG.MELEE_LET_GO or CFG.MELEE_REACH)
    if close and not e.meleeClose then
        e.meleeClose = true
        setEnemy(e, pawn)
    elseif not close then
        e.meleeClose = false
    end
    e.meleeRun = d > CFG.MELEE_RUN
    e.standUntil, e.crouchSince = now + 1, nil
    if now >= (e.nextHint or 0) then
        e.nextHint = now + 0.4
        if not close then
            holdFire(e) -- trackTargets or the tree may have set it again
            e.ctrl:MoveToLocation(los and playerLoc or e.lastSeen or playerLoc, 60, false, true, true, true, queryFilter(), true)
        end
    end
    return true
end

-- Length of the walk from one point to another (nil when unknown), and whether the path stops short.
function Aux.pathLen(e, from, to)
    local ok, len, partial = pcall(function()
        local p = navLib():FindPathToLocationSynchronously(e.ctrl, from, to, e.bot, nil)
        if not valid(p) then return nil end
        return p:GetPathLength(), p:IsPartial()
    end)
    if ok then return len, partial end
    return nil
end

-- A cover spot near in a straight line can be a long walk round (another room or floor): the soldier then ran away
-- from the fight towards it (seen 2026-11-14: a spot 611 away, the move ended 2727 short).
function Aux.longWay(e, here, to)
    local len, partial = Aux.pathLen(e, here, to)
    if not len then return false end
    return partial or len > dist2d(here, to) * CFG.COVER_PATH_STRETCH + CFG.COVER_PATH_SLACK
end

local function combatHints(e, pawn, playerLoc)
    local bb, ctrl = e.ctrl.BlackboardComp, e.ctrl
    local los = soldierSees(e, pawn)
    bb:SetValueAsBool(FName("HasLosToEnemy"), los)
    ctrl.bCanSeePlayer = los
    e.los = los -- trackTargets() keeps LastKnownPlayerPosition current every frame while this holds
    if los and e.cover and e.cover.state == "peeking" then e.cover.peekSaw = true end
    if los then e.lastSeen = playerLoc end
    local now = os.clock()
    local v = e.bot:GetVelocity()
    if los and not e.losSince then e.losSince = now elseif not los then e.losSince = nil end
    if e.mind then
        local tv = pawn:GetVelocity()
        e.bot.AIMissRate = AI.aimFor(e, now, { skillSpread = CFG.AIM_SKILL_SPREAD, streak = CFG.AIM_STREAK,
            streakSeconds = CFG.AIM_STREAK_SECONDS, settleSeconds = CFG.AIM_SETTLE_SECONDS,
            settlePenalty = CFG.AIM_SETTLE_PENALTY, movingPenalty = CFG.AIM_MOVING,
            targetMovingPenalty = CFG.AIM_TARGET_MOVING, hurtPenalty = CFG.AIM_UNDER_FIRE,
            hurtSeconds = CFG.AIM_UNDER_FIRE_SECONDS, rangePer10m = CFG.AIM_RANGE_PER_10M, maxMiss = CFG.AIM_MISS_MAX,
            moving = v.X * v.X + v.Y * v.Y > 2500, targetMoving = tv.X * tv.X + tv.Y * tv.Y > 2500,
            distance = dist2d(e.bot:K2_GetActorLocation(), playerLoc), losSince = e.losSince, hurtAt = e.hurtAt })
        local f = e.foeEntry
        local side = f and f ~= PLAYER and edge(factionOf(e), factionOf(f))
        if side then
            e.bot.AIMissRate = math.min(CFG.AIM_MISS_MAX,
                e.bot.AIMissRate * (side == "guard" and CFG.EDGE_GUARD_MISS or CFG.EDGE_RIVAL_MISS))
        end
    end

    -- A move that barely progresses (blocked by geometry or another soldier) looks like walking on the spot.
    if ctrl:GetMoveStatus() == 3 and math.sqrt(v.X * v.X + v.Y * v.Y) < CFG.STUCK_SPEED then
        e.slowSince = e.slowSince or now
        if now - e.slowSince >= CFG.STUCK_SECONDS then
            ctrl:StopMovement()
            e.slowSince, e.nextHint, e.stuckAt = nil, now + 0.5, now
        end
    else
        e.slowSince = nil
    end

    if Aux.meleeHints(e, pawn, playerLoc, los, now) then return end
    Cover.want(e.bot:K2_GetActorLocation(), CFG.COVER_SEARCH_FAR)
    if coverCycle(e, pawn, playerLoc, now) then
        e.standUntil, e.crouchSince = nil, nil -- cover decides the posture
        return
    end

    -- No cover: limit the tree's crouch-peeking (animate() keeps the soldier standing until standUntil).
    if e.bot.bIsCrouched and not e.standUntil then
        e.crouchSince = e.crouchSince or now
        if now - e.crouchSince >= CFG.CROUCH_MAX then
            e.standUntil, e.crouchSince = now + CFG.CROUCH_COOLDOWN, nil
        end
    elseif not e.bot.bIsCrouched then
        e.crouchSince = nil
    end
    if e.standUntil and now >= e.standUntil then e.standUntil = nil end
    if now >= (e.nextHint or 0) then
        local here = e.bot:K2_GetActorLocation()
        -- Without sight of the player, close in on where they were last seen; with it, strafe quickly.
        local dest = los and strafePoint(e, playerLoc)
            or Aux.advancePoint(e, e.lastSeen or playerLoc)
        if dest then
            bb:SetValueAsVector(FName("destination"), dest)
            bb:SetValueAsVector(FName("CoverEQsResult"), dest)
            -- The tree itself never moves once it has sight (it only shoots and crouch-peeks), but it lets a
            -- strafing move run: the soldier keeps its focus, so it keeps facing and shooting the player.
            ctrl:MoveToLocation(dest, 40, false, true, true, true, queryFilter(), true)
        end
        e.nextHint = now + (los and rnd(CFG.STRAFE_SECONDS)
            or math.random(CFG.REPOSITION_SECONDS[1], CFG.REPOSITION_SECONDS[2]))
    end
end

-- Distant bots: wake() makes every bot tick its pose every frame even unseen, with update-rate optimisation off (asleep
-- bots never turned or aimed, and URO made near ones choppy). With a garrison and docked crews that's dozens of
-- skeletons evaluated each frame while you fly kilometres away. Past ANIM_FAR from the camera they go back to the
-- engine's cheaper way: montages only while not drawn, URO on. They still move, fight and take damage.
local ANIM_FAR_FLAG = PROJECT .. "bridge/anim_far_on" -- NOT on by default yet (untested with a garrison): present = on
local function animDistance(e, cam, farOn)
    local far = farOn and dist(e.bot:K2_GetActorLocation(), cam) > CFG.ANIM_FAR
    if far == e.animFar then return end
    e.animFar = far
    local mesh = e.bot.Mesh
    mesh.VisibilityBasedAnimTickOption = far and 2 or 1 -- OnlyTickMontagesWhenNotRendered / AlwaysTickPose
    mesh.bEnableUpdateRateOptimizations = far
    local P = _G.PVE_PROF
    if P then P.animSwitch = (P.animSwitch or 0) + 1 end
end

local function updateBots(pc)
    -- On space maps the target is your on-foot character, which stays at the helm while you fly the ship.
    local pawn = valid(raid.target) and raid.target or pc.Pawn
    local alive = valid(pawn) and (pawn.Health or 0) > 0
    local playerLoc = alive and pawn:K2_GetActorLocation() or nil
    reapDead()
    local cam
    pcall(function() cam = pc.PlayerCameraManager:GetCameraLocation() end)
    raid.camAt = cam or playerLoc
    local farOn = false
    local ff = io.open(ANIM_FAR_FLAG, "r")
    if ff then ff:close() farOn = true end
    -- Cover is baked around you on foot (fights happen near you) and around every fighting soldier (combatHints).
    if playerLoc and raid.navReady and valid(pc.Pawn) and pc.Pawn:GetAddress() == pawn:GetAddress() then
        Cover.want(playerLoc, CFG.COVER_BAKE_RADIUS)
    end
    -- Everyone who can be fought: you, and every live bot (by faction).
    local bodies = {}
    if alive then bodies[1] = { entry = PLAYER, pawn = pawn, at = playerLoc, faction = "player" } end
    for _, o in ipairs(raid.bots) do
        if valid(o.bot) and (o.bot.Health or 0) > 0 then
            bodies[#bodies + 1] = { entry = o, pawn = o.bot, at = o.bot:K2_GetActorLocation(), faction = factionOf(o) }
        end
    end
    for _, e in ipairs(raid.bots) do
        if valid(e.bot) and valid(e.ctrl) and (e.bot.Health or 0) > 0 then
            local foe = foeOf(e)
            if e.inCombat and not foe then
                -- whoever it was fighting is dead or gone: back to searching
                e.inCombat, e.foeEntry, e.cover = false, nil, nil
                pcall(function() holdFire(e) end)
            end
            local fighting = engaged(e)
            -- Re-arm a bot the game put back to sleep. A stopped tree only counts while fighting:
            -- patrolling bots have it stopped on purpose.
            if not valid(e.bot.Controller) or (fighting and not e.ctrl.BrainComponent:IsRunning()) then
                e.rearms = (e.rearms or 0) + 1
                -- arm() puts a bot on the soldiers' team: rivals and your crew keep their own
                local team = e.faction and e.ctrl.TeamNumber
                if e.rearms <= 20 then
                    arm(e.bot, e.ctrl)
                    if team and valid(e.ctrl) then e.ctrl.TeamNumber = team end
                end
                if e.rearms == 20 then log("giving up re-arming " .. e.bot:GetFName():ToString()) end
            elseif e.bot.CustomTimeDilation < 1 or not e.bot.Mesh:IsComponentTickEnabled() then
                wake(e.bot, e.ctrl)
            end
            if cam then
                if e.bot.Mesh.VisibilityBasedAnimTickOption == 1 and e.animFar then e.animFar = nil end -- woken again
                animDistance(e, cam, farOn)
            end
            local hp = e.bot.Health
            local hurt = e.hp ~= nil and hp < e.hp
            e.hp = hp
            local now = os.clock()
            if hurt then
                e.hurtAt = now
                pcall(Voice.say, e, hp < 40 and "Help" or "Pain", hp >= 40)
            end
            local dt = math.min(1, now - (e.perceivedAt or now))
            e.perceivedAt = now
            local here = e.bot:K2_GetActorLocation()
            e.lastAt = here -- trackTargets: how far from the camera (ANIM_SLOW_FAR)
            local mine = factionOf(e)
            -- Size up every hostile body within range: the first spotted (nearest first) is the foe; otherwise
            -- the nearest one heard.
            local spotted, heard
            if not fighting and not e.alert then
                local cands = {}
                for _, b in ipairs(bodies) do
                    if b.faction ~= mine then
                        local d = dist(here, b.at)
                        if d < CFG.PERCEIVE_RANGE then cands[#cands + 1] = { b = b, d = d } end
                    end
                end
                table.sort(cands, function(x, y) return x.d < y.d end)
                for _, k in ipairs(cands) do
                    if hurt then AI.hurt(e, k.b.pawn, now) end
                    local spotMul = edge(mine, k.b.faction) == "guard" and CFG.EDGE_GUARD_SPOT or nil
                    local what, d, heardAt, kind = AI.perceive(e, k.b.pawn, k.b.at, now, dt, spotMul, k.b)
                    if what == "spotted" then spotted = { b = k.b, d = d } break end
                    if what == "heard" and not heard then heard = { b = k.b, d = d, at = heardAt, kind = kind } end
                end
                -- Shot by someone it didn't see: turn on the nearest hostile.
                if hurt and not spotted and cands[1] then spotted = { b = cands[1].b, d = cands[1].d, shot = true } end
            end
            local function who() return ("%s (%s)"):format(e.rival and e.rival.name or e.crewmate and ("your " .. e.crewmate.name)
                or e.bot:GetFName():ToString(), AI.describe(e)) end
            local function name(b)
                local o = b.entry
                return o == PLAYER and "the player" or (o.rival and o.rival.name
                    or o.crewmate and ("your " .. o.crewmate.name) or "a soldier")
            end
            if not fighting and e.alert and alive then
                engage(e, pawn, PLAYER)
                fighting, e.lastSeen, e.alert = true, playerLoc, nil -- boarders know where you are
                log(who() .. " knows where the player is")
            elseif spotted or (heard and heard.d < CFG.POINT_BLANK) then
                local b = spotted and spotted.b or heard.b
                engage(e, b.pawn, b.entry)
                fighting = true
                e.lastSeen = spotted and b.at or heard.at
                pcall(Voice.say, e, spotted and spotted.shot and "CoverMe" or "EnemySpotted")
                log(who() .. (spotted and spotted.shot and (" was shot, fighting " .. name(b))
                    or spotted and (" spotted %s at %.0f m"):format(name(b), spotted.d / 100)
                    or (" heard %s point-blank"):format(name(b))))
            elseif heard then
                e.heardEntry = heard.b.entry
                hearNoise(e, heard.b.pawn, heard.at, heard.kind, now)
                fighting = e.inCombat == true
            end
            -- Already fighting: perception above only runs at peace, so a bot locked on a far foe used to ignore an
            -- enemy standing beside it (a crewmate and a soldier side by side, each shooting someone across the room).
            -- About once a second, switch to a hostile that is much closer than the current foe and either in sight
            -- or shooting at this bot.
            -- Hurt while its foe is out of sight (behind a wall), the shot came from someone else: turn on the nearest
            -- hostile it can see, however far. Without this a guard locked on a rival through a wall took the
            -- player's fire and kept shooting the wall (Penal Colony, 2026-11-14): the player never counts as "onMe".
            local hitBlind = false
            if fighting and hurt then
                local cur = foeOf(e)
                hitBlind = not (cur and e.ctrl:LineOfSightTo(cur, { X = 0, Y = 0, Z = 0 }, false))
            end
            if fighting and (hitBlind or now >= (e.nextRetarget or 0)) then
                e.nextRetarget = now + CFG.RETARGET_EVERY
                local cur = foeOf(e)
                local df = cur and dist(here, cur:K2_GetActorLocation()) or math.huge
                local best, bd
                for _, b in ipairs(bodies) do
                    if b.faction ~= mine and b.pawn ~= cur then
                        local d = dist(here, b.at)
                        local inReach = hitBlind and d < CFG.PERCEIVE_RANGE
                            or d < CFG.RETARGET_NEAR and d < df * CFG.RETARGET_RATIO
                        if inReach and (not bd or d < bd) then
                            local onMe = b.entry ~= PLAYER and b.entry.inCombat and b.entry.foeEntry == e
                            if onMe or e.ctrl:LineOfSightTo(b.pawn, { X = 0, Y = 0, Z = 0 }, false) then
                                best, bd = b, d
                            end
                        end
                    end
                end
                if best then
                    engage(e, best.pawn, best.entry)
                    e.lastSeen = best.at
                    log(("%s turns on %s at %.0f m (was fighting someone %.0f m off)"):format(who(), name(best), bd / 100,
                        df == math.huge and 0 or df / 100))
                end
            end
            if not fighting then
                -- your crew (crew.lua) follows you instead of patrolling or going to look at noises
                if e.follow then
                    if e.cover then releaseCover(e) end
                    e.investigate = nil
                    local okf, errf = pcall(e.follow, e)
                    if not okf then log("crew follow failed: " .. tostring(errf)) end
                elseif e.investigate then investigate(e, now) else patrol(e) end
            end
            foe = foeOf(e)
            -- A won fight gets an insult; a long one gets the odd call to the crew.
            if e.fighting and not (fighting and foe) and math.random() < 0.5 then
                pcall(Voice.say, e, math.random() < 0.5 and "Insult01" or "FuckOff")
            elseif e.fighting and now >= (e.calloutAt or 0) then
                e.calloutAt = now + math.random(8, 16)
                local calls = { "Attack", "CoverMe", "HoldPosition" }
                pcall(Voice.say, e, calls[math.random(#calls)])
            end
            e.fighting = fighting and foe ~= nil
            if e.fighting then combatHints(e, foe, foe:K2_GetActorLocation()) end
            if e.fighting then -- every update: how fighting soldiers spend their time (logged with the status line)
                local st = e.cover and e.cover.state or (e.los and "open" or "unseen")
                raid.coverTally = raid.coverTally or {}
                raid.coverTally[st] = (raid.coverTally[st] or 0) + 1
            end
        end
    end
    if os.clock() - (raid.lastReport or 0) >= 10 then
        raid.lastReport = os.clock()
        local living, walking, fighting = 0, 0, 0
        for _, e in ipairs(raid.bots) do
            if valid(e.bot) and (e.bot.Health or 0) > 0 then
                living = living + 1
                if e.fighting then fighting = fighting + 1
                elseif e.ctrl:GetMoveStatus() == 3 then walking = walking + 1 end
            end
        end
        log(("soldiers alive %d, fighting %d, patrolling %d, player hp %s | crew: %s"):format(living, fighting, walking,
            alive and string.format("%.0f", pawn.Health) or "dead", Crew and Crew.status() or "-"))
        -- bridge/cover_nobake (testing): random-point cover search only, as before cover.lua
        local nb = io.open(PROJECT .. "bridge/cover_nobake", "r")
        if nb then nb:close() end
        if (nb ~= nil) ~= (raid.coverNoBake == true) then
            raid.coverNoBake = nb ~= nil
            log("cover: baked spots " .. (raid.coverNoBake and "OFF" or "on"))
        end
        local pr = {}
        for k, v in pairs(raid.coverProbe or {}) do pr[#pr + 1] = k .. " " .. v end
        local ow = {}
        for k, v in pairs(raid.openWhy or {}) do ow[#ow + 1] = k .. " " .. v end
        log("cover probes of baked spots: " .. table.concat(pr, ", ") .. " | open fights: " .. table.concat(ow, ", "))
        local t = raid.coverTally or {}
        log(("cover %s | fighting samples: hiding %d, peeking %d, moving %d, open in sight %d, open unseen %d"):format(
            Cover.stats(), t.hiding or 0, t.peeking or 0, t.moving or 0, t.open or 0, t.unseen or 0))
    end
end

-- 5. Aim --------------------------------------------------------------------------------------------
-- Something in the AI (a tree service on its own timer) keeps swapping the controller's focus for a point it
-- refreshes slowly, so the focal point trailed a moving player by 100-1000 units and the bot turned "late".
-- Re-asserting focus every frame keeps the body within ~5 degrees of the player (measured at 1.5-5 m).
-- The AI anim blueprint picks the leg play rate itself every update (Standing_LegsPlayrate 1.1 walking,
-- 0.65 aiming) and overwrites anything we write (post-hooks on BlueprintUpdateAnimation don't fire). Legs
-- slid whenever the bot moved faster than that. So match the speed to the legs instead: 1.1 → 220, 0.65 → 130.
local SPEED_PER_LEG_RATE, CROUCH_ANIM_SPEED = 200, 132
local function animate(e)
    local bot = e.bot
    -- Posture, every frame: the tree crouches between updates. In cover only low cover crouches (to hide);
    -- otherwise crouches are cut short by standUntil. (NavAgentProps.bCanCrouch can't be written from Lua.)
    local c = e.cover
    local wantCrouch
    if c and c.state ~= "moving" then wantCrouch = c.low and c.state == "hiding"
    elseif c or e.standUntil then wantCrouch = false end
    if wantCrouch ~= nil and bot.bIsCrouched ~= wantCrouch then
        if wantCrouch then bot:Crouch(false) else bot:UnCrouch(false) end
    end

    -- The pawn's components are kept on the entry (reapDead drops them with the pawn): every read of bot.Mesh or
    -- bot.CharacterMovement makes a new UE4SS object (with a finalizer), and this runs per bot per frame. The anim
    -- instance isn't kept: a new skeletal mesh (female.lua) can replace it.
    local mesh, move = e.mesh, e.move
    if not mesh then
        mesh, move = bot.Mesh, bot.CharacterMovement
        e.mesh, e.move = mesh, move
    end
    local anim = mesh:GetAnimInstance()
    if not valid(anim) then return end
    local v = bot:GetVelocity()
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y)
    -- The blueprint's leg rates make for a slow 220 walk / 130 aiming walk. Play the whole body faster while
    -- moving and scale the speed to match, so soldiers move briskly without their feet sliding.
    -- The tree's own shuffle input creeps a standing soldier along at a few units/s with its legs walking.
    if speed > 0 and speed < CFG.STUCK_SPEED and valid(e.ctrl) and e.ctrl:GetMoveStatus() ~= 3 then
        move:StopMovementImmediately()
        speed = 0
    end
    -- Running to cover: the AI anim blueprint has no run cycle, so play the player's base sprint on its
    -- FullBodyCinematic slot (combat montages use DefaultSlot and would cut it off).
    local inv = e.investigate
    local running = (c and c.state == "moving" and c.run) or (inv and inv.state == "go" and inv.run)
        or (e.followRun and not e.fighting) or (e.meleeRun and e.fighting)
    local sprinting = running and speed > 150
    if sprinting and not e.sprintAnim then
        local seq = lib(CFG.SPRINT_ANIM)
        if valid(seq) then
            anim:PlaySlotAnimationAsDynamicMontage(seq, FName("FullBodyCinematic"), 0.15, 0.2, 1.0, 1000, -1, 0)
            e.sprintAnim = true
        end
    elseif not sprinting and e.sprintAnim then
        anim:StopSlotAnimation(0.2, FName("FullBodyCinematic"))
        e.sprintAnim = false
    end
    -- Feet match the ground: the body plays at (actual speed / the speed its leg cycle was made for). A fixed
    -- speed-up per mode cycled the legs 2-10x too fast whenever the real speed fell short of the target: side-steps
    -- (the strafe cap, see AI.tuneBody), crouch-walking (crouched speed isn't raised), and sprinting while aiming
    -- (the game's aim modifier holds a 550 run to ~330). Smoothed so the gait doesn't flicker frame to frame.
    local rate = anim.Standing_LegsPlayrate
    if not (rate and rate > 0) then rate = 1.1 end
    local natural = running and CFG.SPRINT_SPEED or bot.bIsCrouched and CROUCH_ANIM_SPEED or SPEED_PER_LEG_RATE * rate
    local want = speed > 30 and math.max(0.6, math.min(CFG.LEG_RATE_MAX, speed / natural)) or 1
    e.animScale = (e.animScale or 1) + (want - (e.animScale or 1)) * 0.5 -- at ANIM_HZ: settles in ~0.1 s
    mesh.GlobalAnimRateScale = e.animScale
    -- That scale is for the legs. The gun's own montage (bolt, pump, recoil) plays at 1.0 on its mesh, so the arms'
    -- matching montage is held at 1.0 too or the two drift apart while the bot moves.
    if not e.sprintAnim and math.abs(e.animScale - 1) > 0.02 then
        local m = anim:GetCurrentActiveMontage()
        if valid(m) then anim:Montage_SetPlayRate(m, 1 / e.animScale) end
    end
    if running then
        move.MaxWalkSpeed = CFG.SPRINT_SPEED
    elseif bot.bIsCrouched then
        anim.Crouching_Legs_Playrate = 1
    else
        -- top speed: brisker than the blueprint's slow walk, faster still when strafing in a fight
        local base = ((not c or c.state == "moving") and e.fighting and e.los) and CFG.STRAFE_ANIM_SCALE
            or CFG.MOVE_ANIM_SCALE
        move.MaxWalkSpeed = SPEED_PER_LEG_RATE * rate * base
    end
    -- Stepping between the cover spot and its firing point: fast, with no sideways speed cap (AI.tuneBody's
    -- strafe factor would hold the 60 unit side-step to ~110/s).
    local step = c and c.peekPos and ((c.state == "peeking" and c.peekPos) or (c.state == "hiding" and c.pos))
    local quick = step and dist2d(bot:K2_GetActorLocation(), step) > 12
    if quick ~= e.quickStep then
        e.quickStep = quick
        e.baseAccel = e.baseAccel or move.MaxAcceleration
        move.MaxAcceleration = quick and CFG.PEEK_ACCEL or e.baseAccel
        move.MaxMoveBackAndStrafeSpeed = quick and 1 or (e.mind and e.mind.profile.strafe or 0.6)
    end
    if quick then move.MaxWalkSpeed = CFG.PEEK_SPEED end
    -- The game slows an aiming bot to half its top speed (measured: forward x 0.5, sideways x 0.5 x the strafe cap),
    -- so fights were walked at 75-95 and strafed at 115-145 while you walk at 280. Every speed above is meant as the
    -- real one. Crouched speed isn't set here each frame, so it's left alone.
    local crouched = bot.bIsCrouched
    local targeting = not running and not crouched and bot:IsTargeting()
    if targeting then
        move.MaxWalkSpeed = move.MaxWalkSpeed / CFG.AIM_SLOWDOWN
    end
    -- No faster than the legs can carry them at LEG_RATE_MAX (the aim slowdown is divided out the same way).
    if not running and not crouched then
        local cap = natural * CFG.LEG_RATE_MAX / (targeting and CFG.AIM_SLOWDOWN or 1)
        if move.MaxWalkSpeed > cap then move.MaxWalkSpeed = cap end
    end
end

trackTargets = function()
    if not raid.spawned then return end
    reapDead()
    -- Bots past ANIM_SLOW_FAR from the camera (where updateBots last saw them) animate ANIM_SLOW_HZ times a second, not
    -- every frame: animate() is ~a dozen engine reads and writes a bot, and with 20-30 bots in a station it was most of
    -- the director's 2-3 ms a frame. Posture, speed caps and leg rates a tenth of a second late don't show at that range.
    -- The rest animate ANIM_HZ times a second: every frame was ~1.2 ms a frame and 3 MB of garbage a second in a
    -- 20-bot fight (the aim section, profile.txt, 2026-11-14), and the collector stepping through that was worse.
    local now = os.clock()
    local cam = raid.camAt
    for _, e in ipairs(raid.bots) do
        if valid(e.bot) and (e.bot.Health or 0) > 0 then
            local far = cam and e.lastAt and not e.fighting and dist(e.lastAt, cam) > CFG.ANIM_SLOW_FAR
            if now >= (e.animNext or 0) then
                e.animNext = now + 1 / (far and CFG.ANIM_SLOW_HZ or CFG.ANIM_HZ)
                animate(e)
            end
        end
    end
    for _, e in ipairs(raid.bots) do
        -- Hide / lean out on time to the frame, not on the 0.5 s update.
        local c = e.cover
        local alive = valid(e.bot) and (e.bot.Health or 0) > 0
        if c and e.fighting and alive and valid(e.ctrl) and c["until"] and now >= c["until"] then
            if c.state == "hiding" then peek(e, c, now) elseif c.state == "peeking" then hide(e, c, now) end
        end
        local state = e.cover and e.cover.state
        local sprinting = state == "moving" and e.cover.run
        -- Reaction time over: open fire, unless cover says hold it (running to cover, hiding).
        if e.holdUntil and now >= e.holdUntil and valid(e.ctrl) then
            e.holdUntil = nil
            local pawn = foeOf(e)
            if e.inCombat and pawn and state ~= "hiding" and not sprinting then setEnemy(e, pawn) end
        end
        -- Aim upkeep, ANIM_HZ a second (focus is kept by the controller between calls), or at once when what the bot
        -- should be doing changes. Only the aiming pose follows the aim up and down, and only it plays the arms' firing
        -- montage. The native shooting code turns it on now and then: from the hip a bot shoots at you with its gun
        -- level or pointing down.
        local want = (e.fighting and not sprinting and state ~= "hiding") and true or false
        if alive and (now >= (e.aimNext or 0) or want ~= e.aimWant) then
            e.aimNext, e.aimWant = now + 1 / CFG.ANIM_HZ, want
            local pawn = foeOf(e)
            local aiming = (want and pawn) and true or false
            if e.bot:IsTargeting() ~= aiming then e.bot:ServerSetTargeting(aiming) end
            if e.fighting and pawn and valid(e.ctrl) and not sprinting then
                if e.los then
                    e.ctrl:K2_SetFocus(pawn)
                    e.ctrl.LastKnownPlayerPosition = pawn:K2_GetActorLocation()
                elseif e.lastSeen then
                    e.ctrl:K2_SetFocalPoint(e.lastSeen)
                end
            end
        end
    end
end

-- Player loadout --------------------------------------------------------------------------------------
-- Offline the player spawns with no weapons, and the SIGIS inventory path (Server_AddItem + Server_EquipItem /
-- the equipment component's ServerEquipItemToSlot) crashes in game code. A soldier's gun is a plain ARaidWeapon,
-- though: spawn a donor soldier out of sight, move its weapon to the player and equip it, then delete the donor.
local function startGiveGun(pc)
    local pawn = pc.Pawn
    local l = pawn:K2_GetActorLocation()
    local donor = lib("/Script/AIModule.Default__AIBlueprintHelperLibrary"):SpawnAIFromClass(pc,
        lib("/Game/Blueprints/Pawns/BotPawnMilitary.BotPawnMilitary_C"), lib(TREE),
        { X = l.X, Y = l.Y, Z = l.Z + 3000 }, { Pitch = 0, Yaw = 0, Roll = 0 }, true, pc)
    if valid(donor) then raid.donor, raid.donorAt = donor, os.clock() end
end

-- For a player-controlled pawn the weapon's ammo-in-clip getter (RVA 0x18875a0) ignores CurrentAmmoInClip and
-- returns the StackAmount of the SIGIS item whose UniqueItemGUID == gun.UUIDSIGIS (0 when there is none), so
-- HandleFiring sees an empty gun and never shoots. Bots skip that lookup. So the gun gets an item of its own: its
-- stack is the loaded magazine, firing drains it (UseAmmo) and the native reload refills it from ammo items in
-- the inventory whose row AmmoType matches the gun's BulletType.
-- UseAmmo also refreshes the item's inventory widget, which only exists once the SIGIS HUD overlay does (the
-- server creates it in a live raid; offline nothing does): without it the first shot crashes (null getter 0x9f2e80).
local GUN_ROWS = { MG42 = "MG42Rifle", Sten = "StenSMG", Mat49 = "Mat49Rifle", M45 = "M45CarlSMG", DP28 = "DP28Rifle",
    Bren = "BrenMk2Rifle", Krasa = "KrasaRifle", Daewoo = "DaewooK1Rifle", Mac10 = "Mac10Rifle",
    Reising = "M50ReisingRifle", Sterling = "SterlingRifle_Short", M712 = "M712Pistol", P08 = "P08Pistol",
    ["1911"] = "1911Pistol", STG44 = "STG44Rifle", Mas44 = "Mas44Rifle" }
-- EBulletType -> ammo row (row AmmoType bytes read from SIGIS_ExampleItemData)
local AMMO_ROWS = { [0] = "12GaugeAmmo", "300Ammo", "32Ammo", "45Ammo", "9mmAmmo", "10mmAmmo", "762Ammo", "54RAmmo",
    "556Ammo", "40mmAmmo", "FlareAmmo", "FlameFuel", "DartAmmo" }
local AMMO_STACK = 60        -- rounds per pocket stack (the 2x2 pocket takes four)

local function inventory() return FindFirstOf("SIGISInventoryComponent") end

local function itemById(guid)
    if guid == "" then return nil end
    for _, it in ipairs(FindAllOf("SIGISInventoryItem") or {}) do
        if it.UniqueItemGUID:ToString() == guid then return it end
    end
end

-- The gun's SIGIS item, remembered per raid (itemById scans every object; keepGunLoaded asks every update).
local function gunItem(gun)
    local guid = gun.UUIDSIGIS:ToString()
    local it = raid.gunItem
    if not (valid(it) and it.UniqueItemGUID:ToString() == guid) then
        it = itemById(guid)
        raid.gunItem = it
    end
    return it
end

-- Returns whether the overlay exists (the match HUD itself can appear a moment after the pawn).
local function ensureHud(pc)
    local hud = pc.MyHUD
    if not (valid(hud) and hud:GetClass():GetFName():ToString() == "MatchHUD_C") then return false end
    if valid(hud.InGameOverlay) then
        -- With the local backend the game now builds its own overlay ("In Game Overlay Match") a moment after ours.
        -- Two full-screen overlays: ours sat on top and swallowed every click (loot grid, Esc menu). Collapse ours.
        local own = raid.ownOverlay
        if valid(own) and own:GetAddress() ~= hud.InGameOverlay:GetAddress() then
            own:SetVisibility(1) -- Collapsed
            raid.ownOverlay = nil
            log("the game created its own SIGIS HUD overlay; collapsed ours")
        end
        return true
    end
    local overlay = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc,
        lib("/SIGISPlugin/Widgets/HUD/SIGIS_HUDOverlay.SIGIS_HUDOverlay_C"), pc)
    if not valid(overlay) then log("couldn't create the SIGIS HUD overlay") return false end
    overlay:AddToViewport(50)
    hud.InGameOverlay = overlay
    raid.ownOverlay = overlay
    log("created the SIGIS HUD overlay")
    return true
end

-- The player's own loadout. In a live raid the server asks the client for its equipped stash items
-- (Client_GetEquippedItems; the client reads them from Nakama) and builds the loadout in
-- SIGISPlayerController::Server_AwsN_EquippedItemsReturned: items into their slots under their stash ids, weapon
-- actors for the guns, each gun's loaded rounds as its item stack. Offline nothing asks, so this feeds that function
-- the equipped items the local Nakama stand-in keeps in backend/loadout.json (only while bridge/offline_backend
-- exists: with the live backend the file would be a stale copy). The SIGIS HUD overlay has to exist first (see
-- above). Returns whether it ran.
local function applyLoadout(pc)
    local flag = io.open(CFG.OFFLINE_BACKEND_FLAG, "r")
    if not flag then return false end
    flag:close()
    local f = io.open(CFG.LOADOUT_FILE, "r")
    if not f then log("no " .. CFG.LOADOUT_FILE .. "; is the Nakama stand-in running?") return false end
    local json = f:read("a")
    f:close()
    pc:Server_AwsN_EquippedItemsReturned(json)
    -- The items are in the raid now, not in the stash: the stand-in removes these ids (lost on death; extraction
    -- saves what comes out as new items). Item strings start with the id: "<id>-<Row>-...".
    local ids = {}
    for id in json:gmatch('"value":"([^"%-]+)%-') do ids[#ids + 1] = id end
    local tmp = CFG.CHECKOUT_FILE .. ".tmp"
    local out = io.open(tmp, "w")
    if out then
        out:write(table.concat(ids, "\n"), "\n")
        out:close()
        os.remove(CFG.CHECKOUT_FILE)
        os.rename(tmp, CFG.CHECKOUT_FILE)
    end
    log(("loadout: %d equipped item(s) from the stand-in stash, checked out of it"):format(#ids))
    return true
end

-- Floor loot. Each ASIGISLootSingleSpawner places one item from its loot table (or nothing, when the roll says "null")
-- as a pickup actor, which it takes from the level's ASIGISResourceManager pool (Manager.ActorForSingleSpawns). The
-- manager is server-only content, so offline TriggerSpawn found none and did nothing. Spawn one with the game
-- instance's DefaultDropItem class (SIGIS_ExamplePickUP_C, also used for dropped items) and trigger every spawner once.
local function spawnFloorLoot(pc)
    raid.floorLoot = true
    local mgr = FindFirstOf("SIGISResourceManager")
    if not valid(mgr) then
        mgr = pc:GetWorld():SpawnActor(lib("/Script/SIGISPlugin.SIGISResourceManager"), { X = 0, Y = 0, Z = 0 },
            { Pitch = 0, Yaw = 0, Roll = 0 })
    end
    local gi = FindFirstOf("SIGISGameInstance")
    if not (valid(mgr) and valid(gi) and valid(gi.DefaultDropItem)) then return log("floor loot: no resource manager") end
    mgr.ActorForSingleSpawns = gi.DefaultDropItem
    local n, placed = 0, 0
    for _, sp in ipairs(FindAllOf("SIGISLootSingleSpawner") or {}) do
        if valid(sp) then
            n = n + 1
            if not sp.HasCompletedASpawn then sp:TriggerSpawn() end
            if valid(sp.ActiveActorHere) then placed = placed + 1 end
        end
    end
    log(("floor loot: %d of %d spawners placed an item"):format(placed, n))
end

-- Extraction. In a live raid the server calls the inventory's Client_GetOutWithLoot when the player gets out: the
-- client copies everything it carries (not keycards / guild badges) into SIGISGameInstanceNakama.ExtractedLoot,
-- and back in the lobby (after Play on the splash screen) saves those as new stash items. Then the server ends
-- the player's session. Offline this hook does that last part: back to the main menu after EXTRACT_SECONDS.
local function extractNow()
    local inv = FindFirstOf("SIGISInventoryComponent")
    if valid(inv) then inv:Client_GetOutWithLoot() end
end

-- Equips the first weapon the pawn carries (the loadout's guns arrive unequipped). Returns whether it had one.
local function equipCarried(pawn)
    local gun
    pawn.Inventory:ForEach(function(_, w)
        if not gun and valid(w:get()) then gun = w:get() end
    end)
    if not gun then return false end
    pawn:ServerEquipWeapon(gun)
    log("equipped " .. gun:GetClass():GetFName():ToString() .. " from the loadout")
    return true
end

local ids = 0
local function newId(kind)
    ids = ids + 1
    return ("pve-%s-%d-%d"):format(kind, os.time(), ids)
end

-- Registers the gun's own item. A fresh id: the donor soldier owns an item under the gun's old id (its loot copy),
-- which went away with the donor, and the gun then had no item and couldn't fire.
local function loadGun(gun, rounds)
    local guid = newId("gun")
    gun.UUIDSIGIS = guid
    local cls, row = gun:GetClass():GetFName():ToString(), "MG42Rifle"
    for k, r in pairs(GUN_ROWS) do if cls:find(k, 1, true) then row = r end end
    -- "Equipment" isn't a grid container, so the item needs no grid cell.
    inventory():Server_AddItem(FName(row), rounds, 100, "Equipment", { Column = 0, Row = 0 }, false, guid, 0, "", 100)
    local it = gunItem(gun)
    if not it then return log("couldn't register the gun's SIGIS item; it won't fire") end
    it.StackAmount = rounds
    gun.CurrentAmmoInClip = rounds
    raid.gun, raid.gunRounds = gun, rounds
end

local function giveAmmo(gun, rounds)
    local row = AMMO_ROWS[gun.BulletType]
    if not row then return log("no ammo row for bullet type " .. tostring(gun.BulletType)) end
    local slot = 0
    while rounds > 0 and slot < 4 do
        local n = math.min(rounds, AMMO_STACK)
        inventory():Server_AddItem(FName(row), n, 100, "PocketLeft", { Column = slot % 2, Row = slot // 2 }, false,
            newId("ammo"), 0, "", 100)
        rounds, slot = rounds - n, slot + 1
    end
    log(("put %d stacks of %s in the left pocket"):format(slot, row))
end

-- If the gun's item ever disappears the gun is dead weight; put it back with the rounds it last had.
local function keepGunLoaded()
    local gun = raid.gun
    if not valid(gun) then return end
    local it = gunItem(gun)
    if it then raid.gunRounds = it.StackAmount return end
    log("the gun's SIGIS item vanished; re-registering it")
    loadGun(gun, raid.gunRounds or 0)
end

-- The donor's weapon appears a moment after it spawns, so this runs from a later update.
local function finishGiveGun(pc)
    local donor, pawn = raid.donor, pc.Pawn
    if os.clock() - raid.donorAt < 1 then return end
    raid.donor = nil
    if not (valid(donor) and valid(pawn)) then return end
    local gun = donor.CurrentWeapon
    if valid(gun) then
        gun:SetOwner(pawn)
        gun.Instigator = pawn
        gun.MyPawn = pawn
        pcall(function() gun:OnRep_MyPawn() end)
        local n = 0
        pawn.Inventory:ForEach(function() n = n + 1 end)
        pawn.Inventory[n + 1] = gun
        pawn:ServerEquipWeapon(gun)
        ensureHud(pc)
        local mag = gun.CurrentAmmoInClip -- a fresh soldier's gun holds a full magazine
        loadGun(gun, mag)
        giveAmmo(gun, mag * CFG.START_MAGS)
        log("gave the player a " .. gun:GetClass():GetFName():ToString())
    end
    -- Empty the donor's weapon list first so deleting it can't take the gun along.
    donor.CurrentWeapon = nil
    donor.Inventory:Empty()
    donor:K2_DestroyActor()
end

-- Test immunity: on while bridge/god.txt exists (survives raids and restarts); the debug menu toggles it.
local GOD_FILE = PROJECT .. "bridge/god.txt"
function godMode()
    local f = io.open(GOD_FILE, "r")
    if f then f:close() return true end
    return false
end

local function toggleGodMode()
    if godMode() then os.remove(GOD_FILE) else
        local f = io.open(GOD_FILE, "w")
        if f then f:write("player can't be damaged while this file exists\n") f:close() end
    end
    log("player damage immunity " .. (godMode() and "ON" or "OFF"))
end

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
        local pin = io.open(MAP_PIN, "r")
        if pin then map = pin:read("l") or map pin:close() end
        mm = { at = os.clock() + CFG.MM_SEARCH_SECONDS, map = map, kind = kind }
        log(("matchmaking started (%s, configuration \"%s\"): offline match on %s in %ds")
            :format(kind, name, mm.map, CFG.MM_SEARCH_SECONDS))
    end
end
for fn, kind in pairs({
    ["/Script/SIGISPlugin.SIGISGameInstanceGraphQL:AwsWs_StartMatchMaking"] = "lobby",
    ["/Script/SIGISPlugin.SIGISGameInstanceGraphQL:AwsWs_StartSoloMatchMaking"] = "solo",
}) do
    if not pcall(RegisterHook, fn, onStartMatchmaking(kind)) then log("couldn't hook " .. fn) end
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
    launching = { pc = pc, at = os.clock() + 0.3, cmd = "open /Game/Maps/" .. m.map .. RAID_OPTS .. Rivals.shipOption(launchShip) }
end

-- Docking at a station ------------------------------------------------------------------------------
-- Flying into a station's docking volume, RaidDockingComponent::FrigateDocking (server) sets the controller's
-- DockedVolume and starts the docking ability (Ability_Frigate_BoardStation). Its client half ends with
-- ClientFrigateDockingToStation, which clears the client's DockedVolume; its server half calls
-- FrigateDockingToStation, which docks the ship (SpaceshipInside::Docked) and lets you through the airlock.
-- Standalone there is one controller and the ability runs only its client half: the clear wiped the server's
-- DockedVolume and nothing docked (you kept pushing into the airlock). So keep DockedVolume across the clear and
-- then run the server half.
-- Airlock refusals, logged so a lockout can be read afterwards (EHangerEvent: 3 ship not in dock, 4 wrong dock,
-- 5 no key card, 6 busy, 7 no dock connection).
pcall(RegisterHook, "/Script/RaidGame.RaidPlayerController:HangerEvent", function(ctx, ev)
    local e = ev:get()
    if e >= 3 then log("airlock refused (hangar event " .. tostring(e) .. ")") end
end)

local dockingVolume
RegisterHook("/Script/RaidGame.RaidPlayerController:ClientFrigateDockingToStation", function(ctx)
    dockingVolume = nil
    local v = ctx:get().DockedVolume
    if valid(v) then dockingVolume = v end
end, function(ctx)
    local pc, v = ctx:get(), dockingVolume
    dockingVolume = nil
    if not v then return end
    local ok, err = pcall(function()
        pc.DockedVolume = v
        pc:FrigateDockingToStation()
    end)
    log(ok and ("docked at " .. v:GetFName():ToString()) or ("docking failed: " .. tostring(err)))
end)

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
    if not raid.veiledAt then
        raid.veiledAt = now
        setLoadSpeed(pc, CFG.LOAD_TIME_DILATION)
        local ok, err = pcall(Loading.show, pc)
        if not ok then log("loading screen failed: " .. tostring(err)) end
    end
    local gm = world.AuthorityGameMode
    local ok, stage, frac = pcall(loadProgress, pc, world, gm)
    if ok then pcall(Loading.stage, stage, frac) end
    if not raid.readyAt and valid(pc.Pawn) and valid(gm) and #gm.ShipsInMap > 0 and streamingDone(world) then
        raid.readyAt = now
        setLoadSpeed(pc, 1)
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
    if (raid.readyAt and now - raid.readyAt >= CFG.REVEAL_DELAY) or now - raid.veiledAt >= CFG.VEIL_MAX then
        raid.revealed = true
        setLoadSpeed(pc, 1)
        pcall(Loading.finish)
        if valid(cam) then cam:StartCameraFade(1, 0, 1.0, BLACK, false, false) end
        log(("aboard after %.0fs%s"):format(now - raid.veiledAt, raid.readyAt and "" or " (gave up waiting)"))
    elseif valid(cam) then
        cam:SetManualCameraFade(1.0, BLACK, false)
    end
end

-- Space maps keep every raid location (Spaceport_01, Fortress_01...) and AI ship interiors as always-loaded
-- sublevels away from where you fly. Their height fogs and unbound post-process volumes apply to the whole world,
-- and UE4 draws only one height fog, whichever registered first: open space came out blue and murky (an AI frigate
-- interior's fog) or with a raid's colour grading. So each sublevel's effects only show near that sublevel (its
-- fog's position), and none in open space. Effects are collected once, when the map is ready (two object scans).
local function levelEffects(world)
    local own = world:GetFullName():match("/Game/[^.]+")
    local levels = {}
    for _, cls in ipairs({ "ExponentialHeightFog", "PostProcessVolume" }) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            local pkg = a:GetFullName():match("/Game/[^.]+")
            -- (valid: skips a previous world's actors still waiting to be destroyed)
            if valid(a) and pkg and pkg ~= own and (cls == "ExponentialHeightFog" or a.bUnbound) then
                local l = levels[pkg] or { name = pkg:match("[^/]+$"), fogs = {}, volumes = {} }
                levels[pkg] = l
                if cls == "ExponentialHeightFog" then
                    l.fogs[#l.fogs + 1] = a
                    l.at = a:K2_GetActorLocation()
                else
                    l.volumes[#l.volumes + 1] = a
                    l.at = l.at or a:K2_GetActorLocation()
                end
            end
        end
    end
    local list = {}
    for _, l in pairs(levels) do list[#list + 1] = l end
    return list
end

local function showLevelEffects(level, on)
    for _, f in ipairs(level.fogs) do f.Component:SetVisibility(on, false) end
    for _, v in ipairs(level.volumes) do v.bEnabled = on end
end

local function updateLevelEffects(pc, world)
    if not raid.effects then
        raid.effects = levelEffects(world)
        for _, l in ipairs(raid.effects) do showLevelEffects(l, false) end
        raid.effectsOn = false
    end
    local cam = pc.PlayerCameraManager:GetCameraLocation()
    local near, best = false, CFG.LEVEL_EFFECT_RADIUS
    for _, l in ipairs(raid.effects) do
        local d = dist(cam, l.at)
        if d < best then near, best = l, d end
    end
    if near ~= raid.effectsOn then
        if raid.effectsOn then showLevelEffects(raid.effectsOn, false) end
        if near then showLevelEffects(near, true) end
        raid.effectsOn = near
        log("level effects: " .. (near and near.name or "open space (none)"))
    end
end


local MENU_FLAG = PROJECT .. "bridge/menu_toggle"
local DEBUG_FLAG = PROJECT .. "bridge/debug_cmd"
local FEMALE_FLAG = PROJECT .. "bridge/female_toggle"
local STASH_ROWS = PROJECT .. "config/stash_rows.txt"
local STASH_ROWS_MAX = 25
local STASH_UNLOCKS = { i1 = true, i2 = true, i3 = true, i4 = true } -- DT_PrestigeUnlockInfo, InventorySpace
local STASH_UNLOCK_ROWS = 2 -- each one's StashSizeIncrease

-- Your ship's key card. The game puts it in the KeyCard slot at the start of a raid (row KEYCARD, Attachments
-- "<captain>!<ship name>!<KeyCardUUID of the ship interior>!<ship type>"), and a station airlock only lets you back
-- into a docked ship while you carry it. One went missing during a Rebel Base raid (2026-11-07, cause not found), and
-- that leaves you shut out of your own ship. So: remember it, and if it's gone while the KeyCard slot is empty, put the
-- same card back (Server_AddItem with its id and info; verified to open the station side of the airlock again).
-- A card of another crew in the slot is left alone: that's yours to use on their ship.
local CARD_CHECK = 2

local function playerInventory()
    for _, inv in ipairs(FindAllOf("SIGISInventoryComponent") or {}) do
        local o = valid(inv) and inv:GetOwner()
        if o and valid(o) and o:GetClass():GetFName():ToString() == "MainPlayerController_C" then return inv end
    end
end

local function guardKeyCard(pc)
    -- found once per raid: FindAllOf walks every object in the game, a hitch every time it ran
    if not (raid.cardInv and valid(raid.cardInv)) then raid.cardInv = playerInventory() end
    local inv = raid.cardInv
    if not inv then return end
    local mine, slotted = false, nil
    inv.StashedItems:ForEach(function(_, e)
        local it = e:get()
        if valid(it) and it.ItemData:ToString() == "KEYCARD" then
            local guid = it.UniqueItemGUID:ToString()
            if not raid.card and it.MotherItemGUID:ToString() == "KeyCard" then
                raid.card = { guid = guid, att = it.Attachments:ToString(), cond = it.Condition }
                log("key card: " .. raid.card.att:gsub("^[^!]*!", ""))
            end
            if raid.card and guid == raid.card.guid then mine = true end
            if it.MotherItemGUID:ToString() == "KeyCard" then slotted = guid end
        end
    end)
    local k = raid.card
    if not k or mine then return end
    if slotted then
        if raid.cardNote ~= slotted then raid.cardNote = slotted log("key card: yours is gone, another crew's is in the slot") end
        return
    end
    inv:Server_AddItem(FName("KEYCARD"), 1, k.cond, "KeyCard", { X = 0, Y = 0 }, false, k.guid, 0, k.att, 0)
    log("key card: it was gone from your inventory; put it back")
end

-- The map's one sun (intensity 10, moving, shadows out to 650000 units) is meant for the hulls and stations seen from
-- space. It has no way to stay out of the interiors: its shadow map spreads over the whole map, far too coarse for a
-- wall to block it, so it lit rooms almost flat, and every station in the map went into that shadow map each frame.
-- Nothing on foot needs it, so it's only on while you fly.
local function updateSun(onFoot)
    if raid.sun == nil then
        raid.sun = false
        for _, c in ipairs(FindAllOf("DirectionalLightComponent") or {}) do
            if valid(c) and c.Intensity > 0 and not c:GetFullName():find("/Engine/Transient", 1, true) then raid.sun = c end
        end
    end
    if raid.sun and valid(raid.sun) and raid.sunOn ~= not onFoot then
        raid.sunOn = not onFoot
        raid.sun:SetVisibility(not onFoot, false)
    end
end

-- Rival crews (rivals.lua) -------------------------------------------------------------------------------
-- Space maps ship a baked navmesh for the stations and AI frigate interiors, but none for your ship's interior
-- (it's spawned at runtime), and boarders have to walk it. Switching the baked navmesh to runtime generation
-- discards its tiles and rebuilds nothing; a freshly spawned dynamic RecastNavMesh (as on raid maps) rebuilds
-- every volume in ~3 s, plus one we add around your interior (a runtime volume has no brush, so it borrows a
-- station volume's box brush, scaled to the interior).
-- Station garrisons on space maps: stations streamed into a space map have no soldiers (only the game's sleeping
-- placeholder raiders), so the first time you walk into one, it gets a garrison like a raid map: soldiers at its AI
-- spawn nodes (RaidAINodeStart inside the station), else at random walkable spots, never close to you.
local function spawnGarrison(pc, box, name, count)
    count = count or CFG.GARRISON
    local foot = raid.target
    local here = valid(foot) and foot:K2_GetActorLocation() or nil
    local function inside(l)
        return math.abs(l.X - box.c.X) <= box.e.X + 1500 and math.abs(l.Y - box.c.Y) <= box.e.Y + 1500
            and math.abs(l.Z - box.c.Z) <= box.e.Z + 1500
    end
    local spots = {}
    for _, n in ipairs(FindAllOf("RaidAINodeStart") or {}) do
        if valid(n) then
            local l = n:K2_GetActorLocation()
            if inside(l) and (not here or dist(l, here) >= CFG.MIN_SPAWN_DIST) then spots[#spots + 1] = l end
        end
    end
    local fromNodes = #spots
    for _ = 1, count * 3 do
        if #spots >= count then break end
        local out = {}
        if Out.call(navLib(), "K2_GetRandomReachablePointInRadius", pc, box.c, out, math.max(box.e.X, box.e.Y), navMesh(),
            queryFilter()) and out.X and (not here or dist(out, here) >= CFG.MIN_SPAWN_DIST) and not offLimits(out) then
            spots[#spots + 1] = { X = out.X, Y = out.Y, Z = out.Z }
        end
    end
    -- Spawned one per update (spawnQueued), not all at once: a burst of actor spawns inside the tick hook (with a
    -- rival crew materializing in the same tick) crashed the game once in UE4SS's hook dispatch.
    raid.spawnQueue = raid.spawnQueue or {}
    for i = 1, math.min(count, #spots) do table.insert(raid.spawnQueue, spots[i]) end
    log(("%s garrison: %d soldiers coming (%d at AI nodes)"):format(name, math.min(count, #spots),
        math.min(count, fromNodes)))
end

local function spawnQueued(pc)
    local q = raid.spawnQueue
    if q and #q > 0 then spawnBot(pc, table.remove(q, 1), math.random(0, 359)) end
end

local addInteriorNav -- below, once navmesh helpers exist
Rivals = require("rivals")
Voice.init({ valid = valid, lib = lib, log = log, root = pveRoot })
Female.init({ valid = valid, lib = lib, log = log, root = pveRoot, loadLoose = pveLoad })
Rivals.init({ female = Female, offLimits = offLimits, rollKit = pveRollKit, addItem = pveAddItem, keepWorn = pveKeepWorn, voice = Voice, loadLoose = pveLoad, root = pveRoot, garrison = spawnGarrison, log = log, valid = valid, lib = lib, navLib = navLib, navMesh = navMesh, queryFilter = queryFilter,
    dist = dist, arm = arm, raid = function() return raid end, addInteriorNav = function(pc, i) addInteriorNav(pc, i) end })
-- Your crew: hired in the lobby (hire.lua, F6), AI teammates in a raid who follow you and work your ship's turrets while
-- you fly (crew.lua).
-- In the lobby they stand beside you on the hangar's crew stands and fill its crew slots (crewlobby.lua).
CrewLobby = require("crewlobby")
CrewLobby.init({ log = log, valid = valid, lib = lib, female = Female, root = pveRoot, rollKit = pveRollKit })
Hire = require("hire")
Hire.init({ log = log, valid = valid, lib = lib, AI = AI, tiers = function() return Rivals.CFG.TIERS end,
    rivals_scale = function() return Rivals.CFG.SCALE_GEAR end,
    femaleShare = function() return Rivals.femaleShare() end,
    rollKit = Rivals.rollKit, lobby = CrewLobby })
Crew = require("crew")
Interiors.init({ log = log, valid = valid })
Crew.init({ rivals = Rivals, hire = Hire, AI = AI, lib = lib, voice = Voice, log = log, valid = valid, dist = dist,
    gunseat = Gunseat,
    navLib = navLib, navMesh = navMesh,
    queryFilter = queryFilter, offLimits = offLimits, raid = function() return raid end, playerTeam = PLAYER_TEAM,
    engage = function(e, pawn, entry) engage(e, pawn, entry) end,
    onPlayer = function(o) return o.inCombat == true and o.foeEntry == PLAYER end })

local PROVOKE_FILE = PROJECT .. "bridge/rivals_provoke"
local CLASH_FILE = PROJECT .. "bridge/rivals_clash"
local BOARD_FILE = PROJECT .. "bridge/rivals_board"
local PREP_FILE = PROJECT .. "bridge/rivals_prep"
local FIRED_FILE = PROJECT .. "bridge/rivals_fired"
local SKIRMISH_FILE = PROJECT .. "bridge/rivals_skirmish"

-- Contract / campaign objectives (missions.lua): the contract actors' server half, so hold-area and inspect
-- objectives count offline.
Loading.init({ log = log, valid = valid, lib = lib })
Splash.init({ log = log, valid = valid, lib = lib })
-- Closing the F3/F9 menus: a raid goes back to game-only input; the lobby is a mouse screen, so it gets its UI back
-- (as hire.lua does).
local function menuClosed(pc)
    local wbl = lib("/Script/UMG.Default__WidgetBlueprintLibrary")
    if pc:GetClass():GetFName():ToString() == "MainPlayerController_C" then
        pc.bShowMouseCursor = false
        wbl:SetInputMode_GameOnly(pc)
    else
        pcall(function() wbl:SetInputMode_GameAndUIEx(pc, nil, 0, false) end)
    end
end
Tuning.init({ log = log, valid = valid, lib = lib, menuClosed = menuClosed, CFG = CFG, RCFG = Rivals.CFG, CREWCFG = Crew.CFG, hire = Hire, AI = AI, applied = function()
    for _, e in ipairs(raid.bots or {}) do
        if valid(e.bot) then AI.tuneBody(e) end
    end
end })
Missions = require("missions")
Missions.init({ log = log, valid = valid })
-- Manning a turret yourself (gunseat.lua): the seat's client half (turning, firing, getting up) that never runs offline.
Gunseat.init({ log = log, valid = valid })
Minimap.init({ log = log, valid = valid, lib = lib, missions = Missions, raid = function() return raid end })

-- A nav bounds volume around a ship interior, borrowing an existing volume's brush.
local function interiorNavVolume(world, src, inside)
    if not valid(src) then return nil end
    local o, e = {}, {}
    Out.call(src, "GetActorBounds", false, o, e, false)
    local s = src:GetActorScale3D()
    local base = { X = e.X / s.X, Y = e.Y / s.Y, Z = e.Z / s.Z }
    local box = inside.InSideComp
    local c, ext = box:K2_GetComponentLocation(), box:GetScaledBoxExtent()
    local vol = world:SpawnActor(lib("/Script/NavigationSystem.NavMeshBoundsVolume"), c,
        { Pitch = 0, Yaw = 0, Roll = 0 })
    vol.Brush = src.Brush
    vol.BrushComponent.Brush = src.BrushComponent.Brush
    vol.BrushComponent.BrushBodySetup = src.BrushComponent.BrushBodySetup
    local sc = { X = (ext.X + 200) / base.X, Y = (ext.Y + 200) / base.Y, Z = (ext.Z + 200) / base.Z }
    vol:SetActorScale3D({ X = sc.X * 1.01, Y = sc.Y * 1.01, Z = sc.Z * 1.01 })
    vol:SetActorScale3D(sc)
    return vol
end

-- Rivals' interiors, spawned when you board one: the runtime navmesh grows to cover them.
-- (the brush donor and the navigation system are looked up once a raid: the two object scans cost ~90 ms per interior)
function addInteriorNav(pc, inside)
    if not valid(raid.navSrc) then raid.navSrc = (FindAllOf("NavMeshBoundsVolume") or {})[1] end
    if not valid(raid.navSys) then raid.navSys = FindFirstOf("NavigationSystemV1") end
    local vol = interiorNavVolume(pc:GetWorld(), raid.navSrc, inside)
    if valid(vol) then raid.navSys:OnNavigationBoundsUpdated(vol) end
end

local function homeInterior(foot)
    local l, best, bd = foot:K2_GetActorLocation(), nil, nil
    for _, ins in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if valid(ins) and not ins.IsAnAIShip and valid(ins.SpaceshipToPairTo) then
            local d = dist(l, ins.InSideComp:K2_GetComponentLocation())
            if not bd or d < bd then best, bd = ins, d end
        end
    end
    return best
end

local function startSpaceNav(pc, home)
    local world = pc:GetWorld()
    for _, n in ipairs(FindAllOf("RecastNavMesh") or {}) do if valid(n) then n.RuntimeGeneration = 2 end end
    lib("/Script/NavigationSystem.Default__RecastNavMesh").RuntimeGeneration = 2 -- Dynamic
    local ns = FindFirstOf("NavigationSystemV1")
    ns.bGenerateNavigationOnlyAroundNavigationInvokers = false
    raid.navMesh = world:SpawnActor(lib("/Script/NavigationSystem.RecastNavMesh"), { X = 0, Y = 0, Z = 0 },
        { Pitch = 0, Yaw = 0, Roll = 0 })
    local vols = FindAllOf("NavMeshBoundsVolume") or {}
    if valid(home) then table.insert(vols, interiorNavVolume(world, vols[1], home)) end
    for _, v in ipairs(vols) do if valid(v) then ns:OnNavigationBoundsUpdated(v) end end
    raid.navStarted = true
    log(("space navmesh: rebuilding %d volumes (your ship's interior included: %s)"):format(#vols, tostring(valid(home))))
end

local function updateSpace(pc, worldName)
    local foot = raid.target
    if not raid.home then
        raid.home = homeInterior(foot)
        if not valid(raid.home) then return end
    end
    if not raid.navStarted then startSpaceNav(pc, raid.home) return end
    if not raid.navReady then
        raid.navReady = navReadyAt(pc, raid.home.InSideComp:K2_GetComponentLocation())
            or navReadyAt(pc, foot:K2_GetActorLocation())
        if raid.navReady then log("space navmesh ready") end
        if not raid.navReady and os.clock() - raid.readyAt < 20 then return end
        raid.navReady = true
    end
    raid.spawned = true -- aim tracking runs for rivals' bodies
    local P, t0 = _G.PVE_PROF, os.clock()
    Rivals.update(pc, raid.world, worldName, foot, raid.home)
    if P then
        local ms = (os.clock() - t0) * 1000
        P.rivalsUpdate = (P.rivalsUpdate or 0) + ms
        if ms > (P.rivalsUpdateMax or 0) then P.rivalsUpdateMax = ms end
    end
    local okc, errc = pcall(Crew.update, pc, raid.world)
    if not okc then log("crew: " .. tostring(errc)) end
    spawnQueued(pc)
    -- Testing from outside the game: bridge/rivals_provoke does what F4 does.
    local f = io.open(PROVOKE_FILE, "r")
    if f then f:close() os.remove(PROVOKE_FILE) Rivals.provoke() end
    f = io.open(BOARD_FILE, "r")
    if f then f:close() os.remove(BOARD_FILE) Rivals.provoke(true) end
    f = io.open(PREP_FILE, "r")
    if f then
        local want = f:read("l")
        f:close()
        os.remove(PREP_FILE)
        Rivals.prepBoard(want and want:match("%S") and want or nil)
    end
    f = io.open(CLASH_FILE, "r")
    if f then -- holding a number: that far apart (default 3000)
        local apart = f:read("l")
        f:close() os.remove(CLASH_FILE) Rivals.clash(tonumber(apart))
    end
    -- bridge/rivals_fired: as if you'd just fired your ship's guns; bridge/rivals_skirmish: an ambient fight now.
    f = io.open(FIRED_FILE, "r")
    if f then f:close() os.remove(FIRED_FILE) Rivals.firedForTest() end
    f = io.open(SKIRMISH_FILE, "r")
    if f then -- holding a number: that many ships on each side
        local size = f:read("l")
        f:close()
        os.remove(SKIRMISH_FILE)
        Rivals.skirmishNow(size and size:match("%d+"))
    end
    updateBots(pc)
end

-- Main update ---------------------------------------------------------------------------------------
local pgosOverlay = { w = nil, findAt = 0 } -- the PGOS social overlay, kept collapsed (see update)
update = function(pc)
    if not valid(pc) then return end
    local world = pc:GetWorld()
    if not valid(world) then return end
    local worldName = world:GetFullName()
    local worldKey = ("%s@%x/%x"):format(worldName, world:GetAddress(), pc:GetAddress())
    if worldKey ~= raid.world then resetRaid(worldKey) Cover.reset(world) raid.startedAt = os.clock() end
    if not raid.footsteps then raid.footsteps = patchFootsteps() end
    if not raid.friendsRefresh then raid.friendsRefresh = patchFriendsRefresh() end
    raid.pcAddr = pc:GetAddress()
    -- PGOS "social service unavailable" overlay, in the menu and in raids: keep it collapsed (removing it crashes the
    -- next travel). It comes back on its own at any time, not only while a map loads (a sweep limited to a map's first
    -- 30 s left it over the lobby). The overlay belongs to the game instance, so it lives as long as the game: it's
    -- found once (FindFirstOf scans every object, and never in a space raid past the veil, where a scan is a visible
    -- hitch), then this update checks the remembered widget every 0.5 s. While missing: every second for a map's first
    -- 30 s, when the overlay turns up as the lobby loads (a scan every 10 s left it over the lobby for up to 10 s, user
    -- report 2026-11-16), then every 10 s.
    local age = os.clock() - raid.startedAt -- this map's age (the stash check below uses it)
    local space = worldName:find("/Maps/Space_", 1, true) ~= nil
    local now = os.clock()
    if not valid(pgosOverlay.w) and now >= pgosOverlay.findAt and not (space and raid.revealed) then
        pgosOverlay.findAt = now + (age < 30 and 1 or 10)
        pgosOverlay.w = FindFirstOf("PgosOverlay_BP_C")
        if valid(pgosOverlay.w) then log(("social overlay found %.1fs into the map: kept collapsed"):format(age)) end
    end
    if valid(pgosOverlay.w) and pgosOverlay.w:GetVisibility() ~= 1 then pgosOverlay.w:SetVisibility(1) end
    -- bridge/female_toggle: F2 without the keyboard (testing, like bridge/god.txt).
    local toggle = io.open(FEMALE_FLAG, "r")
    if toggle then
        toggle:close()
        os.remove(FEMALE_FLAG)
        Female.togglePlayer()
    end
    if worldName:find("/Maps/MainMenu", 1, true) then
        hookCaptainButton()
        -- Your player level, for gear that follows it (gearscale.lua): only the menu's controller knows it. The cap is the
        -- last level GetXPForLevel still climbs at (asked once).
        if os.clock() - (raid.levelReadAt or -100) > 5 then
            raid.levelReadAt = os.clock()
            pcall(function()
                local lvl = pc:GetPlayersLevel()
                if not raid.levelMax then
                    raid.levelMax = 0
                    local prev = -1
                    for n = 1, 200 do
                        local xp = pc:GetXPForLevel(n)
                        if type(xp) ~= "number" or xp <= prev then break end
                        prev, raid.levelMax = xp, n
                    end
                end
                local max = raid.levelMax >= 2 and raid.levelMax < 200 and raid.levelMax or nil
                if GearScale.setLevel(lvl, max) then
                    log(("gear scale: player level %d of %d, gear grade centre %.2f"):format(GearScale.level(),
                        GearScale.CFG.LEVEL_MAX, GearScale.target()))
                end
            end)
        end
        local okh, errh = pcall(Hire.lobby, pc) -- back from a raid: the crew's record, promotions
        if not okh then log("crew lobby: " .. tostring(errh)) end
    else
        Hire.leftLobby()
    end
    if worldName:find("/Maps/MainMenu", 1, true) then
        -- A save with its own stash height (launcher), plus the prestige stash upgrades you own, at most STASH_ROWS_MAX.
        -- The game indexes stash cells with a byte: past 256 cells (25 rows of 10) slots wrap onto the top rows, so the
        -- highlights land 25 rows off and spaces clash. Rechecked every 2 s, so an upgrade bought in the menu counts too.
        if raid.stashFile == nil then
            local f = io.open(STASH_ROWS, "r")
            raid.stashFile = f and tonumber(f:read("l")) or false
            if f then f:close() end
        end
        if raid.stashFile and age >= (raid.stashCheck or 0) then
            raid.stashCheck = age + 2
            if not valid(raid.stashInv) then raid.stashInv = FindFirstOf("SIGISInventoryComponent") end
            if not valid(raid.stashPc) then raid.stashPc = FindFirstOf("SIGISPlayerController") end
            local inv, pc = raid.stashInv, raid.stashPc
            if valid(inv) then
                local bought = 0
                if valid(pc) then
                    pcall(function()
                        pc.PrestigeUnlocks:ForEach(function(_, e)
                            if STASH_UNLOCKS[e:get():ToString()] then bought = bought + 1 end
                        end)
                    end)
                end
                local asked = raid.stashFile + bought * STASH_UNLOCK_ROWS
                local rows = math.min(asked, STASH_ROWS_MAX)
                if raid.stashAsked ~= asked then
                    raid.stashAsked = asked
                    log(("stash: %d rows (save %d, %d prestige upgrade(s))%s"):format(rows, raid.stashFile, bought,
                        asked > rows and (", capped from %d: the game's grid can't index more"):format(asked) or ""))
                end
                -- Written every check: the game adds an upgrade's rows to the size itself when you buy one.
                pveStashRows(math.tointeger(inv:GetAddress()), rows)
                -- The stash grid keeps its own size and builds its slots when the menu does: rebuilt when they differ.
                local w = raid.stashGrid
                if not valid(w) then
                    w = nil
                    for _, x in ipairs(FindAllOf("InventoryContainerWidget") or {}) do
                        if valid(x) and x:GetFullName():find("Transient", 1, true)
                            and x:GetFullName():find("InventoryStashGrid", 1, true) and x.InventorySlots:GetArrayNum() > 0 then
                            w = x
                        end
                    end
                    raid.stashGrid = w
                end
                if w and w.InventoryGridSize.Row ~= rows then
                    w.InventoryGridSize.Row = rows
                    w.InventoryGrid:ClearChildren()
                    w.InventorySlots:Empty()
                    w:InitializeGrid()
                    log(("stash grid: %d rows, %d items on it"):format(rows, w.DraggableItemsCanvas:GetChildrenCount()))
                end
            end
        end
        -- The character standing in the lobby. It's a scan, so not every update, and it re-dresses when you change clothes.
        if age >= (raid.lobbyDress or 0) then
            raid.lobbyDress = age + 3
            if Female.playerDue() then
                for _, char in ipairs(FindAllOf("MM_PlayerChar_C") or {}) do
                    -- only your own stand: the others are your crew's (crewlobby.lua)
                    if valid(char) and not char:GetFullName():find("Default__", 1, true) and char.isPlayer then
                        pcall(Female.dress, char, Female.playerOn())
                    end
                end
            end
        end
        if not raid.splashDone and age >= (raid.splashSweep or 0) then
            raid.splashSweep = age + 1
            raid.splashDone = Splash.apply(pc)
        end
    end
    if mm and os.clock() >= mm.at then launchMatch(pc) end
    -- Space maps (where matchmaking puts you, in your ship) get the loadout and extraction; their fights are ship
    -- AI, so no navmesh or soldiers there.
    if not (space or worldName:find("/Maps/Raids/", 1, true)) then return end
    raid.space = space
    if space and not raid.revealed then veilUntilAboard(pc, world) end
    -- Arriving, the mouse didn't turn the camera until you'd opened and closed the inventory (Tab): the lobby's
    -- mouse-screen input (cursor, game and UI) carried into the raid, and the loading screen sat over the viewport while
    -- you spawned (user report 2026-11-15). Once the loading screen has faded: game-only input, as closing a menu gives.
    if not raid.inputDone and valid(pc.Pawn) and (raid.revealed or not space) then
        raid.inputAt = raid.inputAt or os.clock() + (space and 1.5 or 1)
        if os.clock() >= raid.inputAt then
            raid.inputDone = true
            local ok, err = pcall(function()
                pc:ResetIgnoreLookInput()
                pc:ResetIgnoreMoveInput()
                menuClosed(pc)
            end)
            log(ok and "your input: game only (arrived)" or ("your input on arrival failed: " .. tostring(err)))
        end
    end
    if space and raid.readyAt then
        local aff = io.open(PROJECT .. "bridge/autofly", "r") -- testing: "<station name>" or "x y z"; gone = stop
        if aff then
            local line = aff:read("l") or ""
            aff:close()
            local x, y, z = line:match("^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)")
            raid.autofly = x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } or Rivals.stationAt(line)
        else
            raid.autofly = nil
        end
        updateLevelEffects(pc, world)
        Interiors.update(pc, raid, world)
    end
    -- bridge/menu_toggle: opens or closes the tuning menu without the keyboard (testing, like bridge/god.txt).
    local flag = io.open(MENU_FLAG, "r")
    if flag then
        local line = flag:read("l")
        flag:close()
        os.remove(MENU_FLAG)
        if line and line ~= "" then Tuning.command(line) else Tuning.toggle(pc) end
    end
    -- bridge/debug_cmd: a debug menu action id (see Debug.init below), or empty to open or close the menu.
    flag = io.open(DEBUG_FLAG, "r")
    if flag then
        local line = flag:read("l")
        flag:close()
        os.remove(DEBUG_FLAG)
        if line and line ~= "" then Debug.command(pc, line) else Debug.toggle(pc) end
    end
    local pawn = pc.Pawn
    raid.pawn = pawn
    if not valid(pawn) then return end
    -- Your own body: checked each update, since changing gear puts the game's meshes back on.
    if Female.playerDue() and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C" then
        pcall(Female.dress, pawn, Female.playerOn())
    end
    local ps = pc.PlayerState
    if valid(ps) and ps.TeamNumber ~= PLAYER_TEAM then ps.TeamNumber = PLAYER_TEAM end
    local immune = godMode()
    if pawn.bCanBeDamaged == immune then pawn.bCanBeDamaged = not immune end

    if not raid.loadout and ensureHud(pc) then raid.loadout = os.clock() applyLoadout(pc) end
    if raid.ownOverlay then ensureHud(pc) end -- collapses ours once the game's own overlay appears
    if raid.extractedAt and os.clock() - raid.extractedAt >= CFG.EXTRACT_SECONDS then
        raid.extractedAt = nil
        local gi, n = FindFirstOf("SIGISGameInstanceNakama"), 0
        if valid(gi) then gi.ExtractedLoot:ForEach(function() n = n + 1 end) end
        log(("extracted with %d item(s): back to the main menu; they return to the stash in the lobby (after Play)")
            :format(n))
        -- Leave the way the raid server sent an escaped player home: RaidPlayerController's override of
        -- ClientReturnToMainMenuWithTextReason reads the reason ("ESCAPED", "DEATH", "DISCONNECT") and records the
        -- raid result, which makes the menu pay out finished contracts / campaign steps and write XP, cash, faction
        -- XP and the Escapes stat. A console `open MainMenu` left the result at LoggedIn: no rewards.
        local ok = pcall(function() pc:ClientReturnToMainMenuWithTextReason(FText("ESCAPED")) end)
        if not ok then
            lib("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, "open /Game/Maps/MainMenu", pc)
        end
        return
    end
    if space then
        local onFoot = pawn:GetClass():GetFName():ToString() == "PlayerPawn_C"
        -- In a breaching or escape pod your body waits hidden, but the guns it carries stayed visible and rode on the pod
        -- (user: their Grease Gun on top of it, then a pistol again after the first fix). Hiding only the Inventory list once
        -- missed some: every gun whose MyPawn is your body, or that sits on the pod, is hidden, re-checked each update
        -- (the game shows a gun again on its own) and rescanned a few times early in the flight. Shown again on foot.
        local inPod = false
        pcall(function()
            inPod = not onFoot and (pawn.bADropPod == true or pawn:GetClass():GetFName():ToString():find("Pod", 1, true) ~= nil)
        end)
        if inPod and valid(raid.target) then hidePodGuns(raid.target, pawn) end
        if onFoot and raid.podGuns then
            for _, g in pairs(raid.podGuns) do
                if valid(g) then g:SetActorHiddenInGame(false) end
            end
            raid.podGuns, raid.podScans = nil, nil
        end
        if onFoot then raid.target = pawn end
        if raid.readyAt then updateSun(onFoot) end
        if raid.readyAt and not raid.play then Aux.mapPlayAreas() end
        if raid.play and raid.space and onFoot then Aux.rescan(pawn:K2_GetActorLocation()) end
        -- the loadout's guns arrive unequipped: draw the first one once they've spawned
        if onFoot and raid.loadout and not raid.drawn and os.clock() - raid.loadout >= 2 then
            raid.drawn = true
            if not valid(pawn.CurrentWeapon) then equipCarried(pawn) end
        end
        if raid.readyAt and not raid.floorLoot then spawnFloorLoot(pc) end
        if raid.readyAt and os.clock() >= (raid.cardAt or 0) then
            raid.cardAt = os.clock() + CARD_CHECK
            local ok, err = pcall(guardKeyCard, pc)
            if not ok then log("key card: " .. tostring(err)) end
        end
        if raid.readyAt and valid(raid.target) then
            local ok, err = pcall(Missions.update, pc, raid.world, raid.target)
            if not ok then log("missions: " .. tostring(err)) end
            updateSpace(pc, worldName)
        end
        return
    end
    if not raid.navStarted then startNav(pc) return end
    if not raid.navReady then
        raid.navReady = navReadyAt(pc, pawn:K2_GetActorLocation())
        if raid.navReady then log("navmesh ready") end
        return
    end
    if not raid.spawned then
        raid.spawned = true
        spawnRaidBots(pc)
        spawnFloorLoot(pc)
        if not valid(pawn.CurrentWeapon) and not equipCarried(pawn) and CFG.GIVE_GUN then startGiveGun(pc) end
    end
    if raid.donor then finishGiveGun(pc) end
    keepGunLoaded()
    local okc, errc = pcall(Crew.update, pc, raid.world)
    if not okc then log("crew: " .. tostring(errc)) end
    local okm, errm = pcall(Missions.update, pc, raid.world, pawn)
    if not okm then log("missions: " .. tostring(errm)) end
    -- A gun that breaks only plays its broken effect (BrokenWeaponEvent) from OnRep_WeaponHasBroken, a replication
    -- callback nothing calls offline; call it once when the held gun's bBroke turns on.
    local held = valid(pawn) and pawn.CurrentWeapon
    if valid(held) then
        local broke = held.bBroke
        if broke and raid.brokeGun ~= held:GetAddress() then pcall(function() held:OnRep_WeaponHasBroken(false) end) end
        raid.brokeGun = broke and held:GetAddress() or nil
    end
    updateBots(pc)
end

-- Gunfire effects -----------------------------------------------------------------------------------
-- AI shots run the weapon's fire animation (ServerMultiSimulateWeaponFire, once per shot) but SimulateWeaponFire,
-- which spawns the muzzle flash and plays the shot sound, returns early for Authority weapons. pvepatch.dll removes
-- that check (then bots get the real effects and this stays out of the way); without it, play the weapon's assets.
-- The same function runs once per shot for the player's gun too, so every shot is also a noise bots can hear (ai.lua).
local botClass
RegisterHook("/Script/RaidGame.RaidWeapon:ServerMultiSimulateWeaponFire", function(ctx)
    local w = ctx:get()
    local owner = w.MyPawn
    botClass = botClass or lib("/Script/RaidGame.RaidBot")
    local isBot = valid(owner) and owner:IsA(botClass)
    if valid(owner) then
        local range = CFG.GUNSHOT_RANGE * (isBot and CFG.BOT_GUNSHOT_SCALE or 1)
        local ok, err = pcall(AI.noise, owner:K2_GetActorLocation(), range, "gunshot", owner:GetAddress())
        if not ok then log("gunshot noise failed: " .. tostring(err)) end
    end
    if nativeFireFx then return end
    if not isBot then return end
    if valid(w.MuzzleFX) then
        lib("/Script/Engine.Default__GameplayStatics"):SpawnEmitterAttached(w.MuzzleFX, w.Mesh1P,
            w.MuzzleAttachPoint, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 },
            0, true, 0, true) -- KeepRelativeOffset, auto-destroy, no pooling, auto-activate
    end
    if valid(w.FireSound) then
        w:OnFiringSound(false, 30, 30, w.Mesh1P:GetSocketLocation(w.MuzzleAttachPoint), w.FireSound)
    end
end)

-- Near-miss whizz. The game plays it from ServerTraceMultiFireProjectile_Implementation (0x1898df0) only on a client
-- and only for a shooter pawn with no controller (another player's pawn there); offline every bot has its AI
-- controller, so it never ran. Same rule here: a bot's shot whose line passes within WHIZZ_RANGE of the player.
local WHIZZ_RANGE, lastWhizz = 200, 0
RegisterHook("/Script/RaidGame.RaidWeapon:ServerTraceMultiFireProjectile", function(ctx, originP, dirP)
    local w = ctx:get()
    local owner = w.MyPawn
    botClass = botClass or lib("/Script/RaidGame.RaidBot")
    if not (valid(owner) and owner:IsA(botClass)) or os.clock() - lastWhizz < 0.12 then return end
    local pc = lib("/Script/Engine.Default__GameplayStatics"):GetPlayerController(w, 0)
    if not (valid(pc) and valid(pc.Pawn)) then return end
    local o, d = originP:get(), dirP:get()
    local head = pc.PlayerCameraManager:GetCameraLocation()
    local vx, vy, vz = head.X - o.X, head.Y - o.Y, head.Z - o.Z
    local t = vx * d.X + vy * d.Y + vz * d.Z -- distance along the shot to the closest point
    if t <= 0 then return end
    local cx, cy, cz = vx - d.X * t, vy - d.Y * t, vz - d.Z * t
    if cx * cx + cy * cy + cz * cz > WHIZZ_RANGE * WHIZZ_RANGE then return end
    lastWhizz = os.clock()
    pc:ClientBulletWizzPastHead(w.BulletType)
end)

-- A bot that dies falls as a ragdoll; its lootable body copies that pose once it has settled (settleRagdolls above).
local function ragdollBot(bot)
    local ctrl = bot.Controller
    if valid(ctrl) then ctrl:StopMovement() ctrl:UnPossess() end
    bot.CapsuleComponent:SetCollisionEnabled(0)
    bot.CharacterMovement:DisableMovement()
    local mesh = bot.Mesh
    mesh:SetCollisionProfileName(FName("Ragdoll"), true)
    mesh:SetAllBodiesSimulatePhysics(true)
    mesh:SetSimulatePhysics(true)
    mesh:WakeAllRigidBodies()
    mesh.bBlendPhysics = true
    local bones = {}
    for i, name in ipairs(SETTLE_BONES) do bones[i] = FName(name) end
    table.insert(ragdolls, { bot = bot, mesh = mesh, bones = bones, pose = {}, still = 0, at = os.clock(), nextAt = 0 })
end

-- Only noted here: changing the bot (unpossessing, physics) inside the death event, while the game is still
-- running its death code, crashed the game once. The ragdoll runs from the next frame's tick (onTick's queue).
RegisterHook("/Script/RaidGame.RaidCharacter:Multi_Deathevent", function(ctx)
    local bot = ctx:get()
    botClass = botClass or lib("/Script/RaidGame.RaidBot")
    if not (valid(bot) and bot:IsA(botClass)) then return end
    table.insert(pending, function()
        if not valid(bot) then return end
        for _, e in ipairs(raid.bots) do
            if e.bot == bot or (valid(e.bot) and e.bot:GetAddress() == bot:GetAddress()) then
                pcall(Voice.say, e, "Death", true)
                break
            end
        end
        local ok, err = pcall(ragdollBot, bot)
        if not ok then log("ragdoll failed: " .. tostring(err)) end
    end)
end)

local function tellBackend(path, text)
    local f = io.open(path, "w")
    if f then
        f:write(text)
        f:close()
    end
end

RegisterHook("/Script/SIGISPlugin.SIGISInventoryComponent:Client_GetOutWithLoot", function()
    if not raid.extractedAt then raid.extractedAt = os.clock() end
    tellBackend(CFG.SHIP_LOST_FILE, "") -- out on foot or by pod: a ship leaves through Client_GetOutWithLootAndShip
end)

-- You died: the backend forgets the ship you took in.
RegisterHook("/Script/SIGISPlugin.SIGISInventoryComponent:Client_DiedCloseInv", function()
    tellBackend(CFG.SHIP_LOST_FILE, "")
end)

-- In a space gate: only then does the next ship item the game saves count as the ship coming home (settle_ship). The
-- extraction call itself passes item structs, which can't safely be hooked from Lua.
RegisterHook("/Script/RaidGame.RaidPlayerController:Server_EnterEvacRaidVolume", function()
    tellBackend(CFG.SHIP_GATE_FILE, "1")
end)
RegisterHook("/Script/RaidGame.RaidPlayerController:LeaveEvacRaidVolume", function()
    tellBackend(CFG.SHIP_GATE_FILE, "0")
end)

-- Keys ----------------------------------------------------------------------------------------------
RegisterKeyBind(Key.F2, function() table.insert(pending, Female.togglePlayer) end)
-- F3: the AI tuning menu (tuning.lua), F9: the debug menu (debugmenu.lua), F6: your crew (hire.lua), in the lobby and in
-- raids. One open at a time. All take the controller the director ticks on: FindFirstOf("MainPlayerController_C") found
-- nothing in the lobby (MenuPlayerController_C there), so F3 and F9 did nothing, and in a raid it could be the last map's.
local function menuPc()
    local pc = Hire.lastPc()
    if not valid(pc) then return nil end
    -- the PGOS "social service unavailable" overlay draws over every viewport widget in the lobby
    if pc:GetClass():GetFName():ToString() ~= "MainPlayerController_C" then
        for _, w in ipairs(FindAllOf("PgosOverlay_BP_C") or {}) do
            if valid(w) and w:GetVisibility() ~= 1 then w:SetVisibility(1) end
        end
    end
    return pc
end
local function toggleTuning()
    local pc = menuPc()
    if not pc then return end
    Debug.close(pc) Hire.close(pc)
    Tuning.toggle(pc)
end
local function toggleDebug()
    local pc = menuPc()
    if not pc then return end
    Tuning.close(pc) Hire.close(pc)
    Debug.toggle(pc)
end
RegisterKeyBind(Key.F3, function() table.insert(pending, toggleTuning) end)
RegisterKeyBind(Key.F6, function() table.insert(pending, function()
    local pc = Hire.lastPc()
    if not valid(pc) then return end
    Tuning.close(pc) Debug.close(pc)
    Hire.toggle(pc)
end) end)
RegisterKeyBind(Key.F9, function() table.insert(pending, toggleDebug) end)
-- The minimap (minimap.lua): N shows or hides it, M switches to the full overview and back, B follows the next task.
RegisterKeyBind(Key.N, function() table.insert(pending, Minimap.toggle) end)
RegisterKeyBind(Key.M, function() table.insert(pending, Minimap.expand) end)
RegisterKeyBind(Key.B, function() table.insert(pending, Minimap.next) end)

-- The debug menu's buttons (they used to be F4-F9). when() says whether one can be used where you are.
local function onFootIn(kind)
    local pc = FindFirstOf("PlayerController")
    return valid(pc) and valid(pc.Pawn) and (kind == "land" and raid.navReady or kind == "any")
end
Debug.init({ log = log, valid = valid, lib = lib, menuClosed = menuClosed, actions = {
    { id = "god", label = function() return "God mode: " .. (godMode() and "ON" or "off") end,
      help = "You can't be hurt. Stays on until you turn it off",
      run = function() toggleGodMode() return "God mode " .. (godMode() and "on" or "off") end },
    { id = "extract", label = "Extract now", help = "Leave with everything you carry",
      when = function() return raid.navReady or raid.space end, unusable = "Not available here", closes = true,
      run = function() extractNow() return "Extracting" end },
    { id = "gates", label = "Open the gates now", help = "No waiting for the escape gates",
      when = function() return raid.space end, unusable = "Not available here",
      run = function()
          local t = FindFirstOf("UA_SpaceGateTrigger01_C")
          if not valid(t) then return "No gate console on this map" end
          t:TriggerSpaceEvacReady()
          return "Gates opening"
      end },
    { id = "attack", label = "Send a rival crew at me", help = "The nearest crew attacks your ship",
      when = function() return raid.space end, unusable = "Not available here",
      run = function() Rivals.provoke() return "A crew is coming" end },
    { id = "soldier", label = "Spawn a soldier", help = "Appears 15 m in front of you",
      when = function() return onFootIn("land") end, unusable = "Not available here",
      run = function()
          local pc = FindFirstOf("PlayerController")
          local l, r = pc.Pawn:K2_GetActorLocation(), pc.Pawn:K2_GetActorRotation()
          local y = math.rad(r.Yaw)
          spawnBot(pc, { X = l.X + 1500 * math.cos(y), Y = l.Y + 1500 * math.sin(y), Z = l.Z }, r.Yaw + 180)
          return "Soldier spawned"
      end },
    { id = "gun", label = "Give me a gun", help = "A soldier's gun, with ammo",
      when = function() return onFootIn("land") and not raid.donor end, unusable = "Not available here",
      run = function() startGiveGun(FindFirstOf("PlayerController")) return "Gun on its way" end },
    { id = "testraid", label = "Start a test raid on " .. CFG.MAP, help = "A land raid, without your stash gear",
      closes = true,
      run = function()
          local pc = FindFirstOf("PlayerController")
          lib("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc,
              "open /Game/Maps/Raids/" .. CFG.MAP .. RAID_OPTS, pc)
          return "Loading " .. CFG.MAP
      end },
} })

math.randomseed(os.time())
log("loaded")
