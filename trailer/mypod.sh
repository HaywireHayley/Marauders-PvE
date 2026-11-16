#!/bin/sh
# Your own pod in flight, from a chase camera: trailer/mypod.sh [name, default a_pod_player] [secs, default 8]
# Start it right after you launch your pod (you keep steering; only the view moves). Camera comes back at the end.
cd "$(dirname "$0")/.."
NAME=${1:-a_pod_player}
SECS=${2:-8}
sh trailer/cam.sh "local P = FindFirstOf('MainPlayerController_C') return CINE.chase(function() return P.Pawn end, {back=${BACK:-700}, up=${UP:-180}, side=${SIDE:-200}, lead=900, dur=$SECS})"
sh trailer/rec.sh "$NAME" "$SECS"
sh trailer/cam.sh 'return CINE.stop()'
