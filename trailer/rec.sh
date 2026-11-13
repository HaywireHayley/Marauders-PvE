#!/bin/sh
# Record the game window (desktop duplication, so the game must be in front and uncovered):
#   trailer/rec.sh <name> <seconds>  -> trailer/footage/<name>.mp4 (60 fps, native size; scaled to 1080p in the edit)
# Game client area: 1840x1035 at 3,39 (r.setres 1472x828w, window moved to -8,0); the top 24 px (Razer overlay
# FPS bar) are cut, keeping 16:9. Encoded on the GPU (AMF) so the game keeps its frame rate while recording.
cd "$(dirname "$0")"
[ -n "$NOFRONT" ] || powershell -NoProfile -ExecutionPolicy Bypass -File front.ps1
X=${REC_X:-24}; Y=${REC_Y:-63}; W=${REC_W:-1796}; H=${REC_H:-1010}
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "ddagrab=output_idx=0:framerate=60:draw_mouse=0:offset_x=$X:offset_y=$Y:video_size=${W}x${H},hwdownload,format=bgra" \
  -t "$2" -vf "format=nv12" -c:v h264_amf -quality quality -rc cqp -qp_i 16 -qp_p 18 "footage/$1.mp4"
ffprobe -v error -show_entries format=duration:stream=width,height,avg_frame_rate -of csv=p=0 "footage/$1.mp4"
