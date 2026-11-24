# Impact sound reference

Why a shotgun's boom lost part of its sound after the first shot at a close wall, and how the mod stops it. Written 2026-11-24 on the
branch `fix/recoil-aimed-and-shotgun-sound`. The mod code is `mods/PvEDirector/Scripts/impactsound.lua`, called every frame from
`main.lua` (it acts every 2 seconds); the capture tool is `tools/recoil_test/soundtest.lua`. The reasoning and the dead ends are in
the NOTES.md section "Shotgun boom cut out by its own impact sounds"; this file is the lookup for the chain and the record of the
testing.

Every statement says where it came from:

| Source | Meaning |
| --- | --- |
| Measured | Read or watched live in game on a test install (Spaceport_01, the live bridge probes, the sound test capture). |
| Tested | Done in game and confirmed by the tester by ear. |
| Guess | Inferred, not shown. Marked so nobody builds on it by accident. |

## What this found that was not known before

1. The sound of a gun in the player's hands is played by native code. The hooks on `OnFiringSound`, `ServerStartFire` and
   `ServerStopFire` never fire for the player's own gun offline, so the gun's sound cannot be watched from Lua. (Measured)
2. Every pellet or bullet that lands takes an actor from `PooledImpactActors` (see BULLET_IMPACTS.md) and the actor plays its
   `SoundHitToUse`: `SFX_Bullet_Impact_*` and `Impact_Concrete_LightCalibre` and the like, each about 0.84 seconds long. (Measured)
3. All of those impact sounds share one concurrency asset, `/Game/Blueprints/Weapons/PooledEffects/BaseHitSoundConcurrency`:
   `MaxCount` 20, resolution rule 3, limit to owner on. Twenty impact sounds can play at once beside whatever else the game is playing.
   (Measured)
4. A shotgun lands 10 pellets a shot, and the live impact count rose by 10 for every shot fired (`impacts_live` in the sound test's
   SHOT lines). At 3 shots a second that is up to 20 impact sounds at once, on top of the boom. (Measured)
5. Offline the pool is never handed its actors back: `ReturnToPoolTime` (5 s) is client code. The live count only climbs while
   firing: in one capture it passed 250 within 9 seconds (the pool holds 511 actors in this test, 500 in the BULLET_IMPACTS count).
   It is a separate problem from the sound (it also eats particle systems) and is not fixed here. (Measured)
6. The shotgun's boom is a long cue and is shared: `Shotgun_Boom_102_Cue` is 2.325 s long, with its own limit (`ConcurrencyOverrides`
   `MaxCount` 3, `bOverrideConcurrency` false), and is both the `FireSound` and the `FireLoopSound` of the Jackhammer and the Liberator.
   The STG's `M4_Random_Shot_Cue` is 4.19 s with a `MaxCount` of 16 and was never cut at the same wall. (Measured)
7. The engine plays a limited number of voices at once (32 by default). That limit cannot be raised from Lua at runtime. When the
   impact sounds and the boom together pass it, part of the boom is dropped. Which voices the engine drops was not measured: the
   boom being the one noticed is consistent with it being long and played once per shot. (Guess)

## The symptom and where it showed

Jackhammer and Liberator: the first shot sounds right, later shots lose part of the boom. Only at a close wall: a plain tunnel wall in
Spaceport_01 (`SM_Tunnel_Wall_631`, a `StaticMeshActor`). Fired into open space, or with the STG, the sound was fine. The tester
reproduced it at that wall.

## What was tried

| Try | Result | What it rules out |
| --- | --- | --- |
| Switched off the looped fire flag (`bLoopedFireSound` false) on guns whose loop sound is the same cue as the one shot sound | Still clipped | Looped fire sound restarting the boom |
| Raised the boom cue's own concurrency to 32, then switched the override off | Still clipped | The boom cue's own limit (`MaxCount` 3) |
| Looked for reverb | The map has no audio volume actors | Reverb or an audio volume |
| Read the bot whizz code | Plays for bot shots only | Whizz sounds of the player's own shots |
| Cleared `SoundHitToUse` on the 511 pool actors | Still heard splintering and clipping | Nothing: the game sets it again on every impact, so this does not silence the impacts |
| Set the volume multiplier of the four impact cues to 0 | No clip | PROVES the impact sounds cause it |
| Left the cues alone and set `BaseHitSoundConcurrency` `MaxCount` to 6 | No clip, and the impacts still sound right | PROVES the shared limit is the lever, and is the fix |

The tester confirmed the last one by ear ("Shotgun didnt clip this time").

## What the fix does

`impactsound.lua` finds `BaseHitSoundConcurrency` with `StaticFindObject`, reads `Concurrency.MaxCount`, and writes the wanted value
only when it differs (so the game's own value is restored when the setting is 0). It runs from the director tick every 2 seconds
(so a raid that loads the asset late still gets the cap) and logs once. F3, "Effects" tab, "Impact sounds playing
at once": 6 by default, 0 to 20, 0 leaves the game's own 20. Six is enough for the impacts to still sound like impacts at a wall
while leaving the voices the boom needs.

## Not done

- A cap for other pooled sounds (bullet whizz, blood).
- Handing the pool's actors back offline (the particle systems and the live impact count; see 5 above).
- Why the engine drops the boom and not the impact sounds (see 7 above).

## The test tool

`tools/recoil_test/soundtest.lua` (a test install only). F9 "Weapon sound test" starts a capture, a second click (or 30 seconds)
ends it and writes `bridge/sound_test.txt`: a `CFG` line per gun (its sound set: `FireSound`, `FireLoopSound`, `FireFinishSound`,
`ShootSoundToUse`, `bLoopedFireSound`, the fire audio component) and a `T` line for every shot with `impacts_live` and the surface of
the first impact. The hooks exist only while a capture runs and nothing scans the world.

The settings were changed live with a probe: a Lua file `bridge/dir_eval.lua` is run once inside the game's script state when
`bridge/profile_on` exists, and its returned string is written to `bridge/dir_eval.out`. (A probe that scans every audio component
crashed the game when the file stayed in place and re ran at every launch: delete or rename a probe once it has run.)
