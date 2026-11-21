"""Sets the game's window mode and resolution in its own video save (issue #292).

The game keeps its video settings in %LOCALAPPDATA%/RaidGame/Saved/SaveGames/VideoSettings.sav (SG_VideoSettings_C:
ScreenResolution, EWindowMode, ...) and applies them at start-up over GameUserSettings.ini. The launcher used to force
a window with -windowed -ResX -ResY instead, but the engine re-applies command-line overrides every time settings are
applied, so whatever the player picked in the game's Settings snapped back to that small window on the next map load.

    python -I videosettings.py <windowed|borderless|fullscreen> <width> <height> [save path]

Prints what it did. Exit 0 when it's set, 3 when there's no save yet (the game writes one on its first run), 1 on a
save it can't read, which it leaves untouched.
"""
import os
import struct
import sys

MODES = {"fullscreen": "EWindowMode::Fullscreen", "borderless": "EWindowMode::WindowedFullscreen",
         "windowed": "EWindowMode::Windowed"}
CLASS = b"SG_VideoSettings_C\x00"


def default_path():
    return os.path.join(os.environ.get("LOCALAPPDATA", ""), "RaidGame", "Saved", "SaveGames", "VideoSettings.sav")


def fstring(s):
    b = s.encode("ascii") + b"\x00"
    return struct.pack("<i", len(b)) + b


def read_fstring(d, i):
    (n,) = struct.unpack_from("<i", d, i)
    if n <= 0 or n > 1024:  # (UTF-16 or junk: not a save this knows)
        raise ValueError(f"unexpected string length {n} at {i}")
    return d[i + 4:i + 4 + n - 1].decode("ascii"), i + 4 + n


def patch(data, mode, width, height):
    """Returns the save with the window mode and resolution set; raises ValueError on a layout it doesn't know."""
    at = data.find(CLASS)
    if at < 0:
        raise ValueError("not an SG_VideoSettings save")
    i = at + len(CLASS)
    out = bytearray(data[:i])
    seen = set()
    while True:
        name, j = read_fstring(data, i)
        if name == "None":
            out += data[i:]
            break
        ptype, j = read_fstring(data, j)
        (size,) = struct.unpack_from("<q", data, j)
        j += 8
        head_start = j
        if ptype == "StructProperty":
            _, j = read_fstring(data, j)
            j += 16 + 1  # struct guid, property guid flag
        elif ptype == "ByteProperty":
            _, j = read_fstring(data, j)
            j += 1
        else:
            j += 1
        head = data[head_start:j]
        value = data[j:j + size]
        if name == "ScreenResolution" and size == 8:
            value = struct.pack("<ii", width, height)
            seen.add(name)
        elif name == "EWindowMode" and ptype == "ByteProperty":
            value = fstring(MODES[mode])
            seen.add(name)
        out += fstring(name) + fstring(ptype) + struct.pack("<q", len(value)) + head + value
        i = j + size
    if seen != {"ScreenResolution", "EWindowMode"}:
        raise ValueError(f"missing {sorted({'ScreenResolution', 'EWindowMode'} - seen)}")
    return bytes(out)


def main(argv):
    if len(argv) < 3 or argv[0] not in MODES:
        print("usage: videosettings.py <windowed|borderless|fullscreen> <width> <height> [save path]")
        return 2
    mode, width, height = argv[0], int(argv[1]), int(argv[2])
    path = argv[3] if len(argv) > 3 else default_path()
    if not os.path.exists(path):
        print(f"Window: no video save yet, the game's default this time ({mode} from the next launch)")
        return 3
    with open(path, "rb") as f:
        data = f.read()
    try:
        new = patch(data, mode, width, height)
    except (ValueError, struct.error) as e:
        print(f"Window: left the video save alone ({e})")
        return 1
    if new != data:
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(new)
        os.replace(tmp, path)
    print(f"Window: {mode} {width}x{height}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
