# Draws the minimap's icons into assets/minimap (white shapes, tinted in game by minimap.lua).
# Run once with: python -I tools/make_minimap_art.py
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "minimap")
SIZE, AA = 64, 4  # drawn large, shrunk for smooth edges
os.makedirs(OUT, exist_ok=True)


def icon(name, draw):
    n = SIZE * AA
    img = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    draw(ImageDraw.Draw(img), n)
    img.resize((SIZE, SIZE), Image.LANCZOS).save(os.path.join(OUT, name + ".png"))


icon("dot", lambda d, n: d.ellipse((n * .1, n * .1, n * .9, n * .9), fill="white"))
icon("arrow", lambda d, n: d.polygon(
    [(n * .5, n * .04), (n * .88, n * .92), (n * .5, n * .72), (n * .12, n * .92)], fill="white"))
icon("target", lambda d, n: d.polygon(
    [(n * .5, n * .03), (n * .97, n * .5), (n * .5, n * .97), (n * .03, n * .5)], fill="white"))
icon("station", lambda d, n: d.ellipse(
    (n * .08, n * .08, n * .92, n * .92), outline="white", width=int(n * .14)))
icon("gate", lambda d, n: (
    d.ellipse((n * .04, n * .04, n * .96, n * .96), outline="white", width=int(n * .1)),
    d.ellipse((n * .33, n * .33, n * .67, n * .67), fill="white")))
icon("cross", lambda d, n: (  # a kill (#326)
    d.line((n * .15, n * .15, n * .85, n * .85), fill="white", width=int(n * .2)),
    d.line((n * .15, n * .85, n * .85, n * .15), fill="white", width=int(n * .2))))
icon("bag", lambda d, n: (  # a dropped item (#326)
    d.rounded_rectangle((n * .12, n * .3, n * .88, n * .92), radius=int(n * .12), fill="white"),
    d.arc((n * .3, n * .06, n * .7, n * .5), 180, 360, fill="white", width=int(n * .1))))
icon("lock", lambda d, n: (  # a locked door: key card, blowtorch or hack (#326)
    d.rounded_rectangle((n * .16, n * .44, n * .84, n * .94), radius=int(n * .08), fill="white"),
    d.arc((n * .28, n * .08, n * .72, n * .64), 180, 360, fill="white", width=int(n * .12)),
    d.line((n * .28, n * .36, n * .28, n * .48), fill="white", width=int(n * .12)),
    d.line((n * .72, n * .36, n * .72, n * .48), fill="white", width=int(n * .12))))
