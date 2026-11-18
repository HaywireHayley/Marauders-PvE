"""Puts the space test tools into a TEST install (or takes them out again):

    python tools/space_test/install.py <Scripts folder of a test install>
    python tools/space_test/install.py <Scripts folder> --remove

It copies testtools.lua, explowatch.lua, salvagewatch.lua and spacetest_hook.lua into the folder, and adds three small hooks to
files the folder already has, each marked "SPACE TEST" so --remove finds them again:

  debugactions.lua  one line after Debug.addActions(Give.actions()): the tools' F9 buttons, from the start (also in the lobby)
  botdamage.lua     one line before its final "return B": the tools' tick, every frame (spacetest_hook.lua)
  launch.lua        a block before its final "return M": M.testSearch, the "Start a space raid" button's way into the same offline
                    search and launch the lobby's START RAID uses

Nothing else is touched. Line endings of each file are kept. Refuses a folder inside a git working tree, so the shipped mod can never
pick the tools up by accident: run it on a copy of the install. Close the game first.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["testtools.lua", "explowatch.lua", "salvagewatch.lua", "spacetest_hook.lua"]
MARK = "-- SPACE TEST HOOK (tools/space_test)"
BEGIN = "-- SPACE TEST BEGIN (tools/space_test)"
END = "-- SPACE TEST END"

DEBUGACTIONS_LINE = ('pcall(function() local m = require("testtools") if m.actions then Debug.addActions(m.actions()) end end) '
                     + MARK)
BOTDAMAGE_LINE = 'pcall(function() require("spacetest_hook")(B) end) ' + MARK
LAUNCH_BLOCK = [
    BEGIN,
    "-- The F9 \"Start a space raid\" button: the lobby's START RAID without the lobby, through the same offline search and launch",
    "-- (stash loadout, ship, wages, loading screen). The map is the one picked in the lobby, bridge/map_pin, or random.",
    "function M.testSearch()",
    "    if not offlineBackend() then return \"Needs the offline backend\" end",
    "    if mm or launching then return \"A raid is already loading\" end",
    "    onStartMatchmaking(\"crew captain\")()",
    "    return mm and (\"Loading \" .. mm.map) or \"Not started\"",
    "end",
    END,
]
OLD_WRAPPERS = re.compile(r"TEST LOGGING|valuedump|testtools|TEST \(install only\)")


def read(path):
    text = open(path, "rb").read().decode("utf-8")
    nl = "\r\n" if "\r\n" in text else "\n"
    return text.split(nl), nl


def write(path, lines, nl):
    open(path, "wb").write(nl.join(lines).encode("utf-8"))


def strip_marked(lines):
    """Our lines and block removed (what --remove does, and the first step of an install, so running it twice is safe)."""
    out, skipping, blank_after = [], False, False
    for ln in lines:
        if ln.strip() == BEGIN:
            skipping = True
            continue
        if skipping:
            if ln.strip() == END:
                skipping, blank_after = False, True  # (the one blank line the block was followed by goes too)
            continue
        if blank_after:
            blank_after = False
            if not ln.strip():
                continue
        if MARK in ln:
            continue
        out.append(ln)
    return out


def insert_before_last(lines, pattern, new, what):
    for i in range(len(lines) - 1, -1, -1):
        if re.match(pattern, lines[i]):
            return lines[:i] + new + lines[i:]
    sys.exit(f"{what}: no line matching {pattern!r}; this install's file is not the repo's. Start from the repo copy.")


def insert_after_first(lines, needle, new, what):
    for i, ln in enumerate(lines):
        if needle in ln:
            indent = re.match(r"\s*", ln).group(0)
            return lines[:i + 1] + [indent + new] + lines[i + 1:]
    sys.exit(f"{what}: no line containing {needle!r}; this install's file is not the repo's. Start from the repo copy.")


def in_git_tree(path):
    d = path
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up


def game_running():
    if os.name != "nt":
        return False
    try:
        out = subprocess.run(["tasklist"], capture_output=True, text=True, timeout=20).stdout.lower()
    except Exception:
        return False
    return "raidgame-win64-shipping" in out or "raidgame.exe" in out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scripts", help="the Scripts folder of a test install (the one holding botdamage.lua)")
    ap.add_argument("--remove", action="store_true", help="take the tools and the hooks out again")
    args = ap.parse_args()

    scripts = os.path.abspath(args.scripts)
    targets = {name: os.path.join(scripts, name) for name in ("botdamage.lua", "debugactions.lua", "launch.lua")}
    for name, p in targets.items():
        if not os.path.exists(p):
            sys.exit(f"No {name} in {scripts}. Point this at the Scripts folder of a test install.")
    tree = in_git_tree(scripts)
    if tree:
        sys.exit(f"{scripts} is inside a git working tree ({tree}). Install the tools into a test install, not the repo.")
    if game_running():
        sys.exit("Close the game first.")

    texts = {name: read(p) for name, p in targets.items()}
    for name, (lines, nl) in texts.items():
        stripped = strip_marked(lines)
        if not args.remove:
            for ln in stripped:
                if OLD_WRAPPERS.search(ln):
                    sys.exit(f"{name} already carries an older test wrapper ({ln.strip()[:60]}...). Start from the repo copy.")
        texts[name] = (stripped, nl)

    if args.remove:
        for name, (lines, nl) in texts.items():
            write(targets[name], lines, nl)
        for f in FILES:
            try:
                os.remove(os.path.join(scripts, f))
            except FileNotFoundError:
                pass
        print(f"Space test tools removed from {scripts}")
        return

    lines, nl = texts["botdamage.lua"]
    texts["botdamage.lua"] = (insert_before_last(lines, r"^return B\s*$", [BOTDAMAGE_LINE], "botdamage.lua"), nl)
    lines, nl = texts["debugactions.lua"]
    texts["debugactions.lua"] = (insert_after_first(lines, "Debug.addActions(Give.actions())", DEBUGACTIONS_LINE, "debugactions.lua"), nl)
    lines, nl = texts["launch.lua"]
    texts["launch.lua"] = (insert_before_last(lines, r"^return M\s*$", LAUNCH_BLOCK + [""], "launch.lua"), nl)

    for name, (lines, nl) in texts.items():
        write(targets[name], lines, nl)
    for f in FILES:
        src = open(os.path.join(HERE, f), "rb").read().decode("utf-8")
        # the install's own files use CRLF on Windows; keep the copies consistent with the folder they go into
        _, nl = texts["botdamage.lua"]
        open(os.path.join(scripts, f), "wb").write(src.replace("\r\n", "\n").replace("\n", nl).encode("utf-8"))
    print(f"Space test tools installed in {scripts}. Start the game, press F9: the space tools are at the end of the menu.")
    print("Logs go to bridge/ in the install folder (see tools/space_test/README.md).")


if __name__ == "__main__":
    main()
