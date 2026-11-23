"""Report a problem (issue #96): one zip with what a bug report needs, written to the Desktop.

    report.build(root, game_folder, save_dir=None, crash=True) -> path of the zip

Holds: the mod's logs (backend/last_game.log, server.log, standin_err.log, coverage.json), the game's UE4SS.log (its last 4 MB), the
newest crash report from the last three days (CrashContext.runtime-xml, and its UE4Minidump.dmp if `crash`), the build
(version.txt), Windows and Python versions, and the save's state.json if `save_dir` is given.
Before zipping, text files lose what identifies the player: the Windows user name (and user folder) in paths, Steam IDs,
and the account's own names from the save.
"""
import json
import os
import platform
import re
import sys
import time
import zipfile
from datetime import datetime

TAIL = 4 * 1024 * 1024        # the most of a log kept (its end)
CRASH_DAYS = 3
STEAM_ID = re.compile(r"7656119\d{10}")


def _tail(path, limit=TAIL):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - limit))
        data = f.read()
    text = data.decode("utf-8", errors="replace")
    return ("[... earlier lines cut ...]\n" if size > limit else "") + text


def _names(root):
    """The account's own names, from the live save (what the game shows for you)."""
    out = set()
    try:
        with open(os.path.join(root, "backend", "state.json"), encoding="utf-8") as f:
            text = f.read()
        for key in ("display_name", "username"):
            for m in re.finditer(r'"%s"\s*:\s*"([^"\\]{3,})"' % key, text):
                out.add(m.group(1))
    except OSError:
        pass
    return {n for n in out if n.lower() not in ("marauder", "offline")}


def _scrub(text, names):
    home = os.path.expanduser("~")
    user = os.environ.get("USERNAME") or os.path.basename(home)
    for old, new in ((home, "%USERPROFILE%"), (home.replace("\\", "/"), "%USERPROFILE%")):
        text = re.sub(re.escape(old), new, text, flags=re.I)
    if user and len(user) >= 3:
        text = re.sub(r"(?<![A-Za-z0-9])" + re.escape(user) + r"(?![A-Za-z0-9])", "<user>", text, flags=re.I)
    text = STEAM_ID.sub("<steamid>", text)
    for n in names:
        text = text.replace(n, "<player>")
    return text


def _newest_crash():
    base = os.path.join(os.environ.get("LOCALAPPDATA", ""), "RaidGame", "Saved", "Crashes")
    try:
        dirs = [os.path.join(base, d) for d in os.listdir(base)]
    except OSError:
        return None
    dirs = [d for d in dirs if os.path.isdir(d) and time.time() - os.path.getmtime(d) < CRASH_DAYS * 86400]
    return max(dirs, key=os.path.getmtime) if dirs else None


def build(root, game_folder, save_dir=None, crash=True, out_dir=None):
    names = _names(root)
    stamp = datetime.now().strftime("%Y%m%d-%H%M")
    out_dir = out_dir or os.path.join(os.path.expanduser("~"), "Desktop")
    if not os.path.isdir(out_dir):
        out_dir = os.path.expanduser("~")
    path = os.path.join(out_dir, f"MaraudersOffline-report-{stamp}.zip")
    texts = {
        "last_game.log": os.path.join(root, "backend", "last_game.log"),
        "server.log": os.path.join(root, "backend", "server.log"),
        "standin_err.log": os.path.join(root, "backend", "standin_err.log"),
        "coverage.json": os.path.join(root, "backend", "coverage.json"),  # what the stand-in can't answer (#80)
        "launcher_errors.log": os.path.join(root, "backend", "launcher_errors.log"),  # #161
        "linux_launch.log": os.path.join(root, "backend", "linux_launch.log"),  # #161
        "UE4SS.log": os.path.join(game_folder, "RaidGame", "Binaries", "Win64", "UE4SS.log"),
        "version.txt": os.path.join(root, "version.txt"),
    }
    if save_dir:
        texts["save/state.json"] = os.path.join(save_dir, "state.json")
        texts["save/meta.json"] = os.path.join(save_dir, "meta.json")
    included = []
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, src in texts.items():
            if os.path.isfile(src):
                z.writestr(name, _scrub(_tail(src), names))
                included.append(name)
        cdir = _newest_crash()
        if cdir:
            ctx = os.path.join(cdir, "CrashContext.runtime-xml")
            if os.path.isfile(ctx):
                z.writestr("crash/CrashContext.runtime-xml", _scrub(_tail(ctx), names))
                included.append("crash report")
            dmp = os.path.join(cdir, "UE4Minidump.dmp")
            if crash and os.path.isfile(dmp):
                z.write(dmp, "crash/UE4Minidump.dmp")
                included.append("crash dump")
        info = {"made": stamp, "windows": platform.platform(), "python": sys.version.split()[0], "files": included}
        z.writestr("about.json", json.dumps(info, indent=1))
    return path, included
