# Docs

Reference material that sits next to the code. The research log with the reasoning and the dead ends stays in
[NOTES.md](../NOTES.md).

## internals/

How the game works inside, read out of the running game: chains of calls with flowcharts, number tables, what is still
unknown. Each file tags its facts by source: measured live, read from Blueprint bytecode, hooked, or a marked guess.
A reference here is for a chain or a table too big for a NOTES.md section, written so the next person does not have to
probe the same system again.

| File | What it covers |
| --- | --- |
| [SALVAGE_CHAIN.md](internals/SALVAGE_CHAIN.md) | Salvage from wreck to hold to airlock, offline behaviour, docking, the purge guard, how a refusal is shown on screen. |
| [DAMAGE_REFERENCE.md](internals/DAMAGE_REFERENCE.md) | How a shot becomes damage on a bot: health, hit zones, every vest and helmet rating, base damage per gun, shotguns. |
| [SPACE_GATE.md](internals/SPACE_GATE.md) | When the space gate arrives, why the on screen countdown disagreed with it, the launcher's Space gate setting, and the test record. |
| [LAUNCHERS.md](internals/LAUNCHERS.md) | The 40mm launchers: the twin round and the barrel burst, the China Lake direct hit, armour, the dead bot nudge, the quick fire flash, and the walking burst that is still not understood. |
| [BULLET_IMPACTS.md](internals/BULLET_IMPACTS.md) | How a shot becomes an impact effect: the pool of impact actors, why no bullet holes appeared offline, how the mod stamps them, surfaces, settings, cost. |
| [RECOIL.md](internals/RECOIL.md) | How the game kicks the view for every gun, hip and aimed, the measured numbers for the single shot guns and pistols, and how recoil.lua makes every gun kick what its data says. |
| [IMPACT_SOUNDS.md](internals/IMPACT_SOUNDS.md) | Why a shotgun's boom got cut at a close wall, the shared impact sound limit, the experiments, and the cap that fixes it. |

## lore/

[lore/README.md](lore/README.md): the setting for anyone writing in-world text (notes, loading-screen lines, radio,
trader patter, contract briefings). It keeps what the game says, what fans have guessed and what this project adds
apart. `fragments/` holds short in-world documents, plus `loading_lines.md` and `contracts.md`. None of it is in the game
yet: how to show it is the lore proposal issue.

## Older references

Two older references still sit at the top of the repo, written by the maintainers: [OFFLINE_AUDIT.md](../OFFLINE_AUDIT.md)
(code that never runs offline) and [AI_DESIGN.md](../AI_DESIGN.md). They can move into `internals/` when the maintainers
want that.

Adding one: give it its own file in `internals/` when a finding needs a diagram or a table, tag each fact with its
source, add it to the table above and link it from the NOTES.md section that explains why. Game files, decompiled
output, bytecode dumps and the pak key never go in here (see CONTRIBUTING.md); describe what was found instead of
pasting the dump.
