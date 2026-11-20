"""Is there a newer public test build, and installing it in place. No Tk here, so it can be tested on its own:
    python launcher/update.py check              what the launcher would show
    python launcher/update.py install <zip> [sha256]   install a downloaded release zip over this folder

The installed build is in version.txt (written by tools/release/build_release.py, e.g. "public-test-20261116.4"). A dev
checkout has none, so it never checks. The request to GitHub carries nothing about the player: a fixed User-Agent and
no cookies or tokens.

The big dependencies (UE4SS.dll, the female outfit meshes) are separate MaraudersOffline-<build>-deps-<part>.zip assets.
The release zip's deps.json lists each part's files and their SHA-256, and a part is downloaded only when the files here
don't match it: when updating, and when an earlier update (by a launcher from before this) left them stale (repair).
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
TAG_URL = "https://api.github.com/repos/HaywireHayley/Marauders-PvE/releases/tags/"
RELEASES_PAGE = "https://github.com/HaywireHayley/Marauders-PvE/releases/latest"
ASSET = re.compile(r"^MaraudersOffline-[\w.]+\.zip$")
DEP_ASSET = re.compile(r"^MaraudersOffline-[\w.]+-deps-([\w-]+)\.zip$")
DEPS_FILE = "deps.json"
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


def _sha(asset):
    digest = asset.get("digest") or ""
    return digest[7:].lower() if digest.startswith("sha256:") else None


def latest(url=LATEST_URL, timeout=TIMEOUT):
    """The newest release as {tag, page, zip_url, size, sha256, deps}, or None for anything that goes wrong (offline,
    rate-limited, no zip on it). deps: part name ("female-2of6") -> {url, size, sha256}."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "MaraudersOffline-launcher",
                                                   "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            rel = json.load(r)
        asset = next(a for a in rel.get("assets", []) if ASSET.match(a.get("name", "")))
        deps = {m.group(1): {"url": a["browser_download_url"], "size": a.get("size") or 0, "sha256": _sha(a)}
                for a in rel.get("assets", []) for m in [DEP_ASSET.match(a.get("name", ""))] if m}
        return {"tag": rel["tag_name"], "page": rel.get("html_url") or RELEASES_PAGE,
                "zip_url": asset["browser_download_url"], "size": asset.get("size") or 0,
                "sha256": _sha(asset), "deps": deps}
    except Exception:
        return None


def release(tag, timeout=TIMEOUT):
    """The release with this tag (the installed build's own, for a repair), or None."""
    return latest(TAG_URL + tag.strip(), timeout) if build_key(tag) else None


def newer(release, current):
    """The release if it's a later build than the one installed, else None."""
    have, got = build_key(current), build_key(release and release["tag"])
    return release if have and got and got > have else None


class _Count:
    """Bytes downloaded across several assets, for one progress(done, total)."""
    def __init__(self, total, progress):
        self.done, self.total, self.progress = 0, total, progress

    def __call__(self, n):
        self.done += n
        if self.progress:
            self.progress(self.done, self.total)


def fetch(url, sha256, dest_dir, count=None):
    """One asset in dest_dir, checked against GitHub's SHA-256. Raises on any problem."""
    if not sha256:
        raise ValueError("GitHub gave no checksum for this download")
    path = os.path.join(dest_dir, os.path.basename(url))
    h = hashlib.sha256()
    req = urllib.request.Request(url, headers={"User-Agent": "MaraudersOffline-launcher"})
    with urllib.request.urlopen(req, timeout=30) as r, open(path, "wb") as f:
        while chunk := r.read(1 << 16):
            f.write(chunk)
            h.update(chunk)
            if count:
                count(len(chunk))
    if h.hexdigest() != sha256:
        raise ValueError("the download is damaged (checksum mismatch)")
    return path


def download(release, dest_dir, progress=None):
    """The release zip alone in dest_dir, checked against GitHub's SHA-256. Raises on any problem."""
    return fetch(release["zip_url"], release.get("sha256"), dest_dir, _Count(release.get("size") or 0, progress))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def zip_deps(zip_path):
    """The deps.json a release zip holds ({} for a release from before there was one)."""
    with zipfile.ZipFile(zip_path) as z:
        try:
            return json.loads(z.read(ZIP_TOP + DEPS_FILE).decode("utf-8"))
        except KeyError:
            return {}


def installed_deps(root=ROOT):
    try:
        with open(os.path.join(root, DEPS_FILE), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def stale_deps(manifest, root=ROOT):
    """The parts of a deps.json whose files at root are missing or different."""
    stale = []
    for part, files in sorted((manifest.get("parts") or {}).items()):
        for rel, want in files.items():
            path = os.path.join(root, *rel.split("/"))
            if not os.path.isfile(path) or sha256_file(path) != want:
                stale.append(part)
                break
    return stale


def deps_size(release, parts):
    return sum(((release.get("deps") or {}).get(p) or {}).get("size") or 0 for p in parts)


def _fetch_deps(release, parts, dest_dir, count):
    paths = []
    for part in parts:
        asset = (release.get("deps") or {}).get(part)
        if not asset:
            raise ValueError(f"{release['tag']} has no {part} download")
        paths.append(fetch(asset["url"], asset["sha256"], dest_dir, count))
    return paths


def download_update(release, dest_dir, progress=None, root=ROOT):
    """The release zip and each of its dependency parts that differs from what's at root, all checked: the zips for
    install(), release zip first. progress(done, total) counts them all (the total grows once the parts are known)."""
    count = _Count(release.get("size") or 0, progress)
    path = fetch(release["zip_url"], release.get("sha256"), dest_dir, count)
    parts = stale_deps(zip_deps(path), root)
    count.total += deps_size(release, parts)
    return [path] + _fetch_deps(release, parts, dest_dir, count)


def download_repair(release, parts, dest_dir, progress=None):
    """The installed build's stale dependency parts (stale_deps(installed_deps())) from its own release, checked."""
    return _fetch_deps(release, parts, dest_dir, _Count(deps_size(release, parts), progress))


def install(zip_paths, root=ROOT, release_zip=True):
    """Puts a release zip and its dependency zips (one path, or a list with the release zip first) over the install at
    root, keeping the player's data (KEEP). Every file they replace is backed up first and put back if anything fails,
    so a half-finished update can't be left behind. Returns the new build string, or None for dependency zips alone
    (release_zip=False: a repair)."""
    zip_paths = [zip_paths] if isinstance(zip_paths, str) else list(zip_paths)
    zips = []
    try:
        for p in zip_paths:
            zips.append(zipfile.ZipFile(p))
        return _install(zips, os.path.abspath(root), release_zip)
    finally:
        for z in zips:
            z.close()


def _install(zips, root_abs, release_zip):
    files = []  # (zip, name), in order: a later zip's copy of a file wins
    for i, z in enumerate(zips):
        names = [n for n in z.namelist() if not n.endswith("/")]
        if not names or any(not n.startswith(ZIP_TOP) for n in names) or (
                i == 0 and release_zip and ZIP_TOP + "version.txt" not in names):
            raise ValueError("not a Marauders Offline release zip")
        for n in names:
            rel = n[len(ZIP_TOP):]
            if rel.startswith("/") or ".." in rel.split("/") or ":" in rel:
                raise ValueError(f"unsafe path in zip: {n}")
            files.append((z, n))
    new_version = zips[0].read(ZIP_TOP + "version.txt").decode("utf-8").strip() if release_zip else None
    backup = tempfile.mkdtemp(prefix="pve-update-backup-")
    replaced, added = [], []
    try:
        for z, n in files:
            rel = n[len(ZIP_TOP):]
            target = os.path.join(root_abs, *rel.split("/"))
            exists = os.path.exists(target)
            if exists and KEEP.match(rel):
                continue
            if exists and rel not in replaced and rel not in added:
                keep = os.path.join(backup, *rel.split("/"))
                os.makedirs(os.path.dirname(keep), exist_ok=True)
                shutil.copy2(target, keep)
                replaced.append(rel)
            elif not exists:
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
        print("installed:", installed(), "| latest:", rel and rel["tag"], "| behind:", bool(newer(rel, installed())),
              "| stale dependencies:", stale_deps(installed_deps()) or "none")
    elif sys.argv[1:2] == ["install"]:
        if len(sys.argv) > 3 and sha256_file(sys.argv[2]) != sys.argv[3].lower():
            sys.exit("checksum mismatch")
        print("installed", install(sys.argv[2]))
    else:
        print(__doc__)
