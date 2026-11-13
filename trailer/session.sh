#!/bin/sh
# Long gameplay recording while someone plays: trailer/session.sh [max minutes, default 45]
# 60 fps GPU-encoded 5-minute .mkv chunks in trailer/session/ (a killed recording keeps every finished chunk), plus a
# watcher that puts the window back to the recorded size/place after map loads reset it. Stop: touch session/stop.
cd "$(dirname "$0")/.."
rm -f trailer/session/stop
MAX=$(( ${1:-45} * 60 ))
(
  while [ ! -f trailer/session/stop ]; do
    r=$(powershell -NoProfile -ExecutionPolicy Bypass -File trailer/place.ps1 2>/dev/null | tr -d '\r')
    if [ "$r" != "client 1840x1035 at 3,39" ]; then
      ./scripts/send.sh "r.setres 1472x828w" > /dev/null 2>&1
      sleep 2
      powershell -NoProfile -ExecutionPolicy Bypass -File trailer/place.ps1 > /dev/null 2>&1
      echo "$(date +%H:%M:%S) window reset ($r)" >> trailer/session/watch.log
    fi
    sleep 4
  done
) &
stamp=$(date +%H%M)
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "ddagrab=output_idx=0:framerate=60:draw_mouse=0:offset_x=24:offset_y=63:video_size=1796x1010,hwdownload,format=bgra" \
  -t "$MAX" -vf "format=nv12" -c:v h264_amf -quality quality -rc cqp -qp_i 16 -qp_p 18 \
  -f segment -segment_time 300 -reset_timestamps 1 "trailer/session/play_${stamp}_%02d.mkv"
touch trailer/session/stop
