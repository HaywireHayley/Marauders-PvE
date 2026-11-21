-- Rivals: player-like crews on space maps, as many as a live raid had players.
--
-- Each crew has a ship (an AI frigate it flies), 1-4 members with their own loadout (weapon tier, armour, look,
-- skill) and a plan: fly to a station or one of the big AI frigates, dock, go through the airlock and raid it for a
-- few minutes, move on, and finally extract. A crew that sees your ship may attack it: orbit and shoot, then pull
-- alongside and breach. Boarders come in at your ship's breach points and hunt you; if you're not aboard they wait
-- for you (an ambush when you come back).
--
-- Bodies only exist near you. A crew raiding a station you're not in is simulated (timers, a small chance of losing
-- a member); when you walk into that station they materialize, through the airlock if they just docked, otherwise
-- somewhere inside, and walk the station. Leaving the station puts them back into the simulation (health kept).
-- Their fighting is the director's soldier AI (cover, peeking, strafing, sprinting), with player-like senses.
--
-- Findings this relies on (see NOTES.md, "Player-like rival bots"):
--   * AI frigates (Ship_*_Pawn_Ai_Child_C) spawn with SpawnAIFromClass and fly anywhere with a direct
--     MoveToLocation (no pathfinding: space has no navmesh); BB "Enemy" + focus makes their tree shoot.
--   * Bodies: GOAPNodeBot_Raider_C (the player-model raider: head CharacterMesh0 + body CharacterBody0 + helmet/chest/
--     backpack meshes) with a RaidAIController (the GOAP brain doesn't run offline). A raider spawned at runtime has no
--     kit rows of its own, so equipKit gives it rows from the game's item table (gear.lua) and runs the game's kit step.
--   * Station interiors have baked navmesh; the player's ship interior doesn't, so the director rebuilds the
--     navmesh at runtime on space maps (with a bounds volume for your ship's interior).
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local Out = require("outref") -- releases UE4SS's out-param registry refs (outref.lua)
local Kills = require("killstats") -- your rival kills show as Marauders in the end-of-raid kill list

local R = {}
local X -- context from main.lua: log, valid, lib, navLib, navMesh, queryFilter, dist, arm, wake, engage, raid()

-- Destroy an actor that may already be gone (killed, or its level unloaded mid-travel): a failed call no longer aborts
-- the rest of the update.
function R.destroy(a)
    if a and X.valid(a) then pcall(function() a:K2_DestroyActor() end) end
end

local CFG = {
    -- Population: a live raid filled the map's frigate interior slots (FrigInteriorSpawn): one player per ship on
    -- solo maps, crews of 2-4 on crew maps. You take one slot.
    -- Defaults are set to what a live solo raid usually had, not a full server: a handful of other ships, mostly solo
    -- players up to full crews. The F3 "How many" tab (and CREWS = 0, every free slot filled) turns it up.
    CREW_SIZE = { 1, 4 },           -- people per rival crew (solo maps were one player per ship; live crew maps had 3-4)
    MAX_CREWS = 15,
    CREWS = 5,                      -- rival crews per raid; 0 = one per free player slot (up to MAX_CREWS: 11 on solo maps)
    BARON = 0,                      -- event (#78): 1 = one crew in every raid is the Red Baron's (makeBaron; F3 Rival ships)
    ARRIVAL_SPREAD = { 5, 60 },     -- crews launch from their spawn points this many seconds after you are aboard
    STATIONS_PER_RAID = { 2, 4 },   -- each crew raids this many places before extracting
    DOCK_SECONDS = { 200, 450 },    -- time spent inside a station
    SIM_DEATH_PER_MIN = 0.02,       -- simulated: chance per member per minute in a station of dying there
    -- Ships
    -- Hulls: the player ship designs (DT_ShipInfo): a base pawn (all fly under an AI controller), the design's own hull
    -- mesh (same skeleton as its base, so the turret sockets are there) and its turrets (DT_ShipInfo Turret01/02Type).
    HULLS = {
        { name = "Light Scout", row = "FrigateScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/StarterShipLight01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "Dual25mm" }, weight = 3 },
        { name = "Rustbucket", row = "FrigateStarter_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/StarterShipRust01_SkelMesh", inside = "FrigateInside_Starter", turrets = { "Singular" }, weight = 2 },
        { name = "Cruiser Scout", row = "CruiserScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/Meshes/CruiserScout01_Skelmesh", inside = "Scout_Insides/FrigateInside_CruiserScout", turrets = { "RocketArtillery" }, weight = 2 },
        { name = "Breacher Scout", row = "BreacherScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/Meshes/BreacherScout01_SkelMesh", inside = "Scout_Insides/FrigateInside_BreacherScout", turrets = { "Flak" }, weight = 2 },
        { name = "Patrol Scout", row = "CorvetteScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/Meshes/CorvetteScout01_SkelMesh", inside = "Scout_Insides/FrigateInside_CorvetteScout", turrets = { "Torpedo" }, weight = 2 },
        { name = "Assault Scout", row = "AssaultScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/Meshes/AssaultScout_01_SkelMesh", inside = "Scout_Insides/FrigateInside_AssaultScout", turrets = { "DualRockets" }, weight = 2 },
        { name = "Raider Scout", row = "RaiderScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/Meshes/RaiderScout01_Skelmesh", inside = "Scout_Insides/FrigateInside_RaiderScout", turrets = { "75mm" }, weight = 2 },
        { name = "Marauder Scout", row = "MarauderScout_Ship", pawn = "Ship_ScoutFrigate01_Pawn", mesh = "05_StarterFrigateLight01/Meshes/MarauderScout_01_SkelMesh", inside = "Scout_Insides/FrigateInside_MarauderScout", turrets = { "RocketArtillery" }, weight = 2 },
        { name = "Light Interceptor", row = "FrigateFast_Ship", stand = "FrigateScout_Ship", pawn = "Ship_FastFrigate01_Pawn", mesh = "03_FastFrigate01/FastFrigate01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "Dual25mm" }, weight = 3 },
        { name = "Solar Interceptor", row = "SolarInterceptor_Ship", stand = "FrigateScout_Ship", pawn = "Ship_FastFrigate01_Pawn", mesh = "03_FastFrigate01/Meshes/SolarInterceptor01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "DualRockets" }, weight = 2 },
        { name = "Star Interceptor", row = "StarInterceptor_Ship", stand = "FrigateScout_Ship", pawn = "Ship_FastFrigate01_Pawn", mesh = "03_FastFrigate01/Meshes/StarInterceptor01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "Torpedo" }, weight = 2 },
        { name = "Galaxy Interceptor", row = "GalaxyInterceptor_Ship", stand = "FrigateScout_Ship", pawn = "Ship_FastFrigate01_Pawn", mesh = "03_FastFrigate01/Meshes/GalaxyInterceptor01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "RocketArtillery" }, weight = 2 },
        { name = "Raider Interceptor", row = "RaiderInterceptor_Ship", stand = "FrigateScout_Ship", pawn = "Ship_FastFrigate01_Pawn", mesh = "03_FastFrigate01/Meshes/RaiderInterceptor01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "75mm" }, weight = 2 },
        { name = "Marauder Interceptor", row = "MarauderInterceptor_Ship", stand = "FrigateScout_Ship", pawn = "Ship_FastFrigate01_Pawn", mesh = "03_FastFrigate01/Meshes/MarauderInterceptor01_SkelMesh", inside = "FrigateInside_DefaultScout", turrets = { "RocketArtillery" }, weight = 2 },
        { name = "Heavy Frigate", row = "FrigateHeavy_Ship", stand = "FrigateCapitalShip_Ship", pawn = "Ship_Frigate01_Pawn", mesh = "Frigate01/Frigate01_Skel.Frigate01_Skel_Frigate01_Mesh", inside = "FrigateInside_Capital", turrets = { "75mm" }, weight = 2 },
        { name = "Heavy Cruiser", row = "HeavyCruiser_Ship", stand = "FrigateCapitalShip_Ship", pawn = "Ship_Frigate01_Pawn", mesh = "Frigate01/Meshes/HeavyCruiser01_SkelMesh", inside = "FrigateInside_Capital", turrets = { "RocketArtillery" }, weight = 1.5 },
        { name = "Heavy Destroyer", row = "HeavyDestroyer_Ship", stand = "FrigateCapitalShip_Ship", pawn = "Ship_Frigate01_Pawn", mesh = "Frigate01/Meshes/HeavyDestroyer01_SkelMesh", inside = "FrigateInside_Capital", turrets = { "Triple" }, weight = 1.5 },
        { name = "Heavy Warship", row = "HeavyWarship_Ship", stand = "FrigateCapitalShip_Ship", pawn = "Ship_Frigate01_Pawn", mesh = "Frigate01/Meshes/HeavyWarship01_SkelMesh", inside = "FrigateInside_Capital", turrets = { "Howitzer" }, weight = 1.5 },
        { name = "Heavy Raider", row = "HeavyRaider_Ship", stand = "FrigateCapitalShip_Ship", pawn = "Ship_Frigate01_Pawn", mesh = "Frigate01/Meshes/HeavyRaider01_SkelMesh", inside = "FrigateInside_Capital", turrets = { "Triple" }, weight = 1.5 },
        { name = "Heavy Marauder", row = "HeavyMarauder_Ship", stand = "FrigateCapitalShip_Ship", pawn = "Ship_Frigate01_Pawn", mesh = "Frigate01/Meshes/HeavyMarauder01_SkelMesh", inside = "FrigateInside_Capital", turrets = { "RocketArtillery" }, weight = 1.5 },
        { name = "Strike Frigate", row = "StrikeFrigate_Ship", pawn = "Ship_RedBaron_StrikeFrigate01_Pawn", mesh = "08_RedBaron_StrikeFrigate/SkelMesh_RedBaron_StrikeShip", inside = "FrigateInside_Strike", turrets = { "RocketArtillery" }, weight = 2 },
        { name = "Vulture Frigate", row = "FrigateVIP_Ship", stand = "StrikeFrigate_Ship", pawn = "Ship_VIPFrigate01_Pawn", mesh = "VIPFrigate01/VipShip01_SkelMesh", inside = "FrigateInside_Strike", turrets = { "Singular" }, weight = 1 },
        { name = "Capital Ship", row = "FrigateCapitalShip_Ship", pawn = "Ship_CapitalShipFrigate01_Pawn", mesh = "06_CapitalShip/CapitalShip01_SkelMesh", inside = "FrigateInside_Capital", turrets = { "75mm", "Torpedo" }, weight = 0.5 },
        { name = "Dreadnought", row = "CapitalDreadnought_Ship", pawn = "Ship_CapitalShipFrigate01_Pawn", mesh = "06_CapitalShip/Meshes/DreadnoughtCapitalShip01_SkelMesh", inside = "Capital/FrigateInside_CapitalDreadnought", turrets = { "Triple", "Triple" }, weight = 0.4 },
        { name = "Raider Dreadnought", row = "RaiderDreadnought_Ship", pawn = "Ship_CapitalShipFrigate01_Pawn", mesh = "06_CapitalShip/Meshes/RaiderDreadnoughtCapitalShip01_SkelMesh", inside = "Capital/FrigateInside_RaiderDreadnought", turrets = { "Howitzer", "Flak" }, weight = 0.4 },
        { name = "Marauder Dreadnought", row = "MarauderDreadnought_Ship", pawn = "Ship_CapitalShipFrigate01_Pawn", mesh = "06_CapitalShip/Meshes/MarauderCapitalShip01_SkelMesh", inside = "Capital/FrigateInside_CapitalMarauder", turrets = { "Triple", "Nuclear" }, weight = 0.4 },
    },
    -- Turret types -> the turret classes the game ships (Ships_Extras/Turrets). Types with no class in this build
    -- (flak, triple, howitzer, nuclear, dual rockets) use the closest one. range: how far a crew fires it; spread: deg;
    -- speed: the projectile's (its ProjectileMovement InitialSpeed), for leading moving targets.
    TURRET_TYPES = {
        Singular = { cls = "InGame_Turret_SingleTurret01", range = 7000, spread = 1.5, speed = 15500 },
        Dual25mm = { cls = "InGame_Turret_Dual25mm01", range = 7000, spread = 2.0, speed = 18500 },
        Flak = { cls = "InGame_Turret_Dual25mm01", range = 6000, spread = 3.0, speed = 18500 },
        ["75mm"] = { cls = "InGame_75mm_Turret01", range = 8500, spread = 1.0, speed = 10000 },
        Triple = { cls = "InGame_75mm_Turret01", range = 8500, spread = 1.5, speed = 10000 },
        Howitzer = { cls = "InGame_75mm_Turret01", range = 9500, spread = 1.0, speed = 10000 },
        RocketArtillery = { cls = "InGame_Turret_RocketArtillery01", range = 8000, spread = 3.0, speed = 17500 },
        DualRockets = { cls = "InGame_Turret_RocketArtillery01", range = 7500, spread = 2.5, speed = 17500 },
        Torpedo = { cls = "InGame_Turret_TorpedoLauncher", range = 9000, spread = 1.0, speed = 3500 },
        Nuclear = { cls = "InGame_Turret_TorpedoLauncher", range = 9000, spread = 0.5, speed = 3500 },
    },
    -- Your gunner on a stationary turret (RaidSubNodeActor_Turret): fires from as far as those turrets fire at you
    -- (their FireDistance, 13500), not the hull guns' ship-to-ship ranges above, so you can snipe them back (#47).
    TURRET_RANGE_STATION = 13500,
    TURRET_ARC = 60,                -- deg either side of the nose the turrets swing (their own TurretMax/MinYaw)
    -- Your crew's gunner on your ship's turrets (#88: "only kept shooting ahead", "too far" on ships it could see). Shells
    -- never expire (every turret's shell has InitialLifeSpan 0), so the reach is ours to set.
    GUNNER_ARC = 170,               -- deg either side of the nose they swing your turrets (all but dead astern)
    GUNNER_RANGE = 1.75,            -- x each turret type's range below (75mm: 85 m -> 149 m; stationary turrets: 135 m)
    GUNNER_PITCH_SLACK = 45,        -- deg past the barrels' lift/dip they still fire, along the true aim (rivals: 6): a
                                    -- stationary turret below as you fly over it is 40-60 deg down
    TURRET_PITCH = { -15, 10 },     -- deg the barrels dip and lift (what every type's anim shows; some lift further)
    TURRET_SWING = 3,               -- x the turret's own traverse speed (20 deg/s yaw, 10 pitch) the gunners swing it at
    TURRET_ON_AIM = 2,              -- deg: a turret fires once its barrel is this close to where its gunner aims
    TURRET_PITCH_SLACK = 6,         -- deg: a target this far past the barrels' lift/dip limit is still fired at (near
                                    -- misses); further than that the turret holds
    -- Ship gunnery (fireTurrets; your crew's gunner too, with a skill from their level, crew.lua). Each crew's gunnery
    -- skill (0 = green, 1 = crack) is rolled once; it scales every error below between its worst (skill 0) and best.
    GUN_SKILL = { 0.3, 0.9 },       -- rival crews' gunnery skill, least and most
    TURRET_SPREAD = 1.0,            -- every turret type's spread x this
    GUN_SPREAD_SKILL = { 2.5, 0.8 },-- ...and x this, from a green gunner to a crack one
    GUN_FIRST_MISS = 10,            -- deg: how far off a green gunner's first shots on a new target land (crack: 30%)
    GUN_SETTLE = 0.3,               -- share of that error a crack gunner walks off per volley (green: half as much)
    GUN_LEAD_ERROR = 0.4,           -- a green gunner misjudges the lead on a moving ship by up to this share (crack: none)
    GUN_JINK = 2.0,                 -- deg of new error for every 10 deg the target turns between volleys (crack: half)
    GUN_WANDER = 2.5,               -- deg: a green gunner's aim drifts this much per volley even when settled (crack: none)
    TURRET_SWAP = 0.25,             -- chance a crew refitted a turret slot with another type
    SHIP_TREE = "/Game/Blueprints/Pawns/BotBehaviorShip.BotBehaviorShip",
    DOCK_ARRIVE = 1500,             -- a ship this close to its berth's approach point starts docking
    BERTH_APPROACH = 3500,          -- ships line up this far out from their berth, then glide in nose first
    HULL_MARGIN = 2000,             -- docking: ships keep this far outside the station's bounds till they're on the lane:
    LANE_WIDTH = 1500,              -- ...the berth's approach line, this close to it and out past BERTH_APPROACH / 2
    DOCK_LANE = 900,                -- the glide in only starts this close to the lane's line (and DOCK_ARRIVE of its point)
    BERTH_CLEAR = 500,              -- a dock volume's middle (nodes with no berth transform) is moved out of the hull
    BERTH_CLEAR_MAX = 3000,         -- ...till a sphere this big fits there, at most this far
    HOLD_OUT = 2500, HOLD_SPACING = 1500, -- every berth taken: wait this far beyond the approach point, crews spread out
    DOCK_GLIDE = 7,                 -- seconds to glide into the berth...
    UNDOCK_GLIDE = 5,               -- ...and back out to the approach point when leaving
    DERELICT_CLEAR = 10000,         -- a docked crew wiped out: their ship drifts this far out past the approach point
    DERELICT_GLIDE = 15,            -- (over this many seconds), clear of the berth, its lane and the ships holding off
    ALONGSIDE = 3000,               -- at a big AI frigate the berth is this far off its side, matching its heading
    BERTH_WAIT = 10,                -- with every berth taken, a crew holds off the station this long, then boards anyway
                                    -- (breaching in, as players do) with its ship parked where it holds
    SHIP_SIGHT = 18000,             -- crews notice ships (yours or other crews') this close
    ATTACK_COOLDOWN = 120,          -- a crew that sized up a ship reconsiders attacking it only this much later
    ATTACK_CHANCE = 0.45,           -- x aggression^2 (0..1 per crew): ~15% of crews attack a ship they see
    MAX_ON_SHIP = 2,                -- crews attacking any one ship (yours or a rival's) at the same time
    ORBIT = { 2500, 4500 },         -- boarding: the ship holds this far off while its pods go in
    -- Attack runs (the bow gun only fires forward): fly at the target firing, overshoot past it, swing out, come round.
    RUN_OVERSHOOT = 2500,           -- past the target, off to one side by RUN_OFFSET so they don't ram it
    RUN_OFFSET = 1600,              -- at least (the two hulls' sizes plus PASS_CLEAR, if more)
    RUN_EXTEND = { 3500, 5000 },    -- then swing out this far before the next run
    -- Dogfighting (manoeuvre()): a fight is a string of manoeuvres picked by the crew's style (rolled per crew):
    -- passes (in firing, by the target to one side, out the far side and on), circling it, closing to short range
    -- and holding there, getting on its tail, breaking away when hit. The turrets only swing TURRET_ARC either side of
    -- the nose, so every manoeuvre but the short swing-outs keeps the target ahead (wider than that, nobody fires).
    -- Ships never fly into each other: one heading for another hull within the next SEP_LOOK seconds (closer than
    -- SEP_CLEAR plus both sizes) breaks off first.
    PASS_CLEAR = 600,               -- a pass goes by this far clear of the target's hull...
    PASS_LIFT = 600,                -- ...and up to this far above or below it
    CIRCLE_R = { 1800, 2800 }, CIRCLE_SECONDS = { 10, 16 }, -- plus both sizes
    CIRCLE_LEAD = 80,               -- degrees ahead on the circle: the chord there keeps the target ~50 deg off the nose
    STANDOFF_R = { 2600, 3600 }, STANDOFF_SECONDS = { 7, 11 }, -- plus both sizes; drifting sideways STANDOFF_DRIFT
    STANDOFF_DRIFT = 1500,
    TAIL_BACK = 1600, TAIL_SECONDS = { 8, 12 },    -- plus both sizes
    BREAK_DIST = { 3000, 4500 }, BREAK_SECONDS = { 3, 5 }, BREAK_WHEN_HIT = 0.3,
    SEP_LOOK = 2.5, SEP_CLEAR = 400, SEP_HOLD = 2.0,
    STYLES = {
        jouster = { pass = 5, circle = 1, standoff = 1, tail = 2 },
        brawler = { pass = 2, circle = 4, standoff = 1, tail = 3 },
        sniper = { pass = 1, circle = 2, standoff = 5, tail = 1 },
    },
    NOSE_TURN = 50,                 -- deg/s: while approaching, the nose is turned onto the target (aiming)
    ENGAGE_MAX = { 80, 160 },       -- seconds a crew keeps a fight going before breaking off
    DIEHARD = 0.35,                 -- share of crews that fight to the death: never run, never break off a fight
    -- Ship guns: AI frigates list a bow gun (InGame_BowGun_50Cal) in DefaultInventoryClasses that offline nobody
    -- spawns, and their own ShootEnemy only fires for ships with a crewed interior. Rivals get the gun (spawned for them) and
    -- are fired from here in bursts while the target is in front of them.
    GUN_PATH = "/Game/Blueprints/Ships_Extras/BowGuns/InGame_BowGun_50Cal",
    GUNS_PER_STEP = 2,              -- bow guns spawned per arming step (once a second)
    GUN_RANGE = 6500,
    GUN_CONE = 25,                  -- degrees off the nose the gun is fired at
    BURST = { 1.2, 3.0 },
    BURST_PAUSE = { 0.6, 1.8 },
    -- Boarding. Decided once per fight: crews of 2+ usually send one boarder while the rest keep flying and shooting;
    -- whole crews board less often. AI frigates have no interior, so a fight aboard a rival's ship is simulated
    -- (BOARD_ROUND): if the boarders win they keep the ship.
    BOARD_ONE = 0.45,               -- crews of 2+: one member boards
    BOARD_ALL = 0.15,               -- everyone boards (solo crews: this is their only boarding chance)
    RIVAL_BOARD_ONE = 0.4,          -- the same when the target is another crew's ship
    RIVAL_BOARD_ALL = 0.1,
    BOARD_ROUND = { 3, 6 },         -- seconds between kills in a fight aboard a rival's ship
    BOARD_SKILL = 0.35,             -- how much the skill gap moves those fights' odds from even
    BREACH_AFTER = { 20, 55 },      -- seconds of shooting before the boarders launch...
    BREACH_HULL = 0.5,              -- ...or sooner once the target's hull is below this fraction
    -- End of the raid: crews head out when this much time is left (per crew, so they don't all go at once)
    EXTRACT_REMAINING = { 150, 420 },
    -- A leaving ship that gets no closer to its exit (by EXIT_PROGRESS) extracts where it is: after EXIT_STALL_NEAR
    -- seconds within EXIT_NEAR of it, EXIT_STALL anywhere else.
    EXIT_PROGRESS = 1000, EXIT_NEAR = 12000, EXIT_STALL_NEAR = 15, EXIT_STALL = 45,
    SIM_CLASH_PER_MIN = 0.25,       -- two simulated crews in the same station: chance per minute they run into each other
    -- Station defenders: the raiders/bosses the station levels place themselves (GOAPNodeBot_Raider_C / _Boss_C, the
    -- live server's station NPCs; asleep offline with a GOAP brain that doesn't run). Taken over when you first enter
    -- the station. Every station gets at least MIN_DEFENDERS: more raiders like its own (same body, gear and look as
    -- one of them, a gun of a class one of them carries, same side); a station with none of its own gets the raid
    -- maps' soldier types instead.
    PLACED = { "GOAPNodeBot_Raider_C", "GOAPNodeBot_Boss_C" },
    MIN_DEFENDERS = 6,      -- (about what the levels place: Space_Solo_01 has 25 across its stations, Navy Outpost 7)
    -- Station size: its navmesh box's floor area (Space_Solo_01's run from ~4,000 m2 to ~107,000 m2). Guards scale
    -- with it (MIN_DEFENDERS is for a STATION_AREA_MID station, between half and DEFENDERS_MAX_SCALE x that), and so
    -- does how many crews pick it (chooseStation): every STATION_AREA_PER_CREW m2 holds one crew before it counts
    -- as busy, and each busy station's pull falls by STATION_CROWD per crew-load it already holds.
    STATION_AREA_MID = 35000, DEFENDERS_MAX_SCALE = 1.5,
    STATION_AREA_PER_CREW = 25000,
    STATION_CROWD = 0.35,
    STRAY_EVERY = 8,        -- seconds between sweeps for placed NPCs the garrison missed (sweepStrays)
    STRAY_RANGE = 6000,     -- ...counting those this near you even outside the station's box
    GEAR_SLOTS = { "CharacterBody0", "Helemt", "ChestSlot", "Backpc" },
    POST_RADIUS = 900,              -- defenders walk about this close to where they are (until roamGuards sends them on)
    -- Spreading out (spreadPoint): idle guards and rival crews head for the part of the station furthest from everyone else
    SPREAD_POOL = 160,              -- walkable points kept per station, gathered outward from its airlocks and posts...
    SPREAD_GROW = 4,                -- ...this many more each update until full
    SPREAD_STEP = 2500,             -- each new point is searched for this far around an earlier one
    SPREAD_REACH = 15000,           -- ...and kept only this close to an airlock or a post (the navmesh runs on past stations)
    SPREAD_TRIES = 16,              -- pooled points scored per pick
    SPREAD_GAP = 600,               -- pooled points keep this far apart (without it 112 of Asteroid Mine's 160 sat in a
                                    -- few rooms, each within 5 m of a guard, 2026-11-14)
    SPREAD_SEEDS = { "SIGISLootSingleSpawner", "RaidAINodeStart", "SIGISContractActor" }, -- the pool starts at these
    GUARD_FIRST_ROAM = 10,          -- guards leave their posts within this many seconds of being taken over...
    GUARD_ROAM = { 60, 150 },       -- ...then move on to another part of the station this often
    ROAM_PATROL = 1200,             -- walking about within this radius of it in between
    POD_RANGE = 4500,               -- in this close, each crew member launches a breaching pod at your hull
    POD = "/Game/Blueprints/Ships/Ship_DropPod_Pawn",
    POD_SPEED = { 900, 3200 },      -- pods accelerate from this to this (units/s) over POD_ACCEL seconds
    POD_ACCEL = 1.5,
    POD_TIMEOUT = 12,               -- a pod that hasn't hit by then boards anyway
    BREACH_DELAY = 2.5,             -- after a pod embeds, its rider cuts through this much later
    BREACH_JOINED = 150,            -- a boarder spawn spot counts as inside if a path from inside ends this close to it
    BREACH_FALLBACK = 800,          -- ...and with no breach point inside, they come in this far around a point that is
    -- You boarding a rival: rival hulls have no interior, so one is spawned when your pod comes near (it brings its own
    -- level and a hull of its own, which is swapped for the rival's).
    -- Each design's interior is its row in the game's FrigData table, except where that row's level is the grey, roofless
    -- ShipBlockOut placeholder (every Interceptor, every Heavy, the Vulture): those get the closest real interior.
    INSIDES = "/Game/Blueprints/Prefabs/ShipInsides/",
    -- Interiors that are children of another interior Blueprint (probed in game 2026-11-19, GetSuperStruct): the parent
    -- is loaded first. Loading the child alone while the game's background loader is part-way through the parent is a
    -- fatal "Could not find SuperStruct FrigateInside_DefaultScout_C to create FrigateInside_AssaultScout_C" (#192); a
    -- sync load of the parent itself makes the engine finish it first. Hull pawns all derive from Base_Frigate_Ship,
    -- which your own ship has always loaded.
    INSIDE_PARENTS = { ["Scout_Insides/"] = "FrigateInside_DefaultScout", ["Capital/"] = "FrigateInside_Capital" },
    SHIP_STOLEN_FILE = require("pvebackend") .. "ship_stolen.txt",
    -- Only the ship your pod is flying AT gets an interior (every ship within reach used to: three interiors for one
    -- flight, and after PLAYER_BOARD_MAX of them no ship could be boarded for the rest of the raid).
    PLAYER_BOARD_PREP = 16000,      -- your pod heading for a rival's ship this close: its interior starts loading
    PLAYER_BOARD_AIM = 25,          -- ...heading for = within this many degrees of the pod's course
    PLAYER_BOARD_CLOSE = 4000,      -- ...or this close, whichever way the pod points
    PLAYER_BOARD_RANGE = 1800,      -- this close to its centre: you're through the hull
    PLAYER_BOARD_TOUCH = 600,       -- or this close to its hull's surface (a pod rammed into a big hull stops far from the centre)
    PLAYER_BOARD_FORCE = 250,
    -- The game's own breach (its F prompt near a hull, or flying into it) moves the pod to one of the ship's breach
    -- sockets and brings you in by a wall. It failed on rival hulls only while they had no interior; now that the
    -- interior is loaded and paired as your pod heads for a ship, the game does the breach and ours (an instant teleport
    -- once you're near, which fired the moment the user's pod launched beside a ship pulled alongside) is off.
    -- The void rescue below still catches a breach that leaves you at 0,0,0. false: the old proximity teleport.
    PLAYER_BOARD_GAME = true,       -- this close to the hull the breach can't wait for the interior's navmesh any longer
    VOID_NEAR = 3000, VOID_RESCUE = 3, -- on foot this close to 0,0,0 for this long: rescued into your own ship
    -- The pod hit a hull before the breach was ready (interior still loading, or the hit came between two looks): the
    -- game then drops you at 0,0,0. The ship the pod was last seen at, this close and this recently, is boarded from there.
    VOID_BOARD_NEAR = 9000, VOID_BOARD_RECENT = 6, VOID_BOARD_WAIT = 12,
    -- Out of a pod anywhere else (a station's docking arm): this long after, a body still parked for the flight is
    -- given back, and one left off any floor (Fortress's Pod_Spawner_Fortress6 sits in a shaft between decks) is put on
    -- the nearest floor below.
    POD_EXIT_CHECK = 1.5,
    SHIP_WATCH = { 1, 2 },          -- a docked crew leaves this many aboard (their team, their kind of kit) while they raid
    -- Ambient fights: while you fly, now and then two extra crews meet somewhere near you and fight to the death. They
    -- leave you alone unless you hit them; the winner limps off and extracts. They never appear in your view (user,
    -- 2026-11-16): every ship starts out to the side or behind where your camera looks (SKIRMISH_BEARING off it) and
    -- more than SKIRMISH_UNSEEN deg off its line.
    SKIRMISH_FIRST = { 20, 45 },    -- seconds of flying before the first one
    SKIRMISH_EVERY = { 70, 150 },   -- ...and between later ones (only one at a time)
    SKIRMISH_AHEAD = { 14000, 26000 }, -- this far from your ship...
    SKIRMISH_BEARING = { 110, 170 },-- ...this many deg either way off where your camera looks
    SKIRMISH_SIDE = 7000,           -- up to this far to either side of that line
    SKIRMISH_UNSEEN = 85,           -- every ship's start this far off your view's line at least (wider than any FOV corner)
    SKIRMISH_GAP = { 4000, 7000 },  -- the two ships start this far apart, closing on each other
    SKIRMISH_CLEAR = 9000,          -- not this close to a station or to any other ship
    SKIRMISH_MAX = 3,               -- per raid
    SKIRMISH_SHIPS = { 1, 3 },      -- ships on each side (two sides; bridge/rivals_skirmish holding a number sets it)
    SKIRMISH_SPACING = 3500,        -- a side's ships start this far apart
    SKIRMISH_ROCKS = 2500,          -- nothing solid this close to a ship's starting point (twice that round the middle)
    PROVOKE_SECONDS = 4,            -- hit within this long of you firing (and within 1.5 x gun range of you)...
    PROVOKE_CONE = 20,              -- ...while within this many degrees of where you're aiming: they turn on you
    SKIRMISH_HULL = 1,              -- ambient ships' hull x this: their real hull, as when you fight them yourself
    PLAYER_BOARD_MAX = 6,           -- interiors spawned per raid (each is a level in memory)
    POD_ALONG = { -300, 1000 },     -- pods aim for the hull's side, this far ahead of the ship's centre: never the engines
    POD_SIDE = 3000,                -- from this far out to the side
    HOLD_OFF = 3500,                -- the attacking ship holds this far off while its crew is aboard
    FLEE_HULL = { 0.1, 0.25 },      -- a crew's ship below this fraction of its hull runs and extracts (rolled per crew)
    ABOARD_WAIT = 240,              -- boarders give up waiting for you after this long and go back to their ship
    WRECK_SURVIVORS = { chance = 0.5, most = 2, hp = { 0.25, 0.6 } }, -- a ship shot down keeps 1..most of its crew
                                    -- alive this often, hurt (this share of their health); the rest lie dead aboard (#251)
    -- Bodies
    MATERIALIZE_MARGIN = 1500,      -- you count as in a station within this margin of its navmesh volume
    DEMATERIALIZE_AFTER = 20,       -- seconds outside a station before its rivals go back to being simulated
    FRESH_DOCK = 25,                -- a crew that docked this recently enters through the airlock
    MATERIALIZE_GAP = 3,            -- seconds between crews appearing in a station you walk into
    SHIP_FRAME_HZ_FOOT = 15,        -- while you're on foot, ships' glide, gunnery and turret swing run this often, not every
                                    -- frame (at the helm, in a turret seat or a pod: every frame). 0 = always every frame
    AWAKE_MAX = 16,                 -- bodies awake around you (guards, soldiers, rivals; parked ones don't count) before
                                    -- another crew waits aboard and station top-ups stop; 0 = no cap (F3 How many)
    INSIDE_AREA_PER_CREW = 10000,   -- crews walking a station at once: one per this many m2 (at least INSIDE_MIN).
    INSIDE_MIN = 2,                 -- The rest wait aboard and come in through an airlock as a place frees up: 11 crews
                                    -- docked at Colony Cruiser (30k m2, the map's only station) all appeared inside at
                                    -- once and every one spawned 10-16 m from someone (2026-11-14)
    -- Arriving through an airlock (stations with RaidFrigateStationDock airlocks): built in the closed chamber, the door
    -- opens once they're all armed (or after ARRIVAL_WAIT), they walk out, and it closes again after ARRIVAL_CLOSE.
    ARRIVAL_WAIT = 12, ARRIVAL_CLOSE = 10,
    ARRIVAL_MIN = 6,                -- the airlock cycles at least this long before the door opens
    ARRIVAL_STAGGER = 45,           -- one crew in through a station's airlocks at a time, this many seconds apart: two crews
                                    -- out of neighbouring airlocks at once fought on the spot and were dead in two minutes
    DOOR_OPENING = 7,               -- seconds the hatch takes to open (wheel, steam, swing): they wait for it
    LOCK_YOU = 700,                 -- not in a chamber you're standing in
    SPAWN_AWAY = 2500,              -- crews already inside appear at least this far from you
    SPAWN_CLEAR = 2000,             -- ...and this far from anyone else, built or still being built (all 4 crews in Penal
                                    -- Colony spawned 1-6 m from guards and each other and were dead in 20 s, 2026-11-14)
    SPAWN_POOL_READY = 60,          -- a station's spread pool holds this many points before anyone spawns into it...
    SPAWN_POOL_BURST = 16,          -- ...grown this many a update while it's short
    SPAWN_WAIT_MAX = 20,            -- seconds a crew waits for a clear spot before taking the best there is
    PATROL_RADIUS = 1500,           -- station rivals walk between points this far apart around an area...
    ROAM_SECONDS = { 50, 110 },     -- ...and move on to another area of the station this often
    BODY = "/Game/AI/GOAPNodeBot_Raider",
    SOLDIER = "/Game/Blueprints/Pawns/BotPawnMilitary", -- has the RaidAIController class bodies run on
    TREE = "/Game/Blueprints/Pawns/BotBehavior.BotBehavior",
    TEAM_BASE = 10,                 -- each crew is its own team (10 + crew id): bots only damage other teams
    RUSHERS = 0.4,                  -- crews that make straight for a station and dock, fighting only if shot at
    -- Loadouts follow your player level (gearscale.lua: centred on your level, mostly below it, a few far off either way).
    -- Off = the fixed TIERS odds below, whatever your level.
    SCALE_GEAR = 1, -- 1 = gear follows your level (gearscale.lua), 0 = TIERS' fixed odds (a slider in F3: Gear)
    -- Loadout tiers (like players' kits): price ranges into gear.lua (every row in the game is in at least one) and the
    -- chance of wearing each piece. With SCALE_GEAR they're only names (crew.lua looks a kit's name up here).
    TIERS = {
        { name = "budget", weight = 35, helmet = 0.4, chest = 0.3, backpack = 0.5,
          guns = { 0, 6500 }, helmets = { 0, 3300 }, chests = { 0, 3700 }, bags = { 0, 2100 } },
        { name = "mid", weight = 40, helmet = 0.75, chest = 0.7, backpack = 0.8,
          guns = { 2800, 10000 }, helmets = { 1300, 7400 }, chests = { 1500, 8600 }, bags = { 1200, 4600 } },
        { name = "geared", weight = 25, helmet = 1.0, chest = 1.0, backpack = 0.9,
          guns = { 7000, 1e9 }, helmets = { 3200, 1e9 }, chests = { 3600, 1e9 }, bags = { 2000, 1e9 } },
    },
    ITEM_TABLE = "/SIGISPlugin/ExampleBlueprints/SIGIS_ExampleItemData.SIGIS_ExampleItemData",
    AMMO_STACKS = { 1, 3 }, -- full stacks of the gun's ammo on the body
    AMMO_STACK = 60,
    MEDS = { 0, 2 },
    -- Station guards keep what they wear; their bags and pockets are rolled (rollCarried): ammo for each gun they hold,
    -- meds, and other items from gear.lua's loot / boxes / parts, priced up to a share of what they wear. Without a bag a bot
    -- has one pocket slot.
    CARRY_AMMO = { 20, 60 },
    CARRY_BAG = { 2, 5 },           -- other items in a bag, after the ammo and meds (the bag's grid takes what fits)
    POCKET_AMMO = 0.5, POCKET_MED = 0.2, -- no bag: the one pocket item is ammo, a med, or else loot / a part
    CARRY_CAP_MIN = 1500, CARRY_CAP_SHARE = 1.5, CARRY_JACKPOT = 0.05,
    CARRY_BOX = 0.06, CARRY_PART = 0.12, -- chance a pick is a sealed loot box (bags only) / a gun attachment
    FEMALE = 0.35,          -- share of rivals, soldiers, station guards and new recruits who are women; the launcher's
                            -- "Women among others" slider writes config/female_share.txt (percent), read by R.femaleShare
    GUN_WAIT = 6,           -- seconds for a rolled gun to arrive (the game spawns it a moment after the kit)
    BASE_HP = 100,                  -- worn armour isn't extra health: the game takes it off each hit (flat, per piece)
    -- Known interiors on the space maps (they're sublevels at fixed places): a point inside each one's navmesh volume.
    INTERIOR_ANCHORS = {
        { name = "Fortress", at = { X = 16542, Y = -33198, Z = -472 } },
        { name = "Merchant", at = { X = 60391, Y = 115903, Z = -587 } },
    },
    -- Space-side station nodes (owners of RaidDockingComponents), by class name -> interior name
    NODE_NAMES = { { "SpacePort", "Spaceport" }, { "Spaceport", "Spaceport" }, { "Merchant", "Merchant" },
        { "Fortress", "Fortress" }, { "Navy", "Navy Outpost" }, { "Outpost", "Navy Outpost" } },
    -- Other interiors (Space_Solo_02's) are named after the streaming volume around them and matched to a node by the
    -- first five letters of both names (LevelStreamingVolume_RebelBase <-> Node_RebelBase_01).
    VOLUME_NAMES = { rebel = "Rebel Base", penal = "Penal Colony", aster = "Asteroid Mine", minim = "Mini Mine",
        moonb = "Moon Base", capit = "Capital Ship", colon = "Colony Cruiser", plane = "Planet Killer" },
}

local PILOTS = { "Vex", "Nightjar", "Grub", "Halloran", "Kestrel", "Duke_Nukem_Jr", "salvage_sally", "Moth",
    "Brannigan", "xX_Reaver_Xx", "OldTom", "Pike", "Rook", "Sable", "Tallow", "Wrench", "Cinder", "Mags", "Hex",
    "Bolt", "Ivo", "Jinx", "Kade", "Lark", "Mercer", "Nox", "Orrin", "Pax", "Quill", "Ruckus", "Slag", "Teague",
    "Ulric", "Vossberg", "Wick", "Yarrow", "Zed", "CptCrunch", "Gravedigger", "Sputnik", "Babushka", "Lefty",
    "Sixgun", "Dutch", "Maverick", "Tinker", "Barnacle", "Ratchet", "Scuttle", "Hollow", "Grimsby", "Fennec" }
local SHIP_NAMES = { "Rusty Mule", "Widowmaker", "Lucky Strike", "Iron Gull", "Bad Penny", "Salt Witch",
    "Long Odds", "Crow's Due", "Black Tallow", "Stray Dog", "Brass Monkey", "Grey Mare", "Last Call", "Night Owl",
    "Red Herring", "Slow Burn", "Sea Hag", "Dead Reckoning", "Ill Wind", "Tin Can" }

local S -- per-raid state

-- Placed NPCs, as the game makes them: a spawn hook on their native class (masterNodeBot_C and the GOAPNodeBot_*_C
-- blueprints derive from RaidNodeBot), so the stray sweep doesn't need a FindAllOf. That walks every object in the
-- game, ~46 ms on a space map, and a sweep every few seconds was a steady hitch in fights (profile.txt, Space_Solo_02,
-- 2026-11-14). Entries: { o = object, placed = nil until its class is checked, then true/false }.
local NodeBots = { list = {}, hooked = false }

local AI = require("ai")
local Gear = require("gear")
local GearScale = require("gearscale") -- kits follow your player level
local Nav = require("shipnav")
local function valid(o) return X.valid(o) end
local function lib(p) return X.lib(p) end
local function dist(a, b) return X.dist(a, b) end
local function rnd(r) return r[1] + math.random() * (r[2] - r[1]) end
local function gauss() return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random()) end
local function pick(t) return t[math.random(#t)] end
local function weighted(list)
    local total = 0
    for _, e in ipairs(list) do total = total + e.weight end
    local r = math.random() * total
    for _, e in ipairs(list) do r = r - e.weight if r <= 0 then return e end end
    return list[#list]
end
local function loadClass(path)
    local name = path:match("([^/]+)$")
    local full = path .. "." .. name .. "_C"
    local c = lib(full)
    -- a cooked Blueprint has no object called just its package name: the class only comes with the "Name.Name" form
    if not valid(c) then pcall(LoadAsset, path .. "." .. name) c = lib(full) end
    return valid(c) and c or nil
end
local function helper() return lib("/Script/AIModule.Default__AIBlueprintHelperLibrary") end
local function inBox(b, l, margin)
    margin = margin or 0
    return math.abs(l.X - b.c.X) <= b.e.X + margin and math.abs(l.Y - b.c.Y) <= b.e.Y + margin
        and math.abs(l.Z - b.c.Z) <= b.e.Z + margin
end
local function say(pc, msg)
    X.log("[rivals] " .. msg)
    pcall(function() pc:ClientMessage(msg, FName("Event"), 5.0) end)
end


-- The rest of the rival code is in modules (issue #149: this file had used all 200 of Lua's locals):
--   rivalcrews (who the crews are), rivalships (berths, docking, the ships), rivalbodies (people on foot, spreading
--   out, station defenders), rivalcombat (pods, ship combat, you boarding a rival). They load in that order and
--   share this file's helpers through H; each one's functions that others call are added to H as it loads.
--   X and S reach them through bind(), called by shareState() whenever either changes here.
local H = {
    AI = AI, CFG = CFG, Gear = Gear, GearScale = GearScale, Kills = Kills, Nav = Nav,
    NodeBots = NodeBots, Out = Out, PILOTS = PILOTS, R = R, SHIP_NAMES = SHIP_NAMES, dist = dist,
    gauss = gauss, helper = helper, inBox = inBox, lib = lib, loadClass = loadClass, pick = pick,
    rnd = rnd, say = say, valid = valid, weighted = weighted,
}
package.loaded["rivalshared"] = H
local Crews = require("rivalcrews")
H.between, H.crewAlive, H.crewLabel = Crews.between, Crews.crewAlive, Crews.crewLabel
H.newMember = Crews.newMember
local Ships = require("rivalships")
H.chooseStation, H.dropTurrets, H.fireTurrets = Ships.chooseStation, Ships.dropTurrets, Ships.fireTurrets
H.setShipEnemy, H.shipOk = Ships.setShipEnemy, Ships.shipOk
local Bodies = require("rivalbodies")
H.bodiesAlive, H.breachSpots, H.dematerialize = Bodies.bodiesAlive, Bodies.breachSpots, Bodies.dematerialize
H.entryPoints, H.insideAnchor, H.joined = Bodies.entryPoints, Bodies.insideAnchor, Bodies.joined
H.materialize, H.projected, H.reachableNear = Bodies.materialize, Bodies.projected, Bodies.reachableNear
local Combat = require("rivalcombat")
local function shareState()
    for _, m in ipairs({ Crews, Ships, Bodies, Combat }) do m.bind(X, S) end
end
-- World survey ---------------------------------------------------------------------------------------------------
-- Interiors = navmesh volumes we can name; each gets entry points (station airlock buttons, arrival starts) and a
-- space-side target to fly to (a station node's docking volume, or the AI frigate that owns that interior).
local function survey(pc, shipActor)
    local interiors = {}
    for _, v in ipairs(FindAllOf("NavMeshBoundsVolume") or {}) do
        if valid(v) and not v:GetFName():ToString():find("Rivals", 1, true) then
            local o, e = {}, {}
            Out.call(v, "GetActorBounds", false, o, e, false)
            table.insert(interiors, { box = { c = { X = o.X, Y = o.Y, Z = o.Z }, e = { X = e.X, Y = e.Y, Z = e.Z } },
                entries = {} })
        end
    end
    local function interiorAt(l, margin)
        for _, it in ipairs(interiors) do if inBox(it.box, l, margin) then return it end end
    end
    for _, a in ipairs(CFG.INTERIOR_ANCHORS) do
        local it = interiorAt(a.at)
        if it then it.name = a.name end
    end
    -- Station airlocks name Navy Outpost / Spaceport and are where docked crews come in.
    for _, c in ipairs(FindAllOf("RaidUseableAirLockComponent") or {}) do
        if valid(c) and c.StationAirLock then
            local l = c:K2_GetComponentLocation()
            local it = interiorAt(l, 300)
            if it then
                local owner = c:GetOwner():GetFName():ToString()
                it.name = it.name or (owner:find("Navy") and "Navy Outpost") or (owner:find("Spaceport") and "Spaceport")
                table.insert(it.entries, l)
            end
        end
    end
    local function key5(s) return s:lower():gsub("^node_", ""):gsub("[^a-z]", ""):sub(1, 5) end
    for _, v in ipairs(FindAllOf("LevelStreamingVolume") or {}) do
        if valid(v) then
            local o, e = {}, {}
            Out.call(v, "GetActorBounds", false, o, e, false)
            local suffix = v:GetFName():ToString():gsub("^LevelStreamingVolume_", "")
            for _, it in ipairs(interiors) do
                if not it.name and inBox({ c = o, e = e }, it.box.c) then
                    it.key = key5(suffix)
                    it.name = CFG.VOLUME_NAMES[it.key] or suffix:gsub("Whitebox", ""):gsub("_%d+$", ""):gsub("(%l)(%u)", "%1 %2")
                end
            end
        end
    end
    -- Two nav volumes in one streaming volume (the Capital Ship's): the bigger one is the station.
    local function size(it) return it.box.e.X * it.box.e.Y * it.box.e.Z end
    -- Space_Charlie has two identical ones in the Mini Mine: of equal ones the first is kept.
    for i, a in ipairs(interiors) do
        for j, b in ipairs(interiors) do
            if i ~= j and a.key and a.key == b.key and (size(b) > size(a) or size(b) == size(a) and j < i) then
                a.key, a.name = nil, nil
            end
        end
    end
    for _, s in ipairs(FindAllOf("PlayerStart") or {}) do
        if valid(s) and s:GetClass():GetFName():ToString() == "RaidTeamStart" then
            local it = interiorAt(s:K2_GetActorLocation())
            if it then table.insert(it.entries, s:K2_GetActorLocation()) end
        end
    end
    -- AI frigate interiors: the big pirate ships; their space-side target is the frigate itself.
    for _, ins in ipairs(FindAllOf("RaidSpaceshipInside") or {}) do
        if valid(ins) and ins.IsAnAIShip and valid(ins.SpaceshipToPairTo) then
            local it = interiorAt(ins:K2_GetActorLocation(), 500)
            if it then
                it.name = "the " .. ins.SpaceshipToPairTo:GetClass():GetFName():ToString()
                    :gsub("^Ship_", ""):gsub("_Pawn_[Aa][Ii]_Child_C$", ""):gsub("01", ""):gsub("(%l)(%u)", "%1 %2")
                it.frigate = ins.SpaceshipToPairTo
            end
        end
    end
    -- Space-side station nodes
    local nodes, keyed = {}, {}
    local nodeSeen = {} -- docking-node class -> the name it matched, or false (for the survey log; issue #13)
    for _, it in ipairs(interiors) do if it.key then keyed[it.key] = it.name end end
    for _, c in ipairs(FindAllOf("RaidDockingComponent") or {}) do
        -- (a node's BreachVolume wraps the whole hull for boarding pods: not a place to dock)
        if valid(c) and not c:GetFName():ToString():find("Breach", 1, true) then
            local cls = c:GetOwner():GetClass():GetFName():ToString()
            local named = keyed[key5(cls)]
            if nodeSeen[cls] == nil then nodeSeen[cls] = false end
            for _, n in ipairs(named and { { cls, named } } or CFG.NODE_NAMES) do
                if cls:find(n[1], 1, true) then
                    nodeSeen[cls] = n[2]
                    local list = nodes[n[2]] or {}
                    nodes[n[2]] = list
                    local ok, b = pcall(Ships.stationBerth, c, valid(shipActor) and shipActor or pc)
                    if ok then
                        -- Overlapping volumes of one bay (Fortress) make one berth: the biggest volume's. The Mini Mine has a
                        -- 0.8 m marker 7 m under its real 6 x 12 m dock, and the marker came first: ships glided into the rock.
                        local e = c:GetScaledBoxExtent()
                        b.size = e.X * e.Y * e.Z
                        local dup = false
                        for i, o in ipairs(list) do
                            if dist(o.at, b.at) < 1500 then
                                dup = true
                                if b.size > (o.size or 0) then list[i] = b end
                            end
                        end
                        if not dup then table.insert(list, b) end
                    else
                        X.log("[rivals] berth failed: " .. tostring(b))
                    end
                    break
                end
            end
        end
    end
    local stations = {}
    for _, it in ipairs(interiors) do
        if it.name and (it.frigate or (nodes[it.name] and #nodes[it.name] > 0)) then
            it.berths = it.frigate and { { side = 1 }, { side = -1 } } or nodes[it.name]
            -- No airlock (Mini Mine): come in at the station's own AI spawn spots.
            if #it.entries == 0 then
                for _, a in ipairs(FindAllOf("RaidAINodeStart") or {}) do
                    if valid(a) and inBox(it.box, a:K2_GetActorLocation()) then table.insert(it.entries, a:K2_GetActorLocation()) end
                end
            end
            if #it.entries == 0 then table.insert(it.entries, it.box.c) end
            table.insert(stations, it)
        end
    end
    -- Station airlocks: the chamber a docked ship's crew comes through (floor point) and its button on the station side.
    for _, d in ipairs(FindAllOf("RaidFrigateStationDock") or {}) do
        if valid(d) and valid(d.InSideComp) and valid(d.OpenButton) then
            local c, e = d.InSideComp:K2_GetComponentLocation(), d.InSideComp:GetScaledBoxExtent()
            for _, st in ipairs(stations) do
                if not st.frigate and inBox(st.box, c, 1500) then
                    st.locks = st.locks or {}
                    local b = d.OpenButton:K2_GetComponentLocation()
                    table.insert(st.locks, { dock = d, name = d:GetFName():ToString(),
                        floor = { X = c.X, Y = c.Y, Z = c.Z - e.Z + 20 }, btn = { X = b.X, Y = b.Y, Z = b.Z },
                        box = { c = { X = c.X, Y = c.Y, Z = c.Z }, e = { X = e.X, Y = e.Y, Z = e.Z },
                            yaw = d.InSideComp:K2_GetComponentRotation().Yaw } })
                    break
                end
            end
        end
    end
    for _, st in ipairs(stations) do
        if st.locks then table.sort(st.locks, function(a, b) return a.name < b.name end) end
    end
    local names = {}
    for _, st in ipairs(stations) do
        st.area = st.box and 4 * st.box.e.X * st.box.e.Y / 1e4 or CFG.STATION_AREA_MID
        table.insert(names, ("%s (%.0fk m2, %d entries, %d berths%s)"):format(st.name, st.area / 1000, #st.entries, #st.berths,
            st.locks and (", %d airlocks"):format(#st.locks) or ""))
        for i, b in ipairs(st.berths) do
            if b.at then
                X.log(("[rivals]   %s berth %d at %.0f,%.0f,%.0f yaw %.0f, approach %.0f,%.0f,%.0f"):format(st.name, i,
                    b.at.X, b.at.Y, b.at.Z, b.yaw, b.approach.X, b.approach.Y, b.approach.Z))
            end
        end
    end
    X.log("[rivals] stations: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    -- Why a station did or didn't count (issue #13: some Space_Solo_02 runs survey none): a station needs a named
    -- interior AND docking nodes under the same name (or an AI frigate).
    local its, ns = {}, {}
    for _, it in ipairs(interiors) do if it.name then its[#its + 1] = it.name .. (it.frigate and " (frigate)" or "") end end
    for cls, name in pairs(nodeSeen) do ns[#ns + 1] = cls .. (name and (" -> " .. name) or " -> no name") end
    table.sort(ns)
    X.log(("[rivals] survey: named interiors: %s | docking nodes: %s"):format(
        #its > 0 and table.concat(its, ", ") or "none", #ns > 0 and table.concat(ns, ", ") or "none"))
    return stations, interiors
end

-- Where you are: "ship" (your own ship's interior), a station, or space (flying).
local function playerPlace()
    local foot = S.foot
    if not valid(foot) then return nil end
    local l = foot:K2_GetActorLocation()
    if S.home and inBox(S.home.box, l, 300) then return "ship", l end
    S.aboard = nil
    for _, c in ipairs(S.crews or {}) do
        if c.insideBox and inBox(c.insideBox, l, 300) then
            S.aboard = c
            return "rival", l
        end
    end
    for _, st in ipairs(S.stations) do
        if inBox(st.box, l, CFG.MATERIALIZE_MARGIN) then return st, l end
    end
    -- A place you board with a pod (the Capital Ship): like a station for its guards, never a place crews dock at.
    for _, st in ipairs(S.pois or {}) do
        if inBox(st.box, l, CFG.MATERIALIZE_MARGIN) then return st, l end
    end
    -- A station's airlock chamber can sit outside its navmesh volume: standing in it you're at that station all the
    -- same (you used to be "nowhere" for a moment, and your crew's bodies were taken away mid-transfer).
    local k = R.inAirlock(l, 100)
    if k then
        for _, st in ipairs(S.stations) do
            for _, kk in ipairs(st.locks or {}) do if kk == k then return st, l end end
        end
    end
    return nil, l
end

-- Points of interest (#187, #42): named interiors with a navmesh but no dock and no AI frigate (the Capital Ship on
-- Space_Beta, boarded with a pod) were no station, so standing in one you were "nowhere": no garrison, and the soldiers
-- the level spawns there were never adopted (their GOAP brains don't run offline, so they stood idle or stuck). They
-- get the stations' guard handling (garrisonStation, sweepStrays, roamGuards) through playerPlace, and are kept out of
-- S.stations, which crews dock at. Entries are walkable points: their box centre is often empty space, off the
-- navmesh (the Capital Ship's floors are 7-20 m below it), and every spawn search starts from an entry.
local function pointsOfInterest(pc, interiors, homeInside)
    local home = valid(homeInside) and homeInside:K2_GetActorLocation() or nil
    local isStation = {}
    for _, st in ipairs(S.stations) do isStation[st] = true end
    local names = {}
    for _, it in ipairs(interiors) do
        if it.name and not it.frigate and not isStation[it]
            and not (home and inBox(it.box, home, 0)) then -- (not your own ship's interior)
            local kept = {}
            for _, p in ipairs(it.entries or {}) do if not X.offLimits(p) then kept[#kept + 1] = p end end
            for _, a in ipairs(FindAllOf("RaidAINodeStart") or {}) do
                if #kept < 8 and valid(a) and inBox(it.box, a:K2_GetActorLocation()) then kept[#kept + 1] = a:K2_GetActorLocation() end
            end
            for _, dz in ipairs({ -0.6, -0.3, 0, 0.3, 0.6 }) do
                if #kept >= 4 then break end
                local o = {}
                local at = { X = it.box.c.X, Y = it.box.c.Y, Z = it.box.c.Z + dz * it.box.e.Z }
                if Out.call(X.navLib(), "K2_GetRandomPointInNavigableRadius", pc, at, o, math.max(it.box.e.X, it.box.e.Y),
                    X.navMesh(), X.queryFilter()) and o.X and inBox(it.box, o) then
                    kept[#kept + 1] = { X = o.X, Y = o.Y, Z = o.Z }
                end
            end
            if #kept > 0 then
                it.entries, it.berths, it.poi = kept, {}, true
                it.area = 4 * it.box.e.X * it.box.e.Y / 1e4
                table.insert(S.pois, it)
                names[#names + 1] = ("%s (%.0fk m2, %d entries)"):format(it.name, it.area / 1000, #kept)
            end
        end
    end
    if #names > 0 then X.log("[rivals] boardable places without a dock: " .. table.concat(names, ", ")) end
end

-- A wreck you're aboard: the ones who died with the ship lie where they fell, with their gear (built once, the first
-- time you board), and any survivors are up and fighting. Away from it the survivors go back to being simulated, as
-- boarders do; the corpses stay (dematerialize keeps the dead).
local function updateWreck(c, now, place)
    local here = place == "rival" and S.aboard == c
    if here then
        c.lastBoarded = now
        if not c.bodies then
            local spots = Bodies.breachSpots(c.inside)
            if #spots > 0 then
                Bodies.materialize(c, spots, "boarding", nil, not c.wreckDressed)
                if not c.wreckDressed then
                    local dead, alive = 0, 0
                    for _, m in ipairs(c.members) do
                        if m.alive then alive = alive + 1 elseif m.sankWith then dead = dead + 1 end
                    end
                    X.log(("[rivals] aboard the wreck of the %s: %d dead, %d alive"):format(c.shipName, dead, alive))
                end
                c.wreckDressed = true
            end
        end
    end
    if c.bodies then
        Bodies.bodiesAlive(c)
        if not here and now - (c.lastBoarded or 0) > CFG.DEMATERIALIZE_AFTER then Bodies.dematerialize(c) end
    end
end

-- Crew brain -----------------------------------------------------------------------------------------------------
local function updateCrew(c, now, place, playerLoc)
    if c.state == "gone" then return end
    -- (a derelict's or wreck's interior can still be loading: your pod asked for it on the way in)
    if c.inside and not c.insideBox and valid(c.inside) and Combat.hullThere(c) then Combat.pairInterior(c) end
    if c.state == "wreck" then return updateWreck(c, now, place) end
    if c.state == "derelict" then return end
    if c.bodies then Bodies.bodiesAlive(c) end
    if not Crews.crewAlive(c) then
        Bodies.dematerialize(c)
        X.log("[rivals] " .. Crews.crewLabel(c) .. " wiped out")
        -- A ship whose crew you killed waits for you at its helm, boardable like any other: with its interior already in,
        -- or loaded when your pod heads for it (the user: ships with dead crews must stay fully boardable; the Iron
        -- Gull's crew died boarding you before it had an interior, and was dropped as "gone" with its hull still there).
        if Ships.shipOk(c) then
            Nav.halt(c)
            c.state = "derelict"
            if c.berth or c.moored or c.glide then Ships.clearBerth(c) end
        else
            c.state = "gone"
        end
        return
    end
    if place == "rival" and S.aboard == c then
        c.lastBoarded = now
        if c.state == "docked" then
            -- The crew is off raiding the station; their watch is aboard. Bodies still standing in the station (you left
            -- it a moment ago) make way first. The watch appears away from where you cut in.
            if c.bodies and c.mode == "station" then Bodies.dematerialize(c) end
            if not c.bodies and c.watch then
                local spots = Bodies.breachSpots(c.inside)
                if #spots > 1 then table.remove(spots, 1) end
                local alive = {}
                for _, m in ipairs(c.watch) do if m.alive then alive[#alive + 1] = m end end
                if #alive > 0 and #spots > 0 then
                    Bodies.materialize(c, spots, "boarding", alive)
                    X.log(("[rivals] %d of the %s's watch are aboard"):format(#alive, c.shipName))
                end
            end
        elseif not c.bodies then
            local spots = Bodies.breachSpots(c.inside)
            if #spots > 0 then Bodies.materialize(c, spots, "boarding") end
        end
    elseif c.bodies and c.mode == "boarding" and now - (c.lastBoarded or 0) > CFG.DEMATERIALIZE_AFTER then
        Bodies.dematerialize(c)
    end

    if c.state == "waiting" then
        if now < c.launchAt then return end
        if not Ships.spawnShip(S.pc, c) then c.launchAt = now + 10 return end
        c.state = "travel"
        c.station = Ships.chooseStation(c)
        X.log(("[rivals] %s%s launched in a %s (%s): %s"):format(Crews.crewLabel(c), c.rusher and " (rusher)" or "",
            c.design and c.design.name or "?", table.concat(c.turretKinds or {}, " + "),
            c.station and ("heading for " .. c.station.name) or "nowhere to go"))
        return
    end

    local flying = c.state == "travel" or c.state == "attack" or c.state == "leaving"
    if flying and not Ships.shipOk(c) then
        -- Most go down with the ship; now and then one or two live through it, hurt, and are aboard the wreck when you
        -- board it, among the dead (#251: wrecks were empty).
        local alive = {}
        for _, m in ipairs(c.members) do if m.alive then alive[#alive + 1] = m end end
        local W, kept = CFG.WRECK_SURVIVORS, {}
        if #alive > 0 and math.random() < W.chance then
            for _ = 1, math.min(#alive, math.random(1, W.most)) do
                local m = table.remove(alive, math.random(#alive))
                m.hp = math.max(10, math.floor(m.hp * (W.hp[1] + math.random() * (W.hp[2] - W.hp[1]))))
                kept[#kept + 1] = m.name
            end
        end
        for _, m in ipairs(alive) do m.alive, m.sankWith = false, true end
        X.log(("[rivals] %s went down with their ship%s"):format(Crews.crewLabel(c),
            #kept > 0 and (" (alive in the wreck: " .. table.concat(kept, ", ") .. ")") or ""))
        c.state = valid(c.ship) and "wreck" or "gone"
        if c.state == "wreck" then pcall(Ships.stillTurrets, c) end
        return
    end
    local shipLoc = Ships.shipOk(c) and c.ship:K2_GetActorLocation() or nil
    local hull = Ships.shipOk(c) and c.ship.MainHullHealth / math.max(1, c.maxHull) or 0

    local hurt = c.lastHull and Ships.shipOk(c) and c.ship.MainHullHealth < c.lastHull - 1
    c.lastHull = Ships.shipOk(c) and c.ship.MainHullHealth or nil
    if hurt then c.hurtAt = now end
    -- An ambient fighter hit while you're shooting from close by turns on you (its foe's shots can't be told apart from
    -- yours, so it's the timing: you fired in the last few seconds).
    if c.ambient and hurt and c.state == "attack" and not (c.target and c.target.player) and shipLoc
        and now - (S.playerFiredAt or -1e9) < CFG.PROVOKE_SECONDS and valid(S.playerShip)
        and dist(shipLoc, S.playerShip:K2_GetActorLocation()) < CFG.GUN_RANGE * 1.5 and Combat.inYourSights(c, shipLoc) then
        Combat.engage(c, { player = true }, now, "provoked")
    end
    local ending = S.remaining ~= nil and S.remaining <= c.extractRemaining
    if c.party then Combat.updateParty(c.party, now, place, ending) end
    if flying and c.state ~= "leaving" and not c.diehard and hull < c.fleeHull then
        c.fireAt = nil
        Ships.setShipEnemy(c, nil)
        Ships.startLeaving(c, "hull damaged")
    end
    if ending and (c.state == "travel" or (c.state == "attack" and not c.diehard)) then
        c.fireAt = nil
        if Ships.shipOk(c) then Ships.setShipEnemy(c, nil) end
        Ships.startLeaving(c, "raid ending")
    end
    if c.state == "travel" and shipLoc and Combat.lookForFights(c, shipLoc, now, hurt) then return end

    if c.state == "travel" then
        if not c.station then Ships.startLeaving(c, "no stations") return end
        local st = c.station
        if c.berth and c.berth.taken ~= c then c.berth = nil end
        if not c.berth and not Ships.takeBerth(st, c) then
            -- Every berth taken: hold off the station; after a short wait board anyway (the ship stays parked there).
            local _, _, approach = Ships.berthPose(st, st.berths[1])
            if not approach then c.station = Ships.chooseStation(c) return end
            -- Straight out along the approach lane (open space: it's how ships fly in), spread by crew. A fixed +X offset
            -- put the hold point inside the Mini Mine's rock: ships flew into it and parked there out of sight.
            local at = Ships.berthPose(st, st.berths[1])
            local ox, oy, oz = approach.X - at.X, approach.Y - at.Y, approach.Z - at.Z
            local on = math.max(1, math.sqrt(ox * ox + oy * oy + oz * oz))
            local out = CFG.HOLD_OUT + (c.id % 4) * CFG.HOLD_SPACING
            local side = ((c.id % 3) - 1) * CFG.HOLD_SPACING
            local hold = { X = approach.X + ox / on * out - oy / on * side, Y = approach.Y + oy / on * out + ox / on * side,
                Z = approach.Z + oz / on * out }
            Ships.flyTo(c, hold, 600)
            if dist(shipLoc, hold) < 2500 then
                c.berthWait = c.berthWait or now
                if now - c.berthWait > CFG.BERTH_WAIT then
                    c.berthWait = nil
                    c.state, c.dockedAt = "docked", now
                    c.lock = Bodies.pickLock(st, c)
                    Bodies.setWatch(c)
                    c.leaveAt = now + rnd(CFG.DOCK_SECONDS)
                    Ships.setShipEnemy(c, nil)
                    Nav.halt(c)
                    X.log(("[rivals] %s breached into %s (no free berth)"):format(Crews.crewLabel(c), st.name))
                end
            end
            return
        end
        c.berthWait = nil
        local at, _, approach = Ships.berthPose(st, c.berth)
        if not at then c.berth, c.station = nil, Ships.chooseStation(c) return end -- that AI frigate sank
        Ships.flyTo(c, Ships.dockRoute(c, st, c.berth, at, approach, shipLoc))
        -- The glide in is a straight line: it starts only out on the lane, never from beside or under the station.
        local _, _, off = Ships.laneOf(at, approach, shipLoc)
        if dist(shipLoc, approach) < CFG.DOCK_ARRIVE and off < CFG.DOCK_LANE then
            c.state, c.dockedAt = "docked", now
            c.lock = Bodies.pickLock(st, c)
            Bodies.setWatch(c)
            c.leaveAt = now + rnd(CFG.DOCK_SECONDS)
            Ships.setShipEnemy(c, nil)
            Ships.startGlide(c, "in")
            X.log(("[rivals] %s docked at %s"):format(Crews.crewLabel(c), st.name))
        end

    elseif c.state == "attack" then
        local tgt = Combat.targetShip(c.target)
        if not tgt and c.foes then
            -- a battle: on to the enemy ship fewest are on, nearest first
            local best, bn, bd
            for _, f in ipairs(c.foes) do
                if f.state ~= "gone" and f.state ~= "derelict" and Ships.shipOk(f) then
                    local n = Combat.attackersOn({ crew = f })
                    local fd = dist(shipLoc, f.ship:K2_GetActorLocation())
                    if not best or n < bn or (n == bn and fd < bd) then best, bn, bd = f, n, fd end
                end
            end
            if best then
                local foes = c.foes
                Combat.engage(c, { crew = best }, now, "next target")
                c.foes, c.boardPlan = foes, nil
                tgt = Combat.targetShip(c.target)
            end
        end
        if not tgt then
            Combat.disengage(c, now, "target gone")
            if c.ambient then Ships.startLeaving(c, "won their fight") end
            return
        end
        local tl = tgt:K2_GetActorLocation()
        local d = dist(shipLoc, tl)
        -- (a crew sent in by a test trigger is moved next to you a tick late: not "lost" for its first 30 s)
        if d > CFG.SHIP_SIGHT * (c.diehard and 4 or 1.5) and not (c.testUntil and now < c.testUntil) then
            Combat.disengage(c, now, "lost them") return
        end
        if now >= c.engageUntil and not c.party and not c.diehard then Combat.disengage(c, now, "had enough") return end
        Ships.setShipEnemy(c, tgt)
        c.fireAt = tgt
        if Combat.crewOnShip(c) and not (c.boardPlan and now >= c.boardAt and not c.boarded) then
            local at, accept = Combat.manoeuvre(c, shipLoc, tgt, tl, now)
            Ships.flyTo(c, at, accept)
        elseif Combat.crewOnShip(c) then
            -- boarding: close in and hold off so the pods can go
            c.runPhase = nil
            Ships.flyTo(c, Combat.holdOff(shipLoc, tl), 300)
        else
            Ships.flyTo(c, Combat.holdOff(shipLoc, tl), 300) -- everyone's aboard your ship: it waits nearby
        end
        -- Boarders go once, when the time comes (or your hull is low) and they're close enough for the pods.
        if c.boardPlan and not c.party and not c.boarded then
            local full = c.target.player and S.playerShipMaxHull or (c.target.crew and c.target.crew.maxHull)
            local th = (tgt.MainHullHealth or 0) / math.max(1, full or tgt.MainHullHealth)
            local reachable = not c.target.crew or c.target.crew.state ~= "docked"
            if reachable and (now >= c.boardAt or th < CFG.BREACH_HULL) and d < CFG.POD_RANGE then
                c.boarded = true
                Combat.launchParty(c, now)
            end
        end

    elseif c.state == "docked" then
        local st = c.station
        if ending and not c.wrapUp then
            -- Raid ending: finish up, walk back to the airlock and extract.
            c.wrapUp, c.stationsLeft = true, 1
            c.leaveAt = math.min(c.leaveAt, now)
            X.log(("[rivals] %s is heading back to their ship in %s (raid ending)"):format(Crews.crewLabel(c), st.name))
        end
        -- (held still: StopMovement alone left a ship parked off a full station drifting away in a straight line)
        if Ships.shipOk(c) and not c.glide and not c.moored then Nav.halt(c) end
        if place == st then
            c.lastInside = now
            -- One crew at a time, and only once the station's guards are in and every earlier body is built: spread
            -- points steer clear of bodies that exist, so three crews spawned in one update (before Rebel Base's
            -- guards were adopted) landed among the guards and lost 5 of 7 in nine seconds (2026-11-14).
            local settling = #S.building > 0 or (S.adoptQueue and #S.adoptQueue > 0) or (S.topUps and #S.topUps > 0)
                or (S.pendingDefenders and #S.pendingDefenders > 0)
                or now - (S.lastMaterialize or -99) < CFG.MATERIALIZE_GAP
            -- Room for so many crews at once (insideCap); the rest wait aboard, and come in through an airlock later.
            local full = not c.bodies and Ships.crewsInside(st) >= Ships.insideCap(st)
            local crowd = not c.bodies and not full and CFG.AWAKE_MAX > 0 and R.awakeCount() >= CFG.AWAKE_MAX
            if (full or crowd) and not c.waitingRoom then
                c.waitingRoom = true
                if full then
                    X.log(("[rivals] %s waits aboard: %s already holds %d crews"):format(Crews.crewLabel(c), st.name, Ships.crewsInside(st)))
                else
                    X.log(("[rivals] %s waits aboard: %d awake around you already (AWAKE_MAX)"):format(Crews.crewLabel(c),
                        R.awakeCount()))
                end
            end
            full = full or crowd
            if not c.bodies and not settling and not full then
                if c.waitingRoom then c.lateEntry, c.waitingRoom = true, nil end
                Bodies.materialize(c, Bodies.stationSpawnSpots(c, st, playerLoc), "station")
                if c.bodies then S.lastMaterialize, c.lateEntry = now, nil end
            end
            if c.arrival then Bodies.crewArrival(c, now) end
            if c.bodies then
                for _, e in ipairs(c.bodies) do
                    if valid(e.bot) and (e.bot.Health or 0) > 0 and not e.fighting then
                        if c.exitAt then
                            e.home, e.patrolRadius = c.exitAt, 150
                        elseif now >= (e.rehome or 0) then
                            -- Search the station like a player: a new area every minute or two, preferring parts
                            -- the crew hasn't been through lately. Nobody knows where anyone is; they find you,
                            -- other crews and the station's soldiers by seeing or hearing them (gunfights carry).
                            -- Also away from everyone outside the crew, so crews spread over the station instead
                            -- of all walking into the same rooms.
                            c.searched = c.searched or {}
                            local mates = {}
                            for _, o in ipairs(c.bodies) do mates[o] = true end
                            local best = Bodies.spreadPoint(st, e, mates, c.searched)
                            if best then
                                e.home = best
                                table.insert(c.searched, best)
                                if #c.searched > 6 then table.remove(c.searched, 1) end
                            end
                            e.rehome = now + rnd(CFG.ROAM_SECONDS)
                        end
                    end
                end
                -- Time to go: walk back to an airlock and leave through it (unless they're in a fight).
                if now >= c.leaveAt and not c.exitAt then
                    c.exitAt = c.lock and valid(c.lock.dock) and Bodies.lockExit(c.lock) or Bodies.projected(pick(st.entries)) or st.box.c
                    c.exitStarted = now
                end
                if c.exitAt then
                    local out, fighting = true, false
                    for _, e in ipairs(c.bodies) do
                        if valid(e.bot) and (e.bot.Health or 0) > 0 then
                            if e.fighting then fighting = true end
                            if dist(e.bot:K2_GetActorLocation(), c.exitAt) > 400 then out = false end
                        end
                    end
                    if fighting then c.exitStarted = now
                    elseif out or now - c.exitStarted > 90 then
                        X.log(("[rivals] %s left %s through the airlock"):format(Crews.crewLabel(c), st.name))
                        Bodies.dematerialize(c)
                    end
                end
            end
        else
            -- (not the watch aboard their ship while you're on it: that's the boarding branch's to clear)
            if c.bodies and c.mode ~= "boarding" and now - (c.lastInside or 0) > CFG.DEMATERIALIZE_AFTER then Bodies.dematerialize(c) end
            if not c.bodies then
                -- Simulated raiding: a small chance of losing someone to the station's guards.
                local dt = now - (c.lastSim or now)
                for _, m in ipairs(c.members) do
                    if m.alive and math.random() < CFG.SIM_DEATH_PER_MIN * dt / 60 then
                        m.alive = false
                        X.log(("[rivals] %s died raiding %s"):format(m.name, st.name))
                    end
                end
            end
        end
        c.lastSim = now
        if now >= c.leaveAt and not c.bodies then
            c.lastStation = st
            Ships.undock(c)
            c.stationsLeft = c.stationsLeft - 1
            if not Ships.shipOk(c) then
                -- Ship destroyed while they were inside: stranded for good.
                for _, m in ipairs(c.members) do m.alive = false end
                c.state = "gone"
                X.log("[rivals] " .. Crews.crewLabel(c) .. " lost their ship and are stranded")
            elseif c.stationsLeft <= 0 then
                Ships.startLeaving(c, "raid done")
            else
                c.state, c.station = "travel", Ships.chooseStation(c)
                X.log(("[rivals] %s undocked, heading for %s"):format(Crews.crewLabel(c), c.station and c.station.name or "?"))
            end
        end

    elseif c.state == "leaving" then
        if c.exitAt then Ships.flyTo(c, c.exitAt, 1000) end
        -- Can't get stuck for good: the exit is only a point in space (no gate), so a ship that stops getting any
        -- closer to it extracts where it is. Close in (circling a hull parked at the point), soon; anywhere else
        -- (wedged in a station, as a CapitalShipFrigate was), after longer. Progress = a new best distance.
        local d = c.exitAt and dist(shipLoc, c.exitAt) or 0
        if not c.exitBest or d < c.exitBest - CFG.EXIT_PROGRESS then c.exitBest, c.exitBestAt = d, now end
        local stalled = now - c.exitBestAt > (d < CFG.EXIT_NEAR and CFG.EXIT_STALL_NEAR or CFG.EXIT_STALL)
        if stalled then
            X.log(("[rivals] %s stalled %d m from their exit"):format(Crews.crewLabel(c), math.floor(d / 100)))
        end
        if not c.exitAt or d < 3000 or stalled then
            Ships.dropTurrets(c)
            R.destroy(c.ship)
            c.ship, c.state = nil, "gone"
            X.log("[rivals] " .. Crews.crewLabel(c) .. " extracted")
        end
    end

end

-- Body construction finishes over later updates (a rolled gun arrives a moment after the kit).
local function finishBuilding(now)
    for i = #S.building, 1, -1 do
        local job = S.building[i]
        local ok, entry = pcall(Bodies.finishBody, job.b)
        if not ok then
            X.log("[rivals] body failed: " .. tostring(entry))
            table.remove(S.building, i)
        elseif entry == false then
            table.remove(S.building, i)
        elseif entry and job.corpse then
            -- Went down with the ship (#251): killed where it stands, no attacker, so nobody's kill counts it. Kept in
            -- the crew's bodies only (not the director's list), so it's left as a lootable corpse.
            table.remove(S.building, i)
            local c = job.crew
            pcall(function()
                StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(entry.bot, 100000, nil, nil,
                    StaticFindObject("/Script/Engine.DamageType"))
            end)
            if c.bodies then table.insert(c.bodies, entry) else R.destroy(entry.bot) end
        elseif entry then
            table.remove(S.building, i)
            local c = job.crew
            if c.bodies then
                table.insert(c.bodies, entry)
                table.insert(X.raid().bots, entry)
                if job.mode == "boarding" then
                    -- Boarders know where you are: they breached to get you.
                    entry.alert = true
                else
                    entry.home = entry.bot:K2_GetActorLocation()
                    entry.patrolRadius = CFG.PATROL_RADIUS
                end
                X.log(("[rivals] %s (%s kit, %s, %.0f hp, %s) is in %s"):format(entry.rival.name, entry.rival.tier.name,
                    entry.rival.gunName or "no gun", entry.rival.hp, entry.rival.personality,
                    job.mode == "boarding" and (c.inside and "their ship" or "your ship") or c.station.name))
            else
                -- The crew dematerialized while this one was being built.
                R.destroy(entry.bot)
                Bodies.removeEntry(entry)
            end
        end
    end
end

-- Public ---------------------------------------------------------------------------------------------------------
R.CFG = CFG -- the tuning menu edits it live

-- When you last fired from your ship (its turrets, or the bow gun while flying): an ambient fighter hit just then was hit by you.
local function playerFired() if S then S.playerFiredAt = os.clock() end end

-- The launcher's "Women among others" setting (config/female_share.txt, a percent) into CFG.FEMALE; looked at every 5 s
-- at most, so a change while the game runs applies to the next people made. No file: the default above.
local FEMALE_FILE = PROJECT .. "config/female_share.txt"
local femaleReadAt = -100
function R.femaleShare()
    if os.clock() - femaleReadAt >= 5 then
        femaleReadAt = os.clock()
        local f = io.open(FEMALE_FILE, "r")
        if f then
            local pct = tonumber((f:read("l") or ""):match("[%d%.]+"))
            f:close()
            if pct then CFG.FEMALE = math.max(0, math.min(100, pct)) / 100 end
        end
    end
    return CFG.FEMALE
end

function R.init(ctx)
    X = ctx
    shareState()
    R.femaleShare()
    Kills.init(function(m) X.log(m) end)
    Nav.init(ctx)
    pcall(RegisterHook, "/Script/RaidGame.RaidPlayerController:OnClientFiredTurret", playerFired)
    local function gunFired(w)
        local ship = S and S.playerShip
        if not (ship and valid(ship)) then return end
        local o = w:get():GetOwner()
        if o and o:IsValid() and o:GetAddress() == ship:GetAddress() then playerFired() end
    end
    pcall(RegisterHook, "/Script/RaidGame.RaidWeapon:ServerStartFire", gunFired)
    pcall(RegisterHook, "/Script/RaidGame.RaidWeapon:BurstStartFireEvent", gunFired)
    NodeBots.hooked = pcall(NotifyOnNewObject, "/Script/RaidGame.RaidNodeBot", function(o)
        table.insert(NodeBots.list, { o = o })
    end)
    X.log("[rivals] placed NPC spawn hook " .. (NodeBots.hooked and "on" or "failed: the stray sweep uses FindAllOf"))
end

-- Every frame (from the director's tick), for the current raid's state only.
local lastFrame
function R.frame(worldKey)
    local now = os.clock()
    local dt = math.min(0.1, now - (lastFrame or now))
    lastFrame = now
    if not S or S.key ~= worldKey then return end
    -- On foot (inside a station or your ship) you can't see the ships, so their per-frame work (~29 ms a second with 8
    -- crews, profile.txt 2026-11-17) runs SHIP_FRAME_HZ_FOOT times a second, with the real time since the last pass:
    -- glides go by the clock, and gunnery and turret swing scale by that time.
    local hz = S.onFoot and CFG.SHIP_FRAME_HZ_FOOT or 0
    if hz <= 0 or now >= (S.nextShipFrame or 0) then
        local sdt = math.min(0.25, now - (S.lastShipFrame or now))
        S.lastShipFrame, S.nextShipFrame = now, now + (hz > 0 and 1 / hz or 0)
        Ships.glideShips(now)
        Combat.fireControl(now, sdt)
        pcall(Ships.swingAimed, sdt)
    end
    if #S.pods > 0 then Combat.flyPods(dt) end
    if valid(S.pc) then
        pcall(Combat.rescueFromVoid, now)
        local ok, err = pcall(Combat.playerBoarding, now)
        if not ok and not S.boardErr then S.boardErr = true X.log("[rivals] boarding failed: " .. tostring(err)) end
    end
end

-- Called from the director's update on space maps once the navmesh is ready. foot = your on-foot character (also
-- while you fly: it stands at the helm), home = your ship's interior.
-- Ambient fights (CFG.SKIRMISH_*): only while you're flying your ship, one at a time.
local function skirmishSpot(here, yaw)
    for _ = 1, 12 do
        local off = rnd(CFG.SKIRMISH_BEARING) * (math.random() < 0.5 and -1 or 1)
        local a = math.rad((yaw or math.random(0, 359)) + off)
        local fwd, side = rnd(CFG.SKIRMISH_AHEAD), (math.random() * 2 - 1) * CFG.SKIRMISH_SIDE
        local p = { X = here.X + math.cos(a) * fwd - math.sin(a) * side, Y = here.Y + math.sin(a) * fwd + math.cos(a) * side,
            Z = here.Z + math.random(-2500, 2500) }
        local clear = true
        for _, st in ipairs(S.stations or {}) do
            if inBox(st.box, p, CFG.SKIRMISH_CLEAR) then clear = false end
            for _, b in ipairs(st.berths or {}) do if b.at and dist(b.at, p) < CFG.SKIRMISH_CLEAR * 2 then clear = false end end
        end
        for _, o in ipairs(S.crews) do
            if clear and o.ship and valid(o.ship) and dist(o.ship:K2_GetActorLocation(), p) < CFG.SKIRMISH_CLEAR then clear = false end
        end
        if clear then return p end
    end
end

-- Out of your view: well off the camera's line (aimCos: from your ship along where you look).
local function unseen(p) return Combat.aimCos(p) < math.cos(math.rad(CFG.SKIRMISH_UNSEEN)) end

local function skirmishStep(pc, now)
    if (S.skirmishes or 0) >= CFG.SKIRMISH_MAX or not valid(S.playerShip) then return end
    local flying = valid(pc.Pawn) and pc.Pawn:GetAddress() == S.playerShip:GetAddress()
    if not flying then return end
    S.nextSkirmish = S.nextSkirmish or now + rnd(CFG.SKIRMISH_FIRST)
    if now < S.nextSkirmish then return end
    for _, o in ipairs(S.crews) do
        if o.ambient and o.state == "attack" and o.target and o.target.crew and o.target.crew.ambient then return end
    end
    local here = S.playerShip:K2_GetActorLocation()
    local yaw
    pcall(function() yaw = pc:GetControlRotation().Yaw end) -- where your camera looks
    S.nextSkirmish = now + rnd(CFG.SKIRMISH_EVERY)
    -- two sides of `per` ships each, in a line abreast facing each other across the gap
    local per = S.skirmishSize or math.random(CFG.SKIRMISH_SHIPS[1], math.max(CFG.SKIRMISH_SHIPS[1], CFG.SKIRMISH_SHIPS[2]))
    per = math.max(1, math.min(8, math.floor(per)))
    S.skirmishSize = nil
    -- every ship's starting point clear of rocks (an asteroid field had them spawn scraping along one), in open space
    -- for the fight itself; a few tries, then no fight this time
    local spot, places
    for _ = 1, 8 do
        spot = skirmishSpot(here, yaw)
        if not spot then break end
        local gap, a = rnd(CFG.SKIRMISH_GAP) + (per - 1) * 1500, math.random() * 2 * math.pi
        local ax, ay = math.cos(a), math.sin(a)
        places = { {}, {} }
        local clear = Nav.clearAt(S.playerShip, spot, CFG.SKIRMISH_ROCKS * 2)
        for k = 1, 2 do
            local sgn = k == 1 and 1 or -1
            for i = 1, per do
                local off = (i - (per + 1) / 2) * CFG.SKIRMISH_SPACING
                local stagger = (i % 2 == 0) and 1200 or 0
                local at = { X = spot.X + ax * (gap / 2 + stagger) * sgn - ay * off,
                    Y = spot.Y + ay * (gap / 2 + stagger) * sgn + ax * off, Z = spot.Z + math.random(-800, 800) }
                clear = clear and unseen(at) and Nav.clearAt(S.playerShip, at, CFG.SKIRMISH_ROCKS)
                places[k][i] = at
            end
        end
        if clear then break end
        places = nil
    end
    if not places then
        S.nextSkirmish = now + 10 -- (you may just have been turning) another look soon
        X.log("[rivals] skirmish: no open space near you out of your view")
        return
    end
    local used = {}
    for _, o in ipairs(S.crews) do for _, m in ipairs(o.members) do used[m.name] = true end end
    local sides = { {}, {} }
    for k = 1, 2 do
        for i = 1, per do
            local c = Crews.newCrew(#S.crews + 1, used, CFG.CREW_SIZE)
            for _, mm in ipairs(c.members) do used[mm.name] = true end
            c.ambient, c.diehard, c.rusher, c.stationsLeft = true, true, false, 0
            if Ships.spawnShip(pc, c, places[k][i]) then
                pcall(function()
                    c.ship.MainHullHealth = c.ship.MainHullHealth * CFG.SKIRMISH_HULL
                    c.maxHull = c.ship.MainHullHealth
                end)
                c.state = "travel"
                table.insert(S.crews, c)
                table.insert(sides[k], c)
            end
        end
    end
    if #sides[1] == 0 or #sides[2] == 0 then return end
    S.skirmishes = (S.skirmishes or 0) + 1
    -- guns only: a boarding fight is settled off screen in seconds, which is no show for you to come across.
    -- Each ship takes the enemy across from it; when its target sinks it moves on to another (c.foes).
    for k = 1, 2 do
        local mine, theirs = sides[k], sides[3 - k]
        for i, c in ipairs(mine) do
            Combat.engage(c, { crew = theirs[(i - 1) % #theirs + 1] }, now, per > 1 and "battle" or "skirmish")
            c.boardPlan, c.foes = nil, theirs
        end
    end
    X.log(("[rivals] skirmish: %d against %d (the %s and the %s), %.0f m from you, %.0f deg off your view"):format(
        #sides[1], #sides[2], sides[1][1].shipName, sides[2][1].shipName, dist(here, spot) / 100,
        math.deg(math.acos(math.max(-1, math.min(1, Combat.aimCos(spot)))))))
end

-- Ship damage effects (OFFLINE_AUDIT item 8): the interior's alarms, fire, flickering lights and hull screen, and the hull's
-- damaged animation, only play from RaidSpaceshipInside's OnRep_* callbacks, which nothing calls offline. Call each one
-- with the old value when the server-side state changes, and tell the hull's (and its gun's) anim BP directly.
local SYSTEMS = {
    { "EngineDestroyed", "OnRep_EngineDestroyed", "Frigate_Damage_Engine" },
    { "TurretDestroyed", "OnRep_TurretDestroyed", "Frigate_Damage_Turret" },
    { "LifeSupportDestroyed", "OnRep_LifeSupportDestroyed", nil },
    { "HelmGunDestroyed", "OnRep_HelmGunDestroyed", "Frigate_Damage_HelmGun" },
}

local function shipAnims(hull)
    local out = {}
    for _, a in ipairs({ hull, hull.CurrentWeapon }) do
        if valid(a) then
            pcall(function()
                local mesh = a.Mesh
                if mesh and mesh:IsValid() then
                    local ai = mesh:GetAnimInstance()
                    if ai and ai:IsValid() then out[#out + 1] = ai end
                end
            end)
        end
    end
    return out
end

local function tellAnims(hull, fn, on)
    for _, ai in ipairs(shipAnims(hull)) do pcall(function() ai[fn](ai, on) end) end
end

local function shipDamageFx(ins)
    if not valid(ins) then return end
    local hull = ins.SpaceshipToPairTo
    local seen = S.damageSeen[ins:GetAddress()]
    if not seen then
        -- First look: start from an undamaged ship, so a ship already damaged gets its effects now.
        seen = { hull = 1 }
        S.damageSeen[ins:GetAddress()] = seen
    end
    local frac = ins.TotalShipHullHealth
    if type(frac) == "number" and math.abs(frac - seen.hull) > 0.001 then
        local old = seen.hull
        seen.hull = frac
        pcall(function() ins:OnRep_ShipHullHealthChange(old) end)
        local hurt = frac < 0.999
        if valid(hull) and hurt ~= (seen.hullAnim or false) then
            seen.hullAnim = hurt
            tellAnims(hull, "Frigate_Damage_Hull", hurt)
        end
    end
    for _, s in ipairs(SYSTEMS) do
        local on = ins[s[1]] == true
        if on ~= (seen[s[1]] or false) then
            seen[s[1]] = on
            pcall(function() ins[s[2]](ins, not on) end)
            if s[3] and valid(hull) then tellAnims(hull, s[3], on) end
            X.log(("[rivals] %s: %s %s"):format(ins:GetFName():ToString(), s[1], on and "on" or "off"))
        end
    end
end

-- The hull's own exterior effects (smoke and fire emitters P_HullDamage01-04, P_EngineDamage, P_TurretDamage,
-- P_HelmGunDamage, and the pawn BP's DamageEffects_* events that drive them) are also only reached from replication
-- callbacks, so a rival ship at 0 hull sat in space looking brand new. Drive them from the hull itself, for every ship,
-- interior or not. Thresholds: one more smoke/fire emitter per quarter of hull lost; all systems burn at 0 hull.
local HULL_EMITTERS = { "P_HullDamage01", "P_HullDamage02", "P_HullDamage03", "P_HullDamage04" }
local HULL_SYSTEMS = {
    { "bEngineDestroyed", "DamageEffects_Engine", "P_EngineDamage" },
    { "bTurretDestroyed", "DamageEffects_Turret", "P_TurretDamage" },
    { "bHelmGunDestroyed", "DamageEffects_HelmGun", "P_HelmGunDamage" },
}

local function emitter(hull, name, on)
    local comp = hull[name]
    if not (comp and comp:IsValid()) then return end -- never touch a missing component (probe crash, see NOTES)
    pcall(function()
        if on then
            comp:SetVisibility(true, true)
            comp:Activate(true)
        else
            comp:Deactivate()
        end
    end)
end

local function hullDamageFx(hull, maxHull)
    if not valid(hull) then return end
    local key = hull:GetAddress()
    local seen = S.hullSeen[key]
    if not seen then
        seen = { level = 0 }
        S.hullSeen[key] = seen
    end
    local hp = hull.MainHullHealth or 0
    local frac = math.max(0, math.min(1, hp / math.max(1, maxHull or hp)))
    local dead = hp <= 0 or hull.bLifeSupportDestroyed == true
    -- 0 = pristine, 1-4 = emitters lit (lost 1/4, 1/2, 3/4 of the hull; 4 = disabled).
    local level = dead and 4 or math.min(3, math.floor((1 - frac) * 4 + 0.0001))
    if level ~= seen.level then
        local was = seen.level
        seen.level = level
        for i, n in ipairs(HULL_EMITTERS) do emitter(hull, n, i <= level) end
        pcall(function() hull:DamageEffects_ShipHull(frac * 100) end)
        if (level > 0) ~= (was > 0) then tellAnims(hull, "Frigate_Damage_Hull", level > 0) end
        if dead and was < 4 then
            X.log(("[rivals] hull fx: %s disabled"):format(hull:GetFName():ToString()))
        end
    end
    for _, s in ipairs(HULL_SYSTEMS) do
        local on = dead or hull[s[1]] == true
        if on ~= (seen[s[1]] or false) then
            seen[s[1]] = on
            pcall(function() hull[s[2]](hull, on) end)
            emitter(hull, s[3], on)
        end
    end
end

local function damageFxStep()
    S.damageSeen = S.damageSeen or {}
    S.hullSeen = S.hullSeen or {}
    pcall(shipDamageFx, S.homeInside)
    pcall(hullDamageFx, S.playerShip, S.playerShipMaxHull)
    for _, c in ipairs(S.crews) do
        if c.inside then pcall(shipDamageFx, c.inside) end
        if c.ship and c.ship ~= S.playerShip then pcall(hullDamageFx, c.ship, c.maxHull) end
    end
end

function R.update(pc, worldKey, worldName, foot, homeInside)
    local now = os.clock()
    R.femaleShare()
    if not S or S.key ~= worldKey then
        S = { key = worldKey, building = {}, pods = {}, startedAt = now }
        shareState()
        Ships.resetAimed()
        Kills.reset()
        Nav.reset()
        S.pc = pc
        pcall(Bodies.gearCatalog) -- every look loaded now, under the loading veil
        local ok, st, interiors = pcall(survey, pc, valid(homeInside) and homeInside.SpaceshipToPairTo or nil)
        if not ok then X.log("[rivals] station survey failed: " .. tostring(st)) end
        S.stations = ok and st or {}
        S.pois = {}
        local okP, errP = pcall(pointsOfInterest, pc, ok and interiors or {}, homeInside)
        if not okP then X.log("[rivals] points of interest failed: " .. tostring(errP)) end
        -- Crews arrive at and leave by these; some sit on a station's roof.
        for _, station in ipairs(S.stations) do
            local kept = {}
            for _, p in ipairs(station.entries or {}) do
                if not X.offLimits(p) then kept[#kept + 1] = p end
            end
            if #kept > 0 then station.entries = kept end
        end
        S.homeInside = homeInside
        if valid(homeInside) then
            local c, ext = homeInside.InSideComp:K2_GetComponentLocation(), homeInside.InSideComp:GetScaledBoxExtent()
            S.home = { box = { c = c, e = ext } }
            S.playerShip = homeInside.SpaceshipToPairTo
            if valid(S.playerShip) then
                S.playerShipMaxHull = S.playerShip.MainHullHealth
                S.playerShipLoc = S.playerShip:K2_GetActorLocation()
            end
        end
        S.shipSpawns = {}
        local slots = 0
        for _, s in ipairs(FindAllOf("RaidFrigateIntSpawn") or {}) do
            if valid(s) then
                if s.bForFrigateSpawning and not s.bForFrigateAISpawning then
                    table.insert(S.shipSpawns, s:K2_GetActorLocation())
                elseif not s.bForFrigateSpawning then
                    slots = slots + 1
                end
            end
        end
        local kind = Crews.mapKind(worldName)
        S.crews = Crews.makeCrews(slots, kind)
        X.log(("[rivals] %s map, %d player slots: %d rival crews, %d ship spawn points"):format(kind, slots,
            #S.crews, #S.shipSpawns))
    end
    S.pc = pc
    S.foot = foot
    -- on foot = your character is the pawn (not the helm, a turret seat or a pod): R.frame slows the ships' work
    S.onFoot = false
    pcall(function()
        S.onFoot = valid(foot) and valid(pc.Pawn) and pc.Pawn:GetAddress() == foot:GetAddress()
    end)
    if valid(S.playerShip) then S.playerShipLoc = S.playerShip:K2_GetActorLocation() end
    -- Where you are and where you look from (a trailer camera can be far from your ship): no ship is lifted in sight.
    S.watchers = { S.playerShipLoc }
    pcall(function() S.watchers[#S.watchers + 1] = pc.PlayerCameraManager:GetCameraLocation() end)
    -- Seconds left in the raid (the space gate timer): crews head out near the end.
    pcall(function() S.remaining = pc:GetWorld().GameState.RemainingTime end)
    if S.armPending or (valid(S.playerShip) and not valid(S.playerShip.CurrentWeapon)) then
        local ok, err = pcall(Ships.armShips, pc, now)
        if not ok then X.log("[rivals] arming: " .. tostring(err)) end
    end
    Combat.simClashes(math.min(5, now - (S.lastUpdate or now)))
    S.lastUpdate = now
    local place, playerLoc = playerPlace()
    pcall(Combat.checkStolen)
    local okV, errV = pcall(Combat.rescueFromVoid, os.clock())
    if not okV and not S.voidErr then S.voidErr = true X.log("[rivals] void rescue failed: " .. tostring(errV)) end
    -- First time you walk into a station this raid: it gets its soldiers (the director's garrison).
    if type(place) == "table" and not place.garrisoned then
        place.garrisoned = true
        local ok, err = pcall(Bodies.garrisonStation, pc, place)
        if not ok then X.log("[rivals] garrison failed: " .. tostring(err)) end
    end
    local okS, errS = pcall(skirmishStep, pc, now)
    if not okS then X.log("[rivals] skirmish failed: " .. tostring(errS)) end
    if type(place) == "table" and place.garrisoned then
        S.adoptQueue = S.adoptQueue or {}
        local okA, errA = pcall(Bodies.sweepStrays, place, now)
        if not okA and not S.strayErr then S.strayErr = true X.log("[rivals] stray sweep failed: " .. tostring(errA)) end
        local okR, errR = pcall(Bodies.roamGuards, place, now)
        if not okR and not S.roamErr then S.roamErr = true X.log("[rivals] guard roaming failed: " .. tostring(errR)) end
    end
    Bodies.adoptQueued()
    Bodies.topUpStep(pc)
    Bodies.keepDefendersArmed()
    local okM, errM = pcall(Bodies.keepShipMoving, now)
    if not okM and not S.shipMoveErr then S.shipMoveErr = true X.log("[rivals] ship movement check failed: " .. tostring(errM)) end
    for _, c in ipairs(S.crews) do
        local ok, err = xpcall(updateCrew, function(e) return { e = e, tb = debug.traceback() } end, c, now, place, playerLoc)
        if not ok then
            local msg = type(err) == "table" and (type(err.e) .. " " .. tostring(err.e) .. " | " .. tostring(err.tb))
                or ("raw " .. type(err) .. " " .. tostring(err))
            X.log(("[rivals] crew %d (%s) update failed: %s"):format(c.id, tostring(c.state), msg))
            c.errors = (c.errors or 0) + 1
            if c.errors > 20 then Bodies.dematerialize(c) c.state = "gone" end
        end
    end
    finishBuilding(now)
    damageFxStep()
    -- after the crews (their bodies' deaths are noticed there), so the kill stat the game added is still unseen
    local okK, errK = pcall(Kills.update, pc)
    if not okK and not S.killsErr then S.killsErr = true X.log("[kills] " .. tostring(errK)) end
    if now - (S.lastReport or 0) >= 15 then
        S.lastReport = now
        local counts = {}
        for _, c in ipairs(S.crews) do counts[c.state] = (counts[c.state] or 0) + 1 end
        local parts = {}
        for k, v in pairs(counts) do table.insert(parts, k .. " " .. v) end
        -- (playerPlace says "rival" aboard another crew's ship: that used to fall through to "in space", issue #11)
        X.log("[rivals] crews: " .. table.concat(parts, ", ") .. (place == "ship" and " | you: aboard your ship"
            or place == "rival" and (" | you: aboard the " .. (S.aboard and S.aboard.shipName or "rival ship"))
            or type(place) == "table" and (" | you: in " .. place.name) or " | you: in space")
            .. " | turret shots " .. (S.turretShots or 0) .. Ships.turretWhy() .. " | steering: " .. Nav.report() .. ", breakaways " .. (S.seps or 0))
    end
end

-- Your active ship: the raid spawns it from the travel URL's ?SHIP= (the table row), hull and interior, as the live server
-- did. A design whose interior is the placeholder launches as its stand-in instead, for the stand-in's real interior; only
-- the hull is then replaced (ownHull), under the loading screen.
local function designForRow(row)
    for _, d in ipairs(CFG.HULLS) do
        if d.row == row then return d end
    end
end

function R.shipOption(row)
    local design = designForRow(row)
    if not design then
        if row then X.log("[rivals] no design for your ship " .. row) end
        return ""
    end
    return "?SHIP=" .. (design.stand or row)
end

function R.ownHull(pc, inside, row)
    local design = designForRow(row)
    if not (design and design.stand) then return end
    local old = inside.SpaceshipToPairTo
    local cls, tree = loadClass("/Game/Blueprints/Ships/" .. design.pawn), lib(CFG.SHIP_TREE)
    if not (valid(old) and cls and valid(tree)) then
        X.log("[rivals] couldn't fit your " .. design.name .. "'s hull")
        return
    end
    local at, rot = old:K2_GetActorLocation(), old:K2_GetActorRotation()
    local ctrl = old.Controller
    if valid(ctrl) then
        ctrl:UnPossess()
        R.destroy(ctrl)
    end
    R.destroy(old)
    local hull = helper():SpawnAIFromClass(pc, cls, tree, at, rot, true, pc)
    if not valid(hull) then
        X.log("[rivals] your " .. design.name .. "'s hull failed to spawn")
        return
    end
    pcall(function() hull.Controller.BrainComponent:StopLogic("yours") end)
    hull.Controller:StopMovement()
    local mpath = "/Game/Ships/" .. design.mesh
    if not mpath:find(".", 1, true) then mpath = mpath .. "." .. mpath:match("[^/]+$") end
    pcall(LoadAsset, mpath:match("^[^.]+"))
    local mesh = StaticFindObject(mpath)
    if valid(mesh) then pcall(function() hull.Mesh:SetSkeletalMesh(mesh, true) end) end
    inside.SpaceshipToPairTo = hull
    hull.MyShipInside = inside
    X.log("[rivals] your " .. design.name .. "'s hull is fitted")
end

-- Testing: the nearest flying crew's interior starts loading, as if your pod had come near.
-- want: text in the design's name to prefer, if a crew flying one is out there.
function R.prepBoard(want)
    if not S or not valid(S.playerShip) then return end
    local here, best, bd = S.playerShip:K2_GetActorLocation(), nil, nil
    for _, c in ipairs(S.crews) do
        if c.state == "travel" and Ships.shipOk(c) and not c.inside then
            local d = dist(here, c.ship:K2_GetActorLocation())
            local wanted = want and c.design and c.design.name:find(want, 1, true) and -1
            if not bd or (wanted or d) < bd then best, bd = c, wanted or d end
        end
    end
    if best then Combat.makeInterior(best) end
end

-- Debug: F4 sends the nearest flying crew to attack you right away.
function R.provoke(board)
    if not S then return end
    local best, bd
    for _, c in ipairs(S.crews) do
        if (c.state == "travel" or c.state == "waiting" or c.state == "leaving") and valid(S.playerShip) then
            if c.state == "waiting" then c.launchAt = 0 end
            local d = Ships.shipOk(c) and dist(c.ship:K2_GetActorLocation(), S.playerShip:K2_GetActorLocation()) or 1e9
            if not bd or d < bd then best, bd = c, d end
        end
    end
    if best then
        best.aggression = 1
        best.forceAttack = true
        -- A crew still at its spawn point launches now.
        -- (A ship spawned this frame reads 0 hull until its next tick, so check it exists, not shipOk.)
        if not Ships.shipOk(best) and Ships.spawnShip(S.pc, best) then best.station = Ships.chooseStation(best) end
        if valid(best.ship) then
            local pl = S.playerShip:K2_GetActorLocation()
            Out.call(best.ship, "K2_SetActorLocation", { X = pl.X + 12000, Y = pl.Y, Z = pl.Z }, false, {}, true)
            Combat.engage(best, { player = true }, os.clock(), "provoked")
            if board then best.boardPlan, best.boardAt = "all", 0 end -- bridge/rivals_board: boarders, whatever the roll
            best.testUntil = os.clock() + 30
        end
    end
end

-- Testing and filming: two flying crews meet near you, `apart` units apart (default 3000), and the first boards the
-- second as soon as it's in pod range.
function R.firedForTest() playerFired() end
function R.skirmishNow(size)
    if not S then return end
    S.nextSkirmish = 0
    S.skirmishSize = tonumber(size)
    -- asked for (bridge/rivals_skirmish, filming and tests): not held back by the per-raid cap
    S.skirmishes = math.min(S.skirmishes or 0, CFG.SKIRMISH_MAX - 1)
end

function R.clash(apart)
    if not S or not valid(S.playerShip) then return end
    local pair = {}
    for _, c in ipairs(S.crews) do
        if c.state == "waiting" then
            c.launchAt = 0
            if Ships.spawnShip(S.pc, c) then c.state, c.station = "travel", Ships.chooseStation(c) end
        end
        if c.state == "travel" and valid(c.ship) and #pair < 2 then table.insert(pair, c) end
    end
    -- late in a raid nobody's travelling: crews heading home, or fighting each other, will do (for filming)
    for _, c in ipairs(S.crews) do
        if #pair < 2 and (c.state == "leaving" or (c.state == "attack" and not (c.target and c.target.player)))
            and Ships.shipOk(c) and c ~= pair[1] then table.insert(pair, c) end
    end
    if #pair < 2 then X.log("[rivals] clash: no two crews flying") return end
    local a, b, pl = pair[1], pair[2], S.playerShip:K2_GetActorLocation()
    Out.call(a.ship, "K2_SetActorLocation", { X = pl.X + 12000, Y = pl.Y, Z = pl.Z + 2000 }, false, {}, true)
    Out.call(b.ship, "K2_SetActorLocation", { X = pl.X + 12000, Y = pl.Y + (apart or 3000), Z = pl.Z + 2000 }, false, {}, true)
    Combat.engage(a, { crew = b }, os.clock(), "clash test")
    a.boardPlan, a.boardAt = "all", 0
    -- the target fights back (a crew heading home would otherwise extract before the pods arrive)
    Combat.engage(b, { crew = a }, os.clock(), "clash test")
    b.boardPlan = nil
    a.testUntil, b.testUntil = os.clock() + 30, os.clock() + 30
end

-- Your own crew (crew.lua) is built from the same people, bodies and turrets as the rivals.
R.startBody = function(pc, m, at) return Bodies.startBody(pc, m, at) end
R.rollKit = Bodies.rollKit
R.finishBody = Bodies.finishBody
R.holdGun = Bodies.holdGun

-- Your ship's own turrets (the ones its hull spawned, camera turrets left out), as fireTurrets entries.
function R.shipTurrets(ship, spreadScale)
    local out, addr = {}, ship:GetAddress()
    ship.SpawnedTurretArray:ForEach(function(_, e)
        local t = e:get()
        if valid(t) and not t.bACameraTurret then
            local p = t:GetAttachParentActor()
            if valid(p) and p:GetAddress() == addr then
                local cls = t:GetClass():GetFName():ToString()
                local tt = CFG.TURRET_TYPES.Singular
                for _, k in pairs(CFG.TURRET_TYPES) do
                    if cls:find(k.cls, 1, true) then tt = k break end
                end
                local socks = {}
                t.FiringSockets:ForEach(function(_, s) socks[#socks + 1] = s:get():ToString() end)
                table.insert(out, { actor = t, socks = socks, si = 1, speed = tt.speed, rate = t.FireRate,
                    reload = t.ReloadTime, ammo = math.max(1, t.TotalAmmo), left = t.TotalAmmo, range = tt.range,
                    spread = tt.spread * (spreadScale or 1), next = 0 })
            end
        end
    end)
    return out
end

-- The stationary turrets around space maps (RaidSubNodeActor_Turret: flak and gun nodes near stations). Found once per
-- map with one FindAllOf when your gunner first needs them, again on a click at most every NODE_TURRET_REFRESH s.
local NODE_TURRET_REFRESH = 60
local function nodeTurrets(refresh)
    local now = os.clock()
    if not S.nodeTurrets or (refresh and now - (S.nodeTurretsAt or -1e9) > NODE_TURRET_REFRESH) then
        S.nodeTurrets, S.nodeTurretsAt = {}, now
        for _, t in ipairs(FindAllOf("RaidSubNodeActor_Turret") or {}) do
            if valid(t) then S.nodeTurrets[#S.nodeTurrets + 1] = t end
        end
        X.log(("[rivals] %d stationary turret(s) on this map"):format(#S.nodeTurrets))
    else
        -- a destroyed turret leaves the list at once: a moving flak turret is freed soon after it dies, and the list
        -- is otherwise only refreshed on a click (#191)
        for i = #S.nodeTurrets, 1, -1 do
            if not valid(S.nodeTurrets[i]) then table.remove(S.nodeTurrets, i) end
        end
    end
    return S.nodeTurrets
end

local function nodeTurretAlive(t)
    -- valid() before any property: reading bIsDying on a freed turret faults natively, and pcall can't catch that
    -- (#191: the crash 1 s after a moving flak turret died, on the gunner's next look over the turret list).
    -- (bIsDying reads as a Lua boolean: comparing it with 0 was always false, so every turret counted as dead and your
    -- gunner never shot one, picked or ordered)
    if not valid(t) then return false end
    local ok, alive = pcall(function()
        local dying = t.bIsDying
        return (t.Health or 0) > 0 and not (dying == true or (type(dying) == "number" and dying ~= 0))
    end)
    return ok and alive
end

local function turretTarget(t, here, at)
    return { ship = t, turret = true, name = "turret", d = dist(here, at) }
end

-- Out in space with a hull there: not docked or held in a berth, not a derelict, a wreck or gone.
local OUT_OF_PLAY = { docked = true, derelict = true, wreck = true, gone = true }
local function flyingShip(c) return not OUT_OF_PLAY[c.state] and not c.moored and Ships.shipOk(c) end

-- Ships your gunner may shoot: crews attacking you, the ship you just fired on, and stationary turrets aiming at your
-- ship. Nearest first. Entries as pickShip's.
function R.hostileShips()
    if not S or not valid(S.playerShip) then return {} end
    local here, list = S.playerShip:K2_GetActorLocation(), {}
    local firing = os.clock() - (S.playerFiredAt or -99) < CFG.PROVOKE_SECONDS
    for _, c in ipairs(S.crews or {}) do
        if c.state ~= "gone" and Ships.shipOk(c) then
            local at = c.ship:K2_GetActorLocation()
            if (c.state == "attack" and c.target and c.target.player) or (firing and Combat.inYourSights(c, at)) then
                list[#list + 1] = { ship = c.ship, crew = c, name = c.shipName or "ship", d = dist(here, at) }
            end
        end
    end
    local mine = S.playerShip:GetAddress()
    for _, t in ipairs(nodeTurrets(false)) do
        if nodeTurretAlive(t) then
            local aimed = false
            pcall(function() aimed = valid(t.CurrentAimingActor) and t.CurrentAimingActor:GetAddress() == mine end)
            if aimed then list[#list + 1] = turretTarget(t, here, t:K2_GetActorLocation()) end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

-- Out in space with a hull there: not docked or held in a berth, not a derelict, a wreck or gone.
local OUT_OF_PLAY = { docked = true, derelict = true, wreck = true, gone = true }
local function flyingShip(c) return not OUT_OF_PLAY[c.state] and not c.moored and Ships.shipOk(c) end

-- What you point your gunner at (left click at the helm, crew.lua): of the ships out flying and the stationary turrets
-- standing within `range` of you, the one nearest the middle of your view if any is within `cone` deg of it, else the
-- nearest. Any crew, hostile or not. Returns { ship = actor, crew = c or nil, turret = true or nil, name, d, centred }.
function R.pickShip(range, cone)
    if not S or not valid(S.playerShip) then return nil end
    local here, near, best, nearD, bestCos = S.playerShip:K2_GetActorLocation(), nil, nil, range, math.cos(math.rad(cone))
    local function consider(e, at)
        if e.d > range then return end
        local cs = Combat.aimCos(at)
        if cs >= bestCos then best, bestCos = e, cs end
        if e.d < nearD then near, nearD = e, e.d end
    end
    for _, c in ipairs(S.crews or {}) do
        if flyingShip(c) and not c.glide then
            local at = c.ship:K2_GetActorLocation()
            consider({ ship = c.ship, crew = c, name = c.shipName or "ship", d = dist(here, at) }, at)
        end
    end
    for _, t in ipairs(nodeTurrets(true)) do
        if nodeTurretAlive(t) then
            local at = t:K2_GetActorLocation()
            consider(turretTarget(t, here, at), at)
        end
    end
    local e = best or near
    if e then e.centred = best ~= nil end
    return e
end

-- Is this pickShip entry still one your gunner can go on shooting (a ship out flying, or a turret standing; in range)?
function R.shipInPlay(e, range)
    if not (S and valid(S.playerShip) and e) then return false end
    if e.turret then
        if not nodeTurretAlive(e.ship) then return false end
    elseif not flyingShip(e.crew) then
        return false
    end
    return dist(S.playerShip:K2_GetActorLocation(), e.ship:K2_GetActorLocation()) <= range
end

-- Fires your ship's turrets at a ship, as a crew's gunners would (counts as you firing: ambient fighters hit by it turn on you).
-- gun = the gunner's lasting state: { gunnery = skill 0..1, aim = their aim on the current target (kept by fireTurrets) }.
function R.gunnerFire(turrets, tgt, now, gun)
    if not (S and valid(S.playerShip)) then return false end
    gun = gun or {}
    gun.ship, gun.turrets, gun.arc = S.playerShip, turrets, CFG.GUNNER_ARC
    gun.rangeScale, gun.pitchSlack = CFG.GUNNER_RANGE, CFG.GUNNER_PITCH_SLACK
    gun.reach = tgt:GetClass():GetFName():ToString():find("NodeTurret", 1, true) and CFG.TURRET_RANGE_STATION or nil
    local fired = Ships.fireTurrets(gun, tgt, now)
    if fired then playerFired() end
    return fired
end

-- Your gunner takes the barrels of these shipTurrets entries (on: from the helm your view no longer swings them) or
-- gives them back to the game (off: the pilot aims and fires the first one again, as solo).
function R.aimTurrets(turrets, on)
    for _, e in ipairs(turrets) do
        if valid(e.actor) and (on and not e.aimed or not on and e.aimed) then Ships.aimTurret(e, on) end
    end
end

-- ...and with nothing to shoot at they come back to the nose.
function R.restTurrets(turrets)
    for _, e in ipairs(turrets) do e.wantYaw, e.wantPitch = 0, 0 end
end

-- Where you are: "ship" (your interior), "rival" (aboard a rival's), a station table, or nil (space / unknown).
function R.where()
    if not S then return nil end
    return (playerPlace())
end
-- Your last pod breach: { at, time (os.clock), ship } or nil.
function R.lastBreach() return S and S.breach or nil end
-- A new world: drop the last raid's ships, crews and stations (they were freed with it; see main.lua resetRaid).
function R.reset() S = nil R.civilianAt = nil shareState() end
-- Testing (bridge/autofly): a station's centre by (part of) its name.
function R.stationAt(name)
    for _, st in ipairs(S and S.stations or {}) do
        if st.name:find(name, 1, true) and st.box then return st.box.c end
    end
end
-- Profiler: the station nearest a point (name, distance to its box centre).
function R.nearestStation(l)
    local best, bd
    for _, st in ipairs(S and S.stations or {}) do
        local c = st.box and st.box.c
        if c then
            local d = math.sqrt((l.X - c.X) ^ 2 + (l.Y - c.Y) ^ 2 + (l.Z - c.Z) ^ 2)
            if not bd or d < bd then best, bd = st.name, d end
        end
    end
    return best, bd
end
-- The station airlock chamber this point stands in (the box turns with the airlock), or nil. Chambers are off the
-- navmesh: crew.lua holds its catch-ups while you cycle through one.
function R.inAirlock(l, margin)
    if not (S and S.stations) then return nil end
    margin = margin or 0
    for _, st in ipairs(S.stations) do
        for _, k in ipairs(st.locks or {}) do
            local b = k.box
            if b then
                local dx, dy = l.X - b.c.X, l.Y - b.c.Y
                local r = math.rad(-(b.yaw or 0))
                local x, y = dx * math.cos(r) - dy * math.sin(r), dx * math.sin(r) + dy * math.cos(r)
                if math.abs(x) <= b.e.X + margin and math.abs(y) <= b.e.Y + margin
                    and math.abs(l.Z - b.c.Z) <= b.e.Z + margin then return k end
            end
        end
    end
    return nil
end
function R.playerShip() return S and valid(S.playerShip) and S.playerShip or nil end

return R
