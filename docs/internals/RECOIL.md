# Recoil reference

How the game kicks the view when you fire, what it does for each gun, and how `recoil.lua` makes every gun kick what its weapon
data says. Written 2026-11-24 on the branch `fix/recoil-aimed-and-shotgun-sound` (issue #371). The mod code is
`mods/PvEDirector/Scripts/recoil.lua`, called every frame from `main.lua`; the measuring tool is `tools/recoil_test/`. The reasoning and
the dead ends are in the NOTES.md sections "Recoil as the weapon data says" and "Aimed recoil on single shot guns"; this file is the
lookup for the numbers and the record of the testing.

Every statement says where it came from:

| Source | Meaning |
| --- | --- |
| Measured | Read or watched live in game on a test install with tools/recoil_test (the view's pitch every frame while shots were fired at a wall). |
| Hooked | Seen by hooking a function and logging when it fired. |
| Simulated | Run through the real `recoil.lua` with a stand in for the game (a fake controller and a fake hook), not in the game. |
| Tested | Done in game and confirmed by the tester by feel, with no log. |
| Guess | Inferred, not shown. Marked so nobody builds on it by accident. |

## What this found that was not known before

1. At the hip the game gives the view no kick at all. Every gun fired from the hip left the view where it was, whatever its
   `VerticalRecoil`. (Measured, 28 automatic guns; the single shot guns and pistols were only run with the fix on)
2. Aimed, the game never reads `VerticalRecoilADS`. The Jackhammer (0.3 aimed against 2.0 at the hip) kicked 2.5 degrees a shot, as
   if it were a 2.0 gun, and the SVU and Bren kicked their hip numbers. (Measured)
3. One point of `VerticalRecoil` is 1.25 degrees of climb for one shot. That is steady over 5 shots for the automatic guns held down,
   and it is the figure the fix uses for the hip too. (Measured, 28 automatic guns)
4. `recoilModifier.Aiming` is not applied to the view. The Welrod and SPP 1 have it at 6.0, the Obrez and Sawed off at 3.0, and the
   Welrod still kicks exactly 1.25 * 3.0 = 3.75. (Measured)
5. Clicked one shot at a time, the game's own aimed kick is NOT 1.25 * `VerticalRecoil` for every gun. The De Lisle, Johnson, Double
   barrel, Terminator, Trench gun, Welrod, SPP 1 and Sawed off give it. The Reising, M1 Carbine Para, SVT 40, AC14, both 1911s, the
   Luger P08, the M712, the Webley, the Obrez and the MAS 44 give a fraction of it (from almost nothing, the M712, to about half, the Webley). The Liberators give a
   different amount every shot. Nothing in the weapon data separates the two groups, and the shot rate does not either (the Obrez, at
   one shot every 2.6 seconds, is in the weak group; the Johnson, at one every 0.19, is in the full group). (Measured, no cause found)
6. The weapon's own `currentRecoil` and `currentBulletSpread` stay 0.0 offline, so they cannot be read as the recoil or the bloom. The
   native code writes the view's rotation directly, so there is nothing to hook before it. (Measured, Hooked)
7. The live `WeaponConfig` of every gun equals the pak data, so nothing rewrites it after load. (Measured)
8. The game's kick lands within about 0.1 seconds of the shot hook (`RaidWeapon:ServerMultiSimulateWeaponFire`): a Johnson's starts
   about 0.02 s before the hook runs, a Terminator's about 0.01 s after, a Double barrel's about 0.06 s after, and it finishes in two
   to four frames. (Measured)

## The numbers per gun

One row per gun of the single shot set and the pistol set (the automatic guns are in the NOTES.md section and match
1.25 * `VerticalRecoil` aimed). 5 shots each, clicked by hand at a wall, mod fix partly in place (see the note under the table).
Degrees of climb per shot.

| Gun | Class | Vertical | Vertical ADS | Hip kick a shot | Game's own aimed kick a shot | Data asks aimed | Aimed shot gap (s) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Reising | `Rifle_M50reising_Child_C` | 2.00 | 2.00 | 2.50 | 0.80 | 2.50 | 0.37 |
| Johnson | `Rifle_Johnson_Child_C` | 4.00 | 4.00 | 5.00 | 5.02 | 5.00 | 0.19 |
| SVT 40 | `Rifle_SVT40_Child_C` | 2.75 | 2.75 | 3.43 | 0.60 | 3.44 | 0.18 |
| M1 Carbine Para | `Rifle_M1_Para_Child_C` | 1.50 | 1.50 | 1.88 | 0.34 | 1.88 | 0.24 |
| MAS 44 | `Rifle_Mas44_Child_C` | 3.00 | 3.00 | 3.75 | 1.73 | 3.75 | 0.21 |
| De Lisle | `Rifle_DeLisle_Child_C` | 3.00 | 3.00 | 3.74 | 3.75 | 3.75 | 2.13 |
| M16 | `Rifle_M16_Child_C` | 1.75 | 1.75 | 2.15 | 1.53 | 2.19 | 0.12 |
| AC14 | `Rifle_AC14_Child_C` | 2.20 | 2.20 | 2.75 | 0.56 | 2.75 | 0.28 |
| Custom Mat 49 | `Rifle_CustomMat49_Child_C` | 1.65 | 1.65 | 2.06 | 1.60 | 2.06 | 0.16 |
| Liberator | `Shotgun_Liberator_Child_C` | 2.50 | 0.30 | 3.12 | 1.14 | 0.38 | 0.28 |
| Heavy Liberator | `Shotgun_HeavyLiberator_Child_C` | 2.50 | 0.30 | 3.12 | 3.06 | 0.38 | 0.27 |
| Trench gun | `Shotgun_TrenchGun_Child_C` | 6.50 | 0.75 | 8.12 | 8.13 | 0.94 | 0.45 |
| Double barrel | `Shotgun_LongDouble_Child_C` | 2.50 | 2.50 | 3.12 | 3.12 | 3.12 | 0.45 |
| Terminator | `Shotgun_Terminator_Child_C` | 3.00 | 3.00 | 3.75 | 3.75 | 3.75 | 0.44 |
| M1911 | `Pistol_1911_Child_C` | 2.50 | 2.25 | 3.12 | 0.43 | 2.81 | 0.27 |
| M1911 G | `Pistol_1911_G_Child_C` | 2.50 | 2.25 | 3.13 | 0.47 | 2.81 | 0.19 |
| Luger P08 | `Pistol_P08_Child_C` | 2.00 | 2.00 | 2.49 | 0.88 | 2.50 | 0.18 |
| M712 | `Pistol_M712_Child_C` | 2.25 | 2.25 | 2.82 | 0.11 | 2.81 | 0.30 |
| Webley | `Pistol_Webley_Child_C` | 4.00 | 4.00 | 5.00 | 2.63 | 5.00 | 0.19 |
| Welrod | `Pistol_Welrod_Child_C` | 3.00 | 3.00 | 3.74 | 3.75 | 3.75 | 2.12 |
| SPP 1 | `Pistol_SPP1_Child_C` | 3.00 | 3.00 | 3.75 | 3.75 | 3.75 | 0.34 |
| Obrez | `Pistol_Mosin_Child_C` | 4.00 | 4.00 | 4.99 | 1.24 | 5.00 | 2.58 |
| Sawed off | `Shotgun_SawedOffDouble_Child_C` | 3.00 | 3.00 | 3.75 | 3.75 | 3.75 | 0.38 |

How to read it:
- "Hip kick a shot" is the mean of shots 2 to 4 with the fix on. It is 1.25 * `Vertical` for every gun, which is the point of the fix:
  the game's own hip kick is zero.
- "Game's own aimed kick a shot" is what the game itself did, the mean of shots 2 to 4, with what the first version of the fix added
  taken back off (for the Liberators, the Trench gun and the 1911s, whose aimed value differs from the hip one). It is the number the
  closed loop in the fix measures for itself, shot by shot. "Data asks aimed" is 1.25 * `Vertical ADS`.
- A kick that lands at the edge of one shot's window is counted in the next, so single shots jump around by a fraction of a degree
  and the shot 1 and shot 5 readings are not used. A doubled 5th shot in the hip rows (the Reising, SVT 40, Custom Mat 49, Webley
  and others) is a second click inside the window, not the fix. The Johnson's own kick grew over its first shots
  (3.05, 3.05, 5.0, 5.0 in one run), so the game's own kick is not constant even for one gun.
- The Heavy Liberator and the Liberator have the same weapon data and the game still gave them different amounts in the same test
  (1.1 against 3.1 a shot). That is the game, not the fix: their kick changes from shot to shot.
- Guesses: why the weak group is weak. It could be a per gun recoil curve in a data table the mod does not read, or a recovery that
  runs in the gap between clicks. No sign of recovery was seen in the view (it stays flat between shots).

## What the fix does

`recoil.lua` hooks `RaidWeapon:ServerMultiSimulateWeaponFire`, registered lazily on the first frame of a raid (the weapon class is not
loaded when the script loads), and acts only on shots of the player's pawn
(`PlayerPawn_C`). D is 1.25 degrees of climb per point.

Hip (`IsTargeting()` false, `CFG.HIP_KICK` on): the whole kick is added.
- pitch: `D * VerticalRecoil * RECOIL_SCALE * HIP_SCALE * state`, with `state` the product of the weapon's `recoilModifier.Crouching`
  (crouched), `.Moving` (horizontal speed over 100 cm/s) and `.InAir` (falling)
- yaw: a random value between `HorizontalRecoilMin` and `HorizontalRecoilMax`, times the same factor

Aimed: the game kicks, and the fix tops that up or cuts it so the shot's whole kick is `D * VerticalRecoilADS * RECOIL_SCALE`.
1. At the hook the shot is queued with its target and a cap of `1.5 * D * VerticalRecoil + 0.5`.
2. Every frame the view's pitch is sampled, less everything `recoil.lua` has itself added (`ownSum`), into 0.4 seconds of history.
3. When 0.12 s have passed since the hook the shot's window is closed. The window runs from 0.04 s before the hook to 0.12 s after
   it, never starting before the previous shot's window ended and never running past 0.04 s before the next shot. The game's own
   kick is the movement of the sampled pitch across the window, wrapped the short way round 360.
4. That movement is held between 0 and the cap (the mouse also moves the view; this stops a flick being taken as recoil), and the
   difference between the target and the measured kick is added to the pending climb. It is negative when the game kicked more than
   the data asks, which is the Jackhammer, the Trench gun, the SVU and the Bren.
5. The pending climb goes onto the view every frame at `dt / 0.04` of what is left (about 0.1 seconds in all), and what is applied is
   added to `ownSum`, so it never counts as the game's kick in the next window.

Why it measures. The first version assumed the game gave 1.25 * `VerticalRecoil` aimed and subtracted that (it was right for all 28
automatic guns) before adding the data's value. For a gun where the game gives less, that took the view DOWN: the Liberator, whose
data asks 0.38 aimed against 3.12 at the hip, went down 1.3 to 2.7 degrees a shot. A second version listed those guns and left them
alone; measuring the kick for every shot supersedes it and fixes the weak guns too.

Settings (F3, "Recoil" tab; `recoil.CFG`): `RECOIL_FIX` (1 data's recoil, 0 the game's own), `ADS_VALUES` (1 aimed shots use
`VerticalRecoilADS`, 0 they use `VerticalRecoil` like the game), `HIP_KICK`, `RECOIL_SCALE` (every gun, aimed and hip), `HIP_SCALE`
(the hip's share on top).

## Checks

- Simulated (the real `recoil.lua`, a fake game that kicks by a given amount in two frames): every case below ends on
  1.25 * `VerticalRecoilADS` a shot to two decimals, 5 shots, aimed. At the hip a Trench gun that the game does not kick climbs
  8.12 a shot.

| Case | Game's own kick | Result a shot | Data asks |
| --- | --- | --- | --- |
| Liberator, nothing | 0, 0, 0, 0, 0 | 0.37 | 0.38 |
| Liberator, erratic | 0.1, 1.4, 1.3, 0.7, 0.3 | 0.37 | 0.38 |
| Trench gun, full | 8.125 each | 0.94 | 0.94 |
| Reising, weak | 0.8 each | 2.50 | 2.50 |
| Johnson, growing | 3.05, 3.05, 5, 5, 5 | 5.00 | 5.00 |
| Terminator, full | 3.75 each | 3.75 | 3.75 |
| Double barrel, kick 0.06 s late | 3.125 each | 3.12 | 3.12 |
| M1911, weak | 0.1 each | 2.81 | 2.81 |
| M16, shots 0.09 s apart | 0.3 each | 2.19 | 2.19 |
| Jackhammer, game kicks 2.5 | 2.5 each | 0.38 | 0.38 |

- Tested: after the closed loop went in, the tester said the Liberator was fixed in game. Nothing was logged from that run, so the
  per gun aimed numbers above are from the run BEFORE the closed loop. The check that is still to do is
  `tools/recoil_test` aimed rows for both sets, expecting about "Data asks aimed" for every gun and nothing going down.
- Not tested in game: the automatic guns after the closed loop (the first version of the fix was tested on them: "feels
  phenomenal"), bolt actions, the launchers, crouching and moving while aimed.

## Not covered

- The crouch and moving modifiers while aimed (the hip applies them; aimed the data has no figure for them).
- The sideways drift of the guns with an `AngleMin` and `AngleMax` (Viper, Thompson, Krasa, MG42, Jackhammer drift far more than their
  horizontal numbers say; the Johnson has 13 to 15 degrees). Yaw is only added at the hip.
- Bolt actions: not in the single shot set run here.
- Shots closer than about 0.16 seconds share a window; the kick is split between them by time, and an automatic gun at 600 rounds a
  minute (0.1 s) is measured over shorter windows, so its figure is rougher (the check on a simulated M16 at 0.09 s was exact).
- The cause of the weak group in item 5 above.

## The test tool

`tools/recoil_test/` (a test install only, see its README). F9 "Recoil test, single shot guns" and "Recoil test, pistols": it swaps the
guns, forces aim down sights on and off, puts the view back at eye level between guns, and writes `bridge/recoil_test_single.txt` or
`bridge/recoil_test_pistols.txt`: a `CFG` line per gun (the live weapon data), the view's pitch and yaw every frame for 0.35 s around each
shot (`F` rows), the bloom of each shot (`S` rows), and a `GUN` line per gun. `summarise.py` prints the climb per shot and the bloom per
shot. The automatic guns' version (hold the button) was the first one and is in the git history of this work.
