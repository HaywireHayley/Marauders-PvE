"""Fine beat grid + section boundaries for a song: beats2.py mono.wav"""
import wave, sys
import numpy as np
w = wave.open(sys.argv[1]); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
hop, win = 256, 2048
n = (len(x) - win) // hop
fr = np.lib.stride_tricks.as_strided(x, (n, win), (x.strides[0] * hop, x.strides[0]))
spec = np.log1p(np.abs(np.fft.rfft(fr * np.hanning(win), axis=1)) * 10)
flux = np.concatenate([[0], np.maximum(0, np.diff(spec, axis=0)).sum(1)])
fps = sr / hop
best = None
for per in np.arange(0.620, 0.640, 0.00005):
    for ph in np.arange(0, per, 0.002):
        idx = np.round((ph + np.arange(0, len(x) / sr - ph, per)) * fps).astype(int)
        idx = idx[idx < n]
        s = flux[idx].sum() / len(idx)
        if best is None or s > best[0]: best = (s, per, ph)
_, per, ph = best
print(f"beat {per:.5f}s = {60/per:.2f} BPM, phase {ph:.3f}")
# loudness per beat, in bars
rms = np.sqrt((fr ** 2).mean(1)); db = 20 * np.log10(rms + 1e-9)
nb = int((len(x) / sr - ph) / per)
for b0 in range(0, nb, 4):
    vals = []
    for b in range(b0, min(b0 + 4, nb)):
        a, c = int((ph + b * per) * fps), int((ph + (b + 1) * per) * fps)
        vals.append(db[a:c].mean())
    print(f"beat {b0:4d} t={ph + b0 * per:7.2f}  " + " ".join(f"{v:5.0f}" for v in vals))
