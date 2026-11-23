#!/bin/sh
# Marauders Offline installer for Linux / Steam Deck: finds the game, writes config/game_path.txt, and prints the Steam
# launch option. Nothing in the game folder changes until you press PLAY.   sh linux/install.sh
# From the small installer zip (no version.txt yet) it first downloads the latest build and its parts from GitHub
# (scripts/bootstrap.py, checked downloads), as Install.bat does on Windows.
# Everything is inside main(): the download replaces this file while it runs, and sh reads a function whole first.
main() {
    here="$(cd "$(dirname "$0")/.." && pwd)"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Python 3 isn't installed. On SteamOS it is part of the system; elsewhere install python3 (3.9 or newer)."
        exit 1
    fi
    if [ ! -f "$here/version.txt" ]; then
        echo "Downloading the latest Marauders Offline build from GitHub..."
        python3 "$here/scripts/bootstrap.py" || exit 1
    fi
    chmod +x "$here/linux/marauders-offline.sh" 2>/dev/null
    exec python3 "$here/scripts/pvemode.py" install
}
main "$@"
exit
