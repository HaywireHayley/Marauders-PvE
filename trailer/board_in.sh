#!/bin/sh
# Rivals board your ship, filmed from outside: trailer/board_in.sh [name, default a_pods_incoming] [seconds, default 18]
# Sends the nearest flying crew at you with orders to board (bridge/rivals_board), puts the trailer camera on your ship
# as soon as they turn to attack (pods launch a few seconds later at ~120 m), records, then gives you your view back so
# you can fight the boarders. Run while flying your ship, ideally away from the map edge.
cd "$(dirname "$0")/.."
NAME=${1:-a_pods_incoming}
SECS=${2:-18}
L="/e/SteamLibrary/steamapps/common/PHtest/RaidGame/Binaries/Win64/UE4SS.log"
n=$(grep -ac "" "$L")
touch bridge/rivals_board
i=0; while [ $i -lt 40 ]; do tail -n +$n "$L" | grep -aq "engages your ship" && break; sleep 0.25; i=$((i+1)); done
tail -n +$n "$L" | grep -a "engages your ship" | tail -1 | grep . || { echo "no crew came for you (none left flying or waiting)"; exit 1; }
sh trailer/cam.sh "dofile('C:/Users/Hayley/Documents/MaraudersPvE/bridge/t_myship.lua') return CINE.orbit(MYSHIP, {r=${CAM_R:-2600}, h=${CAM_H:-1600}, a0=150, a1=200, dur=24, fov=65})"
sh trailer/rec.sh "$NAME" "$SECS"
sh trailer/cam.sh 'return CINE.stop()'
tail -n +$n "$L" | grep -a "pods at you\|pulling alongside\|boarders" | tail -3
