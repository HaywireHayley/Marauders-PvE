"""Save slots for the offline game. A save is backend/saves/<id>/ with state.json (the stand-in's account) and meta.json.

The stand-in always works on backend/state.json, so scripts and tests keep working: Play copies the chosen save there, and
when the game has closed it's copied back. backend/active_save.txt names the save in play, so a launcher that was closed
mid-game still puts it back next time.
"""
import importlib.util
import json
import os
import random
import re
import shutil
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(ROOT, "backend")
SAVES = os.path.join(BACKEND, "saves")
LIVE = os.path.join(BACKEND, "state.json")
RAID_COPY = os.path.join(BACKEND, "state.before-last-raid.json")
ACTIVE = os.path.join(BACKEND, "active_save.txt")
ITEMS = os.path.join(ROOT, "assets", "saves", "items.json")

# A new save starts as a brand-new live account did: on its first login the game itself gives 65,000 credits and its
# 34-item starter kit (two Klobb SMGs, three Mat49s, helmets, armour, bags, ammo, bandages, a supply drop). It does
# that when the account has no social/created yet, which a fresh save never has (the seed carries none). The launcher
# used to add its own 10,000 and a P08 kit on top, so the bank showed 10,000 and then jumped to 75,000 (issue #56).
START_CASH = 0
NEW_PLAYER_CASH = 65000       # what the game's new-player setup gives (a gear save skips that setup)
CHEAT_CASH = 999999999       # the stand-in also puts it back after every purchase (cheat saves)
STASH_W, STASH_H = 10, 15
# Rows a new save may ask for (the width is the game's own 10). The game indexes stash cells with a byte, so past
# 256 cells (25 full rows) slots wrap onto the top rows: wrong drop highlights and clashing spaces. 25 is the most.
STASH_MIN, STASH_MAX = 10, 25
STASH_ROWS = os.path.join(ROOT, "config", "stash_rows.txt")  # read by the mod in the menu; absent = the normal stash


def _standin():
    spec = importlib.util.spec_from_file_location("nakama_standin", os.path.join(BACKEND, "nakama_standin.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _read(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def _copy(src, dst):
    """copyfile, but a crash or a full disk mid-copy leaves the old file whole instead of a cut-off one."""
    tmp = dst + ".tmp"
    shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def _stat(state, key, value):
    state["storage"]["playerstats"][key]["value"] = json.dumps({"value": str(value)})


def _item_key(state):
    inv = state["storage"]["inventory"]
    while True:
        key = str(random.randint(10000000, 99999999))
        if key not in inv:
            return key


def _add(state, row, stack, condition, col, line, gun=False):
    """An item in the stash, in the game's own string: id-row-stack-condition-column-row-rotated-container[-attachments]."""
    key = _item_key(state)
    text = f"{key}-{row}-{stack}-{condition}-{col}-{line}-0-Stash"
    if gun:
        text += "-0!0!0!0!0!0!0"
    uid = state["user"]["id"]
    state["storage"]["inventory"][key] = {
        "value": json.dumps({"value": text, "equip": False}), "user_id": uid, "version": key,
        "create_time": "2026-01-01T00:00:00Z", "update_time": "2026-01-01T00:00:00Z", "permission_read": 1, "permission_write": 1}


class Grid:
    """Fills the stash left to right, top to bottom, the way you'd pack it by hand."""

    def __init__(self, state, items, rows=STASH_H):
        self.used = set()
        self.rows = rows
        for o in state["storage"]["inventory"].values():
            m = re.search(r'-([A-Za-z0-9_]+)-\d+-\d+-(\d+)-(\d+)-\d+-Stash', o["value"])
            if m:
                it = items.get(m.group(1), {})
                col, line = int(m.group(2)), int(m.group(3))
                self.used |= {(col + x, line + y) for x in range(max(it.get("w", 1), 1)) for y in range(max(it.get("h", 1), 1))}

    def place(self, w, h):
        for line in range(self.rows - h + 1):
            for col in range(STASH_W - w + 1):
                cells = {(col + x, line + y) for x in range(w) for y in range(h)}
                if not cells & self.used:
                    self.used |= cells
                    return col, line
        return None


def _put(state, grid, items, row, stack=None):
    it = items[row]
    spot = grid.place(max(it["w"], 1), max(it["h"], 1))
    if not spot:
        return False
    if stack is None:
        stack = it["max"] if it["type"] in (0, 1, 18) or it["stackable"] else 1
    _add(state, row, stack, it["dur"], spot[0], spot[1], gun=it["type"] in (0, 1))
    return True


def _fresh(name):
    """The account as a new player has it: no levels, no stats, no campaign progress, an almost empty stash."""
    state = _standin().new_state()
    state["user"]["display_name"] = name
    meta = state["user"].get("metadata") or {}
    state["user"]["metadata"] = {k: 0 if isinstance(v, (int, float)) else v for k, v in meta.items()}
    state["leaderboards"] = {}
    stats = state["storage"]["playerstats"]
    defaults = {"cash": START_CASH, "xp": 0, "points": 0, "chapterprogressions": "A-0-0", "factions": "0-0-0-0-0"}
    for key, value in defaults.items():
        if key in stats:
            _stat(state, key, value)
    for key in ("skillsunlocked", "cosmeticsunlocked"):
        if key in stats:
            _stat(state, key, "")
    # What every new account is given: the base cosmetics and voice pack. Anything else in the seed was earned.
    inv = state["storage"]["inventory"]
    state["storage"]["inventory"] = {k: o for k, o in inv.items() if re.search(r"-(Body01|Head01|Twitchvoicepack01)-", o["value"])}
    state["storage"].setdefault("gifts", {})
    return state


def _set_up_already(state):
    """Marks the account as one the game has already set up (social/created), so its first login doesn't add the
    new-player kit and money: a cheat save's stash is already packed, and the kit would land on top of it."""
    template = next(iter(state["storage"]["playerstats"].values()))
    social = state["storage"].setdefault("social", {})
    for key, value in (("created", time.strftime("%Y.%m.%d-%H.%M.%S")), ("accouttype", "TEST")):
        social[key] = {**template, "value": json.dumps({"value": value})}


def _stacked(state, items, rows):
    """The best of everything that fits: top guns with ammo, full armour, the big bag, and medicine in the gaps."""
    grid = Grid(state, items, rows)
    guns = ["MG42Rifle", "FALRifle", "BrenMk2Rifle", "STG44Rifle", "HeavyThompsonSMG", "PPSHSmg", "SVURifle", "M1911GPistol", "1911GPistol"]
    armour = ["FullPanzerChest", "HeavyStahlhelmHelmet", "CustomPSHHelmet", "FreebooterBag", "FullPanzerRig", "BarrelBag"]
    for row in armour + guns:
        if row in items:
            _put(state, grid, items, row)
    for row in ("762Ammo", "556Ammo", "10mmAmmo", "45Ammo", "9mmAmmo", "300Ammo", "12GaugeAmmo"):
        for _ in range(3):
            if row in items:
                _put(state, grid, items, row)
    for row in ("LargeFirstAid", "SmallFirstAid", "Morphine", "BandageAid", "PirateFirstAid", "Ration", "WaterBottle"):
        for _ in range(3):
            if row in items:
                _put(state, grid, items, row)
    key = _item_key(state)
    uid = state["user"]["id"]
    text = f"{key}-StrikeFrigate_Ship-1-Vanquisher-0!0!0!0!0"
    state["storage"]["inventory"][key] = {
        "value": json.dumps({"value": text, "equip": True}), "user_id": uid, "version": key,
        "create_time": "2026-01-01T00:00:00Z", "update_time": "2026-01-01T00:00:00Z", "permission_read": 1, "permission_write": 1}


# Windows device names: a folder can be made with some of these, but not the files inside it ("Nul" failed silently).
RESERVED = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(10)), *(f"lpt{i}" for i in range(10))}


def _slug(name):
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "save"
    if base in RESERVED:
        base += "-save"
    slug, n = base, 1
    while os.path.exists(os.path.join(SAVES, slug)):
        n += 1
        slug = f"{base}-{n}"
    return slug


def _meta(sid):
    return _read(os.path.join(SAVES, sid, "meta.json"))


def _summary(state):
    def stat(key):
        try:
            return json.loads(state["storage"]["playerstats"][key]["value"]).get("value", "0")
        except (KeyError, ValueError, AttributeError):
            return "0"
    return {"cash": int(stat("cash") or 0), "xp": int(stat("xp") or 0), "items": len(state["storage"].get("inventory", {}))}


def active():
    if os.path.exists(ACTIVE):
        with open(ACTIVE, encoding="utf-8") as f:
            return f.read().strip() or None
    return None


def adopt_existing():
    """First run: the save you've been playing becomes a slot, and nothing is lost."""
    os.makedirs(SAVES, exist_ok=True)
    if os.listdir(SAVES) or not os.path.exists(LIVE):
        return
    folder = os.path.join(SAVES, "main-save")
    os.makedirs(folder)
    _copy(LIVE, os.path.join(folder, "state.json"))
    _write(os.path.join(folder, "meta.json"), {"name": "Main save", "cheat": False, "created": time.time(), "played": time.time()})


def settle():
    """Puts a finished game back in its slot. Safe to call any time the game isn't running."""
    sid = active()
    if not sid:
        return
    folder = os.path.join(SAVES, sid)
    if os.path.isdir(folder) and os.path.exists(LIVE):
        _copy(LIVE, os.path.join(folder, "state.json"))
        if os.path.exists(RAID_COPY):
            _copy(RAID_COPY, os.path.join(folder, "before-last-raid.json"))
            os.remove(RAID_COPY)
        meta = _meta(sid)
        meta["played"] = time.time()
        _write(os.path.join(folder, "meta.json"), meta)
    os.remove(ACTIVE)


def stash_rows(meta):
    """The stash height a save was made with. Saves from before the typed size had a double-stash switch."""
    rows = int(meta.get("stash_rows") or (STASH_H * 2 if meta.get("double_stash") else STASH_H))
    return min(rows, STASH_MAX)  # saves made when up to 100 rows were allowed


def activate(sid):
    settle()
    _copy(os.path.join(SAVES, sid, "state.json"), LIVE)
    rows = stash_rows(_meta(sid))
    if rows != STASH_H:
        with open(STASH_ROWS, "w", encoding="utf-8") as f:
            f.write(f"{rows}\n")
    elif os.path.exists(STASH_ROWS):
        os.remove(STASH_ROWS)
    if os.path.exists(RAID_COPY):
        os.remove(RAID_COPY)
    with open(ACTIVE, "w", encoding="utf-8") as f:
        f.write(sid)


def listing():
    """Every save, newest first. One whose files can't be read is listed as damaged (it used to vanish from the list)."""
    out = []
    for sid in os.listdir(SAVES) if os.path.isdir(SAVES) else []:
        folder = os.path.join(SAVES, sid)
        if not os.path.isdir(folder):  # .keep
            continue
        try:
            meta = _meta(sid)
        except (OSError, ValueError):
            meta = {}
        try:
            info = _summary(_read(os.path.join(folder, "state.json")))
            damaged = not meta
        except (OSError, ValueError, AttributeError, KeyError, TypeError):
            info, damaged = {"cash": 0, "xp": 0, "items": 0}, True
        if damaged:
            meta = {"name": meta.get("name") or sid, "played": meta.get("played") or os.path.getmtime(folder)}
            out.append({"id": sid, **meta, **info, "stash_rows": STASH_H, "can_undo": False, "damaged": True})
            continue
        out.append({"id": sid, **meta, **info, "stash_rows": stash_rows(meta),
                    "can_undo": os.path.exists(os.path.join(folder, "before-last-raid.json"))})
    return sorted(out, key=lambda s: -s.get("played", 0))


def create(name, gear=False, money=False, rows=STASH_H):
    """A new save. gear: start from a packed stash instead of the new-player pistol. money: infinite money (meta's
    "cheat", which the panel toggle can switch later; the starting gear can't be changed later). Its stash height is
    fixed from here on: changing it under items the game has placed is asking for trouble."""
    rows = int(rows)
    if not STASH_MIN <= rows <= STASH_MAX:
        raise ValueError(f"stash rows must be {STASH_MIN}-{STASH_MAX}")
    items = _read(ITEMS)
    state = _fresh(name)
    if gear:
        _stacked(state, items, rows)
        _set_up_already(state)  # no new-player kit landing on top of the packed stash...
        _stat(state, "cash", NEW_PLAYER_CASH)  # ...but its money, so a gear-only save still has normal cash
    if money:
        state["cheat"] = True
        _stat(state, "cash", CHEAT_CASH)
    sid = _slug(name)
    folder = os.path.join(SAVES, sid)
    os.makedirs(folder)
    _write(os.path.join(folder, "state.json"), state)
    _write(os.path.join(folder, "meta.json"), {"name": name, "cheat": bool(money), "gear": bool(gear), "stash_rows": rows,
                                               "created": time.time(), "played": time.time()})
    return sid


def rename(sid, name):
    meta = _meta(sid)
    meta["name"] = name
    _write(os.path.join(SAVES, sid, "meta.json"), meta)


def copy(sid):
    meta = _meta(sid)
    new = _slug(meta["name"] + " copy")
    shutil.copytree(os.path.join(SAVES, sid), os.path.join(SAVES, new))
    meta.update(name=meta["name"] + " copy", played=time.time())
    _write(os.path.join(SAVES, new, "meta.json"), meta)
    return new


def export(sid, out_dir=None):
    """A backup of a save: one zip (its meta.json and state.json), on the Desktop unless out_dir is given (#98)."""
    meta = _meta(sid)
    out_dir = out_dir or os.path.join(os.path.expanduser("~"), "Desktop")
    if not os.path.isdir(out_dir):
        out_dir = os.path.expanduser("~")
    path = os.path.join(out_dir, f"MaraudersOffline-save-{sid}-{time.strftime('%Y%m%d-%H%M')}.zip")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in ("meta.json", "state.json"):
            z.write(os.path.join(SAVES, sid, f), f)
    return path


def _adopt(meta, state):
    """A save from elsewhere becomes a new one here; a name already taken gets " (imported)"."""
    if not isinstance(state, dict) or "storage" not in state or not isinstance(meta, dict):
        raise ValueError("not a Marauders Offline save")
    name = meta.get("name") or "Imported save"
    taken = {m.get("name") for m in (_meta(d) for d in os.listdir(SAVES) if os.path.isfile(os.path.join(SAVES, d, "meta.json")))}
    if name in taken:
        name += " (imported)"
    sid = _slug(name)
    os.makedirs(os.path.join(SAVES, sid))
    meta = dict(meta, name=name)
    _write(os.path.join(SAVES, sid, "state.json"), state)
    _write(os.path.join(SAVES, sid, "meta.json"), meta)
    return name


def import_from(path):
    """Saves from a backup zip, a save folder, or an older install's folder (its backend/saves) (#95, #98). Nothing
    at the source is changed. Returns the names of the saves added."""
    os.makedirs(SAVES, exist_ok=True)
    if os.path.abspath(path).startswith(os.path.abspath(SAVES)):
        raise ValueError("that's this install's own saves folder")
    if os.path.isfile(path) and zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            return [_adopt(json.loads(z.read("meta.json")), json.loads(z.read("state.json")))]
    folders = []
    if os.path.isfile(os.path.join(path, "state.json")) and os.path.isfile(os.path.join(path, "meta.json")):
        folders = [path]
    else:
        root = next((c for c in (os.path.join(path, "backend", "saves"), os.path.join(path, "saves"), path)
                     if os.path.isdir(c)), None)
        for d in sorted(os.listdir(root)) if root else []:
            f = os.path.join(root, d)
            if os.path.isfile(os.path.join(f, "state.json")) and os.path.isfile(os.path.join(f, "meta.json")):
                folders.append(f)
    return [_adopt(_read(os.path.join(f, "meta.json")), _read(os.path.join(f, "state.json"))) for f in folders]


def delete(sid):
    shutil.rmtree(os.path.join(SAVES, sid))


def set_cheat(sid, on):
    """Turns infinite money on or off for a save (it doesn't touch the stash)."""
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    state["cheat"] = on
    if on:
        _stat(state, "cash", CHEAT_CASH)
    _write(path, state)
    meta = _meta(sid)
    meta["cheat"] = on
    _write(os.path.join(SAVES, sid, "meta.json"), meta)


def item_rows():
    """Every item row a stash can hold, for the give-items picker (the game's test rows left out)."""
    return sorted((r for r in _read(ITEMS) if not r.lower().startswith("test")), key=str.lower)


def give(sid, row, count):
    """Adds count of an item row to a save's stash, filling stacks up to the item's maximum and packing them into free
    cells. Returns how many went in: fewer than asked when the stash is full."""
    items = _read(ITEMS)
    if row not in items:
        raise ValueError(f"no item called {row}")
    it = items[row]
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    grid = Grid(state, items, stash_rows(_meta(sid)))
    # Ammo and stackables go in stacks of up to max; anything else (a gun's max is its loaded magazine) one apiece.
    per = max(int(it["max"] or 1), 1) if it["type"] == 18 or it["stackable"] else 1
    given = 0
    while given < count:
        n = min(per, count - given)
        if not _put(state, grid, items, row, n if per > 1 else None):
            break
        given += n
    if given:
        _write(path, state)
    return given


def set_cash(sid, amount):
    """Sets a save's cash. A cheat save keeps its infinite money (the stand-in puts it back after every purchase)."""
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    _stat(state, "cash", max(0, int(amount)))
    _write(path, state)


def undo_last_raid(sid):
    """Back to the moment the last raid started: for a raid that ended without an extraction you wanted."""
    folder = os.path.join(SAVES, sid)
    _copy(os.path.join(folder, "before-last-raid.json"), os.path.join(folder, "state.json"))
    os.remove(os.path.join(folder, "before-last-raid.json"))
