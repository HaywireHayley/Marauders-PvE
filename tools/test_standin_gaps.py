# Checks the stand-in's coverage tally (issue #80), the tournament answer and the gift box hand-off. Touches no save:
# the stand-in's files are pointed at a temporary folder.
import importlib.util
import json
import os
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("standin", os.path.join(HERE, "..", "backend", "nakama_standin.py"))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
tmp = tempfile.mkdtemp()
s.log = lambda msg: None
s.COVERAGE = os.path.join(tmp, "coverage.json")
s.STATE, s.LOADOUT, s.COSMETICS = (os.path.join(tmp, n) for n in ("state.json", "loadout.json", "cosmetics.json"))
s.state = {"user": {"id": "u1", "username": "u", "display_name": "u"}, "master": {},
           "storage": {"inventory": {"12345": {"value": '{"value": "12345-Bren-1-1-0-0-0-Stash"}'}}}}

h = s.Handler.__new__(s.Handler)
out, note = h.route("GET", "/v2/tournament", {"limit": "10"}, None)
assert out == {} and note == "tournaments: none", note
out, note = h.route("POST", "/v2/rpc/guild_getinfo", {}, {"guildid": "x"})
assert out == {"payload": "{}"} and note.startswith("UNKNOWN rpc guild_getinfo"), note
h.route("POST", "/v2/rpc/guild_getinfo", {}, {})
h.route("GET", "/v2/storage/twitch", {}, None)
h.route("GET", "/v2/friend/0123456789abcdef0123456789abcdef", {}, None)
s.flush_coverage()
cov = json.load(open(s.COVERAGE, encoding="utf-8"))
assert cov["unknown rpcs"]["guild_getinfo"]["count"] == 2, cov
assert cov["empty collections"]["twitch"]["count"] == 1, cov
assert "GET /v2/friend/<id>" in cov["unhandled endpoints"], cov
print("coverage:", {k: sorted(v) for k, v in cov.items()})

# A second session adds to the same file.
s.coverage = {"dirty": False, "data": None}
h.route("POST", "/v2/rpc/guild_getinfo", {}, {})
s.flush_coverage()
assert json.load(open(s.COVERAGE, encoding="utf-8"))["unknown rpcs"]["guild_getinfo"]["count"] == 3
print("coverage counts carry over between sessions")

added = s.add_gifts(["Mat49Rifle", "bad row; drop", "BandageAid"])
assert added == ["Mat49Rifle", "BandageAid"], added
gifts = s.state["storage"]["gifts"]
assert len(gifts) == 2 and "12345" not in gifts and all(len(k) == 5 for k in gifts), gifts
assert sorted(json.loads(o["value"])["value"] for o in gifts.values()) == ["BandageAid", "Mat49Rifle"]
master = s.rpc("masterstartfunction", None)
assert sorted(g["value"]["value"] for g in master["gifts"]) == ["BandageAid", "Mat49Rifle"], master["gifts"]
print("gifts reach masterstartfunction:", master["gifts"])
print("ok")
