# Makes female versions of outfit meshes without the editor: cooked skeletal meshes are copied out of the game's pak, every
# LOD's bind-pose vertices are reshaped in place (same topology, weights, UVs and materials, so animations and textures
# keep working) and the copy is saved beside the original under Meshes/<FEMALE_DIR>/.
#   make_female.py (reads assets/female/list.txt: pak paths without extension)   writes assets/female/pak/, installed as loose files by scripts/mode.ps1
import math
import os
import re
import shutil
import struct
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
GAME_PAK = os.path.join(GAME, r'RaidGame/Content/Paks/pakchunk0-WindowsNoEditor.pak')
REPAK = ROOT + '/tools/repak/repak.exe'
KEY = '0x' + open(ROOT + '/backup/keys/pak.key').read().strip()
# Same length as the original folder names: the names in a cooked package can be swapped without moving anything.
FOLDERS = {'Meshes/Bodies/': 'Meshes/BodieF/', 'Meshes/Heads/': 'Meshes/HeadF/', 'Meshes/Accessories/': 'Meshes/AccessorieF/',
           'MainPlayer/Meshes/': 'MainPlayer/MesheF/'}


def smooth(points, t):
    """Piecewise smoothstep through (t, value) points."""
    if t <= points[0][0]: return points[0][1]
    for (a, va), (b, vb) in zip(points, points[1:]):
        if t <= b:
            u = (t - a) / (b - a)
            u = u * u * (3 - 2 * u)
            return va + (vb - va) * u
    return points[-1][1]


# Proportions: ANSUR II (US Army, 2012) median women against men, taken at equal height because the skeleton keeps the
# male height: bideltoid 0.95, chest 1.0, hip 1.11, thigh 1.06, calf 1.03, neck 0.90, biceps and forearm 0.92, wrist 0.95.
# Waist, bust and hips were then set by eye with the user.
# Height (z) -> scale of the torso and legs across (x) and front to back (y).
WIDTH = [(60, 1.05), (72, 1.1), (86, 1.125), (97, 0.99), (108, 0.93), (120, 0.94), (135, 0.93), (150, 0.82), (158, 0.9), (166, 0.96)]
DEPTH = [(0, 1), (60, 1.05), (86, 1.06), (100, 0.95), (108, 0.905), (122, 0.93), (150, 0.92), (158, 0.92), (166, 0.97)]
# Each leg thickens around its own centre: scaling across the body would only stand the legs further apart.
THIGH = [(0, 1), (14, 1.0), (32, 1.03), (42, 1.05), (60, 1.1)]
# The arm in the bind pose: where its centreline runs (x -> z, y, measured on the SAS body), and how much it slims around that
# line from shoulder to hand. Slightly under the data's 0.92 at the top: a sleeve hides less of a slim arm than of a broad one.
ARM_Z = [(28, 135), (34, 129), (40, 123.5), (46, 119), (52, 114.5), (58, 108), (64, 100.8), (70, 96.7)]
ARM_Y = [(28, -9.6), (34, -9.8), (40, -9), (46, -6.7), (52, -3.5), (58, 2.4), (64, 4.1), (70, 4)]
ARM_SLIM = [(25, 1.0), (31, 0.88), (42, 0.89), (52, 0.91), (58, 0.94), (64, 0.97), (72, 0.97)]
LEG_X = 10.5
TORSO = 27.0        # half width of the body: past this, above the hips, it's an arm
ARM_FROM, ARM_TO = 21.0, 33.0
# Hands keep the man's shape exactly: the skeleton isn't changed, so any move of a hand vertex puts it off its finger bones
# (fingers look longer and miss the weapon grips). The reshape fades out along the forearm and is gone at the wrist: the
# hand mesh starts at |x| 52 in the bind pose (every body). They hang down to z 93; nothing else reaches past |x| 30 there.
WRIST = [(36.0, 1.0), (52.0, 0.0)]  # long enough that the arm's 2.2 sideways shift doesn't pinch the forearm
BUST_Z, BUST_X, BUST_Y = 133.0, 10.5, 7.5  # height, distance from centre, how far it comes forward
BUST_SX, BUST_SZ = 10.0, 10.0
SEAT_Z, SEAT_Y = 84.0, 4.5


def smooth_line(points, t):
    """Straight lines between (t, value) points."""
    if t <= points[0][0]: return points[0][1]
    for (a, va), (b, vb) in zip(points, points[1:]):
        if t <= b: return va + (vb - va) * (t - a) / (b - a)
    return points[-1][1]


def female(x, y, z):
    k = smooth(WRIST, abs(x))
    if k <= 0: return x, y, z
    nx, ny, nz = body(x, y, z)
    return x + (nx - x) * k, y + (ny - y) * k, z + (nz - z) * k


def body(x, y, z):
    wide, deep = smooth(WIDTH, z), smooth(DEPTH, z)
    ax = abs(x)
    if z < 60:
        c = math.copysign(LEG_X, x)
        thick = smooth(THIGH, z)
        nx, ny = c + (x - c) * thick, y * (1 + (thick - 1) * 0.8)
        if y < 0:
            ny -= SEAT_Y * 0.5 * math.exp(-((z - 60) / 12) ** 2) * min(1, -y / 6)
        return nx, ny, z
    nx, ny = x * wide, y * deep
    if z > 100 and ax > ARM_FROM:
        # An arm: it moves in with the shoulder and keeps its shape, blended into the torso around the armpit.
        shoulder = smooth(WIDTH, max(z, 138))
        arm = x + math.copysign(TORSO * (shoulder - 1), x)
        t = smooth([(ARM_FROM, 0), (ARM_TO, 1)], ax)
        slim = smooth(ARM_SLIM, ax)
        cz, cy = smooth_line(ARM_Z, ax), smooth_line(ARM_Y, ax)
        az, ay = cz + (z - cz) * slim, cy + (y - cy) * slim
        nx, ny = nx + (arm - nx) * t, ny + (ay - ny) * t
        z = z + (az - z) * t
        if t >= 1: return nx, ny, z
    if y > 0:
        for side in (-1, 1):
            g = math.exp(-((x - side * BUST_X) / BUST_SX) ** 2 - ((z - BUST_Z) / BUST_SZ) ** 2)
            ny += BUST_Y * g * min(1, y / 4 + 0.4)
    else:
        ny -= SEAT_Y * math.exp(-((z - SEAT_Z) / 9) ** 2) * min(1, -y / 6)
    return nx, ny, z


# Heads: narrower jaw and chin, slightly smaller skull. Head meshes sit around z 150-185 in the same space.
def female_head(x, y, z):
    jaw = smooth([(150, 0.92), (160, 0.93), (168, 0.90), (176, 0.95), (186, 0.97)], z)
    return x * jaw, y * (0.5 + 0.5 * jaw), z


# Bags: the straps follow the chest, the bag on the back keeps its shape and stays against the back.
def female_bag(x, y, z):
    if y < -16:
        nx, ny, nz = female(x, -16, z)
        return x, ny + y + 16, z
    return female(x, y, z)


# Soldiers' one-piece outfits have the head on: body below the neck, head above it.
def female_whole(x, y, z):
    return female_head(x, y, z) if z > 160 else female(x, y, z)


def get(path, ext):
    r = subprocess.run([REPAK, '--aes-key', KEY, 'get', GAME_PAK, path + ext], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def positions(d, at, n):
    """Whether n*3 floats at `at` look like vertex positions in centimetres. Skin weights can carry the same header: two
    vertices in a row held wholly by bone 12 read as 12, 255, 12, 255, and reshaping what followed zeroed bone indices, so
    those vertices followed the root and stretched to the floor once the character moved (Commando, Outlaw, Security and
    Space Pirate bodies). Packed bytes read as floats are subnormal, NaN or huge; real positions never are."""
    for v in struct.unpack_from('<%df' % (n * 3), d, at):
        a = abs(v)
        if not a < 2000 or (a and a < 1e-30): return False
    return True


def buffers(d):
    """FPositionVertexBuffer: stride 12, count, then bulk array: element size 12, count."""
    out, p = [], 0
    tag = struct.pack('<I', 12)
    while True:
        p = d.find(tag, p)
        if p < 0 or p + 16 > len(d): return out
        a, n, c, e = struct.unpack_from('<IIII', d, p)
        if c == 12 and n == e and 100 < n < 1000000 and p + 16 + n * 12 <= len(d) and positions(d, p + 16, n):
            out.append((p + 16, n))
            p += 16 + n * 12
        else:
            p += 1


def convert(path, tree):
    folder = next(f for f in FOLDERS if f in path)
    name = path.split('/')[-1]
    shape = (female_head if 'Heads' in folder else female_bag if re.search('Bag|Pack', name)
             else female_whole if folder == 'MainPlayer/Meshes/' else female)
    asset, exp = get(path, '.uasset'), get(path, '.uexp')
    if not asset or not exp:
        return 'missing'
    d = bytearray(exp)
    found = buffers(d)
    if not found:
        return 'no vertex buffers'
    for at, n in found:
        v = list(struct.unpack_from('<%df' % (n * 3), d, at))
        for i in range(0, n * 3, 3):
            v[i], v[i + 1], v[i + 2] = shape(v[i], v[i + 1], v[i + 2])
        struct.pack_into('<%df' % (n * 3), d, at, *v)
    # Only the package's own name: its imports (materials in Accessories/Mats, physics assets) stay where they are.
    rel = path.replace(folder, FOLDERS[folder], 1)
    old_name = ('/Game/' + path.split('Content/', 1)[1]).encode() + b'\0'
    new_name = ('/Game/' + rel.split('Content/', 1)[1]).encode() + b'\0'
    assert asset.count(old_name) >= 1 and len(old_name) == len(new_name), path
    a = asset.replace(old_name, new_name)
    out = os.path.join(tree, rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out + '.uasset', 'wb').write(a)
    open(out + '.uexp', 'wb').write(d)
    return 'ok %s' % [n for _, n in found]


def main():
    tree = ROOT + '/assets/female/pak'
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(tree)
    for path in open(ROOT + "/assets/female/list.txt").read().split():
        print(path.split('/')[-1], convert(path, tree))

    return



if __name__ == '__main__':
    main()
