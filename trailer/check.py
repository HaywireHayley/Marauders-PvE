"""Footage check: real frame rate (frames that actually changed) of trailer/footage clips: python trailer/check.py a_x a_y ..."""
import os, subprocess, sys
import numpy as np
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "footage")
for name in sys.argv[1:]:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", os.path.join(D, name + ".mp4"), "-vf", "scale=192:108,format=gray",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, 108, 192).astype(np.int16)
    d = np.abs(np.diff(f, axis=0)).mean(axis=(1, 2))
    rep = (d < 0.12).mean()
    print(f"{name:16s} {len(f) / 60:5.1f}s  ~{60 * (1 - rep):.0f} real fps  {'OK' if rep < 0.15 else 'CHOPPY'}")
