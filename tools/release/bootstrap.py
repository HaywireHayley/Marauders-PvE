"""The slim installer's first step: downloads the latest public test build and every dependency part it needs from
GitHub (each checked against GitHub's SHA-256), and installs them into this folder. Run by scripts/install.ps1 when the
folder has no version.txt yet (the installer zip, MaraudersOffline-<build>-installer.zip, holds only the launcher's
update.py, this file and the installer), so a new player downloads one small zip instead of eight.

    python scripts/bootstrap.py          install the latest build here
    python scripts/bootstrap.py check    what it would download

It uses launcher/update.py's own download and install, the ones the launcher's UPDATE button uses: nothing about the
player is sent (a fixed User-Agent, no cookies or tokens), a damaged download stops it, and a failed install is rolled
back. Exit code 0 when installed, 1 when anything went wrong.
"""
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "launcher"))
import update  # noqa: E402  (launcher/update.py)


def main():
    rel = update.latest(timeout=20)
    if not rel:
        print("Couldn't reach GitHub for the latest build (offline, or GitHub is rate-limiting this address).")
        print("Try again in a few minutes, or download the zips by hand from " + update.RELEASES_PAGE)
        return 1
    parts = sorted((rel.get("deps") or {}).keys())
    total = (rel.get("size") or 0) + update.deps_size(rel, parts)
    print(f"Latest build: {rel['tag']} ({total / 1e6:.0f} MB in {1 + len(parts)} downloads)")
    if sys.argv[1:2] == ["check"]:
        return 0
    shown = [-1]

    def progress(done, total):
        step = int(done / 5e6)  # a line every 5 MB, and at the end
        if step != shown[0] or done == total:
            shown[0] = step
            print(f"  downloading... {done / 1e6:.0f} of {max(total, done) / 1e6:.0f} MB", flush=True)

    tmp = tempfile.mkdtemp(prefix="pve-install-")
    try:
        paths = update.download_update(rel, tmp, progress, root=ROOT)
        print("Installing...", flush=True)
        version = update.install(paths, root=ROOT)
    except Exception as e:
        print(f"Install failed, nothing was changed: {str(e) or type(e).__name__}")
        print("You can download the zips by hand from " + rel["page"])
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    missing = update.stale_deps(update.installed_deps(ROOT), ROOT)
    if missing:
        print("Installed, but these parts didn't arrive: " + ", ".join(missing))
        return 1
    print(f"Installed {version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
