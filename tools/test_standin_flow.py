# A fresh save's login and stash round trip against the stand-in, from the shipped seed.json (issue #80), and the save
# format's schema migration. Needs no game and touches no save: the stand-in's files go to a temporary folder. CI runs it.
import importlib.util
import json
import os
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("standin", os.path.join(HERE, "..", "backend", "nakama_standin.py"))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
tmp = tempfile.mkdtemp()
logged = []
s.log = logged.append
s.SEED = os.path.join(HERE, "..", "backend", "seed.json")
s.COVERAGE = os.path.join(tmp, "coverage.json")
s.STATE, s.LOADOUT, s.COSMETICS = (os.path.join(tmp, n) for n in ("state.json", "loadout.json", "cosmetics.json"))
for name in ("CHECKOUT", "SHIP_STOLEN", "SHIP_LOST", "SHIP_GATE", "GIFTS_IN"):
    setattr(s, name, os.path.join(tmp, os.path.basename(getattr(s, name))))

# A new save is built from the seed, at the current schema.
s.state = s.load_state()
assert s.state["schema"] == s.SCHEMA, s.state.get("schema")
assert json.load(open(s.STATE, encoding="utf-8"))["schema"] == s.SCHEMA
h = s.Handler.__new__(s.Handler)

# What the client does at the menu, in order (backend/server.log of a real session).
out, _ = h.route("POST", "/v2/account/authenticate/steam", {"create": "true"}, {"token": "x"})
assert out["token"] and out["refresh_token"], out
out, _ = h.route("GET", "/v2/account", {}, None)
assert out["user"]["id"] == s.state["user"]["id"] and isinstance(out["user"]["metadata"], str), out
out, _ = h.route("POST", "/v2/rpc/getbuildinfo", {}, None)
out, _ = h.route("POST", "/v2/rpc/masterstartfunction", {}, None)
master = json.loads(out["payload"])
assert "playerstats" in master and "servertime" in master, sorted(master)

# Stash: write an item, list it, read it by id, delete it.
item = {"collection": "inventory", "key": "54321", "value": json.dumps({"value": "54321-BandageAid-1-1-0-0-0-Stash"})}
out, _ = h.route("PUT", "/v2/storage", {}, {"objects": [item]})
assert out["acks"][0]["key"] == "54321", out
out, _ = h.route("GET", "/v2/storage/inventory", {"limit": "1000"}, None)
assert any(o["key"] == "54321" for o in out["objects"]), out
out, _ = h.route("POST", "/v2/storage", {}, {"object_ids": [{"collection": "inventory", "key": "54321"}]})
assert len(out["objects"]) == 1, out
saved = json.load(open(s.STATE, encoding="utf-8"))
assert "54321" in saved["storage"]["inventory"], "the write reached state.json"
h.route("POST", "/v2/storage/delete", {}, {"object_ids": [{"collection": "inventory", "key": "54321"}]})
assert "54321" not in json.load(open(s.STATE, encoding="utf-8"))["storage"]["inventory"]
print("login, masterstartfunction and the stash round trip work from seed.json")

# #370: a new item that copies one already in the same place isn't stored, and later writes to it are ignored; a
# container's copy and its contents are cleaned at login, the contents moving into the container that stays.
def obj(key, rest):
    return {"collection": "inventory", "key": key, "value": json.dumps({"value": key + "-" + rest})}
h.route("PUT", "/v2/storage", {}, {"objects": [obj("100", "SmallContainer-1-1-0-0-0-Stash"), obj("101", "9mmAmmo-60-1-0-0-0-100")]})
out, _ = h.route("PUT", "/v2/storage", {}, {"objects": [obj("102", "9mmAmmo-60-1-0-0-0-100"), obj("103", "9mmAmmo-60-1-1-0-0-100")]})
assert [a["key"] for a in out["acks"]] == ["102", "103"], out
inv = s.state["storage"]["inventory"]
assert "102" not in inv and "103" in inv, sorted(inv)
h.route("PUT", "/v2/storage", {}, {"objects": [obj("102", "9mmAmmo-60-1-5-5-0-Stash")]})
assert "102" not in s.state["storage"]["inventory"]
inv["200"] = dict(inv["100"], value=json.dumps({"value": "200-SmallContainer-1-1-0-0-0-Stash"}), create_time="2099")
inv["201"] = dict(inv["101"], value=json.dumps({"value": "201-9mmAmmo-60-1-0-0-0-200"}), create_time="2099")
inv["202"] = dict(inv["101"], value=json.dumps({"value": "202-Biscuit-1-1-2-0-0-200"}), create_time="2099")
assert s.drop_twins() == 2 and "200" not in inv and "201" not in inv, sorted(inv)
assert json.loads(inv["202"]["value"])["value"].endswith("-100"), inv["202"]
assert s.drop_twins() == 0
for k in ("100", "101", "103", "202"):
    inv.pop(k)
print("duplicates: not stored on write, removed at login with their contents kept")

# A big extraction stays fast (the duplicate check is one index per request, not a scan per item), and two copies of
# one item in the same request keep only the first.
import time
inv = s.state["storage"]["inventory"]
for i in range(1000):
    inv[str(500000 + i)] = {"value": json.dumps({"value": f"{500000 + i}-Ration-1-1-{i % 10}-{i // 10}-0-Stash"}),
                            "create_time": "2026", "update_time": "2026"}
batch = [obj(str(600000 + i), f"9mmAmmo-60-1-{i % 10}-{i // 10}-0-Stash") for i in range(500)]
batch.append(obj("700000", "9mmAmmo-60-1-0-0-0-Stash"))  # the same item and place as 600000
t0 = time.time()
out, _ = h.route("PUT", "/v2/storage", {}, {"objects": batch})
took = time.time() - t0
assert took < 5, f"500 writes against 1000 items took {took:.1f} s"
assert "600000" in inv and "700000" not in inv, "the second copy in one request is not stored"
for k in [k for k in inv if k.isdigit() and int(k) >= 500000]:
    inv.pop(k)
s.state.pop("dropped_twins", None)
s.save_state(s.state)
print(f"a 500-item write against 1000 items took {took:.2f} s; a copy inside one request is dropped")

# #370: after a raid ends, the first write of new items refuses ones placed inside containers that stayed in the stash
# (raid loot can only be in bags that went in); loot in a bag that went into the raid, and later writes, are stored.
inv = s.state["storage"]["inventory"]
h.route("PUT", "/v2/storage", {}, {"objects": [obj("800", "SmallContainer-1-1-0-0-0-Stash"),
                                              obj("801", "Ration-1-1-0-0-0-800")]})
s.mark_home_containers()
out, _ = h.route("PUT", "/v2/storage", {}, {"objects": [obj("900", "Backpack-1-1-0-0-0-Bag"),  # a bag back from the raid
                                                        obj("901", "Ration-1-1-0-0-0-900"),
                                                        obj("902", "Ration-1-1-1-0-0-800")]})  # stash box: not loot
assert len(out["acks"]) == 3, out
assert "900" in inv and "901" in inv and "902" not in inv, sorted(k for k in inv if k.startswith("9"))
assert "home_containers" not in s.state
h.route("PUT", "/v2/storage", {}, {"objects": [obj("903", "Ration-1-1-2-0-0-800")]})  # later: a vendor buy
assert "903" in inv
for k in ("800", "801", "900", "901", "903"):
    inv.pop(k)
s.state.pop("dropped_twins", None)
s.save_state(s.state)
print("raid end: new items in containers that stayed home are not stored, once")

# #370: the inventory list puts a container before its contents, even when the contents' keys sort first.
lst = s.parents_first({"1": {"value": json.dumps({"value": "1-Ration-1-1-0-0-0-5"})},
                       "5": {"value": json.dumps({"value": "5-Backpack-1-1-0-0-0-9"})},
                       "9": {"value": json.dumps({"value": "9-SmallContainer-1-1-0-0-0-Stash"})}})
assert [k for k, _ in lst] == ["9", "5", "1"], lst
print("inventory list: containers before their contents")

# A state.json that doesn't parse falls back to the copy kept before the last write.
s.save_state(s.state)
open(s.STATE, "w", encoding="utf-8").write("{ broken")
back = s.load_state()
assert back["storage"]["inventory"] == s.state["storage"]["inventory"], "loaded state.json.bak"
assert any("previous copy" in m for m in logged), logged
s.save_state(s.state)
print("a broken state.json loads its previous copy")

# An old save (no schema field) is brought up to date on load and written back; a newer one is left alone.
old = dict(saved)
old.pop("schema")
json.dump(old, open(s.STATE, "w", encoding="utf-8"))
s.state = s.load_state()
assert s.state["schema"] == s.SCHEMA and json.load(open(s.STATE, encoding="utf-8"))["schema"] == s.SCHEMA
newer = dict(saved, schema=s.SCHEMA + 1)
json.dump(newer, open(s.STATE, "w", encoding="utf-8"))
s.state = s.load_state()
assert s.state["schema"] == s.SCHEMA + 1 and any("newer than this stand-in" in m for m in logged), logged
print("schema: old saves migrate, newer saves are left as they are")
print("ok")
