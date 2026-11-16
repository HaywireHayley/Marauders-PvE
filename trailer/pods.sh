#!/bin/sh
# Rival drop pods, filmed on the pods themselves: trailer/pods.sh <name> [secs, default 16] [clash|board, default clash]
#   clash: two rival crews meet near you, APART units apart (default 6000), and one boards the other (bridge/rivals_clash)
#   board: the nearest crew comes to board you (bridge/rivals_board)
# bridge/t_podarm.lua puts the camera on the first pod as it launches; recording starts when the launch shows in the log.
# PODSHOT='{kind="chase", back=650, up=160, side=220, lead=900}' overrides the shot. Run while flying your ship.
cd "$(dirname "$0")/.."
NAME=${1:?name}
SECS=${2:-16}
HOW=${3:-clash}
L="/e/SteamLibrary/steamapps/common/PHtest/RaidGame/Binaries/Win64/UE4SS.log"
n=$(grep -ac "" "$L")
sh trailer/cam.sh "_G.PODSHOT = ${PODSHOT:-nil} return dofile('C:/Users/Hayley/Documents/MaraudersPvE/bridge/t_podarm.lua')"
# recording starts before the launch (rec.sh takes a few seconds to get going; pods fly for only ~2 s)
if [ "$HOW" = board ]; then
  sh trailer/cam.sh "return PODHOME()"
  touch bridge/rivals_board
  i=0; while [ $i -lt 40 ]; do tail -n +$n "$L" | grep -aq "engages your ship" && break; sleep 0.25; i=$((i+1)); done
  tail -n +$n "$L" | grep -aq "engages your ship" || { echo "no crew came for you (all docked?)"; sh trailer/cam.sh 'PODCAM.armed = false return CINE.stop()'; exit 1; }
  sh trailer/cam.sh "return PODINCOMING()"
  sh trailer/rec.sh "$NAME" "$SECS" &
else
  sh trailer/rec.sh "$NAME" "$SECS" &
  sleep 3
  echo "${APART:-6000}" > bridge/rivals_clash
  # once the mod has moved the ships, open on the attacker
  i=0; while [ $i -lt 20 ] && [ -f bridge/rivals_clash ]; do sleep 0.25; i=$((i+1)); done
  sleep 0.3
  sh trailer/cam.sh "return PODOPEN(${APART:-6000})"
fi
i=0; while [ $i -lt 240 ]; do tail -n +$n "$L" | grep -aq "launched [0-9]* \(breaching \)\?pod" && break; sleep 0.25; i=$((i+1)); done
tail -n +$n "$L" | grep -a "launched [0-9]* \(breaching \)\?pod\|clash: " | tail -2
tail -n +$n "$L" | grep -aq "launched [0-9]* \(breaching \)\?pod" || { echo "no pods launched in 60 s"; wait; sh trailer/cam.sh 'PODCAM.armed = false return CINE.stop()'; exit 1; }
wait
sh trailer/cam.sh 'PODCAM.armed = false return tostring(PODCAM.fired) .. " " .. CINE.stop()'
