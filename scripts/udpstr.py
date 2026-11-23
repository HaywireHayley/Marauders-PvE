"""Finds readable text in UE4 net packets captured by native/pveudp.dll (capture/udp-<pid>.log).

    python -I scripts/udpstr.py capture/udp-<pid>.log [minlen]

UE4 packets are bit streams (LSB first) and strings sit at any bit offset, so each packet is re-aligned at all 8 bit
shifts and printable ASCII runs of at least minlen (default 6) are printed with the packet's time, direction and port.
"""
import re
import sys

log, minlen = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 6
run = re.compile(rb'[\x20-\x7e]{%d,}' % minlen)
t0 = None
for line in open(log, encoding="ascii", errors="replace"):
    parts = line.split()
    if len(parts) < 5 or not parts[0].isdigit():
        continue
    t, d, port, length, data = int(parts[0]), parts[1], parts[2], parts[3], bytes.fromhex(parts[4])
    t0 = t if t0 is None else t0
    v = int.from_bytes(data, "little")
    found = set()
    for k in range(8):
        for m in run.finditer(((v >> k).to_bytes(len(data), "little"))):
            found.add(m.group().decode())
    head = f"{(t - t0) / 1000:7.2f}s {d} {port} {length}"
    print(head, " | ".join(sorted(found, key=len, reverse=True)[:6]) if found else "")
