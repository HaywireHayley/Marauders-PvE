#!/bin/sh
# Polls the bridge `status` until its output matches a regex.  waitfor.sh <regex> [max seconds, default 90]
S="$(dirname "$0")/send.sh"
end=$(( $(date +%s) + ${2:-90} ))
while [ $(date +%s) -lt $end ]; do
  out=$(WAIT=4 SETTLE=1 $S status 2>/dev/null)
  echo "$out" | grep -qE "$1" && { echo "$out" | grep -E "world=|pc="; exit 0; }
  sleep 2
done
echo "timeout waiting for: $1"; exit 1
