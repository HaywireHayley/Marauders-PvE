"""Decompiles the Blueprint functions a space test log named, with tools/offline-audit/kdis.py:

    python tools/space_test/kdis_logged.py <install folder> explosions
    python tools/space_test/kdis_logged.py <install folder> salvage

explowatch.lua (bridge/explosions.txt) and salvagewatch.lua (bridge/salvage.txt) write a PARAMS line for each Blueprint function of
the classes they watch, with the function's address in the running game:

    PARAMS SubNodeActorTurret_C::OnDeathEvent() @23da3f822a0

kdis.py reads the bytecode from the game's memory at those addresses, so run this on Windows while the SAME game session is still
open (the addresses die with the game). The result goes to bridge/kdis_explosions.txt or bridge/kdis_salvage.txt in the install
folder, one function after another, each under a "===== class::function @address =====" line. Nothing else is written.

For one function you know the address of, run kdis.py directly: python tools/offline-audit/kdis.py <hex address> [from] [to].
To get an address without a log, from the probe runner: lua return string.format('%x', StaticFindObject('<function path>'):GetAddress())
(see the offline-audit README).
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KDIS = os.path.join(os.path.dirname(HERE), "offline-audit", "kdis.py")

# Which classes and function names are worth reading for each log. The event graph's ExecuteUbergraph function holds the real code
# of a Blueprint, so it is always included.
MODES = {
    "explosions": {
        "classes": re.compile(r"(NodeTurret|NodeMine|Exploder|MineStaticActor|SubNodeActor|Radar)", re.I),
        "funcs": re.compile(r"(Health|Death|Explo|Triggered|Effect|Dying|Destroy|TakeAnyDamage|RadialDamage|ReceiveAnyDamage|MultiExpo|Ubergraph)", re.I),
    },
    "salvage": {
        "classes": re.compile(r"(Salvage|FrigateInside|Frigate|SpaceshipInside|Insides)", re.I),
        "funcs": re.compile(r"(Salvage|Dock|Purge|Unload|Loot|Ubergraph)", re.I),
    },
}


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in MODES:
        sys.exit(__doc__)
    install, mode = os.path.abspath(sys.argv[1]), sys.argv[2]
    log = os.path.join(install, "bridge", "explosions.txt" if mode == "explosions" else "salvage.txt")
    if not os.path.exists(log):
        sys.exit(f"{log} not found: switch the log on in F9 and play first (see tools/space_test/README.md).")
    want = MODES[mode]
    seen, jobs = set(), []
    for line in open(log, encoding="utf-8", errors="replace"):
        m = re.match(r"PARAMS (\S+)::(\S+)\(.*\) @([0-9a-f]+)\s*$", line.strip())
        if m and m.group(3) not in seen and (want["classes"].search(m.group(1)) or want["funcs"].search(m.group(2))):
            seen.add(m.group(3))
            jobs.append(m.groups())
    if not jobs:
        sys.exit(f"No PARAMS lines for {mode} in {log}.")
    dest = os.path.join(install, "bridge", f"kdis_{mode}.txt")
    with open(dest, "w", encoding="utf-8") as out:
        for cls, fn, addr in jobs:
            out.write(f"\n===== {cls}::{fn} @{addr} =====\n")
            out.flush()
            r = subprocess.run([sys.executable, KDIS, addr], capture_output=True, text=True, timeout=120)
            out.write(r.stdout + (("\n!! " + r.stderr[-600:]) if r.returncode else ""))
            out.flush()
            print(cls, fn, "ok" if r.returncode == 0 else "failed")
    print(f"done: {len(jobs)} functions -> {dest}")


if __name__ == "__main__":
    main()
