"""Hitch check: freezes (runs of 4+ unchanged frames, ~67 ms+) in trailer/footage clips, with where they are.
python trailer/stalls.py a_x a_y ...   (a steady 50 fps game only repeats single frames; a run is a hitch)"""
import os, subprocess, sys
import numpy as np
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "footage")
for name in sys.argv[1:]:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", os.path.join(D, name + ".mp4"), "-vf", "scale=192:108,format=gray",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, 108, 192).astype(np.int16)
    same = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2)) < 0.12
    runs, i = [], 0
    while i < len(same):
        if same[i]:
            j = i
            while j < len(same) and same[j]: j += 1
            if j - i >= 3: runs.append((i / 60, (j - i + 1) / 60))
            i = j
        else: i += 1
    worst = max((r[1] for r in runs), default=0)
    at = " ".join(f"{t:.1f}s({d*1000:.0f}ms)" for t, d in runs[:8])
    print(f"{name:16s} {len(f)/60:5.1f}s  {len(runs):2d} freezes, worst {worst*1000:3.0f} ms  {at}")
