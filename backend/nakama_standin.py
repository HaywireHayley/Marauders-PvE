"""Local stand-in for the game's Nakama backend (marauderea2.us-east1.nakamacloud.io), for offline play.

    python -I nakama_standin.py [--port 7350]

pvenet.dll points the game's Nakama connection here (plain HTTP on 127.0.0.1) while bridge/offline_backend
exists. Implements the REST endpoints the client was seen using (see NOTES.md, "Backend capture"):
authenticate, account, storage list/read/write/delete, the RPCs, tournaments. It also does the raid server's stash
part (loadout.json out, checkout.txt in; see write_loadout / watch_checkout). State lives in state.json next to
this file; the first run builds it from capture/seed/account.json (scripts/capture_seed.py). Every request is
logged to server.log, and unknown endpoints answer {} so they show up there instead of breaking the client.
"""
import argparse, base64, json, os, re, shutil, threading, time, uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "state.json")
LOG = os.path.join(HERE, "server.log")
LOADOUT = os.path.join(HERE, "loadout.json")  # equipped items, read by the PvEDirector mod at raid start
CHECKOUT = os.path.join(HERE, "checkout.txt")  # item ids taken into a raid, written by the PvEDirector mod
SHIP_STOLEN = os.path.join(HERE, "ship_stolen.txt")  # table row of a ship you took the helm of, written by the mod
SHIP_LOST = os.path.join(HERE, "ship_lost.txt")  # you died: the ship you took in isn't coming back
SHIP_GATE = os.path.join(HERE, "ship_gate.txt")  # written by the mod: 1 in a space gate, 0 back out of it
# The starting account: the private capture of a real account when this PC has one (capture/ is never shared),
# else seed.json, the anonymous account that releases and the shared repository ship.
SEED = os.path.join(HERE, "..", "capture", "seed", "account.json")
if not os.path.exists(SEED):
    SEED = os.path.join(HERE, "seed.json")
PUBLIC_USER = "00000000-0000-0000-0000-000000000000"
CHEAT_CASH = 999999999
lock = threading.Lock()


def stamp(t=None):
    return datetime.fromtimestamp(t or time.time(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(time.strftime("%H:%M:%S ") + msg + "\n")


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
    return {"user": user, "storage": storage, "master": {k: master[k] for k in ("messages", "prestige", "raidertime")
                                                         if k in master}}


def load_state():
    if os.path.exists(STATE):
        s = json.load(open(STATE, encoding="utf-8"))
        write_loadout(s)
        return s
    s = new_state()
    save_state(s)
    log("built state.json from the capture seed")
    return s


def save_state(s):
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, indent=1)
    os.replace(tmp, STATE)
    write_loadout(s)


def write_loadout(s):
    """The equipped inventory items, as the raid server's SIGISPlayerController::Server_AwsN_EquippedItemsReturned
    takes them: a JSON array of storage objects whose value is {"equip":true,"value":"<item string>"}. There is no
    raid server offline; the PvEDirector mod feeds this file to that function at raid start."""
    items = []
    for o in s["storage"].get("inventory", {}).values():
        try:
            v = json.loads(o["value"])
        except ValueError:
            continue
        if isinstance(v, dict) and v.get("equip"):
            items.append({"value": v})
    tmp = LOADOUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(items, f, separators=(",", ":"))
    os.replace(tmp, LOADOUT)


state = None


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


def user_record():
    u = dict(state["user"])
    u["online"] = True
    return u


def rpc(name, body):
    if name == "masterstartfunction":
        m = dict(state["master"])
        m.update({"cosequip": collection_kv("cosequipped"), "gifts": collection_kv("gifts"),
                  "playerstats": collection_kv("playerstats"), "servertime": str(int(time.time()))})
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
        st = state["storage"]
        uid = state["user"]["id"]
        if path.startswith("/v2/account/authenticate/") or path == "/v2/account/session/refresh":
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
            acks = []
            for o in (body or {}).get("objects", []):
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
                acks.append({"collection": o["collection"], "key": o["key"], "version": col[o["key"]]["version"],
                             "user_id": uid, "create_time": col[o["key"]]["create_time"], "update_time": now})
            save_state(state)
            return {"acks": acks}, f"wrote {[(a['collection'], a['key']) for a in acks]}"
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
                return {"payload": "{}"}, f"UNKNOWN rpc {name} body={json.dumps(arg)[:300]}"
            return {"payload": json.dumps(res)}, f"rpc {name}"
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
        row = take_file(SHIP_STOLEN)
        lost = take_file(SHIP_LOST)
        gate = take_file(SHIP_GATE)
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
            save_state(state)  # the copy below is what to restore from if a raid ends without an extraction
            shutil.copyfile(STATE, STATE.replace("state.json", "state.before-last-raid.json"))
            inv = state["storage"].get("inventory", {})
            taken = {i: inv.pop(i) for i in ids if i in inv}
            gone = list(taken)
            state.pop("ship_out", None)
            for key, item in taken.items():
                if "_Ship-" in item["value"]:
                    state["ship_out"] = {"key": key, "item": item["value"]}
            save_state(state)
        log(f"raid start: took {gone} out of the stash (missing: {sorted(set(ids) - set(gone))})")


def main():
    global state
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7350)
    port = ap.parse_args().port
    state = load_state()
    log(f"listening on 127.0.0.1:{port} as {state['user']['display_name']} "
        f"({len(state['storage'].get('inventory', {}))} stash items)")
    threading.Thread(target=watch_checkout, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
