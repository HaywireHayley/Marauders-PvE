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

Two older references still sit at the top of the repo, written by the maintainers: [OFFLINE_AUDIT.md](../OFFLINE_AUDIT.md)
(code that never runs offline) and [AI_DESIGN.md](../AI_DESIGN.md). They can move into `internals/` when the maintainers
want that.

Adding one: give it its own file in `internals/` when a finding needs a diagram or a table, tag each fact with its
source, add it to the table above and link it from the NOTES.md section that explains why. Game files, decompiled
output, bytecode dumps and the pak key never go in here (see CONTRIBUTING.md); describe what was found instead of
pasting the dump.
