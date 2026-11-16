#!/bin/sh
# Spawn an ambient ship fight near your ship (you must be flying it), then film it: trailer/fight.sh <name> <secs> '<CINE shot>' ['<second shot>' <name2> <secs2>]
# The shot can use PA / PB (the two fighting ships, from t_pair.lua) and MID (their midpoint). Camera goes back to you at the end.
cd "$(dirname "$0")/.."
L="/e/SteamLibrary/steamapps/common/PHtest/RaidGame/Binaries/Win64/UE4SS.log"
n=$(wc -l < "$L")
printf "%s" "${SIZE:-}" > bridge/rivals_skirmish
i=0; while [ $i -lt 20 ]; do tail -n +$n "$L" | grep -aq "skirmish: " && break; sleep 0.5; i=$((i+1)); done
got=$(tail -n +$n "$L" | grep -a "skirmish: " | tail -1)
echo "$got"
case "$got" in *" against "*) ;; *) echo "no fight spawned: nothing filmed"; exit 1 ;; esac
sleep ${LEAD:-2}
sh trailer/cam.sh 'return CINE and "cine ok" or dofile("C:/Users/Hayley/Documents/MaraudersPvE/bridge/cine.lua")' >/dev/null
# wait (up to 20 s) for the two ships to close within CLOSE units (default 400 m), so both fit in one frame
i=0; while :; do
  pair=$(sh trailer/cam.sh 'return dofile("C:/Users/Hayley/Documents/MaraudersPvE/bridge/t_pair.lua")' | tail -1)
  d=$(echo "$pair" | sed -n 's/.*pair \([0-9]*\) apart.*/\1/p')
  [ -n "$d" ] && [ "$d" -lt "${CLOSE:-40000}" ] && break
  i=$((i+1)); [ $i -ge 20 ] && break; sleep 1
done
echo "$pair"
case "$pair" in *"no pair"*) echo "fight not found near you: nothing filmed"; exit 1 ;; esac
sh trailer/cam.sh "return $3"
sh trailer/orec.sh "$1" "$2"
if [ -n "$4" ]; then sh trailer/cam.sh "return $4"; sh trailer/orec.sh "$5" "$6"; fi
sh trailer/cam.sh 'return CINE.stop()'
tail -n +$n "$L" | grep -a "went down\|won their" | tail -2
