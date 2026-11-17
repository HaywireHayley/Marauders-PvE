"""Fit Ahtu's illustrated station maps onto the minimap's floor plans.

The minimap draws a station's plan in its own frame: CELL (100) world units per pixel, top = +X, right = +Y, the frame
the scan wrote to assets/minimap/<key>.png. A scan made with bridge/plan_floors also wrote <key>.floors: every walkable
cell it found on every floor ("cx cy z"). This tool cuts each floor out of Ahtu's map (boxes below), finds where it
lies on the scanned footprint (mirror, rotation, scale, offset), and writes that floor resampled into the plan's frame
(SCALE px per cell) as assets/minimap/ahtu/<key>_<n>.png, plus <key>.ahtu: one line per floor, "<file> <z>", z being the
floor's typical height, for the minimap to pick the floor you're on.

    python tools/minimap/ahtu_align.py [key ...]     (default: every station with a .floors file and boxes below)

Maps illustrated by Ahtu (credited in the minimap while one is shown).
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage, signal

Image.MAX_IMAGE_PIXELS = None
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "..", "assets", "minimap")
AHTU = os.path.join(ASSETS, "ahtu")
SCALE = 4        # output pixels per plan cell
WORK = 2000      # the boxes below are in a 2000-wide copy of each image

# Station level key -> (Ahtu image, [(floor name, box x0, y0, x1, y1 in a 2000 x 1125 copy)])
STATIONS = {
    "Asteriod_Mine_Large_01": ("ahtu-mine.png", [("Main floor", 150, 200, 1270, 940), ("Lower floor", 1260, 280, 1700, 700)]),
    "Mini_Mine_01": ("ahtu-mineship.png", [("Level 3", 130, 350, 690, 720), ("Level 2", 690, 220, 1210, 700),
                                           ("Level 1", 1210, 330, 1780, 700)]),
    "Planet_Killer_01": ("ahtu-pk.png", [("Lower level", 30, 150, 830, 1080), ("Silo lower level", 800, 80, 1030, 470),
                                         ("Launcher mid-level", 840, 810, 1085, 1020), ("Upper level", 1095, 340, 1540, 970),
                                         ("Assembly upper level", 1630, 500, 1800, 770)]),
    "MoonBase_01": ("ahtu-tf.png", [("Terraformer", 250, 100, 1460, 1115)]),
    "Navy_Outpost_01": ("ahtu-navy.png", [("Level 1", 130, 240, 1040, 910), ("Level 2", 1060, 340, 1730, 790)]),
    "Penal_Colony_01": ("ahtu-penal.png", [("Levels 1 and 2", 170, 120, 1160, 1000), ("Level 3", 1260, 400, 1560, 870)]),
    "Spaceport_01": ("ahtu-sp.png", [("Level 1", 70, 100, 960, 930), ("Level 2", 990, 190, 1660, 1000)]),
    "Colony_Cruiser_01": ("ahtu-cc.png", [("Lower deck", 560, 290, 880, 840), ("Upper deck", 970, 280, 1445, 905)]),
    "MerchantShip_01": ("ahtu-merch.png", [("Level 1", 670, 210, 1420, 500), ("Level 2", 220, 540, 1520, 1010)]),
}


def floor_mask(rgb):
    """Floor pixels of an Ahtu map: the grey-blue floor and darker fixtures, brown rock; not the starfield or text."""
    a = rgb.astype(np.int32)
    s = a.sum(axis=2)
    spread = a.max(axis=2) - a.min(axis=2)
    m = (s >= 120) & (s <= 420) & (spread <= 45)
    m = ndimage.binary_opening(m, iterations=2)          # stars and thin text
    m = ndimage.binary_closing(m, iterations=3)          # wall lines and door gaps
    # Fill small holes only (fixtures, gaps): a ring of corridors (Navy Outpost level 2) encloses open space.
    holes = ndimage.binary_fill_holes(m) & ~m
    hl, hn = ndimage.label(holes)
    if hn:
        hs = ndimage.sum(holes, hl, range(1, hn + 1))
        small = np.zeros(hn + 1, bool)
        small[1:] = hs <= 60
        m = m | small[hl]
    lab, n = ndimage.label(m)
    if n:
        sizes = ndimage.sum(m, lab, range(1, n + 1))
        keep = np.zeros(n + 1, bool)
        keep[1:] = sizes >= max(200, sizes.max() * 0.01)
        m = keep[lab]
    return m


def read_floors(key):
    path = os.path.join(ASSETS, key + ".floors")
    with open(path) as f:
        rect = [float(v) for v in f.readline().split()[1:]]
        cells = np.loadtxt(f, ndmin=2)
    with open(os.path.join(ASSETS, key + ".txt")) as f:
        w, h = (int(float(v)) for v in f.read().split()[:2])
    return rect, w, h, cells


def transform_mask(m, flip, angle, s):
    """Source mask -> mirrored, rotated (degrees, counter-clockwise) and scaled by s (plan cells per source px)."""
    img = Image.fromarray((m * 255).astype(np.uint8))
    if flip:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    img = img.rotate(angle, resample=Image.BILINEAR, expand=True)
    w, h = max(1, round(img.width * s)), max(1, round(img.height * s))
    return np.asarray(img.resize((w, h), Image.BILINEAR)) > 127


def best_offset(target, mov):
    """Offset of mov over target maximising 2 * overlap - area (hits count, misses cost): (score, dy, dx)."""
    t = target.astype(np.float32) * 2 - 1    # +1 on scanned floor, -1 off it
    k = mov[::-1, ::-1].astype(np.float32)
    pad = (mov.shape[0], mov.shape[1])
    tp = np.pad(t, ((pad[0], pad[0]), (pad[1], pad[1])), constant_values=-1)
    c = signal.fftconvolve(tp, k, mode="valid")
    i = np.unravel_index(np.argmax(c), c.shape)
    return float(c[i]), i[0] - pad[0], i[1] - pad[1]


def fit(target, src):
    """Search mirror, rotation and scale: (score, flip, angle, s, dy, dx)."""
    area_t = target.sum()
    s0 = math.sqrt(area_t / max(1, src.sum()))           # the whole station's size: an upper bound for one floor
    best = None
    for flip in (False, True):
        for base in (0, 90, 180, 270):
            for s in s0 * np.geomspace(0.35, 1.15, 14):
                mov = transform_mask(src, flip, base, s)
                if mov.shape[0] > target.shape[0] * 2 or mov.shape[1] > target.shape[1] * 2:
                    continue
                sc, dy, dx = best_offset(target, mov)
                if best is None or sc > best[0]:
                    best = (sc, flip, base, s, dy, dx)
    # refine around the best: small rotations and scale steps
    sc, flip, base, s, dy, dx = best
    for angle in np.arange(base - 4, base + 4.01, 1.0):
        for ss in s * np.geomspace(0.93, 1.07, 9):
            mov = transform_mask(src, flip, angle, ss)
            sc2, dy2, dx2 = best_offset(target, mov)
            if sc2 > best[0]:
                best = (sc2, flip, angle, ss, dy2, dx2)
    return best


def render(full, box_full, flip, angle, s, dy, dx, work_scale, w, h):
    """The floor's full-resolution crop drawn into the plan frame (w x h cells, SCALE px each), RGBA, off-floor clear."""
    crop = full.crop(box_full)
    rgb = np.asarray(crop.convert("RGB"))
    mask = floor_mask(np.asarray(crop.resize((max(1, crop.width // 4), max(1, crop.height // 4)), Image.BILINEAR).convert("RGB")))
    mask_img = Image.fromarray((mask * 255).astype(np.uint8)).resize(crop.size, Image.BILINEAR)
    mask_img = mask_img.filter(ImageFilter.MaxFilter(9))
    # The low-resolution mask only: a little sky between rooms shows, but cutting dark pixels at full resolution also
    # took Ahtu's dark icons (bodies, some markers) off the map.
    rgba = Image.fromarray(np.dstack([rgb, np.asarray(mask_img)]), "RGBA")
    # Same steps as transform_mask, at full resolution: the fit's s is plan cells per work px.
    if flip:
        rgba = rgba.transpose(Image.FLIP_LEFT_RIGHT)
    rgba = rgba.rotate(angle, resample=Image.BICUBIC, expand=True)
    k = s * work_scale * SCALE                           # output px per full-res px (work px = full px * work_scale)
    rgba = rgba.resize((max(1, round(rgba.width * k)), max(1, round(rgba.height * k))), Image.LANCZOS)
    out = Image.new("RGBA", (w * SCALE, h * SCALE), (0, 0, 0, 0))
    out.paste(rgba, (int(round(dx * SCALE)), int(round(dy * SCALE))), rgba)
    return out


def floor_heights(cells, w, h, footprints, near=200):
    """Each floor's typical height. Floors are taken largest area under no other floor first; each gets the most common
    height of the scanned cells under it that no floor already placed explains (within `near` of its height, in its
    footprint). A floor lying over another's (Navy Outpost level 2) then gets its own height, not the one below."""
    cx, cy, cz = cells[:, 0].astype(int), cells[:, 1].astype(int), cells[:, 2]
    ok = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
    cx, cy, cz = cx[ok], cy[ok], cz[ok]
    count = sum(fp.astype(int) for fp in footprints)
    order = sorted(range(len(footprints)), key=lambda i: -(footprints[i] & (count == 1)).sum())
    zs = [float("nan")] * len(footprints)
    explained = np.zeros(len(cz), bool)
    for i in order:
        under = footprints[i][cy, cx] & ~explained
        if under.sum() < 10:
            under = footprints[i][cy, cx]
        if not under.any():
            continue
        z = cz[under]
        hist, edges = np.histogram(z, bins=max(1, int((z.max() - z.min()) // 50) + 1))
        j = int(np.argmax(hist))
        peak = (edges[j] + edges[j + 1]) / 2
        zs[i] = float(np.median(z[np.abs(z - peak) <= near]))
        explained |= footprints[i][cy, cx] & (np.abs(cz - zs[i]) <= near)
    return zs


def main(keys):
    for key in keys:
        if key not in STATIONS or not os.path.exists(os.path.join(ASSETS, key + ".floors")):
            print(f"{key}: no boxes or no .floors scan, skipped")
            continue
        image, boxes = STATIONS[key]
        rect, w, h, cells = read_floors(key)
        target = np.zeros((h, w), bool)
        cx, cy = cells[:, 0].astype(int), cells[:, 1].astype(int)
        ok = (cx >= 0) & (cx < w) & (cy >= 0) & (cy < h)
        target[cy[ok], cx[ok]] = True
        target = ndimage.binary_closing(target, iterations=1)
        full = Image.open(os.path.join(AHTU, image))
        work_scale = WORK / full.width
        work = np.asarray(full.convert("RGB").resize((WORK, round(full.height * work_scale)), Image.BILINEAR))
        lines, footprints, shown = [], [], []
        # One image, one drawing: every floor shares its mirror, rotation and scale. The largest floor is fitted
        # freely; the others only look for their place (a small floor alone fitted at twice the scale, mirrored).
        srcs = [floor_mask(work[y0:y1, x0:x1]) for _, x0, y0, x1, y1 in boxes]
        main_i = max(range(len(srcs)), key=lambda i: srcs[i].sum())
        _, flip0, angle0, s0, _, _ = fit(target, srcs[main_i])
        def footprint(src, dy, dx):
            fp = np.zeros((h, w), bool)
            ys, xs = np.nonzero(transform_mask(src, flip0, angle0, s0))
            ys, xs = ys + dy, xs + dx
            inside = (ys >= 0) & (ys < h) & (xs >= 0) & (xs < w)
            fp[ys[inside], xs[inside]] = True
            return fp

        # The main floor on the whole footprint; each smaller floor on the cells at heights the floors placed so far
        # don't explain (a small floor fits almost anywhere on the stacked footprint of every floor).
        placed = {}
        ccx, ccy, ccz = cx[ok], cy[ok], cells[ok, 2]
        explained = np.zeros(len(ccz), bool)
        for i in [main_i] + [i for i in range(len(srcs)) if i != main_i]:
            if i == main_i:
                tgt = target
            else:
                tgt = np.zeros((h, w), bool)
                tgt[ccy[~explained], ccx[~explained]] = True
                tgt = ndimage.binary_closing(tgt, iterations=1)
            _, dy, dx = best_offset(tgt, transform_mask(srcs[i], flip0, angle0, s0))
            fp = footprint(srcs[i], dy, dx)
            placed[i] = (dy, dx, fp)
            under = fp[ccy, ccx] & ~explained
            if under.any():
                z = ccz[under]
                hist, edges = np.histogram(z, bins=max(1, int((z.max() - z.min()) // 50) + 1))
                j = int(np.argmax(hist))
                zpk = (edges[j] + edges[j + 1]) / 2
                explained |= fp[ccy, ccx] & (np.abs(ccz - zpk) <= 250)
        for n, (name, x0, y0, x1, y1) in enumerate(boxes, 1):
            dy, dx, fp = placed[n - 1]
            flip, angle, s = flip0, angle0, s0
            precision = (fp & target).sum() / max(1, fp.sum())
            footprints.append(fp)
            box_full = tuple(round(v / work_scale) for v in (x0, y0, x1, y1))
            out = render(full, box_full, flip, angle, s, dy, dx, work_scale, w, h)
            fname = f"{key}_{n}.png"
            out.save(os.path.join(AHTU, fname), optimize=True)
            shown.append((fname, name))
            print(f"{key} {name}: flip={flip} angle={angle:.0f} scale={s:.3f} at ({dx},{dy}), on scanned floor {precision:.0%}")
        zs = floor_heights(cells, w, h, footprints)
        with open(os.path.join(AHTU, key + ".ahtu"), "w") as f:
            for (fname, name), z in zip(shown, zs):
                f.write(f"{fname} {z:.0f} {name}\n")
        print(f"{key}: floor heights " + ", ".join(f"{name} {z:.0f}" for (_, name), z in zip(shown, zs)))


if __name__ == "__main__":
    main(sys.argv[1:] or sorted(STATIONS))
