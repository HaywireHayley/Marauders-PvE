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
# The mod's crew (hired crewmates, the recruit pool, who died) lives in backend/crew.lua, outside state.json. Each save
# keeps its own copy as crew.lua, and the stand-in copies it at raid start like the state, so Undo last raid brings back
# crewmates lost in that raid. A save from before this has no crew.lua: it keeps whatever crew is in play.
CREW = os.path.join(BACKEND, "crew.lua")
CREW_RAID_COPY = os.path.join(BACKEND, "crew.before-last-raid.lua")
SLOT_CREW, SLOT_CREW_UNDO = "crew.lua", "before-last-raid-crew.lua"
ITEMS = os.path.join(ROOT, "assets", "saves", "items.json")
ITEM_NAMES = os.path.join(ROOT, "assets", "saves", "item_names.json")  # row -> in-game name (tools/offline-audit/itemnames.py)

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
    # The seed's board is the same for every save: the client rolls a new one against an old start time (#333; the
    # ContractTable dump isn't in the repository, so the board itself can't be rolled here). Not verified in game.
    if "contractstarttime" in stats:
        sa = _standin()
        _stat(state, "contractstarttime", sa.contract_time(time.time() - sa.CONTRACT_DUE))
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
        if os.path.exists(CREW):
            _copy(CREW, os.path.join(folder, SLOT_CREW))
        if os.path.exists(RAID_COPY):
            _copy(RAID_COPY, os.path.join(folder, "before-last-raid.json"))
            os.remove(RAID_COPY)
            undo_crew = os.path.join(folder, SLOT_CREW_UNDO)
            if os.path.exists(CREW_RAID_COPY):
                _copy(CREW_RAID_COPY, undo_crew)
            elif os.path.exists(undo_crew):
                os.remove(undo_crew)  # (that raid started with no crew file: an older one would bring back the wrong crew)
        if os.path.exists(CREW_RAID_COPY):
            os.remove(CREW_RAID_COPY)
        meta = _meta(sid)
        meta["played"] = time.time()
        _write(os.path.join(folder, "meta.json"), meta)
    os.remove(ACTIVE)


def rows_in_use(state, items=None):
    """How many stash rows the items in a save reach (0 for an empty stash), from their footprints."""
    grid = Grid(state, _read(ITEMS) if items is None else items)
    return max((line for _, line in grid.used), default=-1) + 1


def _size_for(needed):
    return max(STASH_H, min(STASH_MAX, needed))


def stash_rows(meta):
    """The stash height a save was made with. Saves from before the typed size had a double-stash switch."""
    rows = int(meta.get("stash_rows") or (STASH_H * 2 if meta.get("double_stash") else STASH_H))
    return min(rows, STASH_MAX)  # saves made when up to 100 rows were allowed


def activate(sid):
    settle()
    _copy(os.path.join(SAVES, sid, "state.json"), LIVE)
    if os.path.exists(os.path.join(SAVES, sid, SLOT_CREW)):
        _copy(os.path.join(SAVES, sid, SLOT_CREW), CREW)
    if os.path.exists(CREW_RAID_COPY):
        os.remove(CREW_RAID_COPY)
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


def _readable(path):
    """A save state that loads and has the parts the launcher and the stand-in read."""
    try:
        _summary(_read(path))
        return True
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
        return False


def _rebuild_meta(sid):
    """meta.json is gone or broken but state.json is fine (#555): write a plain one instead of calling the save damaged."""
    folder = os.path.join(SAVES, sid)
    when = os.path.getmtime(os.path.join(folder, "state.json"))
    meta = {"name": sid.replace("-", " "), "cheat": False, "created": when, "played": when}
    try:  # (#565) the stash keeps the size its items need: a rebuilt save used to fall back to 15 rows
        meta["stash_rows"] = _size_for(rows_in_use(_read(os.path.join(folder, "state.json"))))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    try:
        _write(os.path.join(folder, "meta.json"), meta)
    except OSError:
        pass
    return meta


def _repair_rows(sid, meta):
    """A save with no stash size on record gets the size its items need (at least the default)."""
    try:
        needed = rows_in_use(_read(os.path.join(SAVES, sid, "state.json")))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return meta
    meta = dict(meta, stash_rows=_size_for(needed))  # (written once, so the list doesn't read it again)
    try:
        _write(os.path.join(SAVES, sid, "meta.json"), meta)
    except OSError:
        pass
    return meta


def set_stash_rows(sid, rows):
    """Changes an existing save's stash height (#565). Larger is always safe; smaller is refused while items sit in
    the rows that would go. Takes effect the next time the save is played."""
    rows = int(rows)
    if not STASH_MIN <= rows <= STASH_MAX:
        raise ValueError(f"the stash can be {STASH_MIN} to {STASH_MAX} rows")
    needed = rows_in_use(_read(os.path.join(SAVES, sid, "state.json")))
    if rows < needed:
        raise ValueError(f"items reach row {needed}: move them up in the game first, or keep {needed} rows or more")
    meta = _meta(sid)
    meta["stash_rows"] = rows
    meta.pop("double_stash", None)
    _write(os.path.join(SAVES, sid, "meta.json"), meta)
    return rows


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
            damaged = False
        except (OSError, ValueError, AttributeError, KeyError, TypeError):
            info, damaged = {"cash": 0, "xp": 0, "items": 0}, True
        if not damaged and not meta:
            meta = _rebuild_meta(sid)  # (#555) only meta.json was lost: the game itself is fine
        elif not damaged and "stash_rows" not in meta and not meta.get("double_stash"):
            meta = _repair_rows(sid, meta)  # (#565) a meta.json rebuilt by build 45 has no size
        if damaged:
            meta = {"name": meta.get("name") or sid, "played": meta.get("played") or os.path.getmtime(folder)}
            # (#555) the copy taken when the last raid started is a way back: Undo last raid restores it
            can_undo = _readable(os.path.join(folder, "before-last-raid.json"))
            out.append({"id": sid, **meta, **info, "stash_rows": STASH_H, "can_undo": can_undo, "damaged": True})
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
    out_dir = out_dir or os.path.join(os.path.expanduser("~"), "Desktop")
    if not os.path.isdir(out_dir):
        out_dir = os.path.expanduser("~")
    path = os.path.join(out_dir, f"MaraudersOffline-save-{sid}-{time.strftime('%Y%m%d-%H%M')}.zip")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in ("meta.json", "state.json", SLOT_CREW):
            if f == "meta.json" or f == "state.json" or os.path.exists(os.path.join(SAVES, sid, f)):
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


def item_names():
    """Row -> the name the game shows ("SafetyHelmet" -> "Hard Hat"), for the give-items picker (#538). Empty if the
    file is missing: the picker then shows row names only."""
    try:
        with open(ITEM_NAMES, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


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


KITS = os.path.join(ROOT, "config", "kits.json")
GEAR = os.path.join(ROOT, "mods", "PvEDirector", "Scripts", "gear.lua")
KIT_MARKUP = 1.15  # convenience costs a bit: looting stays the cheaper way to gear up (#385)


def gear_prices():
    """Item row -> price, read from the mod's gear.lua (its { "Row", price } entries): the one price list vendors use."""
    with open(GEAR, encoding="utf-8") as f:
        return {row: int(p) for row, p in re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,\s*(\d+)', f.read())}


def kits():
    """The preset kits from config/kits.json, each with its price: gear.lua's prices (ammo, which gear.lua doesn't list,
    at the game's own item price) times KIT_MARKUP."""
    prices, items = gear_prices(), _read(ITEMS)
    out = []
    for k in _read(KITS)["kits"]:
        rows = [(row, int(n)) for row, n in k["items"]]
        total = sum(prices.get(row, items.get(row, {}).get("price", 0)) * n for row, n in rows)
        out.append({"name": k["name"], "items": rows, "price": int(round(total * KIT_MARKUP))})
    return out


def buy_kit(sid, kit):
    """Buys a kit (one entry of kits()) into a save's stash, all or nothing: every item is placed first, and only then is
    the cash taken and the save written once. Returns None when bought, or why not. A cheat save doesn't pay."""
    if active() == sid:
        return "That save is in play: close the game first."
    items = _read(ITEMS)
    missing = [row for row, _ in kit["items"] if row not in items]
    if missing:
        return f"Unknown item rows in the kit: {', '.join(missing)}"
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    cash = _summary(state)["cash"]
    cheat = state.get("cheat")
    if not cheat and cash < kit["price"]:
        return f"Not enough cash: the kit costs {kit['price']:,} and the save has {cash:,}."
    grid = Grid(state, items, stash_rows(_meta(sid)))
    for row, count in kit["items"]:
        it = items[row]
        per = max(int(it["max"] or 1), 1) if it["type"] == 18 or it["stackable"] else 1
        left = count
        while left > 0:
            n = min(per, left)
            if not _put(state, grid, items, row, n if per > 1 else None):
                return "Not enough room in the stash for the whole kit: nothing was bought."  # state isn't written
            left -= n
    if not cheat:
        _stat(state, "cash", cash - kit["price"])
    _write(path, state)
    return None


def set_cash(sid, amount):
    """Sets a save's cash. A cheat save keeps its infinite money (the stand-in puts it back after every purchase)."""
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    _stat(state, "cash", max(0, int(amount)))
    _write(path, state)


# Levels (#561): a way back after a lost save. The player's level comes from playerstats xp through the game's own XP
# table, which the mod writes to config/xp_levels.txt in the menu (lobby.lua: XP needed for level 1, 2, ...). Trader
# standing is playerstats factions, "a-b-c-d-e": faction XP per trader. The order is assumed to be DT_FactionShops' row
# order (United, Republic, Kingdom, Pirate, Guild); not yet checked in game.
XP_LEVELS = os.path.join(ROOT, "config", "xp_levels.txt")
FACTIONS = ("United Allies", "Republic", "Kingdom Alliance", "Pirates", "Guild")
FACTION_XP_MAX = 999999


def xp_table():
    """XP needed for level 1, 2, ... (index 0 is level 1), or [] before the game has been to the menu once."""
    try:
        with open(XP_LEVELS, encoding="utf-8") as f:
            return [int(x) for x in f.read().strip().split(",") if x.strip()]
    except (OSError, ValueError):
        return []


def level_for(xp, table):
    return sum(1 for need in table if xp >= need)


def _stat_value(state, key, default="0"):
    try:
        return json.loads(state["storage"]["playerstats"][key]["value"]).get("value", default)
    except (KeyError, ValueError, AttributeError):
        return default


def levels(sid):
    """{"xp": int, "factions": [int x5]} for a save."""
    state = _read(os.path.join(SAVES, sid, "state.json"))
    parts = str(_stat_value(state, "factions", "0-0-0-0-0")).split("-")
    fac = [int(p) if p.strip().lstrip("-").isdigit() else 0 for p in parts] + [0] * len(FACTIONS)
    return {"xp": int(_stat_value(state, "xp") or 0), "factions": fac[:max(len(FACTIONS), len(parts))]}


def set_levels(sid, xp=None, factions=None):
    """Sets a save's XP and/or faction XP (the game must be closed: it works on backend/state.json)."""
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    stats = state["storage"]["playerstats"]
    template = next(iter(stats.values()))
    for key in ("xp", "factions"):
        if key not in stats:
            stats[key] = dict(template)  # (the value is set below, or stays the template's until then)
    if xp is not None:
        _stat(state, "xp", max(0, int(xp)))
    if factions is not None:
        _stat(state, "factions", "-".join(str(max(0, min(FACTION_XP_MAX, int(v)))) for v in factions))
    _write(path, state)


def undo_last_raid(sid):
    """Back to the moment the last raid started: for a raid that ended without an extraction you wanted."""
    folder = os.path.join(SAVES, sid)
    state = os.path.join(folder, "state.json")
    if os.path.exists(state) and not _readable(state):  # (#555) keep the broken file to work out what broke it
        _copy(state, os.path.join(folder, "state.damaged.json"))
    _copy(os.path.join(folder, "before-last-raid.json"), state)
    os.remove(os.path.join(folder, "before-last-raid.json"))
    undo_crew = os.path.join(folder, SLOT_CREW_UNDO)
    if os.path.exists(undo_crew):  # crewmates lost in that raid come back
        _copy(undo_crew, os.path.join(folder, SLOT_CREW))
        os.remove(undo_crew)


# Crew gear (#418) -----------------------------------------------------------------------------------------------------
# A hired crewmate's record in the save's crew.lua (hire.lua) can carry gear = { gun = row, helmet = row, chest = row,
# bag = row }: stash items the launcher moved onto them. crew.lua dresses them in it instead of their rolled kit every
# raid, for as long as they live; a crewmate who dies or is dismissed takes it with them. The launcher reads and writes
# crew.lua with the small reader below, which handles what hire.lua's ser() writes (tables, strings, numbers, booleans).
CREW_SLOTS = ("gun", "helmet", "chest", "bag")
_GEAR_LISTS = {"gun": "guns", "helmet": "helmets", "chest": "chests", "bag": "bags"}
_NO_BOT_GUNS = {"LPOFlamethrower"}  # gear.lua botGuns: in a bot's hands it never stopped firing (#413)
_LUA_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}
_LUA_SPACE = re.compile(r"(?:\s+|--[^\n]*)*")
_LUA_NAME = re.compile(r"([A-Za-z_]\w*)\s*=")
_LUA_ATOM = re.compile(r"true|false|nil|-?(?:0x[0-9a-fA-F]+|inf|nan|\d+(?:\.\d*)?(?:[eE][-+]?\d+)?)")


def _lua_load(text):
    """The value after `return` in a file hire.lua wrote."""
    def skip(i):
        return _LUA_SPACE.match(text, i).end()

    def expect(i, ch):
        i = skip(i)
        if text[i] != ch:
            raise ValueError(f"crew.lua: expected {ch!r} at {i}")
        return i + 1

    def value(i):
        i = skip(i)
        c = text[i]
        if c == "{":
            out, n, i = {}, 1, i + 1
            while True:
                i = skip(i)
                if text[i] == "}":
                    return out, i + 1
                if text[i] == "[":
                    k, i = value(i + 1)
                    i = expect(expect(i, "]"), "=")
                elif _LUA_NAME.match(text, i):
                    m = _LUA_NAME.match(text, i)
                    k, i = m.group(1), m.end()
                else:
                    k, n = n, n + 1
                out[k], i = value(i)
                i = skip(i)
                if text[i] in ",;":
                    i += 1
        if c == '"':
            s, i = [], i + 1
            while text[i] != '"':
                if text[i] == "\\":
                    m = re.compile(r"\d{1,3}").match(text, i + 1)
                    if m:
                        s.append(chr(int(m.group())))
                        i = m.end()
                        continue
                    s.append(_LUA_ESC.get(text[i + 1], text[i + 1]))
                    i += 2
                else:
                    s.append(text[i])
                    i += 1
            return "".join(s), i + 1
        m = _LUA_ATOM.match(text, i)
        if not m:
            raise ValueError(f"crew.lua: can't read the value at {i}")
        w = m.group()
        if w in ("true", "false", "nil"):
            return {"true": True, "false": False, "nil": None}[w], m.end()
        if "x" in w:
            return int(w, 16), m.end()
        return (float(w) if any(ch in w for ch in ".eEn") else int(w)), m.end()

    return value(text.index("return") + len("return"))[0]


def _lua_str(s):
    return '"' + "".join("\\" + c if c in '"\\' else "\\n" if c == "\n" else c if c >= " " else f"\\{ord(c)}"
                         for c in s) + '"'


def _lua_dump(v, ind=""):
    """As hire.lua's ser() writes it."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return _lua_str(v)
    if isinstance(v, (int, float)):
        return repr(v)
    pad = ind + "  "
    parts = []
    for k, x in v.items():
        key = f"[{k}]" if isinstance(k, int) else k if re.fullmatch(r"[A-Za-z_]\w*", k) else f"[{_lua_str(k)}]"
        parts.append(f"{pad}{key} = {_lua_dump(x, pad)}")
    return "{\n" + ",\n".join(parts) + "\n" + ind + "}"


def _lua_list(t):
    return [t[k] for k in sorted(k for k in t if isinstance(k, int))] if isinstance(t, dict) else []


def _crew_path(sid):
    return os.path.join(SAVES, sid, SLOT_CREW)


def _read_crew(sid):
    if not os.path.exists(_crew_path(sid)):
        return None
    with open(_crew_path(sid), encoding="utf-8") as f:
        return _lua_load(f.read())


def _write_crew(sid, data):
    tmp = _crew_path(sid) + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Your crew and the recruit pool (hire.lua). Delete this file for a fresh pool and no crew.\nreturn "
                + _lua_dump(data) + "\n")
    os.replace(tmp, _crew_path(sid))


def crew_gear_rows():
    """Slot -> the item rows a crewmate can carry there: gear.lua's lists, the ones rolled kits come from (guns with an
    ammo row, so the mod can give them magazines)."""
    with open(GEAR, encoding="utf-8") as f:
        text = f.read()
    out = {}
    for slot, name in _GEAR_LISTS.items():
        m = re.search(r"\n    " + name + r" = \{(.*?)\n    \}", text, re.S)
        rows = re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,\s*\d+\s*(,\s*"[A-Za-z0-9_]+")?', m.group(1)) if m else []
        out[slot] = {r for r, ammo in rows if slot != "gun" or (ammo and r not in _NO_BOT_GUNS)}
    return out


def _stash_entries(state):
    """Inventory key -> item row, for every item lying in the stash itself (not worn, not inside a bag)."""
    out = {}
    for key, o in state["storage"]["inventory"].items():
        try:
            text = json.loads(o["value"]).get("value", "")
        except (ValueError, AttributeError, KeyError, TypeError):
            continue
        m = re.match(r"\d+-([A-Za-z0-9_]+)-\d+-\d+-\d+-\d+-\d+-Stash(?:-|$)", text)
        if m:
            out[key] = m.group(1)
    return out


def crew_gear(sid):
    """For the Crew gear dialog: {"crew": [{id, name, level, gear: {slot: row}}], "stash": {slot: [(key, row)]}}, or
    None when the save has no crew file (nobody hired with it yet)."""
    data = _read_crew(sid)
    if data is None:
        return None
    crew = []
    for r in _lua_list(data.get("crew")):
        g = r.get("gear") if isinstance(r.get("gear"), dict) else {}
        crew.append({"id": r.get("id"), "name": r.get("name", "?"), "level": r.get("level", 1),
                     "gear": {s: g[s] for s in CREW_SLOTS if g.get(s)}})
    rows = crew_gear_rows()
    stash = {s: [] for s in CREW_SLOTS}
    entries = _stash_entries(_read(os.path.join(SAVES, sid, "state.json")))
    for key, row in sorted(entries.items(), key=lambda kv: (kv[1].lower(), kv[0])):
        for s in CREW_SLOTS:
            if row in rows[s]:
                stash[s].append((key, row))
    return {"crew": crew, "stash": stash}


def set_crew_gear(sid, crew_id, picks):
    """Changes what a hired crewmate carries. picks: slot -> a stash item key (moved from the stash onto them; what they
    had in that slot goes back to the stash), or None (back to the stash: the slot is their own rolled kit again). Slots
    left out stay as they are. All or nothing; returns None when done, or why not."""
    if active() == sid:
        return "That save is in play: close the game first."
    data = _read_crew(sid)
    r = next((c for c in _lua_list(data and data.get("crew")) if c.get("id") == crew_id), None)
    if r is None:
        return "That crewmate isn't in this save's crew any more."
    items, rows = _read(ITEMS), crew_gear_rows()
    path = os.path.join(SAVES, sid, "state.json")
    state = _read(path)
    stash = _stash_entries(state)
    gear = dict(r["gear"]) if isinstance(r.get("gear"), dict) else {}
    back = []
    for slot, key in picks.items():
        if slot not in CREW_SLOTS:
            return f"No slot called {slot}."
        if key is not None and stash.get(key) not in rows[slot]:
            return f"That {slot} isn't in the stash any more."
        if gear.get(slot):
            back.append(gear.pop(slot))
        if key is not None:
            gear[slot] = stash.pop(key)
            del state["storage"]["inventory"][key]
    grid = Grid(state, items, stash_rows(_meta(sid)))  # (cells of the items just taken are free again)
    for row in back:  # at the item's full condition: the stash string isn't kept on the crewmate
        if row in items and not _put(state, grid, items, row):
            return "Not enough room in the stash for the gear coming back: nothing was changed."
    if gear:
        r["gear"] = gear
    else:
        r.pop("gear", None)
    _write(path, state)
    _write_crew(sid, data)
    return None
