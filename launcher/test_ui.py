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
saves.ACTIVE = os.path.join(TMP, "active_save.txt")
saves.STASH_ROWS = os.path.join(TMP, "stash_rows.txt")
for name in ("FEMALE_SETTING", "FEMALE_SHARE", "WINDOW_SETTING", "SKIP_INTRO_SETTING", "UNLOCK_LOOKS_SETTING",
             "MINIMIZE_SETTING", "UPDATE_CHECK_SETTING", "RAID_CONDITION", "COOP_HOST", "COOP_JOIN", "COOP_LAST"):
    setattr(L, name, os.path.join(TMP, name.lower() + ".txt"))
with open(L.UPDATE_CHECK_SETTING, "w") as f:
    f.write("off\n")  # no network in tests
os.makedirs(saves.SAVES)
FIRST = saves.create("Alpha", False)
SECOND = saves.create("Bravo", True)


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
            "give_items": self.app.give_items, "import": self.app.import_saves, "report": self.app.report_problem,
            "delete": self.app.delete, "coop": self.app.show_coop,
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
                settle(self.app)
                self.assertEqual(dialogs(self.app), [])

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
