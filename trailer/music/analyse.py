"""Song structure for timing the trailer: loudness, onset strength, tempo, beat grid. -> music/analysis.png + text"""
import wave, sys
import numpy as np
from PIL import Image, ImageDraw
w = wave.open(sys.argv[1]); sr = w.getframerate()
x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
hop, win = 512, 2048
n = (len(x) - win) // hop
frames = np.lib.stride_tricks.as_strided(x, (n, win), (x.strides[0] * hop, x.strides[0]))
spec = np.abs(np.fft.rfft(frames * np.hanning(win), axis=1))
logs = np.log1p(spec * 10)
flux = np.maximum(0, np.diff(logs, axis=0)).sum(axis=1)
flux = np.concatenate([[0], flux])
fps = sr / hop
rms = np.sqrt((frames ** 2).mean(axis=1))
# tempo: autocorrelation of the onset envelope, 70-190 BPM
o = flux - flux.mean()
ac = np.correlate(o, o, 'full')[len(o) - 1:]
lags = np.arange(len(ac))
bpm = 60 * fps / np.maximum(lags, 1)
ok = (bpm > 70) & (bpm < 190)
best = lags[ok][np.argmax(ac[ok])]
tempo = 60 * fps / best
# beat phase: offset maximising onset energy on the grid
period = best
scores = [flux[int(p)::1][::1][np.round(np.arange(0, n - p, period)).astype(int)].sum() if False else
          flux[np.clip(np.round(p + np.arange(0, n - p - 1, period)).astype(int), 0, n - 1)].sum() for p in range(int(period))]
phase = int(np.argmax(scores)) / fps
print(f"tempo {tempo:.1f} BPM, beat period {period / fps:.3f}s, first beat {phase:.3f}s, duration {len(x)/sr:.1f}s")
# loudness per second
sec = int(len(x) / sr)
loud = [20 * np.log10(np.sqrt((x[i * sr:(i + 1) * sr] ** 2).mean()) + 1e-9) for i in range(sec)]
print("loudness dB per 5s:", " ".join(f"{i*5}:{np.mean(loud[i*5:i*5+5]):.0f}" for i in range(sec // 5)))
# big onsets (hits): top flux peaks
pk = [(flux[i], i / fps) for i in range(2, n - 2) if flux[i] == flux[i - 2:i + 3].max()]
pk.sort(reverse=True)
print("strongest hits (s):", " ".join(f"{t:.2f}" for _, t in sorted(pk[:40], key=lambda a: a[1])))
# plot
W, H = 2400, 300
img = Image.new("RGB", (W, H * 2), "black"); d = ImageDraw.Draw(img)
t = np.arange(n) / fps
def plot(v, y0, col):
    v = v / (v.max() + 1e-9)
    pts = [(int(t[i] / t[-1] * (W - 1)), y0 + H - int(v[i] * (H - 10))) for i in range(0, n, 4)]
    d.line(pts, fill=col)
plot(np.convolve(rms, np.ones(20) / 20, 'same'), 0, (255, 160, 40))
plot(np.convolve(flux, np.ones(4) / 4, 'same'), H, (120, 200, 255))
for s in range(0, int(t[-1]), 10):
    xx = int(s / t[-1] * (W - 1)); d.line([(xx, 0), (xx, 2 * H)], fill=(60, 60, 60)); d.text((xx + 2, 2), str(s), fill="white")
img.save(sys.argv[2])
