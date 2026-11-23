# Checks the stand-in's settle_ship on the items a bad extraction really wrote. Touches no save: it uses its own state.
import importlib.util
import sys; import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts')); from pvepaths import ROOT  # noqa: E402

spec = importlib.util.spec_from_file_location("standin", os.path.join(ROOT, r'backend/nakama_standin.py'))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
s.log = lambda msg: None

BAD = {"collection": "inventory", "key": "95830966",
       "value": '{\r\n\t"value": "95830966-FrigateCapitalShip_Ship-1-Helldiver-0!0!0!0!0",\r\n\t"equip": true\r\n}'}
OWN = '{\r\n\t"value": "47943293-HeavyRaider_Ship-1-Vanquisher-0!0!0!0!0",\r\n\t"equip": true\r\n}'
GUN = {"collection": "inventory", "key": "1", "value": '{"value": "1-Bren-1-1-8-0-0-Stash"}'}

s.state = {"ship_out": {"key": "47943293", "item": OWN}}
assert s.settle_ship(dict(BAD)) == BAD and "ship_out" in s.state, "no gate (quit the raid, then bought a ship): left alone"
print("ship bought after quitting a raid left alone")

s.state = {"ship_out": {"key": "47943293", "item": OWN, "gate": True}}
assert s.settle_ship(GUN) == GUN and "ship_out" in s.state, "a non-ship item must pass through and leave ship_out"
got = s.settle_ship(dict(BAD))
assert got["key"] == "47943293" and got["value"] == OWN and "ship_out" not in s.state, got
print("own ship restored over the made-up item")

s.state = {"ship_out": {"row": "HeavyRaider_Ship", "gate": True}}
got = s.settle_ship(dict(BAD))
assert got["key"] == "95830966" and "95830966-HeavyRaider_Ship-1-Helldiver" in got["value"] and "ship_out" not in s.state, got
print("stolen ship keeps the game's id and name, with its real row")

s.state = {}
assert s.settle_ship(dict(BAD)) == BAD, "with nothing remembered (a bought ship) the item must be left alone"
print("bought ship left alone")
