# Blue sky showing through interior seams

Why a blue sliver of sky showed through the walls of ships and stations while you walked, what was measured to find the
cause, and how `skyhide.lua` stops it. Code: `mods/PvEDirector/Scripts/skyhide.lua`, called from `main.lua` (`SkyHide.init`,
`SkyHide.update` from the director update, `SkyHide.reset` when a world loads). The log is the section "Sky seams in
interiors" in [NOTES.md](../../NOTES.md). Probed 2026-11-20 on a space map with the live Lua probe (`bridge/dir_eval.lua`),
the fix played from 2026-11-20 to 22.

## 1. The problem
The interiors (ships, stations) are kits of wall and floor pieces standing in the map, not sealed rooms. A few seams let
the map's sky show through as a blue sliver. The one seen most is the drop pod hatch ring against its wall hole in the
Rustbucket (the wall piece `CurvedWall_Hole_9` and the pod shell `SM_PodShell_DropPod01` of `FrigateInside_Starter_C`), and the
same ring on stations. The game never hides the sky for a player on foot, because in the real game nothing makes you
look at the seam from where it shows.

A line trace from the player straight through the seam found nothing: `0 bounds on the ray within 60 m`. So what shows in the
gap is not geometry, it is the sky behind it.

## 2. What the sky is made of (measured)
Every map has one background actor named `Node_Background_NN_C`. On the probed space map it was `Node_Background_07_C` at
(-93028, 929, -11846). Its components, read three ways (`BlueprintCreatedComponents`, attach children,
`K2_GetComponentsByClass`, all agreeing on 7):

| Component | Type | Detail |
| --- | --- | --- |
| `DefaultSceneRoot` | SceneComponent | the root |
| `Sun` | StaticMeshComponent | `Sphere_mesh`, material `MI_DevLight_Weak_Blue`, scale 200 |
| `Volume` | BoxComponent | not visible |
| `PostProcess` | PostProcessComponent | visible |
| `SM_SkyDome` | StaticMeshComponent | mesh `SM_SkyDome`, material `MI_Sky_11`, scale 400, a radius of about 16384 m |
| `ExponentialHeightFog` | ExponentialHeightFogComponent | visible |
| `DirectionalLight` | DirectionalLightComponent | colour 255 255 255, intensity 5, not visible |

Other facts from the same session, so the fix is not blamed for them:
- The map has no `SkyLight` actor, no `SkyAtmosphere` and no `VolumetricCloud` (counts 0). There is one `SkyLightComponent`,
  and it lives in `/Engine/Transient`. There are 7 `PostProcessVolume` actors, 30 `PostProcessComponent`s and 67
  `SphereReflectionCapture`s.
- Four height fog actors exist (`ExponentialHeightFog_1` twice, `*Fog2`, `*Fog`); their inscatter colours are (0.64, 0.91,
  1.00), (0.10, 0.10, 0.07), (0.49, 0.56, 0.58) and (0.14, 0.18, 0.20). The first is the light blue that matches the sliver.
- The world's only real light is the directional light of another background actor (`Node_Background_06`, see the lighting
  notes in NOTES.md), so the fix must never touch lights: it does not.

## 3. How the cause was narrowed
All with live probes that put everything back after 20 to 30 s:
1. A bisect hid, in stages, the background actor, then the pod hatch mesh, then the wall hole pieces (three components),
   then a post process volume.
2. A combined test hid the actor, three wall hole components, the pod shell and the `PostProcessVolume2` volume (6 changes),
   restored after 25 s.
3. Hiding the sun sphere alone (5811 m away) and the post process component alone were tried and restored.
4. The fog test set the four fog actors' colour to black for 30 s ("look at the gaps now"), then put them back.
5. The dome alone: `SetHiddenInGame(true)` plus `SetVisibility(false)` gave `bHiddenInGame true, visible false` and was
   restored cleanly. Hiding the dome leaves the fog's colour in the seam, hiding the fog leaves the dome. Both go.

## 4. The fix (`skyhide.lua`)
- **Finding the parts.** `find()` walks `FindAllOf("Actor")`, takes the first actor named `^Node_Background`, and reads its
  `BlueprintCreatedComponents` for `SM_SkyDome` and `ExponentialHeightFog` by name. A map without such an actor is left
  alone. A failed find is retried at most every 10 s.
- **Hiding.** `SM_SkyDome:SetHiddenInGame(true, false)`; both components get `SetVisibility(false, false)`. Showing again is
  the same calls reversed. Nothing else on the actor is touched (not the sun, the light, the post process or the volume).
  The log says `sky hidden: on foot` and `sky shown again` on each change, and `sky change failed: ...` on an error.
- **When it is hidden.** On foot only. `M.update(pc, seated)` (about twice a second) hides when you are not in a gun seat
  (`Gunseat.seated() == nil`), not piloting (your pawn is not a `RaidFrigate` or a `RaidSpaceship`, which covers the helm and
  the drop pod) and not viewing through another camera (`pc:GetViewTarget()` is not your own pawn: a turret camera or a
  viewport). In all of those the windows should show space, so the sky comes back.
- **Undoing it.** `M.reset()` puts both parts back when a raid ends or a new world loads and forgets the cached components,
  which belong to the old world.

## 5. How the rule got there (live runs)
- Version 1 hid only the dome, "aboard a ship", and was run for 6 minutes walking in and out of ships and sitting at the
  helm: the dome was hidden four times aboard and shown again each time you sat at the helm.
- Version 3 ran for 30 minutes (hidden aboard a ship, shown again at the helm) and showed the rule works in a long session.
- The shipped version hides on foot rather than "aboard a ship", so stations and ground maps get the black too, and it also hides
  the fog, which is what removed the blue left behind by the dome alone.

## 6. In game
Played 2026-11-20 to 22: the game log shows `sky hidden: on foot` and `sky shown again` at each change between walking and the
helm or a turret, with no `sky change failed` lines, and the seams are black behind the interiors instead of blue.
