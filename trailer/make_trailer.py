"""Marauders offline PvE trailer: edit list + synthesized score + frame renderer.

Footage comes from trailer/footage/*.mp4 (recorded with rec.sh, 1080p30). Run:  python trailer/make_trailer.py
Output: trailer/marauders_offline_trailer.mp4 (and score.wav).
"""
import math
import os
import subprocess
import sys
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FOOT = os.path.join(HERE, "footage")
OUT = os.path.join(HERE, "marauders_offline_trailer.mp4")
TMP = OUT + ".part.mp4"  # rendered here, moved into place when complete
W, H, FPS = 1920, 1080, 60
SR = 44100
BEAT = 0.6  # 100 BPM
DRUMS_AT = 15.6
HITS = [12.0, 33.6, 51.0, 65.4]
END = 72.0
FONT = "C:/Windows/Fonts/bahnschrift.ttf"

# ---------------------------------------------------------------------------------------------------------------
# Edit list: (timeline start, clip, clip in, duration, options)
#   zoom: (from, to) scale over the segment; focus: (x, y) zoom centre as fractions; flash: white flash on the cut
P0, P1, P2 = "play_0937_00", "play_0937_01", "play_0937_02"  # your play session (trailer/session)

# Timed to the song (I Prevail, "Bow Down"): its first hit (11.49 s) lands on the title at 12.0; beats are 0.58033 s
# apart (120 beats from that hit to the big one at 81.13 s); the break is song 38-43 s; next hit at song 44.03 s.
SONG = "E:/Downloads/i-prevail-bow-down-official-music-video-128-ytshorts.savetube.me.mp3"
SONG_OFFSET = 12.0 - 11.49      # the song starts this late in the video
SB = 0.58033                    # one beat
def beat(k): return 12.0 + k * SB
HITS = [12.0, beat(56), beat(120)]
END = beat(120) + 7.0

EDL = [(6.0, "s01_myship", 2.0, 6.0, dict(zoom=(1.0, 1.08), fadein=1.2))]
TEXT = [
    (0.5, 2.9, "card", ["THE SERVERS WILL GO DARK EVENTUALLY."]),
    (3.3, 5.7, "card", ["THE RAIDS DON'T HAVE TO."]),
    (12.0, beat(4), "title", ["MARAUDERS", "OFFLINE  PvE"]),
]


def run(k0, shots):
    """shots: (clip, in, beats, options, caption lines or None) laid end to end from beat k0; returns the end beat."""
    k = k0
    for clip, cin, nb, o, cap in shots:
        t0, dur = beat(k), nb * SB
        EDL.append((t0, clip, cin, dur, o))
        if cap:
            TEXT.append((t0 + 0.2, t0 + dur - 0.05, "cap", cap))
        k += nb
    return k


F, P = dict(flash=True), dict(punch=True)
# space: the first loud section (beats 4-44)
k = run(4, [
    ("s02_chase1", 0.5, 4, F, ["11 RIVAL CREWS", "EVERY RAID"]),
    (P0, 192.0, 4, P, None),
    ("t_fight", 0.5, 4, P, ["26 SHIPS", "REAL TURRETS, REAL DAMAGE"]),
    ("t_fight3", 5.0, 5, P, None),
    (P0, 276.0, 4, P, None),
    ("s06_duel2", 2.5, 4, P, ["THEY HUNT EACH OTHER", "AND YOU"]),
    (P1, 28.0, 4, P, None),
    ("s05_duel1", 0.3, 4, P, None),
    (P1, 0.5, 3, P, None),
    (P1, 58.0, 4, P, ["DOCK", "BOARD THE STATIONS"]),
])
# the break (beats 44-56): quiet, searching
k = run(k, [
    (P1, 85.0, 4, F, None),
    ("s09_rival", 4.0, 8, P, ["RIVALS SEARCH", "NOBODY KNOWS WHERE YOU ARE"]),
])
# the hit at beat 56: fights, loot, out (beats 56-112), then the montage into the big hit at beat 120
k = run(k, [
    (P2, 140.6, 4, F, ["FIGHT YOUR WAY", "THROUGH"]),
    (P2, 45.0, 4, P, None),
    (P2, 17.0, 4, P, ["EVERY STATION", "DEFENDED"]),
    ("s09_rival", 22.0, 4, P, None),
    (P2, 165.0, 4, P, None),
    (P1, 268.0, 4, P, None),
    (P1, 150.0, 4, P, None),
    (P2, 55.5, 4, P, None),
    (P1, 120.0, 4, P, None),
    (P2, 60.0, 4, P, None),
    (P2, 136.8, 4, F, ["LOOT", "EVERYTHING"]),
    ("s13_loot2", 1.0, 4, dict(zoom=(1.15, 1.9), focus=(0.17, 0.80)), ["CONTRACTS", "THAT PAY OUT"]),
    ("escaped", 0.2, 6, dict(zoom=(1.0, 1.12), focus=(0.5, 0.3), punch=True), ["GET OUT", "ALIVE"]),
    (P0, 52.0, 4, dict(zoom=(1.0, 1.06), punch=True), ["YOUR STASH", "SAVED LOCALLY"]),
])
MONTAGE = [(P1, 1.0), ("t_fight3", 6.6), (P2, 141.2), ("s02_chase1", 2.0), (P0, 280.0), (P2, 19.0),
           (P1, 35.0), (P1, 268.0), ("s06_duel2", 4.0), (P2, 46.0), ("t_fight", 3.0), (P2, 142.0)]
for i, (clip, cin) in enumerate(MONTAGE):  # half-beat cuts
    EDL.append((beat(k) + i * SB / 2, clip, cin, SB / 2, dict(flash=(i % 2 == 0))))
assert abs(beat(k) + len(MONTAGE) * SB / 2 - beat(120)) < 1e-6, (k, len(MONTAGE))
TEXT.append((beat(120), END - 0.6, "end", ["MARAUDERS", "OFFLINE  PvE", "NO SERVERS.  NO QUEUE.  JUST THE RAID."]))

ORANGE = (255, 138, 36)


# ---------------------------------------------------------------------------------------------------------------
# Score
def synth():
    n = int(END * SR)
    t = np.arange(n) / SR
    L = np.zeros(n)
    R = np.zeros(n)
    rng = np.random.default_rng(7)

    def add(sig, at, pan=0.0, gain=1.0):
        i = int(at * SR)
        if i >= n:
            return
        s = sig[: n - i] * gain
        L[i:i + len(s)] += s * (1 - max(0, pan))
        R[i:i + len(s)] += s * (1 + min(0, pan))

    def saw(f, tt):
        return 2 * ((tt * f) % 1.0) - 1

    def lp_fast(x, cutoff, passes=2):
        # cheap smoothing: repeated moving average approximates a low-pass without a Python loop
        k = max(1, int(SR / (cutoff * 2)))
        ker = np.ones(k) / k
        for _ in range(passes):
            x = np.convolve(x, ker, mode="same")
        return x

    def env(length, a, d):
        tt = np.arange(int(length * SR)) / SR
        return np.minimum(1, tt / max(a, 1e-4)) * np.exp(-np.maximum(0, tt - a) / d)

    # drone: A1 + E2, detuned saws, slow swell, through the whole piece
    drone = np.zeros(n)
    for f, g in ((55.0, 1.0), (55.4, 0.8), (82.4, 0.5), (110.2, 0.25)):
        drone += saw(f, t) * g
    drone = lp_fast(drone, 220)
    swell = 0.5 + 0.5 * np.sin(2 * math.pi * t / 9.0 - 1.5)
    dr_gain = np.interp(t, [0, 6, 12, 15.6, 63, 65.4, 68, END], [0.15, 0.35, 0.5, 0.18, 0.18, 0.55, 0.4, 0.0])
    L += drone * swell * dr_gain * 0.35
    R += drone * (1 - 0.3 * swell) * dr_gain * 0.35

    # cold-open pulses (heartbeat): soft low thumps
    for k in range(10):
        at = 0.3 + k * 1.2
        tt = np.arange(int(0.5 * SR)) / SR
        f = 70 * np.exp(-tt * 6) + 38
        thump = np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-tt * 9)
        add(thump, at, gain=0.55 + 0.04 * k)
        add(thump, at + 0.22, gain=0.3)

    # riser 6 -> 12: noise sweep + rising tone
    rl = 6.0
    tt = np.arange(int(rl * SR)) / SR
    noise = rng.standard_normal(len(tt))
    sweep = np.zeros_like(noise)
    for seg in range(12):  # band gets brighter in steps
        a, b = int(seg * len(tt) / 12), int((seg + 1) * len(tt) / 12)
        sweep[a:b] = lp_fast(noise[a:b], 300 + seg * 450, passes=1)
    ramp = (tt / rl) ** 2.2
    tone = np.sin(2 * math.pi * np.cumsum(110 + 330 * (tt / rl) ** 2) / SR)
    add((sweep * 0.6 + tone * 0.25) * ramp, 6.0, gain=0.9)

    # braam hits
    def braam(length=3.5):
        tt = np.arange(int(length * SR)) / SR
        s = np.zeros_like(tt)
        for f, g in ((55, 1.0), (55.3, 0.9), (110, 0.7), (110.5, 0.6), (164.8, 0.45), (220, 0.25)):
            s += saw(f, tt) * g
        bright = lp_fast(s, 900, passes=1)
        dark = lp_fast(s, 250, passes=2)
        e = env(length, 0.02, 1.4)
        mix = (bright * np.exp(-tt * 2.2) + dark) * e
        f = 60 * np.exp(-tt * 1.8) + 28
        sub = np.sin(2 * math.pi * np.cumsum(f) / SR) * env(length, 0.005, 1.1)
        crash = rng.standard_normal(len(tt)) * np.exp(-tt * 3.5) * 0.35
        return mix * 0.55 + sub * 0.9 + crash

    for h in HITS:
        b = braam(4.5 if h == HITS[-1] else 3.5)
        add(b, h, pan=-0.15, gain=0.9)
        add(b, h + 0.012, pan=0.15, gain=0.9)

    # drums + bass ostinato, 15.6 -> 65.4 (break before each hit)
    def kick():
        tt = np.arange(int(0.45 * SR)) / SR
        f = 130 * np.exp(-tt * 28) + 44
        return np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-tt * 7) + \
            rng.standard_normal(len(tt)) * np.exp(-tt * 120) * 0.15

    def snare():
        tt = np.arange(int(0.35 * SR)) / SR
        body = np.sin(2 * math.pi * 190 * tt) * np.exp(-tt * 22)
        nz = lp_fast(rng.standard_normal(len(tt)), 5000, passes=1) * np.exp(-tt * 13)
        return body * 0.6 + nz * 0.8

    def hat():
        tt = np.arange(int(0.07 * SR)) / SR
        nz = rng.standard_normal(len(tt))
        nz = nz - lp_fast(nz, 3000, passes=1)
        return nz * np.exp(-tt * 70)

    def tom(f0):
        tt = np.arange(int(0.4 * SR)) / SR
        f = f0 * (1 + 0.6 * np.exp(-tt * 20))
        return np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-tt * 8)

    K, S, HH = kick() * 0.7, snare() * 0.7, hat() * 0.8
    roots = [55.0, 43.65, 49.0, 41.2]  # A, F, G, E (low)
    beat_i = 0
    tb = DRUMS_AT
    while tb < 65.4 - 1e-6:
        near_hit = any(h - 1.2 <= tb < h for h in HITS[1:])  # 2-beat break with tom fill before a hit
        in_montage = tb >= 63.0
        bar_pos = beat_i % 4
        if near_hit:
            add(tom(110 - 20 * bar_pos), tb, pan=0.3, gain=0.8)
            add(tom(80 - 10 * bar_pos), tb + BEAT / 2, pan=-0.3, gain=0.8)
        elif in_montage:
            for k in range(4):  # snare roll
                add(S, tb + k * BEAT / 4, gain=0.35 + 0.15 * k)
            add(K, tb, gain=1.0)
        else:
            add(K, tb, gain=1.0)
            if bar_pos in (1, 3):
                add(S, tb, gain=0.75)
            if bar_pos == 2 and beat_i % 8 == 6:
                add(K, tb + BEAT / 2, gain=0.7)
            for k in range(2):
                add(HH, tb + k * BEAT / 2, pan=0.4, gain=0.25 if k else 0.35)
        # bass: 16ths on the root, chord per bar
        if not near_hit:
            root = roots[(beat_i // 4) % 4]
            for k in range(4):
                tt = np.arange(int(BEAT / 4 * SR)) / SR
                note = saw(root * (2 if k == 2 else 1), tt) * np.exp(-tt * 9)
                add(lp_fast(note, 500, passes=1), tb + k * BEAT / 4, gain=0.24)
        beat_i += 1
        tb = DRUMS_AT + beat_i * BEAT

    # whooshes on montage cuts
    for i in range(len(MONTAGE)):
        tt = np.arange(int(0.25 * SR)) / SR
        w = lp_fast(rng.standard_normal(len(tt)), 2500, passes=1) * np.sin(np.pi * tt / 0.25) ** 2
        add(w, 63.0 + i * 0.3 - 0.08, pan=(-0.5 if i % 2 else 0.5), gain=0.35)

    # master
    fade = np.interp(t, [0, 0.2, END - 3.0, END], [0, 1, 1, 0])
    mix = np.stack([L, R], axis=1) * fade[:, None]
    mix = np.tanh(mix * 1.3)
    mix /= np.max(np.abs(mix)) / 0.89
    return mix


def write_wav(path, mix):
    data = (mix * 32767).astype(np.int16)
    with wave.open(path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(data.tobytes())


# ---------------------------------------------------------------------------------------------------------------
# Video
def font(size):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name("Bold")
    except Exception:
        pass
    return f


def font_cond(size, weight="SemiBold Condensed"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def spaced(draw, xy, text, fnt, fill, spacing, anchor_center=False):
    """Draw text with letter spacing; returns width."""
    widths = [draw.textlength(ch, font=fnt) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x, y = xy
    if anchor_center:
        x -= total / 2
    for ch, w in zip(text, widths):
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += w + spacing
    return total


def ease_out(x):
    x = min(1, max(0, x))
    return 1 - (1 - x) ** 3


_SHADE = None


def caption_shade():
    """Dark elliptical falloff in the lower-left corner, behind captions."""
    global _SHADE
    if _SHADE is None:
        yy, xx = np.mgrid[0:H, 0:W]
        r = np.sqrt(((xx - 420) / 900) ** 2 + ((yy - (H - 230)) / 330) ** 2)
        alpha = (np.clip(1 - r, 0, 1) ** 1.5 * 170).astype(np.uint8)
        arr = np.zeros((H, W, 4), np.uint8)
        arr[..., 3] = alpha
        _SHADE = Image.fromarray(arr, "RGBA")
    return _SHADE


def text_layer(kind, lines, lt, dur):
    """RGBA overlay for a text item at local time lt (seconds into it)."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    fade_in = ease_out(lt / 0.35)
    fade_out = 1 - ease_out((lt - (dur - 0.4)) / 0.4) if lt > dur - 0.4 else 1
    a = fade_in * fade_out
    if kind == "card":
        f = font_cond(64, "Light Condensed")
        sp = 10 + 6 * (lt / dur)  # tracking slowly opens up
        spaced(d, (W / 2, H / 2 - 40), lines[0], f, (235, 235, 235, int(255 * a)), sp, anchor_center=True)
    elif kind in ("title", "end"):
        big = font(220 if kind == "title" else 190)
        sp = 34 - 10 * ease_out(lt / 1.5)
        y0 = H / 2 - (190 if kind == "title" else 230)
        # glitch-in: horizontal slice offsets for the first few frames
        glitch = lt < 0.25
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        spaced(ld, (W / 2, y0), lines[0], big, (245, 245, 245, int(255 * a)), sp, anchor_center=True)
        if glitch:
            arr = np.array(layer)
            rng = np.random.default_rng(int(lt * 1000))
            for _ in range(8):
                yy = rng.integers(int(y0), int(y0 + 230))
                hh = rng.integers(6, 30)
                arr[yy:yy + hh] = np.roll(arr[yy:yy + hh], rng.integers(-60, 60), axis=1)
            layer = Image.fromarray(arr)
        # chromatic fringe
        r = layer.split()[3].point(lambda v: v * 0.55)
        fringe = Image.new("RGBA", (W, H), ORANGE + (0,))
        fringe.putalpha(r)
        img.alpha_composite(fringe, (6, 0))
        img.alpha_composite(layer)
        sub = font_cond(56, "SemiBold Condensed")
        sa = a * ease_out((lt - 0.5) / 0.5)
        spaced(d, (W / 2, y0 + 250), lines[1], sub, ORANGE + (int(255 * sa),), 22, anchor_center=True)
        # thin rules either side of the subtitle
        rw = 260 * ease_out((lt - 0.6) / 0.8)
        cy = y0 + 285
        d.line([(W / 2 - 330 - rw, cy), (W / 2 - 330, cy)], fill=ORANGE + (int(200 * sa),), width=3)
        d.line([(W / 2 + 330, cy), (W / 2 + 330 + rw, cy)], fill=ORANGE + (int(200 * sa),), width=3)
        if kind == "end" and len(lines) > 2:
            ta = a * ease_out((lt - 1.4) / 0.6)
            spaced(d, (W / 2, y0 + 360), lines[2], font_cond(40, "Light Condensed"),
                   (220, 220, 220, int(255 * ta)), 8, anchor_center=True)
    else:  # lower-left caption: orange bar + two lines sliding in, over a soft dark corner for contrast
        x0 = 150
        y0 = H - 330
        shade = caption_shade().copy()
        shade.putalpha(shade.split()[3].point(lambda v: int(v * a)))
        img.alpha_composite(shade)
        slide = 60 * (1 - ease_out(lt / 0.4))
        bar_h = 150 * ease_out(lt / 0.3)
        d.rectangle([x0 - 28, y0 + 8, x0 - 18, y0 + 8 + bar_h], fill=ORANGE + (int(255 * fade_out),))
        f1 = font_cond(78, "Bold Condensed")
        f2 = font_cond(52, "SemiBold Condensed")
        shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        spaced(sd, (x0 + slide + 3, y0 + 3), lines[0], f1, (0, 0, 0, int(200 * a)), 6)
        a2 = a * ease_out((lt - 0.15) / 0.35)
        spaced(sd, (x0 + slide * 1.5 + 3, y0 + 92), lines[1], f2, (0, 0, 0, int(200 * a2)), 6)
        img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(4)))
        spaced(d, (x0 + slide, y0), lines[0], f1, (245, 245, 245, int(255 * a)), 6)
        spaced(d, (x0 + slide * 1.5, y0 + 92), lines[1], f2, ORANGE + (int(255 * a2),), 6)
    return img


class Clip:
    """Sequential frame reader for one EDL segment."""

    def __init__(self, name, cin, dur):
        path = os.path.join(FOOT, name + ".mp4")
        if not os.path.exists(path):  # gameplay session chunks (60 fps, native size)
            path = os.path.join(HERE, "session", name + ".mkv")
        self.p = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(cin), "-i", path, "-t", str(dur + 0.2),
             "-vf", f"fps={FPS},scale={W}:{H}:flags=lanczos", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdout=subprocess.PIPE)
        self.last = np.zeros((H, W, 3), np.uint8)

    def read(self):
        buf = self.p.stdout.read(W * H * 3)
        if len(buf) == W * H * 3:
            self.last = np.frombuffer(buf, np.uint8).reshape(H, W, 3)
        return self.last

    def close(self):
        self.p.stdout.close()
        self.p.wait()


def zoom_frame(fr, s, fx=0.5, fy=0.5):
    if abs(s - 1) < 1e-3:
        return fr
    cw, ch = W / s, H / s
    x0 = min(max(fx * W - cw / 2, 0), W - cw)
    y0 = min(max(fy * H - ch / 2, 0), H - ch)
    im = Image.fromarray(fr).resize((W, H), Image.BILINEAR, box=(x0, y0, x0 + cw, y0 + ch))
    return np.asarray(im)


def make_vignette():
    yy, xx = np.mgrid[0:H, 0:W]
    r = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2)
    v = 1 - 0.38 * np.clip(r - 0.55, 0, 1) ** 1.6
    return v[..., None].astype(np.float32)


def render(audio_path):
    vig = make_vignette()
    rng = np.random.default_rng(3)
    grain_bank = [rng.normal(0, 3.5, (H // 2, W // 2, 1)).astype(np.float32) for _ in range(6)]
    bar = 56  # letterbox (about 2.0:1)
    enc = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-i", audio_path, "-c:v", "libx264", "-preset", "slow",
         "-crf", "11", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "320k", "-shortest", "-movflags", "+faststart",
         TMP], stdin=subprocess.PIPE)
    edl = sorted(EDL, key=lambda e: e[0])
    total = int(END * FPS)
    active, ai = None, -1
    text_cache = {}
    for fi in range(total):
        t = fi / FPS
        # which segment?
        seg = None
        for i, e in enumerate(edl):
            if e[0] <= t < e[0] + e[3]:
                seg = i
        if seg != ai:
            if active:
                active.close()
            active = Clip(edl[seg][1], edl[seg][2], edl[seg][3]) if seg is not None else None
            ai = seg
        if active:
            st, name, cin, dur, o = edl[seg]
            lt = t - st
            fr = active.read()
            z0, z1 = o.get("zoom", (1.0, 1.0))
            s = z0 + (z1 - z0) * (lt / dur)
            if o.get("punch"):
                s *= 1 + 0.05 * max(0, 1 - lt / 0.25) ** 2
            fx, fy = o.get("focus", (0.5, 0.5))
            fr = zoom_frame(fr, s, fx, fy).astype(np.float32)
            if o.get("fadein"):
                fr *= min(1, lt / o["fadein"])
            # grade: a touch more contrast, warm highlights / cool shadows
            fr = (fr - 128) * 1.08 + 128
            lum = fr.mean(axis=2, keepdims=True) / 255
            fr += (lum - 0.5) * np.array([10, 2, -10], np.float32)
            fr *= vig
            g = grain_bank[fi % 6]
            fr += np.repeat(np.repeat(g, 2, axis=0), 2, axis=1)
            if o.get("flash") and lt < 0.12:
                fr = fr + (255 - fr) * (1 - lt / 0.12) * 0.85
        else:
            fr = np.zeros((H, W, 3), np.float32)
        # hit flashes on black too (title / end cards)
        for h in HITS:
            if 0 <= t - h < 0.1:
                fr = fr + (255 - fr) * (1 - (t - h) / 0.1) * 0.9
        fr = np.clip(fr, 0, 255).astype(np.uint8)
        fr[:bar] = 0
        fr[H - bar:] = 0
        img = None
        for (a, b, kind, lines) in TEXT:
            if a <= t < b:
                if img is None:
                    img = Image.fromarray(fr).convert("RGBA")
                img.alpha_composite(text_layer(kind, lines, t - a, b - a))
        if img is not None:
            fr = np.asarray(img.convert("RGB"))
        enc.stdin.write(fr.tobytes())
        if fi % 150 == 0:
            print(f"  frame {fi}/{total}", flush=True)
    if active:
        active.close()
    enc.stdin.close()
    enc.wait()
    os.replace(TMP, OUT)


def song_audio():
    out = os.path.join(HERE, "music", "song_cut.wav")
    ms = int(SONG_OFFSET * 1000)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", SONG, "-af",
                    f"adelay={ms}|{ms},atrim=0:{END:.3f},afade=t=out:st={END - 4.5:.3f}:d=4.5", "-ar", "48000", out],
                   check=True)
    return out


if __name__ == "__main__":
    if "--song" in sys.argv:
        print("song...")
        render(song_audio())
        print("wrote", OUT)
        sys.exit(0)
    wav = os.path.join(HERE, "score.wav")
    if "--video-only" not in sys.argv:
        print("score...")
        write_wav(wav, synth())
    if "--audio-only" not in sys.argv:
        print("video...")
        render(wav)
        print("wrote", OUT)
