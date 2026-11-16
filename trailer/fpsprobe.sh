#!/bin/sh
# Game frame rate over ~8 s of wall time, from the trailer camera's per-frame tick counter: trailer/fpsprobe.sh <label>
cd "$(dirname "$0")/.."
t0=$(date +%s.%N); a=$(SETTLE=0 sh trailer/cam.sh 'return tostring(CINE.ticks)' | sed 's/.*= //'); t1=$(date +%s.%N)
sleep 8
t2=$(date +%s.%N); b=$(SETTLE=0 sh trailer/cam.sh 'return tostring(CINE.ticks)' | sed 's/.*= //'); t3=$(date +%s.%N)
echo "$1 $a $b $t0 $t1 $t2 $t3" | awk '{printf "%s %.1f fps\n", $1, ($3-$2)/(($6+$7)/2-($4+$5)/2)}'
