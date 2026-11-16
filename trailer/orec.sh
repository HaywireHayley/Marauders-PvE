#!/bin/sh
# Record the game with OBS for <secs> seconds into trailer/footage/<name>.mkv: trailer/orec.sh <name> <secs>
cd "$(dirname "$0")"
python obs.py start > /dev/null || exit 1
sleep "$2"
out=$(python obs.py stop | sed 's/^saved //')
mv -f "$out" "footage/$1.mkv" && echo "recorded footage/$1.mkv ($2 s)"
