#!/bin/sh
# Run Lua in the game through the bridge, prints the reply: trailer/cam.sh 'CINE.orbit(SL[2], {...})'
cd "$(dirname "$0")/.."
WAIT=8 SETTLE=${SETTLE:-1} sh scripts/send.sh "lua $1" | tail -1 | cut -c1-400
