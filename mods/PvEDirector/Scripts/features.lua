-- Feature switches (#324): 1 = on, 0 = off, for parts of the mod a player may not want. Shown as the "Features" tab in
-- F10 and in the launcher's SETTINGS page (tuning.lua), saved with the other settings. Each feature reads its switch
-- where it runs, so a change in F10 applies at once. Features that already have a "0 turns it off" setting elsewhere
-- (civilians, guards running, ship battles, bullet holes...) keep it there.
return {
    DEATH_SCREEN = 1,   -- deathscreen.lua: who killed you, after a death (#331)
    LORE_LOADING = 1,   -- loading.lua: a line of lore under the raid loading screen's bar (#272)
    LORE_ARRIVAL = 1,   -- minimap.lua: a line of lore the first time you reach a place (#272)
    MAP_KILLS = 1,      -- minimap.lua: an X where enemies you killed fell (#326)
    MAP_DROPS = 1,      -- minimap.lua: a bag where you dropped something (#326)
    MAP_CREW = 1,       -- minimap.lua: your crewmates (#326)
    FRAME_LOG = 1,      -- main.lua: the "frames:" line in the log every 10 s (#336)
}
