"""Local stand-in for the game's Nakama backend (marauderea2.us-east1.nakamacloud.io), for offline play.

    python -I nakama_standin.py [--port 7350] [--dir <folder> [--name <display name>]]

--dir keeps a second player's save apart (co-op, #26): its own state.json, loadout, checkout and ship files in that
folder, a new account from the anonymous seed.json with its own user id, named --name. The joining game is pointed
at it by scripts/launch-joiner.ps1 (PVE_STANDIN_PORT for pvenet.dll, PVE_BACKEND for the PvEDirector mod).

pvenet.dll points the game's Nakama connection here (plain HTTP on 127.0.0.1) while bridge/offline_backend
exists. Implements the REST endpoints the client was seen using (see NOTES.md, "Backend capture"):
authenticate, account, storage list/read/write/delete, the RPCs, tournaments. It also does the raid server's stash
part (loadout.json out, checkout.txt in; see write_loadout / watch_checkout). State lives in state.json next to
this file; the first run builds it from capture/seed/account.json (scripts/capture_seed.py). Every request is
logged to server.log, and unknown endpoints answer {} so they show up there instead of breaking the client.
"""
import argparse
import base64
import json
import os
import re
import shutil
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "state.json")
LOG = os.path.join(HERE, "server.log")
LOADOUT = os.path.join(HERE, "loadout.json")  # equipped items, read by the PvEDirector mod at raid start
COSMETICS = os.path.join(HERE, "cosmetics.json")  # your look and voice, read by the PvEDirector mod at raid start
CHECKOUT = os.path.join(HERE, "checkout.txt")  # item ids taken into a raid, written by the PvEDirector mod
SHIP_STOLEN = os.path.join(HERE, "ship_stolen.txt")  # table row of a ship you took the helm of, written by the mod
SHIP_LOST = os.path.join(HERE, "ship_lost.txt")  # you died: the ship you took in isn't coming back
SHIP_GATE = os.path.join(HERE, "ship_gate.txt")  # written by the mod: 1 in a space gate, 0 back out of it
GIFTS_IN = os.path.join(HERE, "gifts_in.txt")  # item rows to put in your gift box, one per line (mod, launcher, you)
# What the client asked for that nothing answers (issue #80): unknown RPCs, unhandled endpoints, collections read
# while empty. Counted across sessions, so it shows which missing features players actually reach.
COVERAGE = os.path.join(HERE, "coverage.json")
# The starting account: the private capture of a real account when this PC has one (capture/ is never shared),
# else seed.json, the anonymous account that releases and the shared repository ship.
SEED = os.path.join(HERE, "..", "capture", "seed", "account.json")
if not os.path.exists(SEED):
    SEED = os.path.join(HERE, "seed.json")
PUBLIC_USER = "00000000-0000-0000-0000-000000000000"
CHEAT_CASH = 999999999
# Cosmetics every account owns, on top of the game's own free ones (English voice, head 1, body 6). The mod lets you
# play as a woman from the start, but the game's cheapest female voice (French, frF01) cost 3500. The game keeps
# unlocks in playerstats/cosmeticsunlocked as row names joined by "-" and writes the whole list back after a purchase.
FREE_COSMETICS = ("frF01", "57", "58", "59", "60", "72")  # 72: the Blood Raider's head (outfits.lua)
# The launcher's "Unlock all looks and voices" (issue #48): every DT_PlayerAppearance row (heads and bodies are
# numbered, voices named), read from the running game. Rows 57-60 (Pirate and Mod, cost 1) aren't here: they're
# owned by every account (FREE_COSMETICS) and worn from F9 in the lobby, since the Appearance pages never list them (#229). Only what's sent at login changes, never the save, so turning it off brings progression back.
UNLOCK_ALL_SETTING = os.path.join(HERE, "..", "config", "unlock_all_looks.txt")
ALL_COSMETICS = tuple(str(n) for n in list(range(1, 57)) + list(range(61, 73)) + [84, 85, 86, 87, 88, 89, 90, 92, 93, 94, 95]) + (
    "enM01", "frM01", "frF01", "plM01", "auM01", "usaM01", "usaF01", "huM01", "duM01", "duF01", "roM01", "itM01", "itF01",
    "str01")


NAME = None  # --name: display name for an account built in a --dir folder


def use_dir(folder, name=None):
    """Every per-player file in `folder` instead of next to this script; a new account there starts from the
    anonymous seed.json (never this PC's private capture) as a different user."""
    global STATE, LOG, LOADOUT, COSMETICS, CHECKOUT, SHIP_STOLEN, SHIP_LOST, SHIP_GATE, GIFTS_IN, COVERAGE, SEED, NAME
    os.makedirs(folder, exist_ok=True)
    STATE, LOG, LOADOUT, COSMETICS, CHECKOUT, SHIP_STOLEN, SHIP_LOST, SHIP_GATE, GIFTS_IN, COVERAGE = (
        os.path.join(folder, f) for f in ("state.json", "server.log", "loadout.json", "cosmetics.json", "checkout.txt",
                                          "ship_stolen.txt", "ship_lost.txt", "ship_gate.txt", "gifts_in.txt",
                                          "coverage.json"))
    SEED = os.path.join(HERE, "seed.json")
    NAME = name


def unlock_all():
    try:
        with open(UNLOCK_ALL_SETTING, encoding="utf-8") as f:
            return f.read().strip() == "on"
    except OSError:
        return False
lock = threading.Lock()


def stamp(t=None):
    return datetime.fromtimestamp(t or time.time(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(time.strftime("%H:%M:%S ") + msg + "\n")


LOG_KEEP = 1_000_000  # bytes: a bigger server.log becomes server.log.1 at start-up (one old copy kept)


def rotate_log():
    try:
        if os.path.getsize(LOG) > LOG_KEEP:
            os.replace(LOG, LOG + ".1")
    except OSError:
        pass


def write_atomic(path, text):
    """Writes the file whole or not at all, and on disk before it replaces the old one (a power cut or a blue screen
    mid-write leaves the old file, not an empty one)."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


_written = {}  # path -> the text last written, so unchanged side files aren't rewritten


def write_if_changed(path, text):
    if _written.get(path) == text and os.path.exists(path):
        return
    write_atomic(path, text)
    _written[path] = text


# ---- state --------------------------------------------------------------------------------------------
def new_state():
    """The account as the live backend last held it, from the capture seed."""
    seed = json.load(open(SEED, encoding="utf-8"))
    user = seed["account"]["user"]
    master = seed["rpcs"]["masterstartfunction"]["response"]
    storage = {}

    def put(col, key, value, owner):
        storage.setdefault(col, {})[key] = {
            "value": value if isinstance(value, str) else json.dumps(value),
            "user_id": owner, "version": uuid.uuid4().hex, "create_time": stamp(), "update_time": stamp(),
            "permission_read": 2 if owner == PUBLIC_USER else 1, "permission_write": 0 if owner == PUBLIC_USER else 1}

    # Profile stats come in the masterstartfunction reply; the client's own writes (cash...) override them.
    for kv in master.get("playerstats", []):
        put("playerstats", kv["key"], kv["value"], user["id"])
    for kv in master.get("cosequip", []):
        put("cosequipped", kv["key"], kv["value"], user["id"])
    for col, objs in seed["storage"].items():
        owner = PUBLIC_USER if col == "public" else user["id"]
        for key, value in objs.items():
            put(col, key, value, owner)
    # Unclaimed gifts only: a claimed gift became an inventory item with the same key.
    inv = storage.get("inventory", {})
    for kv in master.get("gifts", []):
        if kv["key"] not in inv:
            put("gifts", kv["key"], kv["value"], user["id"])
    meta = user.get("metadata")
    user["metadata"] = json.loads(meta) if isinstance(meta, str) else (meta or {})
    if NAME:  # a second player (--dir): another user, so nothing the game keys on the user id is shared
        old = user["id"]
        user["id"] = str(uuid.uuid4())
        user["display_name"] = user["username"] = NAME
        for objs in storage.values():
            for o in objs.values():
                if o["user_id"] == old:
                    o["user_id"] = user["id"]
    return {"schema": SCHEMA, "user": user, "storage": storage, "master": {k: master[k] for k in ("messages", "prestige", "raidertime")
                                                         if k in master}}


# The save format's version (issue #80). A change to how state.json is laid out bumps it and adds a step to MIGRATIONS
# that brings an older save up to date, so no stand-in update strands a player's save. Saves from before this field
# are schema 0, which matches schema 1.
SCHEMA = 1
MIGRATIONS = {
    0: lambda s: None,  # 0 -> 1: only the field itself
}


def migrate(s):
    """Brings a loaded save up to SCHEMA. Returns True if anything changed. A save from a newer stand-in is left as
    it is (and logged): migrating backwards could lose what the newer version added."""
    have = s.get("schema", 0)
    if have > SCHEMA:
        log(f"state.json is schema {have}, newer than this stand-in ({SCHEMA}): an older build is reading a newer save")
        return False
    for v in range(have, SCHEMA):
        MIGRATIONS[v](s)
        s["schema"] = v + 1
    if have != SCHEMA:
        log(f"state.json migrated from schema {have} to {SCHEMA}")
    return have != SCHEMA


def read_state_file():
    """state.json, or its previous copy (state.json.bak) if state.json is missing or doesn't parse."""
    for path in (STATE, STATE + ".bak"):
        try:
            with open(path, encoding="utf-8") as f:
                s = json.load(f)
            if path != STATE:
                log(f"state.json missing or unreadable: loaded the previous copy, {os.path.basename(path)}")
            return s
        except FileNotFoundError:
            continue
        except ValueError as e:
            log(f"{os.path.basename(path)} doesn't parse ({e})")
    return None


def load_state():
    s = read_state_file()
    if s is not None:
        if migrate(s):
            save_state(s)
            return s
        write_loadout(s)
        write_cosmetics(s)
        return s
    s = new_state()
    save_state(s)
    log("built state.json from the capture seed")
    return s


def save_state(s):
    """Writes state.json (compact: it's rewritten on every stash change), on disk before it replaces the old one, and
    keeps the copy it replaces as state.json.bak, which load_state falls back to."""
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(s, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    if os.path.exists(STATE):
        os.replace(STATE, STATE + ".bak")
    os.replace(tmp, STATE)
    write_loadout(s)
    write_cosmetics(s)


def write_loadout(s):
    """The equipped inventory items, as the raid server's SIGISPlayerController::Server_AwsN_EquippedItemsReturned
    takes them: a JSON array of storage objects whose value is {"equip":true,"value":"<item string>"}. There is no
    raid server offline; the PvEDirector mod feeds this file to that function at raid start."""
    items, bad = [], []
    for k, o in s["storage"].get("inventory", {}).items():
        try:
            v = json.loads(o["value"])
        except (ValueError, KeyError, TypeError):
            bad.append(k)
            continue
        if isinstance(v, dict) and v.get("equip"):
            items.append({"value": v})
    if bad:
        log(f"loadout: {len(bad)} inventory item(s) don't parse, left out: {bad[:10]}")
    write_if_changed(LOADOUT, json.dumps(items, separators=(",", ":")))


def write_cosmetics(s):
    """Your equipped head, body and voice (cosequipped), as the raid server's
    SIGISPlayerController::Server_AwsN_EquippedplayerCosmeticsReturned takes them: a JSON array of
    {"key": "head" | "body" | "voice", "value": "<row>"} (the stored {"value": ...} unwrapped; passing the stored
    string as it is put {"value":"20"} into EquippedHead). The PvEDirector mod feeds this file to it at raid start."""
    out = []
    for k, o in sorted(s["storage"].get("cosequipped", {}).items()):
        try:
            v = json.loads(o["value"])
        except (ValueError, KeyError, TypeError):
            log(f"cosmetics: {k} doesn't parse, left out")
            continue
        v = v.get("value") if isinstance(v, dict) else v
        if v not in (None, ""):
            out.append({"key": k, "value": str(v)})
    write_if_changed(COSMETICS, json.dumps(out, separators=(",", ":")))


state = None
coverage = {"dirty": False, "data": None}


def note_gap(kind, name):
    """Counts one request nothing answers. Call with the lock held; flush_coverage writes it out."""
    data = coverage["data"]
    if data is None:
        try:
            with open(COVERAGE, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
        coverage["data"] = data
    entry = data.setdefault(kind, {}).setdefault(name, {"count": 0, "first": stamp()})
    entry["count"] += 1
    entry["last"] = stamp()
    coverage["dirty"] = True


def flush_coverage():
    """Writes coverage.json if anything new was counted. Call with the lock held."""
    if not coverage["dirty"]:
        return
    coverage["dirty"] = False
    tmp = COVERAGE + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(coverage["data"], f, indent=1, sort_keys=True)
        os.replace(tmp, COVERAGE)
    except OSError as e:
        log(f"coverage.json not written: {e}")


def add_gifts(rows):
    """Puts item rows in the gift box (the lobby's GIFTS grid; claiming one turns it into a stash item with the same
    key). A gift is just a row: what the game makes of it when claimed is its own default for that item. Call with the
    lock held."""
    gifts = state["storage"].setdefault("gifts", {})
    taken = set(gifts) | set(state["storage"].get("inventory", {}))
    added = []
    for row in rows:
        if not re.fullmatch(r"[A-Za-z0-9_]+", row):
            log(f"gift skipped, not an item row: {row[:60]!r}")
            continue
        key = str(uuid.uuid4().int % 90000 + 10000)
        while key in taken:
            key = str(uuid.uuid4().int % 90000 + 10000)
        taken.add(key)
        now = stamp()
        gifts[key] = {"value": json.dumps({"value": row}), "user_id": state["user"]["id"], "version": uuid.uuid4().hex,
                      "create_time": now, "update_time": now, "permission_read": 1, "permission_write": 1}
        added.append(row)
    return added


def obj_out(col, key, o):
    return {"collection": col, "key": key, "user_id": o["user_id"], "value": o["value"], "version": o["version"],
            "permission_read": o["permission_read"], "permission_write": o["permission_write"],
            "create_time": o["create_time"], "update_time": o["update_time"]}


# ---- session tokens -----------------------------------------------------------------------------------
def b64(d):
    return base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=").decode()


def token(refresh=False):
    """A Nakama-shaped JWT: the client reads uid/usn/exp from it. Not signed (nothing checks it here)."""
    u = state["user"]
    now = int(time.time())
    claims = {"uid": u["id"], "usn": u["username"], "vrs": {}, "exp": now + 30 * 86400, "iat": now}
    if not refresh:
        claims["tid"] = uuid.uuid4().hex
    return b64({"alg": "HS256", "typ": "JWT"}) + "." + b64(claims) + ".offline"


# ---- RPCs ---------------------------------------------------------------------------------------------
def collection_kv(col):
    return [{"key": k, "value": json.loads(o["value"])} for k, o in sorted(state["storage"].get(col, {}).items())]


def with_free_cosmetics(stats):
    """The playerstats list with FREE_COSMETICS (and with the launcher setting on, ALL_COSMETICS) added to
    cosmeticsunlocked (only in what is sent, not in the save)."""
    free = FREE_COSMETICS + (ALL_COSMETICS if unlock_all() else ())
    out, seen = [], False
    for kv in stats:
        if kv["key"] == "cosmeticsunlocked":
            seen = True
            have = [c for c in str(kv["value"].get("value", "")).split("-") if c]
            kv = {"key": kv["key"], "value": {**kv["value"], "value": "-".join(have + [c for c in dict.fromkeys(free) if c not in have])}}
        out.append(kv)
    if not seen:
        out.append({"key": "cosmeticsunlocked", "value": {"value": "-".join(dict.fromkeys(free))}})
    return out


def user_record():
    u = dict(state["user"])
    u["online"] = True
    return u


def rpc(name, body):
    if name == "masterstartfunction":
        m = dict(state["master"])
        m.update({"cosequip": collection_kv("cosequipped"), "gifts": collection_kv("gifts"),
                  "playerstats": with_free_cosmetics(collection_kv("playerstats")), "servertime": str(int(time.time()))})
        return m
    if name == "getbuildinfo":
        return {"branch": {"maintenence": False, "version": 0}, "vtoken": ""}
    if name == "getsteaminfo":
        return {"avatar": state["user"].get("avatar_url", ""), "nick": state["user"].get("display_name", "")}
    if name == "statChangeArray":
        meta = state["user"].setdefault("metadata", {})
        for s in (body or {}).get("arrayIn", []):
            meta[s["stat"]] = meta.get(s["stat"], 0) + int(s["amount"])
        save_state(state)
        return user_record()
    return None


# ---- HTTP ---------------------------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def reply(self, obj, code=200):
        data = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            return raw.decode("utf-8", "replace")

    def handle_any(self):
        url = urlsplit(self.path)
        path, q = url.path, {k: v[0] for k, v in parse_qs(url.query).items()}
        body = self.body()
        with lock:
            out, note = self.route(self.command, path, q, body)
        log(f"{self.command} {self.path[:120]} -> {note}")
        self.reply(out)

    do_GET = do_POST = do_PUT = do_DELETE = handle_any

    def route(self, verb, path, q, body):
        # Other services the game reaches over WinHTTP (Sentry's crash and session reports): pvenet.dll sends them
        # here as /_ext/<host>/<path> so nothing reaches a live server. Answered with {} and counted.
        if path.startswith("/_ext/"):
            host = path.split("/")[2]
            note_gap("other services", f"{host} {verb} {re.sub(r'[0-9]{6,}', '<n>', '/'.join(path.split('/')[3:5]))}")
            return {}, f"other service {host}, answered locally"
        st = state["storage"]
        uid = state["user"]["id"]
        if path.startswith("/v2/account/authenticate/") or path == "/v2/account/session/refresh":
            if path.startswith("/v2/account/authenticate/"):
                return_unfinished_raid("login")
            return {"token": token(), "refresh_token": token(True)}, "session"
        if path == "/v2/account":
            u = dict(state["user"])
            u["metadata"] = json.dumps(u.get("metadata", {}))
            return {"user": u, "wallet": "{}"}, "account"
        if path == "/v2/storage/delete":
            ids = (body or {}).get("object_ids", [])
            for o in ids:
                st.get(o["collection"], {}).pop(o["key"], None)
            save_state(state)
            return {}, f"deleted {[(o['collection'], o['key']) for o in ids]}"
        if path == "/v2/storage" and verb == "PUT":
            acks, twins = [], []
            dropped = state.setdefault("dropped_twins", [])
            dropped_set, places = set(dropped), None
            home_mark = state.get("home_containers")
            if home_mark and time.time() - home_mark.get("at", 0) > HOME_CONTAINERS_TTL:
                state.pop("home_containers")
                home_mark = None
            home = set(home_mark["keys"]) if home_mark else set()
            new_items = [o for o in (body or {}).get("objects", []) if o.get("collection") == "inventory"
                         and o.get("key") not in st.get("inventory", {})]
            if home and new_items:
                state.pop("home_containers")  # only the first write of new items after a raid is checked
            else:
                home = set()
            strays = []
            for o in (body or {}).get("objects", []):
                # #370: a new item that is an exact copy of one already in the same place (same row, stack, condition,
                # cell and container) is a duplicate, never a real item: two can't share a cell. It's acknowledged so
                # the game carries on, but not stored, and later writes to that key are ignored the same way.
                twin = None
                if o["collection"] == "inventory" and o["key"] not in dropped_set \
                        and o["key"] not in st.get("inventory", {}):
                    if places is None:  # built once per request, kept up to date as items are stored below
                        places = item_places(st.get("inventory", {}))
                    twin = places.get(item_place(o.get("value")))
                stray = None
                if home and o["collection"] == "inventory" and o["key"] not in st.get("inventory", {}):
                    stray = home_container_of(o.get("value"), home)
                if stray:
                    strays.append(o["key"])
                if o["collection"] == "inventory" and (o["key"] in dropped_set or twin or stray):
                    if o["key"] not in dropped_set:
                        dropped.append(o["key"])
                        dropped_set.add(o["key"])
                        del dropped[:-1000]  # (the game lists the stash again each login, so old keys don't come back)
                    twins.append(o["key"])
                    now = stamp()
                    acks.append({"collection": "inventory", "key": o["key"], "version": uuid.uuid4().hex, "user_id": uid,
                                 "create_time": now, "update_time": now})
                    continue
                if o["key"] not in st.get(o["collection"], {}):
                    o = settle_ship(o)
                # A cheat save (launcher) never runs out: spending is put straight back.
                if state.get("cheat") and o["collection"] == "playerstats" and o["key"] == "cash":
                    o = {**o, "value": json.dumps({"value": str(CHEAT_CASH)})}
                col = st.setdefault(o["collection"], {})
                old = col.get(o["key"])
                now = stamp()
                col[o["key"]] = {"value": o.get("value", "{}"), "user_id": uid, "version": uuid.uuid4().hex,
                                 "permission_read": o.get("permission_read", 1),
                                 "permission_write": o.get("permission_write", 1),
                                 "create_time": old["create_time"] if old else now, "update_time": now}
                if places is not None and o["collection"] == "inventory":
                    places.setdefault(item_place(o.get("value")), o["key"])
                acks.append({"collection": o["collection"], "key": o["key"], "version": col[o["key"]]["version"],
                             "user_id": uid, "create_time": col[o["key"]]["create_time"], "update_time": now})
            save_state(state)
            if strays:
                log(f"inventory: {len(strays)} new item(s) placed in containers that never left the stash not stored "
                    f"(not raid loot, #370): {strays}")
            twins = [k for k in twins if k not in strays]
            if twins:
                log(f"inventory: {len(twins)} duplicate item(s) not stored (copies of items already in that place, #370): {twins}")
            return {"acks": acks}, f"wrote {[(a['collection'], a['key']) for a in acks if a['key'] not in twins]}"
        if path == "/v2/storage" and verb == "POST":  # read by id
            objs = []
            for o in (body or {}).get("object_ids", []):
                hit = st.get(o["collection"], {}).get(o["key"])
                if hit:
                    objs.append(obj_out(o["collection"], o["key"], hit))
            return {"objects": objs}, f"read {len(objs)}"
        if path.startswith("/v2/storage/") and verb == "GET":  # list a collection
            col = path.split("/")[3]
            items = sorted(st.get(col, {}).items())
            limit, start = int(q.get("limit", 100)), int(q.get("cursor") or 0)
            page = [obj_out(col, k, o) for k, o in items[start:start + limit]]
            if not items:
                note_gap("empty collections", col)
            out = {"objects": page} if page else {}
            if start + limit < len(items):
                out["cursor"] = str(start + limit)
            return out, f"list {col}: {len(page)}"
        if path.startswith("/v2/leaderboard/") and verb == "POST":  # write a record (sent after every raid)
            board = path.split("/")[3]
            score = int((body or {}).get("score", 0))
            state.setdefault("leaderboards", {})[board] = score
            save_state(state)
            return {"leaderboard_id": board, "owner_id": uid, "username": state["user"]["username"],
                    "score": str(score), "subscore": "0", "num_score": 1, "rank": "1",
                    "create_time": stamp(), "update_time": stamp()}, f"leaderboard {board} = {score}"
        if path.startswith("/v2/rpc/"):
            name = path.split("/")[3]
            arg = q.get("payload") if verb == "GET" else body
            if isinstance(arg, str):
                try:
                    arg = json.loads(arg)
                except ValueError:
                    pass
            res = rpc(name, arg)
            if res is None:
                note_gap("unknown rpcs", name)
                return {"payload": "{}"}, f"UNKNOWN rpc {name} body={json.dumps(arg)[:300]}"
            return {"payload": json.dumps(res)}, f"rpc {name}"
        if path == "/v2/tournament" and verb == "GET":  # the live list was empty too (capture): no tournaments
            return {}, "tournaments: none"
        note_gap("unhandled endpoints", f"{verb} {re.sub(r'[0-9a-f-]{32,36}', '<id>', path)}")
        return {}, f"UNHANDLED body={json.dumps(body)[:300]}"


def settle_ship(o):
    """Extracting in a ship, the client saves a ship item of its own making: a new id and name, and the row the raid was
    launched with, which for a ship with a stand-in interior is the wrong one (rivals.lua R.shipOption). So the first new
    ship item after going through a gate becomes the ship that went in, unchanged, or the ship you stole, with its real
    row. Only after a gate: any other new ship item (one you bought after quitting a raid) is what it says it is."""
    out = state.get("ship_out")
    if not out or not out.get("gate") or o["collection"] != "inventory" or "_Ship-" not in o.get("value", ""):
        return o
    state.pop("ship_out")
    if "item" in out:
        log(f"ship back from the raid: {o['key']} kept as {out['key']}")
        return {**o, "key": out["key"], "value": out["item"]}
    log(f"stolen ship saved as {out['row']}")
    return {**o, "value": re.sub(r"-[A-Za-z_]+_Ship-", f"-{out['row']}-", o["value"])}


# Saves with items on top of each other (#239, #240): three helmets in the Head slot, a drum mag and a rifle lying on a
# SMG in the stash. The game shows one item per slot or cell and the rest are invisible, but still there: a helmet you
# discard comes back as the next one in the slot, and items dropped onto hidden ones freeze or vanish, every launch.
# How the saves got that way isn't known yet (not reproduced). At startup the extras are moved to free stash space.
ITEM_SIZES = os.path.join(HERE, "..", "assets", "saves", "items.json")  # row -> w, h (tools/offline-audit/itemsizes.py)
STASH_ROWS = os.path.join(HERE, "..", "config", "stash_rows.txt")  # the save's stash rows (launcher/saves.py)
STASH_COLS, STASH_ROWS_DEFAULT, STASH_ROWS_MAX = 10, 15, 25
# Equipment slots that hold one item (pockets and the stash are grids; a number is a bag, rig or box item's own grid).
ONE_ITEM_SLOTS = {"Head", "Chest", "Legs", "Rig", "Bag", "Prim", "Sec", "Pistol", "Melee", "KeyCard", "Ship",
                  "GuildBadge"}
POCKETS, POCKET_SIDE = ("PocketLeft",), 2
# PocketRight is in the inventory, but the game never shows its grid: anything there is invisible and stuck (the mod
# put loot and ammo there in builds 10-14). It all goes to the stash.
HIDDEN_CONTAINERS = ("PocketRight",)


def item_fields(value):
    """An inventory object's item string as its fields (key, row, stack, condition, column, row, rotated, container,
    attachments...), or None."""
    try:
        return json.loads(value)["value"].split("-")
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def item_place(value):
    """What makes two items the same item in the same place: every field but the key (row, stack, condition, cell,
    rotation, container, attachments). None for anything that isn't a full item string."""
    f = item_fields(value)
    return "-".join(f[1:]) if f and len(f) >= 8 else None


def item_places(inv):
    """{item_place: key} for the inventory, the oldest key for each place."""
    out = {}
    for k, o in sorted(inv.items(), key=lambda kv: (kv[1].get("create_time", ""), kv[0])):
        p = item_place(o.get("value"))
        if p is not None:
            out.setdefault(p, k)
    out.pop(None, None)
    return out


# #370: after a space-gate extraction the game once wrote the stash's container contents again under new keys. Loot
# carried out of a raid can only sit in bags that went into the raid, and those left the stash at raid start, so a new
# item placed inside a container that stayed in the stash isn't loot. When a raid ends, the containers still in the stash
# are remembered; the first write of new items after that (the lobby saving ExtractedLoot) refuses new items placed in
# them. Later writes (vendors, moving things around) aren't checked. Expires after HOME_CONTAINERS_TTL seconds.
HOME_CONTAINERS_TTL = 1800


def mark_home_containers():
    """Remembers the containers in the stash as the raid ends. Call with the lock held."""
    inv = state["storage"].get("inventory", {})
    held = set()
    for o in inv.values():
        f = item_fields(o.get("value"))
        if f and len(f) >= 8:
            held.add(f[7])
    state["home_containers"] = {"keys": sorted(k for k in held if k in inv), "at": time.time()}


def home_container_of(value, home):
    """The stash container a new item claims to be in, if it is one that never went into the raid, else None."""
    f = item_fields(value)
    if f and len(f) >= 8 and f[7] in home:
        return f[7]
    return None


def twin_of(inv, key, value):
    """The key of another item exactly like this one in the same place (all fields but the key equal), or None."""
    p = item_place(value)
    if p is None:
        return None
    k = item_places({k: o for k, o in inv.items() if k != key}).get(p)
    return k


def drop_twins():
    """#370: removes items that are exact copies of an older item in the same place (a space-gate extraction once
    wrote a whole stash's container contents again under new keys). The oldest copy stays; a removed container's
    contents move into the one that stays, where they are compared again. Returns how many went."""
    inv = state["storage"].get("inventory", {})
    gone = 0
    while True:
        seen, twins = {}, []
        for k, o in sorted(inv.items(), key=lambda kv: (kv[1].get("create_time", ""), kv[0])):
            f = item_fields(o.get("value"))
            if not f or len(f) < 8:
                continue
            sig = "-".join(f[1:])
            if sig in seen:
                twins.append((k, seen[sig]))
            else:
                seen[sig] = k
        if not twins:
            return gone
        for k, keep in twins:
            inv.pop(k, None)
            gone += 1
            for co in inv.values():  # its contents go into the copy that stays
                g = item_fields(co.get("value"))
                if g and len(g) >= 8 and g[7] == k:
                    g[7] = keep
                    v = json.loads(co["value"])
                    v["value"] = "-".join(g)
                    co["value"] = json.dumps(v, indent="	")


def repair_inventory():
    """Moves items that share an equipment slot, or overlap in the stash, to free stash space (the newest one keeps
    the slot). Returns what it moved. Call with the lock held, or before the server starts."""
    inv = state["storage"].get("inventory", {})
    try:
        with open(ITEM_SIZES, encoding="utf-8") as f:
            sizes = json.load(f)
    except (OSError, ValueError):
        sizes = {}
    try:
        with open(STASH_ROWS, encoding="utf-8") as f:
            rows = min(STASH_ROWS_MAX, int(f.read().strip()))
    except (OSError, ValueError):
        rows = STASH_ROWS_DEFAULT
    items = []  # [key, fields, update_time]
    for key, o in inv.items():
        try:
            f = json.loads(o["value"])["value"].split("-")
            int(f[4]), int(f[5])
        except (ValueError, KeyError, IndexError, TypeError):
            continue
        if len(f) >= 8:
            items.append([key, f, o.get("update_time", "")])

    def footprint(f):
        sz = sizes.get(f[1]) or {"w": 1, "h": 1}
        w, h = (sz["w"], sz["h"]) if f[6] == "0" else (sz["h"], sz["w"])
        return [(x, y) for x in range(int(f[4]), int(f[4]) + w) for y in range(int(f[5]), int(f[5]) + h)]

    misplaced = []
    by_slot = {}
    for it in items:
        if it[1][7] in ONE_ITEM_SLOTS:
            by_slot.setdefault(it[1][7], []).append(it)
    for held in by_slot.values():
        held.sort(key=lambda it: it[2])
        misplaced += held[:-1]  # the newest one stays (the one the game shows)
    taken = {}
    for it in sorted((it for it in items if it[1][7] == "Stash"), key=lambda it: it[2]):  # older items keep their place
        cells = footprint(it[1])
        if any(c in taken for c in cells) or any(x >= STASH_COLS for x, _ in cells):
            misplaced.append(it)
        else:
            taken.update((c, it[0]) for c in cells)
    # The pockets (2 x 2 each): the mod's ammo for a soldier's gun used to lay four 2-cell stacks (7.62, .30-06, 5.56,
    # 7.62x54R) across the left pocket's four cells, on top of each other.
    for pocket in POCKETS:
        held = {}
        for it in sorted((it for it in items if it[1][7] == pocket), key=lambda it: it[2]):
            cells = footprint(it[1])
            if any(c in held for c in cells) or any(x >= POCKET_SIDE or y >= POCKET_SIDE for x, y in cells):
                misplaced.append(it)
            else:
                held.update((c, it[0]) for c in cells)
    misplaced += [it for it in items if it[1][7] in HIDDEN_CONTAINERS]
    moved = []
    for key, f, _ in misplaced:
        f = list(f)
        f[6] = "0"
        for rot in ("0", "1"):
            f[6] = rot
            spot = next(((x, y) for y in range(rows) for x in range(STASH_COLS)
                         if all(c not in taken and c[0] < STASH_COLS and c[1] < rows
                                for c in footprint(f[:4] + [str(x), str(y)] + f[6:]))), None)
            if spot:
                break
        if not spot:
            log(f"inventory repair: no room in the stash for {f[1]} ({key}), left where it is")
            continue
        was = f"{f[7]} {f[4]},{f[5]}"
        f[4], f[5], f[7] = str(spot[0]), str(spot[1]), "Stash"
        taken.update((c, key) for c in footprint(f))
        o = inv[key]
        v = json.loads(o["value"])
        v["value"] = "-".join(f)
        v["equip"] = False
        o["value"] = json.dumps(v, indent="\t")
        o["update_time"] = stamp()
        o["version"] = uuid.uuid4().hex
        moved.append(f"{f[1]} ({key}) {was} -> stash {spot[0]},{spot[1]}")
    if moved:
        shutil.copyfile(STATE, STATE.replace("state.json", "state.before-repair.json"))
        save_state(state)
        log(f"inventory repair: {len(moved)} item(s) on top of others or out of sight moved: " + "; ".join(moved))
    return moved


def return_unfinished_raid(why):
    """Gear you brought into a raid that ended neither by extraction nor by death (QUIT GAME, Alt+F4, a crash, leaving
    through the menu) goes back to the stash (issue #49: offline there's no one to exploit this against, and it keeps
    a softlock or crash from costing your kit). Call with the lock held, or before the server starts."""
    out = state.get("raid_out")
    if not out:
        return
    state.pop("raid_out")
    if out.get("ended"):
        save_state(state)
        return
    inv = state["storage"].setdefault("inventory", {})
    back = [k for k, item in out["items"].items() if k not in inv]
    for k in back:
        inv[k] = out["items"][k]
    if any("_Ship-" in out["items"][k]["value"] for k in back):
        state.pop("ship_out", None)  # the ship you took in is home again
    save_state(state)
    log(f"raid ended without an extraction or death ({why}): {back} back in the stash")


def take_file(path):
    """The file's text, once, or None."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read().strip()
        os.remove(path)
    except OSError:
        return None  # still being written
    return text


def watch_checkout():
    """Raid start, the live raid server's part: the equipped items go into the raid and leave the stash, so they are
    lost on death. On extraction the client saves what it carried out as new items (the lobby does that after Play,
    from SIGISGameInstanceNakama.ExtractedLoot). The PvEDirector mod writes the ids it loaded to checkout.txt."""
    while True:
        time.sleep(1)
        gifts = take_file(GIFTS_IN)
        with lock:
            flush_coverage()
            if gifts:
                added = add_gifts([line.strip() for line in gifts.splitlines() if line.strip()])
                if added:
                    save_state(state)
                    log(f"gifts: {added} in the gift box (shown at the next login)")
        row = take_file(SHIP_STOLEN)
        lost = take_file(SHIP_LOST)
        gate = take_file(SHIP_GATE)
        if lost is not None or gate:
            with lock:  # dead, out on foot / by pod, or in a space gate: the raid ended the game's way
                if state.get("raid_out"):
                    state["raid_out"]["ended"] = lost is not None or gate == "1"
                if lost is not None or gate == "1":
                    mark_home_containers()
                save_state(state)
        if lost is not None or row:
            with lock:
                state.pop("ship_out", None)
                if row:
                    state["ship_out"] = {"row": row}
                save_state(state)
            log(f"ship in play: stolen {row}" if row else "ship lost")
        if gate and state.get("ship_out"):
            with lock:
                state["ship_out"]["gate"] = gate == "1"
                save_state(state)
            log(f"ship in the gate: {gate == '1'}")
        if not os.path.exists(CHECKOUT):
            continue
        try:
            with open(CHECKOUT, encoding="utf-8") as f:
                ids = [line.strip() for line in f if line.strip()]
            os.remove(CHECKOUT)
        except OSError:
            continue  # still being written
        with lock:
            return_unfinished_raid("a new raid started")
            save_state(state)  # the copy below is what to restore from if a raid ends without an extraction
            shutil.copyfile(STATE, STATE.replace("state.json", "state.before-last-raid.json"))
            # the crew too (the mod's crew.lua: hired crewmates, who dies in a raid), so Undo last raid brings them back
            crew = os.path.join(os.path.dirname(STATE), "crew.lua")
            crew_copy = os.path.join(os.path.dirname(STATE), "crew.before-last-raid.lua")
            if os.path.exists(crew):
                shutil.copyfile(crew, crew_copy)
            elif os.path.exists(crew_copy):
                os.remove(crew_copy)
            inv = state["storage"].get("inventory", {})
            taken = {i: inv.pop(i) for i in ids if i in inv}
            gone = list(taken)
            state.pop("ship_out", None)
            for key, item in taken.items():
                if "_Ship-" in item["value"]:
                    state["ship_out"] = {"key": key, "item": item["value"]}
            state["raid_out"] = {"items": taken, "ended": False}
            save_state(state)
        log(f"raid start: took {gone} out of the stash (missing: {sorted(set(ids) - set(gone))})")


def main():
    global state
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7350)
    ap.add_argument("--dir", help="keep this player's save and files in this folder (a co-op joiner)")
    ap.add_argument("--name", help="display name of a new account in --dir")
    args = ap.parse_args()
    port = args.port
    if args.dir:
        use_dir(os.path.abspath(args.dir), args.name)
    rotate_log()
    state = load_state()
    return_unfinished_raid("the stand-in started")
    before = json.dumps(state)
    twins = drop_twins()
    if twins:  # (a new name each time: an earlier backup is never overwritten)
        write_atomic(STATE.replace("state.json", time.strftime("state.before-twins-%Y%m%d-%H%M%S.json")), before)
        save_state(state)
        log(f"inventory: {twins} duplicate item(s) removed (exact copies of an item in the same place, #370)")
    repair_inventory()
    log(f"listening on 127.0.0.1:{port} as {state['user']['display_name']} "
        f"({len(state['storage'].get('inventory', {}))} stash items)")
    threading.Thread(target=watch_checkout, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    # The launcher starts this hidden, so a crash at startup (port taken, state.json unreadable, no write access) would
    # be invisible: write it where scripts/launch-helpers.ps1 reads it, so PLAY can say why (issue #75).
    err = os.path.join(HERE, "standin_err.log")
    try:
        if os.path.exists(err):
            os.remove(err)
    except OSError:
        pass
    try:
        main()
    except Exception:
        try:
            import traceback
            with open(err, "w", encoding="utf-8") as f:
                traceback.print_exc(file=f)  # its last line is "SomeError: message", the one the launcher shows
        except OSError:
            pass
        raise
