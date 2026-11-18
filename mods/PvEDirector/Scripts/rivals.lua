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
    SHIP_STOLEN_FILE = PROJECT .. "backend/ship_stolen.txt",
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

-- Berths ---------------------------------------------------------------------------------------------------------
-- Where a docked ship sits. Station nodes say where a docking ship goes (ReturnAreaEntranceMoveToLocation, the
-- transform the docking ability flies your ship to: nose-in, deeper in the dock than the volume's middle). Nodes
-- that return nothing (Merchant, Fortress) dock in a bay: the volume itself, along its long axis, nose toward the
-- node's middle. Pitch/roll of the returned transform belong to a marker mesh and are ignored.
local function quatYaw(q)
    return math.deg(math.atan(2 * (q.W * q.Z + q.X * q.Y), 1 - 2 * (q.Y * q.Y + q.Z * q.Z)))
end

-- A dock volume's middle can lie in the hull (the Capital Ship's is 1.3 m off its side, by a rocket turret: a docked
-- frigate sat half inside it). Moved sideways, out of the station, till a ship-sized sphere fits; the height is kept.
-- Only for nodes with no berth transform: the game's own berths (Rebel Base, Spaceport) hold your ship in docking
-- clamps that any sphere overlaps on purpose. Run at the survey, before any rival ship is out: the sweep's ignore list
-- doesn't get through from Lua, only its world context (your ship, as `ctx`) is left out.
local CLEAR_COLOR = { R = 0, G = 0, B = 0, A = 0 }
local function clearOfHull(ctx, owner, at, yaw)
    local sys = lib("/Script/Engine.Default__KismetSystemLibrary")
    local moved, px, py, lane = 0, nil, nil, false
    while moved < CFG.BERTH_CLEAR_MAX do
        local h = {}
        local ok, r = pcall(function()
            return Out.call(sys, "SphereTraceSingle", ctx, at, { X = at.X, Y = at.Y, Z = at.Z + 1 }, CFG.BERTH_CLEAR, 0, false,
                {}, 0, h, true, CLEAR_COLOR, CLEAR_COLOR, 0)
        end)
        if not (ok and r and h.Normal) then break end
        local a = h.Actor and h.Actor:Get()
        -- the hull, its turrets, a rock; not a ship (an AI frigate passing by)
        if not (a and a:IsValid()) or a:GetClass():GetFName():ToString():find("^Ship_") then break end
        local nx, ny = h.Normal.X, h.Normal.Y
        local n = math.sqrt(nx * nx + ny * ny)
        if not lane and n < 0.3 then break end -- a floor or a roof
        nx, ny = nx / math.max(n, 1e-6), ny / math.max(n, 1e-6)
        -- pushed back the way it came (wedged between the hull and a turret): straight out along the lane instead
        if not lane and px and nx * px + ny * py < 0 then lane = true end
        if lane then nx, ny = -math.cos(math.rad(yaw)), -math.sin(math.rad(yaw)) end
        px, py = nx, ny
        local step = math.max(50, math.min(250, (h.PenetrationDepth or 200) + 50))
        at = { X = at.X + nx * step, Y = at.Y + ny * step, Z = at.Z }
        moved = moved + step
    end
    if moved > 0 then
        X.log(("[rivals]   berth at %s moved %.0f out of its hull"):format(owner:GetFName():ToString(), moved))
    end
    return at
end

local function stationBerth(comp, shipActor)
    local owner = comp:GetOwner()
    local loc = comp:K2_GetComponentLocation()
    local b = {}
    pcall(function()
        local t, cam, boom = {}, {}, {}
        owner:ReturnAreaEntranceMoveToLocation(shipActor, comp, t, cam, boom)
        local p = t.Translation
        if p and (p.X ~= 0 or p.Y ~= 0) then
            b.at, b.yaw = { X = p.X, Y = p.Y, Z = p.Z }, quatYaw(t.Rotation)
        end
    end)
    if not b.at then
        local e, r, o = comp:GetScaledBoxExtent(), comp:K2_GetComponentRotation(), owner:K2_GetActorLocation()
        local yaw = r.Yaw + (e.Y > e.X and 90 or 0)
        if (o.X - loc.X) * math.cos(math.rad(yaw)) + (o.Y - loc.Y) * math.sin(math.rad(yaw)) < 0 then yaw = yaw + 180 end
        b.at, b.yaw = clearOfHull(shipActor, owner, { X = loc.X, Y = loc.Y, Z = loc.Z }, yaw), yaw
    end
    -- The node's bounds (with the berth): docking ships stay outside them till they're on the approach lane.
    local o, x = {}, {}
    Out.call(owner, "GetActorBounds", false, o, x, false)
    local lo = { X = math.min(o.X - x.X, b.at.X), Y = math.min(o.Y - x.Y, b.at.Y), Z = math.min(o.Z - x.Z, b.at.Z) }
    local hi = { X = math.max(o.X + x.X, b.at.X), Y = math.max(o.Y + x.Y, b.at.Y), Z = math.max(o.Z + x.Z, b.at.Z) }
    b.hull = { c = { X = (lo.X + hi.X) / 2, Y = (lo.Y + hi.Y) / 2, Z = (lo.Z + hi.Z) / 2 },
        e = { X = (hi.X - lo.X) / 2, Y = (hi.Y - lo.Y) / 2, Z = (hi.Z - lo.Z) / 2 } }
    local rad = math.rad(b.yaw)
    b.approach = { X = b.at.X - math.cos(rad) * CFG.BERTH_APPROACH, Y = b.at.Y - math.sin(rad) * CFG.BERTH_APPROACH,
        Z = b.at.Z }
    return b
end

-- Berth pose now: at, yaw, approach. Berths at an AI frigate (b.side) follow the frigate as it flies.
local function berthPose(st, b)
    if not b.side then return b.at, b.yaw, b.approach end
    if not (st.frigate and valid(st.frigate)) then return nil end
    local f, yaw = st.frigate:K2_GetActorLocation(), st.frigate:K2_GetActorRotation().Yaw
    local rx, ry = math.cos(math.rad(yaw + 90)) * b.side, math.sin(math.rad(yaw + 90)) * b.side
    local at = { X = f.X + rx * CFG.ALONGSIDE, Y = f.Y + ry * CFG.ALONGSIDE, Z = f.Z }
    return at, yaw, { X = at.X + rx * CFG.BERTH_APPROACH, Y = at.Y + ry * CFG.BERTH_APPROACH, Z = at.Z }
end

-- Docking route --------------------------------------------------------------------------------------------------
-- A direct move knows nothing of the station: from its far side a ship flew into the hull and scraped along it to the
-- approach point. A docking ship stays outside the station's bounds (+ HULL_MARGIN) till it's on the berth's approach
-- lane, coming onto it at its entry (where the lane leaves the bounds), round the bounds' corners and edges if need be.
local function grow(box, m) return { c = box.c, e = { X = box.e.X + m, Y = box.e.Y + m, Z = box.e.Z + m } } end

-- Whether the segment a-b passes through an axis-aligned box (slab test).
local function crossesBox(a, b, box)
    local t0, t1 = 0, 1
    for _, k in ipairs({ "X", "Y", "Z" }) do
        local d, lo, hi = b[k] - a[k], box.c[k] - box.e[k], box.c[k] + box.e[k]
        if math.abs(d) < 1e-6 then
            if a[k] < lo or a[k] > hi then return false end
        else
            local u0, u1 = (lo - a[k]) / d, (hi - a[k]) / d
            if u0 > u1 then u0, u1 = u1, u0 end
            t0, t1 = math.max(t0, u0), math.min(t1, u1)
            if t0 > t1 then return false end
        end
    end
    return true
end

-- The station's bounds for this berth now (an AI frigate's move with it).
local function hullOf(st, b)
    if not b.side then return b.hull end
    if not (st.frigate and valid(st.frigate)) then return nil end
    local o, x = {}, {}
    Out.call(st.frigate, "GetActorBounds", true, o, x, false)
    return { c = { X = o.X, Y = o.Y, Z = o.Z }, e = { X = x.X, Y = x.Y, Z = x.Z } }
end

-- The lane out from a berth: its unit vector, and how far a point p is along it (t) and off its line (off).
local function laneOf(at, approach, p)
    local u = { X = approach.X - at.X, Y = approach.Y - at.Y, Z = approach.Z - at.Z }
    local n = math.max(1, math.sqrt(u.X * u.X + u.Y * u.Y + u.Z * u.Z))
    u = { X = u.X / n, Y = u.Y / n, Z = u.Z / n }
    local t = (p.X - at.X) * u.X + (p.Y - at.Y) * u.Y + (p.Z - at.Z) * u.Z
    return u, t, dist(p, { X = at.X + u.X * t, Y = at.Y + u.Y * t, Z = at.Z + u.Z * t })
end

-- Where a ship docking at berth b flies now: the approach point, the lane's entry, or a way round the station.
local function dockRoute(c, st, b, at, approach, here)
    local hull = hullOf(st, b)
    if not hull then return approach, 300 end
    local box, inner = grow(hull, CFG.HULL_MARGIN), grow(hull, CFG.HULL_MARGIN * 0.8)
    local u, t, off = laneOf(at, approach, here)
    -- the entry: out along the lane to where it first leaves the bounds
    local exitT = math.huge
    for _, k in ipairs({ "X", "Y", "Z" }) do
        if math.abs(u[k]) > 1e-6 then
            exitT = math.min(exitT, (box.c[k] + (u[k] > 0 and box.e[k] or -box.e[k]) - at[k]) / u[k])
        end
    end
    local out = math.max(CFG.BERTH_APPROACH, math.min(exitT + 500, 30000))
    local entry = { X = at.X + u.X * out, Y = at.Y + u.Y * out, Z = at.Z + u.Z * out }
    if t >= CFG.BERTH_APPROACH * 0.5 and t <= out + CFG.LANE_WIDTH and off < CFG.LANE_WIDTH then
        c.route = nil
        return approach, 300 -- on the lane: straight in
    end
    if not crossesBox(here, entry, inner) then
        c.route = nil
        return entry, 800
    end
    local r = c.route
    if r and r.berth == b and dist(here, r.at) > CFG.DOCK_ARRIVE and not crossesBox(here, r.at, inner) then
        return r.at, 800
    end
    local cands = {}
    if inBox(inner, here) then
        -- inside the bounds (under a hull, in a gap): straight out through the nearest face first
        local bd
        for _, k in ipairs({ "X", "Y", "Z" }) do
            for _, sgn in ipairs({ 1, -1 }) do
                local d = box.c[k] + sgn * box.e[k] - here[k]
                if not bd or math.abs(d) < bd then
                    bd = math.abs(d)
                    cands[1] = { X = here.X, Y = here.Y, Z = here.Z }
                    cands[1][k] = here[k] + d + sgn * 500
                end
            end
        end
    else
        -- the corners, edge middles and face middles of the bounds
        for _, i in ipairs({ -1, 0, 1 }) do
            for _, j in ipairs({ -1, 0, 1 }) do
                for _, k in ipairs({ -1, 0, 1 }) do
                    if i ~= 0 or j ~= 0 or k ~= 0 then
                        cands[#cands + 1] = { X = box.c.X + i * box.e.X, Y = box.c.Y + j * box.e.Y, Z = box.c.Z + k * box.e.Z }
                    end
                end
            end
        end
    end
    -- the shortest way on, a waypoint that can't see the entry counting double for the rest of the way
    local pickW, pickScore
    for _, w in ipairs(cands) do
        if #cands == 1 or not crossesBox(here, w, inner) then
            local score = dist(here, w) + dist(w, entry) * (crossesBox(w, entry, inner) and 2 or 1)
            if not pickScore or score < pickScore then pickW, pickScore = w, score end
        end
    end
    if not pickW then return entry, 800 end
    c.route = { at = pickW, berth = b }
    return pickW, 800
end

-- A berth is taken while its crew holds it (docking, docked, backing out) and their ship still exists.
local function berthFree(b)
    local h = b.taken
    return not h or (h.berth ~= b and h.undockBerth ~= b) or not (h.ship and valid(h.ship))
end

local function takeBerth(st, c)
    for _, b in ipairs(st.berths) do
        if berthFree(b) then b.taken, c.berth = c, b return b end
    end
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
                    :gsub("^Ship_", ""):gsub("_Pawn_Ai_Child_C$", ""):gsub("01", "")
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
                    local ok, b = pcall(stationBerth, c, valid(shipActor) and shipActor or pc)
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

-- Crews ----------------------------------------------------------------------------------------------------------
local function newMember(usedNames)
    -- gear grade around your level (gearscale.lua); CFG.TIERS' fixed odds are only used with SCALE_GEAR off
    local scale = CFG.SCALE_GEAR ~= false and CFG.SCALE_GEAR ~= 0
    local tier = scale and GearScale.spec(GearScale.roll()) or weighted(CFG.TIERS)
    -- A free name; once all PILOTS are taken (11 crews + 6 skirmish pairs + ship watches is more than the list), a
    -- numbered one. This used to `repeat pick until unused`, which never ended then and froze the game mid-flight.
    local free = {}
    for _, n in ipairs(PILOTS) do if not usedNames[n] then free[#free + 1] = n end end
    local name = #free > 0 and pick(free) or nil
    if not name then
        local base, k = pick(PILOTS), 2
        while usedNames[base .. k] do k = k + 1 end
        name = base .. k
    end
    usedNames[name] = true
    local m = { name = name, tier = tier, alive = true, look = {}, skill = math.random() }
    m.female = math.random() < CFG.FEMALE
    m.voice = X.voice.pick(m.female)
    m.helmet = math.random() < tier.helmet
    m.chest = math.random() < tier.chest
    m.backpack = math.random() < tier.backpack
    m.maxHp = CFG.BASE_HP
    m.hp = m.maxHp
    return m
end

local function mapKind(worldName)
    if worldName:find("Raider", 1, true) then return "raider" end
    if worldName:find("Solo", 1, true) then return "solo" end
    return "crew"
end

-- A whole number in a { least, most } setting (the tuning menu can leave least above most).
local function between(r)
    local a, b = math.floor(r[1]), math.floor(r[2])
    if a > b then a, b = b, a end
    return math.random(a, b)
end

local function newCrew(i, used, size)
    local c = { id = i, ship = nil, members = {}, state = "waiting",
        shipName = SHIP_NAMES[(i - 1) % #SHIP_NAMES + 1],
        aggression = math.random(), -- how readily they attack other players' ships
        diehard = math.random() < CFG.DIEHARD,
        fleeHull = rnd(CFG.FLEE_HULL),
        launchAt = os.clock() + rnd(CFG.ARRIVAL_SPREAD),
        stationsLeft = between(CFG.STATIONS_PER_RAID),
        extractRemaining = rnd(CFG.EXTRACT_REMAINING),
        gunnery = rnd(CFG.GUN_SKILL) } -- how well they work their turrets (fireTurrets)
    for _ = 1, between(size) do
        local m = newMember(used)
        m.crew = i
        table.insert(c.members, m)
    end
    c.rusher = math.random() < CFG.RUSHERS
    c.captain = c.members[1].name
    return c
end

-- Event (#78): the Red Baron's crew. The map's own Red Baron frigate only turns up on some runs (the game rolls it), so
-- the guarantee is one of our crews: his strike frigate with its own guns, a full crew that fights to the death and
-- goes for any ship it sees, his best gunner, and the Baron himself as captain in the game's Baron head and coat, in
-- the best gear and with twice the health. He keeps the rivals' player-like brain (ai.lua "boss" is the weaker one).
-- (Fields of R.baron, not locals: this file's main chunk is at Lua's 200-local limit.)
R.baron = {
    head = "/Game/Characters/MainPlayer/Meshes/Heads/Baron_Head_Skel_01.Baron_Head_Skel_01",
    body = "/Game/Characters/MainPlayer/Meshes/Bodies/Baron_Body_Skel_01.Baron_Body_Skel_01",
}

function R.baron.design()
    for _, d in ipairs(CFG.HULLS) do if d.row == "StrikeFrigate_Ship" then return d end end
end

function R.baron.make(c, used)
    c.baron = true
    c.shipName = "Strike Frigate"
    c.diehard, c.rusher, c.aggression = true, false, 1
    c.gunnery = CFG.GUN_SKILL[2]
    local most = math.max(CFG.CREW_SIZE[1], CFG.CREW_SIZE[2])
    while #c.members < most do
        local m = newMember(used)
        m.crew = c.id
        table.insert(c.members, m)
    end
    local b = c.members[1]
    used["Red Baron"] = true
    b.name, b.baron = "Red Baron", true
    b.tier = GearScale.spec(1)
    b.helmet, b.chest, b.backpack = true, true, true
    b.female = false
    b.voice = X.voice.pick(false)
    b.headPath, b.bodyPath = R.baron.head, R.baron.body
    b.maxHp = CFG.BASE_HP * 2
    b.hp = b.maxHp
    c.captain = b.name
end

local function makeCrews(slots, kind)
    local crews, used = {}, {}
    local n = CFG.CREWS > 0 and math.floor(CFG.CREWS) or math.min(CFG.MAX_CREWS, math.max(0, slots - 1))
    local size = CFG.CREW_SIZE
    local baron = (tonumber(CFG.BARON) or 0) >= 1 and R.baron.design() ~= nil
    if baron then n = math.max(n, 1) end
    for i = 1, n do table.insert(crews, newCrew(i, used, size)) end
    if baron then R.baron.make(crews[1], used) end
    return crews
end

local function crewAlive(c)
    for _, m in ipairs(c.members) do if m.alive then return true end end
    return false
end

local function crewLabel(c)
    return ("%s's %s (%d)"):format(c.captain, c.shipName, #c.members)
end

-- Ships ----------------------------------------------------------------------------------------------------------
local function spawnShip(pc, c, at)
    local spots = {}
    for _, s in ipairs(S.shipSpawns) do
        if not S.playerShipLoc or dist(s, S.playerShipLoc) > 15000 then table.insert(spots, s) end
    end
    if #spots == 0 then spots = S.shipSpawns end
    if #spots == 0 and not at then return false end
    at = at or pick(spots)
    local design = c.baron and R.baron.design() or weighted(CFG.HULLS)
    local cls = loadClass("/Game/Blueprints/Ships/" .. design.pawn)
    local tree = lib(CFG.SHIP_TREE)
    if not (cls and valid(tree)) then return false end
    local off = { X = at.X + math.random(-1500, 1500), Y = at.Y + math.random(-1500, 1500), Z = at.Z }
    local ship = helper():SpawnAIFromClass(pc, cls, tree, off, { Pitch = 0, Yaw = math.random(0, 359), Roll = 0 },
        true, pc)
    if not valid(ship) then return false end
    c.ship, c.shipCtrl = ship, ship.Controller
    c.maxHull = ship.MainHullHealth
    c.design, c.turrets = design, {}
    -- the design's own hull: same skeleton as the base pawn's mesh
    local mpath = "/Game/Ships/" .. design.mesh
    if not mpath:find(".", 1, true) then mpath = mpath .. "." .. mpath:match("[^/]+$") end
    pcall(LoadAsset, mpath:match("^[^.]+"))
    local mesh = StaticFindObject(mpath)
    if valid(mesh) then pcall(function() ship.Mesh:SetSkeletalMesh(mesh, true) end) end
    -- turret slots: the design's types, now and then refitted with another
    c.turretPlan = {}
    local kinds = {}
    for k in pairs(CFG.TURRET_TYPES) do table.insert(kinds, k) end
    table.sort(kinds)
    for _, t in ipairs(design.turrets) do
        table.insert(c.turretPlan, not c.baron and math.random() < CFG.TURRET_SWAP and pick(kinds) or t)
    end
    c.turretKinds = { table.unpack(c.turretPlan) }
    -- The frigate's own behaviour tree picks the nearest ship it can see (usually yours) and steers at it, which made
    -- every crew swarm you. Rivals decide where to fly and whom to fight themselves.
    pcall(function() ship.Controller.BrainComponent:StopLogic("rivals") end)
    S.armPending = true
    return true
end

-- Ship guns: a bow gun is spawned for each ship that has none (two per second at most), also for your own ship, whose
-- bow gun is missing offline for the same reason. They used to be summoned by console command and then found with a
-- FindAllOf, ~45 ms each time: a hitch about every second while crews launched.
local function newGun(near)
    local cls = loadClass(CFG.GUN_PATH)
    if not cls then return nil end
    local g = near:GetWorld():SpawnActor(cls, near:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    return valid(g) and g or nil
end

local function equipGun(ship, g)
    g:SetOwner(ship)
    g.Instigator = ship
    g.MyPawn = ship
    pcall(function() g:OnRep_MyPawn() end)
    ship.Inventory[#ship.Inventory + 1] = g
    ship:ServerEquipWeapon(g)
end

-- Turret aim. A barrel follows its AnimBP's Yaw_Delayed / NewPitch (deg off the hull's nose), which the turret
-- actor's tick (its CameraRotation) works out every frame from whoever the game thinks aims it: on your hull that's
-- the pilot's view, so from the helm your mouse swung the turret your gunner was firing (TurretLocalRot moves
-- nothing). Turrets in AIMED have their actor tick off instead, and swingAimed writes both every frame: their gunners'
-- aim (wantYaw/wantPitch), swung at TURRET_SWING x the turret's own speed. fireTurrets shoots along that barrel.
-- This used to be a hook on every turret AnimBP's CameraRotation: it ran for all of them each frame, aimed or not
-- (~200 at a time late in a raid, wrecks included: 10k+ calls a second), and UE4SS makes garbage for every call:
-- ~18 MB a second, the collector 0.8 s per 10 s with 13 ms steps, a stutter that got worse the longer the raid ran
-- (profile.txt, 2026-11-15).
local AIMED = {} -- AnimBP address -> fireTurrets entry

local function swingStep(cur, want, speed, dt)
    local m = speed * CFG.TURRET_SWING * dt
    return cur + math.max(-m, math.min(m, want - cur))
end

-- Every frame, from R.frame: swing each aimed barrel toward its gunners' aim.
local function swingAimed(dt)
    if next(AIMED) == nil then return end
    local P = _G.PVE_PROF
    for addr, e in pairs(AIMED) do
        local a = e.anim
        if not (valid(e.actor) and valid(a)) then
            AIMED[addr] = nil
        else
            e.yaw = swingStep(e.yaw, e.wantYaw, e.yawSpeed, dt)
            e.pitch = swingStep(e.pitch, e.wantPitch, e.pitchSpeed, dt)
            a.Yaw_Delayed = e.yaw
            a.NewPitch = e.pitch
            if P then P.swing = (P.swing or 0) + 1 end
        end
    end
end

-- Puts a fireTurrets entry's barrel under its gunners (on) or gives it back to the game; it starts where it points now
-- and rests facing the nose until there's something to aim at.
local function aimTurret(e, on)
    local ok, ab = pcall(function() return e.actor.TurretBarrelMesh:GetAnimInstance() end)
    if not (ok and valid(ab)) then return end
    local addr = ab:GetAddress()
    if not on then
        AIMED[addr], e.aimed, e.anim = nil, nil, nil
        pcall(function() e.actor:SetActorTickEnabled(true) end)
        return
    end
    e.yaw, e.pitch = 0, 0
    pcall(function() e.yaw, e.pitch = ab.Yaw_Delayed, ab.NewPitch end)
    e.wantYaw, e.wantPitch = 0, 0
    e.yawSpeed, e.pitchSpeed = 20, 10
    pcall(function() e.yawSpeed, e.pitchSpeed = e.actor.TurretYawSpeed, e.actor.TurretPitchSpeed end)
    pcall(function() e.actor:SetActorTickEnabled(false) end)
    e.aimed, e.anim = true, ab
    AIMED[addr] = e
end

-- A wreck's turrets (its camera turrets too) stop ticking: nobody aims them again, and dozens of wrecks build up.
local function stillTurrets(c)
    for _, t in ipairs(c.turrets or {}) do
        if valid(t.actor) then
            aimTurret(t, false)
            pcall(function() t.actor:SetActorTickEnabled(false) end)
        end
    end
    if not valid(c.ship) then return end
    pcall(function()
        c.ship.SpawnedTurretArray:ForEach(function(_, e)
            local t = e:get()
            if valid(t) then t:SetActorTickEnabled(false) end
        end)
    end)
end

-- Turrets: the design's turret actors attached to the hull's Soc_Turret01/02, fired by fireTurrets (nobody mans them).
-- One ship is fitted per update (several spawns in one tick have crashed the game).
local function fitTurrets(c)
    c.turretPlan = c.turretPlan or {}
    -- the hull blueprint spawns its own default turret on Soc_Turret01 (camera turrets stay): replaced by the plan's
    local addr = c.ship:GetAddress()
    -- the hull's own list of what it spawned (a FindAllOf here cost ~45 ms per ship: a hitch while flying)
    local own = {}
    c.ship.SpawnedTurretArray:ForEach(function(_, e) own[#own + 1] = e:get() end)
    for _, t in ipairs(own) do
        if valid(t) and not t.bACameraTurret then
            local p = t:GetAttachParentActor()
            if valid(p) and p:GetAddress() == addr then R.destroy(t) end
        end
    end
    for slot, kind in ipairs(c.turretPlan) do
        local tt = CFG.TURRET_TYPES[kind]
        local path = "/Game/Blueprints/Ships_Extras/Turrets/" .. tt.cls
        local cls = loadClass(path)
        if cls then
            local t = c.ship:GetWorld():SpawnActor(cls, c.ship:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
            if valid(t) then
                t:K2_AttachToComponent(c.ship.Mesh, FName("Soc_Turret0" .. slot), 2, 2, 2, false)
                t:SetActorRelativeScale3D({ X = 1.25, Y = 1.25, Z = 1.25 })
                t.MyFrigateOwner = c.ship
                t:SetOwner(c.ship)
                local socks = {}
                t.FiringSockets:ForEach(function(_, e) socks[#socks + 1] = e:get():ToString() end)
                local e = { actor = t, kind = kind, socks = socks, si = 1, speed = tt.speed,
                    rate = t.FireRate, reload = t.ReloadTime, ammo = math.max(1, t.TotalAmmo), left = t.TotalAmmo,
                    range = tt.range, spread = tt.spread, next = 0 }
                table.insert(c.turrets, e)
                aimTurret(e, true)
            end
        end
    end
    c.turretPlan = nil
end

local function dropTurrets(c)
    for _, t in ipairs(c.turrets or {}) do
        if valid(t.actor) then
            aimTurret(t, false)
            pcall(function() t.actor:K2_DestroyActor() end)
        end
    end
    c.turrets = {}
end

-- A crew's gunners and their aim on the current target (c.aim): a new target starts them off by GUN_FIRST_MISS, with a
-- misjudged lead; each volley walks part of the error off (GUN_SETTLE), the target turning hard puts some back
-- (GUN_JINK), and a green gunner never quite holds still (GUN_WANDER). All of it shrinks with c.gunnery (0..1).
local function gunAim(c, tgt, tv)
    local skill = math.max(0, math.min(1, c.gunnery or 0.5))
    c.aim = c.aim or {}
    local a, addr = c.aim, tgt:GetAddress()
    local green = 1 - skill
    if a.tgt ~= addr then
        local miss = CFG.GUN_FIRST_MISS * (1 - 0.7 * skill)
        a.tgt, a.yaw, a.pitch = addr, gauss() * miss, gauss() * miss * 0.5
        a.lead = 1 + gauss() * CFG.GUN_LEAD_ERROR * green
    elseif a.vx then
        local s1, s2 = math.sqrt(a.vx * a.vx + a.vy * a.vy), math.sqrt(tv.X * tv.X + tv.Y * tv.Y)
        if s1 > 100 and s2 > 100 then
            local turn = math.deg(math.acos(math.max(-1, math.min(1, (a.vx * tv.X + a.vy * tv.Y) / (s1 * s2)))))
            local jink = turn / 10 * CFG.GUN_JINK * (1 - 0.5 * skill)
            a.yaw = a.yaw + (math.random() < 0.5 and -jink or jink) * math.random()
        end
    end
    a.vx, a.vy = tv.X, tv.Y
    a.spread = CFG.TURRET_SPREAD * (CFG.GUN_SPREAD_SKILL[1] + (CFG.GUN_SPREAD_SKILL[2] - CFG.GUN_SPREAD_SKILL[1]) * skill)
    return a, skill
end

-- After a volley: part of the error walked off, plus a green gunner's drift.
local function gunSettle(a, skill)
    local keep = 1 - CFG.GUN_SETTLE * (0.5 + 0.5 * skill)
    local wander = CFG.GUN_WANDER * (1 - skill)
    a.yaw = a.yaw * keep + gauss() * wander
    a.pitch = a.pitch * keep + gauss() * wander * 0.5
end

-- Swings each turret whose arc covers the target onto it (leading it by the shell's flight time, as well as the crew's
-- gunnery manages: gunAim) and fires the loaded ones whose barrel is there, along the barrel, through the turret's own
-- ServerFireProjectile: its shells, effects and damage. Called every frame while a crew engages.
-- For the status line: per turret-frame, why turrets held fire since the last report (range / arc / pitch / swing / reload).
local function turretWhy()
    local w = S.turretWhy
    S.turretWhy = nil
    if not w then return "" end
    local n, t = 0, {}
    for _, v in pairs(w) do n = n + v end
    for _, k in ipairs({ "range", "arc", "pitch", "swing", "reload" }) do
        if w[k] then t[#t + 1] = ("%s %d%%"):format(k, math.floor(w[k] * 100 / n + 0.5)) end
    end
    return " (held: " .. table.concat(t, ", ") .. ")"
end

local function fireTurrets(c, tgt, now)
    if not c.turrets or #c.turrets == 0 then c.held = nil return false end
    local sl, tl = c.ship:K2_GetActorLocation(), tgt:K2_GetActorLocation()
    local tv = tgt:GetVelocity()
    local r = c.ship:K2_GetActorRotation()
    local a, skill = gunAim(c, tgt, tv)
    local arc = c.arc or CFG.TURRET_ARC
    local fired, seen = false, {}
    for _, t in ipairs(c.turrets) do
        if valid(t.actor) and not t.aimed and now >= (t.aimTry or 0) then
            t.aimTry = now + 1 -- (a turret spawned this frame has no AnimBP yet)
            aimTurret(t, true)
        end
        local d = dist(sl, tl)
        local why = "range"
        if valid(t.actor) and d < math.max(t.range * (c.rangeScale or 1), c.reach or 0) then
            why = "arc"
            local tof = d / t.speed * a.lead
            local aim = { X = tl.X + tv.X * tof, Y = tl.Y + tv.Y * tof, Z = tl.Z + tv.Z * tof }
            local yaw = math.deg(math.atan(aim.Y - sl.Y, aim.X - sl.X))
            local rel = (yaw - r.Yaw + 180) % 360 - 180
            if math.abs(rel) <= arc then
                why = nil
                local sock = t.socks[t.si] or "Soc_Barrel01"
                local o = t.actor.TurretBarrelMesh:GetSocketLocation(FName(sock))
                local dx, dy, dz = aim.X - o.X, aim.Y - o.Y, aim.Z - o.Z
                -- the gunners' error, as yaw/pitch off the true lead (world deg), and that off the hull's nose
                local ay = math.deg(math.atan(dy, dx)) + a.yaw
                local ap = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))) + a.pitch
                local wy, wp = (ay - r.Yaw + 180) % 360 - 180, ap - r.Pitch
                t.wantYaw = math.max(-arc, math.min(arc, wy))
                t.wantPitch = math.max(CFG.TURRET_PITCH[1], math.min(CFG.TURRET_PITCH[2], wp))
                -- the barrel's own heading once it's ours and swinging (no AnimBP hook: straight along the aim)
                -- (the barrel is checked against where it can point: comparing it with an aim past its lift/dip limit
                -- used to hold every turret whose target was a little above or below)
                local past = math.abs(wp - t.wantPitch)
                local on = past <= (c.pitchSlack or CFG.TURRET_PITCH_SLACK)
                if not on then why = "pitch" end
                if on and t.aimed and t.swungAt and now - t.swungAt < 0.5 then
                    on = math.abs(t.yaw - t.wantYaw) <= CFG.TURRET_ON_AIM and math.abs(t.pitch - t.wantPitch) <= CFG.TURRET_ON_AIM
                    if not on then why = "swing" end
                    -- (your gunner, past the barrels' lift/dip: the shell keeps the true pitch, or it went off by up to
                    -- GUNNER_PITCH_SLACK deg)
                    ay = r.Yaw + t.yaw
                    if not (c.pitchSlack and past > 0) then ap = r.Pitch + t.pitch end
                end
                if on and now >= t.next then
                    -- then the gun's own spread
                    local sp = math.rad(t.spread * a.spread)
                    local ry, rp = math.rad(ay), math.rad(ap)
                    local dir = { X = math.cos(rp) * math.cos(ry) + (math.random() - 0.5) * sp,
                        Y = math.cos(rp) * math.sin(ry) + (math.random() - 0.5) * sp, Z = math.sin(rp) + (math.random() - 0.5) * sp }
                    local ok, err = pcall(function() t.actor:ServerFireProjectile(o, dir, t.si - 1) end)
                    if ok then S.turretShots = (S.turretShots or 0) + 1
                    elseif not S.turretErr then S.turretErr = true X.log("[rivals] turret fire failed: " .. tostring(err)) end
                    t.si = t.si % math.max(1, #t.socks) + 1
                    t.left = t.left - 1
                    if t.left <= 0 then t.left, t.next = t.ammo, now + t.reload else t.next = now + t.rate end
                    fired = true
                elseif on then why = "reload" end
            end
        end
        if why then S.turretWhy = S.turretWhy or {} S.turretWhy[why] = (S.turretWhy[why] or 0) + 1 end
        seen[why or "ok"] = true
    end
    -- c.held: "range", "arc" or "pitch" when no turret could bear on the target at all (your gunner says so, crew.lua)
    c.held = not (seen.ok or seen.reload or seen.swing) and (seen.range and "range" or seen.arc and "arc"
        or seen.pitch and "pitch") or nil
    if fired then gunSettle(a, skill) end
    return fired
end

local function armShips(pc, now)
    for _, c in ipairs(S.crews) do
        if c.turretPlan and c.ship and valid(c.ship) then
            local ok, err = xpcall(fitTurrets, function(e) return tostring(e) .. " | " .. debug.traceback() end, c)
            if not ok then c.turretPlan = nil X.log("[rivals] fitting turrets failed: " .. tostring(err)) end
            break
        end
    end
    if now < (S.nextArm or 0) then return end
    S.nextArm = now + 1
    local need = {}
    for _, c in ipairs(S.crews) do
        if c.ship and valid(c.ship) and not (c.gun and valid(c.gun)) then table.insert(need, c) end
    end
    local mine = valid(S.playerShip) and not valid(S.playerShip.CurrentWeapon)
    local fitting = false
    for _, c in ipairs(S.crews) do if c.turretPlan and c.ship then fitting = true end end
    if #need == 0 and not mine then S.armPending = fitting return end
    local spawned = 0
    if mine then
        local ok, err = pcall(function()
            local g = newGun(S.playerShip)
            if not g then error("no gun spawned") end
            equipGun(S.playerShip, g)
        end)
        spawned = spawned + 1
        X.log(ok and "[rivals] your ship's bow gun is fitted" or ("[rivals] arming your ship failed: " .. tostring(err)))
    end
    for _, c in ipairs(need) do
        if spawned >= CFG.GUNS_PER_STEP then break end
        spawned = spawned + 1
        local ok, err = pcall(function()
            local g = newGun(c.ship)
            if not g then error("no gun spawned") end
            equipGun(c.ship, g)
            c.gun = g
        end)
        if not ok then X.log("[rivals] arming failed: " .. tostring(err)) end
    end
    local short = 0
    for _, c in ipairs(need) do if not c.gun then short = short + 1 end end
    if mine and not valid(S.playerShip.CurrentWeapon) then short = short + 1 end
    for _, c in ipairs(S.crews) do if c.turretPlan and c.ship then short = short + 1 end end
    S.armPending = short > 0
end

-- References to actors the game may destroy (sunk ships) are dropped the moment they stop being valid, before the
-- garbage collector frees them.
local function shipOk(c)
    if c.ship and not valid(c.ship) then c.ship, c.shipCtrl = nil, nil dropTurrets(c) end
    if c.shipCtrl and not valid(c.shipCtrl) then c.shipCtrl = nil end
    return c.ship ~= nil and c.shipCtrl ~= nil and (c.ship.MainHullHealth or 0) > 0
end

-- What a ship's obstacle sweeps pass through: its own turrets and gun, and its target (attack runs pass close on
-- purpose: RUN_OFFSET keeps them off it) with the target's turrets.
local function navIgnore(c)
    local list = { c.ship }
    if valid(c.gun) then list[#list + 1] = c.gun end
    for _, t in ipairs(c.turrets or {}) do if valid(t.actor) then list[#list + 1] = t.actor end end
    local tgt = c.fireAt
    if valid(tgt) then
        list[#list + 1] = tgt
        pcall(function()
            tgt.SpawnedTurretArray:ForEach(function(_, e) local t = e:get() if valid(t) then list[#list + 1] = t end end)
        end)
        if valid(tgt.CurrentWeapon) then list[#list + 1] = tgt.CurrentWeapon end
    end
    return list
end

local function flyTo(c, at, accept)
    if c.glide then return end -- docking/undocking: R.frame moves the ship
    local ctrl = c.shipCtrl
    -- around anything in the way, and out again when stuck (shipnav.lua)
    local ok0, wp, acc, fresh = pcall(Nav.steer, c, c.ship, at, accept or 300, os.clock(), navIgnore(c), S.watchers)
    if ok0 then
        at, accept = wp, acc
    elseif not c.navErr then
        c.navErr = true
        X.log(("[rivals] %s steering failed: %s"):format(crewLabel(c), tostring(wp)))
    end
    -- The frigate's own AI keeps issuing patrol moves: re-issue ours whenever its destination isn't ours.
    local ok, dest = pcall(function() return ctrl:GetImmediateMoveDestination() end)
    local ours = ok and dest and dest.X and dist(dest, at) < 600
    if not fresh and c.flyTarget and dist(c.flyTarget, at) < 400 and ctrl:GetMoveStatus() == 3 and ours then return end
    c.flyTarget = at
    -- No navmesh in space: a direct move (no pathfinding), as the frigate AI flies.
    ctrl:MoveToLocation(at, accept or 300, false, false, false, true, nil, true)
end

local function setShipEnemy(c, target)
    -- The player hull designs fly under a plain AIController with no blackboard: only focus (aims the bow gun).
    local bb = c.shipCtrl.BlackboardComp
    if valid(target) then
        if valid(bb) then bb:SetValueAsObject(FName("Enemy"), target) end
        c.shipCtrl:K2_SetFocus(target)
    else
        if valid(bb) then bb:ClearValue(FName("Enemy")) end
        c.shipCtrl:K2_ClearFocus()
    end
end

-- How many crews a station holds before it counts as busy (its size), and how many it has: docked there or on the way.
-- Bodies awake around you: every live director bot that isn't parked (main.lua Aux.parked), your crew excepted.
function R.awakeCount()
    local n = 0
    for _, e in ipairs(X.raid().bots) do
        if not e.parked and not e.crewmate and valid(e.bot) and (e.bot.Health or 0) > 0 then n = n + 1 end
    end
    return n
end

local function insideCap(st) return math.max(CFG.INSIDE_MIN, math.floor((st.area or CFG.STATION_AREA_MID) / CFG.INSIDE_AREA_PER_CREW)) end
local function crewsInside(st)
    local n = 0
    for _, o in ipairs(S.crews) do
        if o.station == st and o.state == "docked" and o.bodies then
            for _, e in ipairs(o.bodies) do
                if valid(e.bot) and (e.bot.Health or 0) > 0 then n = n + 1 break end
            end
        end
    end
    return n
end
local function stationCapacity(st) return math.max(1, (st.area or CFG.STATION_AREA_MID) / CFG.STATION_AREA_PER_CREW) end
local function stationLoad(st, except)
    local n = 0
    for _, o in ipairs(S.crews) do
        if o ~= except and o.station == st and (o.state == "travel" or o.state == "docked" or o.state == "waiting") then
            n = n + 1
        end
    end
    return n
end

-- Somewhere new with a free berth if possible, picked by size: a big station draws more crews than a small one, and
-- each draws less the more crews it already has (so the small ones still see the odd crew, and the big ones fill
-- up first). An AI frigate that sank can't be reached any more.
local function chooseStation(c)
    local free, any = {}, {}
    for _, st in ipairs(S.stations) do
        if st.frigate ~= nil and not (st.frigate and valid(st.frigate)) then st.frigate = false end
        if st ~= c.lastStation and st.frigate ~= false then
            table.insert(any, st)
            for _, b in ipairs(st.berths) do if berthFree(b) then table.insert(free, st) break end end
        end
    end
    local options = #free > 0 and free or any
    if #options == 0 then return nil end
    local total, weights = 0, {}
    for i, st in ipairs(options) do
        local cap = stationCapacity(st)
        weights[i] = cap * CFG.STATION_CROWD ^ (stationLoad(st, c) / cap)
        total = total + weights[i]
    end
    local r = math.random() * total
    for i, st in ipairs(options) do
        r = r - weights[i]
        if r <= 0 then return st end
    end
    return options[#options]
end

-- Docking and undocking are a smooth glide between the approach point and the berth (R.frame), with the ship's
-- own movement stopped; docked ships are held in their berth.
local function startGlide(c, dir, beyond)
    local l, r = c.ship:K2_GetActorLocation(), c.ship:K2_GetActorRotation()
    c.ship.CharacterMovement:StopMovementImmediately()
    pcall(function() c.shipCtrl:StopMovement() c.shipCtrl:K2_ClearFocus() end)
    c.glide = { dir = dir, t0 = os.clock(), dur = beyond and CFG.DERELICT_GLIDE or dir == "in" and CFG.DOCK_GLIDE
            or CFG.UNDOCK_GLIDE, beyond = beyond,
        station = c.glide and c.glide.station or c.station, berth = c.berth or c.undockBerth,
        from = { X = l.X, Y = l.Y, Z = l.Z }, yaw = r.Yaw, pitch = r.Pitch, roll = r.Roll }
end

local function undock(c, beyond)
    if c.glide then c.berth = c.berth or c.glide.berth end
    c.undockBerth, c.berth, c.moored = c.berth, nil, nil
    if c.undockBerth and shipOk(c) then startGlide(c, "out", beyond) end
end

-- A docked crew wiped out (killed raiding the station, or by another crew in it) left their ship held in its berth for
-- the rest of the raid, shown again as a derelict and still holding the berth: nobody else could dock there (user
-- report 2026-11-15, the Rusty Mule at Spaceport). It drifts out, well past the approach lane, and waits there.
local function clearBerth(c)
    if c.moored or (c.glide and c.glide.dir == "in") then
        undock(c, CFG.DERELICT_CLEAR)
    else
        c.berth = nil -- only on its way in: the berth it had reserved is free again
    end
end

-- Docked ships are hidden (and don't collide): a ship held in its berth sat visibly wedged into the station's
-- airlock frame, and ships of crews that breached in (no free berth) idled in a clump beside a station that flies on,
-- like Colony Cruiser (2026-11-14). Shown again once they glide out, leave or you're aboard one. Their turrets too.
local function showShip(c, show)
    for _, a in ipairs({ c.ship }) do
        pcall(function() a:SetActorHiddenInGame(not show) a:SetActorEnableCollision(show) end)
    end
    for _, t in ipairs(c.turrets or {}) do
        if valid(t.actor) then pcall(function() t.actor:SetActorHiddenInGame(not show) end) end
    end
    c.hidden = not show
end

local function glideShips(now)
    for _, c in ipairs(S.crews) do
        if c.ship and valid(c.ship) then
            local hide = c.state == "docked" and not c.glide and S.aboard ~= c
            if hide ~= (c.hidden or false) then showShip(c, not hide) end
        end
        local g = c.glide
        if g and not (c.ship and valid(c.ship)) then
            c.glide, c.undockBerth = nil, nil
        elseif g then
            local at, yaw, approach = berthPose(g.station, g.berth)
            if not at then
                c.glide, c.undockBerth = nil, nil -- the AI frigate it was docked at is gone
            else
                local to = g.dir == "in" and at or approach
                if g.beyond then
                    local ox, oy, oz = approach.X - at.X, approach.Y - at.Y, approach.Z - at.Z
                    local on = math.max(1, math.sqrt(ox * ox + oy * oy + oz * oz))
                    to = { X = approach.X + ox / on * g.beyond, Y = approach.Y + oy / on * g.beyond,
                        Z = approach.Z + oz / on * g.beyond }
                end
                local t = math.min(1, (now - g.t0) / g.dur)
                local s = t * t * (3 - 2 * t)
                local dy = (yaw - g.yaw + 180) % 360 - 180
                local rot = { Pitch = g.pitch * (1 - s), Yaw = g.yaw + dy * s, Roll = g.roll * (1 - s) }
                Out.call(c.ship, "K2_SetActorLocationAndRotation", 
                    { X = g.from.X + (to.X - g.from.X) * s, Y = g.from.Y + (to.Y - g.from.Y) * s,
                        Z = g.from.Z + (to.Z - g.from.Z) * s }, rot, false, {}, true)
                if c.shipCtrl and valid(c.shipCtrl) then c.shipCtrl:SetControlRotation(rot) end
                if t >= 1 then
                    c.glide = nil
                    if g.dir == "in" then c.moored = g.station else c.undockBerth = nil end
                end
            end
        elseif c.moored and c.berth and c.ship and valid(c.ship) then
            -- Hold the berth (and keep up with an AI frigate that flies on). The ship's controller keeps turning it
            -- (it steers by control rotation), so hold that too.
            local at, yaw = berthPose(c.moored, c.berth)
            if at and (dist(c.ship:K2_GetActorLocation(), at) > 30
                    or math.abs((c.ship:K2_GetActorRotation().Yaw - yaw + 180) % 360 - 180) > 2) then
                local rot = { Pitch = 0, Yaw = yaw, Roll = 0 }
                Out.call(c.ship, "K2_SetActorLocationAndRotation", at, rot, false, {}, true)
                if c.shipCtrl and valid(c.shipCtrl) then c.shipCtrl:SetControlRotation(rot) end
            end
        end
    end
end

-- Where a leaving ship heads: a ship spawn point, but not the one your frigate sits at, and the one fewest other
-- leaving crews are heading for (nearest first). Leaving ships stalled 70-80 m off their exit, circling for minutes
-- (2026-11-15): a hull parked at the point (yours, or another leaver's) sat in shipnav's sweep, so every approach
-- turned into a detour away from it and back again.
-- (On R, not a local: the file sits at Lua's 200-local limit for its main chunk.)
function R.pickExit(c)
    local here = shipOk(c) and c.ship:K2_GetActorLocation() or nil
    local best, bn, bd
    for _, s in ipairs(S.shipSpawns) do
        if not S.playerShipLoc or dist(s, S.playerShipLoc) > 15000 or #S.shipSpawns == 1 then
            local n = 0
            for _, o in ipairs(S.crews) do
                if o ~= c and o.state == "leaving" and o.exitAt and dist(o.exitAt, s) < 1 then n = n + 1 end
            end
            local d = here and dist(here, s) or math.random()
            if not best or n < bn or (n == bn and d < bd) then best, bn, bd = s, n, d end
        end
    end
    return best or pick(S.shipSpawns)
end

local function startLeaving(c, why)
    c.state, c.station, c.target, c.fireAt = "leaving", nil, nil, nil
    c.exitAt = R.pickExit(c)
    c.exitBest, c.exitBestAt = nil, nil
    X.log(("[rivals] %s extracting (%s)"):format(crewLabel(c), why))
end

-- Bodies ---------------------------------------------------------------------------------------------------------
-- Building one takes more than one update: the kit goes on at once, but its gun arrives a moment later.
local function comps(actor)
    local out = {}
    local all = actor:K2_GetComponentsByClass(lib("/Script/Engine.SkeletalMeshComponent"))
    for i = 1, #all do
        local c = all[i]:get()
        if valid(c) then out[c:GetFName():ToString()] = c end
    end
    return out
end

local landCatalog -- land raids have no rivals state; your crew (crew.lua) still needs looks there
local function gearCatalog()
    -- Every head and body in the game, loaded once: a look for each rival.
    if S and S.catalog then return S.catalog end
    if not S and landCatalog then return landCatalog end
    local cat = { heads = {}, bodies = {} }
    for key, paths in pairs({ heads = Gear.heads, bodies = Gear.bodies }) do
        for _, path in ipairs(paths) do
            local mesh = lib(path)
            if not valid(mesh) then
                pcall(LoadAsset, path)
                mesh = lib(path)
            end
            if valid(mesh) then
                X.root(mesh)
                table.insert(cat[key], mesh)
            end
        end
    end
    for _, list in ipairs({ cat.heads, cat.bodies }) do
        for _, mesh in ipairs(list) do X.female.version(mesh, true) end
    end
    X.log(("[rivals] looks: %d heads, %d bodies"):format(#cat.heads, #cat.bodies))
    if S then S.catalog = cat else landCatalog = cat end
    return cat
end

-- A raider body's gun must be equipped or it never fires: the bot ran around with its gun lowered, harmless
-- (director's arm() only equips an existing CurrentWeapon). Equipping
-- attaches it to CharacterMesh0, which on a raider is the head (the gun was invisible there): carry it on the body.
-- Checked again every update, in case the game re-equips or re-attaches.
-- A kit, rolled once for a person: rows of the game's item table within the tier's price ranges.
local function inBand(list, band)
    local fits = {}
    for _, row in ipairs(list) do
        if row[2] >= band[1] and row[2] <= band[2] then fits[#fits + 1] = row end
    end
    return pick(fits)
end

-- `tier` is one of CFG.TIERS (price bands) or a GearScale.spec (a grade g: rows near that share of each price-sorted list).
local function rollKit(tier, helmet, chest, bag)
    local function row(list, band)
        if tier.g then return GearScale.pick(list, tier.g) end
        return inBand(list, band)
    end
    return { gun = row(Gear.guns, tier.guns), helmet = helmet and row(Gear.helmets, tier.helmets)[1] or nil,
        chest = chest and row(Gear.chests, tier.chests)[1] or nil, bag = bag and row(Gear.bags, tier.bags)[1] or nil,
        stacks = math.random(CFG.AMMO_STACKS[1], CFG.AMMO_STACKS[2]), meds = math.random(CFG.MEDS[1], CFG.MEDS[2]) }
end

-- Puts a kit on a body the way the game does for a placed bot: the rows go into its spawn slots and the game's kit step
-- makes the items, dresses the body from them and spawns the gun, so what a body wears, holds and drops is one thing.
local function equipKit(body, kit)
    local function row(name) return name and FName(name):GetComparisonIndex() or 0 end
    local at = math.tointeger(body:GetAddress())
    -- A pistol rolled as the gun goes in the pistol slot (it showed in the primary's on the body, #101).
    local gun, pistol = kit.gun and kit.gun[1], kit.pistol
    local gi = gun and require("itemdata").get(gun)
    if gi and gi.type == 1 and not pistol then gun, pistol = nil, gun end
    X.rollKit(at, math.tointeger(lib(CFG.ITEM_TABLE):GetAddress()), row(gun), row(pistol), row(kit.helmet),
        row(kit.chest), row(kit.bag))
    if kit.gun and kit.gun[3] then
        for _ = 1, kit.stacks do X.addItem(at, row(kit.gun[3]), require("itemdata").capStack(kit.gun[3], CFG.AMMO_STACK)) end
    end
    for _ = 1, kit.meds do X.addItem(at, row(pick(Gear.meds)[1]), 1) end
end

-- A station guard's bags and pockets, rolled (the level gives each one a single row: an ammo stack, maybe a bandage). Its
-- worn gear stays. Better-equipped guards carry dearer things; a bag holds more than pockets do.
local PRICES
local function priceOf(name)
    if not PRICES then
        PRICES = {}
        for _, list in ipairs({ Gear.guns, Gear.helmets, Gear.chests, Gear.bags }) do
            for _, r in ipairs(list) do PRICES[r[1]] = r end
        end
    end
    return PRICES[name]
end

local function weightedRow(list, cap)
    local fits, total = {}, 0
    for _, r in ipairs(list) do
        if r[2] <= cap then fits[#fits + 1] = r total = total + 1 / math.sqrt(r[2]) end
    end
    local x = math.random() * total
    for _, r in ipairs(fits) do
        x = x - 1 / math.sqrt(r[2])
        if x <= 0 then return r end
    end
    return fits[#fits]
end

-- The kit rows a placed NPC was given by its level ("None" slots left out): gun, pistol, helmet, chest, bag.
local KIT_FIELDS = { gun = "WeaponToSpawn", pistol = "PistolToSpawn", helmet = "HelmetToSpawn", chest = "ArmourToSpawn",
    bag = "BackPackToSpawn" }
local function wornRows(b)
    local rows = {}
    for k, f in pairs(KIT_FIELDS) do
        local name = "None"
        pcall(function() name = b[f].RowName:ToString() end)
        if name ~= "None" and name ~= "" then rows[k] = name end
    end
    return rows
end

local function rollCarried(b)
    local worn, wealth, guns = {}, 0, {}
    for _, f in ipairs({ "WeaponToSpawn", "PistolToSpawn", "HelmetToSpawn", "ArmourToSpawn", "BackPackToSpawn" }) do
        local name = "None"
        pcall(function() name = b[f].RowName:ToString() end)
        local r = name ~= "None" and priceOf(name)
        if r then
            worn[f] = name
            wealth = wealth + r[2]
            if r[3] then guns[#guns + 1] = r[3] end
        end
    end
    local at = math.tointeger(b:GetAddress())
    X.keepWorn(at)
    -- Never past the row's own stack (12 gauge stacks at 20, and a 35-shell stack showed as 35/20, issue #102). A
    -- blueprint's stack is its uses: one found on a body has half to all of them, not 1 (#100).
    local function add(name, n)
        local Items = require("itemdata")
        local max = Items.max(name)
        if name:find("Blueprint", 1, true) and max and max > 1 and n <= 1 then n = math.random(math.ceil(max / 2), max) end
        X.addItem(at, FName(name):GetComparisonIndex(), Items.capStack(name, n))
    end
    local cap = math.max(CFG.CARRY_CAP_MIN, wealth * CFG.CARRY_CAP_SHARE)
    if math.random() < CFG.CARRY_JACKPOT then cap = 1e9 end
    local bag = worn.BackPackToSpawn ~= nil
    local carried = {}
    -- No bag: one pocket slot (the game turns away the rest), so one roll for it.
    if not bag then
        local function count() local n = 0 b.BotLootItems:ForEach(function() n = n + 1 end) return n end
        local before = count()
        for _ = 1, 4 do -- a roll too big for the pocket is turned away: roll again
            local x, name, n = math.random(), nil, 1
            if x < CFG.POCKET_AMMO and guns[1] then
                name, n = guns[1], math.random(CFG.CARRY_AMMO[1], CFG.CARRY_AMMO[2])
            else
                local r = x < CFG.POCKET_AMMO + CFG.POCKET_MED and weightedRow(Gear.meds, cap)
                    or weightedRow(math.random() < CFG.CARRY_PART and Gear.parts or Gear.loot, cap)
                name = r and r[1]
            end
            if name then
                add(name, n)
                if count() > before then return { n > 1 and (name .. " x" .. n) or name } end
            end
        end
        return {}
    end
    for i, ammo in ipairs(guns) do
        for _ = 1, (i == 1 and math.random(CFG.AMMO_STACKS[1], CFG.AMMO_STACKS[2]) or 1) do
            local n = math.random(CFG.CARRY_AMMO[1], CFG.CARRY_AMMO[2])
            add(ammo, n)
            carried[#carried + 1] = ammo .. " x" .. n
        end
    end
    for _ = 1, math.random(CFG.MEDS[1], CFG.MEDS[2]) do
        local r = weightedRow(Gear.meds, cap)
        if r then add(r[1], 1) carried[#carried + 1] = r[1] end
    end
    for _ = 1, math.random(CFG.CARRY_BAG[1], CFG.CARRY_BAG[2]) do
        local x, list = math.random(), Gear.loot
        if x < CFG.CARRY_BOX then list = Gear.boxes elseif x < CFG.CARRY_BOX + CFG.CARRY_PART then list = Gear.parts end
        local r = weightedRow(list, cap)
        if r then add(r[1], 1) carried[#carried + 1] = r[1] end
    end
    return carried
end

local function gunName(gun)
    return (gun:GetClass():GetFName():ToString():gsub("_Child_C$", ""):gsub("^%a+_", ""))
end

local function holdGun(e)
    local bot = e.bot
    if not valid(bot) or (bot.Health or 0) <= 0 then return end
    local gun = bot.CurrentWeapon
    if not valid(gun) then
        bot.Inventory:ForEach(function(_, w)
            local g = w:get()
            if not valid(gun) and valid(g) then gun = g end
        end)
        if not valid(gun) then return end
        bot:ServerEquipWeapon(gun)
    end
    if valid(e.hand) and valid(gun.Mesh1P) and gun.Mesh1P:GetAttachParent():GetFName():ToString() ~= "CharacterBody0" then
        gun.Mesh1P:K2_AttachToComponent(e.hand, FName("Weapon"), 2, 2, 2, false)
    end
end

-- A raider body of the soldier AI's kind. Raiders spawn with a GOAP controller, whose brain doesn't run offline; the
-- soldier tree needs a RaidAIController.
local function spawnBody(pc, at)
    local bodyCls = loadClass(CFG.BODY)
    loadClass(CFG.SOLDIER)
    local soldier = lib(CFG.SOLDIER .. ".Default__BotPawnMilitary_C")
    local bodyCdo = lib(CFG.BODY .. ".Default__GOAPNodeBot_Raider_C")
    if not (valid(soldier) and bodyCls and valid(bodyCdo)) then return nil end
    bodyCdo.AIControllerClass = soldier.AIControllerClass
    local body = helper():SpawnAIFromClass(pc, bodyCls, lib(CFG.TREE), { X = at.X, Y = at.Y, Z = at.Z + 100 },
        { Pitch = 0, Yaw = math.random(0, 359), Roll = 0 }, true, pc)
    return valid(body) and body or nil
end

local function startBody(pc, m, at)
    local body = spawnBody(pc, at)
    if not body then return nil end
    m.kit = m.kit or rollKit(m.tier, m.helmet, m.chest, m.backpack)
    equipKit(body, m.kit)
    return { m = m, body = body, startedAt = os.clock() }
end

-- Weapon wear (#86). The game's kit step rolls a gun's condition AND its maximum low and at random (a 1911 at 10/10,
-- full is 100): bodies dropped near-useless guns that cost a fortune to repair. A body's guns and melee weapons get
-- their condition and maximum set to a share of the item's full durability (items.json `dur`): rivals keep their gear
-- well (more so the better their kit), station guards less. Bots don't wear guns by firing (their shots aren't counted).
R.WEAR = { budget = { 0.55, 0.85 }, mid = { 0.7, 0.95 }, geared = { 0.85, 1 }, guard = { 0.35, 0.85 } }
function R.wear(body, band)
    local Items = require("itemdata")
    local slots = { Prim = true, Sec = true, Pistol = true, Melee = true }
    pcall(function()
        body.BotLootItems:ForEach(function(_, e)
            local it = e:get()
            if valid(it) and slots[it.MotherItemGUID:ToString()] then
                local r = Items.get(it.ItemData:ToString())
                if r and r.dur and r.dur > 0 then
                    local c = math.max(1, math.floor(r.dur * (band[1] + math.random() * (band[2] - band[1])) + 0.5))
                    it.MaxCondition, it.Condition = c, c
                end
            end
        end)
    end)
end
R.WEAR.of = function(tier)
    if tier and tier.g then local lo = 0.55 + 0.3 * tier.g return { lo, math.min(1, lo + 0.25) } end
    return R.WEAR[tier and tier.name or ""] or R.WEAR.mid
end

-- Second half: look, wake, arm, once the gun is there. Returns the director entry or nil (not ready / failed).
local function finishBody(b)
    local body, m = b.body, b.m
    if not valid(body) then return false end
    if not valid(body.CurrentWeapon) then
        if os.clock() - b.startedAt < CFG.GUN_WAIT then return nil end
        X.log(("[rivals] %s: no %s arrived, rolling another gun next time"):format(m.name, m.kit.gun[1]))
        m.kit = nil
        R.destroy(body)
        return false
    end
    R.wear(body, R.WEAR.of(m.tier))
    local cat = gearCatalog()
    local mine = comps(body)
    -- Look: kept per member so the same person looks the same every time they materialize. Your hired crew have set
    -- looks (crew.lua headPath/bodyPath): the catalog has already loaded and rooted those meshes.
    if m.headPath and not valid(m.look.head) then m.look.head = lib(m.headPath) end
    if m.bodyPath and not valid(m.look.body) then m.look.body = lib(m.bodyPath) end
    -- A rival's head has to fit under the helmet it rolled (gear.lua fits; a new kit can bring another helmet).
    local helmet = m.kit and m.kit.helmet
    if not m.headPath and valid(m.look.head) and not Gear.fits(helmet, m.look.head:GetFName():ToString()) then
        m.look.head = nil
    end
    if not m.look.head and #cat.heads > 0 then
        local fit = {}
        for _, h in ipairs(cat.heads) do if Gear.fits(helmet, h:GetFName():ToString()) then fit[#fit + 1] = h end end
        m.look.head = pick(#fit > 0 and fit or cat.heads)
    end
    if not m.look.body and #cat.bodies > 0 then m.look.body = pick(cat.bodies) end
    if valid(m.look.head) then body.Mesh:SetSkeletalMesh(m.look.head, false) end
    if mine.CharacterBody0 and valid(m.look.body) then mine.CharacterBody0:SetSkeletalMesh(m.look.body, false) end
    if m.female then X.female.dress(body, true) end
    m.gunName = gunName(body.CurrentWeapon)
    local ctrl = X.arm(body)
    if not ctrl then R.destroy(body) return false end
    ctrl.TeamNumber = CFG.TEAM_BASE + m.crew
    body.Health = m.hp
    -- Player-like senses and aim (ai.lua "rival" profile); the personality comes from the kit, once per member.
    m.personality = m.personality or AI.pickPersonality(AI.power({ pmc = true, gun = m.gunName, helmet = m.helmet,
        chest = m.chest }))
    local e = { bot = body, ctrl = ctrl, home = body:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(1, 4),
        rival = m, mind = AI.mind("rival", m.personality), hand = mine.CharacterBody0, faction = "crew" .. m.crew, voice = m.voice }
    AI.tuneBody(e)
    holdGun(e)
    return e
end

local function navData() return X.navMesh() end -- the registered navmesh (see main.lua navMesh)

local function reachableNear(at, radius)
    local out = {}
    if Out.call(X.navLib(), "K2_GetRandomReachablePointInRadius", S.pc, at, out, radius, navData(), X.queryFilter()) and out.X then
        if not X.offLimits(out) then return out end
        S.offRejects = (S.offRejects or 0) + 1
    end
    return nil
end

local function projected(at, ext)
    local out = {}
    if Out.call(X.navLib(), "K2_ProjectPointToNavigation", S.pc, at, out, navData(), X.queryFilter(),
        ext or { X = 400, Y = 400, Z = 800 }) and out.X then return out end
    return nil
end

-- A random walkable point somewhere in a station. Searching from the station box's centre fails (often empty space,
-- off the navmesh), so it searches around real points inside: airlocks / arrival points and defenders' posts.
local function stationPoint(st, radius)
    local origins = {}
    for _, p in ipairs(st.entries or {}) do origins[#origins + 1] = p end
    for _, p in ipairs(st.posts or {}) do origins[#origins + 1] = p end
    if #origins == 0 then origins[1] = st.box.c end
    -- moderate radius: a big one mostly lands outside the station (the navmesh carries on past its box)
    for _ = 1, 16 do
        local o = projected(origins[math.random(#origins)])
        -- No box check: a station's box is one navmesh volume (the first holding an airlock), which can miss most of
        -- the station (Spaceport); points this close to an airlock or a defender's post are inside it anyway.
        local p = o and reachableNear(o, radius or 3000)
        if p then return p end
    end
end

-- Spreading out --------------------------------------------------------------------------------------------------
-- stationPoint only searches within 30 m of the airlocks and guards' posts, so everyone sent somewhere "random" (guards,
-- crews spawning in, crews picking an area to search) ended up in the same few rooms and fought on arrival. Each station
-- keeps a pool of walkable points that creeps outward instead: every new point is searched for around an earlier one
-- (the furthest from the airlocks and posts of a few), so within seconds of you arriving it covers the whole station.
-- Idle bodies are sent to the pooled point furthest from everyone else.
local function anchorDist(st, p)
    local best = math.huge
    for _, list in ipairs({ st.entries or {}, st.posts or {} }) do
        for _, q in ipairs(list) do best = math.min(best, dist(p, q)) end
    end
    return best
end

local function nearStation(st, p)
    return inBox(st.box, p, CFG.MATERIALIZE_MARGIN) or anchorDist(st, p) <= CFG.SPREAD_REACH
end

local function spotTaken(pool, p)
    for _, q in ipairs(pool) do if dist(p, q) < CFG.SPREAD_GAP then return true end end
end

-- First: the station's loot spawners, AI spawn spots and contract objects, which the level designers spread over every
-- room you're meant to play in (a few hundred in a big station), on the navmesh and in random order.
local function seedSpots(st)
    local pool, seeds = st.spots, {}
    for _, cls in ipairs(CFG.SPREAD_SEEDS) do
        for _, a in ipairs(X.findAll(cls)) do -- shared with main.lua's boarding rescan (same classes, same moment)
            if valid(a) then
                local l = a:K2_GetActorLocation()
                if nearStation(st, l) then seeds[#seeds + 1] = l end
            end
        end
    end
    for i = #seeds, 2, -1 do local j = math.random(i) seeds[i], seeds[j] = seeds[j], seeds[i] end
    local n = 0
    for _, l in ipairs(seeds) do
        if #pool >= CFG.SPREAD_POOL then break end
        local p = projected(l)
        if p and not X.offLimits(p) and not spotTaken(pool, p) then
            table.insert(pool, { X = p.X, Y = p.Y, Z = p.Z })
            n = n + 1
        end
    end
    X.log(("[rivals] %s: spread pool seeded with %d points (%d candidates)"):format(st.name, n, #seeds))
    return n, #seeds
end

local function growSpots(st, n)
    st.spots = st.spots or {}
    local pool = st.spots
    -- (again in 10 s if hardly any landed on the navmesh: the station's may not have streamed in yet)
    if st.box and os.clock() >= (st.seedAt or 0) and not st.seeded then
        local ok, got, of = pcall(seedSpots, st)
        if not ok then X.log("[rivals] seeding " .. st.name .. "'s spread pool failed: " .. tostring(got)) end
        if ok and (got >= 10 or got * 2 >= of or #pool >= CFG.SPREAD_POOL) then st.seeded = true
        else st.seedAt = os.clock() + 10 end
    end
    for _ = 1, n do
        if #pool >= CFG.SPREAD_POOL then return end
        local p
        if #pool < 4 then
            p = stationPoint(st)
        else
            local o, od
            for _ = 1, 3 do
                local q = pool[math.random(#pool)]
                local d = anchorDist(st, q)
                if not od or d > od then o, od = q, d end
            end
            p = reachableNear(o, CFG.SPREAD_STEP)
        end
        if p and nearStation(st, p) and not spotTaken(pool, p) then table.insert(pool, { X = p.X, Y = p.Y, Z = p.Z }) end
    end
end

-- The pooled point furthest from every other living body (and where each is headed), skipping `self` and anyone in
-- `mates` (a rival's own crew: they search together). `visited`: places this one (or its crew) went lately, avoided
-- too. `awayFrom`: a point the result must be at least SPAWN_AWAY from (you, when spawning someone in).
local function spreadPoint(st, self, mates, visited, awayFrom)
    growSpots(st, CFG.SPREAD_GROW)
    local pool = st.spots
    if #pool == 0 then return nil end -- callers fall back to stationPoint
    local others = {}
    for _, o in ipairs(X.raid().bots) do
        if o ~= self and not o.dead and o.bot and valid(o.bot) and not (mates and mates[o]) then
            others[#others + 1] = o.bot:K2_GetActorLocation()
            if o.home then others[#others + 1] = o.home end
        end
    end
    for _, v in ipairs(visited or {}) do others[#others + 1] = v end
    -- bodies spawned but not yet armed aren't in the director's list yet: a rival body or a guard top-up
    for _, job in ipairs(S.building or {}) do
        if job.b and valid(job.b.body) then others[#others + 1] = job.b.body:K2_GetActorLocation() end
    end
    for _, d in ipairs(S.pendingDefenders or {}) do
        if valid(d.body) then others[#others + 1] = d.body:K2_GetActorLocation() end
    end
    local best, bestScore
    for _ = 1, CFG.SPREAD_TRIES do
        local p = pool[math.random(#pool)]
        if not awayFrom or dist(p, awayFrom) >= CFG.SPAWN_AWAY then
            local score = math.huge
            for _, q in ipairs(others) do score = math.min(score, dist(p, q)) end
            if not bestScore or score > bestScore then best, bestScore = p, score end
        end
    end
    if not best then return nil end
    return { X = best.X, Y = best.Y, Z = best.Z }, bestScore
end

-- Idle station guards (the level's own, top-ups and the director's garrison soldiers) don't hold their posts: every
-- GUARD_ROAM seconds each moves on to the part of the station furthest from everyone, and walks about there.
local function roamGuards(st, now)
    growSpots(st, CFG.SPREAD_GROW)
    for _, e in ipairs(X.raid().bots) do
        if not e.faction and not e.crewmate and not e.follow and not e.dead and e.bot and valid(e.bot)
            and not e.fighting and not e.inCombat and not e.investigate and not e.alert then
            if e.roamSt == nil then e.roamSt = nearStation(st, e.bot:K2_GetActorLocation()) and st or false end
            if e.roamSt == st then
                if not e.rehome then
                    e.rehome = now + math.random() * CFG.GUARD_FIRST_ROAM -- not all at once
                elseif now >= e.rehome then
                    local p = spreadPoint(st, e)
                    if p then e.home, e.patrolRadius, e.nextPatrol = p, CFG.ROAM_PATROL, now end
                    e.rehome = now + rnd(CFG.GUARD_ROAM)
                end
            end
        end
    end
end

-- Queue bodies for a crew's living members at the given spots (one spot per member, reused if fewer).
local function materialize(c, spots, mode, members)
    if c.bodies or #spots == 0 then return end
    c.bodies, c.mode = {}, mode
    local living = 0
    for _, m in ipairs(members or c.members) do
        if m.alive and not (mode == "station" and m.boarding) then
            living = living + 1
            -- spread out on floor joined to the spot (a plain offset could put them the far side of a wall)
            local at = spots[(living - 1) % #spots + 1]
            at = reachableNear(at, 150) or at
            local b = startBody(S.pc, m, at)
            if b then table.insert(S.building, { crew = c, b = b, mode = mode }) end
        end
    end
end

-- Out of the director's list for good (the body is put away): its object references go too, as main.lua's reapDead
-- does for the dead. Others can still hold the entry (a soldier's or crewmate's foeEntry), and once the actor is freed
-- any look at it, even IsValid, reads freed memory: an access violation (the crash crossing an airlock after a fight
-- at a station, 2026-11-15). Destroy the body before this.
local function removeEntry(e)
    local bots = X.raid().bots
    for i = #bots, 1, -1 do if bots[i] == e then table.remove(bots, i) end end
    e.bot, e.ctrl, e.hand, e.mesh, e.move = nil, nil, nil, nil, nil
    e.fighting, e.inCombat, e.cover, e.investigate, e.foeEntry, e.holdUntil = false, false, nil, nil, nil, nil
end

-- Back to simulation: remember health, delete the bodies (their guns go with them; a new body rolls a new gun of
-- the same tier, which a player wouldn't notice between visits).
local function dematerialize(c)
    if not c.bodies then return end
    for _, e in ipairs(c.bodies) do
        -- Corpses stay where they fell (lootable); only the living go back into the simulation.
        if valid(e.bot) and (e.bot.Health or 0) > 0 then
            e.rival.hp = e.bot.Health
            R.destroy(e.bot)
        end
        removeEntry(e)
    end
    c.bodies, c.exitAt, c.arrival = nil, nil, nil
end

local function bodiesAlive(c)
    local n = 0
    for _, e in ipairs(c.bodies or {}) do
        if valid(e.bot) and (e.bot.Health or 0) > 0 then
            n = n + 1
            pcall(holdGun, e)
        elseif e.rival.alive then
            e.rival.alive = false
            X.log(("[rivals] %s (%s, %s) was killed"):format(e.rival.name, e.rival.tier.name, e.rival.gunName or "?"))
            -- Rivals stand in for other players: their deaths count for "Kill N Marauders" (tag Human). Bodies only
            -- exist near you and share the soldiers' team, so you're the only one who can kill them.
            pcall(function() S.pc:Client_CheckMissionEvent(FName("Human"), 2) end)
            Kills.rivalDied() -- the kill list files it under the soldier body's kind: moved to Marauder (killstats.lua)
        end
    end
    return n
end

-- Some stay with the ship: a docked crew's ship is never left empty for anyone to take. They're extra people (not drawn
-- from the crew), on the crew's team, rolled like the crew; once rolled they stay for the raid, dead or alive.
local function setWatch(c)
    if c.watch then return end
    local used = {}
    for _, m in ipairs(c.members) do used[m.name] = true end
    c.watch = {}
    for _ = 1, between(CFG.SHIP_WATCH) do
        local m = newMember(used)
        m.crew, m.watch = c.id, true
        table.insert(c.watch, m)
    end
end

-- The airlock a docking crew uses: one per berth (the same berth always gives the same airlock), skipping one your ship
-- is docked at or another crew holds.
local function lockFree(st, l, c)
    if not valid(l.dock) then return false end
    local ships = 0
    pcall(function() l.dock.DockedShips:ForEach(function() ships = ships + 1 end) end)
    if ships > 0 then return false end
    for _, o in ipairs(S.crews or {}) do
        if o ~= c and o.lock == l and o.state == "docked" and o.station == st then return false end
    end
    return true
end

local function pickLock(st, c)
    local locks = st.locks
    if not locks or #locks == 0 then return nil end
    -- the free one used longest ago (never used: oldest), ties at random: crews docking one after another came in
    -- through the same airlock and died in a heap at its door
    local best
    for _, l in ipairs(locks) do
        if lockFree(st, l, c) then
            local t = (l.usedAt or -1e9) + math.random()
            if not best or t < best.t then best = { l = l, t = t } end
        end
    end
    if best then best.l.usedAt = os.clock() return best.l end
end

-- Walking out once the door is open: a point on the station side, past the button.
local function lockExit(l)
    local dx, dy = l.btn.X - l.floor.X, l.btn.Y - l.floor.Y
    local d = math.max(1, math.sqrt(dx * dx + dy * dy))
    local out = { X = l.btn.X + dx / d * 250, Y = l.btn.Y + dy / d * 250, Z = l.btn.Z }
    return projected(out) or reachableNear(l.btn, 400) or l.btn
end

-- A crew coming in: once everyone is built and armed in the chamber (or ARRIVAL_WAIT is up), the door opens and they
-- walk out; it closes again once nobody stands in the chamber.
local function crewArrival(c, now)
    local a = c.arrival
    if not valid(a.lock.dock) then c.arrival = nil return end
    if not a.openedAt or not a.out then
        -- Until the hatch has swung open they stay put: no search areas, no patrol legs.
        for _, e in ipairs(c.bodies or {}) do
            if not e.fighting then e.rehome, e.nextPatrol = now + 60, now + 60 end
        end
    end
    if not a.openedAt then
        local pending = 0
        for _, job in ipairs(S.building or {}) do if job.crew == c then pending = pending + 1 end end
        local have = c.bodies and #c.bodies or 0
        if now - a.started < CFG.ARRIVAL_MIN then return end
        if (pending > 0 or have == 0) and now - a.started < CFG.ARRIVAL_WAIT then return end
        if have == 0 then
            if pending == 0 then c.arrival = nil end
            return
        end
        -- Another crew came in here not long ago: this one waits its turn in the closed chamber.
        local st = c.station
        if st and st.lastArrival and now - st.lastArrival < CFG.ARRIVAL_STAGGER then return end
        local inside = 0
        for _, e in ipairs(c.bodies) do
            if valid(e.bot) and dist(e.bot:K2_GetActorLocation(), a.lock.floor) < 600 then inside = inside + 1 end
        end
        pcall(function() a.lock.dock:StartDoorEvent(true) end)
        a.openedAt = now
        if st then st.lastArrival = now end
        for _, e in ipairs(c.bodies) do
            e.home, e.patrolRadius = a.lock.floor, 100
            pcall(function() e.ctrl:StopMovement() end)
        end
        X.log(("[rivals] %s came in through %s's airlock %s (%d of %d waiting in the chamber, %.0f s)"):format(crewLabel(c),
            c.station.name, a.lock.name, inside, #c.bodies, now - a.started))
    elseif not a.out then
        -- The way is clear the moment the door starts opening: hold them until it has swung open.
        if now - a.openedAt < CFG.DOOR_OPENING then return end
        a.out = now
        local out = lockExit(a.lock)
        for _, e in ipairs(c.bodies or {}) do e.home, e.patrolRadius, e.nextPatrol, e.rehome = out, 300, now, now + 20 end
    elseif now - a.out >= CFG.ARRIVAL_CLOSE then
        local inside = false
        for _, e in ipairs(c.bodies or {}) do
            if valid(e.bot) and (e.bot.Health or 0) > 0 and dist(e.bot:K2_GetActorLocation(), a.lock.floor) < 600 then inside = true end
        end
        if S.foot and valid(S.foot) and dist(S.foot:K2_GetActorLocation(), a.lock.floor) < 600 then inside = true end
        if not inside or now - a.out > 40 then
            pcall(function() a.lock.dock:StartDoorEvent(false) end)
            c.arrival = nil
        end
    end
end

local function stationSpawnSpots(c, st, playerLoc)
    local spots = {}
    local l = c.lock
    local fresh = os.clock() - (c.dockedAt or 0) <= CFG.FRESH_DOCK or c.lateEntry
    if fresh and l and valid(l.dock)
        and not (playerLoc and dist(playerLoc, l.floor) < CFG.LOCK_YOU) then
        -- Just docked: built in their airlock's closed chamber, then the door opens (crewArrival).
        c.arrival = { lock = l, started = os.clock() }
        table.insert(spots, l.floor)
        return spots
    end
    if fresh then
        -- Just docked (or waited aboard for room): they come in through the airlock / arrival point furthest from
        -- everyone already inside.
        local e, far = pick(st.entries), -1
        for _, q in ipairs(st.entries or {}) do
            local near = math.huge
            for _, o in ipairs(X.raid().bots) do
                if not o.dead and o.bot and valid(o.bot) then near = math.min(near, dist(q, o.bot:K2_GetActorLocation())) end
            end
            if playerLoc then near = math.min(near, dist(q, playerLoc)) end
            near = near * (0.8 + 0.4 * math.random())
            if near > far then e, far = q, near end
        end
        local p = projected(e)
        if not p or X.offLimits(p) then p = reachableNear(e, 600) end
        if p then table.insert(spots, p) end
    else
        -- Already inside: somewhere well away from you and from everyone else in the station. Not until the
        -- station's spread pool covers it (it starts as a few points by the airlocks), and not next to anyone: wait
        -- for a clear spot (an empty list: materialize tries again next update), up to SPAWN_WAIT_MAX.
        local now = os.clock()
        c.spawnWait = c.spawnWait or now
        local patient = now - c.spawnWait < CFG.SPAWN_WAIT_MAX
        st.spots = st.spots or {}
        if #st.spots < CFG.SPAWN_POOL_READY then
            growSpots(st, CFG.SPAWN_POOL_BURST)
            if patient and #st.spots < CFG.SPAWN_POOL_READY then return spots end
        end
        local p, clear = spreadPoint(st, nil, nil, nil, playerLoc)
        if p and patient and clear < CFG.SPAWN_CLEAR then return spots end
        if p then
            if not patient then
                X.log(("[rivals] %s: no clear spot in %s after %d s, spawning %.0f m from the nearest body"):format(
                    crewLabel(c), st.name, CFG.SPAWN_WAIT_MAX, clear / 100))
            end
            table.insert(spots, p)
            c.spawnWait = nil
        end
        for _ = 1, 12 do
            if #spots > 0 then break end
            p = stationPoint(st)
            if p and (not playerLoc or dist(p, playerLoc) >= CFG.SPAWN_AWAY) then table.insert(spots, p) break end
        end
    end
    return spots
end

-- Where to come aboard: the breach points, or the dock starts on a ship that has none (the Strike interior).
local function entryPoints(inside)
    local points = {}
    local il = inside:K2_GetActorLocation()
    inside.BreachTransforms:ForEach(function(_, t)
        local tl = t:get().Translation
        table.insert(points, { X = il.X + tl.X, Y = il.Y + tl.Y, Z = il.Z + tl.Z })
    end)
    if #points == 0 then
        for _, name in ipairs({ "ShipDockOnePlayerStart", "ShipDockTwoPlayerStart", "ShipDockThreePlayerStart" }) do
            table.insert(points, inside[name]:K2_GetComponentLocation())
        end
    end
    return points
end

-- Whether a walkable spot joins up with one known to be inside: the runtime navmesh also lays floor outside the
-- interior's walls (in the hull's skin, on top of it), and a breach point is right against the hull, so the nearest
-- floor to one can be out there. Boarders spawned on it stood outside the walls. No path, or one that stops short: no.
local function joined(from, to)
    local path = lib("/Script/NavigationSystem.Default__NavigationSystemV1"):FindPathToLocationSynchronously(S.pc, from, to,
        nil, nil)
    if not valid(path) then return false end
    local last
    path.PathPoints:ForEach(function(_, e) last = e:get() end)
    return last ~= nil and dist(last, to) < CFG.BREACH_JOINED
end

-- A walkable point known to be inside: `from` (you, aboard), else the interior's dock starts.
local function insideAnchor(home, from)
    local ext = { X = 200, Y = 200, Z = 300 }
    if from then
        local p = projected(from, ext)
        if p then return p end
    end
    for _, name in ipairs({ "ShipDockOnePlayerStart", "ShipDockTwoPlayerStart", "ShipDockThreePlayerStart" }) do
        local ok, at = pcall(function() return home[name]:K2_GetComponentLocation() end)
        local p = ok and at and projected(at, ext)
        if p then return p end
    end
end

-- Floor by the breach points that joins up with the inside (`from`: a point known to be inside, e.g. you). With no
-- breach point joined up, floor around the inside point itself, so nobody comes in through the outside of the walls.
local function breachSpots(inside, from)
    local spots = {}
    local home = inside or S.homeInside
    if not valid(home) then return spots end
    local anchor = insideAnchor(home, from)
    for _, at in ipairs(entryPoints(home)) do
        local p = reachableNear(at, 600)
        if p and (not anchor or joined(anchor, p)) then table.insert(spots, p) end
    end
    if #spots == 0 and anchor then
        for _ = 1, 4 do
            local p = reachableNear(anchor, CFG.BREACH_FALLBACK)
            if p then table.insert(spots, p) end
        end
        if #spots > 0 then X.log("[rivals] no breach point joins up with the inside: boarders come in nearer the middle") end
    end
    return spots
end

-- Station defenders ----------------------------------------------------------------------------------------------
-- Live placed NPCs (CFG.PLACED classes) from the spawn hook; dead and destroyed entries are dropped as it goes.
-- (Defined before garrisonStation, which uses it too: defined after, it was a nil global there and the garrison of
-- the first station you boarded failed, 2026-11-14.)
local function hookedPlaced()
    local placed, list, out = {}, NodeBots.list, {}
    for _, c in ipairs(CFG.PLACED) do placed[c] = true end
    for i = #list, 1, -1 do
        local n = list[i]
        if not valid(n.o) or n.placed == false then
            list[i] = list[#list]
            list[#list] = nil
        else
            if n.placed == nil then
                local ok, name = pcall(function() return n.o:GetClass():GetFName():ToString() end)
                n.placed = ok and placed[name] == true and not n.o:GetFName():ToString():find("^Default__")
            end
            if n.placed then out[#out + 1] = n.o end
        end
    end
    return out
end

local function placedDefenders(st)
    local managed = {}
    for _, e in ipairs(X.raid().bots) do
        if e.bot and valid(e.bot) then managed[e.bot:GetAddress()] = true end
    end
    -- From the spawn hook when it's on (the two FindAllOf scans cost ~105 ms in the frame you step into a station and
    -- found the same NPCs: "spawn hook knows 6 ... FindAllOf found 6", 2026-11-15); the scans are the fallback.
    local found
    if NodeBots.hooked then
        found = hookedPlaced()
    else
        found = {}
        for _, cls in ipairs(CFG.PLACED) do
            for _, b in ipairs(FindAllOf(cls) or {}) do found[#found + 1] = b end
        end
    end
    local list = {}
    for _, b in ipairs(found) do
        if valid(b) and not managed[b:GetAddress()] and (b.Health or 0) > 0
            and inBox(st.box, b:K2_GetActorLocation(), 500) and not X.offLimits(b:K2_GetActorLocation()) then
            table.insert(list, b)
        end
    end
    return list
end

-- Wake one placed NPC under the director's soldier AI: a RaidAIController instead of its GOAP one, its own gun
-- held in the body mesh's hand, the station's faction and team.
local function adopt(b)
    if not valid(b) or (b.Health or 0) <= 0 then return nil end
    local soldier = lib(CFG.SOLDIER .. ".Default__BotPawnMilitary_C")
    if not valid(soldier) then pcall(LoadAsset, CFG.SOLDIER) soldier = lib(CFG.SOLDIER .. ".Default__BotPawnMilitary_C") end
    if not valid(soldier) then return nil end
    local old = b.Controller
    if valid(old) then old:UnPossess() end
    b.AIControllerClass = soldier.AIControllerClass
    b:SpawnDefaultController()
    local ctrl = b.Controller
    if not valid(ctrl) then return nil end
    ctrl = X.arm(b, ctrl)
    if not ctrl then return nil end
    R.wear(b, R.WEAR.guard) -- (the level's own guards too: their rolls ran as low as 1/1, #86)
    local boss = b:GetClass():GetFName():ToString():find("Boss", 1, true) ~= nil
    local row = ""
    -- the placed NPC's GOAP controller (a weak pointer) names its brain row, e.g. EliteRaider / AverageRaiderSemi
    pcall(function()
        local gc = b.CachedPlayerController:Get()
        if gc and gc:IsValid() then row = gc.AIActionsRowname:ToString() end
    end)
    local profile = boss and "boss" or (row:find("Elite", 1, true) and "guard" or "soldier")
    local gun = b.CurrentWeapon
    local held = valid(gun) and gunName(gun) or nil
    local e = { bot = b, ctrl = ctrl, home = b:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(2, 8),
        patrolRadius = CFG.POST_RADIUS, placed = true, hand = comps(b).CharacterBody0,
        mind = AI.mind(profile, AI.pickPersonality(AI.power({ gun = held }) + (boss and 2 or 0))) }
    -- what the level gave it (kit rows, and how it looks before female.lua dresses it): top-ups copy this
    local okw, rows = pcall(wornRows, b)
    e.rows = okw and rows or {}
    e.look = { head = b.Mesh.SkeletalMesh, gear = {} }
    local parts = comps(b)
    for _, key in ipairs(CFG.GEAR_SLOTS) do if parts[key] then e.look.gear[key] = parts[key].SkeletalMesh end end
    local female = math.random() < CFG.FEMALE
    e.voice = X.voice.pick(female)
    if female then pcall(X.female.dress, b, true) end
    AI.tuneBody(e)
    pcall(holdGun, e)
    local ok, carried = pcall(rollCarried, b)
    e.carried = ok and carried or { "roll failed: " .. tostring(carried) }
    table.insert(X.raid().bots, e)
    return e, profile, row
end

-- First visit to a station: queue its own NPCs for adoption (one per update), then top it up to MIN_DEFENDERS.
local function garrisonStation(pc, st)
    local list = placedDefenders(st)
    X.log(("[rivals] %s: %d placed NPC(s) to adopt (%s)"):format(st.name, #list,
        NodeBots.hooked and "from the spawn hook" or "from object scans"))
    S.adoptQueue = S.adoptQueue or {}
    for _, b in ipairs(list) do table.insert(S.adoptQueue, { bot = b, st = st }) end
    -- MIN_DEFENDERS is for a mid-size station: a small one gets as few as half, a big one up to DEFENDERS_MAX_SCALE x.
    local scale = math.max(0.5, math.min(CFG.DEFENDERS_MAX_SCALE, (st.area or CFG.STATION_AREA_MID) / CFG.STATION_AREA_MID))
    local extra = math.max(0, math.floor(CFG.MIN_DEFENDERS * scale + 0.5) - #list)
    if CFG.AWAKE_MAX > 0 then
        local room = math.max(0, CFG.AWAKE_MAX - R.awakeCount() - #list)
        if room < extra then
            X.log(("[rivals] %s: %d more guards wanted, room for %d (AWAKE_MAX)"):format(st.name, extra, room))
            extra = room
        end
    end
    if #list > 0 then
        X.log(("[rivals] %s: %d of its own defenders%s"):format(st.name, #list,
            extra > 0 and (", plus %d more like them"):format(extra) or ""))
        if extra > 0 then
            S.topUps = S.topUps or {}
            table.insert(S.topUps, { st = st, left = extra, templates = {}, guns = {} })
        end
    else
        X.log(("[rivals] %s: none of its own defenders, %d soldiers"):format(st.name, extra))
        if extra > 0 and X.garrison then X.garrison(pc, st.box, st.name, extra) end
    end
end

-- Top-ups: a raider body like one of the station's own, with a kit of its own. Two steps, like rival bodies: spawn the body
-- and roll the kit, then on a later update, once the gun has arrived, arm it.
local function defenderSpot(st)
    local you = valid(S.foot) and S.foot:K2_GetActorLocation() or nil
    -- the pool starts as a few points by the airlocks: grow it first, so top-ups spread over the whole station
    if #(st.spots or {}) < CFG.SPAWN_POOL_READY then growSpots(st, CFG.SPAWN_POOL_BURST) end
    local spread = spreadPoint(st, nil, nil, nil, you)
    if spread then return spread end
    local found, near = 0, 0
    for _ = 1, 8 do
        local p = stationPoint(st)
        if p then
            found = found + 1
            if not S.foot or not valid(S.foot) or dist(p, S.foot:K2_GetActorLocation()) >= CFG.SPAWN_AWAY then return p end
            near = near + 1
        end
    end
    X.log(("[rivals] %s: no defender spot (%d points found, %d too close to you; %d entries, %d posts; %d off limits so far)")
        :format(st.name, found, near, #(st.entries or {}), #(st.posts or {}), S.offRejects or 0))
end

-- A top-up's kit: the template guard's own helmet, chest armour, bag and sidearm rows (so it looks like them), and a gun
-- one of the station's own guards carries (the station's gear pool, not your level). A template whose rows couldn't be
-- read falls back to a rolled kit.
local function topUpKit(job, tpl)
    local r = tpl.rows or {}
    if not (r.gun or r.pistol or r.helmet or r.chest or r.bag) then
        local tier = CFG.TIERS[2]
        return rollKit(tier, math.random() < tier.helmet, math.random() < tier.chest, math.random() < tier.backpack)
    end
    local gun = #job.guns > 0 and job.guns[math.random(#job.guns)] or r.gun
    return { gun = gun and (priceOf(gun) or { gun, 0 }) or nil, pistol = r.pistol, helmet = r.helmet, chest = r.chest,
        bag = r.bag, stacks = math.random(CFG.AMMO_STACKS[1], CFG.AMMO_STACKS[2]), meds = math.random(CFG.MEDS[1], CFG.MEDS[2]) }
end

local function startTopUp(pc, job)
    local tpl = job.templates[math.random(#job.templates)]
    local at = defenderSpot(job.st)
    if not at then return "no free spot in the station" end
    local body = spawnBody(pc, at)
    if not body then return "spawn refused" end
    -- the template's head (the raider's Mesh) and outfit; its gear slots come from the kit, and once that has arrived
    -- finishTopUp puts the template's own meshes on them (a placed guard can wear a mesh its rows don't name).
    local female = math.random() < CFG.FEMALE
    if valid(tpl.head) then pcall(function() body.Mesh:SetSkeletalMesh(tpl.head, false) end) end
    local outfit, suit = comps(body).CharacterBody0, tpl.gear.CharacterBody0
    if outfit and valid(suit) then pcall(function() outfit:SetSkeletalMesh(suit, false) end) end
    body.Health = tpl.maxHp or body.Health
    S.pendingDefenders = S.pendingDefenders or {}
    table.insert(S.pendingDefenders, { body = body, st = job.st, profile = tpl.profile, startedAt = os.clock(), female = female,
        look = tpl.gear })
    equipKit(body, topUpKit(job, tpl))
end

local function finishTopUp(p)
    local body = p.body
    if not valid(body) then return true end
    if not valid(body.CurrentWeapon) and os.clock() - p.startedAt < CFG.GUN_WAIT then return false end
    local name = valid(body.CurrentWeapon) and gunName(body.CurrentWeapon) or "no gun"
    local parts = comps(body)
    for key, mesh in pairs(p.look or {}) do
        if key ~= "CharacterBody0" and parts[key] and valid(mesh) then
            pcall(function() parts[key]:SetSkeletalMesh(mesh, false) end)
        end
    end
    if p.female then X.female.dress(body, true) end
    local ctrl = X.arm(body)
    if not ctrl then R.destroy(body) return true end
    R.wear(body, R.WEAR.guard)
    local e = { bot = body, ctrl = ctrl, home = body:K2_GetActorLocation(), nextPatrol = os.clock() + math.random(2, 8),
        patrolRadius = CFG.POST_RADIUS, placed = true, hand = comps(body).CharacterBody0, voice = X.voice.pick(p.female),
        mind = AI.mind(p.profile or "soldier", AI.pickPersonality(AI.power({ gun = name }))) }
    AI.tuneBody(e)
    pcall(holdGun, e)
    local ok, carried = pcall(rollCarried, body)
    table.insert(X.raid().bots, e)
    S.adopted = S.adopted or {}
    table.insert(S.adopted, e)
    X.log(("[rivals] %s defender up: copy with %s, carrying %s"):format(p.st.name, name,
        ok and table.concat(carried, ", ") or ("roll failed: " .. tostring(carried))))
    return true
end

-- One step per update: finish a pending top-up, else start the next one once the station's own are all adopted.
local function topUpStep(pc)
    local pend = S.pendingDefenders
    if pend and #pend > 0 then
        local ok, done = pcall(finishTopUp, pend[1])
        if not ok then X.log("[rivals] defender top-up failed: " .. tostring(done)) end
        if not ok or done then table.remove(pend, 1) end
        return
    end
    if S.adoptQueue and #S.adoptQueue > 0 then return end
    local jobs = S.topUps
    if not jobs or #jobs == 0 then return end
    local job = jobs[1]
    if #job.templates == 0 then
        X.log("[rivals] " .. job.st.name .. ": no defenders of its own came up; soldiers instead")
        if X.garrison then pcall(X.garrison, pc, job.st.box, job.st.name, job.left) end
        table.remove(jobs, 1)
        return
    end
    local ok, err = pcall(startTopUp, pc, job)
    if not ok or err then X.log("[rivals] defender top-up failed: " .. tostring(err)) end
    job.left = job.left - 1
    if job.left <= 0 then table.remove(jobs, 1) end
end

local function adoptQueued()
    local q = S.adoptQueue
    if not q or #q == 0 then return end
    local job = table.remove(q, 1)
    local ok, e, profile, row = pcall(adopt, job.bot)
    if ok and e then
        S.adopted = S.adopted or {}
        table.insert(S.adopted, e)
        job.st.posts = job.st.posts or {}
        table.insert(job.st.posts, e.home)
        local b = e.bot
        local look = e.look or { head = b.Mesh.SkeletalMesh, gear = {} }
        local tpl = { head = look.head, gear = look.gear, rows = e.rows, profile = profile, maxHp = b.Health }
        for _, t in ipairs(S.topUps or {}) do
            if t.st == job.st then
                table.insert(t.templates, tpl)
                if e.rows and e.rows.gun then table.insert(t.guns, e.rows.gun) end
            end
        end
        X.log(("[rivals] %s defender up: %s (%s%s, %s), carrying %s"):format(job.st.name, e.bot:GetClass():GetFName():ToString()
            :gsub("_C$", ""), profile, row ~= "" and ("/" .. row) or "", AI.describe(e), table.concat(e.carried or {}, ", ")))
    elseif not ok then
        X.log("[rivals] adopting a defender failed: " .. tostring(e))
    end
end

-- Strays: the garrison sweep runs once, on your first step into a station, and only takes NPCs inside its box. A placed
-- NPC outside the box (Spaceport's box misses most of it) or one that streams in later keeps its GOAP controller, which
-- does nothing offline: it stands there, gun up, until shot. Every STRAY_EVERY s, any living, unmanaged placed NPC in the
-- box or near you is queued for adoption, once it has gone unmanaged for two sweeps in a row (a body the director is
-- still building is unmanaged for a few seconds too; GUN_WAIT is well under a sweep).
-- Each sweep scans one of the PLACED classes in turn: a FindAllOf walks every object in the game, ~50 ms each on a
-- space map, and both at once were a 100+ ms hitch every 8 s (profile.txt, Moon Base, 2026-11-14).
local function sweepStrays(st, now)
    if now < (S.nextStraySweep or 0) or (S.adoptQueue and #S.adoptQueue > 0) then return end
    S.nextStraySweep = now + CFG.STRAY_EVERY
    local managed = {}
    for _, e in ipairs(X.raid().bots) do
        if e.bot and valid(e.bot) then managed[e.bot:GetAddress()] = true end
    end
    for _, job in ipairs(S.building or {}) do
        if job.b and valid(job.b.body) then managed[job.b.body:GetAddress()] = true end
    end
    for _, p in ipairs(S.pendingDefenders or {}) do
        if valid(p.body) then managed[p.body:GetAddress()] = true end
    end
    local foot = valid(S.foot) and S.foot:K2_GetActorLocation() or nil
    local seen, found = {}, 0
    -- Without the spawn hook: one of the PLACED classes per sweep, by FindAllOf (both at once was a 100+ ms hitch).
    local cls, bots = "hooked", nil
    if NodeBots.hooked then
        bots = hookedPlaced()
    else
        S.strayClass = (S.strayClass or 0) % #CFG.PLACED + 1
        cls = CFG.PLACED[S.strayClass]
        bots = FindAllOf(cls) or {}
    end
    S.strays = S.strays or {}
    local before = S.strays[cls] or {}
    do
        for _, b in ipairs(bots) do
            if valid(b) and (b.Health or 0) > 0 and not managed[b:GetAddress()] then
                local at = b:K2_GetActorLocation()
                if (inBox(st.box, at, 500) or (foot and dist(at, foot) <= CFG.STRAY_RANGE)) and not X.offLimits(at) then
                    local key = b:GetAddress()
                    seen[key] = true
                    if before[key] then
                        table.insert(S.adoptQueue, { bot = b, st = st })
                        found = found + 1
                    end
                end
            end
        end
    end
    S.strays[cls] = seen
    if found > 0 then X.log(("[rivals] %s: %d stray NPC(s) the garrison missed, adopting"):format(st.name, found)) end
end

-- Your ship, flown and undocked, with its movement component not ticking: it takes thrust (CurrentThrust 1) and goes
-- nowhere, though nothing looks disabled. Seen once, after undocking from Penal Colony on Space_Beta (2026-11-14);
-- turning the tick back on from the bridge freed it at once. Two seconds' grace so the game's own undock can finish.
local function keepShipMoving(now)
    local ship = S.playerShip
    if not (valid(ship) and valid(S.pc) and valid(S.pc.Pawn) and S.pc.Pawn:GetAddress() == ship:GetAddress()) then
        S.shipStillSince = nil return
    end
    local cm = ship.CharacterMovement
    if not valid(cm) or ship.bDocked or cm:IsComponentTickEnabled() then S.shipStillSince = nil return end
    S.shipStillSince = S.shipStillSince or now
    if now - S.shipStillSince < 2 then return end
    S.shipStillSince = nil
    cm:SetComponentTickEnabled(true)
    X.log("[rivals] your ship's movement had stopped ticking after undocking: turned it back on")
end

-- Defenders' guns: equipping puts the gun on the head mesh (invisible); keep it in the body's hand (like rivals).
local function keepDefendersArmed()
    for i = #(S.adopted or {}), 1, -1 do
        local e = S.adopted[i]
        if e.dead or not e.bot then table.remove(S.adopted, i) else pcall(holdGun, e) end
    end
end

-- Breaching pods -------------------------------------------------------------------------------------------------
-- Live, a boarder launches from their frigate in a drop pod (Ship_DropPod_Pawn_C), flies it into your hull, and the
-- breach ability drives it in and moves them inside. That pod only works with a player controller: spawned for an AI
-- it crashes (a timer, delayforLocalSPawnAbility = 0.5 s after spawn, casts its controller to a player controller and
-- calls through the result unchecked; with no controller at all it skips). So each pod is spawned, has its AI
-- controller removed at once, and is flown here frame by frame; on contact it's gone at once, as if it slammed through
-- the hull, and you get the game's breach alarm (SpaceshipInside:StartBreachedEvent) and notice (ClientBeenBreached).
-- Rival ships get the same pods, without the alarm.
local function holdOff(shipLoc, target)
    local dx, dy = shipLoc.X - target.X, shipLoc.Y - target.Y
    local n = math.max(1, math.sqrt(dx * dx + dy * dy))
    return { X = target.X + dx / n * CFG.HOLD_OFF, Y = target.Y + dy / n * CFG.HOLD_OFF, Z = target.Z + 300 }
end

-- A hull's size: its colliding bounds' larger flat half-extent (the frigates' capsules are only 50-100 across; the
-- hulls run 500-1200), read once per ship. o = a crew, or nil for your ship.
local function boundsRadius(ship)
    local r = 900
    pcall(function()
        local o, e = {}, {}
        Out.call(ship, "GetActorBounds", true, o, e, false)
        if e.X and e.Y then r = math.max(400, math.min(2000, math.max(e.X, e.Y) * 0.85)) end
    end)
    return r
end
local function hullRadius(o)
    if not o then
        if not S.playerRadius and valid(S.playerShip) then S.playerRadius = boundsRadius(S.playerShip) end
        return S.playerRadius or 1200
    end
    if o.hullR and o.hullFor == o.ship then return o.hullR end
    if o.ship and valid(o.ship) then o.hullR, o.hullFor = boundsRadius(o.ship), o.ship return o.hullR end
    return 900
end

-- Every flying ship's place, read once per director update (separation checks all of them for every fighter).
local function shipsFlying(now)
    if S.posAt == now and S.pos then return S.pos end
    local list = {}
    for _, o in ipairs(S.crews) do
        if o.state ~= "docked" and o.state ~= "gone" and o.state ~= "waiting" and shipOk(o) then
            list[#list + 1] = { c = o, ship = o.ship, at = o.ship:K2_GetActorLocation(), r = hullRadius(o) }
        end
    end
    if valid(S.playerShip) then list[#list + 1] = { ship = S.playerShip, at = S.playerShip:K2_GetActorLocation(), r = hullRadius(nil) } end
    S.pos, S.posAt = list, now
    return list
end

-- About to fly into another ship (closest approach in the next SEP_LOOK seconds, at the two ships' velocities, closer
-- than SEP_CLEAR between the hulls): a point to break away to, held SEP_HOLD seconds. Away from it, and off to the side
-- of our own heading so the two don't back apart and close again.
local function separation(c, here, now)
    if c.sep and now < c.sep.untilT then return c.sep.at end
    c.sep = nil
    local v = c.ship:GetVelocity()
    local myR = hullRadius(c)
    local worst, wgap
    for _, p in ipairs(shipsFlying(now)) do
        if p.c ~= c and valid(p.ship) then
            local rx, ry, rz = here.X - p.at.X, here.Y - p.at.Y, here.Z - p.at.Z
            local d = math.sqrt(rx * rx + ry * ry + rz * rz)
            if d - myR - p.r < CFG.SEP_CLEAR + 6000 then
                local ov = p.ship:GetVelocity()
                local wx, wy, wz = v.X - ov.X, v.Y - ov.Y, v.Z - ov.Z
                local ww = wx * wx + wy * wy + wz * wz
                local t = ww > 1 and math.max(0, math.min(CFG.SEP_LOOK, -(rx * wx + ry * wy + rz * wz) / ww)) or 0
                local cx, cy, cz = rx + wx * t, ry + wy * t, rz + wz * t
                local gap = math.sqrt(cx * cx + cy * cy + cz * cz) - myR - p.r
                if gap < CFG.SEP_CLEAR and (not wgap or gap < wgap) then worst, wgap = { x = rx, y = ry, z = rz, d = d }, gap end
            end
        end
    end
    if not worst then return nil end
    local n = math.max(1, worst.d)
    local ax, ay, az = worst.x / n, worst.y / n, worst.z / n
    local sp = math.max(1, math.sqrt(v.X * v.X + v.Y * v.Y))
    local sx, sy = -v.Y / sp, v.X / sp
    if sx * ax + sy * ay < 0 then sx, sy = -sx, -sy end
    local dx, dy, dz = ax + sx * 0.8, ay + sy * 0.8, az + (az >= 0 and 0.5 or -0.5)
    local m = math.max(1e-3, math.sqrt(dx * dx + dy * dy + dz * dz))
    c.sep = { at = { X = here.X + dx / m * 4000, Y = here.Y + dy / m * 4000, Z = here.Z + dz / m * 4000 }, untilT = now + CFG.SEP_HOLD }
    c.man = { kind = "break", untilT = now + CFG.SEP_HOLD, at = c.sep.at, phase = "out" }
    S.seps = (S.seps or 0) + 1
    return c.sep.at
end

local function weighted(w)
    local total = 0
    for _, v in pairs(w) do total = total + v end
    local r = math.random() * total
    for k, v in pairs(w) do
        r = r - v
        if r <= 0 then return k end
    end
    return next(w)
end

-- The next manoeuvre against the target: after a pass, out the far side (or a break); hit hard, maybe break away;
-- otherwise by the crew's style. Tailing only on a target flying away from us.
local function nextManoeuvre(c, tl, bx, by, now, last, tgt)
    c.style = c.style or weighted({ jouster = 1, brawler = 1, sniper = 1 })
    if last == "pass" then return math.random() < 0.75 and "extend" or "break" end
    if c.hurtAt and now - c.hurtAt < 1.5 and last ~= "break" and math.random() < CFG.BREAK_WHEN_HIT then return "break" end
    local w = {}
    for k, v in pairs(CFG.STYLES[c.style] or CFG.STYLES.jouster) do w[k] = v end
    local away = false
    pcall(function()
        local f = tgt:GetActorForwardVector()
        away = f.X * bx + f.Y * by > 0.3
    end)
    if not away then w.tail = nil end
    if last == "circle" or last == "standoff" then w[last] = (w[last] or 0) * 0.3 end
    return weighted(w)
end

-- Where a ship in a fight flies now, and whether its nose is on the target (fireControl aims and fires the bow gun
-- for phase "in"). The pass works as the old attack run, but keeps its side offset all the way in (re-aiming at the
-- target each update used to drop it and fly straight at the hull) and swings out on the far side (it used to come
-- back through the target).
local function manoeuvre(c, here, tgt, tl, now)
    local dx, dy, dz = tl.X - here.X, tl.Y - here.Y, tl.Z - here.Z
    local d = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
    local h = math.max(1, math.sqrt(dx * dx + dy * dy))
    local bx, by = dx / h, dy / h -- bearing to the target, flat
    local px, py = -by, bx        -- and square to it
    local myR, tR = hullRadius(c), hullRadius(c.target and c.target.crew)
    local m = c.man
    local done = not m or now > m.untilT or (m.at and m.fixed and dist(here, m.at) < 1200)
    if m and m.kind == "pass" and not done then
        -- past the target (it's behind us) and clear: the pass is over
        local f = c.ship:GetActorForwardVector()
        if (f.X * dx + f.Y * dy + f.Z * dz) / d < -0.2 and d > myR + tR + 800 then done = true end
    end
    if done then
        local kind = nextManoeuvre(c, tl, bx, by, now, m and m.kind, tgt)
        m = { kind = kind, t0 = now, sgn = math.random() < 0.5 and -1 or 1 }
        if kind == "pass" then
            m.side = m.sgn * math.max(CFG.RUN_OFFSET, myR + tR + CFG.PASS_CLEAR)
            m.lift = (math.random() * 2 - 1) * CFG.PASS_LIFT
            m.untilT, m.phase = now + 20, "in"
        elseif kind == "extend" then
            -- on out the side we're on now, swinging off the line
            local a = math.atan(-by, -bx) + math.rad(math.random(-60, 60))
            local r = rnd(CFG.RUN_EXTEND)
            m.at = { X = tl.X + math.cos(a) * r, Y = tl.Y + math.sin(a) * r, Z = tl.Z + math.random(-1200, 1200) }
            m.fixed, m.untilT, m.phase = true, now + 15, "out"
        elseif kind == "break" then
            local r = rnd(CFG.BREAK_DIST)
            local ux, uy, uz = px * m.sgn - bx * 0.4, py * m.sgn - by * 0.4, (math.random() < 0.5 and -0.6 or 0.6)
            local n = math.sqrt(ux * ux + uy * uy + uz * uz)
            m.at = { X = here.X + ux / n * r, Y = here.Y + uy / n * r, Z = here.Z + uz / n * r }
            m.fixed, m.untilT, m.phase = true, now + rnd(CFG.BREAK_SECONDS), "out"
        elseif kind == "circle" then
            m.r = rnd(CFG.CIRCLE_R) + myR + tR
            m.z = math.random(-400, 400)
            m.untilT, m.phase = now + rnd(CFG.CIRCLE_SECONDS), "in"
        elseif kind == "standoff" then
            m.r = rnd(CFG.STANDOFF_R) + myR + tR
            m.z = math.random(-300, 300)
            m.dur = rnd(CFG.STANDOFF_SECONDS)
            m.untilT, m.phase = now + m.dur, "in"
        else -- tail
            m.untilT, m.phase = now + rnd(CFG.TAIL_SECONDS), "in"
        end
        c.man = m
    end
    local at, accept = m.at, 600
    if m.kind == "pass" then
        if not m.locked and d < CFG.RUN_OVERSHOOT * 1.2 + myR + tR then
            m.locked = { X = tl.X + bx * CFG.RUN_OVERSHOOT + px * m.side, Y = tl.Y + by * CFG.RUN_OVERSHOOT + py * m.side,
                Z = tl.Z + m.lift }
        end
        at = m.locked or { X = tl.X + bx * CFG.RUN_OVERSHOOT + px * m.side, Y = tl.Y + by * CFG.RUN_OVERSHOOT + py * m.side,
            Z = tl.Z + m.lift }
        if m.locked and dist(here, m.locked) < 1200 then m.untilT = now end
    elseif m.kind == "circle" then
        local a = math.atan(here.Y - tl.Y, here.X - tl.X) + m.sgn * math.rad(CFG.CIRCLE_LEAD)
        at, accept = { X = tl.X + math.cos(a) * m.r, Y = tl.Y + math.sin(a) * m.r, Z = tl.Z + m.z }, 300
    elseif m.kind == "standoff" then
        -- close to short range on our side of it, nose on, and hold there drifting slowly sideways
        local drift = m.sgn * CFG.STANDOFF_DRIFT * math.min(1, (now - m.t0) / m.dur)
        at, accept = { X = tl.X - bx * m.r + px * drift, Y = tl.Y - by * m.r + py * drift, Z = tl.Z + m.z }, 400
    elseif m.kind == "tail" then
        local f = { X = bx, Y = by, Z = 0 }
        pcall(function() f = tgt:GetActorForwardVector() end)
        local back = CFG.TAIL_BACK + myR + tR
        at, accept = { X = tl.X - f.X * back - f.Y * 700 * m.sgn, Y = tl.Y - f.Y * back + f.X * 700 * m.sgn,
            Z = tl.Z - f.Z * back + 300 }, 300
    end
    local sep = separation(c, here, now)
    if sep then at, accept, m = sep, 600, c.man end
    c.runPhase = m.phase
    return at, accept
end

local function launchPods(c, party, ship)
    local cls = loadClass(CFG.POD)
    if not (cls and shipOk(c)) then return end
    local from = c.ship:K2_GetActorLocation()
    local n = 0
    for _, m in ipairs(party.members) do
        if m.alive then
            local at = { X = from.X + math.random(-200, 200), Y = from.Y + math.random(-200, 200), Z = from.Z - 250 }
            local pod = helper():SpawnAIFromClass(S.pc, cls, lib(CFG.SHIP_TREE), at, { Pitch = 0, Yaw = 0, Roll = 0 },
                true, S.pc)
            if valid(pod) then
                -- In the same call, before its 0.5 s timer: no controller, or the game crashes.
                local ctrl = pod.Controller
                if valid(ctrl) then ctrl:UnPossess() R.destroy(ctrl) end
                pod:SetActorHiddenInGame(false)
                pod:SetActorEnableCollision(false)
                pcall(function() pod:SetBoostingVisuals(true) end)
                table.insert(S.pods, { pod = pod, crew = party, member = m, ship = ship, launchedAt = os.clock(),
                    wobble = math.random() * 6.28, along = rnd(CFG.POD_ALONG) })
                n = n + 1
            end
        end
    end
    if party.victim then
        X.log(("[rivals] %s launched %d pod(s) at the %s"):format(crewLabel(c), n, party.victim.shipName))
    else
        say(S.pc, ("The %s launched %d breaching pod%s at you!"):format(c.shipName, n, n == 1 and "" or "s"))
    end
end

local function podHit(p, ship)
    local pod = p.pod
    p.hitAt = os.clock()
    local at = pod:K2_GetActorLocation()
    R.destroy(pod)
    if p.crew.victim then
        X.log(("[rivals] %s's pod hit the %s"):format(p.member.name, p.crew.victim.shipName))
        return
    end
    if not S.alarmAt or p.hitAt - S.alarmAt > 10 then
        S.alarmAt = p.hitAt
        pcall(function() S.homeInside:StartBreachedEvent() end)
        pcall(function() S.pc:ClientBeenBreached() end)
    end
    local loc, f, r = ship:K2_GetActorLocation(), ship:GetActorForwardVector(), ship:GetActorRightVector()
    local dx, dy, dz = at.X - loc.X, at.Y - loc.Y, at.Z - loc.Z
    X.log(("[rivals] %s's pod hit your hull, %.0f ahead of its centre, %.0f to the side"):format(p.member.name,
        dx * f.X + dy * f.Y + dz * f.Z, dx * r.X + dy * r.Y + dz * r.Z))
end

-- Where a pod is heading: the point on the hull's side nearest a spot out abeam, on whichever side the pod came from.
-- Aiming at the point nearest the pod itself put pods launched from behind into the engines.
local function podAim(p, ship, here)
    local loc, f, r = ship:K2_GetActorLocation(), ship:GetActorForwardVector(), ship:GetActorRightVector()
    p.side = p.side or ((here.X - loc.X) * r.X + (here.Y - loc.Y) * r.Y + (here.Z - loc.Z) * r.Z < 0 and -1 or 1)
    local out = CFG.POD_SIDE * p.side
    local hit = {}
    ship.Mesh:GetClosestPointOnCollision({ X = loc.X + f.X * p.along + r.X * out, Y = loc.Y + f.Y * p.along + r.Y * out,
        Z = loc.Z + f.Z * p.along + r.Z * out }, hit, FName("None"))
    return hit.X and hit or loc
end

-- Every frame: fly pods in flight. A pod that hit stays listed, with no actor, until its rider has cut through.
local function flyPods(dt)
    local now = os.clock()
    for i = #S.pods, 1, -1 do
        local p = S.pods[i]
        local pod = p.pod
        local ship = p.ship
        if p.hitAt then
            if p.boarded or now - p.hitAt > CFG.POD_TIMEOUT then table.remove(S.pods, i) end
        elseif not valid(pod) then
            table.remove(S.pods, i)
        elseif not valid(ship) then
            R.destroy(pod)
            table.remove(S.pods, i)
        else
            local here = pod:K2_GetActorLocation()
            local hit = podAim(p, ship, here)
            local dx, dy, dz = hit.X - here.X, hit.Y - here.Y, hit.Z - here.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            local age = now - p.launchedAt
            local speed = CFG.POD_SPEED[1] + (CFG.POD_SPEED[2] - CFG.POD_SPEED[1]) * math.min(1, age / CFG.POD_ACCEL)
            local step = speed * dt
            if d <= math.max(40, step) or age > CFG.POD_TIMEOUT then
                Out.call(pod, "K2_SetActorLocation", hit, false, {}, true)
                podHit(p, ship)
            else
                dx, dy, dz = dx / d, dy / d, dz / d
                -- A little corkscrew while far out, straight in for the last stretch, like a piloted pod.
                local w = math.min(1, d / 3000) * 0.25
                p.wobble = p.wobble + dt * 2.5
                local sw = math.sin(p.wobble) * w
                local at = { X = here.X + (dx - dy * sw) * step, Y = here.Y + (dy + dx * sw) * step,
                    Z = here.Z + (dz + math.cos(p.wobble) * w * 0.5) * step }
                local rot = { Pitch = math.deg(math.asin(math.max(-1, math.min(1, dz)))),
                    Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
                Out.call(pod, "K2_SetActorLocationAndRotation", at, rot, false, {}, true)
            end
        end
    end
end

-- Ship combat ----------------------------------------------------------------------------------------------------
-- A crew's target is your ship or another crew's ship (c.target = { player = true } or { crew = o }).
local function targetShip(t)
    if not t then return nil end
    if t.player then return valid(S.playerShip) and (S.playerShip.MainHullHealth or 0) > 0 and S.playerShip or nil end
    local o = t.crew
    if o.state ~= "gone" and shipOk(o) then return o.ship end
end

local function attackersOn(t)
    local n = 0
    for _, o in ipairs(S.crews) do
        if o.state == "attack" and o.target and ((t.player and o.target.player) or (t.crew and o.target.crew == t.crew)) then
            n = n + 1
        end
    end
    return n
end

-- Members still on the ship (flying and shooting it) vs off boarding someone.
local function crewOnShip(c)
    for _, m in ipairs(c.members) do if m.alive and not m.boarding then return true end end
    return false
end

local function engage(c, t, now, why)
    c.state, c.target, c.attackStart = "attack", t, now
    c.engageUntil = now + rnd(CFG.ENGAGE_MAX)
    c.orbitAngle, c.orbitDir = math.random() * 2 * math.pi, math.random() < 0.5 and -1 or 1
    c.orbitR = rnd(CFG.ORBIT)
    c.boardPlan, c.boardAt, c.boarded, c.man, c.sep = nil, now + rnd(CFG.BREACH_AFTER), nil, nil, nil
    local alive = 0
    for _, m in ipairs(c.members) do if m.alive then alive = alive + 1 end end
    local all, one = CFG.RIVAL_BOARD_ALL, CFG.RIVAL_BOARD_ONE
    if t.player then all, one = CFG.BOARD_ALL, CFG.BOARD_ONE end
    local r = math.random()
    if r < all then c.boardPlan = "all"
    elseif alive >= 2 and r < all + one then c.boardPlan = "one" end
    if t.player then say(S.pc, ("Contact: the %s is coming about to attack you"):format(c.shipName)) end
    X.log(("[rivals] %s%s engages %s (%s%s, gunnery %.2f)"):format(crewLabel(c), c.diehard and " (to the death)" or "",
        t.player and "your ship" or ("the " .. t.crew.shipName), why, c.boardPlan and (", boarding: " .. c.boardPlan) or "",
        c.gunnery or 0))
end

local function disengage(c, now, why)
    c.fireAt, c.target = nil, nil
    if shipOk(c) then setShipEnemy(c, nil) end
    c.state = "travel"
    c.station = c.station or chooseStation(c)
    X.log(("[rivals] %s breaks off (%s, %d bursts fired)"):format(crewLabel(c), why, c.bursts or 0))
    c.bursts = 0
end

-- Size up ships in sight; returns true if the crew starts a fight.
local function lookForFights(c, shipLoc, now, hurt)
    c.seen = c.seen or {}
    local cands = {}
    if valid(S.playerShip) and (S.playerShip.MainHullHealth or 0) > 0 then
        local d = dist(shipLoc, S.playerShip:K2_GetActorLocation())
        if d < CFG.SHIP_SIGHT then table.insert(cands, { key = "player", t = { player = true }, d = d }) end
    end
    for _, o in ipairs(S.crews) do
        if o ~= c and o.state ~= "docked" and o.state ~= "gone" and o.state ~= "waiting" and shipOk(o) then
            local d = dist(shipLoc, o.ship:K2_GetActorLocation())
            if d < CFG.SHIP_SIGHT then table.insert(cands, { key = o, t = { crew = o }, d = d }) end
        end
    end
    -- Shot at: fight back against whoever did it. A crew that fired at us is known (fireControl); anything else
    -- (you, mines) is taken to be the nearest ship in gun range that isn't docked, you or a rival alike.
    if hurt then
        if c.shotBy and now - (c.shotAt or 0) < 5 and c.shotBy.state ~= "gone" and shipOk(c.shotBy) then
            engage(c, { crew = c.shotBy }, now, "shot at")
            return true
        end
        local near
        for _, k in ipairs(cands) do
            if k.d < CFG.GUN_RANGE * 1.3 and (not near or k.d < near.d) then near = k end
        end
        if near then engage(c, near.t, now, "shot at") return true end
    end
    -- Rushers make for their station and dock; they only fight when shot at.
    if c.rusher then return false end
    for _, k in ipairs(cands) do
        if now >= (c.seen[k.key] or 0) then
            c.seen[k.key] = now + CFG.ATTACK_COOLDOWN
            if attackersOn(k.t) < CFG.MAX_ON_SHIP and math.random() < c.aggression ^ 2 * CFG.ATTACK_CHANCE then
                engage(c, k.t, now, "sighted")
                return true
            end
        end
    end
    return false
end

-- Every frame: guns. A crew in a fight fires bursts while its target is in range and within GUN_CONE of the nose
-- (ships keep facing their target while they circle it). The gun aims along the controller's view (focused on it).
local function fireControl(now, dt)
    for _, c in ipairs(S.crews) do
        c.frameDt = dt
        local want = false
        local tgt = c.fireAt
        if tgt and c.state == "attack" and c.gun and valid(c.gun) and shipOk(c) and valid(tgt) and crewOnShip(c) then
            local sl, tl = c.ship:K2_GetActorLocation(), tgt:K2_GetActorLocation()
            local d = dist(sl, tl)
            if c.runPhase == "in" and d < CFG.GUN_RANGE * 1.3 and d > CFG.RUN_OVERSHOOT * 0.5 then
                -- aim: slew the nose toward the target (flight path stays the movement's)
                local r = c.ship:K2_GetActorRotation()
                local wantYaw = math.deg(math.atan(tl.Y - sl.Y, tl.X - sl.X))
                local wantPitch = math.deg(math.atan(tl.Z - sl.Z, math.sqrt((tl.X - sl.X) ^ 2 + (tl.Y - sl.Y) ^ 2)))
                local dy = (wantYaw - r.Yaw + 180) % 360 - 180
                local dp = wantPitch - r.Pitch
                local step = CFG.NOSE_TURN * (c.frameDt or 0.016)
                if math.abs(dy) < 70 then
                    c.ship:K2_SetActorRotation({ Pitch = r.Pitch + math.max(-step, math.min(step, dp)),
                        Yaw = r.Yaw + math.max(-step, math.min(step, dy)), Roll = r.Roll }, true)
                end
            end
            if d < CFG.GUN_RANGE and d > 1 then
                local f = c.ship:GetActorForwardVector()
                local dot = (f.X * (tl.X - sl.X) + f.Y * (tl.Y - sl.Y) + f.Z * (tl.Z - sl.Z)) / d
                if dot > math.cos(math.rad(CFG.GUN_CONE)) then
                    if now >= (c.burstUntil or 0) then
                        c.burstOn = not c.burstOn
                        c.burstUntil = now + rnd(c.burstOn and CFG.BURST or CFG.BURST_PAUSE)
                    end
                    want = c.burstOn
                end
            end
        end
        if tgt and c.state == "attack" and shipOk(c) and valid(tgt) and crewOnShip(c) then
            local ok, fired = pcall(fireTurrets, c, tgt, now)
            if not ok and not S.turretErr then S.turretErr = true X.log("[rivals] turrets failed: " .. tostring(fired)) end
            if ok and fired then
                c.turretShots = (c.turretShots or 0) + 1
                if c.target and c.target.crew then c.target.crew.shotBy, c.target.crew.shotAt = c, now end
            end
        end
        if want and c.target and c.target.crew then c.target.crew.shotBy, c.target.crew.shotAt = c, now end
        if want ~= (c.firing or false) then
            c.firing = want
            if want then c.bursts = (c.bursts or 0) + 1 end
            pcall(function() if want then c.gun:ServerStartFire() else c.gun:ServerStopFire() end end)
        end
    end
end

-- Boarding parties: one member (or the whole crew) in pods; they materialize at your breach points while you're
-- aboard and hunt you; the ship carries on fighting with whoever stayed. Aboard a rival's ship (p.victim) there are no
-- bodies: the fight is rounds of one kill each, and boarders who clear the ship keep it.
local function launchParty(c, now)
    local members = {}
    for _, m in ipairs(c.members) do
        if m.alive then
            table.insert(members, m)
            if c.boardPlan == "one" then break end
        end
    end
    if #members == 0 then return end
    local p = { id = c.id, parent = c, members = members, captain = members[1].name, shipName = c.shipName,
        state = "pods", podsAt = now, victim = c.target.crew }
    for _, m in ipairs(members) do m.boarding = true end
    c.party = p
    launchPods(c, p, targetShip(c.target))
    if c.boardPlan == "all" and not p.victim then say(S.pc, ("The %s is pulling alongside to board you!"):format(c.shipName)) end
end

local function endParty(p, why)
    dematerialize(p)
    for _, m in ipairs(p.members) do
        m.boarding = nil
        -- Stranded with no ship to go back to: lost.
        if not shipOk(p.parent) then m.alive = false end
    end
    p.parent.party = nil
    X.log(("[rivals] %s's boarders %s"):format(p.parent.captain, why))
end

local function defenders(o)
    local list = {}
    for _, m in ipairs(o.members) do if m.alive and not m.boarding then table.insert(list, m) end end
    return list
end

-- The boarders cleared the ship: it's theirs now, under its old name, and they go on with its raid.
local function captureShip(p, now)
    local c, o = p.parent, p.victim
    local kept = {}
    for _, m in ipairs(c.members) do
        local boarded = false
        for _, b in ipairs(p.members) do if b == m then boarded = true end end
        if not boarded then table.insert(kept, m) end
    end
    local crew = {}
    for _, m in ipairs(p.members) do
        m.boarding = nil
        if m.alive then table.insert(crew, m) end
    end
    c.members, c.party = kept, nil
    o.members, o.captain, o.diehard, o.fleeHull = crew, p.captain, c.diehard, c.fleeHull
    o.fireAt, o.target, o.boardPlan, o.state = nil, nil, nil, "travel"
    setShipEnemy(o, nil)
    o.station = o.station or chooseStation(o)
    o.seen, c.seen = o.seen or {}, c.seen or {}
    o.seen[c], c.seen[o] = math.huge, math.huge
    X.log(("[rivals] %s took the %s from its crew"):format(p.captain, o.shipName))
    if crewAlive(c) then
        disengage(c, now, "took their ship")
    else
        c.fireAt, c.target = nil, nil
        if shipOk(c) then
            dropTurrets(c)
            R.destroy(c.ship)
        end
        c.ship, c.state = nil, "gone"
        X.log(("[rivals] %s left their own %s behind"):format(p.captain, c.shipName))
    end
end

local function fightAboard(p, now)
    local o = p.victim
    if o.state == "gone" or not shipOk(o) then
        for _, m in ipairs(p.members) do m.alive = false end
        p.parent.party = nil
        X.log(("[rivals] %s's boarders were lost with the %s"):format(p.captain, o.shipName))
        return
    end
    if o.bodies or now < p.roundAt then return end -- its crew are on foot in a station you're in: nothing to simulate
    p.roundAt = now + rnd(CFG.BOARD_ROUND)
    local foes, ours = defenders(o), {}
    for _, m in ipairs(p.members) do if m.alive then table.insert(ours, m) end end
    if #foes > 0 then
        local a, d = pick(ours), pick(foes)
        local attackerWins = math.random() < 0.5 + (a.skill - d.skill) * CFG.BOARD_SKILL
        local dead = attackerWins and d or a
        dead.alive = false
        X.log(("[rivals] %s was killed in the fight aboard the %s"):format(dead.name, o.shipName))
        if not attackerWins then return end
    end
    if #defenders(o) == 0 then captureShip(p, now) end
end

local function updateParty(p, now, place, ending)
    if p.bodies then bodiesAlive(p) end
    local alive = false
    for _, m in ipairs(p.members) do if m.alive then alive = true end end
    if not alive then dematerialize(p) p.parent.party = nil return end
    if p.state == "pods" then
        local waiting = false
        for _, pod in ipairs(S.pods) do
            if pod.crew == p and not pod.boarded then
                if (pod.hitAt and now - pod.hitAt >= CFG.BREACH_DELAY) or now - p.podsAt > CFG.POD_TIMEOUT + 5 then
                    pod.boarded = true
                else
                    waiting = true
                end
            end
        end
        if not waiting and p.victim then
            p.state, p.roundAt = "fight", now + rnd(CFG.BOARD_ROUND)
            X.log(("[rivals] %s %s aboard the %s"):format(p.captain, #p.members > 1 and "and crew are" or "is", p.victim.shipName))
        elseif not waiting then
            p.state, p.boardedAt = "aboard", now
            say(S.pc, ("%s %s cut through your hull"):format(p.captain, #p.members > 1 and "and crew have" or "has"))
        end
    elseif p.state == "fight" then
        fightAboard(p, now)
    elseif p.state == "aboard" then
        if place == "ship" then
            p.lastSeenAboard = now
            if not p.bodies and now >= (p.spotsAt or 0) then
                p.spotsAt = now + 1 -- (path queries: not every frame while there's nowhere yet)
                local pawn = S.pc.Pawn
                local spots = breachSpots(nil, valid(pawn) and pawn:K2_GetActorLocation() or nil)
                if #spots > 0 then materialize(p, spots, "boarding") end
            end
        elseif p.bodies and now - (p.lastSeenAboard or now) > CFG.DEMATERIALIZE_AFTER then
            dematerialize(p)
        end
        if ending then endParty(p, "went back to their ship (raid ending)")
        elseif now - (p.lastSeenAboard or p.boardedAt) > CFG.ABOARD_WAIT then endParty(p, "gave up waiting aboard your ship") end
    end
end

-- Simulated crews docked at the same station sometimes run into each other: someone may not come back.
local function simClashes(dt)
    local by = {}
    for _, c in ipairs(S.crews) do
        if c.state == "docked" and c.station and not c.bodies then
            by[c.station] = by[c.station] or {}
            table.insert(by[c.station], c)
        end
    end
    for st, list in pairs(by) do
        if #list >= 2 and math.random() < CFG.SIM_CLASH_PER_MIN * dt / 60 then
            local a = list[math.random(#list)]
            local b
            repeat b = list[math.random(#list)] until b ~= a
            local loser = math.random() < 0.5 and a or b
            for _, m in ipairs(loser.members) do
                if m.alive and not m.boarding then
                    m.alive = false
                    X.log(("[rivals] %s (%s) was killed by %s's crew in %s"):format(m.name, loser.shipName,
                        (loser == a and b or a).captain, st.name))
                    break
                end
            end
        end
    end
end

-- You boarding a rival's ship --------------------------------------------------------------------------------------
-- The free slots are listed once a raid (two object scans, ~45 ms each: a hitch per interior before), then handed out.
local function freeInteriorSlot()
    if not S.freeSlots then
        S.freeSlots = {}
        local insides = FindAllOf("RaidSpaceshipInside") or {}
        for _, s in ipairs(FindAllOf("RaidFrigateIntSpawn") or {}) do
            if valid(s) and not s.bForFrigateSpawning then
                local l, taken = s:K2_GetActorLocation(), false
                for _, i in ipairs(insides) do
                    if valid(i) and dist(i:K2_GetActorLocation(), l) < 1000 then taken = true end
                end
                if not taken then table.insert(S.freeSlots, { X = l.X, Y = l.Y, Z = l.Z }) end
            end
        end
    end
    return table.remove(S.freeSlots, 1)
end

local function makeInterior(c)
    local at = freeInteriorSlot()
    if not at then
        if not S.noSlotSaid then S.noSlotSaid = true X.log("[rivals] no free interior slot left on this map") end
        return
    end
    S.interiors = (S.interiors or 0) + 1
    local cls = c.design and loadClass(CFG.INSIDES .. c.design.inside)
    if not cls then
        X.log(("[rivals] no interior class for the %s: using yours"):format(c.shipName))
        cls = S.homeInside:GetClass()
    end
    local inside = S.pc:GetWorld():SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 })
    if valid(inside) then
        c.inside = inside
        X.log(("[rivals] interior for the %s (%s) loading: %s"):format(c.shipName, c.design and c.design.name or "?",
            inside:GetClass():GetFName():ToString()))
    end
end

-- The new interior spawns a hull of its own a moment later: the rival's takes its place.
local function pairInterior(c)
    local own = c.inside.SpaceshipToPairTo
    if not valid(own) then return end
    local ctrl = own.Controller
    c.inside.SpaceshipToPairTo = c.ship
    c.ship.MyShipInside = c.inside
    if valid(ctrl) then
        ctrl:UnPossess()
        R.destroy(ctrl)
    end
    R.destroy(own)
    local box = c.inside.InSideComp
    c.insideBox = { c = box:K2_GetComponentLocation(), e = box:GetScaledBoxExtent() }
    X.addInteriorNav(S.pc, c.inside)
    X.log(("[rivals] interior for the %s ready"):format(c.shipName))
end

-- Out of the pod and through the hull, at one of the ship's breach points. No navmesh needed: the spots are the game's.
-- Where you stand after cutting in: walkable floor by a breach point that joins up with the inside of the ship. The
-- breach points themselves are in the hull wall, about 5 m up (the user came out inside a wall), and the floor nearest
-- one can be outside the walls (see joined). No breach point with such floor: the floor at the ship's dock starts.
-- nil while the interior's navmesh isn't built yet.
local function breachLanding(inside)
    local anchor = insideAnchor(inside, nil)
    if not anchor then return nil end
    for _, at in ipairs(entryPoints(inside)) do
        for try = 1, 4 do
            local p = try == 1 and projected(at, { X = 250, Y = 250, Z = 600 }) or reachableNear(at, 500)
            if p and not X.offLimits(p) and joined(anchor, p) then return { X = p.X, Y = p.Y, Z = p.Z + 100 } end
        end
    end
    return { X = anchor.X, Y = anchor.Y, Z = anchor.Z + 100 }
end

-- The camera back on your body after the void wait (see rescueFromVoid).
local function voidCamOff(pawn)
    if not S.voidCam then return end
    S.voidCam = nil
    pcall(function() S.pc:SetViewTargetWithBlend(pawn, 0, 0, 0, false) end)
end

-- Your body after a pod flight. The game parks it for the flight (hidden, movement component not ticking, no gravity,
-- not turned by the mouse) and its own breach ability undoes that; ours and the void rescue skip that ability, so you
-- could pitch and shoot but not turn or walk (2026-11-14, read off the body and fixed live from the bridge).
local function afterPod(foot)
    local cdo
    pcall(function() cdo = foot:GetClass():GetCDO() end)
    local cm = foot.CharacterMovement
    local grav = 1.0
    pcall(function() if valid(cdo.CharacterMovement) then grav = cdo.CharacterMovement.GravityScale end end)
    local was = ("yaw=%s tick=%s grav=%s"):format(tostring(foot.bUseControllerRotationYaw),
        tostring(valid(cm) and cm:IsComponentTickEnabled()), tostring(valid(cm) and cm.GravityScale))
    pcall(function() foot.bUseControllerRotationYaw = cdo and cdo.bUseControllerRotationYaw ~= false end)
    if valid(cm) then
        pcall(function() cm:SetComponentTickEnabled(true) end)
        pcall(function() cm.GravityScale = grav end)
        pcall(function() cm:SetMovementMode(1, 0) end)
    end
    pcall(function() foot:SetActorHiddenInGame(false) end)
    -- and the controller's input, which the body's fix alone didn't give back (all of these were needed live)
    pcall(function() S.pc:ResetIgnoreInputFlags() end)
    pcall(function() foot:EnableInput(S.pc) end)
    pcall(function() S.pc:EnableInput(S.pc) end)
    pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(S.pc) end)
    pcall(function() S.pc:SetCinematicMode(false, false, false, true, true) end)
    pcall(function() S.pc.bShowMouseCursor = false end)
    pcall(function() S.pc:FlushPressedKeys() end)
    S.voidCam = true
    voidCamOff(foot)
    X.log("[rivals] your body after the pod had " .. was .. ": walking again")
end

-- Traces for podExitCheck (the Visibility channel, your body ignored). Kept in R (not exported for use elsewhere):
-- rivals.lua is at Lua's 200-locals limit.
R.Ground = { NOCOL = { R = 0, G = 0, B = 0, A = 0 } }
function R.Ground.trace(foot, from, to)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = {}
    if Out.call(ksl, "LineTraceSingle", S.pc, from, to, 0, false, { foot }, 0, out, true, R.Ground.NOCOL, R.Ground.NOCOL, 0)
        and out.ImpactPoint then
        return { X = out.ImpactPoint.X, Y = out.ImpactPoint.Y, Z = out.ImpactPoint.Z }
    end
end
-- The first thing straight below `at`, within `depth`.
function R.Ground.below(foot, at, depth) return R.Ground.trace(foot, at, { X = at.X, Y = at.Y, Z = at.Z - depth }) end
-- Nothing between `at` and a body standing on `p` (aimed 60 above its floor point).
function R.Ground.inSight(foot, at, p) return R.Ground.trace(foot, at, { X = p.X, Y = p.Y, Z = p.Z + 60 }) == nil end

-- Just out of a pod that didn't bring you into a rival's ship (see POD_EXIT_CHECK). The game's station docking left the
-- body parked, in a sealed shaft at Fortress (2026-11-14: "stuck inside what looks to be a tube"), fixed live from the bridge.
local function podExitCheck(foot)
    local l = foot:K2_GetActorLocation()
    local cm = foot.CharacterMovement
    local parked = valid(cm) and not cm:IsComponentTickEnabled()
    local floor = projected({ X = l.X, Y = l.Y, Z = l.Z - 100 }, { X = 80, Y = 80, Z = 120 })
    if floor and not parked then return end
    if not floor then
        -- Straight down first: the real floor under you (a trace), and the navmesh right where it hit. At Fortress
        -- (Space_Alpha, 2026-11-16) the pod leaves you above a hatch whose room floor is ~590 below; stepping the
        -- navmesh search down 300 at a time (+-200) found a point 180 to the side first, behind a wall, and put the
        -- tester in it. Any other spot must be in sight from where you came out (nothing in the way of a line to it).
        local spot
        local down = R.Ground.below(foot, l, 1500)
        -- (navmesh is built around you as you arrive, so right out of the pod there may be none yet: then the floor
        -- point itself, which the trace reached with nothing in the way)
        if down then spot = projected(down, { X = 80, Y = 80, Z = 150 }) or down end
        for dz = 300, 1500, 300 do
            if spot then break end
            local p = projected({ X = l.X, Y = l.Y, Z = l.Z - dz }, { X = 200, Y = 200, Z = 200 })
            if p and R.Ground.inSight(foot, l, p) then spot = p end
        end
        if not spot then
            local p = projected(l)
            if p and R.Ground.inSight(foot, l, p) then spot = p end
        end
        if spot then
            Out.call(foot, "K2_SetActorLocation", { X = spot.X, Y = spot.Y, Z = spot.Z + 100 }, false, {}, true)
            X.log(("[rivals] out of the pod with no floor under you at %.0f,%.0f,%.0f: moved to the floor at %.0f,%.0f,%.0f")
                :format(l.X, l.Y, l.Z, spot.X, spot.Y, spot.Z))
        else
            X.log(("[rivals] out of the pod with no floor under you at %.0f,%.0f,%.0f, and no floor found near"):format(l.X, l.Y, l.Z))
        end
    end
    if parked then afterPod(foot) end
end

-- force: the pod is at the hull (or already gone), so with no navmesh yet you come in at a dock start (made to be stood
-- at) rather than not at all. Returns whether you're in.
local function breachInto(c, force)
    local ok, spot = pcall(breachLanding, c.inside)
    if not ok then spot = nil end
    if not spot then
        if not force then return false end
        pcall(function()
            local l = c.inside.ShipDockOnePlayerStart:K2_GetComponentLocation()
            spot = { X = l.X, Y = l.Y, Z = l.Z + 50 }
        end)
        spot = spot or entryPoints(c.inside)[1]
        X.log("[rivals] breach: the interior's navmesh isn't ready, coming in at a dock start")
    end
    local pod, foot = S.pc.Pawn, S.foot
    if not (spot and valid(foot)) then return false end
    local inPod = valid(pod) and pod:GetAddress() ~= foot:GetAddress()
    if inPod then S.pc:Possess(foot) end
    afterPod(foot)
    foot:SetActorHiddenInGame(false)
    foot:SetActorEnableCollision(true)
    Out.call(foot, "K2_SetActorLocation", spot, false, {}, true)
    pcall(function() foot.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
    -- facing into the ship
    S.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(c.insideBox.c.Y - spot.Y, c.insideBox.c.X - spot.X)), Roll = 0 })
    if inPod then R.destroy(pod) end
    S.podAt, S.voidSince = nil, nil
    -- crew.lua brings your crewmates in through the same hole, behind you
    S.breach = { at = { X = spot.X, Y = spot.Y, Z = spot.Z }, time = os.clock(), ship = c.shipName,
        spots = breachSpots(c.inside) }
    say(S.pc, ("You cut through the hull of the %s"):format(c.shipName))
    X.log(("[rivals] you boarded the %s at %.0f,%.0f,%.0f"):format(c.shipName, spot.X, spot.Y, spot.Z))
    return true
end

-- A wreck (hull shot to 0, crew dead with it) still floats where it died, and the user expects to board it like any
-- other ship: its hull only has to still exist (shipOk wants hull and controller).
local function hullThere(c)
    if c.state == "wreck" then
        if c.ship and not valid(c.ship) then c.ship = nil end
        return c.ship ~= nil
    end
    return shipOk(c)
end

local function boardable(c)
    return (c.state == "travel" or c.state == "attack" or c.state == "leaving" or c.state == "docked"
        or c.state == "derelict" or c.state == "wreck") and hullThere(c)
end

-- How far a point is from a hull's collision surface (its centre distance if that can't be read). Measured only when
-- the centre is near enough for the hull to matter. The user rammed a rival over and over without breaching: the hull
-- stopped the pod well outside PLAYER_BOARD_RANGE of the centre.
local function hullGap(ship, here, d)
    if d > CFG.PLAYER_BOARD_RANGE * 4 then return d end
    local hit = {}
    local ok = pcall(function() ship.Mesh:GetClosestPointOnCollision(here, hit, FName("None")) end)
    if not (ok and hit.X) then return d end
    local dx, dy, dz = hit.X - here.X, hit.Y - here.Y, hit.Z - here.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- A pod's breach (or anything else) that left you on foot in the dark at the map origin, where the game parks your body
-- during a pod flight. If the pod was last seen at a rival's hull, that's the ship you hit: you come out inside it, once
-- its interior is in (VOID_BOARD_*). Otherwise back into your own ship after VOID_RESCUE seconds.
-- While you wait in the void the camera looks at the hull you hit (or your own ship), not at the dark (user: "I was in a black
-- void for a moment while the interior loaded which doesn't look great"). Looked at every frame (R.frame) as well as
-- from the update, so the dark doesn't show for the half second between two updates.
local function rescueFromVoid(now)
    local pawn = S.pc.Pawn
    if not (valid(pawn) and pawn:GetClass():GetFName():ToString() == "PlayerPawn_C") then S.voidSince = nil return end
    local l = pawn:K2_GetActorLocation()
    if math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) > CFG.VOID_NEAR then
        S.voidSince = nil
        voidCamOff(pawn)
        return
    end
    S.voidSince = S.voidSince or now
    local waited = now - S.voidSince
    local c = S.podShip
    if not S.voidCam then
        local look = (c and hullThere(c) and c.ship) or (valid(S.playerShip) and S.playerShip) or nil
        if look and pcall(function() S.pc:SetViewTargetWithBlend(look, 0, 0, 0, false) end) then S.voidCam = true end
    end
    if c and S.podSeen and S.voidSince - S.podSeen < CFG.VOID_BOARD_RECENT and waited < CFG.VOID_BOARD_WAIT
        and boardable(c) then
        if not c.inside and (S.interiors or 0) < CFG.PLAYER_BOARD_MAX then
            makeInterior(c)
            if c.inside then X.log(("[rivals] the pod hit the %s before its interior was in: loading it now"):format(c.shipName)) end
        end
        if c.inside then
            -- (two seconds for the interior's navmesh, then in at a dock start)
            if c.insideBox and breachInto(c, waited > 2) then return end
            return
        end
    end
    if waited < CFG.VOID_RESCUE or not valid(S.homeInside) then return end
    S.voidSince, S.podShip = nil, nil
    local ok, spot = pcall(breachLanding, S.homeInside)
    if not (ok and spot) then
        spot = entryPoints(S.homeInside)[1]
        if not spot then return end
        spot = { X = spot.X, Y = spot.Y, Z = spot.Z + 100 }
    end
    Out.call(pawn, "K2_SetActorLocation", spot, false, {}, true)
    afterPod(pawn)
    say(S.pc, "That hull had no way in: you made it back to your ship")
    X.log("[rivals] you were left in the void after a breach: moved back into your ship")
end

-- Every frame while you fly a pod (a pod covers several metres a frame: looked at twice a second, it could go from out
-- of range to into the hull between two looks, and then the game's own impact left you in the void).
local function playerBoarding(now)
    local pawn = S.pc.Pawn
    if not valid(pawn) then return end
    if not pawn.bADropPod then
        -- Just out of a pod: if the game's breach put you inside a rival's ship, your crewmates follow you in (crew.lua)
        -- and your body gets the same check as after ours.
        if S.podSeen and now - S.podSeen < CFG.VOID_BOARD_RECENT then
            local l = pawn:K2_GetActorLocation()
            for _, c in ipairs(S.crews) do
                if c.insideBox and inBox(c.insideBox, l, 300) then
                    S.podSeen, S.podAt, S.voidSince = nil, nil, nil
                    afterPod(pawn)
                    S.breach = { at = { X = l.X, Y = l.Y, Z = l.Z }, time = os.clock(), ship = c.shipName,
                        spots = breachSpots(c.inside) }
                    X.log(("[rivals] the game's breach brought you into the %s at %.0f,%.0f,%.0f"):format(c.shipName, l.X, l.Y, l.Z))
                    break
                end
            end
        end
        local l = pawn:K2_GetActorLocation()
        if S.podSeen and now - S.podSeen >= CFG.POD_EXIT_CHECK and now - S.podSeen < CFG.VOID_BOARD_RECENT
            and math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) > CFG.VOID_NEAR then -- (in the void: rescueFromVoid's)
            S.podSeen, S.podAt = nil, nil
            local ok, err = pcall(podExitCheck, pawn)
            if not ok then X.log("[rivals] pod exit check: " .. tostring(err)) end
        end
        return
    end
    local here = pawn:K2_GetActorLocation()
    -- the pod's course: its velocity, or its nose while it's barely moving
    local v = pawn:GetVelocity()
    local speed = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
    if speed < 100 then v, speed = pawn:GetActorForwardVector(), 1 end
    local loading = false
    for _, c in ipairs(S.crews) do
        if c.inside and not c.insideBox and valid(c.inside) then loading = true end
    end
    local nearest, nd, want, wd
    for _, c in ipairs(S.crews) do
        -- Docked ships too (parked at a station while the crew raids it): before, a pod into one of those met a hull
        -- with no interior, and the game left you where your body waits during a pod flight, 0,0,0 in the dark.
        if boardable(c) then
            local at = c.ship:K2_GetActorLocation()
            local d = dist(here, at)
            local gap = hullGap(c.ship, here, d)
            if not nd or gap < nd then nearest, nd = c, gap end
            if c.insideBox then
                if not CFG.PLAYER_BOARD_GAME and (d < CFG.PLAYER_BOARD_RANGE or gap < CFG.PLAYER_BOARD_TOUCH) and breachInto(c, gap < CFG.PLAYER_BOARD_FORCE) then
                    return
                end
            elseif not c.inside and d < CFG.PLAYER_BOARD_PREP then
                local cos = ((at.X - here.X) * v.X + (at.Y - here.Y) * v.Y + (at.Z - here.Z) * v.Z) / (math.max(1, d) * speed)
                if (d < CFG.PLAYER_BOARD_CLOSE or cos > math.cos(math.rad(CFG.PLAYER_BOARD_AIM))) and (not wd or d < wd) then
                    want, wd = c, d
                end
            end
        end
    end
    S.podAt, S.podSeen = here, now
    S.podShip = nd and nd < CFG.VOID_BOARD_NEAR and nearest or nil
    -- one interior at a time (each is a level streaming in), and only for the ship you're flying at
    if want and not loading and (S.interiors or 0) < CFG.PLAYER_BOARD_MAX then makeInterior(want) end
end

-- Your hands on its helm: the game has handed you the rival's hull (Interact possesses it). It's your ship from now on,
-- and what's left of its crew carries on as bodies with nothing to fly.
local function checkStolen()
    local pawn = S.pc.Pawn
    if not valid(pawn) then return end
    for _, c in ipairs(S.crews) do
        if c.insideBox and valid(c.ship) and c.ship:GetAddress() == pawn:GetAddress() then
            X.log(("[rivals] you took the %s"):format(c.shipName))
            say(S.pc, ("The %s is yours"):format(c.shipName))
            -- What the game would save is the interior's row: the backend gets the hull's.
            local f = io.open(CFG.SHIP_STOLEN_FILE, "w")
            if f then
                f:write(c.design and c.design.row or "")
                f:close()
            end
            S.playerShip, S.homeInside, S.playerShipMaxHull = c.ship, c.inside, c.maxHull
            S.home = { box = c.insideBox }
            c.fireAt, c.target, c.ship, c.shipCtrl, c.insideBox, c.inside = nil, nil, nil, nil, nil, nil
            c.state = "gone"
            return
        end
    end
end

-- Within PROVOKE_CONE of where you're looking (the camera: your ship's guns or the turret you man aim along it). Its
-- foe's hits and yours land at the same time, so this is what tells the ship you shot from the one you didn't.
local function aimCos(at)
    local ship = S.playerShip
    local ok, r = pcall(function() return S.pc:GetControlRotation() end)
    if not (ok and r and valid(ship)) then return -1 end
    local from = ship:K2_GetActorLocation()
    local dx, dy, dz = at.X - from.X, at.Y - from.Y, at.Z - from.Z
    local n = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz))
    local yaw, pitch = math.rad(r.Yaw), math.rad(r.Pitch)
    local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
    return (dx * fx + dy * fy + dz * fz) / n
end

-- Two ships in a dogfight are often both inside the cone: only the one nearest your line of fire counts.
local function inYourSights(c, at)
    local mine = aimCos(at)
    if mine < math.cos(math.rad(CFG.PROVOKE_CONE)) then return false end
    for _, o in ipairs(S.crews) do
        if o ~= c and o.ambient and o.state == "attack" and shipOk(o) and aimCos(o.ship:K2_GetActorLocation()) > mine then
            return false
        end
    end
    return true
end

-- Crew brain -----------------------------------------------------------------------------------------------------
local function updateCrew(c, now, place, playerLoc)
    if c.state == "gone" then return end
    -- (a derelict's or wreck's interior can still be loading: your pod asked for it on the way in)
    if c.inside and not c.insideBox and valid(c.inside) and hullThere(c) then pairInterior(c) end
    if c.state == "derelict" or c.state == "wreck" then return end
    if c.bodies then bodiesAlive(c) end
    if not crewAlive(c) then
        dematerialize(c)
        X.log("[rivals] " .. crewLabel(c) .. " wiped out")
        -- A ship whose crew you killed waits for you at its helm, boardable like any other: with its interior already in,
        -- or loaded when your pod heads for it (the user: ships with dead crews must stay fully boardable; the Iron
        -- Gull's crew died boarding you before it had an interior, and was dropped as "gone" with its hull still there).
        if shipOk(c) then
            Nav.halt(c)
            c.state = "derelict"
            if c.berth or c.moored or c.glide then clearBerth(c) end
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
            if c.bodies and c.mode == "station" then dematerialize(c) end
            if not c.bodies and c.watch then
                local spots = breachSpots(c.inside)
                if #spots > 1 then table.remove(spots, 1) end
                local alive = {}
                for _, m in ipairs(c.watch) do if m.alive then alive[#alive + 1] = m end end
                if #alive > 0 and #spots > 0 then
                    materialize(c, spots, "boarding", alive)
                    X.log(("[rivals] %d of the %s's watch are aboard"):format(#alive, c.shipName))
                end
            end
        elseif not c.bodies then
            local spots = breachSpots(c.inside)
            if #spots > 0 then materialize(c, spots, "boarding") end
        end
    elseif c.bodies and c.mode == "boarding" and now - (c.lastBoarded or 0) > CFG.DEMATERIALIZE_AFTER then
        dematerialize(c)
    end

    if c.state == "waiting" then
        if now < c.launchAt then return end
        if not spawnShip(S.pc, c) then c.launchAt = now + 10 return end
        c.state = "travel"
        c.station = chooseStation(c)
        X.log(("[rivals] %s%s launched in a %s (%s): %s"):format(crewLabel(c), c.rusher and " (rusher)" or "",
            c.design and c.design.name or "?", table.concat(c.turretKinds or {}, " + "),
            c.station and ("heading for " .. c.station.name) or "nowhere to go"))
        return
    end

    local flying = c.state == "travel" or c.state == "attack" or c.state == "leaving"
    if flying and not shipOk(c) then
        X.log("[rivals] " .. crewLabel(c) .. " went down with their ship")
        for _, m in ipairs(c.members) do m.alive = false end
        c.state = valid(c.ship) and "wreck" or "gone"
        if c.state == "wreck" then pcall(stillTurrets, c) end
        return
    end
    local shipLoc = shipOk(c) and c.ship:K2_GetActorLocation() or nil
    local hull = shipOk(c) and c.ship.MainHullHealth / math.max(1, c.maxHull) or 0

    local hurt = c.lastHull and shipOk(c) and c.ship.MainHullHealth < c.lastHull - 1
    c.lastHull = shipOk(c) and c.ship.MainHullHealth or nil
    if hurt then c.hurtAt = now end
    -- An ambient fighter hit while you're shooting from close by turns on you (its foe's shots can't be told apart from
    -- yours, so it's the timing: you fired in the last few seconds).
    if c.ambient and hurt and c.state == "attack" and not (c.target and c.target.player) and shipLoc
        and now - (S.playerFiredAt or -1e9) < CFG.PROVOKE_SECONDS and valid(S.playerShip)
        and dist(shipLoc, S.playerShip:K2_GetActorLocation()) < CFG.GUN_RANGE * 1.5 and inYourSights(c, shipLoc) then
        engage(c, { player = true }, now, "provoked")
    end
    local ending = S.remaining ~= nil and S.remaining <= c.extractRemaining
    if c.party then updateParty(c.party, now, place, ending) end
    if flying and c.state ~= "leaving" and not c.diehard and hull < c.fleeHull then
        c.fireAt = nil
        setShipEnemy(c, nil)
        startLeaving(c, "hull damaged")
    end
    if ending and (c.state == "travel" or (c.state == "attack" and not c.diehard)) then
        c.fireAt = nil
        if shipOk(c) then setShipEnemy(c, nil) end
        startLeaving(c, "raid ending")
    end
    if c.state == "travel" and shipLoc and lookForFights(c, shipLoc, now, hurt) then return end

    if c.state == "travel" then
        if not c.station then startLeaving(c, "no stations") return end
        local st = c.station
        if c.berth and c.berth.taken ~= c then c.berth = nil end
        if not c.berth and not takeBerth(st, c) then
            -- Every berth taken: hold off the station; after a short wait board anyway (the ship stays parked there).
            local _, _, approach = berthPose(st, st.berths[1])
            if not approach then c.station = chooseStation(c) return end
            -- Straight out along the approach lane (open space: it's how ships fly in), spread by crew. A fixed +X offset
            -- put the hold point inside the Mini Mine's rock: ships flew into it and parked there out of sight.
            local at = berthPose(st, st.berths[1])
            local ox, oy, oz = approach.X - at.X, approach.Y - at.Y, approach.Z - at.Z
            local on = math.max(1, math.sqrt(ox * ox + oy * oy + oz * oz))
            local out = CFG.HOLD_OUT + (c.id % 4) * CFG.HOLD_SPACING
            local side = ((c.id % 3) - 1) * CFG.HOLD_SPACING
            local hold = { X = approach.X + ox / on * out - oy / on * side, Y = approach.Y + oy / on * out + ox / on * side,
                Z = approach.Z + oz / on * out }
            flyTo(c, hold, 600)
            if dist(shipLoc, hold) < 2500 then
                c.berthWait = c.berthWait or now
                if now - c.berthWait > CFG.BERTH_WAIT then
                    c.berthWait = nil
                    c.state, c.dockedAt = "docked", now
                    c.lock = pickLock(st, c)
                    setWatch(c)
                    c.leaveAt = now + rnd(CFG.DOCK_SECONDS)
                    setShipEnemy(c, nil)
                    Nav.halt(c)
                    X.log(("[rivals] %s breached into %s (no free berth)"):format(crewLabel(c), st.name))
                end
            end
            return
        end
        c.berthWait = nil
        local at, _, approach = berthPose(st, c.berth)
        if not at then c.berth, c.station = nil, chooseStation(c) return end -- that AI frigate sank
        flyTo(c, dockRoute(c, st, c.berth, at, approach, shipLoc))
        -- The glide in is a straight line: it starts only out on the lane, never from beside or under the station.
        local _, _, off = laneOf(at, approach, shipLoc)
        if dist(shipLoc, approach) < CFG.DOCK_ARRIVE and off < CFG.DOCK_LANE then
            c.state, c.dockedAt = "docked", now
            c.lock = pickLock(st, c)
            setWatch(c)
            c.leaveAt = now + rnd(CFG.DOCK_SECONDS)
            setShipEnemy(c, nil)
            startGlide(c, "in")
            X.log(("[rivals] %s docked at %s"):format(crewLabel(c), st.name))
        end

    elseif c.state == "attack" then
        local tgt = targetShip(c.target)
        if not tgt and c.foes then
            -- a battle: on to the enemy ship fewest are on, nearest first
            local best, bn, bd
            for _, f in ipairs(c.foes) do
                if f.state ~= "gone" and f.state ~= "derelict" and shipOk(f) then
                    local n = attackersOn({ crew = f })
                    local fd = dist(shipLoc, f.ship:K2_GetActorLocation())
                    if not best or n < bn or (n == bn and fd < bd) then best, bn, bd = f, n, fd end
                end
            end
            if best then
                local foes = c.foes
                engage(c, { crew = best }, now, "next target")
                c.foes, c.boardPlan = foes, nil
                tgt = targetShip(c.target)
            end
        end
        if not tgt then
            disengage(c, now, "target gone")
            if c.ambient then startLeaving(c, "won their fight") end
            return
        end
        local tl = tgt:K2_GetActorLocation()
        local d = dist(shipLoc, tl)
        -- (a crew sent in by a test trigger is moved next to you a tick late: not "lost" for its first 30 s)
        if d > CFG.SHIP_SIGHT * (c.diehard and 4 or 1.5) and not (c.testUntil and now < c.testUntil) then
            disengage(c, now, "lost them") return
        end
        if now >= c.engageUntil and not c.party and not c.diehard then disengage(c, now, "had enough") return end
        setShipEnemy(c, tgt)
        c.fireAt = tgt
        if crewOnShip(c) and not (c.boardPlan and now >= c.boardAt and not c.boarded) then
            local at, accept = manoeuvre(c, shipLoc, tgt, tl, now)
            flyTo(c, at, accept)
        elseif crewOnShip(c) then
            -- boarding: close in and hold off so the pods can go
            c.runPhase = nil
            flyTo(c, holdOff(shipLoc, tl), 300)
        else
            flyTo(c, holdOff(shipLoc, tl), 300) -- everyone's aboard your ship: it waits nearby
        end
        -- Boarders go once, when the time comes (or your hull is low) and they're close enough for the pods.
        if c.boardPlan and not c.party and not c.boarded then
            local full = c.target.player and S.playerShipMaxHull or (c.target.crew and c.target.crew.maxHull)
            local th = (tgt.MainHullHealth or 0) / math.max(1, full or tgt.MainHullHealth)
            local reachable = not c.target.crew or c.target.crew.state ~= "docked"
            if reachable and (now >= c.boardAt or th < CFG.BREACH_HULL) and d < CFG.POD_RANGE then
                c.boarded = true
                launchParty(c, now)
            end
        end

    elseif c.state == "docked" then
        local st = c.station
        if ending and not c.wrapUp then
            -- Raid ending: finish up, walk back to the airlock and extract.
            c.wrapUp, c.stationsLeft = true, 1
            c.leaveAt = math.min(c.leaveAt, now)
            X.log(("[rivals] %s is heading back to their ship in %s (raid ending)"):format(crewLabel(c), st.name))
        end
        -- (held still: StopMovement alone left a ship parked off a full station drifting away in a straight line)
        if shipOk(c) and not c.glide and not c.moored then Nav.halt(c) end
        if place == st then
            c.lastInside = now
            -- One crew at a time, and only once the station's guards are in and every earlier body is built: spread
            -- points steer clear of bodies that exist, so three crews spawned in one update (before Rebel Base's
            -- guards were adopted) landed among the guards and lost 5 of 7 in nine seconds (2026-11-14).
            local settling = #S.building > 0 or (S.adoptQueue and #S.adoptQueue > 0) or (S.topUps and #S.topUps > 0)
                or (S.pendingDefenders and #S.pendingDefenders > 0)
                or now - (S.lastMaterialize or -99) < CFG.MATERIALIZE_GAP
            -- Room for so many crews at once (insideCap); the rest wait aboard, and come in through an airlock later.
            local full = not c.bodies and crewsInside(st) >= insideCap(st)
            local crowd = not c.bodies and not full and CFG.AWAKE_MAX > 0 and R.awakeCount() >= CFG.AWAKE_MAX
            if (full or crowd) and not c.waitingRoom then
                c.waitingRoom = true
                if full then
                    X.log(("[rivals] %s waits aboard: %s already holds %d crews"):format(crewLabel(c), st.name, crewsInside(st)))
                else
                    X.log(("[rivals] %s waits aboard: %d awake around you already (AWAKE_MAX)"):format(crewLabel(c),
                        R.awakeCount()))
                end
            end
            full = full or crowd
            if not c.bodies and not settling and not full then
                if c.waitingRoom then c.lateEntry, c.waitingRoom = true, nil end
                materialize(c, stationSpawnSpots(c, st, playerLoc), "station")
                if c.bodies then S.lastMaterialize, c.lateEntry = now, nil end
            end
            if c.arrival then crewArrival(c, now) end
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
                            local best = spreadPoint(st, e, mates, c.searched)
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
                    c.exitAt = c.lock and valid(c.lock.dock) and lockExit(c.lock) or projected(pick(st.entries)) or st.box.c
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
                        X.log(("[rivals] %s left %s through the airlock"):format(crewLabel(c), st.name))
                        dematerialize(c)
                    end
                end
            end
        else
            -- (not the watch aboard their ship while you're on it: that's the boarding branch's to clear)
            if c.bodies and c.mode ~= "boarding" and now - (c.lastInside or 0) > CFG.DEMATERIALIZE_AFTER then dematerialize(c) end
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
            undock(c)
            c.stationsLeft = c.stationsLeft - 1
            if not shipOk(c) then
                -- Ship destroyed while they were inside: stranded for good.
                for _, m in ipairs(c.members) do m.alive = false end
                c.state = "gone"
                X.log("[rivals] " .. crewLabel(c) .. " lost their ship and are stranded")
            elseif c.stationsLeft <= 0 then
                startLeaving(c, "raid done")
            else
                c.state, c.station = "travel", chooseStation(c)
                X.log(("[rivals] %s undocked, heading for %s"):format(crewLabel(c), c.station and c.station.name or "?"))
            end
        end

    elseif c.state == "leaving" then
        if c.exitAt then flyTo(c, c.exitAt, 1000) end
        -- Can't get stuck for good: the exit is only a point in space (no gate), so a ship that stops getting any
        -- closer to it extracts where it is. Close in (circling a hull parked at the point), soon; anywhere else
        -- (wedged in a station, as a CapitalShipFrigate was), after longer. Progress = a new best distance.
        local d = c.exitAt and dist(shipLoc, c.exitAt) or 0
        if not c.exitBest or d < c.exitBest - CFG.EXIT_PROGRESS then c.exitBest, c.exitBestAt = d, now end
        local stalled = now - c.exitBestAt > (d < CFG.EXIT_NEAR and CFG.EXIT_STALL_NEAR or CFG.EXIT_STALL)
        if stalled then
            X.log(("[rivals] %s stalled %d m from their exit"):format(crewLabel(c), math.floor(d / 100)))
        end
        if not c.exitAt or d < 3000 or stalled then
            dropTurrets(c)
            R.destroy(c.ship)
            c.ship, c.state = nil, "gone"
            X.log("[rivals] " .. crewLabel(c) .. " extracted")
        end
    end

end

-- Body construction finishes over later updates (a rolled gun arrives a moment after the kit).
local function finishBuilding(now)
    for i = #S.building, 1, -1 do
        local job = S.building[i]
        local ok, entry = pcall(finishBody, job.b)
        if not ok then
            X.log("[rivals] body failed: " .. tostring(entry))
            table.remove(S.building, i)
        elseif entry == false then
            table.remove(S.building, i)
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
                X.log(("[rivals] %s (%s kit, %s, %d hp, %s) is in %s"):format(entry.rival.name, entry.rival.tier.name,
                    entry.rival.gunName or "no gun", entry.rival.hp, entry.rival.personality,
                    job.mode == "boarding" and (c.inside and "their ship" or "your ship") or c.station.name))
            else
                -- The crew dematerialized while this one was being built.
                R.destroy(entry.bot)
                removeEntry(entry)
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
        glideShips(now)
        fireControl(now, sdt)
        pcall(swingAimed, sdt)
    end
    if #S.pods > 0 then flyPods(dt) end
    if valid(S.pc) then
        pcall(rescueFromVoid, now)
        local ok, err = pcall(playerBoarding, now)
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
local function unseen(p) return aimCos(p) < math.cos(math.rad(CFG.SKIRMISH_UNSEEN)) end

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
            local c = newCrew(#S.crews + 1, used, CFG.CREW_SIZE)
            for _, mm in ipairs(c.members) do used[mm.name] = true end
            c.ambient, c.diehard, c.rusher, c.stationsLeft = true, true, false, 0
            if spawnShip(pc, c, places[k][i]) then
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
            engage(c, { crew = theirs[(i - 1) % #theirs + 1] }, now, per > 1 and "battle" or "skirmish")
            c.boardPlan, c.foes = nil, theirs
        end
    end
    X.log(("[rivals] skirmish: %d against %d (the %s and the %s), %.0f m from you, %.0f deg off your view"):format(
        #sides[1], #sides[2], sides[1][1].shipName, sides[2][1].shipName, dist(here, spot) / 100,
        math.deg(math.acos(math.max(-1, math.min(1, aimCos(spot)))))))
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
        AIMED = {}
        Kills.reset()
        Nav.reset()
        S.pc = pc
        pcall(gearCatalog) -- every look loaded now, under the loading veil
        local ok, st = pcall(survey, pc, valid(homeInside) and homeInside.SpaceshipToPairTo or nil)
        if not ok then X.log("[rivals] station survey failed: " .. tostring(st)) end
        S.stations = ok and st or {}
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
        local kind = mapKind(worldName)
        S.crews = makeCrews(slots, kind)
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
        local ok, err = pcall(armShips, pc, now)
        if not ok then X.log("[rivals] arming: " .. tostring(err)) end
    end
    simClashes(math.min(5, now - (S.lastUpdate or now)))
    S.lastUpdate = now
    local place, playerLoc = playerPlace()
    pcall(checkStolen)
    local okV, errV = pcall(rescueFromVoid, os.clock())
    if not okV and not S.voidErr then S.voidErr = true X.log("[rivals] void rescue failed: " .. tostring(errV)) end
    -- First time you walk into a station this raid: it gets its soldiers (the director's garrison).
    if type(place) == "table" and not place.garrisoned then
        place.garrisoned = true
        local ok, err = pcall(garrisonStation, pc, place)
        if not ok then X.log("[rivals] garrison failed: " .. tostring(err)) end
    end
    local okS, errS = pcall(skirmishStep, pc, now)
    if not okS then X.log("[rivals] skirmish failed: " .. tostring(errS)) end
    if type(place) == "table" and place.garrisoned then
        S.adoptQueue = S.adoptQueue or {}
        local okA, errA = pcall(sweepStrays, place, now)
        if not okA and not S.strayErr then S.strayErr = true X.log("[rivals] stray sweep failed: " .. tostring(errA)) end
        local okR, errR = pcall(roamGuards, place, now)
        if not okR and not S.roamErr then S.roamErr = true X.log("[rivals] guard roaming failed: " .. tostring(errR)) end
    end
    adoptQueued()
    topUpStep(pc)
    keepDefendersArmed()
    local okM, errM = pcall(keepShipMoving, now)
    if not okM and not S.shipMoveErr then S.shipMoveErr = true X.log("[rivals] ship movement check failed: " .. tostring(errM)) end
    for _, c in ipairs(S.crews) do
        local ok, err = xpcall(updateCrew, function(e) return { e = e, tb = debug.traceback() } end, c, now, place, playerLoc)
        if not ok then
            local msg = type(err) == "table" and (type(err.e) .. " " .. tostring(err.e) .. " | " .. tostring(err.tb))
                or ("raw " .. type(err) .. " " .. tostring(err))
            X.log(("[rivals] crew %d (%s) update failed: %s"):format(c.id, tostring(c.state), msg))
            c.errors = (c.errors or 0) + 1
            if c.errors > 20 then dematerialize(c) c.state = "gone" end
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
            .. " | turret shots " .. (S.turretShots or 0) .. turretWhy() .. " | steering: " .. Nav.report() .. ", breakaways " .. (S.seps or 0))
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
        if c.state == "travel" and shipOk(c) and not c.inside then
            local d = dist(here, c.ship:K2_GetActorLocation())
            local wanted = want and c.design and c.design.name:find(want, 1, true) and -1
            if not bd or (wanted or d) < bd then best, bd = c, wanted or d end
        end
    end
    if best then makeInterior(best) end
end

-- Debug: F4 sends the nearest flying crew to attack you right away.
function R.provoke(board)
    if not S then return end
    local best, bd
    for _, c in ipairs(S.crews) do
        if (c.state == "travel" or c.state == "waiting" or c.state == "leaving") and valid(S.playerShip) then
            if c.state == "waiting" then c.launchAt = 0 end
            local d = shipOk(c) and dist(c.ship:K2_GetActorLocation(), S.playerShip:K2_GetActorLocation()) or 1e9
            if not bd or d < bd then best, bd = c, d end
        end
    end
    if best then
        best.aggression = 1
        best.forceAttack = true
        -- A crew still at its spawn point launches now.
        -- (A ship spawned this frame reads 0 hull until its next tick, so check it exists, not shipOk.)
        if not shipOk(best) and spawnShip(S.pc, best) then best.station = chooseStation(best) end
        if valid(best.ship) then
            local pl = S.playerShip:K2_GetActorLocation()
            Out.call(best.ship, "K2_SetActorLocation", { X = pl.X + 12000, Y = pl.Y, Z = pl.Z }, false, {}, true)
            engage(best, { player = true }, os.clock(), "provoked")
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
            if spawnShip(S.pc, c) then c.state, c.station = "travel", chooseStation(c) end
        end
        if c.state == "travel" and valid(c.ship) and #pair < 2 then table.insert(pair, c) end
    end
    -- late in a raid nobody's travelling: crews heading home, or fighting each other, will do (for filming)
    for _, c in ipairs(S.crews) do
        if #pair < 2 and (c.state == "leaving" or (c.state == "attack" and not (c.target and c.target.player)))
            and shipOk(c) and c ~= pair[1] then table.insert(pair, c) end
    end
    if #pair < 2 then X.log("[rivals] clash: no two crews flying") return end
    local a, b, pl = pair[1], pair[2], S.playerShip:K2_GetActorLocation()
    Out.call(a.ship, "K2_SetActorLocation", { X = pl.X + 12000, Y = pl.Y, Z = pl.Z + 2000 }, false, {}, true)
    Out.call(b.ship, "K2_SetActorLocation", { X = pl.X + 12000, Y = pl.Y + (apart or 3000), Z = pl.Z + 2000 }, false, {}, true)
    engage(a, { crew = b }, os.clock(), "clash test")
    a.boardPlan, a.boardAt = "all", 0
    -- the target fights back (a crew heading home would otherwise extract before the pods arrive)
    engage(b, { crew = a }, os.clock(), "clash test")
    b.boardPlan = nil
    a.testUntil, b.testUntil = os.clock() + 30, os.clock() + 30
end

-- Your own crew (crew.lua) is built from the same people, bodies and turrets as the rivals.
R.startBody = function(pc, m, at) return startBody(pc, m, at) end
R.rollKit = rollKit
R.finishBody = finishBody
R.holdGun = holdGun

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
    end
    return S.nodeTurrets
end

local function nodeTurretAlive(t)
    -- (bIsDying reads as a Lua boolean: comparing it with 0 was always false, so every turret counted as dead and your
    -- gunner never shot one, picked or ordered)
    local ok, alive = pcall(function()
        local dying = t.bIsDying
        return valid(t) and (t.Health or 0) > 0 and not (dying == true or (type(dying) == "number" and dying ~= 0))
    end)
    return ok and alive
end

local function turretTarget(t, here, at)
    return { ship = t, turret = true, name = "turret", d = dist(here, at) }
end

-- Out in space with a hull there: not docked or held in a berth, not a derelict, a wreck or gone.
local OUT_OF_PLAY = { docked = true, derelict = true, wreck = true, gone = true }
local function flyingShip(c) return not OUT_OF_PLAY[c.state] and not c.moored and shipOk(c) end

-- Ships your gunner may shoot: crews attacking you, the ship you just fired on, and stationary turrets aiming at your
-- ship. Nearest first. Entries as pickShip's.
function R.hostileShips()
    if not S or not valid(S.playerShip) then return {} end
    local here, list = S.playerShip:K2_GetActorLocation(), {}
    local firing = os.clock() - (S.playerFiredAt or -99) < CFG.PROVOKE_SECONDS
    for _, c in ipairs(S.crews or {}) do
        if c.state ~= "gone" and shipOk(c) then
            local at = c.ship:K2_GetActorLocation()
            if (c.state == "attack" and c.target and c.target.player) or (firing and inYourSights(c, at)) then
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
local function flyingShip(c) return not OUT_OF_PLAY[c.state] and not c.moored and shipOk(c) end

-- What you point your gunner at (left click at the helm, crew.lua): of the ships out flying and the stationary turrets
-- standing within `range` of you, the one nearest the middle of your view if any is within `cone` deg of it, else the
-- nearest. Any crew, hostile or not. Returns { ship = actor, crew = c or nil, turret = true or nil, name, d, centred }.
function R.pickShip(range, cone)
    if not S or not valid(S.playerShip) then return nil end
    local here, near, best, nearD, bestCos = S.playerShip:K2_GetActorLocation(), nil, nil, range, math.cos(math.rad(cone))
    local function consider(e, at)
        if e.d > range then return end
        local cs = aimCos(at)
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
    local fired = fireTurrets(gun, tgt, now)
    if fired then playerFired() end
    return fired
end

-- Your gunner takes the barrels of these shipTurrets entries (on: from the helm your view no longer swings them) or
-- gives them back to the game (off: the pilot aims and fires the first one again, as solo).
function R.aimTurrets(turrets, on)
    for _, e in ipairs(turrets) do
        if valid(e.actor) and (on and not e.aimed or not on and e.aimed) then aimTurret(e, on) end
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
function R.reset() S = nil end
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
