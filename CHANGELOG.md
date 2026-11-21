# Changelog

Public test builds are on [GitHub Releases](https://github.com/HaywireHayley/Marauders-PvE/releases).

## Next build (not released yet)

### Changes

- **A kinder defuse board (#197, PR #301):** every board now opens with a cleared area to start from, so there's no
  blind first click, and the first charge you set off is caught instead of ending it (the next one still blows). The
  board has a new look too: a time bar that turns red, raised cells, and numbers on their classic colours.

## Public test, 21 Nov 2026, build 19 (`public-test-20261121.19`)

Fullscreen that stays fullscreen, and the game's Settings on the title screen and in the lobby. On build 1 of 17 Nov
or later, the launcher's orange **!** installs this one for you, keeping your saves.

### Fixes

- **Window mode sticks (#292, PR #294):** loading into a raid put the game back into a small window, and fullscreen
  picked in Settings reverted. The launcher used to force the window with `-windowed`, which the game re-applies on
  every map load. It now sets the window in the game's own video settings instead, once (on the first launch after a
  change of the launcher's "Borderless fullscreen" box). After that, whatever you pick in the game's Settings
  (Fullscreen, Borderless, Windowed, resolution) stays, across raids and launches. The "Borderless fullscreen" box now
  works too: the game used to overwrite it from its own settings.
- **Settings outside a raid (#293, PR #296):** the game's Settings (video, audio, gameplay, controls) could only be
  opened from the Esc menu in a raid. There's now a **SETTINGS** button on the title screen (after EXIT and PLAY) and a
  **SETTINGS** tab in the lobby's top bar (before QUIT). The lobby tabs are a little narrower so all seven fit.
- **A log error at lobby start (#297, PR #298):** the mod asked a lobby widget whether it was the local player, which
  only a player controller can answer. Nothing broke, but it logged a native error each session.

## Public test, 20 Nov 2026, build 18 (`public-test-20261120.18`)

Repair your ship with the blowtorch, take nuclear mines home to the hold, find survivors (and loot) in wrecked ships,
and a hidden Blood Raider outfit. On build 1 of 17 Nov or later, the launcher's orange **!** installs this one for you,
keeping your saves.

### Changes

- **One small download to install (PR #287):** new players on Windows download just
  `MaraudersOffline-20261120.18-installer.zip` (a few KB): its `Install.bat` downloads this build and every part it
  needs from GitHub, checks each file, and installs them, then sets up as usual. The other zips are still there for
  Linux and for installing by hand.
- **README (PR #288):** how to install and update now, this week's features, the controls for mines and repairs (also in
  the launcher's CONTROLS), and the issues still open.
- **Blood Raider outfit (#228, #230, PR #271):** the game files hold one outfit that no menu lists, a bloodied Raider
  suit that goes with the free Nomad Blood Head. **F9 in the lobby > Hidden outfit** now cycles the brown coat, the black
  coat and the Blood Raider; it shows in raids too, and picking any look in Appearance takes it off. The same search
  found no Ranger, Early Access or pre-order skins in the game files (#231).
- **Wrecks aren't empty any more (#251, PR #275):** a rival ship shot down now holds the crew who went down with it, as
  corpses you can loot, and half the time one or two of them survived, hurt, and fight you when you board.
- **Nuclear mines go in the hold (#197, PR #276):** at the helm by a nuclear mine, **R** takes it aboard (no ToolKit
  needed). On foot in the hold, **F** with a ToolKit opens the nuclear board: win for its parts and the nuclear material
  (gift box); lose and it goes off in the hold, killing you and wrecking your ship. Small mines are still defused in
  place from the helm.
- **Your gunner on a ship you took (#70, PR #279):** after you took a rival's ship, your crew gunner found no turrets
  on it ("mans 0 turrets"). They now man its turrets.
- **Repair your ship with the blowtorch (#70, PR #282):** a ship shot to 0 hull is disabled (its life support broken)
  and used to stay that way offline. Fire the **Blowtorch** at a part of your ship (the life-support pipe in the engine
  room, the helm gun, the engine): broken parts come back first, then the hull rises until the ship can fly, up to full.
  It uses the torch's charge. A rival wreck you board and take now needs the same repair before it flies. Its smoke
  and fire go out as the hull comes back (PR #284).
- **Co-op joiner's minimap shows the map (#214, PR #269):** after build 17's fix the joiner had tasks and directions but
  no floor plan. The plans that ship with the mod (your ship, the stations) now load for a joiner too.

### For contributors

- **README:** a "What's new compared to the original game" section (PR #267).
- **Lore (#272, PR #273):** `docs/lore/` has a lore bible, 36 in-world fragments, loading lines and contract briefings,
  for the proposal on showing more of Marauders' lore in game. Feedback welcome in #272.
- **Tools:** `tools/offline-audit/paknames.py` lists every packed file's path from the running game's memory, no pak key
  needed, and `approws.py` lists the appearance rows with their meshes (PR #271).
- **Releases without the pak key (PR #290):** where the women's meshes can't be made, the build takes them from the latest
  release, only if nothing that makes them changed since, every file checked against that release's checksums.
- **NOTES:** ship damage and repair, first look (#70, PR #281).
- **NOTES:** host and joiner extracting through the space gate together, tested (#214, PR #278).
- **NOTES:** through UE4SS, a game function's text return value is junk (`GetPlayerName()`, even `Concat_StrStr`). The
  "garbled co-op names" of #200 were that, not the game (PRs #268, #270).

## Public test, 20 Nov 2026, build 17 (`public-test-20261120.17`)

The co-op joiner gets a working minimap, women's outfits stop stretching to the floor, and fewer small hitches for
everyone. On build 1 of 17 Nov or later, the
launcher's orange **!** installs this one for you, keeping your saves.

### Fixes

- **Co-op joiner's minimap (#214, PR #261):** a player who joined a co-op raid saw the minimap as an empty dark box. It
  now shows their tasks, the stations, and the way to the helm of the ship they're aboard. (No flying route to far
  stations for a joiner: the host's game doesn't send those to the joiner's.)
- **Fewer hitches (PR #260):** looking for mines to defuse scanned every object in the game every 20 seconds, on every map
  (a small stutter). Now it looks a few times at the start, then rarely, and not at all on maps without mines.
- **Women's hands (#35, PR #255):** the women's fingers were mangled whatever the outfit. The body reshape now fades out
  along the forearm, so the hands are exactly the men's and sit right on their finger bones (and on weapon grips).
- **Women's outfits stretching to the floor (#10, PR #263):** some women's bodies (Commando, Outlaw, Security, Space
  Pirate and the soldiers' one-piece outfits) pulled a strip of cloth down to the feet while moving, and dead boarders'
  legs fanned out into spikes. Making the women's meshes damaged part of their skin weights, tying those vertices to the
  root bone at the feet. The meshes are made again without that.
- **Updates bring the big files too (PR #257):** since build 15 the UE4SS library and the women's outfit meshes ship as
  separate dependency zips, and the launcher's update only took the main one. It now downloads the dependency parts that
  changed (checked against their checksums) and installs everything together, with a rollback if anything is missing.

## Public test, 20 Nov 2026, build 16 (`public-test-20261120.16`)

Nuclear mines can be defused, co-op joiners stop stuttering, and the Capital Ship gets its guards. On build 1 of 17 Nov
or later, the launcher's orange **!** installs this one for you, keeping your saves.

### Changes

- **Defuse nuclear mines (#197, PR #256):** at the helm, within 30 m of a nuclear mine, with a **ToolKit**, press **R**:
  a bigger Minesweeper round (8x8, 12 charges, 120 s). Clear it and a fuse and high-grade powder go into your pocket, and
  the **nuclear material** goes to your gift box (claim it in the lobby). Fail and its blast reaches your ship at full
  strength: enough to disable a starter frigate. Towing one home to your hold comes later.

### Fixes

- **Co-op joiner stutter (#254, PR #258):** a player who joined a co-op raid had a hitch every second or two: a search
  for the raid's game state that only the host can finish ran twice a second for the whole raid. Now it stops. Thanks
  roomtempsalami for the report.
- **Guards on the Capital Ship (#187, #42, PR #253):** places you board with a pod and that have no dock (the Capital
  Ship on Space_Beta) weren't treated as stations, so they got no guards and the soldiers the game puts there were left
  idle or stuck. They now get the stations' guards, patrols and handling.

## Public test, 20 Nov 2026, build 15 (`public-test-20261120.15`)

Inventory cells that stayed "occupied" after you moved an item are freed again. On build 1 of 17 Nov or later, the
launcher's orange **!** installs this one for you, keeping your saves.

### Fixes

- **Inventory desync (#249, PR #250):** moving items could leave the cells they came from "occupied", so nothing fit
  there, and moving more could stack, duplicate or lose items. Each cell of the inventory grid points at the item
  covering it, and the game sometimes leaves a cell pointing at an item that has moved away or is gone. While your
  inventory or stash is open, those cells are now cleared about once a second. Thanks to H1tSc4n for the report.
- **Items lost in the hidden right pocket (#249, PR #250):** the game has a second pocket it never shows. The mod put
  ammo and mine-defusing loot there in some cases since build 10, where it was invisible and stuck. It no longer does,
  and anything already there is moved to your stash at launch.

## Public test, 20 Nov 2026, build 14 (`public-test-20261120.14`)

No more slabs of ground and girders floating in space by Rebel Base. On build 1 of 17 Nov or later, the launcher's
orange **!** installs this one for you, keeping your saves.

### Fixes

- **Floating slabs and girders (#9, PR #247):** Rebel Base's terrain (a big flat slab of ground) and some of its
  ceilings, bridges and walls that stick out past the station were drawn in open space from far away. They're now
  hidden from space like the rest of its interior, and show again when you're inside.

## Public test, 20 Nov 2026, build 13 (`public-test-20261120.13`)

One cause of stuck, stacked items found and fixed. On build 1 of 17 Nov or later, the launcher's orange **!** installs
this one for you, keeping your saves.

### Fixes

- **Ammo stacked on itself in your pocket (#239, PR #245):** going into a raid without a gun, you get a soldier's gun
  and its ammo in your left pocket. That ammo was laid into the pocket's four cells without checking what was there, but
  7.62, .30-06, 5.56 and 7.62x54R stacks are two cells wide: they landed on top of each other (and on anything else in
  that pocket), and extracting saved it that way. Ammo, the F9 ammo button and mine-defusing loot now only go where they
  fit, and the save repair at launch now sorts out pockets too. Stacked helmets and stash items (#239) are still being
  looked into.

## Public test, 20 Nov 2026, build 12 (`public-test-20261120.12`)

Defuse the small mines out in space, from your ship. On build 1 of 17 Nov or later, the launcher's orange **!**
installs this one for you, keeping your saves.

### Changes

- **Defuse space mines (#197, PR #243):** at the helm, within 30 m of a small space mine, with a **ToolKit** on you,
  press **R**: the same Minesweeper round as the station mines. Clear it and the mine comes apart: a Fuse, gunpowder and
  chemicals go into your pockets. Hit a charge or run out of time and it goes off on your ship (500 hull damage, like
  flying into it). Nuclear mines come later.

### Fixes

- **Station mine defusing (#197, PR #243):** the "You need a ToolKit" prompt could show although you carried one, and
  the AP mine you get could land on top of another item in your pockets. Both fixed; leaving the helm with the board
  open now closes it.

## Public test, 20 Nov 2026, build 11 (`public-test-20261120.11`)

Saves with items stuck on top of each other are repaired. On build 1 of 17 Nov or later, the launcher's orange **!**
installs this one for you, keeping your saves.

### Fixes

- **Items stacked on top of each other (#240, #239, PR #241):** some saves held two or more items in the same place:
  several helmets in the Head slot, or stash items lying on another item. The game shows only one, so the others were
  invisible: a discarded helmet came back as the next one, and moved items froze or vanished, even after a relaunch.
  At every launch the backend now keeps one item per gear slot (the one you saw) and moves the rest, and any
  overlapping stash items, to free stash space. A backup of the save is kept first. What stacks them in the first place
  is still being looked for (#239). Thanks no-portobello and roomtempsalami for the reports and saves.

## Public test, 20 Nov 2026, build 10 (`public-test-20261120.10`)

Defuse the mines inside stations. On build 1 of 17 Nov or later, the launcher's orange **!** installs this one for
you, keeping your saves.

### Changes

- **Defuse station mines (#197, PR #237):** the anti-personnel mines the stations place can now be defused. Stand next
  to one with a **ToolKit** and press **F**: a Minesweeper round (6x6, 6 charges, 75 seconds; the first click is always
  safe, and a Flag mode button marks charges). Clear it and the mine comes apart: an AP mine and gunpowder go into your
  pockets. Hit a charge or run out of time and it goes off. The ToolKit is kept either way; "Back away" leaves the mine
  armed. Mines out in space come later.

## Public test, 20 Nov 2026, build 9 (`public-test-20261120.9`)

The lobby stops flashing when you change gear, and two hidden outfits. On build 1 of 17 Nov or later, the launcher's
orange **!** installs this one for you, keeping your saves.

### Changes

- **No more flashing on LOADOUT (#233, PR #234):** putting gear on or taking it off made the menu's panels blink out
  and fade back in, and the hangar behind them dim. It came from the mod's own redress of your lobby character; that
  now happens without the fade. Thanks The Wang for the report and clip.
- **Two hidden outfits (#229, PR #235):** the game has two long-coat outfits (brown with a brass mask, black with a
  goggled mask) that its Appearance pages never list. **F9 > Hidden outfit** in the lobby puts one on; pick any look in
  Appearance to change back.
- **F9 menu fits the screen (PR #235):** with all its buttons it ran off the bottom of a 900 or 1080 px window. It now
  uses two columns.

## Public test, 20 Nov 2026, build 8 (`public-test-20261120.8`)

A crash fix and two minimap and crew fixes. On build 1 of 17 Nov or later, the launcher's orange **!** installs this
one for you, keeping your saves.

### Changes

- **Crash fix (#191, PR #222):** the game could close a moment after a turret in space was destroyed (seen after a
  moving flak turret died on Space_Charlie). Your gunner kept destroyed turrets on its list and read them after the
  game had freed them.
- **Minimap and the space gate (#223, PR #225):** with "Leave through a space gate" followed, the minimap stopped
  working once you left the helm. Its gate countdown also ignored the launcher's "Space gate" setting: on "instant" it
  counted down 4 minutes to a gate that was already there. It now follows the same time as the HUD.
- **Hired crew (#224, PR #226):** a hurt crewmate following you into a new place no longer cuts the crew's update short.

## Public test, 19 Nov 2026, build 7 (`public-test-20261118.7`)

Co-op on one ship, an unstuck button, civilians in their own clothes, and a crash fix. On build 1 of 17 Nov or later,
the launcher's orange **!** installs this one for you, keeping your saves.

### Changes

- **Co-op: one ship (#214):** a friend who joins your raid now comes aboard your ship, as one of your crew, instead
  of flying a ship of their own 330 m away. Their loading screen also clears as soon as they're in (it used to sit for
  up to 90 s). Flying, turrets, boarding and extracting together are still untested: tell us how it goes.
- **Unstuck (#198):** stuck in a wall or fell under the map? **F9 > Unstuck** puts you back where you last stood on
  solid ground, or on the nearest floor. Once every 30 seconds.
- **No collision (#198):** **F9 > No collision** walks through walls and flies (look up or down to climb or sink). A
  cheat like god mode, for getting out of trouble or exploring; it switches off at every map change.
- **Civilians dressed by trade (#196):** miners, prisoners and port workers no longer all wear the same green outfit:
  miners in mining gear, prisoners in prison suits, workers in colonist and work clothes, mixed within each group.
- **New save: gear and money apart (#204):** NEW SAVE has two boxes, "Start with lots of gear" and "Infinite money".
  Gear alone starts you with the usual 65,000 credits; infinite money alone starts you with the new-player kit.
- **Crash fix (#192):** boarding an Assault Scout (or another scout or dreadnought) could close the game with "Could
  not find SuperStruct". The ship's interior now loads its parent first.
- **The download comes in pieces (#213):** each file is under 9 MB. Updating through the launcher only needs the main
  zip; a new install extracts all of them into one folder.

### Missed in earlier notes

- **Launcher (build 6, #193):** "Raid conditions" no longer pushes the right-hand panel out of the window (#188).
- **Co-op joining (build 6, #194):** the fix that made joining work at all (#26).
- Release notes are now checked against every merged PR, so contributors' work gets its line and its thanks (#199).

## Public test, 19 Nov 2026, build 6 (`public-test-20261118.6`)

Co-op (early), a faster Rustbucket with a boost, and J and K in raids. On build 1 of 17 Nov or later, the launcher's
orange **!** installs this one for you, keeping your saves.

### Changes

- **Co-op, early (#201, #200):** play a raid with a friend. In the launcher, **CO-OP**: the host ticks "Host: friends
  can join my raids" and starts a raid as usual; the friend types the host's address and presses **JOIN**. Each of you
  plays from your own save and flies your own ship. Across the internet you need a shared network:
  [docs/COOP.md](docs/COOP.md) walks through it with ZeroTier and has a setup script for Windows and Linux (#202). Only
  tested with two copies on one PC so far: tell us how it goes.
- **Rustbucket (#207):** a quarter faster, and quicker to get up to speed. **Space** at the helm of any ship boosts it
  to nearly twice its top speed for 4 seconds, then needs 12 seconds to recharge, like the drop pod.
- **J and K in a raid (#209):** with a crate or body open, **K** moves the item under the mouse between your gear and
  the container, and **J** drops your item on the floor.
- **Crew helmets (#195):** recruits no longer keep turning up in the Red Baron's cap (Rosco and his whole bloodline).
  Recruits and crew already wearing one get a fitting helmet of the same grade.

### Missed in earlier notes

- **Shotgun throw** (build 1 of 18 Nov, #154, thanks sp0rrk): a shotgun volley throws the bots it hits, harder the more
  pellets land and the closer you are; the sawed-off and the Terminator throw furthest.
- Thanks to sp0rrk for the space gate timer, bullet holes, space explosions, the blowtorch, unlimited stamina in god mode
  and the salvage purge fix in build 4 (#170, #173, #176, #179, #181, #182).

## Public test, 19 Nov 2026, build 5 (`public-test-20261118.5`)

A minefield. On build 1 of 17 Nov or later, the launcher's orange **!** installs this one for you, keeping your saves.

### Changes

- **Minefield (raid condition):** twenty times the space mines, scattered around every minefield the map has. Pick it
  in the launcher ("Raid conditions") or the lobby's REGION picker. Better loot. Make your own with `mines = N` in
  `config/my_raid_conditions.txt`. New and lightly tested: tell us if it slows or crashes your game.

## Public test, 19 Nov 2026, build 4 (`public-test-20261118.4`)

Civilians, bullet holes, and explosions you can see. On build 1 of 17 Nov or later, the launcher's orange **!**
installs this one for you, keeping your saves.

### Changes

- **Civilians (#81):** a few unarmed miners, prisoners and workers at the mines, the Penal Colony and the ports. They
  go about their work, run when you come close or start shooting, and plead when cornered. Each carries a few things
  of their trade. Kill one and nearby station guards come for you. F3 > How many sets how many (0 turns them off).
- **Bullet holes** now show on walls, floors and other surfaces offline.
- **Turret and mine explosions** and their sounds now show in space (#15).
- **Space gate:** choose when it arrives, and its countdown is right again.
- **Blowtorch** burns through a vault door's locks offline.
- **God mode** also gives unlimited stamina.
- **Salvage** can't be purged while docked any more.
- **AI frigates** are named "the Scout Frigate", not their internal class name.

## Public test, 18 Nov 2026, build 3 (`public-test-20261118.3`)

Raid conditions for events, your ship's engine hum, and nothing reaching a live server any more. On build 1 of 17 Nov
or later, the launcher's orange **!** installs this one for you, keeping your saves.

### Changes

- **Raid conditions (#78):** pick a set-up for your next raid in the launcher ("Raid conditions", click to cycle) or in
  the lobby's REGION picker: Baron hunt, Hunted (every crew attacks you), Busy sky, Capital ships (a guaranteed Capital
  Ship and Dreadnought) or Baron's last stand. Harder ones put more and better loot on bodies. They last the raid; your
  own F3 settings come back after. Make and share your own in `config/my_raid_conditions.txt`.
- **Your ship's engine hum** now plays inside (it only started on a network client), and a pod flying into a
  station's docking area gets the "only ships are able to dock" warning again (#143).
- **Privacy:** the game's crash and session reports (Sentry) were still reaching their live server offline. Every
  online service the game calls now goes to the local stand-in instead.
- **Saves** now carry a format version, so a future update can bring old saves up to date safely (#80).
- **README:** bug reports point at the launcher's **REPORT** button, which bundles the logs for you.

## Public test, 18 Nov 2026, build 2 (`public-test-20261118.2`)

Sound and motion the offline game was skipping. On build 1 of 17 Nov or later, the launcher's orange **!** installs
this one for you, keeping your saves.

### Changes

- **Stations come alive (#143):** fans and tape reels turn, machinery hums, and broken machinery sparks again. They
  waited on a timer only the live servers' players started.
- **Footsteps (#143):** you and the soldiers now make the settling footstep when you stop walking or running, and
  landing from a fall shakes your camera again.
- **For contributors:** every top-level folder has a short README, with diagrams of how the game's online services
  are replaced offline, how the mod runs each frame, and how we find what the game skips offline.

## Public test, 18 Nov 2026, build 1 (`public-test-20261118`)

Working shotguns and armour on enemies, a raid length setting, and the breach prompt in pods. On build 1 of 17 Nov or
later, the launcher's orange **!** installs this one for you, keeping your saves.

### Changes

- **Damage on enemies (#123, #154):** helmets and vests now protect the soldiers wearing them, by how good the piece
  is, and head, body and leg hits count differently. Shotguns work: each shot fires its pellets, and armour is taken
  off each one. Hits no longer stop on a bot's helmet, vest or backpack before reaching the body behind. The numbers
  are in `docs/internals/DAMAGE_REFERENCE.md`.
- **Raid length (#159):** a new launcher setting: 25 minutes (the game's own), 15, 30, 45, 60, 90 or 120 minutes, or
  no limit. It takes effect from your next raid.
- **Breach prompt in pods (#77):** flying a pod at a ship now shows "BREACH BOOST READY" and "F" BREACH when you're
  close enough to breach. Pressing F always worked; nothing told you.
- **Linux / Steam Deck (#127):** the launcher window now works on Linux too (saves and settings; its PLAY starts the
  game through Steam), and the README has a Steam Deck button layout for the mod's keys. Still not tested under real
  Proton or on a Deck: if you try it, please report in #161.
- **F9 debug menu:** a Bottomless mags toggle (#155).
- **REPORT** now also includes a short list of the game requests the offline backend can't answer yet, which tells us
  which missing features players actually run into (#80).

## Public test, 17 Nov 2026, build 8 (`public-test-20261117.8`)

Fixes the **crash on leaving a raid**, plus the salvage hold door, giving items to a save, a rebuilt launcher and
Linux / Steam Deck support. On build 1 or later from today, the launcher's orange **!** installs this one for you; from
yesterday's build 4 or older, download it by hand.

### Changes

- **Crash on leaving a raid (#133):** `EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000268` on extracting,
  dying, leaving through a space gate or quitting to the main menu, for anyone with hired crew. The crew portraits in
  the lobby kept the old lobby world alive through the raid, and loading the menu again picked up that dead world. Your
  save wasn't corrupted: the game crashed before it could save what you brought back. No need to delete or remake
  your profile.
- **Salvage hold (#134):** after you take a wreck's salvage aboard, the hold's door now opens and the lever panel shows
  it, so you can loot the salvage.
- **Launcher:** give items or cash to a save (#136); fixed garbled text from Windows on non-English systems (#139);
  window scaling, fonts, keyboard use and proper dialogs reworked (#147).
- **Linux / Steam Deck (#127):** play through Proton with a Steam launch option. See the README. Not tested under real
  Proton yet, so tell us how it goes.
- **Bots** animate at your display's frame rate (up to 120 Hz), so walking and aiming look smooth on fast monitors.
- **F9 gun list:** the gun variants (Terminator, Heavy Liberator, Thompson Special and more) can be given for testing.
- Under the hood: the mod's two biggest scripts are split into smaller modules, and checks that stop this kind of
  crash from coming back. If something that used to work broke, send a REPORT from the launcher.

## Public test, 17 Nov 2026, build 7 (`public-test-20261117.7`)

Another **airlock crash** fixed, a **crew gunner** that actually turns the guns, and a smoother menu. On build 1 or later
from today, the launcher's orange **!** installs this one for you; from yesterday's build 4 or older, download it by hand.

### Changes

- **Airlock crash (#53), the other kind:** crashing in UE4SS on going through an airlock or into a station (the Asteroid
  Mine most often). The mod's object checks could read memory the game had already freed as a station's contents
  streamed out; they're now checked natively first. Build 4 fixed a different airlock crash. If you still crash at an
  airlock, send a REPORT from the launcher.
- **Crew gunner (#88):** your gunner now reaches further (1.75x each turret's range), swings the turrets to 170 deg
  either side, and keeps firing at ships and turrets well above or below you. A left click picks the ship nearest the
  middle of your view more easily. When they can't fire, they say why: too far, can't swing onto it, or too far above
  or below. Two new settings on the F3 **Ship guns** tab. Rival crews' gunners are unchanged.
- **Hit zones on soldiers (#123):** on land raids, the mod's soldiers now take head, body and leg damage from your shots
  (head shots hit much harder, legs less) instead of the same damage everywhere. Station guards and rival crews already
  had them. Liberator pellets are still being looked at.
- **Menu (#125, thanks sp0rrk):** no more once-a-second hitch in the lobby after a raid, and a smoother title screen.
- **Minimap:** no more error spam in the log while it looks for your ship.

## Public test, 17 Nov 2026, build 6 (`public-test-20261117.6`)

A batch of fixes from the bug reports, and a handier launcher. On build 1 or later from today, the launcher's orange
**!** installs this one for you; from yesterday's build 4 or older, download it by hand.

### Changes

- **Loot from bodies:**
  - **Guns in usable condition (#86).** Bots used to drop guns as low as 1/1 durability. Rivals now carry well-kept
    guns (better kit, better kept) and station guards somewhat worn ones.
  - **Shotgun ammo stacks (#102)** stay within their limit (12 gauge: 20, not 35 or 60).
  - **Blueprints (#100)** found on bodies have half to all of their uses, not 1.
  - **Pistol-only rivals (#101)** carry the pistol in the pistol slot.
- **Contracts:**
  - **Inspect spots (#99)** only take over the Use key when you're close and looking right at the object, and never
    over loot, doors or containers.
  - **No repeating contract sound (#20)** while holding Use on a finished one.
  - **Your own Use key (#103):** inspects and the turret seat follow your key binding instead of assuming F.
- **Launcher:**
  - **CONTROLS (#97)** lists every mod key.
  - **REPORT (#96)** makes one zip of your logs (and the last crash) on the Desktop for a bug report, with your
    Windows user name, Steam IDs and in-game name taken out.
  - **Back up** a save to a zip, and **IMPORT (#95)** saves from a backup or from an older copy of the mod.
  - **Starts Steam** for you when it isn't running, **minimizes while you play** (a setting), and takes **Enter**
    (play), **Delete** and **F2** (rename) (#98).
  - Shows the **build** you're on, next to OFFLINE PvE.
- **Stash search:** typing an N, M or B in it no longer toggles the minimap.

## Public test, 17 Nov 2026, build 5 (`public-test-20261117.5`)

**Stash tools** and **enemies that reload**. On build 1 or later from today, the launcher's orange **!** installs this
one for you; from yesterday's build 4 or older, download it by hand.

### Changes

- **Enemies reload (#115):** soldiers, rival crews and your own crew used to fire forever from a 30-round magazine. Now
  each gun's magazine runs out, and its owner stops for about 2.5-3 seconds to reload: a window to push or reposition.
- **Stash tools** under SECURE STORAGE (LOADOUT and TRADE):
  - **SORT** merges part stacks of ammo and meds, then packs your stash by kind (guns, ammo, attachments, armour and
    bags, meds...). A nearly full stash is sorted as far as the free space allows.
  - **Search box:** type part of a name and everything else dims.
  - **SELL SHOWN** (at a trader): sells what your search shows, after a second press to confirm.
- **Hotkeys** for the item under the mouse: **K** moves it between your stash and your pockets or bags, **J** discards
  it (press J twice: it can't be undone).

## Public test, 17 Nov 2026, build 4 (`public-test-20261117.4`)

Fixes for the two worst problems on build 3: the **crash going through airlocks** and **raids at 10 fps** after
opening the GUILD tab. Also **illustrated station maps** in the minimap, by Ahtu. On builds 1-3 from today, the
launcher's orange **!** installs this one for you; from yesterday's build 4 or older, download it by hand.

### Changes

- **Airlock crash (#53):** going back aboard through an airlock, or into a station a second time, crashed the game. The
  minimap kept each place's floor plan only on the Lua side, so the game freed the one you'd left, and coming back
  drew a freed image. Plans now stay loaded while the minimap exists. The lobby's crew portraits and the loading
  screen's picture had the same weakness and are fixed too.
- **Raids at 1-15 fps after opening GUILD (#112):** once the guild page had been opened, every frame of every raid
  searched the whole game for it (it's gone with the lobby). It's now forgotten when the lobby goes. The pause menu's
  Quit button had the same habit in the raid after one where you'd opened the menu.
- **Minimap: Ahtu's maps.** Asteroid Mine, Mining Frigate, Planet Killer, Terraformer, Navy Outpost, Penal Colony and
  Spaceport show Ahtu's illustrated floor maps (the floor you're on, by height) instead of the plain outline, credited
  in the map's corner. Thanks, Ahtu!
- **Smoother menus (#113, thanks sp0rrk):** the lobby, loadout and market no longer stutter once a second (the
  friends list refresh, already stubbed in raids, is now stubbed in the menu too).
- **Guide:** the six video topics (they need YouTube) now show short written guidance instead of an empty box.
- **Steadier:** actors that disappear mid-raid can't stop the director's update any more, cached objects from the last
  map are dropped, and a few menu searches back off instead of retrying every few seconds forever.

## Public test, 17 Nov 2026, build 3 (`public-test-20261117.3`)

A fix for the low frame rate some of you saw on build 2 (a flat 9-10 fps on foot). On build 2 or this morning's
build, the launcher offers this one by itself (the orange **!**); from build 4 or older, download it by hand.

### Changes

- **Frame rate on foot (#110):** the minimap searched the whole game twice per redraw, 30 times a second, when it
  couldn't find your ship's airlock or helm: about 10 fps for as long as you were on foot. It now tries again every
  5 seconds. The minimap's task lookup and the inventory keys' widget search no longer repeat full-game searches
  either.

## Public test, 17 Nov 2026, build 2 (`public-test-20261117.2`)

A frame-rate follow-up to this morning's build. If you're on build `public-test-20261117`, the launcher offers this
one by itself (the orange **!**); from build 4 or older, download it by hand.

### Changes

- **Lighter on the CPU in stations:** while you're on foot, rival ships out in space are updated 15 times a second
  instead of every frame, and enemies who aren't fighting update their animation and aim half as often. In a test
  the mod's own work per frame roughly halved, which matters most on slower PCs.

## Public test, 17 Nov 2026 (`public-test-20261117`)

The headline is **frame rate**: guards in stations you've left no longer stay awake for the whole raid, so raids
don't get slower the more stations you visit. Also the **Red Baron** as an event setting, a fix for the launcher
hanging on **CONNECTING TO BACKEND**, and the launcher can now **update itself** from this build on.

- **Updating from build 4:** download this one by hand (build 4's launcher can't update itself yet). From this build
  on, the launcher shows an orange **!** when a newer build is out and updates in place, keeping your saves.
- **Startup video:** the release no longer includes the mod's re-cut intro (it has music in it); you see the game's
  own, or a one-second clip with **Skip the intro video** on.

### Changes

- **Stuck on "CONNECTING TO BACKEND"** when the mod's folder path had a space in it (#75): fixed. If the offline backend
  still can't start, PLAY now says why instead of hanging.
- **The Red Baron in every raid** (an event setting, #78): F3 > **Rival ships** > "The Red Baron in every raid". With it
  on, one rival crew is the Red Baron's: his strike frigate, a full crew that fights to the death and goes for any ship
  it sees, his best gunner, and the Baron himself in his own look, best gear and twice the health. Off by default.
- **Less stutter while looting:** the mod no longer searches the whole game for the pause menu every 2 seconds while your
  inventory is open. Distant enemies also animate the cheaper way.
- **Ctrl+R no longer restarts the mod mid-raid** (crouch + reload triggered UE4SS's hot reload).
- **Better frame rate later in a raid:** guards in stations you've left used to stay fully awake for the rest of the
  raid, so every station you visited made the game slower. Now guards far from you sleep until you come back, and at
  most 16 enemies are awake around you (more crews wait on their ship). In a test with one busy station behind us, the
  frame rate went from about 70 to about 95. Both are adjustable in F3 > **How many**. `last_game.log` now records your
  frame rate every 10 seconds, so please include it with performance reports.
- **Windowed mode fits small screens:** 1600x900 when it fits, smaller on laptops (e.g. 1152x648 on 1366x768).

## Public test, 16 Nov 2026, build 4 (`public-test-20261116.4`)

About 20 changes since build 3. The headline ones are an **offline guild** (guild page and guild shop), **choosing
your raid map**, your **look and voice showing in raids**, **getting your gear back** when a raid ends without
extraction or death, and a launcher that **tells you about new builds**. Please read **Known issues** at the bottom.

### New in this build

#### Offline guild and guild shop
**What happened:** guilds live on the online social service, so offline SOCIAL > GUILD was an empty room and the
TRADE page's **GUILD** shopkeeper stayed locked.

**Now:** you captain an offline guild, **Marauders**, with Haywire Hayley and Lilykoi as officers and a random
handful of people from the Discord as crew mates (some shown online). The page shows the member list, the guild's
rank and its progression. On **EDIT GUILD** you can set an announcement, public or not, the join type, the patch
(design and colours) and up to 5 tags; they're kept between sessions. **First Mate Calico's guild shop** on the
TRADE page opens, and buying and selling there work.

- The guild hideout, guild chat, leaving and disbanding need online servers and are hidden.

#### Choose your raid map
The **REGION** box next to START RAID means nothing offline, so it now picks the map. Its buttons are the six space
maps (**SOLO 1, SOLO 2, ALPHA, BETA, CHARLIE, DELTA**) plus **RANDOM**. Each says whether it's a solo or crew map,
and hovering shows the stations usually found there. Your pick is remembered.

#### Your gear comes back when a raid ends without extraction or death
**What happened:** quitting mid-raid, Alt+F4, a crash or leaving through the menu lost the gear you brought in.

**Now:** that gear goes back to your stash, still equipped, the next time you log in or start a raid. Anything you
picked up in that raid is lost. Dying and extracting work as before.

#### The launcher tells you about new builds
An orange **!** at the top right when a newer build is out, and it can update itself: it downloads the new zip, checks
it and installs it over the folder, keeping your saves and settings. Switch it off with **Check for new builds**.
**It starts working from the build after this one**, so download this one by hand.

#### Also new
- **Unlock all looks and voices:** a launcher checkbox that unlocks every head, body and voice without buying them.
  Your save isn't changed, so switching it off brings the normal unlocks back.
- **QUIT tab** in the lobby's top bar (click twice to confirm).
- **F9 menu:** pick a specific gun or ammo type and get it (loaded, into a free slot).
- **Crew gunner snipes station turrets** from as far as those turrets reach you (13,500), instead of having to close
  to the hull guns' own range.

### Fixed in this build

#### Your look and voice didn't show in raids
**What happened:** whatever head, body and voice you picked in the lobby, raids had the default look and the English
male voice.

**Why:** the raid server normally hands your chosen look to the raid. Offline nothing did.

**Now:** the mod hands it over at raid start, with your loadout. Voice lines use your chosen voice.

#### Stuck behind a loot window
**What happened:** pressing Use (F, or R if you've moved Use onto Rotate's key) in an open loot window brought up the
pause menu. Closing it left the loot window drawn over the game while you could still move and shoot.

**Now:** Use in a loot window closes it. As a safety net, an inventory left on screen without the mouse cursor is
closed.

#### Pod breach into Fortress put you in a wall
**What happened:** at one Fortress breach point the pod leaves you above a hatch, with the floor below out of reach.
The mod's "no floor under you" rescue moved you to the nearest walkable point, which was behind a wall.

**Now:** it lands you on the floor straight below. Any other spot must be in clear sight of where you came out.

#### Also fixed
- **Esc in the inventory** closes it, instead of opening the pause menu behind it. No leaning while it's open.
- **You and your crew walk through each other** instead of blocking doorways. Enemies still collide.
- **Gear shows on your lobby character** as soon as you equip it, instead of after switching tabs.
- **New saves start like the game's own new player** (its starting credits and kit), without the launcher's extra
  10,000 and kit on top. No more "10,000 then 75,000".
- **Crew errors in fights from cover** ("attempt to perform arithmetic on a table value") are gone.
- **Launcher:** opening it twice no longer risks losing a raid's progress (the second one just brings the first
  forward). Closing it while you play asks first, and if you do, it saves your game and puts the online game back
  next time it opens. A damaged save shows as **DAMAGED** instead of disappearing, a save can be called "Nul", and a
  setting that can't be saved says so.

### Known issues

- **Crash using a station airlock after some time in a raid** (#53). Still being tracked down. Until then, **save
  your progress by extracting before long station runs**. If you crash, please share `backend\last_game.log`
  (written when the game closes) on the Discord.
- **Docking at Planet Killer** (Space_Charlie): the airlock may not take you through (#32).
- **Interceptors** (Solar and Galaxy) aren't properly boardable yet: missing walls inside (#70).
- **Space salvage can disappear** when you dock at a station (#74).
- **No button prompt to breach** when your pod reaches a ship (#77).
- A **"social service unavailable"** panel may flash after login. If you see it stay up, please send a screenshot.

### For contributors

- NOTES.md: five AI fixes from 14 Nov are now confirmed in game (crew arrival spacing, guard counts by station size,
  baked cover in Rebel Base, the off-limits fix, fight hitches).
- `tools/offline-audit/kdis.py` decodes delegate opcodes and set/map/array literals.

## Public test, 16 Nov 2026, build 3 (`public-test-20261116.3`)

A big one: about 25 changes since build 2. The headline fixes are **space salvage**, the **missing key card**, your
**crew gunner ignoring station turrets**, and the **interaction prompts** that went missing. There's also a
**Quit Game** button at last. Please read **Known issues** at the bottom before a long session.

### New in this build

#### Quit Game in the pause menu
**What happened:** there was no way to close the game from inside it. The pause menu's EXIT belongs to the "leave the
raid?" dialog, so testers were force-closing the game.

**Now:** press Esc in a raid and there's a **QUIT GAME** button under Main Menu. Click it once and it asks again
("CLICK AGAIN TO QUIT"). Click again within 4 seconds to close the game. Quitting mid-raid counts the gear you brought
in as lost, the same as Alt+F4; the launcher's **Undo last raid** brings it back.

- The lobby still has no quit button (tracked in #50).

#### START RAID
Offline there's no matchmaking: the lobby's button loads a raid straight away. It now says **START RAID**.

#### French female voice free from the start
**What happened:** you could play as a woman from the first launch, but every female voice cost credits (the cheapest,
FRENCH 02, was 3,500).

**Now:** FRENCH 02 is unlocked on every save. Pick it under **Loadout > Appearance > Voice**. Other voices keep their
prices and level requirements.

#### Your crew gunner tells you why they aren't shooting
If no turret on your ship can bear on the target for 3 seconds, your gunner says why, once:
- "**too far, close in**": the target is out of your guns' range;
- "**can't swing onto it, turn us toward it**": it's outside your turret's arc (the starter ship's single turret
  covers about 120° either side of the nose).

#### Also new
- **Gear tab in the F3 menu:** switch level-scaled enemy gear off, or make it tougher.
- **Launcher:** an option to skip the 60 s intro video. PLAY now checks what it needs before starting, and tells you
  why a launch failed.

### Fixed in this build

#### Space salvage works offline
**What happened:** flying up to a wreck never showed the salvage prompt, and R did nothing.

**Why:** the ship only starts its "is there salvage nearby?" scan on a network client. Offline your game is the
server, so the scan never ran.

**The fix:** the scan now starts offline too. Fly within about 15 m of a wreck and press **R**. The salvage lands in
your hold as a crate you can search with **F**, and the **lever** in the hold purges it so you can take another.
Tested end to end: capture, loot into your loadout, purge.

#### Interaction prompts missing (doors, contracts, ship panel)
**What happened:** "F" prompts on doors and contract objects, and the ship panel, often didn't show.

**Why:** the mod builds a HUD early for your loadout; the game later builds its own. Prompts kept going to the mod's
hidden copy.

**The fix:** once the game's HUD exists, prompts go to it. Please report any prompt that's still missing.

#### Missing captain's key card
**What happened:** sometimes you started a raid with no key card for your own ship, so after docking you couldn't get
back aboard. Reproduced with an empty loadout.

**The fix:** if no card has turned up 6 seconds after you board, the mod asks the game for one, using the same call
the game makes itself. Asking again never gives you a second card.

#### Crew gunner never shot station turrets
**What happened:** your gunner ignored the stationary turrets around stations, even while they shot you, and even if
you clicked one.

**Why:** a one-line bug made every stationary turret look already destroyed.

**The fix:** they now engage turrets that are aiming at you, and ones you click. In testing, a level 1 gunner took
out a flak turret in about 12 seconds. Station turrets outrange your ship's guns (about 13,500 vs 6,000-9,500
units), so close in and point your nose at them. Your gunner will now tell you if you're too far or facing wrong.

#### Also fixed
- **Health lost at the start of a raid:** you now spawn at normal speed, with no damage on arrival.
- **A crash when the intro was skipped:** PLAY now stays hidden until the backend login has finished.
- **Stray floating airlocks** from stations that aren't on the map this run are hidden (seen floating in open space
  on Space_Solo_02).
- **Bot heads:** the hidden decal head stays hidden when bots wake, for men and women, and swapped heads get their own
  material.
- **Escape pod:** the attachments (stock, magazine) of the guns hidden on your pod are hidden too.
- **Gear by level** counts levels the way the game does, and a new save stays at level 1.
- **Shorter hitch on first entering a station:** the mod shares its object scans there.
- **Land raids:** the minimap is skipped there, where it threw an error every frame.
- **Crew name tags** no longer leak memory over a long session.
- **Status line** says "aboard the <ship>" when you're on a rival's ship.

### Known issues

- **Crash using a station airlock after some time in a raid** (#53). Seen by a tester at every station they tried, and reproduced here,
  after some time in a raid or after an earlier raid in the same session; a quick in-and-out at the start doesn't
  trigger it. We've reproduced it and are tracking it down. Until then, **save your progress by extracting
  before long station runs**. If you crash, please share `backend\last_game.log` (written when the game closes) on
  the Discord.
- **A new save shows 10,000 credits, then 75,000** after the first stash change (#56). Harmless; we're deciding the
  intended starting amount.
- **Docking at Planet Killer** (Space_Charlie): the airlock may not take you through (#32).

### For contributors

- CI checks Lua syntax and Python compile on every push and PR.
- `scripts/setup-dev.ps1` sets up a dev checkout in one command.
- `bridge/profile_on` can now be switched on and off mid-raid (it used to be read only at launch), so
  `bridge/dir_eval.lua` works in a running raid.
- NOTES.md has the co-op join findings and the station survey log.

## Public test, 16 Nov 2026, build 2 (`public-test-20261116.2`)

The only change from the 16 Nov build is the Mini Mine fix below. (The first 16 Nov zip had been replaced in place
with one carrying this fix; build 2 gives it its own release, so anyone holding an early download can tell.)

### Fixed: crash after taking a pod to the Mini Mine

**What happened:** if you took a pod to a station you have to board, like the Mini Mine, the game could crash a few
moments after you got out. It happened twice in testing (15 Nov, and on 16 Nov with the Just Deserts contract), both
with the same crash signature.

**Why:** this wasn't the pod itself. It was the mod's contract tracking. At the start of each raid the mod
(`mods/PvEDirector/Scripts/missions.lua`) scans the map once for contract objects (the things you inspect, hold or
deliver to for a contract) and used to keep a direct reference to each one. The game can delete and replace those
objects later in the raid, for example when a station's contents load in as you arrive. The mod's reference then
pointed at memory that had already been freed. When you came within range of the contract, the mod checked whether
the object was still valid, and that check read the freed memory and crashed the game. A pod drops you right next to
the station's contract objects, which is why it showed up there.

**The fix:** the mod no longer holds on to the objects. The scan now saves each contract object's *name in the
game's world* (its object path) instead. Every time the mod needs the object, to check whether you're standing in a
hold area, inspecting something, or pressing Use on it, it looks the object up again by that name. If the game has
replaced or removed the object, the lookup returns nothing or the new live copy, and the mod never reads stale memory.

- Changed: [`missions.lua`](mods/PvEDirector/Scripts/missions.lua): the scan stores `path` instead of `actor`, and a
  new `live()` helper finds the current object with `StaticFindObject` on each use (hold-area check, inspect, Use).
- Contracts behave as before. Only how the mod finds their objects changed.
- Status: in this build. The exact Mini Mine pod run hasn't been repeated in game since the fix, so please report it
  in the Discord if it still crashes there, with `backend\last_game.log` and `backend\server.log`.

## Public test, 16 Nov 2026 (`public-test-20261116`)

### Fixed in this build

- Your shotguns work. Before, the player's shotgun fired but its pellets did no damage.
- The social overlay is hidden within a second or two of the lobby loading.
- Start Matchmaking gets you into your ship about 4 s sooner.
- Bots' heads fit their helmets, with no merged or clipping headgear.
- Berths held by wiped-out crews are freed for other ships.
- You get camera control as soon as you arrive in a raid, without pressing Tab.
- Rival ships no longer circle their exit point forever.
- Crashes on raid load, space stutter, fight hitches and a stash overflow past 25 rows are fixed.

### New in this build

- Crew hiring and wages cost half as much while we test how useful crew are.
- Left-click while flying to send your crew gunner after the ship or space turret nearest the middle of your view.
  Click empty space to send them back to whoever is attacking you.
