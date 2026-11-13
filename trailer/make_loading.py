"""Renders the raid loading screen in the trailer's style: backdrop + title, and one caption per loading stage.
Same font, colours and layouts as make_trailer.py (Bahnschrift isn't in the game, so the text ships as images that
mods/PvEDirector/Scripts/loading.lua loads at runtime). python trailer/make_loading.py  ->  assets/loading/*.png
"""
import os
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "loading")
FONT = "C:/Windows/Fonts/bahnschrift.ttf"
FRAME_FROM = os.path.join(ROOT, "trailer", "marauders_offline_trailer_60fps_hq.mp4")
FRAME_AT = 26.0  # a clean ship shot over the nebula, no captions or HUD
W, H = 1920, 1080
ORANGE = (255, 138, 36)
CAP_W, CAP_H = 1100, 240  # one caption image

# Stage key, white line, orange line.
CAPTIONS = [
    ("world", "LOADING THE SECTOR", "STATIONS AND WRECKS"),
    ("match", "STARTING THE RAID", "CREWS FINDING THEIR SHIPS"),
    ("ship", "PREPARING YOUR SHIP", "ALMOST THERE"),
    ("ready", "YOU'RE ABOARD", "GOOD LUCK"),
]


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def spaced(draw, xy, text, fnt, fill, spacing, center=False):
    widths = [draw.textlength(ch, font=fnt) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x, y = xy
    if center:
        x -= total / 2
    for ch, w in zip(text, widths):
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += w + spacing
    return total


def backdrop():
    with tempfile.TemporaryDirectory() as tmp:
        frame = os.path.join(tmp, "f.png")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(FRAME_AT), "-i", FRAME_FROM,
                        "-frames:v", "1", "-vf", f"crop=iw*0.78:ih*0.78,scale={W}:{H}", frame], check=True)  # no letterbox
        img = Image.open(frame).convert("RGB")
    img = img.filter(ImageFilter.GaussianBlur(1.2))
    arr = np.asarray(img).astype(np.float32) / 255
    # Dark enough for the title to read, darker toward the edges and the top where the title sits.
    yy, xx = np.mgrid[0:H, 0:W]
    vig = np.clip(1.15 - np.sqrt(((xx - W / 2) / (W * 0.62)) ** 2 + ((yy - H * 0.62) / (H * 0.62)) ** 2), 0.1, 1)
    top = np.clip((yy / H - 0.05) / 0.6, 0.18, 1)
    arr = arr * 0.55 * (vig * top)[..., None]
    return Image.fromarray((arr * 255).astype(np.uint8), "RGB").convert("RGBA")


def title(img):
    """The trailer's end card: tracked title with an orange ghost edge, subtitle between rules."""
    y0 = 250
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    spaced(ImageDraw.Draw(layer), (W / 2, y0), "MARAUDERS", font(170, "Bold"), (245, 245, 245, 255), 24, center=True)
    ghost = Image.new("RGBA", (W, H), ORANGE + (0,))
    ghost.putalpha(layer.split()[3].point(lambda v: v * 0.55))
    img.alpha_composite(ghost, (5, 0))
    img.alpha_composite(layer)
    d = ImageDraw.Draw(img)
    spaced(d, (W / 2, y0 + 212), "OFFLINE  PvE", font(50, "SemiBold Condensed"), ORANGE + (255,), 20, center=True)
    cy = y0 + 244
    d.line([(W / 2 - 300 - 230, cy), (W / 2 - 300, cy)], fill=ORANGE + (200,), width=3)
    d.line([(W / 2 + 300, cy), (W / 2 + 300 + 230, cy)], fill=ORANGE + (200,), width=3)


def caption(white, orange):
    """The trailer's lower-left caption: orange bar, white bold line, orange line, soft shadow."""
    img = Image.new("RGBA", (CAP_W, CAP_H), (0, 0, 0, 0))
    x0, y0 = 60, 30
    f1, f2 = font(78, "Bold Condensed"), font(52, "SemiBold Condensed")
    shadow = Image.new("RGBA", (CAP_W, CAP_H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    spaced(sd, (x0 + 3, y0 + 3), white, f1, (0, 0, 0, 200), 6)
    spaced(sd, (x0 + 3, y0 + 95), orange, f2, (0, 0, 0, 200), 6)
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(4)))
    d = ImageDraw.Draw(img)
    d.rectangle([x0 - 28, y0 + 8, x0 - 18, y0 + 158], fill=ORANGE + (255,))
    spaced(d, (x0, y0), white, f1, (245, 245, 245, 255), 6)
    spaced(d, (x0, y0 + 92), orange, f2, ORANGE + (255,), 6)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    bg = backdrop()
    title(bg)
    bg.convert("RGB").save(os.path.join(OUT, "backdrop.png"))
    for i, (key, white, orange) in enumerate(CAPTIONS):
        cap = caption(white, orange)
        cap.save(os.path.join(OUT, "cap_" + key + ".png"))
        if i == 0:
            # What the game's own loading screen shows while the map travels: the first caption and an empty bar, where
            # loading.lua draws them, so the live screen takes over without a jump.
            travel = bg.copy()
            travel.alpha_composite(cap, (120, 750))
            overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(overlay).rectangle([152, 970, 152 + 640, 973], fill=(255, 255, 255, 38))
            travel.alpha_composite(overlay)
            travel.convert("RGB").save(os.path.join(OUT, "travel.png"))


if __name__ == "__main__":
    main()
