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
