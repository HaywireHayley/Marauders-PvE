"""Where the project and the game live, for the Python tools.

ROOT: this project folder (worked out from this file's location).
GAME: the Marauders install folder (the one holding RaidGame\\). Set it once in config/game_path.txt (one line);
      scripts/mode.ps1, launch-offline.ps1 and the launcher read the same file.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME_PATH_FILE = os.path.join(ROOT, "config", "game_path.txt")
DEFAULT_GAME = r"C:\Program Files (x86)\Steam\steamapps\common\PHtest"


def _game():
    try:
        with open(GAME_PATH_FILE, encoding="utf-8") as f:
            return f.readline().strip() or DEFAULT_GAME
    except OSError:
        return DEFAULT_GAME


GAME = _game()
