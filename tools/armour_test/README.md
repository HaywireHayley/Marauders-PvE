# Armour test

A test tool that measures the game's own armour numbers by shooting dummy raiders, and writes them to a text file. It produced every
vest and helmet rating in `botdamage.lua` and `DAMAGE_REFERENCE.md`. Run it again after a game update to see whether any rating
changed. It is for test installs only: it is not part of the shipped mod, and installing it does not change the F9 menu code or any
file of the mod, only a test copy.

## What is here

| File | What it is |
| --- | --- |
| `armourtest.lua` | The test itself: the dummies, the aim lock, the hit counting and the result file |
| `armourtest_hook.lua` | Gives the test its tick, its dummy in the bots list and its F9 button, from one line at the end of `botdamage.lua` |
| `install.ps1` | Copies the two files into a test install and adds that line (or takes them out again with `-Remove`) |
| `summarise.py` | Turns the result file into the markdown tables of `DAMAGE_REFERENCE.md` and checks them against `botdamage.lua` |

## Run it

1. Make a test copy of the install (a folder that is not inside a git working tree) with the repo's current `botdamage.lua`,
   `hitzones.lua` and `outref.lua`, and `native\pvepatch.dll`. The test uses the game's kit step (`pve_roll_kit`) from that DLL and the
   shotgun pellets of `botdamage.lua`.
2. `powershell -File tools\armour_test\install.ps1 -Scripts <test install>\mods\PvEDirector\Scripts`. If the game already has its own
   copy of the mods (`RaidGame\Binaries\Win64\Mods\PvEDirector\Scripts`), run it on that folder too, or switch the install to offline
   again with `scripts\mode.ps1` so the copy is made.
3. Turn bottomless mags on (a debug item of its own; the test needs neither gun to run dry). Put the STG44 in slot 1 and the
   Liberator in slot 2.
4. Start a raid, press F9 and click Armour test.
5. First it reads the meshes of every piece without shooting (about a minute). A banner then says OKAY, KILL THEM ALL. Hold fire at
   the dummy 5 m ahead. The view is locked on the part under test, so recoil does not matter. A banner says which gun to hold.
   It runs the Liberator on a few pieces, then the STG44 on every vest and helmet. About 5 hits per zone, three zones per piece.
6. The result is `bridge\armour_test.txt` in the install folder. The SUMMARY block at the end is written only when the run finishes.

## Read the result

```
python tools\armour_test\summarise.py <install>\bridge\armour_test.txt --lua mods\PvEDirector\Scripts\botdamage.lua
```

It prints a vest table and a helmet table, and lists every mesh whose measured rating differs from `botdamage.lua`, or that one has
and the other lacks. A rating that is not a whole number is flagged: check that piece before trusting it. Put changed ratings into the
VESTS and HELMETS tables of `botdamage.lua` and into `DAMAGE_REFERENCE.md`.

## Take it out

`powershell -File tools\armour_test\install.ps1 -Scripts <folder> -Remove` deletes the two files and the hook line.

## How it measures

DAMAGE_REFERENCE.md, section 8, describes the method: one dummy per piece, 100000 health put back after every hit, the view locked on
the part under test, only hits whose line trace met that zone counted, median of 5, every other AI killed. Vest rating is the base
damage (34 for the STG44) minus the torso damage taken. Helmet rating is the base minus the head damage divided by 3.5.

## Known limits

- Needs the native `pve_roll_kit` and the hit capsules from `hitzones.lua`, so it runs on a build that has both.
- A bare head took the head multiplier twice (416.5) in the last run; helmets are measured against one application of it.
- The Liberator part checks that armour comes off each pellet, with a spread of 7 to 10 pellets per volley, so its numbers are ranges.
- Only the STG44 and Liberator are used. Other guns' base damage comes from logged hits, not from this test.
