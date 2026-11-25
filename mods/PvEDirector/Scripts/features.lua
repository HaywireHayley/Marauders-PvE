-- Feature switches (#324): 1 = on, 0 = off, for parts of the mod a player may not want. Shown as the "Features" tab in
-- F10 and in the launcher's SETTINGS page (tuning.lua), saved with the other settings. Each feature reads its switch
-- where it runs, so a change in F10 applies at once. Features that already have a "0 turns it off" setting elsewhere
-- (civilians, guards running, ship battles, bullet holes...) keep it there.
return {
    DEATH_SCREEN = 1,   -- deathscreen.lua: who killed you, after a death (#331)
    RAID_SUMMARY = 1,   -- raidsummary.lua: kills, crew and progress in the lobby after a raid (#390; untested)
    LORE_LOADING = 1,   -- loading.lua: a line of lore under the raid loading screen's bar (#272)
    LORE_ARRIVAL = 1,   -- minimap.lua: a line of lore the first time you reach a place (#272)
    MAP_KILLS = 1,      -- minimap.lua: an X where enemies you killed fell (#326)
    MAP_DROPS = 1,      -- minimap.lua: a bag where you dropped something (#326)
    MAP_CREW = 1,       -- minimap.lua: your crewmates (#326)
    FRAME_LOG = 1,      -- main.lua: the "frames:" line in the log every 10 s (#336)
    VENDOR_STOCK = 1,   -- vendors.lua: the four traders sell most guns, armour, helmets and bags by faction level (#384)
    VENDOR_PRICE = 100, -- vendors.lua: trader prices, % of the game's (the faction discount still applies) (#384)
    BUSY_START = 1,     -- rivals.lua: crews launch within 15 s, first ship fight in 5-15 s, one crew attacks you after 15 s of flying (#459; on: players asked for faster action)
    CREW_HUD = 1,       -- crew.lua: your crewmates' names and health % at the left of the screen in a raid (#391)
    SORT_FADE = 1,      -- invqol.lua: the screen goes black with "Sorting..." while the stash SORT runs (#468)
    FOV = 0,            -- fov.lua: field of view in degrees, 0 = the game's own (#328; untested)
    ADS_ZOOM = 1,       -- fov.lua: aim zoom, 1 = the game's, 0 = none, between = a blend (#328; untested)
    HINTS = 1,          -- hints.lua: a short line the first time you reach a few moments (lobby, raid, helm, mine, crew), once per save (#389)
    KEEP_PROGRESS_ON_DEATH = 0, -- loadout.lua: a death ends the raid as DISCONNECT so contract/chapter progress is kept (#361; untested, off)
}
