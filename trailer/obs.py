"""Drive OBS recording over obs-websocket (stdlib only).
  python trailer/obs.py start | stop | status
The password is read from OBS's own websocket config, so nothing secret lives in the repo."""
import base64, hashlib, json, os, socket, struct, sys

CFG = os.path.expandvars(r"%APPDATA%\obs-studio\plugin_config\obs-websocket\config.json")


def ws_connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
               "Sec-WebSocket-Protocol: obswebsocket.json\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    if b" 101 " not in buf.split(b"\r\n")[0]:
        raise SystemExit("websocket handshake failed: " + buf.split(b"\r\n")[0].decode())
    return s, buf.split(b"\r\n\r\n", 1)[1]


class WS:
    def __init__(self, port):
        self.s, self.buf = ws_connect(port)

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise SystemExit("OBS closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        b1, b2 = self._read(2)
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        data = self._read(n)
        if b1 & 0x0F == 8:
            raise SystemExit("OBS closed the connection: " + data[2:].decode(errors="replace"))
        return json.loads(data)

    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
        self.s.sendall(head + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))


def connect():
    cfg = json.load(open(CFG))
    try:
        ws = WS(cfg.get("server_port", 4455))
    except OSError:
        raise SystemExit("OBS isn't running (or its websocket server is off)")
    hello = ws.recv()["d"]
    ident = {"rpcVersion": 1}
    auth = hello.get("authentication")
    if auth:
        secret = base64.b64encode(hashlib.sha256((cfg["server_password"] + auth["salt"]).encode()).digest())
        ident["authentication"] = base64.b64encode(hashlib.sha256(secret + auth["challenge"].encode()).digest()).decode()
    ws.send({"op": 1, "d": ident})
    ws.recv()
    return ws


def call(ws, req, data=None):
    ws.send({"op": 6, "d": {"requestType": req, "requestId": req, "requestData": data or {}}})
    while True:
        m = ws.recv()
        if m["op"] == 7 and m["d"]["requestId"] == req:
            st = m["d"]["requestStatus"]
            if not st["result"]:
                raise SystemExit(f"{req} failed: {st.get('comment', st['code'])}")
            return m["d"].get("responseData", {})


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    ws = connect()
    if cmd == "start":
        # no mouse cursor in the footage: every game capture source, every time (a new source defaults to capturing it)
        for i in call(ws, "GetInputList", {"inputKind": "game_capture"})["inputs"]:
            call(ws, "SetInputSettings", {"inputName": i["inputName"], "inputSettings": {"capture_cursor": False}})
        call(ws, "StartRecord")
        print("recording")
    elif cmd == "stop":
        print("saved", call(ws, "StopRecord").get("outputPath"))
    elif cmd == "scenes":
        print("current:", call(ws, "GetCurrentProgramScene")["currentProgramSceneName"])
        print("all:", [s["sceneName"] for s in call(ws, "GetSceneList")["scenes"]])
    elif cmd == "scene":
        call(ws, "SetCurrentProgramScene", {"sceneName": sys.argv[2]})
        print("scene", sys.argv[2])
    elif cmd == "desk":
        # a scene capturing the whole primary monitor (for browser footage), cursor off; made once, then reused
        name = "Desktop capture"
        if name not in [s["sceneName"] for s in call(ws, "GetSceneList")["scenes"]]:
            call(ws, "CreateScene", {"sceneName": name})
            call(ws, "CreateInput", {"sceneName": name, "inputName": "Monitor", "inputKind": "monitor_capture",
                                     "inputSettings": {"capture_cursor": False}})
        # a new monitor source captures nothing until a display is picked: take the primary one
        items = call(ws, "GetInputPropertiesListPropertyItems", {"inputName": "Monitor", "propertyName": "monitor_id"})
        mon = [i for i in items["propertyItems"] if i["itemEnabled"]]
        mon = next((i for i in mon if "Primary" in i["itemName"]), mon[0] if mon else None)
        if mon:
            call(ws, "SetInputSettings", {"inputName": "Monitor", "inputSettings": {"monitor_id": mon["itemValue"], "method": 1,
                                                                                    "capture_cursor": False}})
        call(ws, "SetCurrentProgramScene", {"sceneName": name})
        print("scene", name)
    else:
        r = call(ws, "GetRecordStatus")
        s = call(ws, "GetStats")
        print(f"recording={r['outputActive']} {r.get('outputTimecode')}  "
              f"render-lag={s['renderSkippedFrames']}/{s['renderTotalFrames']}  "
              f"encode-skip={s['outputSkippedFrames']}/{s['outputTotalFrames']}  fps={s['activeFps']:.1f}")


if __name__ == "__main__":
    main()
