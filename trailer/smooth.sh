#!/bin/sh
# Smooth a clip the game recorded below 60 fps: trailer/smooth.sh <name> -> trailer/footage/<name>_s.mp4
# The capture repeats a frame whenever the game hadn't drawn a new one (~1 in 6 at 50 fps), which shows as judder.
# The repeats are dropped (keeping each real frame's own time) and the gaps filled with motion-interpolated frames.
cd "$(dirname "$0")/footage"
ffmpeg -hide_banner -loglevel error -y -i "$1.mp4" \
  -vf "mpdecimate=hi=200:lo=64:frac=0.33:max=3,minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1" \
  -c:v h264_amf -quality quality -rc cqp -qp_i 16 -qp_p 18 "$1_s.mp4"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$1_s.mp4"
