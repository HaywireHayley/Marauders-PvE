"""Onsets in a song range, as beat positions: stabs.py mono.wav b0 b1 [thresh]"""
import wave, sys
import numpy as np
w = wave.open(sys.argv[1]); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
BEAT, PH = 0.63160, 0.030
hop, win = 256, 1024
n = (len(x) - win) // hop
fr = np.lib.stride_tricks.as_strided(x, (n, win), (x.strides[0] * hop, x.strides[0]))
spec = np.log1p(np.abs(np.fft.rfft(fr * np.hanning(win), axis=1)) * 10)
flux = np.concatenate([[0], np.maximum(0, np.diff(spec, axis=0)).sum(1)])
rms = np.sqrt((fr ** 2).mean(1))
fps = sr / hop
b0, b1 = float(sys.argv[2]), float(sys.argv[3])
a, c = int((PH + b0 * BEAT) * fps), int((PH + b1 * BEAT) * fps)
seg = flux[a:c]; th = float(sys.argv[4]) if len(sys.argv) > 4 else 0.45
pk = [i for i in range(3, len(seg) - 4) if seg[i] == seg[i-3:i+4].max() and seg[i] > th * seg.max()]
for i in pk:
    t = (a + i) / fps
    nxt = rms[a + i: a + i + int(0.25 * fps)].mean()
    print(f"t={t:7.3f} beat={(t - PH) / BEAT:7.2f} flux={seg[i]/seg.max():.2f} rms={20*np.log10(nxt):.0f}")
