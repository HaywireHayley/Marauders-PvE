"""Builds the stand-in backend's seed data from pvenet captures.

    python -I capture_seed.py [capture.jsonl ...]     (default: every capture/winhttp-*.jsonl, oldest first)

Replays the Nakama traffic in order: storage reads (GET /v2/storage/<collection>, POST /v2/storage) load
objects, the client's own writes (PUT /v2/storage) and deletes (PUT /v2/storage/delete) are applied on top, so
the result is the account as the live backend last held it. The masterstartfunction RPC payload (profile:
playerstats, contracts, ship rotation, gifts, cosmetics) is kept as returned, and the last reply of every RPC
is kept as an example. Writes capture/seed/account.json (nothing secret: tokens and auth replies are left out)
and prints a summary.
"""
import glob
import json
import os
import sys
from urllib.parse import urlsplit

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CAP = os.path.join(ROOT, "capture")
# RPC replies that carry credentials (voice tokens etc.): kept out of the seed.
SECRET_RPCS = {"getbuildinfo"}


def requests(paths):
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    yield json.loads(line)


def main():
    paths = sys.argv[1:] or sorted(glob.glob(os.path.join(CAP, "winhttp-*.jsonl")))
    storage = {}   # (collection, key) -> object (value parsed when it is JSON)
    rpcs = {}      # name -> {"request": ..., "response": ...}
    account = None
    n = 0
    for r in requests(paths):
        if "nakamacloud" not in r["host"] or r["status"] != 200:
            continue
        n += 1
        url = urlsplit(r["path"])
        path = url.path

        def load(objs):
            for o in objs or []:
                try:
                    o["value"] = json.loads(o["value"])
                except (TypeError, ValueError):
                    pass
                storage[(o["collection"], o["key"])] = o

        if path.startswith("/v2/storage/delete"):
            for o in json.loads(r["reqBody"]).get("object_ids", []):
                storage.pop((o["collection"], o["key"]), None)
        elif path == "/v2/storage" and r["verb"] == "PUT":
            load(json.loads(r["reqBody"]).get("objects"))
        elif path.startswith("/v2/storage"):  # reads
            if r["respBody"]:
                load(json.loads(r["respBody"]).get("objects"))
        elif path.startswith("/v2/rpc/"):
            name = path.split("/")[-1]
            if name in SECRET_RPCS:
                continue
            body = json.loads(r["respBody"]) if r["respBody"] else {}
            payload = body.get("payload")
            try:
                payload = json.loads(payload)
            except (TypeError, ValueError):
                pass
            req = r["reqBody"]
            try:
                req = json.loads(json.loads(req)) if req else None
            except (TypeError, ValueError):
                pass
            rpcs[name] = {"verb": r["verb"], "request": req, "response": payload}
        elif path == "/v2/account" and r["respBody"]:
            account = json.loads(r["respBody"])

    collections = {}
    for (col, key), o in sorted(storage.items()):
        collections.setdefault(col, {})[key] = o["value"]

    os.makedirs(os.path.join(CAP, "seed"), exist_ok=True)
    out = os.path.join(CAP, "seed", "account.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"sources": [os.path.basename(p) for p in paths], "account": account,
                   "storage": collections, "rpcs": rpcs}, f, indent=1)

    print(f"{n} Nakama requests from {len(paths)} capture(s) -> {out}")
    for col, objs in collections.items():
        print(f"  storage {col}: {len(objs)}")
    print("  rpcs:", ", ".join(sorted(rpcs)))
    inv = collections.get("inventory", {})
    loadout = [v["value"] for v in inv.values() if isinstance(v, dict) and v.get("equip")]
    print("  equipped:", "; ".join(loadout))


if __name__ == "__main__":
    main()
