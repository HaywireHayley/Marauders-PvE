# Recoil test

Test tools that measure the recoil climb of every automatic gun, single shot gun and pistol by themselves while you click or hold the left
mouse button at a wall, and write the result to a text file. Test installs only: none of this is part of the shipped mod.

## What is here

| File | What it is |
| --- | --- |
| `recoiltest.lua` | The single shot guns and the pistols: swaps the guns, forces aim down sights on and off, puts the view back at eye level between guns, counts the shots, writes `bridge/recoil_test_single.txt` (or `_pistols`). F9 "Recoil test, single shot guns" and "Recoil test, pistols" |
| `recoiltest_auto.lua` | The same for the 28 automatic guns (hold the button for each gun). F9 "Recoil test" (or "Recoil test, 5 guns"), writes `bridge/recoil_test.txt` |
| `recoiltest_hook.lua` | Gives the tests their tick and their F9 buttons, from one line at the end of `botdamage.lua` |
| `make_test_recoil.py` | Makes a test copy of `recoil.lua` that has a raw switch (the game's own recoil), settings read from a file on every shot, and a log of what each shot added |
| `soundtest.lua` | The weapon sound test (F9 "Weapon sound test", rides on the recoil test's tick): click, fire the gun in your hands, click again; writes `bridge/sound_test.txt` with the gun's sound set, every shot, and how many impact effects are live. It is how the shotgun boom cut out by its own impact sounds was found (NOTES.md) |
| `summarise.py` | Turns a result file into a table of the climb shot by shot |

## Run it

1. Copy the Lua files (`recoiltest.lua`, `recoiltest_auto.lua`, `recoiltest_hook.lua`, `soundtest.lua`) into `mods/PvEDirector/Scripts` of the install and add
   `require("recoiltest_hook")(B)` on the line before `return B` at the end of `botdamage.lua`. Switch the install to offline again
   (`scripts\mode.ps1 offline`) so the game gets the copy.
2. Start a raid on foot, with one gun slot free (the test removes the gun in your hands, then gives the next one). The tests turn bottomless
   mags on themselves.
3. Stand 3 to 5 m from a flat wall and look at it. Press F9, click the test, close the menu. (Or leave a file in `bridge/` before the raid:
   `recoil_autostart` containing `single` or `pistols`, `recoil_autostart_auto` containing anything. The test starts 10 s after you are on foot, once.)
4. Single shot guns and pistols: click once per shot, 5 shots per gun. Automatic guns: hold the button until the gun is taken away. Round 1 is
   aim down sights for every gun in turn, round 2 is the hip. Each gun fires 5 shots with the view left free, so the recoil builds up as in play.
   Then the gun is taken away, the view goes back to eye level (the wall) and the next gun is given. A banner says which gun and round it is.
   Pump shotguns and bolt actions take their time between clicks; wait for the gun to be ready.
5. The result is the text file named above. `python summarise.py <that file>` prints the tables.

## Comparing the recoil layer with the game's own

`python make_test_recoil.py ../../mods/PvEDirector/Scripts/recoil.lua > recoil.lua` and put the result over the install's `recoil.lua` (put the repo's
file back afterwards). Then, in the install's `bridge/`:

- a file called `recoil_raw` switches the layer off (the baseline: the game's own recoil), delete it to switch it on;
- `recoil_cfg.txt` holds lines like `RECOIL_MULT=0.5` or `HIP_KICK=1`, read again on every shot;
- `recoil_dbg.txt` gets a line for each shot the layer added to.

Run each test once raw, once with the settings under test, and compare the climbs.

Not in the sets: the launchers, the blowtorch, the fire extinguisher, the flamethrower, the flare gun. The shotguns fire pellets, so their
bloom lines are per pellet. The pistol set is run on its own because the pistols go into the pistol slot. The sideways drift is in the `F` rows
(the view's yaw) but `summarise.py` only tabulates the climb.
