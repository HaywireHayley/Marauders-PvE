#!/bin/sh
# Contact sheet of a footage clip: trailer/sheet.sh <name> <out.png>  (8 frames across the clip)
cd "$(dirname "$0")"
f=footage/$1.mp4; [ -f "$f" ] || f=session/$1.mkv
d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
ffmpeg -hide_banner -loglevel error -y -i "$f" -vf "fps=8/$d,scale=480:-1,tile=4x2" -frames:v 1 "$2"
