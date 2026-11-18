"""Turns the armour test's result file into the tables of docs/internals/DAMAGE_REFERENCE.md, and checks them against botdamage.lua:
python tools/armour_test/summarise.py <armour_test.txt> [--lua mods/PvEDirector/Scripts/botdamage.lua]

The test (tools/armour_test/README.md) writes bridge/armour_test.txt in the install folder. This reads its SUMMARY block, works
out each rating (vest: base minus the torso damage; helmet: base minus the head damage divided by the head multiplier) and prints
a vest table and a helmet table in markdown. With --lua it also lists every mesh whose measured rating differs from the VESTS and
HELMETS tables of botdamage.lua, and every mesh one table has and the other lacks, so a game update that changes a rating shows up."""
import re
import sys

HEAD_MULT = 3.5


def parse(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    if "SUMMARY" not in text:
        sys.exit("no SUMMARY in %s: the run did not finish (it writes the summary at the very end)" % path)
    summ = text[text.index("SUMMARY"):]
    m = re.search(r"base damage on a bare torso ([\d.]+)", summ)
    base = float(m.group(1)) if m else 34.0
    vests, helms = [], []
    for line in summ.splitlines():
        m = re.match(r"^\s*([\d.]+|unknown) \| (chest|helmet) \| (\S+) \| ([\d.]+) \| ([\d.]+) \| ([\d.]+) \| (\S+)\s*$", line)
        if not m:
            continue
        _, slot, row, main, arm, leg, mesh = m.groups()
        main, arm, leg = float(main), float(arm), float(leg)
        rating = base - main if slot == "chest" else base - main / HEAD_MULT
        rec = {"row": row, "mesh": mesh, "rating": round(rating), "exact": abs(rating - round(rating)) < 0.01,
               "main": main, "arm": arm, "leg": leg}
        (vests if slot == "chest" else helms).append(rec)
    return base, vests, helms


def table(rows, zone):
    out = ["| Item row | Mesh the bot wears | Rating | STG44 %s hit | STG44 arm hit | STG44 leg hit |" % zone, "| --- | --- | --- | --- | --- | --- |"]
    for r in sorted(rows, key=lambda r: (-r["rating"], r["row"])):
        flag = "" if r["exact"] else " (not a whole number: check this piece)"
        out.append("| %s | %s | %d%s | %g | %g | %g |" % (r["row"], r["mesh"], r["rating"], flag, r["main"], r["arm"], r["leg"]))
    return "\n".join(out)


def lua_table(src, name):
    m = re.search(r"local %s = \{(.*?)\n\}" % name, src, re.S)
    return {k: int(v) for k, v in re.findall(r"^\s*(\w+) = (\d+),", m.group(1), re.M)} if m else {}


def main():
    args = sys.argv[1:]
    lua = None
    if "--lua" in args:
        i = args.index("--lua")
        lua = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    base, vests, helms = parse(args[0])
    print("Base damage on a bare torso: %g. %d vests, %d helmets.\n" % (base, len(vests), len(helms)))
    print("### Vests\n\n" + table(vests, "torso") + "\n")
    print("### Helmets\n\n" + table(helms, "head") + "\n")
    if lua:
        src = open(lua, encoding="utf-8").read()
        bad = 0
        for name, rows in (("VESTS", vests), ("HELMETS", helms)):
            code = lua_table(src, name)
            seen = {r["mesh"]: r["rating"] for r in rows}
            for mesh, rating in sorted(seen.items()):
                if mesh not in code:
                    print("%s: measured but not in botdamage.lua: %s = %d" % (name, mesh, rating)); bad += 1
                elif code[mesh] != rating:
                    print("%s: %s is %d in botdamage.lua, measured %d" % (name, mesh, code[mesh], rating)); bad += 1
            for mesh in sorted(set(code) - set(seen)):
                print("%s: in botdamage.lua but not measured: %s" % (name, mesh)); bad += 1
        print("botdamage.lua matches the measurement." if not bad else "%d difference(s)." % bad)
        sys.exit(1 if bad else 0)


main()
