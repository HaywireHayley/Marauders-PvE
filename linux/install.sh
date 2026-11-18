#!/bin/sh
# Marauders Offline installer for Linux / Steam Deck: finds the game, writes config/game_path.txt, and prints the Steam
# launch option. Nothing in the game folder changes until you press PLAY.   sh linux/install.sh
here="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 isn't installed. On SteamOS it is part of the system; elsewhere install python3 (3.9 or newer)."
    exit 1
fi
chmod +x "$here/linux/marauders-offline.sh" 2>/dev/null
exec python3 "$here/scripts/pvemode.py" install
