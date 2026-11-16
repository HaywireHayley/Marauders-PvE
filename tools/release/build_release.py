"""Builds the public release: release/MaraudersOffline/ and release/MaraudersOffline-<build>.zip.

    python tools/release/build_release.py [build]

<build> defaults to today's date (20261116); give a later same-day build its own, like 20261116.2. Each build is
its own GitHub release (tag public-test-<build>): never replace a published zip.

Only what a player's game needs goes in (an allow-list, so new dev files stay out by default): the launcher, the
stand-in backend with an anonymous starting account, the two mods, the two native DLLs, UE4SS, the art, the switch
scripts, and the installer, README and default settings from this folder. No notes, probes, tests, captures, dumps,
backups, saves or logs. Rebuild native/pvenet.dll and native/pvepatch.dll first if their sources changed.
"""
import json
import os
import re
import shutil
import sys
import uuid
import zipfile
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(os.path.dirname(HERE))
OUT_DIR = os.path.join(SRC, "release")
NAME = "MaraudersOffline"
DEST = os.path.join(OUT_DIR, NAME)

FILES = [  # (from, to), relative to the dev tree and the release
    ("launcher/launcher.pyw", "launcher/launcher.pyw"),
    ("launcher/saves.py", "launcher/saves.py"),
    ("launcher/update.py", "launcher/update.py"),
    ("backend/nakama_standin.py", "backend/nakama_standin.py"),
    ("scripts/mode.ps1", "scripts/mode.ps1"),
    ("scripts/launch-offline.ps1", "scripts/launch-offline.ps1"),
    ("native/pvenet.dll", "native/pvenet.dll"),
    ("native/pvepatch.dll", "native/pvepatch.dll"),
    ("config/UE4SS-settings.ini", "config/UE4SS-settings.ini"),
    ("tools/ue4ss/dwmapi.dll", "tools/ue4ss/dwmapi.dll"),
    ("tools/ue4ss/UE4SS.dll", "tools/ue4ss/UE4SS.dll"),
    ("tools/release/install.ps1", "scripts/install.ps1"),
    ("scripts/find-game.ps1", "scripts/find-game.ps1"),
    ("tools/release/uninstall.ps1", "scripts/uninstall.ps1"),
    ("tools/release/README.txt", "README.txt"),
    ("CREDITS.md", "CREDITS.md"),
    ("tools/release/PvEBridge_main.lua", "mods/PvEBridge/Scripts/main.lua"),
]
# Your own names, IDs and account strings that must never ship, one per line (untracked: they're private too).
_private = os.path.join(os.path.dirname(os.path.abspath(__file__)), "private.txt")
PRIVATE = [l.strip() for l in open(_private, encoding="utf-8")] if os.path.exists(_private) else []
PRIVATE = [s for s in PRIVATE if s and not s.startswith("#")]
if not PRIVATE:
    print("warning: tools/release/private.txt missing or empty: only dev paths are checked for")

TREES = [  # (from, to, skip): whole folders, minus names matching skip
    ("mods/PvEDirector/Scripts", "mods/PvEDirector/Scripts", r"\.whl$|^pveproject\.lua$"),
    # UE4SS's own mods, minus the dumpers and profilers (off in mods.txt anyway).
    ("tools/ue4ss/Mods", "tools/ue4ss/Mods", r"^(ActorDumperMod|LineTraceMod|SplitScreenMod|jsbLuaProfilerMod|jsbProfiler)$"),
    # The art, minus the female outfits' sources and stills nothing loads.
    ("assets", "assets", r"^src$|^ingame_sample\.png$|^list\.txt$|^hangar_vanquisher\.png$|^splash_check\.png$"),
    # Cover points the bots recorded on each map (cover.lua reads and appends to these), so players start with them.
    ("cover", "cover", r"^$"),
]
TEXT = {  # generated files: the player's default settings
    "bridge/offline_backend": "",  # read by pvenet.dll and the mods: the game's backend is the local stand-in
    "config/female_player.txt": "off\n",
    "config/minimap.txt": "shown\n",
    "config/window_mode.txt": "windowed\n",  # the launcher's "Borderless fullscreen" box
    "backend/saves/.keep": "",
}
BATS = {
    "Install.bat": r'@echo off' '\r\n' r'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"' '\r\n',
    "Uninstall.bat": r'@echo off' '\r\n' r'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1"' '\r\n',
}
DEV_ONLY_MODS = {"PvEQuitProbe", "ActorDumperMod", "LineTraceMod", "SplitScreenMod", "jsbLuaProfilerMod"}


def put(rel, data, mode="w"):
    path = os.path.join(DEST, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode, **({} if "b" in mode else {"encoding": "utf-8", "newline": ""})) as f:
        f.write(data)


def copy_tree(src, dst, skip):
    for dirpath, dirs, files in os.walk(os.path.join(SRC, src)):
        dirs[:] = [d for d in dirs if not re.search(skip, d) and d != "__pycache__"]
        for name in files:
            if re.search(skip, name):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), os.path.join(SRC, src))
            target = os.path.join(DEST, dst, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(os.path.join(dirpath, name), target)


def mods_txt():
    """The dev mods.txt minus the mods that aren't shipped."""
    with open(os.path.join(SRC, "config", "mods.txt"), encoding="utf-8") as f:
        lines = [l for l in f.read().splitlines() if l.split(":")[0].strip() not in DEV_ONLY_MODS]
    return "\n".join(lines) + "\n"


def seed():
    """The captured account with everything that identifies a player taken out. A new save only keeps its base
    cosmetics and the public news/regions anyway (saves._fresh); the rest is the shape the stand-in expects."""
    with open(os.path.join(SRC, "capture", "seed", "account.json"), encoding="utf-8") as f:
        s = json.load(f)
    s.pop("sources", None)
    s["account"]["user"].update(id=str(uuid.uuid5(uuid.NAMESPACE_URL, "marauders-offline-player")), username="offline",
                                display_name="Marauder", avatar_url="", steam_id="", metadata="{}",
                                create_time="2026-01-01T00:00:00Z", update_time="2026-01-01T00:00:00Z")
    s["account"]["wallet"] = "{}"
    s["rpcs"] = {"masterstartfunction": s["rpcs"]["masterstartfunction"]}
    s["storage"].pop("social", None)
    text = json.dumps(s, indent=1)
    for bad in PRIVATE + ["avatars.steamstatic"]:
        assert bad not in text, bad
    return text


def check():
    """No dev paths or personal names in anything shipped as text."""
    bad = re.compile("|".join(re.escape(s) for s in PRIVATE + ["Documents/MaraudersPvE"]), re.I)
    found = []
    for dirpath, _, files in os.walk(DEST):
        for name in files:
            if name.endswith((".lua", ".py", ".pyw", ".ps1", ".txt", ".ini", ".json", ".bat", ".md")):
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8", errors="ignore") as f:
                    if bad.search(f.read()):
                        found.append(os.path.relpath(path, DEST))
    return found


def main():
    # A second build on the same day gets its own name (e.g. 20261116.2), so a published zip is never replaced.
    build = sys.argv[1] if len(sys.argv) > 1 else f"{date.today():%Y%m%d}"
    zip_path = os.path.join(OUT_DIR, f"{NAME}-{build}.zip")
    if os.path.exists(zip_path):
        sys.exit(f"{zip_path} already exists: give this build a new name, e.g. {build}.2")
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST)
    for src, dst in FILES:
        target = os.path.join(DEST, dst)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(SRC, src), target)
    for src, dst, skip in TREES:
        copy_tree(src, dst, skip)
    for rel, text in TEXT.items():
        put(rel, text)
    for rel, text in BATS.items():
        put(rel, text)
    put("config/mods.txt", mods_txt())
    put("backend/seed.json", seed())
    put("version.txt", f"public-test-{build}\n")  # the launcher's update check compares this with the latest release tag

    found = check()
    if found:
        sys.exit("dev paths or personal data in: " + ", ".join(found))

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for dirpath, _, files in os.walk(DEST):
            for name in files:
                path = os.path.join(dirpath, name)
                z.write(path, os.path.join(NAME, os.path.relpath(path, DEST)))
    count = sum(len(f) for _, _, f in os.walk(DEST))
    print(f"{DEST}: {count} files\n{zip_path}: {os.path.getsize(zip_path) / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
