"""Marauders Offline without PowerShell: the mode switch, saves and the Steam launch wrapper (Linux / Steam Deck, issue #127).

    python3 scripts/pvemode.py status | offline | online       the same switch as scripts/mode.ps1
    python3 scripts/pvemode.py install                          find the game, write config/game_path.txt, print setup
    python3 scripts/pvemode.py saves                            list saves (* = the one PLAY uses)
    python3 scripts/pvemode.py use <save id>                    pick the save the next game uses
    python3 scripts/pvemode.py new <name> [--cheat] [--rows N]  make a save
    python3 scripts/pvemode.py steam on | off                   whether the Steam launch option starts the mod
    python3 scripts/pvemode.py steam-run -- <Steam's %command%> what linux/marauders-offline.sh runs

On Linux the game runs under Proton, started by Steam. Marauders' launch option is set to
    "<this folder>/linux/marauders-offline.sh" %command%
and steam-run then does what the Windows launcher's PLAY does: activate the save, start the stand-in backend, switch the
game folder to offline, run the game (RaidGame-Win64-Shipping.exe instead of the EAC bootstrapper, as on Windows, with
UE4SS's dwmapi.dll proxy loaded native), and when it closes put the save back and the game folder back to stock.

Stdlib only, Python 3.9+ (SteamOS has Python but not Tk or Pillow). Windows keeps using mode.ps1 and the launcher; this
module works there too, but nothing on Windows calls it yet.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "launcher"))
import saves  # noqa: E402  (stdlib only: launcher/saves.py)

LINUX = sys.platform.startswith("linux")
EXE_REL = os.path.join("RaidGame", "Binaries", "Win64", "RaidGame-Win64-Shipping.exe")
GAME_EXE = "RaidGame-Win64-Shipping.exe"
BOOTSTRAP = "raidgame.exe"  # what Steam starts: the EAC bootstrapper
GAME_PATH = os.path.join(ROOT, "config", "game_path.txt")
BACKUP = os.path.join(ROOT, "backup")
DIRTY = os.path.join(BACKUP, "offline_applied")  # written once the folder is offline, removed once it's stock again
STEAM_SETTING = os.path.join(ROOT, "config", "linux_offline.txt")  # "off": the launch option starts the stock game
SAVE_SETTING = os.path.join(ROOT, "config", "linux_save.txt")  # the save steam-run plays (else the last played)
STANDIN_PORT = 7350
# What offline adds to Binaries/Win64 (and UE4SS's own output); online removes exactly these. Same list as mode.ps1.
ADDED = ["dwmapi.dll", "UE4SS.dll", "UE4SS-settings.ini", "Mods", "UE4SS.log", "UE4SS_ObjectDump.txt", "CXXHeaderDump",
         "Mappings.usmap", "../../Content/Paks/LogicMods",
         "../../Content/Characters/MainPlayer/Meshes/BodieF", "../../Content/Characters/MainPlayer/Meshes/HeadF",
         "../../Content/Characters/MainPlayer/Meshes/AccessorieF", "../../Content/Characters/MainPlayer/MesheF"]
MOD_DIRS_WITH_ROOT = ("PvEDirector", "PvEBridge")


def say(text):
    print(text, flush=True)


# Paths ----------------------------------------------------------------------------------------------------------------
def wine_path(path):
    """A Linux path as Windows programs under Wine/Proton see it: drive Z: is the Linux root. The Lua mods run inside
    the game, so the project root they read (pveproject.lua) has to be in this form."""
    path = path if path.startswith("/") else os.path.abspath(path)
    return "Z:" + path.replace("\\", "/")


def project_root_for_mods():
    root = wine_path(ROOT) if LINUX else os.path.abspath(ROOT).replace("\\", "/")
    return root.rstrip("/") + "/"


def path_problem(path):
    """Why the mods can't use a folder, or None. They open files by this path, and non-ASCII letters don't survive."""
    if any(ord(c) > 126 or ord(c) < 32 for c in path):
        return f"the path has letters the mods can't open: {path}"
    return None


def read_game():
    try:
        with open(GAME_PATH, encoding="utf-8") as f:
            return f.readline().strip() or None
    except OSError:
        return None


def is_game(folder):
    return bool(folder) and os.path.isfile(os.path.join(folder, EXE_REL))


# Finding the game ----------------------------------------------------------------------------------------------------
def steam_roots():
    """Steam's own folders: the native install, the old ~/.steam link, Flatpak; or the registry's on Windows."""
    if os.name == "nt":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
                return [winreg.QueryValueEx(k, "SteamPath")[0]]
        except OSError:
            return []
    home = os.path.expanduser("~")
    return [os.path.join(home, p) for p in (".local/share/Steam", ".steam/steam", ".steam/root",
                                            ".var/app/com.valvesoftware.Steam/.local/share/Steam")]


def library_folders(vdf_text):
    """The "path" entries of a libraryfolders.vdf (every Steam library, SD cards included)."""
    import re
    return [m.replace("\\\\", "\\") for m in re.findall(r'"path"\s+"([^"]+)"', vdf_text)]


def find_game(roots=None):
    libs = []
    for root in roots if roots is not None else steam_roots():
        if not os.path.isdir(root):
            continue
        libs.append(root)
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        try:
            with open(vdf, encoding="utf-8", errors="replace") as f:
                libs += library_folders(f.read())
        except OSError:
            pass
    seen = set()
    for lib in libs:
        real = os.path.realpath(lib)
        if real in seen:
            continue
        seen.add(real)
        common = os.path.join(lib, "steamapps", "common")
        try:
            names = sorted(os.listdir(common))
        except OSError:
            continue
        for name in names:
            if is_game(os.path.join(common, name)):
                return os.path.join(common, name)
    return None


# Is the game running? --------------------------------------------------------------------------------------------------
def game_running():
    if LINUX:
        # Wine processes keep the Windows exe's path in their command line.
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    cmd = f.read().replace(b"\0", b" ").lower()
            except OSError:
                continue
            if GAME_EXE.lower().encode() in cmd and b"pvemode" not in cmd:
                return True
        return False
    if os.name == "nt":
        import ctypes
        enc = f"cp{ctypes.windll.kernel32.GetOEMCP()}"
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {GAME_EXE}", "/NH"], capture_output=True, text=True,
                             encoding=enc, errors="replace", creationflags=0x08000000).stdout or ""
        return GAME_EXE[:20].lower() in out.lower()
    return False


# The switch (scripts/mode.ps1) -----------------------------------------------------------------------------------------
class Folder:
    def __init__(self, game):
        self.game = game
        self.bin = os.path.join(game, "RaidGame", "Binaries", "Win64")
        self.ini = os.path.join(game, "RaidGame", "Binaries", "pgos_res", "pgos_config.ini")
        self.intro = os.path.join(game, "RaidGame", "Content", "Movies", "LoadingScreen.mp4")
        self.ini_backup = os.path.join(BACKUP, "pgos_config.ini.original")
        self.intro_backup = os.path.join(BACKUP, "LoadingScreen.mp4.original")

    def mode(self):
        return "offline" if os.path.exists(os.path.join(self.bin, "dwmapi.dll")) else "online"

    def backups(self):
        os.makedirs(BACKUP, exist_ok=True)
        if not os.path.exists(self.ini_backup):
            shutil.copy2(self.ini, self.ini_backup)
        if not os.path.exists(self.intro_backup) and os.path.exists(self.intro):
            shutil.copy2(self.intro, self.intro_backup)

    def offline(self):
        self.backups()
        ue4ss = os.path.join(ROOT, "tools", "ue4ss")
        for name in ("dwmapi.dll", "UE4SS.dll"):
            shutil.copy2(os.path.join(ue4ss, name), self.bin)
        shutil.copy2(os.path.join(ROOT, "config", "UE4SS-settings.ini"), self.bin)
        mods = os.path.join(self.bin, "Mods")
        if os.path.exists(mods):
            shutil.rmtree(mods)
        shutil.copytree(os.path.join(ue4ss, "Mods"), mods)
        ours = os.path.join(ROOT, "mods")
        for name in sorted(os.listdir(ours)):
            if os.path.isdir(os.path.join(ours, name)):
                shutil.copytree(os.path.join(ours, name), os.path.join(mods, name), dirs_exist_ok=True)
        shutil.copy2(os.path.join(ROOT, "config", "mods.txt"), mods)
        # The mods find the project's files (saves, art, native/*.dll) through require("pveproject").
        root = project_root_for_mods()
        for m in MOD_DIRS_WITH_ROOT:
            scripts = os.path.join(mods, m, "Scripts")
            if os.path.isdir(scripts):
                with open(os.path.join(scripts, "pveproject.lua"), "w", encoding="utf-8", newline="\n") as f:
                    f.write(f'return "{root}"\n')
        ours_intro = os.path.join(ROOT, "assets", "intro", "LoadingScreen.mp4")
        skip = os.path.join(ROOT, "assets", "loading", "skip_intro.mp4")
        if setting(os.path.join(ROOT, "config", "skip_intro.txt")) == "on" and os.path.exists(skip):
            ours_intro = skip
        if os.path.exists(ours_intro) and os.path.exists(self.intro):
            shutil.copy2(ours_intro, self.intro)
        female = os.path.join(ROOT, "assets", "female", "pak", "RaidGame", "Content")
        if os.path.isdir(female):
            shutil.copytree(female, os.path.join(self.game, "RaidGame", "Content"), dirs_exist_ok=True)
        # Backend -> localhost port 1: every PGOS request fails locally instead of reaching the live service.
        with open(self.ini_backup, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        out = []
        for line in lines:
            key = line.split("=", 1)[0].strip()
            if key == "socket_base_url":
                line = "socket_base_url = wss://127.0.0.1:1"
            elif key == "http_base_url":
                line = "http_base_url = https://127.0.0.1:1"
            out.append(line)
        with open(self.ini, "w", encoding="ascii", errors="replace", newline="\r\n") as f:
            f.write("\n".join(out) + "\n")
        with open(DIRTY, "w", encoding="utf-8") as f:
            f.write(self.game + "\n")

    def online(self):
        for rel in ADDED:
            p = os.path.normpath(os.path.join(self.bin, rel))
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            elif os.path.lexists(p):
                os.remove(p)
        if os.path.exists(self.ini_backup):
            shutil.copy2(self.ini_backup, self.ini)
        if os.path.exists(self.intro_backup):
            shutil.copy2(self.intro_backup, self.intro)
        if os.path.exists(DIRTY):
            os.remove(DIRTY)


def setting(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.readline().strip().lower() or default
    except OSError:
        return default


def recover():
    """Puts the folder back to stock if the last offline game never got to (killed, suspended, power lost). Every
    command runs this first. Returns whether it had to."""
    if not os.path.exists(DIRTY) or game_running():
        return False
    try:
        with open(DIRTY, encoding="utf-8") as f:
            game = f.readline().strip()
    except OSError:
        game = ""
    game = game if is_game(game) else read_game()
    if not is_game(game):
        say("The game folder was left offline, but it can't be found to put back: run 'pvemode.py online' once it can.")
        return False
    Folder(game).online()
    saves.settle()
    say("The last offline game didn't close cleanly: the game folder is back to stock and the save is put back.")
    return True


# The stand-in backend --------------------------------------------------------------------------------------------------
def port_open(port):
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) == 0


def start_standin(port=STANDIN_PORT, timeout=15):
    """Starts backend/nakama_standin.py and waits until it answers. Returns (process or None, problem or None)."""
    if port_open(port):
        return None, None
    backend = os.path.join(ROOT, "backend")
    err = os.path.join(backend, "standin_err.log")
    proc = subprocess.Popen([sys.executable, "-I", os.path.join(backend, "nakama_standin.py"), "--port", str(port)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=LINUX)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if port_open(port):
            return proc, None
        if proc.poll() is not None:
            break
        time.sleep(0.25)
    why = ""
    try:
        with open(err, encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip()]
            why = lines[-1] if lines else ""
    except OSError:
        pass
    if proc.poll() is None:
        proc.kill()
    return None, (f"the offline backend stopped: {why} (backend/standin_err.log)" if why else
                  f"the offline backend didn't answer on port {port} within {timeout} s (backend/server.log)")


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()


# Steam's %command% ----------------------------------------------------------------------------------------------------
def game_command(argv, game=None):
    """Steam's command line with the EAC bootstrapper (RaidGame.exe) swapped for the game itself, as the Windows
    launcher starts it. Returns (argv, game folder) or (None, None) when there's no RaidGame.exe in it."""
    for i, arg in enumerate(argv):
        if os.path.basename(arg.replace("\\", "/")).lower() == BOOTSTRAP:
            folder = os.path.dirname(arg)
            if not is_game(folder) and is_game(game):
                folder = game
            return argv[:i] + [os.path.join(folder, EXE_REL)] + argv[i + 1:] + ["-nosplash"], folder
        if os.path.basename(arg.replace("\\", "/")).lower() == GAME_EXE.lower():
            folder = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(arg))))
            return argv + ["-nosplash"], folder
    return None, None


def dll_overrides(current):
    """WINEDLLOVERRIDES with UE4SS's proxy loaded native: Wine uses its own dwmapi.dll otherwise."""
    parts = [p for p in (current or "").split(";") if p and not p.lower().startswith("dwmapi=")]
    return ";".join(parts + ["dwmapi=n,b"])


def chosen_save():
    sid = setting(SAVE_SETTING)
    ids = [s["id"] for s in saves.listing() if not s.get("damaged")]
    if sid in ids:
        return sid
    return ids[0] if ids else None  # listing() is newest-played first


class Stop(Exception):
    pass


def steam_run(argv):
    """The Steam launch option: plays the chosen save offline, or runs Steam's command untouched when switched off."""
    if not argv:
        sys.exit("steam-run: nothing to run (the launch option needs %command% after the script)")
    recover()
    if setting(STEAM_SETTING, "on") == "off":
        say("Marauders Offline is switched off ('pvemode.py steam on' switches it back on): starting the stock game.")
        os.execvp(argv[0], argv)
    cmd, game = game_command(argv, read_game())
    if not cmd:
        say("steam-run: no RaidGame.exe in Steam's command, so it runs unchanged: " + " ".join(argv))
        os.execvp(argv[0], argv)
    for problem in (path_problem(ROOT), None if is_game(game) else f"no {EXE_REL} under {game}"):
        if problem:
            sys.exit("Marauders Offline can't start: " + problem)
    if read_game() != game:
        with open(GAME_PATH, "w", encoding="utf-8") as f:
            f.write(game + "\n")
    sid = chosen_save()
    if not sid:
        sid = saves.create("Save 1", False)
        say("No saves yet: made 'Save 1'.")
    folder, standin, proc = Folder(game), None, None

    def interrupted(signum, _frame):
        raise Stop(signum)

    for sig in (signal.SIGTERM, signal.SIGINT, getattr(signal, "SIGHUP", None)):
        if sig is not None:
            signal.signal(sig, interrupted)
    try:
        saves.activate(sid)
        if os.path.exists(os.path.join(ROOT, "bridge", "offline_backend")):
            standin, problem = start_standin()
            if problem:
                sys.exit("Marauders Offline can't start: " + problem)
        folder.offline()
        say(f"Marauders Offline: playing save '{sid}'. The game folder goes back to stock when the game closes.")
        env = dict(os.environ, WINEDLLOVERRIDES=dll_overrides(os.environ.get("WINEDLLOVERRIDES")))
        proc = subprocess.Popen(cmd, env=env)
        proc.wait()
    except Stop:
        say("Marauders Offline: stopped; tidying up.")
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
    finally:
        # The bootstrapper's child can outlive Proton's process for a moment: wait for the game itself to go.
        deadline = time.time() + 20
        while game_running() and time.time() < deadline:
            time.sleep(0.5)
        stop(standin)
        if not game_running():
            folder.online()
            saves.settle()
        else:
            say("The game is still running: the next start puts the game folder back.")
    return proc.returncode if proc else 1


# Commands ------------------------------------------------------------------------------------------------------------
def desktop_entry(apps=None):
    """Adds "Marauders Offline" to the desktop's app menu (Desktop Mode on a Deck): the launcher window, for saves and
    settings. Only when Tk and Pillow are there (SteamOS ships neither); PLAY in Steam works without it. Returns what to
    tell the player."""
    missing = []
    for module in ("tkinter", "PIL.ImageTk"):
        try:
            __import__(module)
        except ImportError:
            missing.append({"tkinter": "Tk (python3-tk)", "PIL.ImageTk": "Pillow (python3-pil, python3-pil.imagetk)"}[module])
    if missing:
        return ("\nThe launcher window (saves and settings, Desktop Mode) needs " + " and ".join(missing) + ", which this "
                "Python doesn't have. Not needed to play: use the commands below for saves.")
    apps = apps or os.path.join(os.path.expanduser("~"), ".local", "share", "applications")
    os.makedirs(apps, exist_ok=True)
    path = os.path.join(apps, "marauders-offline.desktop")
    icon = os.path.join(ROOT, "assets", "launcher", "icon.ico")
    with open(path, "w", encoding="utf-8") as f:
        f.write("[Desktop Entry]\nType=Application\nName=Marauders Offline\n"
                "Comment=Saves and settings for the Marauders offline mod\n"
                f'Exec="{sys.executable}" "{os.path.join(ROOT, "launcher", "launcher.pyw")}"\n'
                f'Path={ROOT}\n' + (f"Icon={icon}\n" if os.path.exists(icon) else "") +
                "Terminal=false\nCategories=Game;\n")
    os.chmod(path, 0o755)
    return f"\nAdded 'Marauders Offline' to your app menu ({path}): the launcher window for saves and settings."


def cmd_install():
    problem = path_problem(ROOT)
    if problem:
        sys.exit("Move this folder: " + problem)
    if sys.version_info < (3, 9):
        sys.exit("Python 3.9 or newer is needed (this is %d.%d)." % sys.version_info[:2])
    game = read_game() if is_game(read_game()) else find_game()
    if not game:
        sys.exit("Couldn't find Marauders in your Steam libraries. Write the game's folder (the one holding RaidGame) "
                 "into config/game_path.txt and run this again.")
    with open(GAME_PATH, "w", encoding="utf-8") as f:
        f.write(game + "\n")
    os.makedirs(os.path.join(ROOT, "backend", "saves"), exist_ok=True)
    saves.adopt_existing()
    wrapper = os.path.join(ROOT, "linux", "marauders-offline.sh")
    if os.path.exists(wrapper):
        os.chmod(wrapper, 0o755)
    say(f"Folder:  {ROOT}\nGame:    {game}\nPython:  {sys.executable} ({sys.version.split()[0]})")
    if not LINUX:
        say("\nOn Windows, use Install.bat and the launcher instead.")
        return
    say(desktop_entry())
    say("\nLast step, in Steam: Marauders > Properties > General > Launch options, paste this line:\n\n"
        f'    "{wrapper}" %command%\n\n'
        "Then PLAY in Steam starts the offline mod (from Game Mode too), and the game folder goes back to stock when\n"
        "the game closes. To play the normal online game again, clear the launch option, or run\n"
        f'    python3 "{os.path.join(ROOT, "scripts", "pvemode.py")}" steam off')


def cmd_saves():
    current = chosen_save()
    rows = saves.listing()
    if not rows:
        say("No saves yet. PLAY makes one, or: pvemode.py new <name>")
    for s in rows:
        mark = "*" if s["id"] == current else " "
        if s.get("damaged"):
            say(f"{mark} {s['id']:<24} (can't read this save)")
        else:
            say(f"{mark} {s['id']:<24} {s['name']}  ·  {s['cash']:,} cash  ·  {s['items']} items")


def main(args):
    if not args:
        args = ["status"]
    cmd, rest = args[0], args[1:]
    if cmd == "steam-run":
        if rest[:1] == ["--"]:
            rest = rest[1:]
        return steam_run(rest)
    recover()
    if cmd == "install":
        return cmd_install()
    if cmd == "saves":
        return cmd_saves()
    if cmd == "use":
        ids = [s["id"] for s in saves.listing()]
        if not rest or rest[0] not in ids:
            sys.exit("use <save id>, one of: " + ", ".join(ids))
        with open(SAVE_SETTING, "w", encoding="utf-8") as f:
            f.write(rest[0] + "\n")
        return say(f"The next game plays '{rest[0]}'.")
    if cmd == "new":
        if not rest:
            sys.exit("new <name> [--cheat] [--rows N]")
        rows = saves.STASH_H
        if "--rows" in rest:
            rows = int(rest[rest.index("--rows") + 1])
        sid = saves.create(rest[0], "--cheat" in rest, rows)
        with open(SAVE_SETTING, "w", encoding="utf-8") as f:
            f.write(sid + "\n")
        return say(f"Made '{sid}'; the next game plays it.")
    if cmd == "steam":
        if rest[:1] not in (["on"], ["off"]):
            return say("Steam launch option: " + setting(STEAM_SETTING, "on"))
        with open(STEAM_SETTING, "w", encoding="utf-8") as f:
            f.write(rest[0] + "\n")
        return say("PLAY in Steam now starts " + ("the offline mod." if rest[0] == "on" else "the stock online game."))
    game = read_game()
    if not is_game(game):
        sys.exit("No game folder set: run 'pvemode.py install' first.")
    folder = Folder(game)
    if cmd == "status":
        return say(f"Mode: {folder.mode()}")
    if cmd in ("offline", "online"):
        if game_running():
            sys.exit("Close the game first.")
        folder.offline() if cmd == "offline" else folder.online()
        return say(f"Mode: {cmd}")
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
