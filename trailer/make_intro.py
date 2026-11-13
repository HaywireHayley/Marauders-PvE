"""Re-cuts the game's startup video (Content/Movies/LoadingScreen.mp4): the logo moment lands on the first big hit of a song,
and the key art's logo becomes the trailer's MARAUDERS / OFFLINE PvE. The cinematic before and the studio logos after stay.
python trailer/make_intro.py [--still]  ->  assets/intro/LoadingScreen.mp4 (or a preview frame in the scratch path given)
The song is yours and stays on this machine: the result is for this install, not for sharing.
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_loading import ORANGE, font, spaced  # the trailer's type

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "backup", "LoadingScreen.mp4.original")
SONG = "E:/Downloads/What I ve Done Official Music Video 4K Upgrade Linkin Park.mp3"
OUT = os.path.join(ROOT, "assets", "intro", "LoadingScreen.mp4")
W, H, FPS = 1920, 1080, 30
SR = 48000

SONG_HIT = 25.27    # the band comes in
# The song plays from the video's first frame. Its band arrives 16 s before the logo could, and the dialogue runs nearly all
# the way there, so no footage goes: an 8 s piano phrase plays three times instead of once. The block is the sample-accurate
# picked by what the join sounds like: the sound changes no more across it than the piano does anyway, 10 ms off the beat.
LOOP_START = 9.640  # seconds into the song
LOOP_BLOCK = 7.99
LOOP_EXTRA = 2      # extra passes
LOOP_XFADE = 0.35   # equal-power join
HIT = SONG_HIT + LOOP_BLOCK * LOOP_EXTRA  # the logo lands on the band, in the near-silent gap in the source's sound
ART_START = 41.1    # the source is black from here until its key art would fade in
ART_END = 48.3      # the source is black again here, before the studio logos
ART_FADE = 0.5      # fade to black before ART_END
END = 60.4
# The video's own sound (dialogue, effects) is mixed very low, peaking at -21.6 dB all the way through: it's raised to meet
# the song, with room to spare (peaks at -5.6 dB, nothing limited). Otherwise it's left as it is: only the song moves, around it.
SOURCE_GAIN_DB = 16
MUSIC_UNDER_SPEECH = 0.79  # -2 dB: through the cinematic, ~11 dB under the raised dialogue
MUSIC_LOGO = 0.7          # -3 dB: loud for as long as the logo is up
LOGO_OUT = (ART_END - 0.4, ART_END + 0.4)  # down to the studio level as the logo leaves
MUSIC_END = 0.28          # -11 dB: over the studio logos
SONG_FADE = 2.5     # the song fades out over the end of the video


def music_gain():
    """The song's level over time, as an ffmpeg expression."""
    a, b = LOGO_OUT
    return (f"if(lt(t,{HIT - 0.1}),{MUSIC_UNDER_SPEECH},if(lt(t,{a}),{MUSIC_LOGO},"
            f"if(lt(t,{b}),{MUSIC_LOGO}+({MUSIC_END}-{MUSIC_LOGO})*(t-{a})/{b - a},{MUSIC_END})))")


def extended_song(path):
    """The song with its piano phrase repeated, written as raw 48 kHz stereo floats."""
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", SONG, "-ac", "2", "-ar", str(SR),
                          "-f", "f32le", "-"], check=True, capture_output=True).stdout
    x = np.frombuffer(raw, np.float32).reshape(-1, 2)
    start, block, half = round(LOOP_START * SR), round(LOOP_BLOCK * SR), round(LOOP_XFADE * SR / 2)
    t = np.linspace(0, np.pi / 2, half * 2)[:, None]
    fade_out, fade_in = np.cos(t), np.sin(t)
    parts = [x[:start + block - half]]  # up to the join
    for i in range(LOOP_EXTRA):
        parts.append(x[start + block - half:start + block + half] * fade_out + x[start - half:start + half] * fade_in)
        parts.append(x[start + half:start + block - half] if i < LOOP_EXTRA - 1 else x[start + half:])
    np.concatenate(parts).astype(np.float32).tofile(path)


def ease_out(x):
    x = min(1, max(0, x))
    return 1 - (1 - x) ** 3


def plate():
    """The key art, large, with its baked-in logo buried under a gradient."""
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", "45", "-i", SOURCE, "-frames:v", "1",
                          "-vf", f"scale={W}:{H}:flags=lanczos", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         check=True, capture_output=True).stdout
    arr = np.frombuffer(raw, np.uint8).reshape(H, W, 3).astype(np.float32) / 255
    y = np.arange(H)[:, None, None] / H
    shade = 1 - np.clip((y - 0.60) / 0.17, 0, 1) ** 0.8  # true black from where the old logo starts
    return Image.fromarray((arr * shade * 255).astype(np.uint8), "RGB")


def title_layers():
    """The logo pieces on transparent layers: ghost + title, then subtitle + rules."""
    y0 = 800
    title = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    spaced(ImageDraw.Draw(title), (W / 2, y0), "MARAUDERS", font(150, "Bold"), (245, 245, 245, 255), 22, center=True)
    ghost = Image.new("RGBA", (W, H), ORANGE + (0,))
    ghost.putalpha(title.split()[3].point(lambda v: v * 0.55))
    main = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    main.alpha_composite(ghost, (5, 0))
    main.alpha_composite(title)
    sub = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(sub)
    spaced(d, (W / 2, y0 + 185), "OFFLINE  PvE", font(46, "SemiBold Condensed"), ORANGE + (255,), 18, center=True)
    cy = y0 + 214
    d.line([(W / 2 - 270 - 210, cy), (W / 2 - 270, cy)], fill=ORANGE + (200,), width=3)
    d.line([(W / 2 + 270, cy), (W / 2 + 270 + 210, cy)], fill=ORANGE + (200,), width=3)
    return main, sub


def art_frame(base, main, sub, t):
    """One frame at t seconds after the hit."""
    if t < 0:
        return np.zeros((H, W, 3), np.uint8)
    # a slow push in, as the trailer's title shots do
    s = 1.0 + 0.035 * ease_out(t / 6)
    sw, sh = int(W / s), int(H / s)
    x0, y0 = (W - sw) // 2, (H - sh) // 3
    img = base.crop((x0, y0, x0 + sw, y0 + sh)).resize((W, H), Image.BILINEAR).convert("RGBA")
    layer = main.copy()
    if t < 0.25:  # glitch-in: horizontal slices knocked sideways
        a = np.array(layer)
        rng = np.random.default_rng(int(t * 1000))
        for _ in range(9):
            yy = rng.integers(790, 980)
            hh = rng.integers(6, 30)
            a[yy:yy + hh] = np.roll(a[yy:yy + hh], rng.integers(-70, 70), axis=1)
        layer = Image.fromarray(a)
    img.alpha_composite(layer)
    sa = ease_out((t - 0.45) / 0.5)
    if sa > 0:
        s2 = sub.copy()
        s2.putalpha(s2.split()[3].point(lambda v: int(v * sa)))
        img.alpha_composite(s2)
    arr = np.asarray(img.convert("RGB")).astype(np.float32)
    flash = max(0.0, 1 - t / 0.28) ** 2  # the trailer's white hit flash
    arr = arr + (255 - arr) * flash
    fade = 1 - max(0.0, min(1.0, (t - (ART_END - HIT - ART_FADE)) / ART_FADE))
    return (arr * fade).clip(0, 255).astype(np.uint8)


def render():
    base = plate()
    main, sub = title_layers()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    song = OUT + ".song.raw"
    extended_song(song)
    fc = (f"[0:v]scale={W}:{H}:flags=lanczos,fps={FPS},format=yuv420p,split=2[a][c];"
          f"[a]trim=0:{ART_START},setpts=PTS-STARTPTS[a1];"
          f"[1:v]format=yuv420p,setpts=PTS-STARTPTS[b];"
          f"[c]trim={ART_END}:{END},setpts=PTS-STARTPTS[c1];"
          f"[a1][b][c1]concat=n=3:v=1:a=0[v];"
          f"[2:a]volume='{music_gain()}':eval=frame,afade=t=out:st={END - SONG_FADE}:d={SONG_FADE}[song];"
          f"[0:a]volume={SOURCE_GAIN_DB}dB[source];[source][song]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95,atrim=0:{END}[aout]")
    ff = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", SOURCE,
                           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                           "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", song, "-filter_complex", fc, "-map", "[v]", "-map", "[aout]",
                           "-c:v", "libx264", "-profile:v", "main", "-preset", "medium", "-crf", "18",
                           "-pix_fmt", "yuv420p", "-r", str(FPS), "-c:a", "aac", "-b:a", "256k", "-ar", "48000",
                           "-movflags", "+faststart", OUT], stdin=subprocess.PIPE)
    frames = int(round((ART_END - ART_START) * FPS))
    for i in range(frames):
        t = ART_START + i / FPS - HIT
        ff.stdin.write(art_frame(base, main, sub, t).tobytes())
    ff.stdin.close()
    if ff.wait() != 0:
        raise SystemExit("ffmpeg failed")
    os.remove(song)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--still":
        base = plate()
        main, sub = title_layers()
        Image.fromarray(art_frame(base, main, sub, float(sys.argv[3]) if len(sys.argv) > 3 else 2.0)).save(sys.argv[2])
    else:
        render()
