#!/bin/sh
# Sends commands to a PvEBridge in a chosen bridge dir (for driving a specific co-op instance).
#   bsend.sh <bridgeDir> "status" ["open 127.0.0.1:7777?PID=1" ...]
# bridgeDir is a project-relative name like "bridge" or "bridge2" (or an absolute path).
# Waits up to $WAIT seconds (default 20) for the command file to be consumed.
P="$(cd "$(dirname "$0")/.." && pwd)"
D="$1"; shift
case "$D" in /*|[A-Za-z]:*) B="$D" ;; *) B="$P/$D" ;; esac
n=$(wc -l < "$B/out.txt" 2>/dev/null || echo 0)
printf '%s\n' "$@" > "$B/cmd.txt"
for i in $(seq 1 ${WAIT:-20}); do [ -f "$B/cmd.txt" ] || break; sleep 1; done
sleep ${SETTLE:-2}
tail -n +$((n+1)) "$B/out.txt" 2>/dev/null
