-- AI tuning: every setting of the bots' brain as a slider, in a menu built at runtime (F10 in a raid).
-- The rows point straight at the live tables (main.lua CFG, rivals.lua CFG, ai.lua's profiles and personalities), which
-- the AI reads when it decides, so a change applies at once. Defaults are whatever those tables start with; only
-- values you changed are saved, in SAVE_FILE, so a new default in the code still reaches an untouched setting.
--
-- UE4SS has no UI API here and UMG delegates can't be bound from Lua, so the menu is plain widgets: constructed into a
-- host widget's tree, and polled while open (slider values, button presses). The host is DebugInfo_Widget with its
-- children cleared: an existing Blueprint with a canvas root, because the base UserWidget class is abstract.
local PROJECT = require("pveproject") -- the install folder (".../MaraudersPvE/"), written by scripts/mode.ps1
local T = {}
local X -- context from main.lua: log, valid, lib, menuClosed, CFG, RCFG, AI, applied

local SAVE_FILE = PROJECT .. "config/ai_tuning.txt"
local PRESET_FILE = PROJECT .. "config/ai_presets.txt" -- your own presets
local HOST = "/SIGISPlugin/Widgets/DebugInfo_Widget.DebugInfo_Widget_C"
local X0, Y0, W, MAX_H = 40, 40, 760, 980 -- the panel, in UI units: as tall as the window allows
local TEXT, SMALL = 15, 12
local SAVE_DELAY = 2 -- seconds after the last change

local tabs, rows = {}, {}
local mine = {} -- your presets: { name, values = { id = value } }; a setting left out is at its default
-- The launcher's SETTINGS page (#324) edits SAVE_FILE and PRESET_FILE before a raid; it learns what the settings are
-- (tabs, labels, ranges, defaults, the difficulty presets) from SCHEMA_FILE, written here at every start.
local SCHEMA_FILE = PROJECT .. "config/settings_schema.json"
local writeSchema -- (below presetValue, which it uses)

-- Difficulty: how capable bots are, not how they behave, so cover and sprint tuning stays as set at every level.
-- profile = multipliers on every bot type's defaults (Rivals, Bosses, Guards, Soldiers tabs); aim = values for the Aim
-- tab, anything left out at its default. Normal is the defaults. AIMissRate stops mattering above ~0.9 and shows little
-- change below ~0.45, so the hardest levels work mostly by capping the worst moments (AIM_MISS_MAX) and through reaction
-- and senses, not by pushing the base lower still.
local PRESETS = {
    { name = "Easy", profile = { miss = 1.5, reaction = 1.6, spotTime = 1.5, sight = 0.75, hearing = 0.75, dispersion = 1.4 },
      aim = { AIM_MISS_MAX = 1.0, AIM_SETTLE_SECONDS = 3.5, AIM_SETTLE_PENALTY = 2.2, AIM_MOVING = 1.6, AIM_TARGET_MOVING = 1.45,
              AIM_UNDER_FIRE = 1.4 } },
    { name = "Normal", profile = {}, aim = {} },
    { name = "Hard", profile = { miss = 0.75, reaction = 0.7, spotTime = 0.8, sight = 1.15, hearing = 1.15, dispersion = 0.8 },
      aim = { AIM_MISS_MAX = 0.8, AIM_SETTLE_SECONDS = 1.0, AIM_SETTLE_PENALTY = 1.25, AIM_MOVING = 1.1, AIM_UNDER_FIRE = 1.15 } },
    { name = "Very Hard", profile = { miss = 0.55, reaction = 0.45, spotTime = 0.6, sight = 1.3, hearing = 1.3, dispersion = 0.6 },
      aim = { AIM_MISS_MAX = 0.6, AIM_SETTLE_SECONDS = 0.6, AIM_SETTLE_PENALTY = 1.1, AIM_MOVING = 1.05, AIM_TARGET_MOVING = 1.0,
              AIM_UNDER_FIRE = 1.05 } },
}

-- { key, label, min, max, step, help } on table t; a { key, index, ... } row is one end of a { low, high } range.
local function add(tab, t, list)
    tab.rows = tab.rows or {}
    for _, d in ipairs(list) do
        local r
        if type(d[2]) == "number" and d[6] ~= nil and type(d[6]) ~= "string" then
            r = { t = t, k = d[1], i = d[2], label = d[3], min = d[4], max = d[5], step = d[6], help = d[7] }
        else
            r = { t = t, k = d[1], label = d[2], min = d[3], max = d[4], step = d[5], help = d[6] }
        end
        r.id = (tab.id or tab.name) .. ":" .. tostring(r.k) .. (r.i and ("." .. r.i) or "")
        tab.rows[#tab.rows + 1] = r
        rows[#rows + 1] = r
    end
end

-- A row's value in a saved list (settings file, preset), by its id or the id it had before.
local function stored(values, r)
    local v = values[r.id]
    if v == nil and r.oldId then v = values[r.oldId] end
    return v
end

local function get(r)
    if r.i then return r.t[r.k][r.i] end
    return r.t[r.k]
end

local function set(r, v)
    if r.i then r.t[r.k][r.i] = v else r.t[r.k] = v end
end

-- Labels and hints are written for anyone: plain words, no jargon. Distances are in centimetres (100 = 1 metre), the
-- game's own unit. A tab's `id` is its old name: saved settings are keyed on it, so renaming a tab loses nothing.
local function define()
    local CFG, RCFG, AI = X.CFG, X.RCFG, X.AI
    local aim = { name = "Aim" }
    add(aim, CFG, {
        { "AIM_SKILL_SPREAD", "How different enemies' aim is", 0, 1, 0.01, "0 = every enemy aims equally well. Higher = some are sharpshooters, some are bad shots" },
        { "AIM_STREAK", "Good and bad moments", 0, 1, 0.01, "How much an enemy's aim gets better or worse from moment to moment" },
        { "AIM_STREAK_SECONDS", 1, "Length of a good or bad moment, shortest (seconds)", 0.5, 15, 0.1, "" },
        { "AIM_STREAK_SECONDS", 2, "Length of a good or bad moment, longest (seconds)", 0.5, 30, 0.1, "" },
        { "AIM_SETTLE_SECONDS", "Time to get their aim in (seconds)", 0, 6, 0.1, "After spotting you, enemies miss more until this time has passed" },
        { "AIM_SETTLE_PENALTY", "How badly the first shots miss", 1, 4, 0.05, "1 = no worse than usual. Higher = first shots miss more" },
        { "AIM_MOVING", "Worse aim while they move", 1, 3, 0.05, "1 = no effect. Higher = they miss more while walking or running" },
        { "AIM_TARGET_MOVING", "Worse aim when you move", 1, 3, 0.05, "1 = no effect. Higher = moving makes you harder to hit" },
        { "AIM_UNDER_FIRE", "Worse aim right after being hit", 1, 3, 0.05, "1 = no effect. Higher = getting shot throws their aim off more" },
        { "AIM_UNDER_FIRE_SECONDS", "How long being hit throws them off (seconds)", 0, 6, 0.1, "" },
        { "AIM_RANGE_PER_10M", "Worse aim at long range", 0, 0.5, 0.01, "How much more they miss for every 10 metres away you are" },
        { "AIM_MISS_MAX", "Their worst possible aim", 0.3, 1.5, 0.01, "Lower = even their worst shots are fairly accurate (lowering this makes them harder)" },
    })
    local move = { name = "Moving" , id = "Fighting" }
    add(move, CFG, {
        { "STRAFE_SECONDS", 1, "Time between side-steps, shortest (seconds)", 0.2, 6, 0.1, "In a gunfight, enemies step left and right to be harder to hit" },
        { "STRAFE_SECONDS", 2, "Time between side-steps, longest (seconds)", 0.2, 10, 0.1, "" },
        { "STRAFE_DIST", 1, "Side-step length, shortest (cm)", 50, 1000, 10, "" },
        { "STRAFE_DIST", 2, "Side-step length, longest (cm)", 50, 1500, 10, "" },
        { "STRAFE_ANIM_SCALE", "Speed while shooting and moving", 1, 3.5, 0.05, "1 = slow. Higher = they move faster while firing" },
        { "MOVE_ANIM_SCALE", "Walking speed", 1, 3, 0.05, "When patrolling and walking around" },
        { "LEG_RATE_MAX", "Fastest leg movement", 1, 2.5, 0.05, "Caps the two speeds above so legs never cycle unnaturally fast" },
        { "REPOSITION_SECONDS", 1, "Time between moves toward you, shortest (seconds)", 1, 15, 1, "When they've lost sight of you" },
        { "REPOSITION_SECONDS", 2, "Time between moves toward you, longest (seconds)", 1, 20, 1, "" },
        { "ADVANCE_RADIUS", "How close they get to where they last saw you (cm)", 100, 2000, 25, "" },
        { "CROUCH_MAX", "Longest time crouching in the open (seconds)", 0, 6, 0.1, "" },
        { "CROUCH_COOLDOWN", "Time standing before crouching again (seconds)", 0, 30, 0.5, "" },
        { "POINT_BLANK", "Close noise that starts a fight (cm)", 50, 1000, 10, "Any noise you make this close makes them attack straight away" },
    })
    local cover = { name = "Cover" }
    add(cover, CFG, {
        { "COVER_SEEK_CHANCE", "Chance they look for cover", 0, 1, 0.01, "0 = never, 1 = always. Bold enemies use cover less" },
        { "COVER_HURT_CHANCE", "Chance they look for cover after being hit", 0, 1, 0.01, "0 = never, 1 = always" },
        { "SPRINT_EXPOSED_CHANCE", "Chance they run to cover while you can see them", 0, 1, 0.01, "Running is faster but they can't shoot. Otherwise they walk and shoot" },
        { "SPRINT_UNSEEN_CHANCE", "Chance they run to cover while hidden from you", 0, 1, 0.01, "" },
        { "SPRINT_SPEED", "Running speed", 300, 800, 10, "" },
        { "OPEN_FIGHT_SECONDS", "Time fighting in the open before trying cover again (seconds)", 0, 20, 0.25, "" },
        { "COVER_RETRY", "How often they look for cover (seconds)", 0.25, 6, 0.25, "" },
        { "COVER_SEARCH", "How far they look for cover (cm)", 200, 3000, 25, "" },
        { "COVER_SEARCH_FAR", "How far they look when nothing is nearby (cm)", 200, 5000, 25, "Only while you can't see them" },
        { "EXPOSED_COVER_DIST", "Furthest cover they'll go to while you can see them (cm)", 200, 3000, 25, "" },
        { "EXPOSED_RUN_SECONDS", "Longest run to cover while you can see them (seconds)", 0.5, 10, 0.25, "After this they give up and fight" },
        { "COVER_BLIND_PEEKS", "Peeks without seeing you before they move", 1, 6, 1, "After this many, they leave that cover and find another" },
        { "HIDE_SECONDS", 1, "Time hiding between peeks, shortest (seconds)", 0.1, 6, 0.1, "" },
        { "HIDE_SECONDS", 2, "Time hiding between peeks, longest (seconds)", 0.1, 10, 0.1, "" },
        { "PEEK_SECONDS", 1, "Time leaning out to shoot, shortest (seconds)", 0.1, 6, 0.1, "" },
        { "PEEK_SECONDS", 2, "Time leaning out to shoot, longest (seconds)", 0.1, 10, 0.1, "" },
        { "PEEK_SPEED", "Speed of leaning out and back", 100, 900, 10, "" },
        { "HURT_DUCK_SECONDS", "Hide again if hit within (seconds)", 0, 3, 0.1, "If shot this recently, they duck back behind cover" },
        { "LOW_COVER_PENALTY", "How much they avoid low cover", 0, 2000, 25, "0 = low cover is as good as tall cover. Higher = they prefer tall cover" },
        { "COVER_PLAYER_DIST", 1, "Closest cover to you they'll use (cm)", 0, 2000, 25, "" },
        { "COVER_PLAYER_DIST", 2, "Furthest cover from you they'll use (cm)", 500, 10000, 50, "" },
        { "BOT_LOW_MAG", "Reload in cover when the magazine is down to this share", 0, 0.6, 0.05, "They go to cover and reload before running dry. 0 = only when empty, in the open" },
        { "BOT_HEAL_COUNT", "Times each enemy heals in cover", 0, 5, 1, "0 = they never heal" },
        { "BOT_HEAL_HP", "They heal below this share of health", 0.05, 0.9, 0.05, "Only if not shot for a few seconds, and cover is near" },
        { "BOT_HEAL_QUIET", "...and not shot for (seconds)", 0, 20, 0.5, "" },
        { "BOT_HEAL_SECONDS", "Healing takes (seconds)", 1, 20, 0.5, "" },
        { "BOT_HEAL_TO", "They heal back up to this share of health", 0.1, 1, 0.05, "" },
        { "BOT_PUSH_SECONDS", "Chads rush you while you reload or heal (seconds)", 0, 10, 0.5, "Chads and GigaChads fighting you close in for this long. 0 = never" },
    })
    local senses = { name = "Senses" }
    add(senses, CFG, {
        { "PERCEIVE_RANGE", "How far away they notice people (cm)", 1000, 20000, 100, "" },
        { "GUNSHOT_RANGE", "How far away they hear gunshots (cm)", 1000, 30000, 100, "" },
        { "BOT_GUNSHOT_SCALE", "How far enemies' own gunshots carry", 0.1, 1, 0.05, "Share of the range above. Lower = fights between them draw in fewer others" },
        { "CALIBRE_EFFECT", "How much the gun's calibre changes how far its shot carries", 0, 1, 0.05, "0 = every gun as loud (the range above). 1 = pistols short, rifles long, machine guns longest" },
        { "SUPPRESSED_GUNSHOT", "How far suppressed gunshots carry", 0.05, 1, 0.05, "Share of the range. 1 = a suppressor makes no difference" },
        { "LOOK_AROUND", 1, "Time checking out a noise, shortest (seconds)", 0, 20, 0.5, "" },
        { "LOOK_AROUND", 2, "Time checking out a noise, longest (seconds)", 0, 30, 0.5, "" },
        { "PATROL_RADIUS", "How far they wander when nothing's happening (cm)", 200, 6000, 50, "" },
        { "PATROL_PAUSE", 1, "Wait between wanders, shortest (seconds)", 0, 30, 0.5, "" },
        { "PATROL_PAUSE", 2, "Wait between wanders, longest (seconds)", 0, 60, 0.5, "" },
    })
    tabs = { aim, move, cover, senses }
    for _, p in ipairs({ { "rival", "Rivals", "rival crews" }, { "boss", "Bosses", "bosses" }, { "guard", "Guards", "elite guards" },
            { "soldier", "Soldiers", "soldiers" } }) do
        local tab = { name = p[2] }
        add(tab, AI.PROFILES[p[1]], {
            { "miss", "How often " .. p[3] .. " miss", 0, 1, 0.01, "Lower = better shots. Most of the difference is between 0.45 and 0.85" },
            { "reaction", 1, "Time to shoot after spotting you, fastest (seconds)", 0, 3, 0.05, "" },
            { "reaction", 2, "Time to shoot after spotting you, slowest (seconds)", 0, 4, 0.05, "" },
            { "spotTime", "Time to spot you", 0.2, 4, 0.05, "1 = normal. Higher = slower to notice you" },
            { "sight", "How far they can see (cm)", 2000, 30000, 100, "" },
            { "halfAngle", "How wide they can see (degrees to each side)", 20, 120, 1, "" },
            { "hearing", "How well they hear", 0, 2, 0.01, "1 = normal. Higher = they hear you from further away" },
            { "dispersion", "How badly they guess where a sound came from", 0, 3, 0.01, "0 = they know exactly where you are" },
            { "strafe", "Speed moving sideways or backwards", 0.1, 1, 0.01, "Compared to walking forwards (1 = just as fast)" },
        })
        for _, r in ipairs(tab.rows) do r.perProfile = true end
        tabs[#tabs + 1] = tab
    end
    -- AI.PERSONALITIES' names are the AI's own; shown the way you'd describe the person (as hire.lua does).
    local TEMPER = { GigaChad = "Fearless", Wreckless = "Reckless", Chad = "Aggressive", SnappingTurtle = "Defensive",
        Normal = "Steady", Rat = "Sneaky", Timmy = "Timid", Coward = "Cowardly" }
    local pers = { name = "Personalities" }
    local names = {}
    for n in pairs(AI.PERSONALITIES) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        local who = TEMPER[n] or n
        add(pers, AI.PERSONALITIES[n], {
            { "aggression", who .. ": boldness", 0.1, 4, 0.05, "Higher = uses cover less and pushes toward you more" },
            { "holdGround", who .. ": stays in the open", 0.1, 4, 0.05, "Higher = fights longer without cover" },
            { "sprintSearch", who .. ": runs to check noises", 0, 1, 0.01, "Chance they run (not walk) to a noise they heard" },
        })
        -- each personality's rows get ids of their own ("Personalities:Rat:aggression"); they used to share one per
        -- setting, so a saved value landed on every personality. The old id is still read (stored) from older files.
        for j = #pers.rows - 2, #pers.rows do
            local r = pers.rows[j]
            r.oldId, r.id = r.id, "Personalities:" .. n .. ":" .. tostring(r.k)
        end
    end
    add(pers, X.CFG, {
        { "BEG_CHANCE", "Hurt Rats, Cowards and Timmys beg for their life", 0, 1, 0.05, "Chance, once per person, near you and under a quarter health. They hold fire, then run. 0 = never" },
        { "BEG_HP", "Begging starts below this share of health", 0.05, 0.6, 0.05, "" },
        { "TAUNT_CHANCE", "Chads taunt after a kill or a hit on you", 0, 1, 0.05, "Chance each time (and not too often). 0 = silent" },
    })
    tabs[#tabs + 1] = pers
    -- How many bots there are. Read when they're placed (crews at the start of a raid, guards when a station is first
    -- reached), so a change shows from the next raid or station.
    local spawns = { name = "How many", id = "Spawns" }
    add(spawns, X.RCFG, {
        { "CREWS", "Rival crews in each raid", 0, 30, 1, "0 = every free player slot (11). Takes effect next raid" },
        { "CREW_SIZE", 1, "People in a rival crew, fewest", 1, 6, 1, "Takes effect next raid" },
        { "CREW_SIZE", 2, "People in a rival crew, most", 1, 6, 1, "" },
        { "STATIONS_PER_RAID", 1, "Stations a crew raids before leaving, fewest", 1, 6, 1, "Takes effect next raid" },
        { "STATIONS_PER_RAID", 2, "Stations a crew raids before leaving, most", 1, 6, 1, "" },
        { "MIN_DEFENDERS", "Guards at a mid-size station", 0, 40, 1, "Small stations get as few as half, big ones up to 1.5x. Takes effect at the next station you visit" },
        { "STATION_AREA_PER_CREW", "Station space per crew (m2)", 5000, 60000, 1000, "Lower = big stations hold more crews before others look elsewhere" },
        { "STATION_CROWD", "How much a busy station puts crews off", 0.05, 1, 0.05, "1 = not at all (crews go by size alone); lower = crews spread out more" },
        { "SKIRMISH_MAX", "Fights between other crews per raid", 0, 20, 1, "Other crews fighting each other where you can see. 0 = none" },
        { "SKIRMISH_EVERY", 1, "Time between those fights, shortest (seconds)", 20, 600, 5, "" },
        { "SKIRMISH_EVERY", 2, "Time between those fights, longest (seconds)", 20, 900, 5, "" },
        { "SKIRMISH_SHIPS", 1, "Ships on each side in those fights, fewest", 1, 8, 1, "1 = one on one; more = a battle" },
        { "SKIRMISH_SHIPS", 2, "Ships on each side in those fights, most", 1, 8, 1, "Big battles cost frame rate" },
        { "AWAKE_MAX", "Most enemies awake around you", 0, 40, 1, "More crews wait aboard their ship until some are down. Lower = better frame rate. 0 = no limit" },        { "ROUT_SECONDS", 1, "Guards run when their leader dies, shortest (seconds)", 0, 120, 5, "0 = they never run" },
        { "ROUT_SECONDS", 2, "Guards run when their leader dies, longest (seconds)", 0, 180, 5, "" },
        { "ROUT_FIRE_RANGE", "Running guards fight back this close (cm)", 0, 3000, 100, "" },
    })
    add(spawns, X.CFG, {
        { "PARK_RANGE", "Far-off guards sleep beyond (cm)", 0, 40000, 500, "Guards at peace this far from you stop until you come back. 0 = never (costs frame rate)" },
    })
    add(spawns, require("civilians").CFG, {
        { "COUNT", "Civilians at mines, ports and prisons", 0, 10, 1, "Miners, workers and prisoners who run instead of fighting. Per station, from the next station you enter. 0 = none" },
    })
    tabs[#tabs + 1] = spawns
    -- Gear: how well armed rivals, station top-ups and new crew are, by your player level (gearscale.lua). Read when a
    -- person's kit is rolled (crews at the start of a raid, recruits in the hiring list), so a change shows from then.
    local gear = { name = "Gear" }
    add(gear, X.RCFG, {
        { "SCALE_GEAR", "Gear follows your level", 0, 1, 1, "1 = on: better-armed enemies and recruits as you level up. 0 = off: the same odds at every level" },
    })
    add(gear, require("gearscale").CFG, {
        { "TARGET", 1, "Typical gear at level 1", 0, 1, 0.01, "0 = the cheapest gear in the game, 1 = the dearest. Most people roll a bit below this" },
        { "TARGET", 2, "Typical gear at the top level", 0, 1, 0.01, "Raise both to make everyone better armed" },
        { "DOWN_SHARE", "Share of people below the typical gear", 0, 1, 0.01, "0.7 = most are worse armed than the typical gear for your level; lower = tougher" },
        { "OUTLIER", "Chance of any gear at all", 0, 0.5, 0.01, "The odd geared rival early on, or a poorly armed one late" },
    })
    tabs[#tabs + 1] = gear
    -- Loot density (#325). Containers are filled by the game itself at map load, so they have no setting here.
    local loot = { name = "Loot" }
    add(loot, X.CFG, {
        { "FLOOR_LOOT", "Floor loot", 0, 3, 0.05, "1 = the game's own odds. Lower = spawners skipped; higher = empty spawners roll again. Takes effect next raid" },
    })
    add(loot, X.RCFG, {
        { "BODY_LOOT", "Loot on bodies", 0, 3, 0.05, "1 = normal. Scales the meds and items in a guard's or rival's bag (not their ammo) and the chance of a pocket item. Takes effect for bodies rolled after the change" },
    })
    tabs[#tabs + 1] = loot
    local ships = { name = "Rival ships", id = "Crews" }
    add(ships, X.RCFG, {
        { "BARON", "The Red Baron in every raid", 0, 1, 0.05, "1 = always: one rival crew is the Red Baron's, in his strike frigate, and he hunts any ship he sees. Below 1 = his chance per raid. Takes effect next raid" },
        { "BARON_RISE", "Baron chance added per raid without him", 0, 0.5, 0.01, "0 = off. Each raid he doesn't fly raises his chance by this much; a raid with him resets it. Counted per save. Takes effect next raid" },
        { "BARON_MAX", "Most the Baron's chance can rise to", 0, 1, 0.05, "The ceiling for the rise above. Takes effect next raid" },
        { "IMPOSTOR_CHANCE", "Chance a crew's captain poses as the Red Baron", 0, 1, 0.01, "0 = never. Per raid, one ordinary crew's captain wears the Baron's head and coat; he fights like any rival and the log calls him an impostor. Never with the real Baron on. Takes effect next raid" },
        { "RUSHERS","Crews that head straight for a station", 0, 1, 0.01, "0 = none, 1 = all. They only fight if shot at" },
        { "ATTACK_CHANCE", "Chance a crew attacks a ship it sees", 0, 1, 0.01, "Aggressive crews attack more often" },
        { "BOARD_ONE", "Chance one crew member boards", 0, 1, 0.01, "Only for crews of 2 or more" },
        { "BOARD_ALL", "Chance the whole crew boards", 0, 1, 0.01, "" },
        { "BREACH_HULL", "Board once the target's hull is below", 0, 1, 0.01, "0.5 = half health" },
        { "FLEE_HULL", 1, "Run away once their own hull is below, boldest crews", 0, 1, 0.01, "0.5 = half health. Each crew rolls between these two" },
        { "FLEE_HULL", 2, "Run away once their own hull is below, most careful crews", 0, 1, 0.01, "" },
        { "GUN_RANGE", "Range of their ship guns (cm)", 1000, 20000, 100, "" },
        { "GUN_CONE", "How far off the nose they fire (degrees)", 5, 90, 1, "" },
    })
    -- Your ship's speed (#207, #459: shipspeed.lua)
    add(ships, require("shipspeed").CFG, {
        { "RUSTBUCKET_SPEED", "Your Rustbucket's top speed (x)", 0.5, 3, 0.05, "1 = the game's 1000 cm/s. Very fast ships outrun rival AI and ram hard" },
        { "RUSTBUCKET_ACCEL", "Your Rustbucket's acceleration (x)", 0.5, 4, 0.1, "1 = the game's" },
        { "BOOST_SPEED", "Helm boost: top speed (x)", 1, 4, 0.1, "Space at the helm of any frigate" },
        { "BOOST_ACCEL", "Helm boost: acceleration (x)", 1, 8, 0.5, "" },
        { "BOOST_SECONDS", "Helm boost: how long (seconds)", 1, 15, 1, "" },
        { "BOOST_COOLDOWN", "Helm boost: cooldown (seconds)", 0, 60, 1, "Counted from the end of the boost" },
    })
    tabs[#tabs + 1] = ships
    -- Ship turrets: every crew's gunnery, rivals' and your gunner's (rivals.lua gunAim). Skill 0 = green, 1 = crack.
    local guns = { name = "Ship guns" }
    add(guns, X.RCFG, {
        { "GUN_SKILL", 1, "Rival gunners' skill, lowest", 0, 1, 0.01, "0 = beginner, 1 = expert. Each crew gets a skill between these. Next raid" },
        { "GUN_SKILL", 2, "Rival gunners' skill, highest", 0, 1, 0.01, "" },
        { "TURRET_SPREAD", "Shell spread, all turrets", 0, 4, 0.05, "1 = normal. 0 = every shell goes exactly where it's aimed" },
        { "GUN_SPREAD_SKILL", 1, "Shell spread for a beginner", 0, 4, 0.05, "" },
        { "GUN_SPREAD_SKILL", 2, "Shell spread for an expert", 0, 4, 0.05, "" },
        { "GUN_FIRST_MISS", "How far the first shots miss (degrees)", 0, 20, 0.25, "For a beginner, on a new target. Experts miss by about a third of this" },
        { "GUN_SETTLE", "How fast they correct their aim", 0, 1, 0.01, "Higher = they find the range in fewer shots" },
        { "GUN_LEAD_ERROR", "How badly they aim ahead of a moving ship", 0, 1, 0.01, "0 = perfectly" },
        { "GUN_JINK", "How much your turning throws them off", 0, 5, 0.05, "Higher = dodging by turning works better" },
        { "GUN_WANDER", "How much their aim drifts (degrees)", 0, 6, 0.05, "" },
        { "TURRET_SWING", "Turret turning speed", 0.5, 10, 0.1, "1 = normal" },
        { "GUNNER_ARC", "How far your gunner turns your turrets (degrees to each side)", 30, 180, 5, "" },
        { "GUNNER_RANGE", "Your gunner's range", 0.5, 3, 0.05, "x each turret's normal range. 1 = same as rival gunners" },
        { "GUNNER_PITCH_SLACK", "How far above or below your gunner still fires (degrees)", 0, 75, 1, "Past what the barrels can tilt" },
        { "TURRET_ON_AIM", "How close to on-target before firing (degrees)", 0.5, 10, 0.1, "Lower = gunners wait for a better shot" },
    })
    tabs[#tabs + 1] = guns
    -- Your guns' recoil (recoil.lua, #371). Read when you next hold a gun, so a change shows at once.
    local recoil = { name = "Recoil" }
    add(recoil, require("recoil").CFG, {
        { "RECOIL_MULT", "Recoil, all guns", 0, 2, 0.05, "1 = the game's own. Lower = less climb on every gun" },
        { "REF_INTERVAL", "Full recoil up to this fire rate (seconds between shots)", 0.06, 0.2, 0.005, "0.12 = 500 RPM. Faster guns climb less, by how much faster" },
        { "MIN_SCALE", "Least recoil for the fastest guns", 0.2, 1, 0.05, "1 = fire rate makes no difference" },
        { "RECOIL_ADS_MULT", "Recoil while aiming down sights", 0, 2, 0.05, "The aim kick only happens in ADS; hip fire is not changed" },
    })
    tabs[#tabs + 1] = recoil
    if X.CREWCFG and X.hire then
        local mates = { name = "Your crew" }
        add(mates, X.CREWCFG, {
            { "FOLLOW_NEAR", "How close they stay to you (cm)", 150, 1000, 10, "" },
            { "LEASH", "How far they'll go from you in a fight (cm)", 800, 6000, 100, "Past this they stop fighting and come back to you" },
            { "GUN_REACT", 1, "Gunner's time to start shooting, fastest (seconds)", 0, 5, 0.1, "On your ship's turrets, at a new target" },
            { "GUN_REACT", 2, "Gunner's time to start shooting, slowest (seconds)", 0, 5, 0.1, "" },
            { "GUN_SKILL", 1, "Gunner's skill at crew level 1", 0, 1, 0.01, "0 = beginner, 1 = expert" },
            { "GUN_SKILL", 2, "Gunner's skill at crew level 5", 0, 1, 0.01, "" },
            { "GUN_TALENT", "How much gunners differ from each other", 0, 1, 0.01, "0 = all the same at the same level" },
        })
        add(mates, X.hire.CFG, {
            { "BASE_HP", "Health at crew level 1", 100, 600, 10, "Enemies have 100" },
            { "HP_PER_LEVEL", "Extra health per crew level", 0, 100, 5, "" },
        })
        for _, k in ipairs({ { "miss", "Misses", 0, 1.5 }, { "reaction", "Reaction time", 0, 1.5 }, { "spotTime", "Time to spot enemies", 0, 1.5 } }) do
            add(mates, X.hire.CFG.EDGE, {
                { k[1], 1, k[2] .. " compared to rivals, crew level 1", k[3], k[4], 0.05, "1 = the same as a rival. Lower = better than a rival" },
                { k[1], 2, k[2] .. " compared to rivals, crew level 5", k[3], k[4], 0.05, "" },
            })
        end
        tabs[#tabs + 1] = mates
    end
    -- Effects: bullet holes the offline game never makes (bulletholes.lua). Read as shots land, so a change shows at once.
    local fx = { name = "Effects" }
    add(fx, require("bulletholes").CFG, {
        { "BULLET_HOLES", "Bullet holes in walls and floors", 0, 1, 1, "1 = on, 0 = off. Concrete, metal, wood, glass and snow. Blood on a bot is the game's own" },
        { "HOLE_SECONDS", "How long a bullet hole lasts (seconds)", 10, 300, 5, "Then it fades out" },
        { "MAX_HOLES", "Most bullet holes at once", 0, 500, 10, "The oldest go first. Lower = better frame rate in long firefights" },
        { "HOLE_SIZE", "Bullet hole size (cm, half width)", 2, 12, 0.5, "5 = a 10 cm hole" },
    })
    add(fx, require("gatetaps").CFG, {
        { "GATE_TAPS", "Gate superstition: two taps", 0, 1, 1, "1 = tap Space exactly twice just before the space gate and a gold coin lands in your gift box (once or three times: only a remark). 0 = off" },
        { "TAP_WINDOW", "Gate taps count this far back (seconds)", 2, 15, 1, "How long before entering the gate a Space press still counts" },
    })
    tabs[#tabs + 1] = fx
    -- Features (#324): whole parts of the mod on or off (features.lua). Each reads its switch as it runs.
    local feats = { name = "Features" }
    add(feats, require("features"), {
        { "DEATH_SCREEN", "Death screen: who killed you", 0, 1, 1, "1 = on, 0 = off. After a death: who shot you, with what, from how far" },
        { "LORE_LOADING", "Lore line on the loading screen", 0, 1, 1, "1 = on, 0 = off" },
        { "LORE_ARRIVAL", "Lore line when you reach a place", 0, 1, 1, "1 = on, 0 = off. Shown on the minimap for a few seconds" },
        { "MAP_KILLS", "Minimap: where your kills fell", 0, 1, 1, "1 = on, 0 = off" },
        { "MAP_DROPS", "Minimap: where you dropped things", 0, 1, 1, "1 = on, 0 = off" },
        { "MAP_CREW", "Minimap: your crewmates", 0, 1, 1, "1 = on, 0 = off" },
        { "FRAME_LOG", "Frame times in the log", 0, 1, 1, "1 = on, 0 = off. Helps us find stutter: please leave it on if you report one" },
        { "VENDOR_STOCK", "Traders sell more gear", 0, 1, 1, "1 = on, 0 = off. Most guns, armour, helmets and bags, unlocked by faction level (boss gear stays loot). Turning it off needs a restart" },
        { "VENDOR_PRICE", "Trader prices (%)", 50, 400, 25, "100 = the game's prices. Higher makes buying a pricier route than looting; your faction discount still applies" },
        { "BUSY_START", "Busy start: rivals come at you sooner", 0, 1, 1, "1 = on, 0 = off. Rival crews launch within 15 s, the first ship fight comes after 5-15 s, and one crew attacks you after 15 s of flying. On by default: players asked for faster action. Takes effect next raid" },
        { "CREW_HUD", "Crew health readout in raids", 0, 1, 1, "1 = on, 0 = off. Each crewmate's name and health % (or down) at the left of the screen while you have crew in the raid" },
        { "SORT_FADE", "Stash SORT: black screen while sorting", 0, 1, 1, "1 = on, 0 = off. Hides the items jumping around while the stash sorts; gone after 8 s at most" },
        { "FOV", "Field of view (degrees)", 0, 120, 1, "0 = the game's own. 70-120 widens or narrows the view (values under 70 count as 70). Untested (#328)" },
        { "ADS_ZOOM", "Aim zoom", 0, 1, 0.05, "1 = the game's zoom when aiming, 0 = no FOV change when aiming, between = less zoom. Untested (#328)" },
        { "HINTS", "First-time hints", 0, 1, 1, "1 = on, 0 = off. A short line on screen the first time you reach the lobby, a raid, the helm, a mine or hire crew; each once per save" },
        { "KEEP_PROGRESS_ON_DEATH", "Keep contract progress when you die", 0, 1, 1, "1 = on, 0 = off. A death ends the raid as a disconnect so contracts, campaign and XP count; your gear is still lost. Untested (#361)" },
    })
    tabs[#tabs + 1] = feats
    tabs[#tabs + 1] = { name = "Saved setups", rows = {}, mine = true }
end

local function load()
    local f = io.open(SAVE_FILE, "r")
    if not f then return 0 end
    local saved = {}
    for line in f:lines() do
        local id, v = line:match("^(.-)=(.-)$")
        if id and tonumber(v) then saved[id] = tonumber(v) end
    end
    f:close()
    local n = 0
    for _, r in ipairs(rows) do
        local v = stored(saved, r)
        if v then set(r, v) n = n + 1 end
    end
    return n
end

local dirtyAt

local function save()
    dirtyAt = nil
    local f = io.open(SAVE_FILE, "w")
    if not f then return X.log("tuning: can't write " .. SAVE_FILE) end
    for _, r in ipairs(rows) do
        -- a raid condition (conditions.lua) changes some settings for one raid: what's saved is your own value
        local v = get(r)
        if X.base then v = X.base(r.t, r.k, r.i, v) end
        if v ~= r.default then f:write(r.id, "=", tostring(v), "\n") end
    end
    f:close()
end

-- Your presets, one file: "[name]" then id=value lines, only what differs from the defaults. Like SAVE_FILE, that lets a
-- new default in the code reach whatever a preset didn't change. A preset is everything, tuning included.
local function loadMine()
    mine = {}
    local f = io.open(PRESET_FILE, "r")
    if not f then return end
    local cur
    for line in f:lines() do
        local name = line:match("^%[(.*)%]$")
        local id, v = line:match("^(.-)=(.-)$")
        if name then
            cur = { name = name, values = {} }
            mine[#mine + 1] = cur
        elseif cur and id and tonumber(v) then
            cur.values[id] = tonumber(v)
        end
    end
    f:close()
end

local function saveMine()
    local f = io.open(PRESET_FILE, "w")
    if not f then return X.log("tuning: can't write " .. PRESET_FILE) end
    for _, m in ipairs(mine) do
        f:write("[", m.name, "]\n")
        for id, v in pairs(m.values) do f:write(id, "=", tostring(v), "\n") end
    end
    f:close()
end

function T.init(ctx)
    X = ctx
    define()
    for _, r in ipairs(rows) do r.default = get(r) end
    local n = load()
    loadMine()
    local okS, errS = pcall(writeSchema)
    if not okS then X.log("tuning: settings list for the launcher not written: " .. tostring(errS)) end
    X.log(("tuning: %d settings, %d changed from the defaults, %d saved presets (F10 in a raid)"):format(#rows, n, #mine))
end

-- A setting by its id (as in config/ai_tuning.txt, e.g. "Crews:BARON" or "Spawns:CREW_SIZE.2"): the table, key and
-- index it lives at, for conditions.lua. nil if there's no such setting.
function T.row(id)
    for _, r in ipairs(rows) do
        if r.id == id or r.oldId == id then return r.t, r.k, r.i end
    end
end

-- The menu ------------------------------------------------------------------------------------------------------
local showPreset, showMine -- forward
local ui -- { host, tree, root, scroll, tabButtons, rows, footer, tab }

local function make(cls)
    return StaticConstructObject(X.lib("/Script/UMG." .. cls), ui.tree)
end

local function text(s, size, opacity)
    local t = make("TextBlock")
    t.Font.Size = size or TEXT -- (SetFont can't take the struct back from Lua; this is read when the widget is built)
    t:SetText(FText(s))
    if opacity then t:SetOpacity(opacity) end
    return t
end

local function place(widget, x, y, w, h)
    local slot = ui.root:AddChildToCanvas(widget)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
    return slot
end

local function button(label)
    local b = make("Button")
    b:AddChild(text(label, SMALL))
    return b
end

local function fmt(r, v)
    if r.step >= 1 then return string.format("%.0f", v) end
    if r.step >= 0.1 then return string.format("%.1f", v) end
    return string.format("%.2f", v)
end

local function caption(r, v)
    return r.label .. ":  " .. fmt(r, v) .. (v ~= r.default and "   (normally " .. fmt(r, r.default) .. ")" or "")
end

local function showTab(i)
    ui.tab, ui.rows = i, {}
    ui.scroll:ClearChildren()
    for j, b in ipairs(ui.tabButtons) do b.b:SetBackgroundColor(j == i and { R = 0.9, G = 0.35, B = 0.1, A = 1 } or { R = 0.35, G = 0.35, B = 0.35, A = 1 }) end
    ui.mineButtons = nil
    ui.footer[1].b:SetIsEnabled(not tabs[i].mine) -- nothing to reset on that tab
    if tabs[i].mine then return showMine() end
    for _, r in ipairs(tabs[i].rows) do
        local box = make("VerticalBox")
        local label = text(caption(r, get(r)))
        box:AddChild(label)
        if r.help and r.help ~= "" then box:AddChild(text(r.help, SMALL, 0.65)) end
        local s = make("Slider")
        s:SetMinValue(r.min)
        s:SetMaxValue(r.max)
        s:SetStepSize(r.step)
        s:SetValue(get(r))
        box:AddChild(s)
        box:AddChild(text(" ", 6))
        ui.scroll:AddChild(box)
        ui.rows[#ui.rows + 1] = { r = r, label = label, slider = s, shown = get(r) }
    end
    ui.scroll:SetScrollOffset(0)
end

local function build(pc)
    local lib = X.lib
    local cls = lib(HOST)
    if not X.valid(cls) then
        pcall(LoadAsset, (HOST:match("^[^.]+")))
        cls = lib(HOST)
    end
    if not X.valid(cls) then return X.log("tuning: no host widget") end
    local host = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not X.valid(host) then return X.log("tuning: couldn't create the menu") end
    ui = { host = host, tree = host.WidgetTree, root = host.WidgetTree.RootWidget, tabButtons = {}, footer = {},
        presets = {} }
    ui.root:ClearChildren()
    local layout = lib("/Script/UMG.Default__WidgetLayoutLibrary")
    local H = math.min(MAX_H, layout:GetViewportSize(pc).Y / layout:GetViewportScale(pc) - 2 * Y0)
    local bg = make("Border")
    bg:SetBrushColor({ R = 0.03, G = 0.03, B = 0.04, A = 0.93 })
    place(bg, X0, Y0, W, H)
    place(text("Enemy and crew settings   (F10 to close. Changes work at once and save themselves)", TEXT), X0 + 16, Y0 + 10, W - 32, 26)
    -- two rows of tabs (the difficulty buttons sit below them)
    local perRow = math.max(6, math.ceil(#tabs / 2))
    local x, y, each = X0 + 16, Y0 + 42, (W - 32) / perRow
    for i, t in ipairs(tabs) do
        local b = button(t.name)
        place(b, x, y, each - 4, 30)
        ui.tabButtons[i] = { b = b }
        x = x + each
        if i == perRow then x, y = X0 + 16, y + 34 end
    end
    ui.presetLabel = text("Difficulty", SMALL)
    place(ui.presetLabel, X0 + 16, Y0 + 122, 150, 24)
    for i, p in ipairs(PRESETS) do
        local b = button(p.name)
        place(b, X0 + 170 + (i - 1) * 145, Y0 + 116, 139, 30)
        ui.presets[i] = { b = b }
    end
    ui.scroll = make("ScrollBox")
    place(ui.scroll, X0 + 16, Y0 + 154, W - 32, H - 214)
    local labels = { { "Undo changes on this tab", "tab" }, { "Undo all changes", "all" }, { "Close", "close" } }
    for i, l in ipairs(labels) do
        local b = button(l[1])
        place(b, X0 + 16 + (i - 1) * ((W - 32) / 3), Y0 + H - 48, (W - 32) / 3 - 6, 34)
        ui.footer[i] = { b = b, act = l[2] }
    end
    host:AddToViewport(5000) -- above the lobby's own pages, like the crew menu
    showPreset()
    showTab(1)
    return true
end

-- What a preset wants for this row, or nil when presets leave it alone.
local function presetValue(r, p)
    local v
    if r.perProfile then
        local names = false
        for _, q in ipairs(PRESETS) do names = names or q.profile[r.k] ~= nil end
        if not names then return nil end
        local m = p.profile[r.k] or 1
        if m == 1 then return r.default end -- exact: a default needn't sit on the slider's step
        v = r.default * m
    elseif r.t == X.CFG then
        local used = false
        for _, q in ipairs(PRESETS) do used = used or q.aim[r.k] ~= nil end
        if not used then return nil end
        if p.aim[r.k] == nil then return r.default end
        v = p.aim[r.k]
    else
        return nil
    end
    v = math.floor(v / r.step + 0.5) * r.step
    return tonumber(string.format("%.4f", math.max(r.min, math.min(r.max, v))))
end

-- JSON for the launcher: strings, numbers, booleans, arrays (sequential tables) and objects.
local function json(v)
    local t = type(v)
    if t == "number" then return (v ~= v or v == math.huge or v == -math.huge) and "0" or tostring(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "string" then
        local esc = v:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
            return string.format("\\u%04x", c:byte())
        end)
        return '"' .. esc .. '"'
    end
    if t == "table" then
        local out = {}
        if #v > 0 or next(v) == nil then
            for _, x in ipairs(v) do out[#out + 1] = json(x) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do out[#out + 1] = json(k) .. ":" .. json(v[k]) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

writeSchema = function()
    local out = { version = 1, tabs = {}, presets = {} }
    for _, tab in ipairs(tabs) do
        if not tab.mine then
            local list = {}
            for _, r in ipairs(tab.rows or {}) do
                local d = r.default -- (taken before any saved value or raid condition was applied)
                list[#list + 1] = { id = r.id, label = r.label or r.id, min = r.min, max = r.max, step = r.step,
                    default = d, help = r.help or "" }
            end
            out.tabs[#out.tabs + 1] = { name = tab.name, rows = list }
        end
    end
    for _, p in ipairs(PRESETS) do
        local values = {}
        for _, r in ipairs(rows) do
            local v = presetValue(r, p)
            if v ~= nil and v ~= r.default then values[r.id] = v end
        end
        out.presets[#out.presets + 1] = { name = p.name, values = values }
    end
    local f = io.open(SCHEMA_FILE, "w")
    if not f then return X.log("tuning: can't write " .. SCHEMA_FILE) end
    f:write(json(out))
    f:close()
end

-- Which preset the current values match (nil: tuned by hand).
local function activePreset()
    for i, p in ipairs(PRESETS) do
        local match = true
        for _, r in ipairs(rows) do
            local v = presetValue(r, p)
            if v and math.abs(get(r) - v) >= r.step / 2 then match = false break end
        end
        if match then return i end
    end
end

showPreset = function()
    local active = activePreset()
    for i, b in ipairs(ui.presets) do
        b.b:SetBackgroundColor(i == active and { R = 0.9, G = 0.35, B = 0.1, A = 1 } or { R = 0.35, G = 0.35, B = 0.35, A = 1 })
    end
    ui.presetLabel:SetText(FText(active and "Difficulty" or "Difficulty (changed)"))
end

local function changed()
    dirtyAt = os.clock()
    if X.applied then X.applied() end
    if ui then showPreset() end
end

local function applyPreset(i)
    for _, r in ipairs(rows) do
        local v = presetValue(r, PRESETS[i])
        if v then set(r, v) end
    end
    changed()
    showTab(ui.tab)
end

local function matchesMine(m)
    for _, r in ipairs(rows) do
        local want = stored(m.values, r) or r.default
        if math.abs(get(r) - want) >= r.step / 2 then return false end
    end
    return true
end

-- A name you typed: one line, and no square brackets (they mark a preset in the file).
local function cleanName(name)
    name = (name or ""):gsub("[%[%]%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return name:sub(1, 32)
end

local function saveCurrent(name)
    name = cleanName(name)
    if name == "" then
        local n = #mine + 1
        repeat
            name = "My preset " .. n
            local taken = false
            for _, m in ipairs(mine) do taken = taken or m.name == name end
            n = n + 1
        until not taken
    end
    local values = {}
    for _, r in ipairs(rows) do
        if get(r) ~= r.default then values[r.id] = get(r) end
    end
    local entry
    for _, m in ipairs(mine) do
        if m.name == name then entry = m end
    end
    local said = entry and "Updated " or "Saved "
    if not entry then
        entry = { name = name }
        mine[#mine + 1] = entry
    end
    entry.values = values
    saveMine()
    ui.mineStatus = said .. name
    showTab(ui.tab)
end

local function loadPreset(i)
    local m = mine[i]
    if not m then return end
    for _, r in ipairs(rows) do set(r, stored(m.values, r) or r.default) end
    changed()
    ui.mineStatus = "Loaded " .. m.name
    showTab(ui.tab)
end

local function deletePreset(i)
    local m = table.remove(mine, i)
    if not m then return end
    saveMine()
    ui.confirmDelete = nil
    ui.mineStatus = "Deleted " .. m.name
    showTab(ui.tab)
end

showMine = function()
    ui.mineButtons = {}
    local top = make("VerticalBox")
    top:AddChild(text("Save the current settings", TEXT))
    top:AddChild(text("Keeps all your settings under a name, to load again later. Using a name again replaces it.", SMALL, 0.65))
    ui.nameBox = make("EditableTextBox")
    ui.nameBox:SetHintText(FText("Name"))
    top:AddChild(ui.nameBox)
    local save = button("Save")
    top:AddChild(save)
    ui.mineButtons[#ui.mineButtons + 1] = { b = save, act = "save" }
    top:AddChild(text(ui.mineStatus or " ", SMALL, 0.8))
    top:AddChild(text(" ", 6))
    ui.scroll:AddChild(top)
    if #mine == 0 then ui.scroll:AddChild(text("Nothing saved yet.", SMALL, 0.65)) end
    for i, m in ipairs(mine) do
        local box = make("VerticalBox")
        box:AddChild(text(m.name .. (matchesMine(m) and "   (active)" or ""), TEXT))
        local row = make("HorizontalBox")
        local load = button("Load")
        local del = button(ui.confirmDelete == i and "Click again to delete" or "Delete")
        for _, b in ipairs({ load, del }) do
            row:AddChildToHorizontalBox(b):SetPadding({ Left = 0, Top = 2, Right = 8, Bottom = 2 })
        end
        box:AddChild(row)
        box:AddChild(text(" ", 6))
        ui.scroll:AddChild(box)
        ui.mineButtons[#ui.mineButtons + 1] = { b = load, act = "load", i = i }
        ui.mineButtons[#ui.mineButtons + 1] = { b = del, act = "delete", i = i }
    end
    ui.scroll:SetScrollOffset(0)
end

local function reset(list)
    for _, r in ipairs(list) do set(r, r.default) end
    changed()
    showTab(ui.tab)
end

function T.isOpen() return ui ~= nil and ui.open == true and X.valid(ui.host) end

-- Testing without the mouse (bridge/menu_toggle holding a line): "tab N", "preset N", "reset", "resetall", "set <id> <value>" (the
-- id as in the save file; works with the menu closed and is applied at once).
function T.command(line)
    local id, value = line:match("^set (%S+) (%S+)")
    if id then
        for _, r in ipairs(rows) do
            if r.id == id or r.oldId == id then set(r, tonumber(value)) end
        end
        return changed()
    end
    if not T.isOpen() then return end
    local n = line:match("^tab (%d+)")
    local preset = line:match("^preset (%d+)")
    local savedName = line:match("^save ?(.*)$")
    local loaded, deleted = line:match("^load (%d+)"), line:match("^delete (%d+)")
    if savedName then saveCurrent(savedName)
    elseif loaded then loadPreset(tonumber(loaded))
    elseif deleted then deletePreset(tonumber(deleted))
    elseif preset then applyPreset(tonumber(preset))
    elseif n then showTab(tonumber(n))
    elseif line:find("^resetall") then reset(rows)
    elseif line:find("^reset") then reset(tabs[ui.tab].rows) end
end

function T.close(pc)
    if not T.isOpen() then return end
    ui.open = false
    ui.host:SetVisibility(1) -- Collapsed
    X.menuClosed(pc)
    if dirtyAt then save() end
end

function T.toggle(pc)
    if T.isOpen() then return T.close(pc) end
    if ui and not X.valid(ui.host) then ui = nil end -- the world it was built in is gone
    if not ui and not build(pc) then return end
    ui.open = true
    ui.host:SetVisibility(0) -- Visible
    pc.bShowMouseCursor = true
    X.lib("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, ui.host, 0)
end

-- Every frame while open: nothing can be bound from Lua, so this watches the sliders and buttons.
function T.tick(pc)
    if dirtyAt and os.clock() - dirtyAt >= SAVE_DELAY then save() end
    if not T.isOpen() then return end
    for _, row in ipairs(ui.rows) do
        local v = row.slider:GetValue()
        if math.abs(v - row.shown) >= row.r.step / 2 then
            v = math.floor(v / row.r.step + 0.5) * row.r.step
            row.shown = v
            set(row.r, tonumber(string.format("%.4f", v)))
            row.label:SetText(FText(caption(row.r, get(row.r))))
            changed()
        end
    end
    local function pressed(b)
        local down = b.b:IsPressed()
        local click = b.down and not down -- on release, like a real button
        b.down = down
        return click
    end
    for i, b in ipairs(ui.tabButtons) do
        if pressed(b) then return showTab(i) end
    end
    for i, b in ipairs(ui.presets) do
        if pressed(b) then return applyPreset(i) end
    end
    for _, b in ipairs(ui.mineButtons or {}) do
        if pressed(b) then
            if b.act == "save" then return saveCurrent(ui.nameBox:GetText():ToString()) end
            if b.act == "load" then return loadPreset(b.i) end
            if ui.confirmDelete == b.i then return deletePreset(b.i) end
            ui.confirmDelete = b.i
            return showTab(ui.tab)
        end
    end
    for _, b in ipairs(ui.footer) do
        if pressed(b) then
            if b.act == "tab" then return reset(tabs[ui.tab].rows) end
            if b.act == "all" then return reset(rows) end
            return T.close(pc)
        end
    end
end

-- A new world: the old one took the widgets with it, so they're dropped untouched.
function T.reset()
    if dirtyAt then save() end
    ui = nil
end

return T
