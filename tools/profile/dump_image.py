"""Dump the running game's image to a PE for offline analysis (Ghidra and friends).

Why: RaidGame-Win64-Shipping.exe is protected with a packer, so .xtext/.xcode are
encrypted on disk and only contain real code once the loader has decrypted them inside a
running process. This reads the image of a copy that is already running -- read-only, the
same ReadProcessMemory the other tools here use -- and writes a file whose sections hold
what the loader produced. ImageBase is patched to the runtime base so absolute pointers in
the dump point at the right addresses.

Nothing is unpacked or defeated: the game keeps running its own protection, and this only
records what that protection already decrypted.

    python tools/profile/dump_image.py D:/Tools/dumps/RaidGame-win64-mem.exe [--base 0x...]

The game must be running when this is called; `python tools/profile/dump_image.py --help`
for usage. Base comes from UE4SS.log via gbase, as for the other profile tools.

Then: Ghidra > Import, language x86:LE:64:default. The dump goes stale after a game
update, so re-dump rather than trusting an old file.
"""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    out_path = args[0]
    base = gbase.base()
    if "--base" in sys.argv:
        base = int(sys.argv[sys.argv.index("--base") + 1], 16)
    exe = os.path.join(GAME, r"RaidGame/Binaries/Win64/RaidGame-Win64-Shipping.exe")
    img = bytearray(open(exe, "rb").read())
    hdr = bytes(img[:0x1000])

    e_lfanew = struct.unpack_from("<I", hdr, 0x3C)[0]
    nsec = struct.unpack_from("<H", hdr, e_lfanew + 6)[0]
    opt_size = struct.unpack_from("<H", hdr, e_lfanew + 20)[0]
    opt_off = e_lfanew + 24
    if struct.unpack_from("<H", hdr, opt_off)[0] != 0x20B:
        print("not PE32+")
        return 1
    struct.pack_into("<Q", img, opt_off + 0x18, base)   # ImageBase -> runtime base
    print("image base patched to %#x" % base)

    for i in range(nsec):
        o = opt_off + opt_size + i * 40
        name = bytes(img[o:o + 8]).rstrip(b"\0").decode(errors="ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", img, o + 8)
        if rawsize == 0 or rawptr == 0:
            continue
        chunk = bytearray()
        span = min(rawsize, vsize or rawsize)
        for off in range(0, span, 0x100000):
            n = min(0x100000, span - off)
            try:
                chunk += m.read(base + vaddr + off, n)
            except OSError:
                chunk += b"\0" * n
        img[rawptr:rawptr + len(chunk)] = chunk
        print("  %-10s %8.2f MB from memory" % (name, len(chunk) / 1048576))

    os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)
    open(out_path, "wb").write(img)
    print("wrote %s (%.1f MB)" % (out_path, len(img) / 1048576))
    return 0


if __name__ == "__main__":
    sys.exit(main())
