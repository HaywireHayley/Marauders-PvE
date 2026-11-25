# Launcher test

A test tool that fires the two launchers (China Lake, Mini Thumper) by itself, from the hip and aimed, and says whether a 40mm round
goes off in your hands (#360). Test installs only: it is not part of the shipped mod.

## What is here

| File | What it is |
| --- | --- |
| `launchertest.lua` | The test: gives each launcher, fires 3 shots hip and 3 aimed with `ServerStartFire` and `ServerStopFire` (the way the rival crews fire), follows every `Proj40mm_C` and your health for 2.5 s after each shot, and writes `bridge/launcher_test.txt` |
| `launchertest_hook.lua` | Gives the test its tick and its F9 button, from one line at the end of `botdamage.lua` |

## Run it

1. Copy both files into `mods/PvEDirector/Scripts` of the install and add `require("launchertest_hook")(B)` on the line before `return B` at the
   end of `botdamage.lua`. It needs the debug menu's `debuggive.lua` (`giveGun`, bottomless mags), as the recoil test does. Switch the install to
   offline again (`scripts\mode.ps1 offline`) so the game gets the copy.
2. Start a raid on foot with a free long gun slot and a free pistol slot (the test gives the China Lake, then the Mini Thumper).
3. Stand 5 to 10 m from a flat wall and look at it. Press F9 and click "Launcher test". Or leave a file `bridge/launcher_autostart` (its text is a label,
   `far` or `near`) before the raid: the test starts 10 s after you are on foot, once.
4. Hands off the mouse and keys. The banner says which gun and shot it is on. It takes about 1 minute. For the close wall case run it again standing 2 to 3 m from the wall.
5. Read `bridge/launcher_test.txt`: a `SHOT` line per shot ending in `OK`, `SELF HIT` or `BARREL` (and `N ROUNDS` when more than one round left the gun,
   which was the twin round of the old bug), then a `ROUND` line per round with its track.
