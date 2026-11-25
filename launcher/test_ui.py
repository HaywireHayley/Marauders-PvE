"""Headless checks of the launcher window (issue #147): thread-safe updates, fonts, keyboard, dialogs and display scaling.
Opens real windows for a moment, on a temporary save folder: your saves and settings are never touched.

    python launcher/test_ui.py [screenshot folder]     (Windows; screenshots only when a folder is given)
"""
import ctypes
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv.pop(1) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None
spec = importlib.util.spec_from_loader("launcher", importlib.machinery.SourceFileLoader("launcher", os.path.join(HERE, "launcher.pyw")))
L = importlib.util.module_from_spec(spec)
spec.loader.exec_module(L)
saves = L.saves

TMP = tempfile.mkdtemp(prefix="pve-ui-test-")
saves.SAVES = os.path.join(TMP, "saves")
saves.LIVE = os.path.join(TMP, "state.json")
saves.RAID_COPY = os.path.join(TMP, "state.before-last-raid.json")
saves.CREW = os.path.join(TMP, "crew.lua")
saves.CREW_RAID_COPY = os.path.join(TMP, "crew.before-last-raid.lua")
saves.ACTIVE = os.path.join(TMP, "active_save.txt")
saves.STASH_ROWS = os.path.join(TMP, "stash_rows.txt")
for name in ("FEMALE_SETTING", "FEMALE_SHARE", "WINDOW_SETTING", "SKIP_INTRO_SETTING", "UNLOCK_LOOKS_SETTING",
             "MINIMIZE_SETTING", "UPDATE_CHECK_SETTING", "RAID_CONDITION", "COOP_HOST", "COOP_JOIN", "COOP_LAST"):
    setattr(L, name, os.path.join(TMP, name.lower() + ".txt"))
# Settings page (#324): a small schema and the files it edits, all in the temporary folder.
L.settings.SCHEMA = os.path.join(TMP, "settings_schema.json")
L.settings.VALUES = os.path.join(TMP, "ai_tuning.txt")
L.settings.PRESETS = os.path.join(TMP, "ai_presets.txt")
with open(L.settings.SCHEMA, "w", encoding="utf-8") as f:
    f.write('{"version":1,"tabs":[{"name":"Aim","rows":[{"id":"Aim:MISS","label":"Miss rate","min":0,"max":2,"step":0.05,'
            '"default":0.35,"help":"How often they miss"},{"id":"Aim:REACT","label":"Reaction","min":0,"max":3,"step":0.1,'
            '"default":1,"help":""}]},{"name":"How many","rows":[{"id":"Spawns:CIV","label":"Civilians","min":0,"max":20,'
            '"step":1,"default":6,"help":"0 turns them off"}]}],"presets":[{"name":"Easy","values":{"Aim:MISS":0.55}},'
            '{"name":"Normal","values":[]}]}')
with open(L.UPDATE_CHECK_SETTING, "w") as f:
    f.write("off\n")  # no network in tests
os.makedirs(saves.SAVES)
FIRST = saves.create("Alpha", False)
SECOND = saves.create("Bravo", True, True)


def grab(window, name):
    """A screenshot of one window (PrintWindow), when a screenshot folder was given."""
    if not OUT:
        return
    from PIL import Image
    window.update()
    hwnd = ctypes.windll.user32.GetAncestor(window.winfo_id(), 2)
    w, h = window.winfo_width() + 40, window.winfo_height() + 80
    gdi, user = ctypes.windll.gdi32, ctypes.windll.user32
    dc = user.GetDC(hwnd)
    mem = gdi.CreateCompatibleDC(dc)
    bmp = gdi.CreateCompatibleBitmap(dc, w, h)
    gdi.SelectObject(mem, bmp)
    user.PrintWindow(hwnd, mem, 2)
    raw = ctypes.create_string_buffer(w * h * 4)
    info = (ctypes.c_uint32 * 10)(40, w, -h, 0x200001, 0, 0, 0, 0, 0, 0)
    gdi.GetDIBits(mem, bmp, 0, h, raw, info, 0)
    os.makedirs(OUT, exist_ok=True)
    Image.frombuffer("RGBA", (w, h), raw, "raw", "BGRA", 0, 1).convert("RGB").save(os.path.join(OUT, name))


def settle(app, seconds=0.3):
    end = time.time() + seconds
    while time.time() < end:
        app.update()
        time.sleep(0.02)


def dialogs(app):
    return [w for w in app.winfo_children() if isinstance(w, L.Dialog)]


class Fonts(unittest.TestCase):
    def test_bahnschrift_first(self):
        self.assertEqual(L.pick_family(["Arial", "bahnschrift", "Segoe UI"]), "bahnschrift")

    def test_fallbacks(self):
        self.assertEqual(L.pick_family(["DejaVu Sans", "Liberation Sans"]), "DejaVu Sans")
        self.assertEqual(L.pick_family([]), "TkDefaultFont")


class Kits(unittest.TestCase):
    """saves.buy_kit (#385): all or nothing, on throwaway saves in the temporary folder."""

    def setUp(self):
        self.sid = saves.create(f"Kit {time.time()}", False)
        self.kit = saves.kits()[0]

    def cash(self):
        return saves._summary(saves._read(os.path.join(saves.SAVES, self.sid, "state.json")))["cash"]

    def items(self):
        return len(saves._read(os.path.join(saves.SAVES, self.sid, "state.json"))["storage"]["inventory"])

    def test_every_kit_row_is_a_real_item_and_priced(self):
        items, prices = saves._read(saves.ITEMS), saves.gear_prices()
        for k in saves.kits():
            self.assertGreater(k["price"], 0)
            for row, _n in k["items"]:
                self.assertIn(row, items, k["name"])
                self.assertTrue(row in prices or items[row]["type"] == 18, f"{row} has no gear.lua price")

    def test_enough_cash(self):
        saves.set_cash(self.sid, self.kit["price"] + 5)
        before = self.items()
        self.assertIsNone(saves.buy_kit(self.sid, self.kit))
        self.assertEqual(self.cash(), 5)
        self.assertGreater(self.items(), before)

    def test_short_cash(self):
        saves.set_cash(self.sid, self.kit["price"] - 1)
        before = self.items()
        self.assertIn("Not enough cash", saves.buy_kit(self.sid, self.kit))
        self.assertEqual(self.cash(), self.kit["price"] - 1)
        self.assertEqual(self.items(), before)

    def test_full_stash(self):
        while saves.give(self.sid, "9mmAmmo", 600):
            pass
        saves.set_cash(self.sid, self.kit["price"] * 2)
        before = self.items()
        self.assertIn("room", saves.buy_kit(self.sid, self.kit))
        self.assertEqual(self.cash(), self.kit["price"] * 2)
        self.assertEqual(self.items(), before)

    def test_save_in_play(self):
        saves.set_cash(self.sid, self.kit["price"])
        with open(saves.ACTIVE, "w") as f:
            f.write(self.sid)
        try:
            self.assertIn("in play", saves.buy_kit(self.sid, self.kit))
        finally:
            os.remove(saves.ACTIVE)
        self.assertEqual(self.cash(), self.kit["price"])


# A crew file as hire.lua's ser() writes it (a hired crewmate with a rolled kit, a recruit in the pool).
CREW_FILE = '''-- Your crew and the recruit pool (hire.lua). Delete this file for a fresh pool and no crew.
return {
  enabled = true,
  nextId = 7,
  crew = {
    [1] = {
      id = 3,
      name = "Noor \\"Ace\\"",
      level = 2,
      aimRoll = -0.125,
      bring = true,
      kit = {
        gun = {
          [1] = "StenSMG",
          [2] = 1400,
          [3] = "9mmAmmo"
        },
        chest = "PouchRig"
      }
    }
  },
  pool = {
    [1] = {
      id = 7,
      name = "Kip",
      level = 1
    }
  }
}
'''


class CrewGear(unittest.TestCase):
    """saves.crew_gear / set_crew_gear (#418): stash items moved onto a hired crewmate and back, all or nothing."""

    def setUp(self):
        self.sid = saves.create(f"Crew {time.time()}", False)
        with open(saves._crew_path(self.sid), "w", encoding="utf-8") as f:
            f.write(CREW_FILE)
        for row in ("Mat49Rifle", "BABeret", "SackBag"):
            self.assertEqual(saves.give(self.sid, row, 1), 1)

    def stash(self):
        return sorted(saves._stash_entries(saves._read(os.path.join(saves.SAVES, self.sid, "state.json"))).values())

    def pick(self, slot, row):
        return next(k for k, r in saves.crew_gear(self.sid)["stash"][slot] if r == row)

    def test_reader_round_trips_what_hire_lua_writes(self):
        data = saves._lua_load(CREW_FILE)
        self.assertEqual(data["crew"][1]["name"], 'Noor "Ace"')
        self.assertEqual(data["crew"][1]["kit"]["gun"], {1: "StenSMG", 2: 1400, 3: "9mmAmmo"})
        self.assertEqual(data["crew"][1]["aimRoll"], -0.125)
        self.assertEqual(saves._lua_load("return " + saves._lua_dump(data)), data)

    def test_listing_filters_by_slot(self):
        g = saves.crew_gear(self.sid)
        self.assertEqual([c["name"] for c in g["crew"]], ['Noor "Ace"'])
        self.assertIn("Mat49Rifle", [r for _, r in g["stash"]["gun"]])
        self.assertIn("BABeret", [r for _, r in g["stash"]["helmet"]])
        self.assertNotIn("BABeret", [r for _, r in g["stash"]["gun"]])
        self.assertIn("SackBag", [r for _, r in g["stash"]["bag"]])

    def test_equip_takes_from_the_stash_and_back_returns(self):
        before = self.stash()
        self.assertIsNone(saves.set_crew_gear(self.sid, 3, {"gun": self.pick("gun", "Mat49Rifle"),
                                                             "helmet": self.pick("helmet", "BABeret")}))
        self.assertNotIn("Mat49Rifle", self.stash())
        self.assertNotIn("BABeret", self.stash())
        r = saves._read_crew(self.sid)["crew"][1]
        self.assertEqual(r["gear"], {"gun": "Mat49Rifle", "helmet": "BABeret"})
        self.assertEqual(r["kit"]["chest"], "PouchRig", "the rest of the record is kept")
        self.assertEqual(saves._read_crew(self.sid)["pool"][1]["name"], "Kip")
        self.assertIsNone(saves.set_crew_gear(self.sid, 3, {"gun": None, "helmet": None}))
        self.assertEqual(self.stash(), before)
        self.assertNotIn("gear", saves._read_crew(self.sid)["crew"][1])

    def test_swapping_returns_the_old_piece(self):
        saves.give(self.sid, "Mat49Rifle", 1)
        guns = saves.crew_gear(self.sid)["stash"]["gun"]
        self.assertIsNone(saves.set_crew_gear(self.sid, 3, {"gun": guns[0][0]}))
        self.assertIsNone(saves.set_crew_gear(self.sid, 3, {"gun": self.pick("gun", "Mat49Rifle")}))
        self.assertEqual(self.stash().count("Mat49Rifle"), 1)

    def test_refusals_change_nothing(self):
        key = self.pick("gun", "Mat49Rifle")
        with open(saves.ACTIVE, "w") as f:
            f.write(self.sid)
        try:
            self.assertIn("in play", saves.set_crew_gear(self.sid, 3, {"gun": key}))
        finally:
            os.remove(saves.ACTIVE)
        self.assertIn("isn't in", saves.set_crew_gear(self.sid, 99, {"gun": key}))
        self.assertIn("isn't in the stash", saves.set_crew_gear(self.sid, 3, {"gun": self.pick("helmet", "BABeret")}))
        self.assertIn("Mat49Rifle", self.stash())
        self.assertNotIn("gear", saves._read_crew(self.sid)["crew"][1])

    def test_no_room_to_return_changes_nothing(self):
        self.assertIsNone(saves.set_crew_gear(self.sid, 3, {"gun": self.pick("gun", "Mat49Rifle")}))
        while saves.give(self.sid, "9mmAmmo", 600):
            pass
        self.assertIn("room", saves.set_crew_gear(self.sid, 3, {"gun": None}))
        self.assertEqual(saves._read_crew(self.sid)["crew"][1]["gear"], {"gun": "Mat49Rifle"})

    def test_no_crew_file(self):
        self.assertIsNone(saves.crew_gear(saves.create(f"Nobody {time.time()}", False)))


@unittest.skipUnless(os.name == "nt", "the launcher window is Windows-only")
class Window(unittest.TestCase):
    def setUp(self):
        self.app = L.App()
        self.app.select(FIRST)
        settle(self.app)

    def tearDown(self):
        for d in dialogs(self.app):
            d.destroy()
        self.app.destroy()

    def test_crew_gear_dialog_moves_a_stash_item_onto_a_crewmate(self):
        sid = saves.create(f"Crew dialog {time.time()}", False)
        with open(saves._crew_path(sid), "w", encoding="utf-8") as f:
            f.write(CREW_FILE)
        saves.give(sid, "BABeret", 1)
        self.app.refresh()
        self.app.select(sid)
        settle(self.app)
        self.app.show_crew_gear()
        settle(self.app)
        d = dialogs(self.app)[0]
        grab(d, "ui_crew_gear_hired.png")
        menus = [w for w in self._all(d) if isinstance(w, L.tk.OptionMenu)]
        self.assertEqual(len(menus), len(saves.CREW_SLOTS))
        helmet = menus[saves.CREW_SLOTS.index("helmet")]
        helmet["menu"].invoke("BABeret")
        apply = next(w for w in self._all(d) if isinstance(w, L.Button) and "APPLY" in str(w.cget("text")))
        apply.press()
        settle(self.app)
        self.assertEqual(saves._read_crew(sid)["crew"][1]["gear"], {"helmet": "BABeret"})
        d.destroy()

    def test_font_is_installed(self):
        family = L.font(12)[0].replace(" SemiBold", "").replace(" Bold", "")
        self.assertIn(family.lower(), [f.lower() for f in L.tkfont.families()] + ["tkdefaultfont"])

    def test_background_threads_update_through_the_queue(self):
        main = threading.get_ident()
        seen = []

        def work():
            self.app.ui(lambda: (seen.append(threading.get_ident()), self.app.say("from a worker")))
        threading.Thread(target=work).start()
        end = time.time() + 3
        while not seen and time.time() < end:
            settle(self.app, 0.1)
        self.assertEqual(seen, [main])  # ran on the main thread, not the worker's
        self.assertEqual(self.app.status.cget("text"), "from a worker")

    def test_a_failing_update_does_not_stop_the_pump(self):
        self.app.ui(lambda: 1 / 0)
        self.app.ui(lambda: self.app.say("still pumping"))
        settle(self.app, 0.4)
        self.assertEqual(self.app.status.cget("text"), "still pumping")

    def test_enter_presses_the_focused_button_and_not_play(self):
        pressed, played = [], []
        self.app.b_copy.command = lambda: pressed.append(1)
        self.app.launch = lambda: played.append(1)
        self.app.b_copy.focus_force()
        settle(self.app)
        self.app.b_copy.event_generate("<Return>")
        self.app.b_copy.event_generate("<space>")
        settle(self.app)
        self.assertEqual(len(pressed), 2)
        self.assertEqual(played, [])

    def test_tab_reaches_the_buttons(self):
        reached, w = set(), self.app.focus_get() or self.app
        for _ in range(60):
            w = w.tk_focusNext()
            if w is None:
                break
            reached.add(w)
        for b in (self.app.play, self.app.b_rename, self.app.b_copy):
            self.assertIn(b, reached)

    def test_disabled_buttons_are_skipped(self):
        self.app.b_undo.enable(False)
        self.assertFalse(int(self.app.b_undo.cget("takefocus")))

    def test_arrow_keys_move_through_the_saves(self):
        ids = [s["id"] for s in self.app.items]
        self.app.select(ids[0])
        self.app.focus_force()
        settle(self.app)
        self.app.event_generate("<Down>")
        settle(self.app)
        self.assertEqual(self.app.selected, ids[1])
        self.app.event_generate("<Up>")
        settle(self.app)
        self.assertEqual(self.app.selected, ids[0])

    def test_every_dialog_opens_on_screen_above_the_launcher_and_holds_the_grab(self):
        grab(self.app, "ui_main.png")
        opens = {
            "new_save": self.app.new_save, "controls": self.app.show_controls, "rename": self.app.rename,
            "give_items": self.app.give_items, "kits": self.app.show_kits, "crew_gear": self.app.show_crew_gear, "import": self.app.import_saves, "report": self.app.report_problem,
            "delete": self.app.delete, "coop": self.app.show_coop, "settings": self.app.show_settings,
        }
        for name, open_it in opens.items():
            with self.subTest(dialog=name):
                open_it()
                settle(self.app)
                ds = dialogs(self.app)
                self.assertEqual(len(ds), 1)
                d = ds[0]
                self.assertTrue(d.winfo_viewable())
                self.assertEqual(str(d.grab_current()), str(d))
                ax, ay = self.app.winfo_rootx(), self.app.winfo_rooty()
                cx, cy = d.winfo_rootx() + d.winfo_width() // 2, d.winfo_rooty() + d.winfo_height() // 2
                self.assertTrue(ax <= cx <= ax + self.app.winfo_width() and ay <= cy <= ay + self.app.winfo_height(),
                                "centred on the launcher")
                grab(d, f"ui_{name}.png")
                d.event_generate("<Escape>")
                for _ in range(20):  # up to 2 s: the first dialog of a run can be slow to go
                    settle(self.app, 0.1)
                    if not dialogs(self.app):
                        break
                self.assertEqual(dialogs(self.app), [])

    def test_new_save_gear_and_money_are_separate(self):
        """NEW SAVE (#204): one box for a packed stash, one for infinite money, in any combination."""
        made = []
        for gear in (False, True):
            for money in (False, True):
                self.app.new_save()
                settle(self.app)
                d = dialogs(self.app)[0]
                boxes = [w for w in d.body.winfo_children() if isinstance(w, L.tk.Checkbutton)]
                self.assertEqual([b.cget("text") for b in boxes], ["Start with lots of gear (a packed stash)", "Infinite money"])
                for box, on in zip(boxes, (gear, money)):
                    if on:
                        box.invoke()
                name = [w for w in d.body.winfo_children() if isinstance(w, L.tk.Entry)][0]
                name.delete(0, "end")
                name.insert(0, f"Combo {gear} {money}")
                name.event_generate("<Return>")
                settle(self.app)
                self.assertEqual(dialogs(self.app), [])
                sid = self.app.selected
                made.append(sid)
                state = saves._read(os.path.join(saves.SAVES, sid, "state.json"))
                meta = saves._meta(sid)
                stash = len(state["storage"]["inventory"])
                with self.subTest(gear=gear, money=money):
                    self.assertEqual(bool(state.get("cheat")), money)
                    self.assertEqual(meta["cheat"], money)
                    self.assertEqual(meta["gear"], gear)
                    self.assertEqual(stash > 20, gear, f"{stash} items in the stash")
                    self.assertEqual("social" in state["storage"], gear, "a packed stash skips the new-player kit")
                    listed = [s for s in saves.listing() if s["id"] == sid][0]
                    self.assertEqual(listed["cash"], saves.CHEAT_CASH if money else saves.NEW_PLAYER_CASH if gear else 0)
                    self.assertEqual(bool(listed.get("cheat")), money, "the CHEAT tag means infinite money only")
        for sid in made:
            saves.delete(sid)
        self.app.selected = FIRST
        self.app.refresh()

    def test_coop_host_box_and_join(self):
        """CO-OP (#201): the Host box writes coop_host.txt; JOIN writes the one-shot coop_join.txt and starts the selected
        save with the address; a plain PLAY afterwards removes a join left over from a start that never happened."""
        self.app.show_coop()
        settle(self.app)
        d = dialogs(self.app)[0]
        box = [w for w in d.body.winfo_children() if isinstance(w, L.tk.Checkbutton)][0]
        box.invoke()
        with open(L.COOP_HOST) as f:
            self.assertEqual(f.read().strip(), "on")
        started = []
        real = self.app.launch
        self.app.launch = lambda join=None: started.append(join)
        try:
            field = [w for w in d.body.winfo_children() if isinstance(w, L.tk.Entry)][0]
            field.delete(0, "end")
            field.insert(0, "10.147.17.5")
            field.event_generate("<Return>")
            settle(self.app)
        finally:
            self.app.launch = real
        self.assertEqual(started, ["10.147.17.5"])
        with open(L.COOP_JOIN) as f:
            self.assertEqual(f.read().strip(), "10.147.17.5")
        self.assertEqual(dialogs(self.app), [])
        self.app.running = True  # PLAY that won't start a game: the leftover join still goes
        try:
            self.app.launch()
        finally:
            self.app.running = False
        self.assertFalse(os.path.exists(L.COOP_JOIN))
        os.remove(L.COOP_HOST)

    def test_settings_page_files_and_presets(self):
        """SETTINGS (#324): only changed values are written to ai_tuning.txt, a difficulty level sets its values, and a
        saved preset round-trips through export and import."""
        S = L.settings
        schema = S.load_schema()
        self.assertEqual([t["name"] for t in schema["tabs"]], ["Aim", "How many"])
        self.assertEqual(schema["presets"][1]["values"], {})  # (an empty Lua table arrives as [])
        values = {"Aim:MISS": 0.351, "Spawns:CIV": 0, "Old:GONE": 3}
        S.write_values(schema, values)
        self.assertEqual(S.read_values(), {"Spawns:CIV": 0, "Old:GONE": 3})  # default dropped, unknown id kept
        self.assertEqual(S.clamp(schema["tabs"][0]["rows"][0], 5), 2)
        self.assertEqual(S.clamp(schema["tabs"][0]["rows"][0], 0.333), 0.35)
        S.write_presets([{"name": "Mine", "values": {"Spawns:CIV": 2}}])
        self.assertEqual(S.read_presets(), [{"name": "Mine", "values": {"Spawns:CIV": 2}}])
        shared = os.path.join(TMP, "shared.txt")
        S.export_preset({"name": "Hard [x]", "values": {"Aim:MISS": 0.2}}, shared)
        self.assertEqual(S.import_preset(shared), {"name": "Hard (x)", "values": {"Aim:MISS": 0.2}})
        # the page: opens, shows the first tab's rows, Reset all clears the file
        self.app.show_settings()
        settle(self.app)
        d = dialogs(self.app)[0]
        scales = [w for w in d.winfo_children()[0].winfo_children()]
        self.assertTrue(scales)
        reset_all = [w for w in self._all(d) if isinstance(w, L.Button) and w.cget("text") == "Reset all"][0]
        reset_all.press()
        self.assertEqual(S.read_values(), {"Old:GONE": 3})
        easy = [w for w in self._all(d) if isinstance(w, L.Button) and w.cget("text") == "Easy"][0]
        easy.press()
        self.assertEqual(S.read_values().get("Aim:MISS"), 0.55)
        d.destroy()
        settle(self.app)
        for path in (S.VALUES, S.PRESETS):
            if os.path.exists(path):
                os.remove(path)

    def _all(self, w):
        out = []
        for c in w.winfo_children():
            out.append(c)
            out.extend(self._all(c))
        return out

    def test_layout_fits(self):
        self.app.update_idletasks()
        bottom = self.app.status.winfo_y() + self.app.status.winfo_height()
        self.assertLessEqual(bottom, self.app.winfo_height())
        self.assertLessEqual(self.app.play.winfo_rooty() + self.app.play.winfo_height(),
                             self.app.winfo_rooty() + self.app.winfo_height())

    def test_raid_conditions_keep_the_right_panel_in_the_window(self):
        # #188: the condition's about line in the status bar widened the left column and pushed the panel off
        names = [n for n, _ in self.app.raid_conditions()]
        for _ in names:
            self.app.cycle_condition(1)
            settle(self.app, 0.1)
            right = self.app.play.winfo_rootx() + self.app.play.winfo_width()
            self.assertLessEqual(right, self.app.winfo_rootx() + self.app.winfo_width(), self.app.cond_label.cget("text"))
            self.assertTrue(self.app.play.winfo_viewable())
        self.assertEqual(self.app.cond_label.cget("text"), "Normal")


SCALED = r"""
import ctypes, importlib.machinery, importlib.util, json, os, sys
ctypes.windll.shcore.SetProcessDpiAwareness(1)
spec = importlib.util.spec_from_loader("t", importlib.machinery.SourceFileLoader("t", sys.argv[1]))
sys.argv = sys.argv[:1] + ([sys.argv[2]] if len(sys.argv) > 2 else [])
T = importlib.util.module_from_spec(spec); spec.loader.exec_module(T)
L = T.L
class Big(L.App):
    def theme(self):
        self.tk.call("tk", "scaling", 1.5 * 96 / 72)   # 150 %
        super().theme()
app = Big(); T.settle(app, 0.5)
out = {"w": app.winfo_width(), "h": app.winfo_height(), "rw": app.winfo_reqwidth(), "rh": app.winfo_reqheight(),
       "sw": app.winfo_screenwidth(), "sh": app.winfo_screenheight()}
T.grab(app, "ui_main_150pct.png")
app.destroy()
print(json.dumps(out))
"""


@unittest.skipUnless(os.name == "nt", "the launcher window is Windows-only")
class Scaled(unittest.TestCase):
    """As at 150 % display scaling, in its own process (Tk's font cache is shared within one): the fonts grow, and the
    window must grow with its content instead of cutting it off. A screen too small for that is the only limit."""

    def test_window_grows_with_its_content(self):
        import json
        import subprocess
        script = os.path.join(TMP, "scaled.py")
        with open(script, "w") as f:
            f.write(SCALED)
        res = subprocess.run([sys.executable, script, os.path.abspath(__file__)] + ([OUT] if OUT else []),
                             capture_output=True, text=True, timeout=120)
        m = json.loads(res.stdout.strip().splitlines()[-1])
        self.assertGreater(m["w"], L.W, "wider than at 100 %")
        self.assertGreaterEqual(m["w"], min(m["rw"], m["sw"]))
        self.assertGreaterEqual(m["h"], min(m["rh"], m["sh"] - 80))  # (the title bar and taskbar take the rest)


if __name__ == "__main__":
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (OSError, AttributeError):
        pass
    unittest.main(verbosity=2)
