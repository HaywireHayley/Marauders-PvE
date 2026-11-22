"""The launcher's SETTINGS page (#324): every F3 setting, edited before a raid, plus presets you save, share and load.

The mod owns the settings. Each start it writes config/settings_schema.json (tuning.lua writeSchema): the tabs, each
row's id, label, range, step, default and help, and the built-in difficulty presets. The values themselves live where
the F3 menu keeps them, so the launcher and F3 always agree:
  config/ai_tuning.txt    id=value, only the settings changed from their defaults (read when the game starts)
  config/ai_presets.txt   "[name]" then id=value lines: your own presets (F3's "Saved setups")
A shared preset is a small text file in the same form as one ai_presets.txt entry, with a header line.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "config")
SCHEMA = os.path.join(CONFIG, "settings_schema.json")
VALUES = os.path.join(CONFIG, "ai_tuning.txt")
PRESETS = os.path.join(CONFIG, "ai_presets.txt")
SHARE_HEADER = "# Marauders Offline settings preset"


def load_schema(path=None):
    """The settings the mod described, or None before the game has run once with this build."""
    try:
        with open(path or SCHEMA, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    tabs = [t for t in data.get("tabs", []) if t.get("rows")]
    for p in data.get("presets", []):
        if not isinstance(p.get("values"), dict):
            p["values"] = {}  # (an empty Lua table is written as [])
    return {"tabs": tabs, "presets": data.get("presets", [])} if tabs else None


def rows(schema):
    return [r for t in schema["tabs"] for r in t["rows"]]


def _num(text):
    try:
        v = float(text)
    except ValueError:
        return None
    return int(v) if v.is_integer() else v


def read_values(path=None):
    """id -> value for the settings changed from their defaults."""
    out = {}
    try:
        with open(path or VALUES, encoding="utf-8") as f:
            for line in f:
                key, sep, val = line.strip().partition("=")
                v = _num(val) if sep else None
                if key and v is not None:
                    out[key] = v
    except OSError:
        pass
    return out


def clamp(row, v):
    v = max(row["min"], min(row["max"], v))
    step = row.get("step") or 0
    if step > 0:
        v = row["min"] + round((v - row["min"]) / step) * step
        v = max(row["min"], min(row["max"], v))
    v = round(v, 4)
    return int(v) if float(v).is_integer() else v


def same(row, a, b):
    return abs(a - b) < max(row.get("step") or 0, 1e-9) / 2


def write_values(schema, values, path=None):
    """Saves only what differs from the defaults, like the F3 menu does. Ids the schema doesn't know are kept as they
    were (a setting from a newer or older build)."""
    known = {r["id"]: r for r in rows(schema)}
    lines = []
    for key, v in values.items():
        r = known.get(key)
        if r is None:
            lines.append(f"{key}={v}")
        elif not same(r, v, r["default"]):
            lines.append(f"{key}={clamp(r, v)}")
    _write(path or VALUES, "".join(line + "\n" for line in lines))


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def read_presets(path=None):
    """Your own presets, in file order: [{"name", "values"}]."""
    out, cur = [], None
    try:
        with open(path or PRESETS, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    cur = {"name": line[1:-1], "values": {}}
                    out.append(cur)
                elif cur is not None and "=" in line and not line.startswith("#"):
                    key, _, val = line.partition("=")
                    v = _num(val)
                    if v is not None:
                        cur["values"][key] = v
    except OSError:
        pass
    return out


def write_presets(presets, path=None):
    text = ""
    for p in presets:
        text += f"[{p['name']}]\n" + "".join(f"{k}={v}\n" for k, v in p["values"].items())
    _write(path or PRESETS, text)


def clean_name(name):
    """One line, no square brackets (they mark a preset in the file), not empty."""
    name = " ".join(name.replace("[", "(").replace("]", ")").split())
    return name[:40]


def export_preset(preset, path):
    _write(path, f"{SHARE_HEADER}\n[{preset['name']}]\n" + "".join(f"{k}={v}\n" for k, v in preset["values"].items()))


def import_preset(path):
    """A shared preset file (or any ai_presets.txt): its first preset, or None."""
    found = read_presets(path)
    if not found:
        return None
    p = found[0]
    p["name"] = clean_name(p["name"]) or "Imported"
    return p


def changed_count(schema, values):
    known = {r["id"]: r for r in rows(schema)}
    return sum(1 for k, v in values.items() if k in known and not same(known[k], v, known[k]["default"]))
