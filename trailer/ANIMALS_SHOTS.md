# Public test trailer: what to capture

Cut to the whole of Architects "Animals", uncut (4:04). Edit script: `trailer/make_animals.py` (`--list` shows every shot, its timecode and
whether it's recorded yet; `--draft` renders a quick preview with stand-ins and grey slates for the gaps).

## Your part: first person and menus

Record with `trailer/session.sh` running (60 fps chunks in `trailer/session/`), play normally, and tell me roughly when
each moment happened. HUD on is fine for first person. Most shots are 0.6-2.5 s on screen, so one good second matters
more than a long take. Turn on god mode first (`echo on > bridge/god.txt`) so a bad moment doesn't end the take.

| Shot | What I need | On screen |
|---|---|---|
| fp_gunseat | You in a turret seat, shells landing on a rival ship | 2.5 s + drop montage |
| **You board them** | | |
| fp_pod_launch | Launching a drop pod from your ship at a rival | 2.5 s |
| fp_pod_impact | The pod hitting their hull | 1.3 s |
| fp_board_breach | Breaching into the rival ship: first step in | 2.5 s |
| fp_board_fight, fp_board_fight2, fp_board_fight3, fp_board_clear | Fighting their crew through their ship, room by room, last one down | 1.3 s each |
| fp_board_helm | Walking up to their helm and taking it | 2.5 s |
| fp_steal_fly | Flying the stolen ship away (cockpit or chase view) | 2.5 s |
| **They board you** (provoke with F4 or `bridge/rivals_board`) | | |
| fp_breach_alarm | The breach alarm going off on your ship, you turning to face it | 2.5 s |
| fp_repel1, fp_repel2, fp_repel3 | Fighting boarders in your own corridors, ideally with your crew there | 2.5 s each |
| fp_repel_last | The last boarder down, ship quiet again | 2.5 s |
| **Fights and kills** | | |
| fp_fight1, fp_fight2, fp_fight3 | Pushing a corridor, peeking a corner, a station firefight | 2 s each |
| fp_kill1-8 | Eight different kills: headshots, bodies dropping, close range. Variety of guns and rooms | 0.6 s each, cut on the beat |
| fp_killlist | The kill list on screen after a few kills | 0.6 s |
| fp_crew_follow | Your hired crew moving with you through a station (look back at them) | 2.5 s |
| fp_loot_body, fp_loot_crate | Looting a body; opening a container | 0.6 s each |
| fp_extract_gate | Flying into the space gate and the jump | 2.5 s |
| fp_raid_start | The raid loading screen into the start of a raid | 2.5 s |
| **Menus** (each now gets its own 2.5 s shot with a caption, plus quick cuts later) | | |
| m_female_orbit | A woman in one of the women's outfits: character screen or lobby, ideally slowly turning | 5 s (the song's quiet break) |
| m_lobby_crew | Lobby with your hired crew on their stands | 3 s |
| m_hire | The hiring page, picking someone | 2.5 s |
| m_contracts | The main contracts screen, picking a contract and its detail | 2.5 s + 2 stabs |
| m_minimap | The task map: full overview (M) with a route drawn to a contract | 2.5 s |
| m_traders | A trader: buying something, then selling something | 2.5 s + 2 stabs |
| m_shipshop | The ship shop, looking over / buying a hull | 2.5 s + stab |
| m_level | Level / XP going up after a raid | 2.5 s + stab |
| m_stash | The stash, reasonably full; hover a couple of items | 2.5 s + 4 stabs |
| m_ai_menu | The AI menu (F3): the difficulty preset row, then flick through a few tabs | 2.5 s |
| m_ai_presets | The My presets tab: typing a name and saving | 2.5 s |
| m_launcher | The launcher with a few saves (I can grab this myself) | 2.5 s |
| m_newsave | The new-save dialog with a stash size typed in (I can grab this too) | 2.5 s |

## My part: AI and space shots (trailer camera, no HUD)

Recorded with `bridge/cine.lua` + `trailer/rec.sh`:
- Ships: a_open, a_chase1/2/3, a_duel1/2, a_orbit_fight, a_rockets, a_hit, a_burn/2, a_battle_wide/top/high, a_drift,
  a_crew_gunner, a_ship_ok.
- Pods and boarding from outside: a_pods, a_pods2 (rivals boarding each other), a_captured (the taken ship leaving),
  a_pod_player (your pod), a_pods_incoming (pods at your ship), a_stolen_leave.
- The world: a_map1-4 (one station per map, different types), a_rival_dock, a_rival_extract, a_breach_ship.
- On foot: a_rival_airlock, a_inf_fight1/2, a_inf_cover, a_inf_search, a_inf_peek, a_kill1-5, a_crew_fight,
  a_repel_crew (your crew vs boarders on your ship), a_rival_geared.

## Feature coverage (from NOTES.md, 2026-11-14)

What a player would care about, and where the trailer shows it. Everything below now has a slot in the edit.

| Feature | In the trailer now | Proposal |
|---|---|---|
| Plays offline, no servers; saves on your PC (launcher, save slots) | m_launcher, m_newsave | - |
| Rival crews flying their own ships, 26 designs, real turrets | Ship section, captions | - |
| Ambient ship battles, rivals fighting each other | a_orbit_fight | - |
| Manning a turret; crew gunner | fp_gunseat, a_crew_gunner | - |
| Drop pods: boarding by pod, rivals podding each other and you | a_pods, a_pods_incoming, fp_pod_launch | - |
| Boarding and stealing rival ships, keeping them | fp_board_*, fp_steal_fly | - |
| Rivals board each other and capture ships | a_pods, a_captured | - |
| Stations: docking, guards, rival crews arriving by airlock, three-way fights | a_dock_arrive, a_rival_airlock, a_inf_fight1 | - |
| Six maps (2 solo, 4 crew maps), many station types (Rebel Base, Asteroid Mine, Penal Colony, Capital Ship, Mini Mine, Colony Cruiser, Spaceport) | a_map1-4 | - |
| Smarter AI: cover, peeking, hearing, personalities, searching | a_inf_cover caption | - |
| Difficulty presets, 121-setting AI menu, your own presets | m_ai_menu, m_ai_presets | - |
| Hired crew: levels, promotions, wages, permadeath, own voices | m_hire, fp_crew_follow, a_crew_fight caption | - |
| Missions and contracts work offline | m_contracts | - |
| Task minimap with routes to every contract | m_minimap | - |
| Traders, ship shop, levels, stash with a size you pick | m_traders, m_shipshop, m_level, m_stash, m_newsave | - |
| Rival gear scales with your level (not gear unlocks: the old "BETTER GEAR" stab was wrong) | a_rival_geared | - |
| Rivals board YOU, you fight them off | a_pods_incoming, fp_breach_alarm, fp_repel*, a_repel_crew | - |
| Kill list counts rival crews | fp_killlist + caption | - |
| Women's versions of every outfit; women among rivals and crew | m_female_orbit | - |
| Space gate extraction | fp_extract_gate | - |

## Old footage still in the edit (to replace)

From the first trailer (11-01) or before today's ship AI fixes: a_open (s01_myship), a_dock_arrive (s07_docked),
a_breach_ship (s08_defender), a_rival_airlock (s09_rival), a_inf_fight1/2 and a_kill1 (s10_firefight), a_chase1,
a_duel1, a_hit (filmed with the old ramming AI), a_battle_wide, a_battle_high, a_drift (before the turret fix),
fp_loot_body/crate (s12/s13), fp_extract_gate (escaped), and every fp_ slot cut from the 11-01 play session
(play_0937_*). New today: c_b1, c_b2, c_c1, c_c2, c_c5.

Reshoot order: 1) ships in open space (me, you flying): chase, duel, wide battle, top-down, your ship leaving, rivals
podding each other, a captured ship; 2) boarding, both ways (together): rivals pod your ship (I film a_pods_incoming,
you record the alarm and the fight inside), then you pod a rival (I film your pod, you record the breach, fight, helm,
flying away); 3) a station with rivals (you docked): docking, airlock arrivals, guard fights, cover, searching, kills,
your crew fighting; 4) map flybys (me, a raid per map); 5) your menu list above.

## Take notes
- a_duel_n5: mouse cursor visible (around 1:32 of new_footage_preview.mp4). Do not use, or use only the frames without it.
- fp_repel_take1: they board you, all five repelled, back at the helm. Good.
- fp_pod_board1: pod launch, flight, breach. Ends inside, so no helm or stolen-ship flight yet.
- fp_steal1 (60 fps, 3:20): pod launch, a great shot of the pod slamming into the Long Odds (~1:40), the fight aboard, then flying it off past the planet and sun. Covers fp_board_helm, fp_steal_fly, a_stolen_leave.
- a_station1 (Asteroid Mine station fight, ~7 min). User: kills are all fine, use freely. Kill/fire windows (s):
  68-73, 79.5-84.5 (slump down wall, best), 88-91, 136-142 (flash/fire), 163.5-168.5 (stairs),
  184.5-188.5, 214.5-218.5, 241.5-244.5, 247.5-250.5 (shotgun), 255.5-259.5 (white suit drops, best).
  Also 239-242 rival walks down lit stairs; 65-66 body + blood. Skip 149-161 (shotgun, user: don't use), loot-UI spans (85-88, 162, 180-190, 224-235) and 264-end (idle).
  Preview reel of all windows: trailer/station_kills_preview.mp4
- m_female_orbit2 (lobby, 50 s, static, no cursor; use this one over orbit1 which has a cursor). Masked by design (no faces in game).
  Lobby UI on all edges: crop to the centre ~960x1080 (x 480-1440) and zoom in; smoke billows best around 18-22 s and 36-44 s.
- m_menus1 (lobby menus, 100 s). Windows (s):
  m_hire 16.4-21.1 (portraits all loaded; menu blinks off 15.9-16.3, so start after; Uri, Yara, Abel signed on).
  traders/shopkeepers 28-34 (24-27 still fading in), market trades 34 and ~40, crafting 36-39,
  m_contracts "Zero to Hero" detail 42-45, m_shipshop 46-53 (hull spinning), weapon inspect (Luger) 54-57, loadout + stash 58-59,
  m_lobby_crew 60-100 (three hired crew on stands behind her, smoke; crop off lobby UI).
- m_stash1 (17 s): secure storage with ~12 items in the top third, lower grid empty, loadout empty. Hovers throughout; drag (green) at ~6-7 s.
  Crop to the storage panel's filled top area (x ~1600-2880 of 2880 sheet scale, i.e. right ~45% of frame, top half).
- fp_raid_map1 (raid, 311 s). fp_raid_start: loading screens 18-36 ("Loading the sector" / "Preparing your ship" / "You're aboard",
  Marauders Offline PvE title) into the cockpit 39-45. User: use map shots only while the ship is moving and the arrow moves:
  m_minimap small map in cockpit 52-56; full overview with route, asteroids behind, ship flying 56-74. Third-person ship in asteroids 75-77.
  78-285 sitting at the console (skip). End-of-raid "You escaped" XP screen ~290-311.
- m_level1 (63 s): "You escaped" XP bar 0-16, LEVEL UP! 8 popup from ~17 s to end (best 17-22).
- a_map takes stalled while recording (mine: 10-36 frame freezes; spaceport ~5 fps throughout). In the edit for now as
  motion-interpolated *_s.mp4 spans; refilm with an unrecorded warm-up orbit first, record the second pass.
- board3 31-33: a crew member pops in right in front of you; don't use. Crew running up the stairs 37-39.5 instead.
- a_map flybys (CINE.orbit of the map's stations from bridge/t_stations.lua, collide=false: the wall check pulls the camera inside a station).
  Space_Solo_02: a_map_penal (21 s, Penal Colony in an asteroid field, orange nebula; a rock sweeps the foreground near the end),
  a_map_capital (21 s, Capital Ship with red lights in front of the Penal Colony, planet behind).
  Space_Alpha (blue planet below, dark rocks): a_map_spaceport (21 s, low side-on; use 0-8 s, rocks cover it after),
  a_map_rebel (21 s, from above with the planet behind; busy with rocks but the base and its rings read throughout).
  A camera high over the Spaceport turns everything red (inside some volume): avoid.
  Space_Beta: a_map_mine (21 s, Asteroid Mine with its rings over the blue planet; clear throughout, best of the Alpha/Beta set).
  Space_Charlie: a_map_planetkiller (21 s, Planet Killer among rocks under the orange nebula, red lights; slow, steady),
  a_map_minimine (21 s, Mini Mine tower on its rock under the nebula; a ring structure sweeps into the foreground from ~10 s, nice depth).
  Space_Delta (dark map, red planet glow below): a_map_navy (21 s, Navy Outpost silhouette with orange lights over the red planet; very dark, lift it in the grade),
  a_map_merchant (21 s, Merchant station traced by red lights over the planet's rim; reads well despite the dark, moody).

## Flyby refilm (2026-11-15)
- Bridge commands run one line at a time: keep each CINE.orbit call on a single line (`STATIONS[n]` inline), or the orbit silently fails.
- Per station: one unrecorded warm-up orbit, then the same orbit recorded. Takes: a_map_mine2 (55 fps, usable 0-20.4 s), a_map_penal2 (52), a_map_spaceport2 (59), a_map_rebel2 (58, spare; Space_Alpha's Rebel Base). a_map4 uses a_map_minimine2 (Space_Solo_02 rolled no Capital Ship); a_map_rebel2 is the spare.
