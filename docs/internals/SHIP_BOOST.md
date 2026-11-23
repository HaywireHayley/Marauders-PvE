# Ship speed and the Rustbucket boost

What the Rustbucket's speed and boost are, how they work in this mod, and everything measured on the way. Code:
`shipspeed.lua`, the per frame hook in `main.lua`, and `gatetaps.lua` (which counts boost presses). Issue #207 for the first
version (2026-11-19); the Shift key, the Rustbucket only rule and the sounds came after (2026-11-22).

## 1. The numbers behind the speed

**Measured** on Space_Alpha, with the Rustbucket possessed from Lua and W held through `keybd_event`: a frigate's top speed
is `CharacterMovement.MaxFlySpeed` exactly (1000 cm/s, reached in about 4 s at `MaxAcceleration` 256). Class defaults, read
with `GetCDO()`:

| Ship | MaxFlySpeed (cm/s) | MaxAcceleration |
| --- | --- | --- |
| Rustbucket, Scout, Frigate | 1000 | 256 |
| Fast, VIP | 1100 | 512 |
| Red Baron's strike frigate | 1200 | 512 |
| Capital | 1000 | 512 |
| Drop pod | 800 | 1024 |

Rival Rustbuckets are Scout pawns, so `Ship_StarterFrigate01_Pawn_C` is only ever the player's ship. That is how
`shipspeed.lua` knows which ship is the Rustbucket (`RUSTBUCKET = "Ship_StarterFrigate01_Pawn_C"`).

The drop pod has a native boost on `ARaidSpaceship` (`ServerBoost`, `BoostLength` 4, `CooldownBoostLength` 12,
`IsBoosting`). Frigates are `ARaidFrigate` and have none, so the mod builds one with the same timings.

## 2. What the mod does

All values are in `shipspeed.lua` `CFG`.

| Setting | Value | Meaning |
| --- | --- | --- |
| `RUSTBUCKET_SPEED` | 1.25 | 1000 to 1250 cm/s: past the Fast frigate (1100), behind the Baron's (1200 times the boost) |
| `RUSTBUCKET_ACCEL` | 1.5 | 256 to 384: up to speed in about 3 s instead of 4 |
| `BOOST_SPEED` | 1.8 | top speed while boosting |
| `BOOST_ACCEL` | 4 | acceleration while boosting |
| `BOOST_SECONDS` | 4 | as the pod's |
| `BOOST_COOLDOWN` | 12 | as the pod's, counted from the end of the boost |

- **Base speed.** While you fly the Rustbucket, `M.update` (from the director update, twice a second, space maps only)
  writes `MaxFlySpeed` times 1.25 and `MaxAcceleration` times 1.5 to its movement component. Measured after: top speed
  1250, `MaxAcceleration` 384. Offline the game is the authority, so writing the component is enough. The base values come
  from the class default object and are cached per class name.
- **Boost: Rustbucket only.** Other frigates are left exactly as the game has them.
- **Boost key: whatever the game has bound to Run** (Shift by default, `Input.ini` ActionMappings, so a remap follows),
  **held**, not toggled. `main.lua` calls `ShipSpeed.frame` every raid tick on a space map; it polls `Keys.down(pc, "Run",
  "LeftShift")` at most every 0.04 s (`keys.lua`, `pc:IsInputKeyDown`) and only while you are at the Rustbucket's helm or
  a boost is running, so it costs nothing elsewhere. Pressing starts the boost, letting go ends it, and the 4 s ends it if
  you hold on. The poll is skipped while the mouse cursor is showing (a menu is open).
- **Why Run and not Space.** The first version used Space (`RegisterKeyBind(Key.SPACE, ...)`). Space is the game's ship
  up (the MoveUp axis), so it could not also be the boost key. This UE4SS has no Shift key for `RegisterKeyBind`
  (`Key` has only `ModifierKey.SHIFT`), which is why the key is polled rather than bound. Run is an on foot action; nothing
  at a frigate's helm uses it.
- **Start.** Raising the top speed alone barely helps: the ship gains speed slowly (1250 to 1440 cm/s over 4 s, measured:
  the thrust ramps, it is not `MaxAcceleration`). So the boost starts at full speed: `CharacterMovement.Velocity` is set to
  the new top speed along the direction of travel, or along the nose from a standstill, and the raised top speed keeps it
  there while you hold W. **Measured:** 1250 to 2204 cm/s at once, about 2000 at the end of the 4 s, back to 1250 within
  about 4 s after.
- **Cooldown.** A press during the 12 s shows "Boost recharging: N s". Letting go early also starts the 12 s. The next
  boost is ready at once in a new raid (`M.reset`).
- **Sounds.** The drop pod's own boost sounds, all SoundCues, played 2D because only the pilot hears the boost:
  `/Game/Sounds/Ships/EF_ShipPod_Boosting_OneShot` as it starts, `EF_ShipPod_Boosting_EngineLoop` while it lasts (the
  audio component `SpawnSound2D` returns is kept so letting go can `Stop()` it) and `EF_ShipPod_BoostEnd_OneShot01` as it
  ends. A cue the game has unloaded is loaded again with `LoadAsset`.
  A probe first checked that `GameplayStatics:SpawnSound2D`, `PlaySound2D`, `CreateSound2D`, `SpawnSoundAttached` and
  `AudioComponent:Stop` / `FadeOut` exist in this UE4SS, and that all three cues load as `SoundCue`.
- **Messages.** "BOOST", "Boost spent: ready again in 12 s", "Boost off: ready again in 12 s" (key let go), "Boost
  recharging: N s", through `pc:ClientMessage(text, FName("Event"), 2.5)`.
- **Leaving the helm** ends a running boost without the end sound (cause "helm").

## 3. Gate taps

`gatetaps.lua` (#332, "tap the gate plate twice on the way out") counts boost presses. `M.boost` calls `gatetaps.tap()` at
every press at the helm, before the cooldown checks, so a recharging boost still counts. Since the boost is the Rustbucket's
only, and the key is Run, the taps are Shift presses at the Rustbucket's helm; another ship's helm never reaches `M.boost`.
Exactly two taps in the last 6 s before the ship enters the gate's evac volume gives a gold coin in the gift box.

## 4. Pitfalls found

- The director's own 0.5 s update puts the speeds back, so hand written values in a probe are undone within half a second.
- `M.update` is the only writer of the base speed. Anything else that writes `MaxFlySpeed` on the Rustbucket gets
  overwritten.
- Co-op: a joiner's boost would be undone by the host's movement of that ship (not handled).

## 5. In game

Chandler flew the Rustbucket with the Shift boost on 2026-11-22 and it worked: the log shows `ship boost:
Ship_StarterFrigate01_Pawn_C, up to 4 s while the key is held` on the press, no errors in the boost hook.
