#!/bin/sh
# Steam launch option for Marauders on Linux / Steam Deck (issue #127). In Steam: Marauders > Properties > General >
# Launch options:
#     "/path/to/MaraudersOffline/linux/marauders-offline.sh" %command%
# PLAY then starts the offline mod under Steam's own Proton, and puts the game folder back to stock when the game
# closes (scripts/pvemode.py steam-run). "pvemode.py steam off" makes PLAY start the stock online game again.
here="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$here/scripts/pvemode.py" steam-run -- "$@"
