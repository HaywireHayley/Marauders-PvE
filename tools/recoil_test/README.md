# Recoil test

A test tool that measures the recoil climb of every single shot gun (then every pistol) by itself while you click the left mouse button at a
wall, and writes the result to a text file. Test installs only: it is not part of the shipped mod. (The automatic guns' version, hold the
button, was the first one: it is kept in the git history of the recoil work, not here.)

## What is here

| File | What it is |
| --- | --- |
| `recoiltest.lua` | The test: swaps the guns, forces aim down sights on and off, puts the view back at eye level between guns, counts the shots, writes `bridge/recoil_test_single.txt` (or `_pistols`) |
| `soundtest.lua` | The weapon sound test (F9 "Weapon sound test", rides on the recoil test's tick): click, fire the gun in your hands, click again; writes `bridge/sound_test.txt` with the gun's sound set, every shot, and how many impact effects are live. It is how the shotgun boom cut out by its own impact sounds was found (NOTES.md) |
| `recoiltest_hook.lua` | Gives the test its tick and its F9 button, from one line at the end of `botdamage.lua` |
| `summarise.py` | Turns the result file into a table of the climb shot by shot |

## Run it

1. Copy the Lua files (`recoiltest.lua`, `recoiltest_hook.lua`, `soundtest.lua`) into `mods/PvEDirector/Scripts` of the install and add `require("recoiltest_hook")(B)` on the line before
   `return B` at the end of `botdamage.lua`. Switch the install to offline again (`scripts\mode.ps1 offline`) so the game gets the copy.
2. Start a raid on foot, with one gun slot free (the test removes the gun in your hands, then gives the next one).
3. Stand 3 to 5 m from a flat wall and look at it. Press F9, click "Recoil test, single shot guns" (or "Recoil test, pistols"), close the menu.
4. Click the left mouse button on the wall once per shot, 5 shots per gun. Round 1 is aim down sights for every gun in turn, round 2 is the hip for every gun in turn.
   Each gun fires 5 shots with the view left free, so the recoil builds up as in play. Then the gun is taken away, the view goes back
   to eye level (the wall) and the next gun is given. A banner says which gun and round it is and how many shots are left. Pump shotguns and bolt actions take their time between clicks; wait
   for the gun to be ready.
5. The result is `bridge/recoil_test_single.txt` (or `_pistols`). `python summarise.py <that file>` prints the tables.

Not in the sets: the automatic guns, the launchers, the blowtorch, the fire extinguisher, the flamethrower, the flare gun. The shotguns
fire pellets, so their bloom lines are per pellet. The pistol set is run on its own because the pistols go into the pistol slot.
