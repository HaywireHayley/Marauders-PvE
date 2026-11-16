#!/bin/sh
# Rolling recording while you play: trailer/roll.sh [max minutes, default 30] -> trailer/footage/roll_HHMMSS_NN.mkv,
# 5-minute chunks (gfxcapture, like rec.sh, so other windows don't get in). The start time is in the file name, so
# clock times from the log ([podcam] ... at HH:MM:SS) map to offsets in the chunks. Stop: touch trailer/footage/roll_stop
cd "$(dirname "$0")"
rm -f footage/roll_stop
stamp=$(date +%H%M%S)
echo "roll_$stamp started $(date +%H:%M:%S)"
ffmpeg -hide_banner -loglevel error -y -filter_complex "gfxcapture=window_exe=(?i)RaidGame.*:capture_cursor=0:max_framerate=60:crop_left=22:crop_right=22:crop_top=24:crop_bottom=1,hwdownload,format=bgra,fps=60,crop=trunc(iw/2)*2:trunc(ih/2)*2,format=nv12" \
  -t $(( ${1:-30} * 60 )) -c:v h264_amf -quality quality -rc cqp -qp_i 16 -qp_p 18 \
  -f segment -segment_time 300 -reset_timestamps 1 "footage/roll_${stamp}_%02d.mkv" < /dev/null &
FF=$!
while kill -0 $FF 2>/dev/null; do
  [ -f footage/roll_stop ] && { taskkill //F //IM ffmpeg.exe > /dev/null 2>&1; break; }
  sleep 1
done
wait
ls -la footage/roll_${stamp}_*.mkv
