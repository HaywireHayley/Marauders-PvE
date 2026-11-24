-- PvEDirector: turns an offline raid into a PvE raid.
-- The shipped client has no AI navigation data (it lived in a server-only "Whitebox" sublevel), and bots
-- spawn frozen (time dilation 0, hidden, movement off) waiting for a server-side significance manager.
-- So on every raid map this mod:
--   1. builds a navmesh at runtime, bounded by the map's CullDistanceVolume
--   2. spawns soldiers at the map's AINodeStart nodes, away from the player
--   3. keeps them awake, and gives them the player as enemy once they see/hear the player or get shot
-- Keys: F3 = AI tuning menu (tuning.lua), F9 = debug menu (debugmenu.lua: god mode, extract now, spawn a soldier, a
--       crew attacks you, open the gates, give a gun, bottomless mags, test raid), F2 = your body female or male,
--       N / M / B = minimap on or off / full overview / next task (minimap.lua).
-- With the offline backend, the lobby's Start Matchmaking loads a space map, where you start in your ship
-- (launch.lua); space maps get the loadout and extraction but no soldiers.
-- Also loads native/pvepatch.dll, which patches out the role checks that stop a standalone player's shots from
-- doing damage and skip all weapon fire effects (see pvepatch.c).
-- This file is the director (settings, the per-frame tick, the update, hooks and keys); its parts live in modules
-- (bots.lua, playareas.lua, loadout.lua, launch.lua, space.lua, debugactions.lua and the older ones; NOTES.md,
-- "main.lua and its modules").
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local Interiors = require("interiors") -- interiors seen from open space: hidden while you're outside them
local LevelProps = require("levelprops") -- fans, reels, ambience and sparks the client side would start (#143)
local BotDamage = require("botdamage") -- your shots at bots: armour, shotgun pellets, a clear path to the hit zones (#123)

local CFG = {
    BOTS = 8,                -- soldiers per raid (0 = use the game mode's NumberNormal/Guard/MilitaryAI)
    MIN_SPAWN_DIST = 2500,   -- don't spawn closer than this to the player
    GARRISON = 6,            -- soldiers per station on space maps (fallback: rivals passes MIN_DEFENDERS)
    -- Senses, spotting time, reaction and accuracy come from ai.lua's profiles (soldiers "soldier"/"guard").
    POINT_BLANK = 300,       -- a noise this close starts a fight at once
    PERCEIVE_RANGE = 7000,   -- bots size up hostile bodies (you, other factions) within this range
    ANIM_FAR = 6000,         -- bots farther than this from the camera animate the engine's cheap way (not drawn = no pose)
    ANIM_HZ_LOW = 60,        -- every bot, near or far, runs animate() this many times a second...
    ANIM_HZ_HIGH = 120,      -- ...or this many while the game runs faster than ANIM_HI_FPS (never more: 120 is the ceiling)
    ANIM_HI_FPS = 120,
    ANIM_BUDGET = 14,        -- most animate() calls in one frame; bots over it wait for the next frame (a crowd can't stall one)
    ANIM_PEACE_HZ = 15,      -- aim upkeep of a bot at peace (nothing changes until it has a target, which is caught at once)
    -- Parking (bots.lua, parked): a guard or soldier at peace farther than PARK_RANGE from you is frozen and skipped until you
    -- come back within 85% of that or it's hurt. 0 = never park.
    PARK_RANGE = 15000,
    -- Floor loot density (#325, loadout.lua spawnFloorLoot), 0-3. 1 = the game's own rolls. Below 1 a spawner is skipped
    -- with chance 1 - x; above 1 a spawner that rolled nothing rolls again (floor(x - 1) more times, plus one more with
    -- the fraction's chance).
    FLOOR_LOOT = 1,
    BEG_HP = 0.25,           -- a Rat, Coward or Timmy below this share of its health may beg (banter.lua, #316)...
    BEG_CHANCE = 0.4,        -- ...with this chance, once per bot, when within BEG_RANGE of you (0 = never)
    BEG_RANGE = 1500,
    BEG_SECONDS = { 6, 10 }, -- it holds fire and stays put this long, then runs for BEG_FLEE_SECONDS (fights again if hit)
    BEG_FLEE_SECONDS = 20,
    TAUNT_CHANCE = 0.4,      -- a Chad or GigaChad that wins a fight or hits you taunts with this chance (0 = never)...
    TAUNT_EVERY = 12,        -- ...at most once in this many seconds per bot...
    TAUNT_GAP = 4,           -- ...and not within this many seconds of anyone else's
    RETARGET_EVERY = 1.0,    -- while fighting, how often (s) a bot looks for a much closer enemy to switch to
    RETARGET_NEAR = 1500,    -- ...within this range
    RETARGET_RATIO = 0.5,    -- ...and at most this share of the current foe's distance
    GUNSHOT_RANGE = 10000,   -- gunshots carry this far (at hearing 1.0)
    CALIBRE_EFFECT = 1,      -- (#317) how much the gun's calibre changes how far its shot carries: 0 = every gun the same
    SUPPRESSED_GUNSHOT = 0.35, -- ...and a suppressed gun's shot carries this share of that
    BOT_RELOAD_SECONDS = 2.4, -- a bot's magazine is empty: this long without shooting (issue #115), plus up to
    BOT_RELOAD_JITTER = 0.8,  -- this much more
    BOT_LOW_MAG = 0.15,      -- (#314, selfcare.lua) a fighting bot whose magazine is down to this share goes to cover to reload (0 = only when empty)
    BOT_HEAL_COUNT = 1,      -- a hurt bot heals in cover this many times (0 = never)...
    BOT_HEAL_HP = 0.4,       -- ...once it's below this share of its health...
    BOT_HEAL_QUIET = 4,      -- ...and hasn't been shot for this many seconds...
    BOT_HEAL_SECONDS = 5,    -- ...taking this long...
    BOT_HEAL_TO = 0.7,       -- ...to get back to this share
    BOT_CARE_GIVEUP = 8,     -- no cover reached in this many seconds: it carries on (and waits BOT_CARE_COOLDOWN to try again)
    BOT_CARE_COOLDOWN = 12,
    BOT_PUSH_SECONDS = 4,    -- Chads and GigaChads fighting you rush you this long while you reload or heal (0 = never)...
    BOT_PUSH_RANGE = 2500,   -- ...if within this range
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
    SPAWN_SLOW_AT = 40,      -- match seconds: normal speed again from here (you spawn at ~45; see onTick)
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
    LOADOUT_FILE = require("pvebackend") .. "loadout.json",
    COSMETICS_FILE = require("pvebackend") .. "cosmetics.json", -- your head, body and voice (the stand-in's cosequipped)
    CHECKOUT_FILE = require("pvebackend") .. "checkout.txt",
    SHIP_LOST_FILE = require("pvebackend") .. "ship_lost.txt",
    SHIP_GATE_FILE = require("pvebackend") .. "ship_gate.txt",
    EXTRACT_SECONDS = 3,     -- after extracting, back to the main menu this much later
    OFFLINE_BACKEND_FLAG = PROJECT .. "bridge/offline_backend",
    GIVE_GUN = true,         -- no gun in the loadout (or no stand-in): hand the player a soldier's gun...
    START_MAGS = 4,          -- ...and this many magazines of its ammo in the left pocket
    PLAYER_DAMAGE = true,    -- your shots at bots get armour, shotgun pellets and a clear path to the hit zones (botdamage.lua); false: the game's flat damage
}

local TREE = "/Game/Blueprints/Pawns/BotBehavior.BotBehavior"
-- Teams: you 3 (the station levels' own NPCs default to 1), soldiers/station defenders 2, rival crews 10+.
local PLAYER_TEAM, BOT_TEAM = 3, 2

-- URL options a raid server reads at login (player id, name, crew...); standalone they just need to be present.
local RAID_OPTS = "?PID=offline1?PNAME=Marauder?CREW=solo1?CPT=1?NUM=1?EOS=offline1?UPN=offline1?psid=1"

local function log(msg) print("[PvEDirector] " .. tostring(msg) .. "\n") end
-- (any falsy value too: `valid(a and a.b)` hands it false, which threw "attempt to index a boolean" from the minimap
-- dozens of times a second while it looked for your ship)
-- UE4SS's IsValid() reads the object's own memory, so a kept reference to an object the game has since freed (a station's
-- contents streaming out as you cycle an airlock) crashed the game in UE4SS (issue 53). pve_alive (pvepatch.c) checks the
-- address natively first; without pvepatch.dll, or for something that isn't a UObject, it's IsValid() alone.
local valid
do
    local alive = package.loadlib(PROJECT .. "native/pvepatch.dll", "pve_alive") -- (object address) -> 1 if live
    local function address(o) return o:GetAddress() end
    valid = function(o)
        if not o then return false end
        if alive then
            local ok, at = pcall(address, o)
            at = ok and math.tointeger(at)
            if at and alive(at) ~= 1 then return false end
        end
        return o:IsValid()
    end
end
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
local Unstuck = require("unstuck") -- F9 unstuck and no collision (#198)
local Defuse = require("defuse") -- station mines: F and a Minesweeper board (#197)
local DeathScreen = require("deathscreen") -- who killed you, on your death (#331)
-- main.lua's own parts, in modules: each takes main's helpers in init(ctx), and the per-raid table in setRaid (below)
local PlayAreas = require("playareas") -- where bots may go on a station
local Bots = require("bots") -- soldiers: spawning, awareness, patrols, noises, cover, aim, animation, garrisons
local Loadout = require("loadout") -- your loadout and HUD, a gun when you have none, floor loot, extraction
local Launch = require("launch") -- offline matchmaking, the map travel, the loading veil on space maps
local Census = require("census") -- object scans shared per world (rivals, minimap, play areas)
local Lobby = require("lobby") -- the main menu's per-update work: stash height and grid, lobby outfit, splash
local Space = require("space") -- space maps: pod guns, docking, level effects, key card, sun, your ship's navmesh
local DebugActions = require("debugactions") -- the debug menu's buttons (F9) and god mode
local RaidTime = require("raidtime") -- the launcher's raid length (#159)
local ShipSpeed = require("shipspeed") -- a faster Rustbucket and a boost at the helm (#207)
local Blowtorch = require("blowtorch") -- the blowtorch burns a vault door's three locks offline
local BulletHoles = require("bulletholes") -- bullet holes in walls and floors, which the offline game never makes
AI.init({ log = log, valid = valid, dist = dist })
require("cache").init(valid) -- (lookups kept while valid: the menu's controller, the world)

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
-- pveRoot(object): keeps it from the garbage collector for good (pve_root, UObject::AddToRoot). Mods hold assets in Lua
-- tables, which the collector can't see. Never anything a world owns: a rooted object keeps its outer alive, so rooting
-- one kept a whole lobby world through the raid, and loading the menu again picked that dead world up and crashed
-- (issue 133). Those are refused with a log line; make such objects inside the game instance instead.
local pveRoot
do
    local root = package.loadlib(PATCH_DLL, "pve_root") -- (object address)
    local function worldOwner(o)
        local outer = o:GetOuter()
        for _ = 1, 32 do
            if not valid(outer) then return nil end
            local class = outer:GetClass():GetFName():ToString()
            if class == "World" or class == "Level" then return outer:GetFullName() end
            outer = outer:GetOuter()
        end
    end
    pveRoot = function(o)
        if not root or not valid(o) then return false end
        local ok, owner = pcall(worldOwner, o)
        if ok and owner then
            log(("root: refused %s (a world owns it: %s)"):format(o:GetFullName(), owner))
            return false
        end
        -- (if the check itself failed, root it as before: an unrooted mesh or sound can be freed in use, the #53 crash)
        if not ok then log("root: couldn't check the outers of " .. o:GetFullName() .. ": " .. tostring(owner)) end
        root(math.tointeger(o:GetAddress()))
        return true
    end
end
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
local update, Rivals -- forward

local raid -- forward: per-raid state (below)
local resetRaid, patchFriendsRefresh -- forward (below; onTick calls them)
local Quit, GameSettings, InvKeys, LobbyLabel, InvQol, InvSync -- forward: menu helpers onTick polls (required below)
local CrewLobby, Hire, Crew, PveMapPick, PveGuild, Conditions, Minefield, Civilians, Missions -- forward (required below)
-- onTick's own state: the world it last saw (whether it's the main menu, since when) and the lobby's friends stub retries
local tick = {}

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
-- profiled(tick) wraps the tick in the counters and returns it with an undo that puts the plain scans back.
-- (inside a do block: only profiler is needed outside)
local profiler
do
local function profiled(tick)
    local scans, slow, frames, flushed = {}, {}, 0, os.clock()
    local reals = {}
    for _, name in ipairs({ "FindAllOf", "FindFirstOf" }) do
        local real = _G[name]
        reals[name] = real
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
    local fn = function(ctx)
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
    return fn, function()
        for name, real in pairs(reals) do _G[name] = real end
        _G.PVE_PROF, _G.PVE_ALLOC = nil, nil
    end
end

-- The flag is looked for every PROFILE_CHECK s, so it can be dropped in or taken out mid-raid (bridge/dir_eval.lua
-- only runs while it's on). Without it the tick runs as is, apart from that check.
local PROFILE_CHECK = 3
-- Always on (#336): testers' logs only had an average fps, which hides hitches. Every FRAMES_EVERY s one "frames:" line
-- in the normal log: the worst gap between frames and how many went over 50/100/200 ms, the director's own worst tick,
-- its slowest sections (ppcall), the object scans (FindAllOf / FindFirstOf: 40-50 ms each on space maps) and the Lua
-- heap. Costs an os.clock per frame, per section and per scan. bridge/profile_on still gives the full profile.
local FRAMES_EVERY = 10
local scansLight = {}
for _, name in ipairs({ "FindAllOf", "FindFirstOf" }) do
    local real = _G[name]
    if real then
        _G[name] = function(cls)
            local t = os.clock()
            local out = real(cls)
            local key = name .. " " .. tostring(cls)
            local s = scansLight[key]
            if not s then s = { n = 0, ms = 0 } scansLight[key] = s end
            s.n, s.ms = s.n + 1, s.ms + (os.clock() - t) * 1000
            return out
        end
    end
end
local function light(tick)
    local last, flushed, worst, worstTick, tickMs, frames = nil, os.clock(), 0, 0, 0, 0
    local over = {}
    _G.PVE_PROF = {}
    return function(ctx)
        local t = os.clock()
        if last then
            local gap = (t - last) * 1000
            if gap > worst then worst = gap end
            for _, limit in ipairs({ 50, 100, 200 }) do
                if gap >= limit then over[limit] = (over[limit] or 0) + 1 end
            end
        end
        last = t
        tick(ctx)
        local ms = (os.clock() - t) * 1000
        tickMs, frames = tickMs + ms, frames + 1
        if ms > worstTick then worstTick = ms end
        if t - flushed >= FRAMES_EVERY and frames > 0 and (not (raid and raid.pcAddr) or require("features").FRAME_LOG ~= 1) then -- (only raids are logged)
            last, flushed, worst, worstTick, tickMs, frames, over = nil, os.clock(), 0, 0, 0, 0, {}
            scansLight, _G.PVE_PROF = {}, {}
        elseif t - flushed >= FRAMES_EVERY and frames > 0 then
            local secs = {}
            for k, v in pairs(_G.PVE_PROF or {}) do
                if not k:find("Max$") and k ~= "swing" then secs[#secs + 1] = { k, v, (_G.PVE_PROF or {})[k .. "Max"] or 0 } end
            end
            table.sort(secs, function(a, b) return a[2] > b[2] end)
            local top = {}
            for i = 1, math.min(4, #secs) do top[#top + 1] = ("%s %.0f (max %.0f)"):format(secs[i][1], secs[i][2], secs[i][3]) end
            local sc, scN, scMs = {}, 0, 0
            for k, v in pairs(scansLight) do sc[#sc + 1] = { k, v } scN, scMs = scN + v.n, scMs + v.ms end
            table.sort(sc, function(a, b) return a[2].ms > b[2].ms end)
            local topScans = {}
            for i = 1, math.min(2, #sc) do topScans[#topScans + 1] = ("%s x%d %.0f ms"):format(sc[i][1], sc[i][2].n, sc[i][2].ms) end
            log(("frames: %d in %.0f s, worst gap %.0f ms, over 50/100/200 ms: %d/%d/%d | director worst %.0f ms, avg %.1f | sections ms: %s | scans %d, %.0f ms%s | lua %.0f MB, gc %d"):format(
                frames, t - flushed, worst, over[50] or 0, over[100] or 0, over[200] or 0, worstTick, tickMs / frames,
                #top > 0 and table.concat(top, ", ") or "-", scN, scMs,
                #topScans > 0 and (" (" .. table.concat(topScans, "; ") .. ")") or "",
                collectgarbage("count") / 1024, gc.cycles))
            gc.cycles = 0
            last, flushed, worst, worstTick, tickMs, frames, over = nil, os.clock(), 0, 0, 0, 0, {}
            scansLight = {}
            _G.PVE_PROF = {}
        end
    end
end
function profiler(tick)
    local live, undo, nextCheck = nil, nil, 0
    local plain = light(tick)
    return function(ctx)
        local now = os.clock()
        if now >= nextCheck then
            nextCheck = now + PROFILE_CHECK
            local f = io.open(PROJECT .. "bridge/profile_on", "r")
            if f then f:close() end
            if f and not live then
                live, undo = profiled(tick)
                log("profiler on (bridge/profile_on)")
            elseif not f and live then
                undo()
                live, undo = nil, nil
                _G.PVE_PROF = {}
                log("profiler off")
            end
        end
        return (live or plain)(ctx)
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

-- The menu's own loads (the voice lines) are 15 to 50 ms hitches each: felt as stutter while you move the
-- mouse over the title screen and the lobby. They wait for the mouse to be still for half a second. Returns false when
-- the mouse position can't be read, so nothing is held back for nothing.
local mouse = {}
local function mouseBusy(now)
    local pc = Hire and Hire.lastPc and Hire.lastPc()
    if not valid(pc) then return false end
    -- (APlayerController::GetMousePosition gives its numbers as out parameters, which Lua here doesn't hand back; the
    -- layout library's version returns a vector: 5 microseconds a call.)
    local lib = mouse.lib
    if not (lib and lib:IsValid()) then
        lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        mouse.lib = lib
    end
    local x, y
    if lib and lib:IsValid() then
        local okv, v = pcall(function() return lib:GetMousePositionOnViewport(pc) end)
        if okv and type(v) == "table" then x, y = v.X, v.Y end
    end
    if not y then
        if not mouse.warned then
            mouse.warned = true
            log("menu: mouse position can't be read; menu loads are not held back while it moves")
        end
        return false
    end
    if not mouse.seen then
        mouse.seen = true
        log(("menu: mouse position read (%.0f, %.0f); voice lines load while it is still"):format(x, y))
    end
    if x ~= mouse.x or y ~= mouse.y then mouse.x, mouse.y, mouse.movedAt = x, y, now end
    return now - (mouse.movedAt or 0) < 0.5
end

local function onTick(ctx)
    -- A new world, seen on its first frame: drop everything held from the old one now. update() notices too, but only
    -- every UPDATE_SECONDS, and until then the per-frame work below (the crew menu, the lobby stands, menus) still held
    -- the old world's freed objects. Keyed on the world's address and name: a new world can reuse the old one's address.
    local w = ctx:get():GetWorld()
    local wk = w and w:IsValid() and ("%x %s"):format(w:GetAddress(), w:GetFName():ToString()) or nil
    if wk ~= tick.world then
        if tick.world ~= nil and resetRaid then resetRaid(nil) end
        tick.world = wk
        -- Is this world the main menu (the lobby)? Asked once per world. The lobby work below used `not raid.world`, which is
        -- only true until update() first runs in the menu (raid.world is the menu's own key from then on), so the friends
        -- stub barely ran, and never after a raid.
        tick.menu = (w and w:IsValid() and w:GetFullName():find("/Maps/MainMenu", 1, true) ~= nil) or false
        -- a raid map gets the picked raid condition (#78), the lobby your own settings again
        if Conditions and w and w:IsValid() then
            local okc, errc = pcall(tick.menu and Conditions.restore or Conditions.apply)
            if not okc then log("raid conditions: " .. tostring(errc)) end
        end
        tick.menuSince = os.clock()
        tick.remote, tick.isPc = {}, {}
    end
    -- Co-op host: a joiner's MainPlayerController ticks here too. update() keys the raid on the controller's address,
    -- so every switch between the two restarted the raid (a second batch of soldiers and floor loot, the stash checked
    -- out again; #26). Only the controller playing on this machine drives the director. Only "remote" is remembered:
    -- a controller asked in the frame it spawns may not know yet.
    local me = ctx:get()
    local meAddr = me:GetAddress()
    if tick.remote and tick.remote[meAddr] then return end
    -- Only a controller can be a joiner's: the lobby widget ticker (MM_CoreMissions_C) has no IsLocalController, and
    -- UE4SS hands back a null object for it, whose call errors natively even inside pcall (#297). Asked once per object.
    tick.isPc = tick.isPc or {}
    local isPc = tick.isPc[meAddr]
    if isPc == nil then
        isPc = me:GetClass():GetFName():ToString():find("PlayerController", 1, true) ~= nil
        tick.isPc[meAddr] = isPc
    end
    local okLocal, isLocal = false, nil
    if isPc then okLocal, isLocal = pcall(function() return me:IsLocalController() end) end
    if okLocal and isLocal == false then
        tick.remote = tick.remote or {}
        tick.remote[meAddr] = true
        log("co-op: ignoring a joining player's controller (not local)")
        return
    end
    -- The load runs at LOAD_TIME_DILATION (20x) until veilUntilAboard sees your pawn, but that only looks every
    -- UPDATE_SECONDS (10 game seconds at 20x). Spawning and landing on the deck in those big physics steps cost 3-15
    -- health and burned it (testers: "always a bit of health missing at the start of a raid"; 100 at 1x). So normal
    -- speed comes back here, per frame, a few match seconds before the spawn, or as soon as a pawn exists.
    if raid.veiledAt and not raid.readyAt and not raid.spawnSpeed and w and w:IsValid() then
        pcall(function()
            local gm, gs, t = w.AuthorityGameMode, w.GameState, ctx:get()
            local soon = valid(gm) and valid(gs) and gm.MatchState:ToString() == "InProgress"
                and gm.RoundTime - gs.RemainingTime >= CFG.SPAWN_SLOW_AT
            local ok, pawn = pcall(function() return t.Pawn end)
            if soon or (ok and valid(pawn)) then
                StaticFindObject("/Script/Engine.Default__GameplayStatics"):SetGlobalTimeDilation(t, 1)
                raid.spawnSpeed = true
            end
        end)
    end
    -- Loading a sound crashes while a map travels, so voice lines only load in the menu with no match on the way. Lines
    -- not loaded yet are skipped by the bots, and the rest load next time you're in the menu.
    -- One line a frame, and only while the mouse is still: the first 25 s of the menu (a raid started sooner than that
    -- still gets its voices), then regardless.
    local menuBusy = tick.menu and mouseBusy(os.clock())
    if Voice.pending() and not Launch.busy() and ctx:get():GetClass():GetFName():ToString() ~= "MainPlayerController_C"
        and not (menuBusy and os.clock() - (tick.menuSince or 0) < 25) then
        pcall(Voice.step)
    end
    pcall(Splash.gatePlay) -- PLAY hidden until the backend login is done (splash.lua)
    if Quit then pcall(Quit.tick) end -- Quit Game in the pause menu (quit.lua)
    if GameSettings then pcall(GameSettings.tick) end -- SETTINGS on the title screen and in the lobby (gamesettings.lua)
    if InvKeys then pcall(InvKeys.tick) end -- Esc / lean with the inventory open (invkeys.lua)
    if InvSync then
        local oks, errs = pcall(InvSync.tick) -- stale cells in the inventory grids cleared (invsync.lua)
        if not oks and not tick.invSyncErr then tick.invSyncErr = true log("inventory sync: " .. tostring(errs)) end
    end
    if LobbyLabel then pcall(LobbyLabel.tick, ctx:get()) end -- START RAID label (lobbylabel.lua)
    if InvQol then
        local okq, errq = pcall(InvQol.tick, ctx:get())
        if not okq and not tick.invQolErr then tick.invQolErr = true log("stash tools: " .. tostring(errq)) end
    end
    local shown, shownErr = ppcall("loading", Loading.tick, ctx:get())
    if not shown then
        log("loading screen failed: " .. tostring(shownErr))
        Loading.reset()
    end
    if Launch.fire() then return end -- the raid's map travel, once it's due (launch.lua)
    while #pending > 0 do
        local ok, err = pcall(table.remove(pending, 1))
        if not ok then log("queued job failed: " .. tostring(err)) end
    end
    -- Aim tracking runs every frame, before update() has noticed a new world: only from the player controller the
    -- current raid state belongs to, so it never touches the previous raid's (freed) soldiers.
    local ticker = ctx:get()
    if raid.pcAddr and ticker:GetAddress() == raid.pcAddr then
        raid.frames = (raid.frames or 0) + 1 -- for the status line's fps (testers' logs had no frame data at all)
        local ok, err = ppcall("aim", Bots.trackTargets)
        if not ok then log("aim tracking failed: " .. tostring(err)) end
        if CFG.PLAYER_DAMAGE then
            ok, err = ppcall("damage", BotDamage.frame, ticker)
            if not ok and not raid.damageFailed then raid.damageFailed = true log("bot damage failed: " .. tostring(err)) end
        end
        if raid.navReady then
            ok, err = ppcall("cover", function() Cover.setNav(raid.navMesh) Cover.step(ticker) end)
            if not ok then log("cover baking failed: " .. tostring(err)) end
        end
        ok, err = ppcall("ragdolls", settleRagdolls)
        if not ok then log("ragdoll settling failed: " .. tostring(err)) end
        -- F9 bottomless mags puts back what a shot took off the clip. It runs after the sections above so anything that reads the clip
        -- for shots has seen it drop first.
        ok, err = ppcall("mags", DebugActions.frame, ticker)
        if not ok and not raid.magsFailed then raid.magsFailed = true log("bottomless mags failed: " .. tostring(err)) end
        ok, err = ppcall("blowtorch", Blowtorch.frame, ticker)
        if not ok and not raid.torchFailed then raid.torchFailed = true log("blowtorch failed: " .. tostring(err)) end
        ok, err = ppcall("bulletholes", BulletHoles.frame, ticker)
        if not ok and not raid.holesFailed then raid.holesFailed = true log("bullet holes failed: " .. tostring(err)) end
        ok, err = ppcall("unstuck", Unstuck.update, ticker)
        if not ok and not raid.unstuckFailed then raid.unstuckFailed = true log("unstuck failed: " .. tostring(err)) end
        ok, err = ppcall("defuse", Defuse.update, ticker)
        if not ok and not raid.defuseFailed then raid.defuseFailed = true log("defuse failed: " .. tostring(err)) end
        if pveBodies then pveBodies() end
        ok, err = ppcall("deathscreen", DeathScreen.frame, ticker)
        if not ok and not raid.deathFailed then raid.deathFailed = true log("death screen failed: " .. tostring(err)) end
        ok, err = ppcall("gatetext", RaidTime.frame)
        if not ok and not raid.gateTextFailed then raid.gateTextFailed = true log("space gate countdown failed: " .. tostring(err)) end
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
    -- The 1 s friends refresh hitch (~150 ms, see patchFriendsRefresh) is in the lobby too, where it made the mouse stutter in
    -- the menu, loadout and market; it was only patched inside raids. Repeating is safe (the DLL checks the bytes).
    if tick.menu and patchFriendsRefresh and os.clock() >= (tick.friendsAt or 0) then
        tick.friendsAt = os.clock() + 5
        local okF, doneF = pcall(patchFriendsRefresh)
        if okF and doneF and tick.friendsLogged ~= tick.world then
            tick.friendsLogged = tick.world -- (once per world: it comes back after every raid)
            log("lobby: friends refresh stubbed (the once a second hitch in the menu)")
        elseif not (okF and doneF) and tick.friendsMissed ~= tick.world then
            tick.friendsMissed = tick.world
            log("lobby: friends refresh function not found yet (" .. tostring(okF) .. "), retrying every 5 s")
        end
    end
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
-- (#143, 2026-11-18) Also: the step a character settles with on stopping ("returned to idle": a random 0.2-0.7 s
-- later, a walk or crouch footstep; player 17368, bots 14327) and the landing camera shake on your own camera (27802).
local FOOTSTEP_BRANCHES = {
    ["/Game/Characters/MainPlayer/rc_FPS_AnimBP.rc_FPS_AnimBP_C:ExecuteUbergraph_rc_FPS_AnimBP"] =
        { 13585, 14667, 15387, 16022, 17368, 27802 },
    ["/Game/Characters/MainPlayer/rc_FPS_AnimBP.rc_FPS_AnimBP_C:PlayFootstepSound"] = { 1288 },
    ["/Game/Characters/MainPlayer/rc_AI_FPS_AnimBP.rc_AI_FPS_AnimBP_C:ExecuteUbergraph_rc_AI_FPS_AnimBP"] =
        { 11338, 11609, 12116, 13292, 13409, 14327 },
}

-- The PGOS overlay's friends view: a looping 1 s native timer calls StartGetFriends, which walks the whole Steam friends list
-- with blocking Steam calls on the game thread (GetAdditionalSteamFriendsPGOS, ~70 ms): a hitch every second, in the menu
-- and in raids (the overlay lives on, hidden). Offline that panel only says "social service unavailable", so its stub is
-- made to return at once. Per world, like the footsteps (the DLL checks the bytes, so repeating is safe).
local FRIENDS_REFRESH = "/PgosOverlay/BlueprintUI/Friends/Subview/PgosFriendsPanel_FriendsView_WBP.PgosFriendsPanel_FriendsView_WBP_C:StartGetFriends"
function patchFriendsRefresh()
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

-- Other client-only branches worth running offline (#143, kdis 2026-11-18), patched like the footsteps. Station node
-- classes load with their station, so these are retried every CLIENT_BRANCH_EVERY s, not every update (a name lookup
-- of an object that doesn't exist yet walks every object). Each entry is done once found.
--   Base_RaidNode / Base_RaidMovementNode PopupWarning_CantEnterAsPod @20: "if HasAuthority return" before the
--     "Warning Pods Can't Enter / Only ships are able to dock" popup your pod gets at a station's docking area.
--   their ubergraphs @288: the same gate before the once-a-second check that sets PlayerIsInPodVisuals (pod or ship).
local CLIENT_BRANCHES = {
    ["/Game/Blueprints/NodeSystem/NodeActors/Base_RaidNode.Base_RaidNode_C:PopupWarning_CantEnterAsPod"] = { 20 },
    ["/Game/Blueprints/NodeSystem/NodeActors/Base_RaidNode.Base_RaidNode_C:ExecuteUbergraph_Base_RaidNode"] = { 288 },
    ["/Game/Blueprints/NodeSystem/NodeActors/Base_RaidMovementNode.Base_RaidMovementNode_C:PopupWarning_CantEnterAsPod"] = { 20 },
    ["/Game/Blueprints/NodeSystem/NodeActors/Base_RaidMovementNode.Base_RaidMovementNode_C:ExecuteUbergraph_Base_RaidMovementNode"] = { 288 },
}
local CLIENT_BRANCH_EVERY = 10
local function patchClientBranches()
    local now = os.clock()
    if (raid.clientBranchAt or 0) > now then return end
    raid.clientBranchAt = now + CLIENT_BRANCH_EVERY
    raid.clientBranches = raid.clientBranches or {}
    for path, offsets in pairs(CLIENT_BRANCHES) do
        if not raid.clientBranches[path] then
            local fn = StaticFindObject(path)
            if valid(fn) then
                for _, offset in ipairs(offsets) do pveBpJump(fn:GetAddress(), offset) end
                raid.clientBranches[path] = true
                log("client branch patched: " .. path:match("[^.]+$"))
            end
        end
    end
end

-- Per-raid state, reset whenever the world changes. A world is told apart by name and address: loading the same
-- map again keeps the name, and checking the previous raid's soldiers after the old world was freed crashed
-- (IsValid reads the object's memory).
raid = { world = nil }
-- The modules keep their own reference to the per-raid table: each is handed the new one whenever it's replaced.
local function shareRaid()
    for _, m in ipairs({ PlayAreas, Bots, Loadout, Launch, Space, DebugActions, RaidTime, LevelProps, Blowtorch, Civilians, DeathScreen, Lobby, Census }) do
        if m then m.setRaid(raid) end
    end
end
shareRaid()

function resetRaid(worldKey)
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
    Unstuck.reset()
    Defuse.reset()
    DeathScreen.reset()
    ShipSpeed.reset()
    if Rivals then Rivals.reset() end
    if Crew then Crew.reset() end
    if Missions then Missions.reset() end
    if Hire then Hire.reset() end
    raid = { world = worldKey, navStarted = false, navReady = false, spawned = false, bots = {}, hp = {} }
    shareRaid()
end

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

local Aux = {} -- small helpers the modules share (they get it as ctx.aux)
-- True at most once every `every` seconds per key: the test flag files (bridge/*) were each opened on every update,
-- ~20 failed opens a second, each a filesystem lookup (and a virus-scanner hook).
function Aux.due(key, every)
    local t = os.clock()
    Aux.dueAt = Aux.dueAt or {}
    if t < (Aux.dueAt[key] or 0) then return false end
    Aux.dueAt[key] = t + every
    return true
end

local MENU_FLAG = PROJECT .. "bridge/menu_toggle"
local DEBUG_FLAG = PROJECT .. "bridge/debug_cmd"
local FEMALE_FLAG = PROJECT .. "bridge/female_toggle"

-- Rival crews (rivals.lua), and the modules above that need them --------------------------------------------
Rivals = require("rivals")
Census.init({ valid = valid })
PlayAreas.init({ log = log, valid = valid })
Bots.init({ CFG = CFG, log = log, valid = valid, dist = dist, dist2d = dist2d, rnd = rnd, lib = lib, navLib = navLib,
    navMesh = navMesh, queryFilter = queryFilter, TREE = TREE, BOT_TEAM = BOT_TEAM, aux = Aux, rivals = Rivals,
    offLimits = PlayAreas.offLimits })
Loadout.init({ CFG = CFG, log = log, valid = valid, lib = lib, TREE = TREE })
Launch.init({ CFG = CFG, log = log, valid = valid, lib = lib, RAID_OPTS = RAID_OPTS, rivals = Rivals })
Space.init({ CFG = CFG, log = log, valid = valid, lib = lib, dist = dist, aux = Aux, rivals = Rivals, bots = Bots,
    navReadyAt = navReadyAt })
Voice.init({ valid = valid, lib = lib, log = log, root = pveRoot })
Female.init({ valid = valid, lib = lib, log = log, root = pveRoot, loadLoose = pveLoad })
Rivals.init({ female = Female, offLimits = PlayAreas.offLimits, findAll = PlayAreas.findAll, rollKit = pveRollKit, addItem = pveAddItem, keepWorn = pveKeepWorn, voice = Voice, loadLoose = pveLoad, root = pveRoot, garrison = Bots.spawnGarrison, log = log, valid = valid, lib = lib, navLib = navLib, navMesh = navMesh, queryFilter = queryFilter,
    dist = dist, arm = Bots.arm, raid = function() return raid end, addInteriorNav = Space.addInteriorNav })
-- Your crew: hired in the lobby (hire.lua, F6), AI teammates in a raid who follow you and work your ship's turrets while
-- you fly (crew.lua).
-- In the lobby they stand beside you on the hangar's crew stands and fill its crew slots (crewlobby.lua).
CrewLobby = require("crewlobby")
CrewLobby.init({ log = log, valid = valid, lib = lib, female = Female, root = pveRoot, rollKit = pveRollKit })
Hire = require("hire")
Hire.init({ log = log, valid = valid, lib = lib, AI = AI, tiers = function() return Rivals.CFG.TIERS end,
    rivals_scale = function() local s = Rivals.CFG.SCALE_GEAR return s ~= false and s ~= 0 end,
    femaleShare = function() return Rivals.femaleShare() end,
    rollKit = Rivals.rollKit, lobby = CrewLobby })
Crew = require("crew")
Interiors.init({ log = log, valid = valid })
LevelProps.init({ log = log, valid = valid, lib = lib })
RaidTime.init({ log = log, valid = valid })
ShipSpeed.init({ log = log, valid = valid })
Unstuck.init({ log = log, valid = valid, navLib = navLib, navMesh = navMesh, queryFilter = queryFilter })
Blowtorch.init({ log = log, valid = valid, lib = lib })
BulletHoles.init({ log = log, valid = valid })
Crew.init({ rivals = Rivals, hire = Hire, AI = AI, lib = lib, voice = Voice, log = log, valid = valid, dist = dist,
    gunseat = Gunseat,
    navLib = navLib, navMesh = navMesh,
    queryFilter = queryFilter, offLimits = PlayAreas.offLimits, raid = function() return raid end, playerTeam = PLAYER_TEAM,
    engage = Bots.engage,
    onPlayer = function(o) return o.inCombat == true and o.foeEntry == Bots.PLAYER end })

-- Contract / campaign objectives (missions.lua): the contract actors' server half, so hold-area and inspect
-- objectives count offline.
Loading.init({ log = log, valid = valid, lib = lib, root = pveRoot })
Splash.init({ log = log, valid = valid, lib = lib })
Lobby.init({ log = log, valid = valid, stashRows = pveStashRows })
PveMapPick = require("mappick") -- (lobbylabel.lua and launch.lua require it too)
PveMapPick.init({ log = log, valid = valid, project = PROJECT })
PveGuild = require("guild") -- (lobbylabel.lua requires it too)
PveGuild.init({ log = log, valid = valid, project = PROJECT })
LobbyLabel = require("lobbylabel") -- the lobby's START RAID label (lobbylabel.lua)
InvQol = require("invqol") -- stash SORT / SELL JUNK / search / double-click to gear (invqol.lua)
InvQol.init({ log = log, valid = valid, lib = lib, minimap = Minimap })
LobbyLabel.init({ log = log, valid = valid, offline = function() return Launch.offlineBackend() end })
InvKeys = require("invkeys") -- Esc / lean with the inventory open (invkeys.lua)
InvKeys.init({ log = log, valid = valid,
    pc = function() local pc = Hire.lastPc() return valid(pc) and pc:GetClass():GetFName():ToString() == "MainPlayerController_C" and pc or nil end,
    modMenuOpen = function() return Hire.isOpen() or Tuning.isOpen() or Debug.isOpen() end })
InvSync = require("invsync") -- stale cells in the inventory grids (invsync.lua)
InvSync.init({ log = log, valid = valid })
Quit = require("quit")
Quit.init({ log = log, valid = valid, pc = function() return Hire.lastPc() end,
    inRaid = function() local pc = Hire.lastPc() return valid(pc) and pc:GetClass():GetFName():ToString() == "MainPlayerController_C" end })
GameSettings = require("gamesettings") -- the game's Settings outside a raid (#293)
GameSettings.init({ log = log, valid = valid, pc = function() return Hire.lastPc() end })
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
Tuning.init({ base = function(...) return Conditions.base(...) end, log = log, valid = valid, lib = lib, menuClosed = menuClosed, CFG = CFG, RCFG = Rivals.CFG, CREWCFG = Crew.CFG, hire = Hire, AI = AI, applied = function()
    for _, e in ipairs(raid.bots or {}) do
        if valid(e.bot) then AI.tuneBody(e) end
    end
end })
-- Raid conditions (#78, conditions.lua): an event set-up applied while a raid map is loaded, picked in the launcher or
-- the lobby's REGION picker.
Conditions = require("conditions")
Conditions.init({ log = log, project = PROJECT, tuning = Tuning, tables = { Rivals = Rivals.CFG, Crew = Crew.CFG, CFG = CFG } })
Rivals.conditions = Conditions
Minefield = require("minefield")
Minefield.init({ log = log, valid = valid, conditions = Conditions })
-- Civilians (#81, civilians.lua): miners, prisoners and workers who run instead of fighting.
Civilians = require("civilians")
Civilians.init({ log = log, valid = valid, lib = lib, dist = dist, navLib = navLib, navMesh = navMesh,
    queryFilter = queryFilter, offLimits = PlayAreas.offLimits, arm = Bots.arm, voice = Voice, female = Female,
    rivals = Rivals })
Civilians.setRaid(raid)
Rivals.onStation = Civilians.station
Missions = require("missions")
Missions.init({ log = log, valid = valid, lib = lib })
-- Manning a turret yourself (gunseat.lua): the seat's client half (turning, firing, getting up) that never runs offline.
Gunseat.init({ log = log, valid = valid })
Minimap.init({ log = log, valid = valid, lib = lib, missions = Missions, crew = Crew, raid = function() return raid end })
require("killstats").onKills = Minimap.noteKills -- your kill list growing turns recent deaths into map markers (#326)
BotDamage.init({ log = log, valid = valid, bots = function() return raid.spawned and raid.bots end })

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
    patchClientBranches()
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
    -- A new world: the overlay found in the last one went with it (valid() on it would read freed memory).
    if pgosOverlay.world ~= raid.world then pgosOverlay.w, pgosOverlay.world = nil, raid.world end
    -- (in a raid map, not past its first minute: a co-op joiner never has it, and kept scanning every 10 s, #254)
    local inRaidMap = not worldName:find("/Maps/MainMenu", 1, true)
    if not valid(pgosOverlay.w) and now >= pgosOverlay.findAt and not (space and raid.revealed)
        and not (inRaidMap and age > 60) then
        pgosOverlay.findAt = now + (age < 30 and 1 or 10)
        pgosOverlay.w = FindFirstOf("PgosOverlay_BP_C")
        if valid(pgosOverlay.w) then log(("social overlay found %.1fs into the map: kept collapsed"):format(age)) end
    end
    if valid(pgosOverlay.w) and pgosOverlay.w:GetVisibility() ~= 1 then pgosOverlay.w:SetVisibility(1) end
    -- bridge/female_toggle: F2 without the keyboard (testing, like bridge/god.txt).
    local toggle = Aux.due("female", 2) and io.open(FEMALE_FLAG, "r")
    if toggle then
        toggle:close()
        os.remove(FEMALE_FLAG)
        Female.togglePlayer()
    end
    Lobby.tick(pc, age, worldName:find("/Maps/MainMenu", 1, true) ~= nil) -- the main menu's own work (lobby.lua)
    Launch.update(pc) -- an offline search that's over: the match (launch.lua)
    -- Space maps (where matchmaking puts you, in your ship) get the loadout and extraction; their fights are ship
    -- AI, so no navmesh or soldiers there.
    if not (space or worldName:find("/Maps/Raids/", 1, true)) then return end
    raid.space = space
    RaidTime.update() -- the launcher's raid length, once per raid (raidtime.lua, #159)
    if space then ShipSpeed.update(pc) end -- the Rustbucket's speed and the helm boost (shipspeed.lua, #207)
    if space and not raid.revealed then Launch.veilUntilAboard(pc, world) end
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
    if raid.inputDone then
        local okp, errp = pcall(LevelProps.update, age)
        if not okp then log("level props: " .. tostring(errp)) end
    end
    if space and raid.readyAt then
        local aff = Aux.due("autofly", 1) and io.open(PROJECT .. "bridge/autofly", "r") -- testing: "<station name>" or "x y z"; gone = stop
        if aff == false then -- not due: keep the last answer
        elseif aff then
            local line = aff:read("l") or ""
            aff:close()
            local x, y, z = line:match("^(%-?[%d.]+)%s+(%-?[%d.]+)%s+(%-?[%d.]+)")
            raid.autofly = x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } or Rivals.stationAt(line)
        else
            raid.autofly = nil
        end
        Space.updateLevelEffects(pc, world)
        Interiors.update(pc, raid, world)
    end
    -- bridge/menu_toggle: opens or closes the tuning menu without the keyboard (testing, like bridge/god.txt).
    local flagsDue = Aux.due("menuFlags", 1)
    local flag = flagsDue and io.open(MENU_FLAG, "r")
    if flag then
        local line = flag:read("l")
        flag:close()
        os.remove(MENU_FLAG)
        if line and line ~= "" then Tuning.command(line) else Tuning.toggle(pc) end
    end
    -- bridge/debug_cmd: a debug menu action id (see debugactions.lua), or empty to open or close the menu.
    flag = flagsDue and io.open(DEBUG_FLAG, "r")
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
    local immune = DebugActions.godMode()
    if pawn.bCanBeDamaged == immune then pawn.bCanBeDamaged = not immune end
    DebugActions.holdStamina(pawn) -- god mode: unlimited stamina

    if not raid.loadout and Loadout.ensureHud(pc) then raid.loadout = os.clock() Loadout.applyLoadout(pc) end
    if raid.ownOverlay then Loadout.ensureHud(pc) end -- collapses ours once the game's own overlay appears
    if Loadout.returnAfterExtract(pc) then return end -- extracted (loadout.lua)
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
        if inPod and valid(raid.target) then Space.hidePodGuns(raid.target, pawn) end
        if onFoot and raid.podGuns then
            for _, g in pairs(raid.podGuns) do
                if valid(g) then g:SetActorHiddenInGame(false) end
            end
            raid.podGuns, raid.podScans = nil, nil
        end
        if onFoot then raid.target = pawn end
        if raid.readyAt then Space.updateSun(onFoot) end
        if raid.readyAt and not raid.play then PlayAreas.mapPlayAreas() end
        if raid.play and raid.space and onFoot then PlayAreas.rescan(pawn:K2_GetActorLocation()) end
        -- the loadout's guns arrive unequipped: draw the first one once they've spawned
        if onFoot and raid.loadout and not raid.drawn and os.clock() - raid.loadout >= 2 then
            raid.drawn = true
            if not valid(pawn.CurrentWeapon) then Loadout.equipCarried(pawn) end
        end
        if raid.readyAt and not raid.floorLoot then Loadout.spawnFloorLoot(pc) end
        if raid.readyAt and os.clock() >= (raid.cardAt or 0) then
            raid.cardAt = os.clock() + Space.CARD.CHECK
            local ok, err = pcall(Space.guardKeyCard, pc)
            if not ok then log("key card: " .. tostring(err)) end
        end
        if raid.readyAt and valid(raid.target) then
            local ok, err = pcall(Missions.update, pc, raid.world, raid.target)
            if not ok then log("missions: " .. tostring(err)) end
            pcall(Minefield.update, pc)
            local okc, errc = pcall(Civilians.update, pc) -- (#81)
            if not okc then log("civilians: " .. tostring(errc)) end
            Space.update(pc, worldName)
        elseif raid.revealed and valid(raid.target) and not valid(world.AuthorityGameMode) then
            -- A co-op joiner: its veil can lift without readyAt (it gave up on streaming), and everything above is the
            -- host's to do (floor loot, mines, civilians, rivals). Only the contract actors are its own business: its
            -- tasks and its minimap's places come from them (the minimap was an empty box, #214).
            local ok, err = pcall(Missions.update, pc, raid.world, raid.target)
            if not ok then log("missions: " .. tostring(err)) end
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
        Bots.spawnRaidBots(pc)
        Loadout.spawnFloorLoot(pc)
        if not valid(pawn.CurrentWeapon) and not Loadout.equipCarried(pawn) and CFG.GIVE_GUN then Loadout.startGiveGun(pc) end
    end
    if raid.donor then Loadout.finishGiveGun(pc) end
    Loadout.keepGunLoaded()
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
    Bots.updateBots(pc)
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
        local range = AI.gunshotRadius(w, CFG.GUNSHOT_RANGE * (isBot and CFG.BOT_GUNSHOT_SCALE or 1),
            CFG.CALIBRE_EFFECT, CFG.SUPPRESSED_GUNSHOT)
        local ok, err = pcall(AI.noise, owner:K2_GetActorLocation(), range, "gunshot", owner:GetAddress())
        if not ok then log("gunshot noise failed: " .. tostring(err)) end
    end
    if valid(owner) and not isBot then raid.playerShotAt = os.clock() end -- (civilians.lua: they run from gunfire)
    if isBot then
        pcall(DeathScreen.botShot, w, owner)
        local okr, errr = pcall(Bots.botShot, w, owner)
        if not okr and not raid.reloadErr then raid.reloadErr = true log("bot reload: " .. tostring(errr)) end
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
        pcall(function() Minimap.noteDeath(bot:K2_GetActorLocation()) end) -- a kill marker if it was yours (#326)
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
-- (not while typing in the stash search: "nickel" turned the minimap off)
function Aux.unlessTyping(fn) return function() if not (InvQol and InvQol.typing()) then fn() end end end
RegisterKeyBind(Key.N, function() table.insert(pending, Aux.unlessTyping(Minimap.toggle)) end)
RegisterKeyBind(Key.M, function() table.insert(pending, Aux.unlessTyping(Minimap.expand)) end)
RegisterKeyBind(Key.B, function() table.insert(pending, Aux.unlessTyping(Minimap.next)) end)
-- Stash hotkeys (invqol.lua): K quick move, J discard (twice) for the item under the mouse. Neither key is bound by the game.
-- Space at the helm: a boost, like the drop pod's (shipspeed.lua, #207). On foot Space stays the game's jump. (This
-- UE4SS has no Shift key, only Shift as a modifier; Space does nothing at a frigate's helm, checked.)
RegisterKeyBind(Key.SPACE, function() table.insert(pending, ShipSpeed.boost) end)
RegisterKeyBind(Key.K, function() table.insert(pending, function() if InvQol then InvQol.hotkey("move") end end) end)
RegisterKeyBind(Key.J, function() table.insert(pending, function() if InvQol then InvQol.hotkey("discard") end end) end)
-- F by an armed station mine with a ToolKit: the defusal board (defuse.lua, #197). The game's own F (use) carries on;
-- a mine isn't usable, so next to one it does nothing of its own.
RegisterKeyBind(Key.F, function() table.insert(pending, Defuse.key) end)
-- R at the helm by a space mine (the ship's salvage key; it only opens the board while that prompt is up).
RegisterKeyBind(Key.R, function() table.insert(pending, function() Defuse.key("R") end) end)

-- The debug menu's buttons (debugactions.lua).
DebugActions.init({ log = log, valid = valid, lib = lib, CFG = CFG, RAID_OPTS = RAID_OPTS, aux = Aux, rivals = Rivals,
    bots = Bots, loadout = Loadout, menuClosed = menuClosed })
Defuse.init({ log = log, valid = valid, lib = lib, menuClosed = menuClosed })
DeathScreen.init({ log = log, valid = valid, lib = lib })

math.randomseed(os.time())
log("loaded")
