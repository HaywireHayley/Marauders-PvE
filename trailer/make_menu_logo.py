"""Renders the splash screen logo: the trailer's end card title on a transparent background, loaded at runtime by
mods/PvEDirector/Scripts/splash.lua. python trailer/make_menu_logo.py  ->  assets/menu/logo.png
"""
import os

from PIL import Image, ImageDraw

from make_loading import ORANGE, ROOT, font, spaced

OUT = os.path.join(ROOT, "assets", "menu")
W, H = 1720, 360  # drawn big, shrunk to SIZE so it stays crisp without mipmaps
CROP = (265, 2, 1466, 282)  # the ink, so the widget places the logo itself, plus a gap above the buttons
SIZE = (600, 140)


def main():
    img = Image.new("RGBA", (W, H), ORANGE + (0,))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    spaced(ImageDraw.Draw(layer), (W / 2, 0), "MARAUDERS", font(170, "Bold"), (245, 245, 245, 255), 24, center=True)
    ghost = Image.new("RGBA", (W, H), ORANGE + (0,))
    ghost.putalpha(layer.split()[3].point(lambda v: v * 0.55))
    img.alpha_composite(ghost, (5, 0))
    img.alpha_composite(layer)
    d = ImageDraw.Draw(img)
    spaced(d, (W / 2, 212), "OFFLINE  PvE", font(50, "SemiBold Condensed"), ORANGE + (255,), 20, center=True)
    cy = 244
    d.line([(W / 2 - 300 - 230, cy), (W / 2 - 300, cy)], fill=ORANGE + (200,), width=3)
    d.line([(W / 2 + 300, cy), (W / 2 + 300 + 230, cy)], fill=ORANGE + (200,), width=3)
    os.makedirs(OUT, exist_ok=True)
    img.crop(CROP).resize(SIZE, Image.LANCZOS).save(os.path.join(OUT, "logo.png"))


if __name__ == "__main__":
    main()
