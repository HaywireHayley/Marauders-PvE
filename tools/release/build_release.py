"""Builds the public release: release/MaraudersOffline/ and release/MaraudersOffline-<build>.zip.

    python tools/release/build_release.py [build]
    python tools/release/build_release.py --repackage <build>   (zips the release/MaraudersOffline/ already built)

<build> defaults to today's date (20261116); give a later same-day build its own, like 20261116.2. Each build is
its own GitHub release (tag public-test-<build>): never replace a published zip.

Only what a player's game needs goes in (an allow-list, so new dev files stay out by default): the launcher, the
stand-in backend with an anonymous starting account, the two mods, the two native DLLs, UE4SS, the art, the switch
scripts, and the installer, README and default settings from this folder. No notes, probes, tests, captures, dumps,
backups, saves or logs. Rebuild native/pvenet.dll and native/pvepatch.dll first if their sources changed.

What to upload (uploads over ~10 MB failed from the maintainer's connection, 2026-11-19, so every file is kept under
PART_MAX): MaraudersOffline-<build>.zip, the build without its two big dependencies (the one the launcher's updater
takes), and the dependencies as MaraudersOffline-<build>-deps-*.zip (UE4SS.dll; the female meshes in parts). Every zip
has the same top folder, so a new player extracts them all into one place. The names with "-deps-" and "-full" never
match the updater's main-zip pattern. The main zip holds deps.json (each part's files and their SHA-256): the updater
compares it with the files a player has and downloads only the parts that changed (a remade mesh, a new UE4SS).
MaraudersOffline-<build>-full.zip is everything in one zip, for when a big upload works.
MaraudersOffline-<build>-installer.zip (a few KB: the installer, scripts/bootstrap.py and the launcher's update.py) is
the one a new player needs: Install.bat downloads the latest build and its dependency parts from GitHub, checks and
installs them, then sets up as usual. Upload it with the others; "-installer" never matches the updater's patterns.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
import zipfile
import zlib
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
    ("launcher/report.py", "launcher/report.py"),
    ("backend/nakama_standin.py", "backend/nakama_standin.py"),
    ("scripts/mode.ps1", "scripts/mode.ps1"),
    ("scripts/launch-offline.ps1", "scripts/launch-offline.ps1"),
    ("scripts/launch-helpers.ps1", "scripts/launch-helpers.ps1"),
    ("native/pvenet.dll", "native/pvenet.dll"),
    ("native/pvepatch.dll", "native/pvepatch.dll"),
    ("config/UE4SS-settings.ini", "config/UE4SS-settings.ini"),
    ("config/raid_conditions.txt", "config/raid_conditions.txt"),  # the raid conditions (#78, conditions.lua)
    ("tools/ue4ss/dwmapi.dll", "tools/ue4ss/dwmapi.dll"),
    ("tools/ue4ss/UE4SS.dll", "tools/ue4ss/UE4SS.dll"),
    ("tools/release/install.ps1", "scripts/install.ps1"),
    ("tools/release/bootstrap.py", "scripts/bootstrap.py"),  # the slim installer's download (installer zip)
    ("scripts/find-game.ps1", "scripts/find-game.ps1"),
    ("tools/release/uninstall.ps1", "scripts/uninstall.ps1"),
    ("tools/release/README.txt", "README.txt"),
    ("CREDITS.md", "CREDITS.md"),
    ("tools/release/PvEBridge_main.lua", "mods/PvEBridge/Scripts/main.lua"),
    # Linux / Steam Deck (issue #127): the mode switch without PowerShell, the Steam launch option, the installer
    ("scripts/pvemode.py", "scripts/pvemode.py"),
    ("linux/marauders-offline.sh", "linux/marauders-offline.sh"),
    ("linux/install.sh", "linux/install.sh"),
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
    # (not intro/: the re-cut startup video has a song in it, this install only, as .gitignore says)
    ("assets", "assets", r"^src$|^intro$|^ingame_sample\.png$|^list\.txt$|^hangar_vanquisher\.png$|^splash_check\.png$"
               r"|^ahtu-.*\.png$|\.floors$"),  # (Ahtu's full-size sources and the plan scans' floor dumps: tools input only)
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
    captured = os.path.join(SRC, "capture", "seed", "account.json")
    if not os.path.exists(captured):
        # No capture in this checkout (capture/ stays private): ship the repository's own backend/seed.json, which is
        # this function's output already. The privacy check still runs on it.
        with open(os.path.join(SRC, "backend", "seed.json"), encoding="utf-8") as f:
            text = f.read()
        for bad in PRIVATE + ["avatars.steamstatic"]:
            assert bad not in text, bad
        return text
    with open(captured, encoding="utf-8") as f:
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


# The maintainer's public handle may contain a private name: the repository's URLs (the updater needs them) and the guild
# officer named after it in guild.lua ship on purpose. Only these exact forms are let through.
PUBLIC = re.compile(r"HaywireHayley|Haywire Hayley")


def check():
    """No dev paths or personal names in anything shipped as text."""
    bad = re.compile("|".join(re.escape(s) for s in PRIVATE + ["Documents/MaraudersPvE"]), re.I)
    found = []
    for dirpath, _, files in os.walk(DEST):
        for name in files:
            if name.endswith((".lua", ".py", ".pyw", ".ps1", ".sh", ".txt", ".ini", ".json", ".bat", ".md")):
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8", errors="ignore") as f:
                    if bad.search(PUBLIC.sub("", f.read())):
                        found.append(os.path.relpath(path, DEST))
    return found


def make_female():
    """The female outfit meshes (assets/female/pak) are made per checkout from the game's pak by
    tools/female/make_female.py and never committed (they're extracted game files). Whatever is in that folder is what
    players get, so it's made again here for every build: meshes left from before a change to make_female.py or
    assets/female/list.txt would ship as they are, with valid checksums, and every player would keep the old shape.
    Stops the build if any mesh can't be made (no game, no pak key)."""
    script = os.path.join(SRC, "tools", "female", "make_female.py")
    with open(os.path.join(SRC, "assets", "female", "list.txt"), encoding="utf-8") as f:
        want = len(f.read().split())
    print("Making the female meshes (tools/female/make_female.py)...")
    r = subprocess.run([sys.executable, script], cwd=SRC, capture_output=True, text=True)
    lines = r.stdout.splitlines()
    made = [l for l in lines if l.split(" ")[1:2] == ["ok"]]
    if r.returncode or len(made) != want:
        bad = [l for l in lines if l.strip() and l not in made] + r.stderr.strip().splitlines()[-5:]
        sys.exit(f"female meshes: {len(made)} of {want} made, so no release (it would ship old or missing meshes).\n"
                 + "\n".join(bad[:15]))
    print(f"  {len(made)} meshes")


# What makes the female meshes: if none of these changed since a release, that release's meshes are what
# make_female.py would make now.
FEMALE_RECIPE = ("tools/female", "assets/female/list.txt")


def female_from_release():
    """Without the pak key or repak (no make_female.py here), the female meshes of the latest release, when nothing
    that makes them (FEMALE_RECIPE) changed since its tag: its -deps-female-* zips, each checked against GitHub's SHA-256,
    every file then checked against that release's own deps.json, put into assets/female/. Stops the build otherwise."""
    sys.path.insert(0, os.path.join(SRC, "launcher"))
    import tempfile
    import update  # launcher/update.py: the launcher's checked downloads
    rel = update.latest(timeout=20)
    if not rel:
        sys.exit("female meshes: no pak key here, and GitHub's latest release couldn't be read to take them from")
    tag = rel["tag"]
    if subprocess.run(["git", "rev-parse", "--verify", "-q", tag], cwd=SRC, capture_output=True).returncode:
        subprocess.run(["git", "fetch", "-q", "upstream", "--tags"], cwd=SRC, capture_output=True)
    diff = subprocess.run(["git", "diff", "--quiet", tag, "HEAD", "--", *FEMALE_RECIPE], cwd=SRC, capture_output=True)
    if diff.returncode != 0:
        sys.exit(f"female meshes: no pak key here, and {' or '.join(FEMALE_RECIPE)} changed since {tag} (or its tag "
                 "isn't fetched): its meshes would be the old shape. Build where make_female.py can run.")
    parts = sorted(p for p in (rel.get("deps") or {}) if p.startswith("female"))
    if not parts:
        sys.exit(f"female meshes: {tag} has no -deps-female- zips to take them from")
    print(f"Female meshes: no pak key here; taking them from {tag} (unchanged since: {', '.join(FEMALE_RECIPE)})...")
    tmp = tempfile.mkdtemp(prefix="pve-female-")
    try:
        main_zip = update.fetch(rel["zip_url"], rel.get("sha256"), tmp)
        want = {}
        for part, files in (update.zip_deps(main_zip).get("parts") or {}).items():
            if part.startswith("female"):
                want.update(files)
        if not want:
            sys.exit(f"female meshes: {tag}'s deps.json lists no female files")
        got = {}
        for part in parts:
            path = update.fetch(rel["deps"][part]["url"], rel["deps"][part]["sha256"], tmp)
            with zipfile.ZipFile(path) as z:
                for n in z.namelist():
                    if n.endswith("/"):
                        continue
                    r = n[len(NAME) + 1:] if n.startswith(NAME + "/") else None
                    if not r or not r.startswith("assets/female/") or ".." in r.split("/"):
                        sys.exit(f"female meshes: unexpected file {n} in {os.path.basename(path)}")
                    got[r] = z.read(n)
        if set(got) != set(want):
            sys.exit(f"female meshes: {tag}'s zips hold {len(got)} files, its deps.json lists {len(want)}")
        for r, data in got.items():
            if hashlib.sha256(data).hexdigest() != want[r]:
                sys.exit(f"female meshes: {r} doesn't match {tag}'s deps.json")
        pak = os.path.join(SRC, "assets", "female", "pak")
        if os.path.isdir(pak):
            shutil.rmtree(pak)  # nothing left over from another recipe
        for r, data in got.items():
            dst = os.path.join(SRC, *r.split("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as f:
                f.write(data)
        print(f"Female meshes: {len(got)} files from {tag}, every one matching its deps.json")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def female_meshes():
    """make_female.py where it can run (the pak key and repak are here), else the latest release's (female_from_release)."""
    if os.path.exists(os.path.join(SRC, "backup", "keys", "pak.key")) and os.path.exists(
            os.path.join(SRC, "tools", "repak", "repak.exe")):
        make_female()
    else:
        female_from_release()


PART_MAX = 9_000_000  # bytes of compressed data per zip (uploads over ~10 MB were cut off, 2026-11-19)
# The dependencies: big and seldom changed, so the updater downloads them only when deps.json says they did.
DEPS_FILE = "deps.json"
DEPS = (("ue4ss", lambda rel: rel == "tools/ue4ss/UE4SS.dll"),
        ("female", lambda rel: rel.startswith("assets/female/")))


def write_zip(path, rels):
    """A zip of these files from DEST, under NAME/ (.sh files executable when unzipped on Linux)."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel in rels:
            src = os.path.join(DEST, rel)
            arc = NAME + "/" + rel
            if rel.endswith(".sh"):  # a Windows build has no mode bits
                info = zipfile.ZipInfo.from_file(src, arc)
                info.external_attr = (0o100755 << 16)
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(src, "rb") as f:
                    z.writestr(info, f.read())
            else:
                z.write(src, arc)


# The slim installer zip: just enough for Install.bat to fetch and install the latest build (bootstrap.py).
INSTALLER = (("tools/release/install.ps1", "scripts/install.ps1"), ("scripts/find-game.ps1", "scripts/find-game.ps1"),
             ("tools/release/bootstrap.py", "scripts/bootstrap.py"), ("launcher/update.py", "launcher/update.py"),
             ("tools/release/README.txt", "README.txt"), ("CREDITS.md", "CREDITS.md"))


def write_installer(build, out_dir=OUT_DIR):
    """MaraudersOffline-<build>-installer.zip, from the dev tree (it needs no game files, so it can be made anywhere)."""
    path = os.path.join(out_dir, f"{NAME}-{build}-installer.zip")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for src, dst in INSTALLER:
            z.write(os.path.join(SRC, src), NAME + "/" + dst)
        z.writestr(NAME + "/Install.bat", BATS["Install.bat"])
    return path


def package(build):
    """The zips to upload, from DEST (see the docstring). Returns their paths."""
    rels = sorted(os.path.relpath(os.path.join(d, n), DEST).replace(os.sep, "/")
                  for d, _, names in os.walk(DEST) for n in names)
    rels = [r for r in rels if r != DEPS_FILE]  # remade below (--repackage finds the last one)
    groups = {key: [r for r in rels if test(r)] for key, test in DEPS}
    main_rels = [r for r in rels if not any(test(r) for _, test in DEPS)]
    manifest = {}  # part name ("female-2of6") -> {file: sha256}
    for key, members in groups.items():
        parts, part, size = [], [], 0
        for rel in members:  # filled in path order by compressed size
            with open(os.path.join(DEST, rel), "rb") as f:
                n = len(zlib.compress(f.read(), 6))
            if part and size + n > PART_MAX:
                parts.append(part)
                part, size = [], 0
            part.append(rel)
            size += n
        if part:
            parts.append(part)
        for i, part in enumerate(parts, 1):
            tag = key if len(parts) == 1 else f"{key}-{i}of{len(parts)}"
            manifest[tag] = {}
            for rel in part:
                with open(os.path.join(DEST, rel), "rb") as f:
                    manifest[tag][rel] = hashlib.sha256(f.read()).hexdigest()
    put(DEPS_FILE, json.dumps({"parts": manifest}, indent=1, sort_keys=True) + "\n")
    rels, main_rels = sorted(rels + [DEPS_FILE]), main_rels + [DEPS_FILE]
    full = os.path.join(OUT_DIR, f"{NAME}-{build}-full.zip")
    write_zip(full, rels)
    out = [os.path.join(OUT_DIR, f"{NAME}-{build}.zip")]
    write_zip(out[0], main_rels)
    for tag, files in manifest.items():
        path = os.path.join(OUT_DIR, f"{NAME}-{build}-deps-{tag}.zip")
        write_zip(path, sorted(files))
        out.append(path)
    out.insert(0, write_installer(build))
    for path in out:
        if os.path.getsize(path) > PART_MAX + 500_000:
            sys.exit(f"{path} is {os.path.getsize(path) / 1e6:.1f} MB: over PART_MAX")
    print(f"{full}: {os.path.getsize(full) / 1e6:.0f} MB (everything; not for upload over a bad connection)")
    print("Upload these:")
    for path in out:
        print(f"  {os.path.basename(path)}  {os.path.getsize(path) / 1e6:.1f} MB")
    return out


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--repackage":
        if not os.path.exists(os.path.join(DEST, "version.txt")):
            sys.exit(f"nothing built in {DEST}")
        package(sys.argv[2])
        return
    # A second build on the same day gets its own name (e.g. 20261116.2), so a published zip is never replaced.
    build = sys.argv[1] if len(sys.argv) > 1 else f"{date.today():%Y%m%d}"
    zip_path = os.path.join(OUT_DIR, f"{NAME}-{build}.zip")
    if os.path.exists(zip_path):
        sys.exit(f"{zip_path} already exists: give this build a new name, e.g. {build}.2")
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST)
    female_meshes()
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

    count = sum(len(f) for _, _, f in os.walk(DEST))
    print(f"{DEST}: {count} files")
    package(build)


if __name__ == "__main__":
    main()
