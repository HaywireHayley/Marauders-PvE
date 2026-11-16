"""Action meter: per second of a trailer/footage clip, how much fire is on screen (bright warm pixels: muzzle flashes,
tracers, explosions) -> python trailer/action.py a_x [a_y ...]. Prints a bar per second and the best 2 s window."""
import os, subprocess, sys
import numpy as np
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "footage")
W, H = 240, 135
for name in sys.argv[1:]:
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", os.path.join(D, name + ".mp4"), "-vf", f"scale={W}:{H},fps=30",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    f = np.frombuffer(raw, np.uint8).reshape(-1, H, W, 3).astype(np.int16)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    hot = ((r > 200) & (g > 90) & (b < 140) & (r - b > 90)).sum(axis=(1, 2))  # orange/yellow fire
    per = [hot[i:i + 30].mean() for i in range(0, len(hot), 30)]
    win = [sum(per[i:i + 2]) for i in range(max(1, len(per) - 1))]
    best = int(np.argmax(win))
    print(f"{name}: best {best}-{best + 2}s  " + " ".join(f"{p:.0f}" for p in per))
