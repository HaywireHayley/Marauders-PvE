"""Is there a newer public test build, and installing it in place. No Tk here, so it can be tested on its own:
    python launcher/update.py check              what the launcher would show
    python launcher/update.py install <zip> [sha256]   install a downloaded release zip over this folder

The installed build is in version.txt (written by tools/release/build_release.py, e.g. "public-test-20261116.4"). A dev
checkout has none, so it never checks. The request to GitHub carries nothing about the player: a fixed User-Agent and
no cookies or tokens.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_FILE = os.path.join(ROOT, "version.txt")
LATEST_URL = "https://api.github.com/repos/HaywireHayley/Marauders-PvE/releases/latest"
RELEASES_PAGE = "https://github.com/HaywireHayley/Marauders-PvE/releases/latest"
ASSET = re.compile(r"^MaraudersOffline-[\w.]+\.zip$")
ZIP_TOP = "MaraudersOffline/"
TIMEOUT = 6  # seconds: offline or slow just means no badge
# Player data that a release zip also ships a default for: kept as they are, only added if missing. Everything else
# the zip holds is replaced; files the zip doesn't hold (saves, logs, state) aren't touched at all.
KEEP = re.compile(r"^(config/(?!mods\.txt$|UE4SS-settings\.ini$)|bridge/|backend/saves/|backend/state[^/]*\.json$|cover/)")


def build_key(tag):
    """public-test-20261116.3 -> (20261116, 3); a build with no suffix is .1. None if it isn't one of ours."""
    m = re.fullmatch(r"(?:public-test-)?(\d{8})(?:\.(\d+))?", (tag or "").strip())
    return (int(m.group(1)), int(m.group(2) or 1)) if m else None


def installed():
    try:
        with open(VERSION_FILE, encoding="utf-8") as f:
            return f.readline().strip() or None
    except OSError:
        return None


def latest(url=LATEST_URL, timeout=TIMEOUT):
    """The newest release as {tag, page, zip_url, size, sha256}, or None for anything that goes wrong (offline,
    rate-limited, no zip on it)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "MaraudersOffline-launcher",
                                                   "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            rel = json.load(r)
        asset = next(a for a in rel.get("assets", []) if ASSET.match(a.get("name", "")))
        digest = asset.get("digest") or ""
        return {"tag": rel["tag_name"], "page": rel.get("html_url") or RELEASES_PAGE,
                "zip_url": asset["browser_download_url"], "size": asset.get("size") or 0,
                "sha256": digest[7:].lower() if digest.startswith("sha256:") else None}
    except Exception:
        return None


def newer(release, current):
    """The release if it's a later build than the one installed, else None."""
    have, got = build_key(current), build_key(release and release["tag"])
    return release if have and got and got > have else None


def download(release, dest_dir, progress=None):
    """The release zip in dest_dir, checked against GitHub's SHA-256. Raises on any problem."""
    if not release.get("sha256"):
        raise ValueError("GitHub gave no checksum for this download")
    path = os.path.join(dest_dir, os.path.basename(release["zip_url"]))
    h, done = hashlib.sha256(), 0
    req = urllib.request.Request(release["zip_url"], headers={"User-Agent": "MaraudersOffline-launcher"})
    with urllib.request.urlopen(req, timeout=30) as r, open(path, "wb") as f:
        while chunk := r.read(1 << 16):
            f.write(chunk)
            h.update(chunk)
            done += len(chunk)
            if progress:
                progress(done, release.get("size") or 0)
    if h.hexdigest() != release["sha256"]:
        raise ValueError("the download is damaged (checksum mismatch)")
    return path


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def install(zip_path, root=ROOT):
    """Puts a release zip over the install at root, keeping the player's data (KEEP). Every file it replaces is
    backed up first and put back if anything fails, so a half-finished update can't be left behind. Returns the new
    build string."""
    with zipfile.ZipFile(zip_path) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        if not names or any(not n.startswith(ZIP_TOP) for n in names) or ZIP_TOP + "version.txt" not in names:
            raise ValueError("not a Marauders Offline release zip")
        for n in names:
            rel = n[len(ZIP_TOP):]
            if rel.startswith("/") or ".." in rel.split("/") or ":" in rel:
                raise ValueError(f"unsafe path in zip: {n}")
        new_version = z.read(ZIP_TOP + "version.txt").decode("utf-8").strip()
        root_abs = os.path.abspath(root)
        backup = tempfile.mkdtemp(prefix="pve-update-backup-")
        replaced, added = [], []
        try:
            for n in names:
                rel = n[len(ZIP_TOP):]
                target = os.path.join(root_abs, *rel.split("/"))
                exists = os.path.exists(target)
                if exists and KEEP.match(rel):
                    continue
                if exists:
                    keep = os.path.join(backup, *rel.split("/"))
                    os.makedirs(os.path.dirname(keep), exist_ok=True)
                    shutil.copy2(target, keep)
                    replaced.append(rel)
                else:
                    added.append(rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with z.open(n) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
        except Exception:
            for rel in replaced:
                shutil.copy2(os.path.join(backup, *rel.split("/")), os.path.join(root_abs, *rel.split("/")))
            for rel in added:
                try:
                    os.remove(os.path.join(root_abs, *rel.split("/")))
                except OSError:
                    pass
            raise
        finally:
            shutil.rmtree(backup, ignore_errors=True)
    return new_version


if __name__ == "__main__":
    if sys.argv[1:2] == ["check"]:
        rel = latest()
        print("installed:", installed(), "| latest:", rel and rel["tag"], "| behind:", bool(newer(rel, installed())))
    elif sys.argv[1:2] == ["install"]:
        if len(sys.argv) > 3 and sha256_file(sys.argv[2]) != sys.argv[3].lower():
            sys.exit("checksum mismatch")
        print("installed", install(sys.argv[2]))
    else:
        print(__doc__)
