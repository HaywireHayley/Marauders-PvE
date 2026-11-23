# Undo last raid brings back crewmates lost in that raid: the crew file (backend/crew.lua) is kept per save and copied
# at raid start with the state (Discord report, build 24). Runs on temporary files only. CI runs it.

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "launcher"))
import saves  # noqa: E402

tmp = tempfile.mkdtemp(prefix="pve-crew-undo-")
saves.SAVES = os.path.join(tmp, "saves")
saves.LIVE, saves.RAID_COPY = os.path.join(tmp, "state.json"), os.path.join(tmp, "state.before-last-raid.json")
saves.CREW, saves.CREW_RAID_COPY = os.path.join(tmp, "crew.lua"), os.path.join(tmp, "crew.before-last-raid.lua")
saves.ACTIVE, saves.STASH_ROWS = os.path.join(tmp, "active_save.txt"), os.path.join(tmp, "stash_rows.txt")
os.makedirs(saves.SAVES)


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


a = saves.create("Crew A")
b = saves.create("Crew B")
# An old save with no crew file keeps the crew in play.
write(saves.CREW, "return { 'Noor', 'Vasko' }")
saves.activate(a)
assert read(saves.CREW) == "return { 'Noor', 'Vasko' }"
# Raid start (what the stand-in does at checkout), then Vasko dies in the raid.
write(saves.RAID_COPY, read(saves.LIVE))
write(saves.CREW_RAID_COPY, read(saves.CREW))
write(saves.CREW, "return { 'Noor' }")
saves.settle()
assert read(os.path.join(saves.SAVES, a, "crew.lua")) == "return { 'Noor' }"
assert not os.path.exists(saves.CREW_RAID_COPY)
# Another save gets its own crew and doesn't touch A's.
write(saves.CREW, "return { 'Noor' }")
saves.activate(b)
write(saves.CREW, "return {}")
saves.settle()
assert read(os.path.join(saves.SAVES, a, "crew.lua")) == "return { 'Noor' }"
assert read(os.path.join(saves.SAVES, b, "crew.lua")) == "return {}"
# Undo on A brings Vasko back, and playing A puts that crew in play.
saves.undo_last_raid(a)
assert read(os.path.join(saves.SAVES, a, "crew.lua")) == "return { 'Noor', 'Vasko' }"
assert not os.path.exists(os.path.join(saves.SAVES, a, "before-last-raid-crew.lua"))
saves.activate(a)
assert read(saves.CREW) == "return { 'Noor', 'Vasko' }"
saves.settle()
print("ok: undo last raid restores the crew, each save keeps its own")
