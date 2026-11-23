"""Tests for scripts/pvemode.py (Linux / Steam Deck support, issue #127). Needs no game: a fake game folder and a fake
"Proton" stand in. Never touches the real backend/state.json, saves or game folder.

    python3 scripts/test_pvemode.py            (the end-to-end steam-run tests need Linux: WSL works)
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pvemode  # noqa: E402

HAVE_UE4SS = os.path.exists(os.path.join(pvemode.ROOT, "tools", "ue4ss", "dwmapi.dll"))


def fake_game(base, name="Marauders Game"):
    """A game folder with the files the switch touches, each holding its own name as stock content."""
    game = os.path.join(base, "steamapps", "common", name)
    files = {
        pvemode.EXE_REL: "shipping exe",
        "RaidGame.exe": "eac bootstrapper",
        os.path.join("RaidGame", "Binaries", "pgos_res", "pgos_config.ini"):
            "[pgos]\r\nsocket_base_url = wss://live.example\r\nhttp_base_url = https://live.example\r\nother = 1\r\n",
        os.path.join("RaidGame", "Content", "Movies", "LoadingScreen.mp4"): "stock intro",
        os.path.join("RaidGame", "Content", "Paks", "RaidGame-WindowsNoEditor.pak"): "stock pak",
    }
    for rel, text in files.items():
        path = os.path.join(game, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
    return game


def sandbox(tmp):
    """Points pvemode and saves at a temporary project state (backup, config, saves), keeping the real sources."""
    cfg = os.path.join(tmp, "config")
    os.makedirs(cfg, exist_ok=True)
    pvemode.BACKUP = os.path.join(tmp, "backup")
    pvemode.DIRTY = os.path.join(pvemode.BACKUP, "offline_applied")
    pvemode.GAME_PATH = os.path.join(cfg, "game_path.txt")
    pvemode.STEAM_SETTING = os.path.join(cfg, "linux_offline.txt")
    pvemode.SAVE_SETTING = os.path.join(cfg, "linux_save.txt")
    pvemode.LAUNCH_LOG = os.path.join(tmp, "linux_launch.log")
    s = pvemode.saves
    s.SAVES = os.path.join(tmp, "saves")
    s.LIVE = os.path.join(tmp, "state.json")
    s.RAID_COPY = os.path.join(tmp, "state.before-last-raid.json")
    s.CREW = os.path.join(tmp, "crew.lua")
    s.CREW_RAID_COPY = os.path.join(tmp, "crew.before-last-raid.lua")
    s.ACTIVE = os.path.join(tmp, "active_save.txt")
    s.STASH_ROWS = os.path.join(cfg, "stash_rows.txt")
    os.makedirs(s.SAVES, exist_ok=True)


def snapshot(game):
    out = {}
    for dirpath, _, files in os.walk(game):
        for name in files:
            path = os.path.join(dirpath, name)
            with open(path, "rb") as f:
                out[os.path.relpath(path, game)] = f.read()
    return out


class Paths(unittest.TestCase):
    def test_wine_path(self):
        self.assertEqual(pvemode.wine_path("/home/deck/Marauders Offline"), "Z:/home/deck/Marauders Offline")

    def test_path_problem(self):
        self.assertIsNone(pvemode.path_problem("/run/media/mmcblk0p1/Games/Marauders Offline"))
        self.assertIsNotNone(pvemode.path_problem("/home/deck/Jogos/Marauders Ofensiva Café"))

    def test_library_folders(self):
        vdf = '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"/home/deck/.local/share/Steam"\n\t}\n' \
              '\t"1"\n\t{\n\t\t"path"\t\t"/run/media/mmcblk0p1"\n\t}\n}\n'
        self.assertEqual(pvemode.library_folders(vdf), ["/home/deck/.local/share/Steam", "/run/media/mmcblk0p1"])

    def test_find_game_in_second_library_with_space(self):
        with tempfile.TemporaryDirectory() as tmp:
            steam = os.path.join(tmp, "Steam")
            card = os.path.join(tmp, "SD Card")
            os.makedirs(os.path.join(steam, "steamapps", "common", "Other Game"))
            game = fake_game(card, "PHtest")
            with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), "w") as f:
                f.write(f'"libraryfolders"\n{{\n"0" {{ "path" "{steam}" }}\n"1" {{ "path" "{card}" }}\n}}\n')
            self.assertEqual(pvemode.find_game([steam, os.path.join(tmp, "missing")]), game)


class Command(unittest.TestCase):
    def test_bootstrapper_swapped_for_the_game(self):
        game = "/home/deck/.local/share/Steam/steamapps/common/PHtest"
        argv = ["/steam/proton", "waitforexitandrun", game + "/RaidGame.exe", "-someflag"]
        cmd, folder = pvemode.game_command(argv)
        self.assertEqual(folder, game)
        self.assertEqual(cmd, ["/steam/proton", "waitforexitandrun", os.path.join(game, pvemode.EXE_REL), "-someflag",
                               "-nosplash"])

    def test_command_given_twice_runs_the_last(self):
        # #161: the tester's Steam log had our Shipping exe followed by Steam's whole wrapper chain as its arguments
        game = "/home/deck/.local/share/Steam/steamapps/common/PHtest"
        chain = ["/steam/reaper", "SteamLaunch", "AppId=1789480", "--", "/steam/proton", "waitforexitandrun"]
        argv = chain + [game + "/RaidGame.exe"] + chain + [game + "/RaidGame.exe"]
        cmd, folder = pvemode.game_command(argv)
        self.assertEqual(folder, game)
        self.assertEqual(cmd, chain + [os.path.join(game, pvemode.EXE_REL), "-nosplash"])

    def test_no_game_in_command(self):
        self.assertEqual(pvemode.game_command(["/usr/bin/true"]), (None, None))

    def test_dll_overrides(self):
        self.assertEqual(pvemode.dll_overrides(None), "dwmapi=n,b")
        self.assertEqual(pvemode.dll_overrides("d3d11=n;dwmapi=b"), "d3d11=n;dwmapi=n,b")


@unittest.skipUnless(HAVE_UE4SS, "needs tools/ue4ss (set up by scripts/setup-dev.ps1)")
class Switch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        sandbox(self.tmp)
        self.game = fake_game(self.tmp)
        with open(pvemode.GAME_PATH, "w") as f:
            f.write(self.game + "\n")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_offline_then_online_is_stock_again(self):
        before = snapshot(self.game)
        folder = pvemode.Folder(self.game)
        folder.offline()
        self.assertEqual(folder.mode(), "offline")
        self.assertTrue(os.path.exists(pvemode.DIRTY))
        with open(os.path.join(folder.bin, "Mods", "PvEDirector", "Scripts", "pveproject.lua")) as f:
            self.assertEqual(f.read(), f'return "{pvemode.project_root_for_mods()}"\n')
        with open(folder.ini) as f:
            ini = f.read()
        self.assertIn("socket_base_url = wss://127.0.0.1:1", ini)
        self.assertIn("http_base_url = https://127.0.0.1:1", ini)
        self.assertIn("other = 1", ini)
        folder.online()
        self.assertEqual(folder.mode(), "online")
        self.assertFalse(os.path.exists(pvemode.DIRTY))
        self.assertEqual(snapshot(self.game), before)

    @unittest.skipUnless(pvemode.LINUX, "Linux only")
    def test_mods_get_a_wine_path(self):
        self.assertTrue(pvemode.project_root_for_mods().startswith("Z:/"))

    def test_recover_after_an_unclean_exit(self):
        running, pvemode.game_running = pvemode.game_running, lambda: False  # (a real game may be open on this PC)
        self.addCleanup(setattr, pvemode, "game_running", running)
        before = snapshot(self.game)
        pvemode.Folder(self.game).offline()  # ...and then the Deck lost power
        self.assertTrue(pvemode.recover())
        self.assertEqual(snapshot(self.game), before)
        self.assertFalse(pvemode.recover())


FAKE_PROTON = r'''#!/bin/bash
# Records what it was started with, then plays "the game" for $FAKE_SECONDS.
game="$2"
bin="$(dirname "$game")"
{ echo "argv=$*"; echo "dll=$WINEDLLOVERRIDES"; [ -f "$bin/dwmapi.dll" ] && echo "offline=yes"; } > "$FAKE_LOG"
exec -a "$game" sleep "${FAKE_SECONDS:-0}"
'''

HARNESS = r'''
import os, sys
sys.path.insert(0, sys.argv[1])
import pvemode, test_pvemode
test_pvemode.sandbox(sys.argv[2])
pvemode.start_standin = lambda *a, **k: (None, None)   # no real backend in tests
sys.exit(pvemode.main(sys.argv[3:]))
'''


@unittest.skipUnless(HAVE_UE4SS and pvemode.LINUX, "Linux only (WSL works), and needs tools/ue4ss")
class SteamRun(unittest.TestCase):
    """The launch option end to end: Steam's command with a fake Proton."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        sandbox(self.tmp)
        self.game = fake_game(self.tmp)
        self.before = snapshot(self.game)
        self.proton = os.path.join(self.tmp, "proton")
        with open(self.proton, "w") as f:
            f.write(FAKE_PROTON)
        os.chmod(self.proton, 0o755)
        self.harness = os.path.join(self.tmp, "harness.py")
        with open(self.harness, "w") as f:
            f.write(HARNESS)
        self.log = os.path.join(self.tmp, "proton.log")
        pvemode.saves.create("Deck save", False)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_steam(self, seconds, *extra):
        env = dict(os.environ, FAKE_LOG=self.log, FAKE_SECONDS=str(seconds))
        return subprocess.Popen([sys.executable, self.harness, HERE, self.tmp, *extra, "steam-run", "--", self.proton,
                                 "waitforexitandrun", os.path.join(self.game, "RaidGame.exe")], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def test_play_and_tidy_up(self):
        p = self.run_steam(0)
        out, _ = p.communicate(60)
        self.assertEqual(p.returncode, 0, out)
        with open(self.log) as f:
            log = f.read()
        self.assertIn(pvemode.EXE_REL.replace(os.sep, "/"), log)      # the game, not the EAC bootstrapper
        self.assertIn("-nosplash", log)
        self.assertIn("dll=dwmapi=n,b", log)                         # UE4SS's proxy loaded native
        self.assertIn("offline=yes", log)                            # the mod was in place while it ran
        self.assertEqual(snapshot(self.game), self.before)           # and the folder is stock afterwards
        self.assertFalse(os.path.exists(pvemode.saves.ACTIVE))       # the save went back to its slot
        self.assertTrue(os.path.exists(os.path.join(pvemode.saves.SAVES, "deck-save", "state.json")))
        with open(os.path.join(self.tmp, "linux_launch.log"), encoding="utf-8") as f:
            launch = f.read()                                         # what a player sends when it fails (#161)
        self.assertIn("Steam's command: ", launch)
        self.assertIn("running: ", launch)
        self.assertIn("the game exited with code 0", launch)

    def test_killed_from_the_steam_menu(self):
        p = self.run_steam(30)
        deadline = time.time() + 30
        while not os.path.exists(self.log) and time.time() < deadline:
            time.sleep(0.2)
        self.assertEqual(pvemode.Folder(self.game).mode(), "offline")
        p.send_signal(signal.SIGTERM)
        out, _ = p.communicate(60)
        self.assertIn("tidying up", out)
        self.assertEqual(snapshot(self.game), self.before)

    def test_switched_off_runs_the_stock_game(self):
        with open(pvemode.STEAM_SETTING, "w") as f:
            f.write("off\n")
        p = self.run_steam(0)
        out, _ = p.communicate(60)
        with open(self.log) as f:
            log = f.read()
        self.assertIn("RaidGame.exe", log)
        self.assertNotIn("Shipping", log)
        self.assertNotIn("offline=yes", log)
        self.assertEqual(snapshot(self.game), self.before)


class LauncherOnLinux(unittest.TestCase):
    """The launcher window's Linux side (needs Tk and Pillow: skipped without them)."""

    def setUp(self):
        try:
            import tkinter  # noqa: F401
            import PIL.ImageTk  # noqa: F401
        except ImportError:
            self.skipTest("no Tk / Pillow")
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_desktop_entry(self):
        msg = pvemode.desktop_entry(os.path.join(self.tmp, "apps"))
        path = os.path.join(self.tmp, "apps", "marauders-offline.desktop")
        self.assertIn("app menu", msg)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("launcher.pyw", text)
        self.assertIn("Type=Application", text)

    @unittest.skipUnless(pvemode.LINUX, "Linux only")
    def test_launch_option_check(self):
        import importlib.machinery
        import importlib.util
        src = os.path.join(pvemode.ROOT, "launcher", "launcher.pyw")
        spec = importlib.util.spec_from_loader("launcher_t", importlib.machinery.SourceFileLoader("launcher_t", src))
        launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launcher)
        steam = os.path.join(self.tmp, "Steam")
        launcher.pvemode.steam_roots = lambda: [steam]
        self.assertIsNone(launcher.linux_launch_option())  # no Steam config: can't tell, PLAY tries anyway
        cfg = os.path.join(steam, "userdata", "123", "config")
        os.makedirs(cfg)
        vdf = os.path.join(cfg, "localconfig.vdf")

        def write(option):
            with open(vdf, "w", encoding="utf-8") as f:
                f.write('"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n'
                        '\t\t\t\t"apps"\n\t\t\t\t{\n\t\t\t\t\t"1789480"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LastPlayed"\t\t"1"\n'
                        + (f'\t\t\t\t\t\t"LaunchOptions"\t\t"{option}"\n' if option else "") +
                        '\t\t\t\t\t}\n\t\t\t\t\t"440"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LaunchOptions"\t\t"marauders-offline.sh"\n'
                        '\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n')
        write(None)
        self.assertIs(launcher.linux_launch_option(), False)  # (another game's option doesn't count)
        write('\\"/home/deck/Games/MaraudersOffline/linux/marauders-offline.sh\\" %command%')
        self.assertIs(launcher.linux_launch_option(), True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
