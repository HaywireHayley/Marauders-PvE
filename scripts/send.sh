#!/bin/sh
# Sends one or more commands to the in-game PvEBridge and prints the replies.
#   send.sh "status" ["find RaidAIController" ...]   (waits up to $WAIT seconds, default 20)
P="$(cd "$(dirname "$0")/.." && pwd)"
B="$P/bridge"
n=$(wc -l < $B/out.txt 2>/dev/null || echo 0)
printf '%s\n' "$@" > $B/cmd.txt
for i in $(seq 1 ${WAIT:-20}); do [ -f $B/cmd.txt ] || break; sleep 1; done
sleep ${SETTLE:-2}
tail -n +$((n+1)) $B/out.txt
