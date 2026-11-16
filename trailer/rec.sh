#!/bin/sh
# Record the game window: trailer/rec.sh <name> <seconds>  -> trailer/footage/<name>.mp4 (60 fps, native size; scaled
# to 1080p in the edit). Windows Graphics Capture (ffmpeg's gfxcapture) reads the game window itself, so other windows
# on top of it (the Claude window) don't end up in the shot and the game doesn't need focus.
# Game client area: 1840x1035 (r.setres 1472x828w, trailer/setup.sh); the top 24 px (Razer overlay FPS bar) are cut,
# keeping 16:9. Encoded on the GPU (AMF) so the game keeps its frame rate while recording.
# REC_DDA=1 falls back to the old desktop-duplication capture (needs the game in front and uncovered).
cd "$(dirname "$0")"
if [ -n "$REC_DDA" ]; then
  [ -n "$NOFRONT" ] || powershell -NoProfile -ExecutionPolicy Bypass -File front.ps1
  SRC="ddagrab=output_idx=0:framerate=60:draw_mouse=0:offset_x=24:offset_y=63:video_size=1796x1010"
else
  SRC="gfxcapture=window_exe=(?i)RaidGame.*:capture_cursor=0:max_framerate=60:crop_left=22:crop_right=22:crop_top=24:crop_bottom=1"
fi
ffmpeg -hide_banner -loglevel error -y -filter_complex "$SRC,hwdownload,format=bgra,fps=60,crop=trunc(iw/2)*2:trunc(ih/2)*2,format=nv12" \
  -t "$2" -c:v h264_amf -quality quality -rc cqp -qp_i 16 -qp_p 18 "footage/$1.mp4"
ffprobe -v error -show_entries format=duration:stream=width,height,avg_frame_rate -of csv=p=0 "footage/$1.mp4"
