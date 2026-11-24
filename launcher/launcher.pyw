"""Marauders Offline launcher: pick or manage a save and play. Same look as the trailer and the loading screens: Bahnschrift,
the orange (255,138,36), the title art on the raid backdrop, thin rules and lower-left captions."""
import ctypes
import os
import queue
import socket
import shutil
import subprocess
import sys
import threading
import tempfile
import time
import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk
from tkinter import filedialog
import webbrowser
from datetime import datetime

from PIL import Image, ImageDraw, ImageEnhance, ImageTk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report
import saves
import settings
import update

# Linux / Steam Deck (issue #127): Steam starts the game through the launch option (linux/marauders-offline.sh ->
# scripts/pvemode.py steam-run), which switches the folder offline, runs the stand-in, and puts everything back when the
# game closes. There the launcher manages saves and settings, and its PLAY picks the save and asks Steam to start the game.
IS_WIN = os.name == "nt"
if not IS_WIN:
    sys.path.insert(0, os.path.join(saves.ROOT, "scripts"))
    import pvemode
STEAM_APPID = "1789480"  # Marauders (steamapps/appmanifest_1789480.acf)

ROOT = saves.ROOT
GAME_EXE = "RaidGame-Win64-Shipping.exe"
FEMALE_SETTING = os.path.join(ROOT, "config", "female_player.txt")
FEMALE_SHARE = os.path.join(ROOT, "config", "female_share.txt")  # percent of other characters who are women (rivals.lua)
FEMALE_SHARE_DEFAULT = 35
RAID_LENGTH = os.path.join(ROOT, "config", "raid_length.txt")  # minutes, "default" or "none" (raidtime.lua, #159)
GATE_TIME = os.path.join(ROOT, "config", "gate_time.txt")  # minutes, "instant" or "default": when the space gate arrives (raidtime.lua)
# Raid conditions (#78): named set-ups in these files ([Name], then "about = ..."), the pick in RAID_CONDITION
# (conditions.lua reads the same files; the lobby's REGION picker can change it too)
RAID_CONDITIONS = [os.path.join(ROOT, "config", n) for n in ("raid_conditions.txt", "my_raid_conditions.txt")]
RAID_CONDITION = os.path.join(ROOT, "config", "raid_condition.txt")
RAID_LENGTHS = ["default", "15", "30", "45", "60", "90", "120", "none"]  # the slider's stops; the game's own is 25 min
GATE_TIMES = ["default", "instant", "5", "10", "15"]  # the space gate slider's stops; the game's own is 5 min into the raid
WINDOW_SETTING = os.path.join(ROOT, "config", "window_mode.txt")  # read by scripts/launch-offline.ps1
SKIP_INTRO_SETTING = os.path.join(ROOT, "config", "skip_intro.txt")  # read by scripts/mode.ps1
UNLOCK_LOOKS_SETTING = os.path.join(ROOT, "config", "unlock_all_looks.txt")  # read by the Nakama stand-in at login
MINIMIZE_SETTING = os.path.join(ROOT, "config", "minimize_while_playing.txt")  # "off": stay on screen while playing
UPDATE_CHECK_SETTING = os.path.join(ROOT, "config", "update_check.txt")  # "off" stops the check for a newer build
COOP_HOST = os.path.join(ROOT, "config", "coop_host.txt")  # "on": your raids are listen servers (launch.lua, #201)
COOP_JOIN = os.path.join(ROOT, "config", "coop_join.txt")  # host[:port] to join once at the menu; the mod deletes it
COOP_LAST = os.path.join(ROOT, "config", "coop_last.txt")  # the last address joined, to fill the box next time
GAME_PATH = os.path.join(ROOT, "config", "game_path.txt")  # written by the installer; scripts/mode.ps1 has the same default


def game_folder():
    try:
        with open(GAME_PATH, encoding="utf-8") as f:
            return f.readline().strip()
    except OSError:
        return "C:/Program Files (x86)/Steam/steamapps/common/PHtest"


GAME_LOG = os.path.join(game_folder(), "RaidGame", "Binaries", "Win64", "UE4SS.log")
NO_WINDOW = 0x08000000
# Console tools (tasklist, PowerShell) write in the OEM code page, not UTF-8 (issue #139).
try:
    CONSOLE_ENCODING = f"cp{ctypes.windll.kernel32.GetOEMCP()}"
    "".encode(CONSOLE_ENCODING)
except (AttributeError, OSError, LookupError):
    CONSOLE_ENCODING = "utf-8"
START_TIMEOUT = 90     # seconds for the game to appear after Play

ORANGE = "#FF8A24"
ORANGE_DIM = "#B5611A"
INK = "#0B0D10"
PANEL = "#12151A"
PANEL_HI = "#1B2027"
LINE = "#2B313A"
TEXT = "#F5F5F5"
MUTED = "#8E97A3"
DANGER = "#E0533D"
W, H = 1060, 660


# The launcher's face is Bahnschrift (Windows 10/11). Elsewhere the first installed fallback is used, with bold standing
# in for Bahnschrift's SemiBold and Bold styles (issue #147): Tk otherwise substitutes something unpredictable.
FONT_FALLBACKS = ("Bahnschrift", "Segoe UI", "DejaVu Sans", "Liberation Sans", "Helvetica")
_family = None


def pick_family(installed):
    names = {f.lower(): f for f in installed}
    return next((names[f.lower()] for f in FONT_FALLBACKS if f.lower() in names), "TkDefaultFont")


def font(size, weight=""):
    global _family
    if _family is None:
        try:
            _family = pick_family(tkfont.families())
        except (tk.TclError, RuntimeError):  # no Tk root yet: decide on the first call that has one
            return ("Bahnschrift " + weight if weight else "Bahnschrift", size)
    if _family == "Bahnschrift":
        return ("Bahnschrift " + weight if weight else "Bahnschrift", size)
    return (_family, size, "bold" if weight else "normal")


def ps(*args):
    # PVE_PYTHON: launch-offline.ps1 starts the stand-in with this interpreter, not whatever "python" is on PATH.
    env = dict(os.environ, PVE_PYTHON=sys.executable)
    return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", *args], cwd=ROOT,
                          creationflags=NO_WINDOW, capture_output=True, text=True, encoding=CONSOLE_ENCODING, errors="replace", env=env)


def tasklist_has(image, shown):
    """Whether tasklist lists a running image. tasklist writes in the console's code page (cp850 on Spanish Windows,
    issue #139): decoded as UTF-8 an accented character failed and stdout came back None, which crashed the launcher."""
    try:
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {image}", "/NH"], capture_output=True, text=True,
                             encoding=CONSOLE_ENCODING, errors="replace", creationflags=NO_WINDOW).stdout or ""
    except OSError:
        return False
    return shown.lower() in out.lower()


def game_running():
    if not IS_WIN:
        return pvemode.game_running()
    return tasklist_has(GAME_EXE, GAME_EXE[:20])  # tasklist cuts long names to 25 characters


def ps_error(result):
    """The first line of a failed PowerShell script's error, short enough for the status line."""
    lines = [l.strip() for l in (result.stderr or "").splitlines() if l.strip()]
    text = lines[0] if lines else f"exit code {result.returncode}"
    return text if len(text) <= 160 else text[:157] + "..."


def steam_running():
    if not IS_WIN:
        for pid in os.listdir("/proc"):
            try:
                with open(f"/proc/{pid}/comm", encoding="utf-8", errors="replace") as f:
                    if f.read().strip() in ("steam", "steamwebhelper"):
                        return True
            except OSError:
                continue
        return False
    return tasklist_has("steam.exe", "steam.exe")


def open_url(url):
    """steam:// links and folders, with the desktop's handler."""
    if IS_WIN:
        os.startfile(url)
    else:
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def reveal(path):
    """Shows a file in the file manager (Linux: opens its folder)."""
    try:
        if IS_WIN:
            subprocess.Popen(["explorer", "/select,", path])
        else:
            open_url(os.path.dirname(path))
    except OSError:
        pass


def linux_launch_option():
    """Whether Steam's launch option for Marauders runs linux/marauders-offline.sh, read from every Steam user's
    localconfig.vdf: True, False, or None when there's no Steam config to tell from."""
    found = None
    for root in pvemode.steam_roots():
        users = os.path.join(root, "userdata")
        for user in (os.listdir(users) if os.path.isdir(users) else []):
            try:
                with open(os.path.join(users, user, "config", "localconfig.vdf"), encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            found = False
            at = text.find('"' + STEAM_APPID + '"')
            while at >= 0:
                if "marauders-offline.sh" in text[at:at + 3000].split("}", 1)[0]:
                    return True
                at = text.find('"' + STEAM_APPID + '"', at + 1)
    return found


def preflight():
    """Why PLAY can't work right now, in words a player can act on; None when everything it needs is in place.
    Without this a missing piece only showed as "The game didn't start" after START_TIMEOUT."""
    game = game_folder()
    if not os.path.isfile(os.path.join(game, "RaidGame", "Binaries", "Win64", GAME_EXE)) and not IS_WIN:
        return f"Can't find the game in {game}. Run linux/install.sh again (or set config/game_path.txt)."
    if not os.path.isfile(os.path.join(game, "RaidGame", "Binaries", "Win64", GAME_EXE)):
        return f"Can't find the game in {game}. Run Install.bat again (developers: set config\\game_path.txt)."
    for need in ("dwmapi.dll", "UE4SS.dll", "Mods"):
        if not os.path.exists(os.path.join(ROOT, "tools", "ue4ss", need)):
            return f"UE4SS is missing (tools\\ue4ss\\{need}). Unzip the mod again (developers: see the README's setup)."
    if not steam_running():
        return "Start Steam first: the game needs it running."
    return None


def stop_standin():
    if not IS_WIN:
        return  # on Linux pvemode.py steam-run starts and stops it
    ps("-Command", "Get-CimInstance Win32_Process -Filter \"Name LIKE 'python%.exe'\" | Where-Object { $_.CommandLine -match "
                   "'nakama_standin' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }")


def when(t):
    return datetime.fromtimestamp(t).strftime("%d %b %Y, %H:%M") if t else "never"


def scrollbar(parent, **kw):
    """A vertical scrollbar in the launcher's colours."""
    style = ttk.Style(parent)
    if "Dark.Vertical.TScrollbar" not in style.element_names() and style.theme_use() != "clam":
        style.theme_use("clam")
    style.configure("Dark.Vertical.TScrollbar", background=PANEL_HI, troughcolor=INK, bordercolor=INK, arrowcolor=MUTED,
                    lightcolor=PANEL_HI, darkcolor=PANEL_HI, gripcount=0)
    style.map("Dark.Vertical.TScrollbar", background=[("active", ORANGE_DIM), ("pressed", ORANGE)])
    return ttk.Scrollbar(parent, orient="vertical", style="Dark.Vertical.TScrollbar", **kw)


class Button(tk.Label):
    """A flat button: the game's menus have no bevels."""

    def __init__(self, parent, text, command, kind="plain", size=12, pad=(16, 8)):
        self.colors = {"main": (ORANGE, INK, "#FFA64F"), "plain": (PANEL_HI, TEXT, "#2A313B"), "danger": (PANEL_HI, DANGER, "#2A313B")}[kind]
        # Tab reaches it (an orange ring shows focus) and Enter or Space presses it, as a real button (issue #147).
        super().__init__(parent, text=text, bg=self.colors[0], fg=self.colors[1], font=font(size, "SemiBold"), padx=pad[0], pady=pad[1],
                         cursor="hand2", takefocus=True, highlightthickness=2, highlightcolor=ORANGE,
                         highlightbackground=parent.cget("bg"))
        self.command, self.enabled = command, True
        self.bind("<Button-1>", lambda e: self.press())
        # "break": the launcher window's own Enter (PLAY) doesn't fire as well
        self.bind("<Return>", lambda e: (self.press(), "break")[1])
        self.bind("<space>", lambda e: (self.press(), "break")[1])
        self.bind("<Enter>", lambda e: self.enabled and self.config(bg=self.colors[2]))
        self.bind("<Leave>", lambda e: self.enabled and self.config(bg=self.colors[0]))

    def press(self):
        if self.enabled:
            self.command()

    def enable(self, on):
        self.enabled = on
        self.config(bg=self.colors[0] if on else PANEL, fg=self.colors[1] if on else "#4A525E", cursor="hand2" if on else "arrow",
                    takefocus=on)


# The mod's keys, as the CONTROLS dialog lists them (keep in step with README.md's "Controls" table).
CONTROLS = [
    ("F11", "Your crew: hire, dismiss, and choose who comes on raids", "Lobby and raids"),
    ("F10", "AI tuning: every enemy, rival and crew setting, including how many spawn", "Lobby and raids"),
    ("F9", "Debug menu: god mode, your body (woman or man), extract now, spawn a soldier, and more", "Lobby and raids"),
    ("N", "Minimap on or off", "Raids"),
    ("M", "Minimap full overview, and back", "Raids"),
    ("B", "Minimap: follow the next task", "Raids"),
    ("K", "Move the item under the mouse between stash and pockets or bags; in a raid, between you and what you loot", "LOADOUT, TRADE, raid"),
    ("J", "Discard the item under the mouse (press twice); in a raid, drop it", "LOADOUT, TRADE, raid"),
    ("Left click", "With a crew gunner aboard: send them after what you aim at", "Flying your ship"),
    ("Space", "Boost: full speed for 4 s, then 12 s to recharge", "Flying your ship"),
    ("F + ToolKit", "By a mine: defuse a station mine, or the nuclear mine in your hold", "On foot"),
    ("R", "By a space mine: defuse a small one (ToolKit), take a nuclear one aboard", "At the helm"),
    ("Blowtorch", "Fire it at a ship part to repair your ship: parts first, then the hull", "Aboard your ship"),
]


class Dialog(tk.Toplevel):
    """A small dark window in the launcher's style.

    A normal window with a title bar, owned by the launcher (transient: kept above it, minimised with it). It used to be
    borderless, and could open underneath the launcher while holding the grab, so every click went nowhere and the
    launcher looked frozen (issue #147). Now it's built hidden, centred on the launcher, and takes the grab only once
    it's on screen. Escape or the title bar's X closes it."""

    def __init__(self, app, title):
        super().__init__(app, bg=PANEL)
        self.withdraw()  # until show(): no flash at the default position
        self.app = app
        self.title(title)
        self.resizable(False, False)
        self.transient(app)
        self.body = tk.Frame(self, bg=PANEL, padx=26, pady=20)
        self.body.pack()
        tk.Label(self.body, text=title.upper(), bg=PANEL, fg=ORANGE, font=font(15, "SemiBold")).pack(anchor="w")
        tk.Frame(self.body, bg=ORANGE, height=2, width=400).pack(anchor="w", pady=(6, 14))
        self.bind("<Escape>", lambda e: self.destroy())
        self.protocol("WM_DELETE_WINDOW", self.destroy)

    def show(self):
        self.update_idletasks()
        x = self.app.winfo_rootx() + (self.app.winfo_width() - self.winfo_reqwidth()) // 2
        y = self.app.winfo_rooty() + (self.app.winfo_height() - self.winfo_reqheight()) // 2
        self.geometry(f"+{max(0, x)}+{max(0, y)}")
        dark_title_bar(self)
        self.deiconify()
        self.lift(self.app)
        self.focus_force()
        self._grab(0)

    def _grab(self, tries):
        """The grab once the window is mapped (a grab on an unmapped window fails or grabs nothing). Polled, not
        wait_visibility(): a compositing window manager (Wayland, KDE, WSLg) may never send the VisibilityNotify it
        waits for, which hung every dialog on Linux (#161)."""
        try:
            if not self.winfo_exists():
                return
            if self.winfo_viewable():
                self.grab_set()
                self.focus_force()
            elif tries < 100:
                self.after(20, self._grab, tries + 1)
        except tk.TclError:
            pass  # closed already, or another grab: it still works, only without blocking the launcher

    def row(self):
        f = tk.Frame(self.body, bg=PANEL)
        f.pack(anchor="e", pady=(18, 0))
        return f


def wrap(pixels):
    """A text wrap width given in pixels at 100 % display scaling, as points: it grows with the fonts (issue #147)."""
    return f"{pixels * 0.75:g}p"


def dark_title_bar(window):
    """Windows 10/11 draws the window's title bar dark, to match the launcher (no-op elsewhere or on older Windows)."""
    try:
        window.update_idletasks()
        hwnd = ctypes.windll.user32.GetParent(window.winfo_id())
        on = ctypes.c_int(1)
        for attribute in (20, 19):  # DWMWA_USE_IMMERSIVE_DARK_MODE (20H1+), and its number before that
            if ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, attribute, ctypes.byref(on), ctypes.sizeof(on)) == 0:
                break
    except (AttributeError, OSError):
        pass


def entry(parent, size=14, width=32):
    """A text box in the launcher's style (its colours come from App.theme)."""
    return tk.Entry(parent, font=font(size), width=width)


def check(parent, text, var, size=12, command=None, **kw):
    """A checkbox in the launcher's style (its colours come from App.theme)."""
    return tk.Checkbutton(parent, text=text, variable=var, command=command, font=font(size), **kw)


ERROR_LOG = os.path.join(ROOT, "backend", "launcher_errors.log")


def log_error(text):
    """Appends to backend/launcher_errors.log. pythonw (and a Linux desktop entry) has no console, so an error in a
    button's handler used to vanish and the button just seemed to do nothing (#161: SETTINGS and saves on Linux)."""
    try:
        os.makedirs(os.path.dirname(ERROR_LOG), exist_ok=True)
        with open(ERROR_LOG, "a", encoding="utf-8") as f:
            f.write(datetime.now().strftime("%Y-%m-%d %H:%M:%S ") + text.rstrip() + "\n")
    except OSError:
        pass


class App(tk.Tk):
    def report_callback_exception(self, exc, val, tb):
        import traceback
        log_error("".join(traceback.format_exception(exc, val, tb)))
        try:
            self.say(f"Something went wrong ({exc.__name__}: {val}). Details: backend/launcher_errors.log")
        except Exception:
            pass

    def __init__(self):
        super().__init__()
        self.title("Marauders Offline")
        self.geometry(f"{W}x{H}")
        self.resizable(False, False)
        self.configure(bg=INK)
        self.theme()
        dark_title_bar(self)
        # Background threads (starting the game, tidying up, updates) never touch Tk themselves: Tk isn't thread-safe, and
        # calling it from another thread can now and then crash or freeze the window (issue #147). They hand the main
        # thread a function through ui(), and pump() runs it.
        self.ui_queue = queue.Queue()
        self.after(50, self.pump)
        icon = os.path.join(ROOT, "assets", "launcher", "icon.ico")
        if os.path.exists(icon):
            try:
                if IS_WIN:
                    self.iconbitmap(icon)
                else:  # (X11 Tk can't read .ico as a bitmap)
                    self.icon_image = ImageTk.PhotoImage(Image.open(icon))
                    self.iconphoto(True, self.icon_image)
            except (tk.TclError, OSError):
                pass
        saves.adopt_existing()
        # A save still marked active means a launcher was closed while its game ran: finish that game's tidy-up now.
        left_playing = saves.active() is not None
        playing = game_running()
        if not IS_WIN:
            # Linux: Steam's launch option (pvemode.py steam-run) activates and settles saves, and may be starting a game
            # right now. Only a game left offline a while ago with nothing running is put back (as its next start would).
            left_playing = False
            try:
                stale = time.time() - os.path.getmtime(pvemode.DIRTY) > START_TIMEOUT
            except OSError:
                stale = False
            if stale and not playing:
                pvemode.recover()
        elif not playing:
            saves.settle()
        self.selected = None
        self.running = False
        self.launch_error = None
        self.seen = False
        self.started = time.time()
        self.cards = {}
        self.release = None  # a newer public test build, once the background check finds one
        self.updating = False
        self.tidying = left_playing and not playing  # PLAY waits for tidy_after_close
        self.build()
        self.refresh()
        # Keyboard (#98): Enter plays, Delete deletes (asking first), F2 renames. Dialogs grab the keys while open.
        self.bind("<Return>", lambda e: self.launch())
        self.bind("<Delete>", lambda e: self.current() and self.delete())
        self.bind("<F2>", lambda e: self.current() and self.rename())
        self.bind("<Up>", lambda e: self.step(-1, e))  # (#147) arrow keys move through the saves
        self.bind("<Down>", lambda e: self.step(1, e))
        self.after(1000, self.watch)
        self.check_update()
        self.protocol("WM_DELETE_WINDOW", self.close)
        if left_playing and playing:
            # still running: watch() saves and goes back to stock when it closes, as if PLAY had started it here
            self.running, self.seen = True, True
            self.show_selected()
            self.say("Playing. Leave this window open: it saves when you close the game.")
        elif left_playing:
            self.say("Putting the game back to normal (the launcher was closed while you played)...")
            threading.Thread(target=self.tidy_after_close, daemon=True).start()

    def theme(self):
        """The shared look of text boxes and checkboxes, in Tk's option database: one place to change it (issue #147).
        Widgets made after this take these unless they're given their own."""
        for pattern, value in (
                ("*Entry.background", INK), ("*Entry.foreground", TEXT), ("*Entry.insertBackground", ORANGE),
                ("*Entry.relief", "flat"), ("*Entry.highlightThickness", 1), ("*Entry.highlightColor", ORANGE),
                ("*Entry.highlightBackground", INK),
                ("*Checkbutton.background", PANEL), ("*Checkbutton.foreground", TEXT), ("*Checkbutton.selectColor", INK),
                ("*Checkbutton.activeBackground", PANEL), ("*Checkbutton.activeForeground", TEXT),
                ("*Checkbutton.borderWidth", 0), ("*Checkbutton.highlightThickness", 1),
                ("*Checkbutton.highlightColor", ORANGE), ("*Checkbutton.highlightBackground", PANEL),
                ("*Checkbutton.cursor", "hand2")):
            self.option_add(pattern, value)

    def destroy(self):
        # pump() and watch() re-arm themselves: cancel them, or they fire into a window that's gone
        for pending in self.tk.splitlist(self.tk.call("after", "info")):
            try:
                self.after_cancel(pending)
            except tk.TclError:
                pass
        super().destroy()

    def ui(self, fn):
        """Runs fn on the main thread, soon. The only way a background thread may change the window."""
        self.ui_queue.put(fn)

    def pump(self):
        while True:
            try:
                fn = self.ui_queue.get_nowait()
            except queue.Empty:
                break
            try:
                fn()
            except Exception:  # one failed update mustn't stop the pump
                import traceback
                traceback.print_exc()
        self.after(50, self.pump)

    def step(self, delta, event=None):
        if isinstance(getattr(event, "widget", None), tk.Scale):
            return  # the slider uses the arrow keys itself
        ids = [s["id"] for s in getattr(self, "items", [])]
        if not ids:
            return
        i = ids.index(self.selected) if self.selected in ids else 0
        self.select(ids[max(0, min(len(ids) - 1, i + delta))])

    def tidy_after_close(self):
        stop_standin()
        try:
            shutil.copyfile(GAME_LOG, os.path.join(ROOT, "backend", "last_game.log"))
        except OSError:
            pass
        if IS_WIN:
            ps("-File", os.path.join(ROOT, "scripts", "mode.ps1"), "online")
        else:
            pvemode.recover()
        self.ui(self.tidied)

    def tidied(self):
        self.tidying = False
        self.show_selected()
        self.say("Saved your last game. The normal online game works as usual.")

    def close(self):
        # Closing mid-install would kill the update thread before it can put replaced files back.
        if self.updating:
            self.say("Updating: the launcher restarts by itself when it's done.")
            return
        if self.running is None:  # finish() is saving and switching back to stock
            self.say("Saving: this takes a few seconds.")
            return
        if self.running:
            self.confirm("Close the launcher?", "The game is still running. The launcher saves your game and puts the "
                         "normal online game back when the game closes. If you close it now, that waits until you "
                         "open the launcher again.", "CLOSE ANYWAY", self.destroy)
            return
        self.destroy()

    # Layout ---------------------------------------------------------------------------------------------------------
    def build(self):
        # (#147) A grid with minimum sizes, not fixed pixel positions: with Windows display scaling the fonts grow, and
        # so do the panels and the window, instead of the text being cut off.
        self.columnconfigure(0, minsize=620)
        self.columnconfigure(1, minsize=368)
        self.rowconfigure(0, minsize=130)  # the title art
        # weight: on a screen too short for everything (1080p at 150 %), this row gives up the difference, so the status
        # line stays on screen; inside the details panel PLAY was packed first and keeps its place too
        self.rowconfigure(1, minsize=474, weight=1)
        left = tk.Frame(self, bg=INK)
        left.grid(row=1, column=0, sticky="nsew", padx=(36, 0))
        head = tk.Frame(left, bg=INK)
        head.pack(fill="x")
        tk.Label(head, text="SAVES", bg=INK, fg=TEXT, font=font(17, "SemiBold")).pack(side="left")
        Button(head, "NEW SAVE", self.new_save, "main", 11, (14, 5)).pack(side="right")
        Button(head, "CONTROLS", self.show_controls, size=11, pad=(14, 5)).pack(side="right", padx=(0, 8))
        Button(head, "REPORT", self.report_problem, size=11, pad=(14, 5)).pack(side="right", padx=(0, 8))
        Button(head, "IMPORT", self.import_saves, size=11, pad=(14, 5)).pack(side="right", padx=(0, 8))
        Button(head, "CO-OP", self.show_coop, size=11, pad=(14, 5)).pack(side="right", padx=(0, 8))
        Button(head, "SETTINGS", self.show_settings, size=11, pad=(14, 5)).pack(side="right", padx=(0, 8))
        tk.Frame(left, bg=ORANGE, height=2).pack(fill="x", pady=(7, 8))
        self.list_box = tk.Frame(left, bg=INK)
        self.list_box.pack(fill="both", expand=True)

        right = tk.Frame(self, bg=PANEL)
        right.grid(row=1, column=1, sticky="nsew", padx=(0, 36))
        self.right = tk.Frame(right, bg=PANEL, padx=22, pady=18)
        self.right.pack(fill="both", expand=True)
        # PLAY first, so it keeps its place at the bottom whatever else the panel holds
        self.play = Button(self.right, "PLAY", self.launch, "main", 20, (10, 12))
        self.play.pack(side="bottom", fill="x", pady=(12, 0))
        self.d_name = tk.Label(self.right, bg=PANEL, fg=TEXT, font=font(18, "SemiBold"), anchor="w", wraplength=wrap(310), justify="left")
        self.d_name.pack(fill="x")
        self.d_mode = tk.Label(self.right, bg=PANEL, fg=ORANGE, font=font(11), anchor="w")
        self.d_mode.pack(fill="x", pady=(2, 8))
        tk.Frame(self.right, bg=LINE, height=1).pack(fill="x", pady=(0, 10))
        self.d_info = tk.Label(self.right, bg=PANEL, fg=MUTED, font=font(12), anchor="w", justify="left")
        self.d_info.pack(fill="x")
        grid = tk.Frame(self.right, bg=PANEL)
        grid.pack(fill="x", pady=(14, 0))
        self.b_rename = Button(grid, "Rename", self.rename, size=11, pad=(10, 6))
        self.b_copy = Button(grid, "Copy", self.copy, size=11, pad=(10, 6))
        self.b_delete = Button(grid, "Delete", self.delete, "danger", 11, (10, 6))
        self.b_rename.grid(row=0, column=0, sticky="ew", padx=(0, 6))
        self.b_copy.grid(row=0, column=1, sticky="ew", padx=(0, 6))
        self.b_delete.grid(row=0, column=2, sticky="ew")
        for c in range(3):
            grid.columnconfigure(c, weight=1)
        row2 = tk.Frame(self.right, bg=PANEL)
        row2.pack(fill="x", pady=(6, 0))
        self.b_undo = Button(row2, "Undo last raid", self.undo, size=11, pad=(10, 6))
        self.b_backup = Button(row2, "Back up", self.backup, size=11, pad=(10, 6))
        self.b_undo.grid(row=0, column=0, sticky="ew", padx=(0, 6))
        self.b_undo.bind("<Enter>", lambda e: None if self.b_undo.enabled else self.say(
            "Undo last raid: nothing to undo yet. It puts this save back to the start of its last raid, once you've "
            "played one with it."))
        self.b_backup.grid(row=0, column=1, sticky="ew")
        row2.columnconfigure(0, weight=2)
        row2.columnconfigure(1, weight=1)
        self.b_give = Button(self.right, "Give items or cash", self.give_items, size=11, pad=(10, 6))
        self.b_give.pack(fill="x", pady=(6, 0))

        tk.Frame(self.right, bg=LINE, height=1).pack(fill="x", pady=(10, 6))
        self.cheat_var = tk.BooleanVar()
        self.female_var = tk.BooleanVar(value=self.read_female())
        self.toggle("Infinite money", self.cheat_var, self.toggle_cheat)
        self.toggle("Play as a woman  (the F9 menu switches in game)", self.female_var, self.toggle_female)
        # The save panel holds this save and the next raid; options for every save and the app are on the SETTINGS page
        # (app_options). Sliders are one row each (label, slider, value).
        self.share_var = tk.IntVar(value=self.read_share())
        self.share_label = None
        tk.Label(self.right, text="NEXT RAID", bg=PANEL, fg=MUTED, font=font(10, "SemiBold"), anchor="w").pack(
            fill="x", pady=(8, 2))
        length = tk.Frame(self.right, bg=PANEL)
        length.pack(fill="x")
        tk.Label(length, text="Raid length", bg=PANEL, fg=TEXT, font=font(12), anchor="w").pack(side="left")
        self.length_label = tk.Label(length, bg=PANEL, fg=ORANGE, font=font(12, "SemiBold"), width=8, anchor="e")
        self.length_label.pack(side="right")
        self.length_var = tk.IntVar(value=self.read_raid_length())
        tk.Scale(length, from_=0, to=len(RAID_LENGTHS) - 1, resolution=1, orient="horizontal", variable=self.length_var,
                 showvalue=False, command=self.change_raid_length, bg=ORANGE, troughcolor=PANEL_HI, activebackground=ORANGE,
                 highlightthickness=0, bd=0, sliderrelief="flat", sliderlength=18, width=10,
                 cursor="hand2").pack(side="left", fill="x", expand=True, padx=(12, 4))
        self.length_label.config(text=self.raid_length_text(self.length_var.get()))
        gate = tk.Frame(self.right, bg=PANEL)
        gate.pack(fill="x")
        tk.Label(gate, text="Space gate", bg=PANEL, fg=TEXT, font=font(12), anchor="w").pack(side="left")
        self.gate_label = tk.Label(gate, bg=PANEL, fg=ORANGE, font=font(12, "SemiBold"), width=8, anchor="e")
        self.gate_label.pack(side="right")
        self.gate_var = tk.IntVar(value=self.read_gate_time())
        tk.Scale(gate, from_=0, to=len(GATE_TIMES) - 1, resolution=1, orient="horizontal", variable=self.gate_var,
                 showvalue=False, command=self.change_gate_time, bg=ORANGE, troughcolor=PANEL_HI, activebackground=ORANGE,
                 highlightthickness=0, bd=0, sliderrelief="flat", sliderlength=18, width=10,
                 cursor="hand2").pack(side="left", fill="x", expand=True, padx=(12, 4))
        self.gate_label.config(text=self.gate_time_text(self.gate_var.get()))
        # Raid conditions (#78): < Name > (click either arrow or the name; right-click goes back), and what it does
        # on the line under it.
        cond = tk.Frame(self.right, bg=PANEL)
        cond.pack(fill="x", pady=(2, 0))
        tk.Label(cond, text="Raid conditions", bg=PANEL, fg=TEXT, font=font(12), anchor="w").pack(side="left")
        nxt = tk.Label(cond, text="\u203a", bg=PANEL_HI, fg=ORANGE, font=font(12, "SemiBold"), width=2, cursor="hand2")
        nxt.pack(side="right")
        self.cond_label = tk.Label(cond, bg=PANEL, fg=ORANGE, font=font(12, "SemiBold"), anchor="center", cursor="hand2",
                                   padx=6)
        self.cond_label.pack(side="right")
        prev = tk.Label(cond, text="\u2039", bg=PANEL_HI, fg=ORANGE, font=font(12, "SemiBold"), width=2, cursor="hand2")
        prev.pack(side="right")
        for w, step in ((nxt, 1), (prev, -1), (self.cond_label, 1)):
            w.bind("<Button-1>", lambda e, step=step: self.cycle_condition(step))
        self.cond_label.bind("<Button-3>", lambda e: self.cycle_condition(-1))
        self.cond_about = tk.Label(self.right, bg=PANEL, fg=MUTED, font=font(10), anchor="w", justify="left",
                                   wraplength=wrap(310))
        self.cond_about.pack(fill="x", pady=(2, 0))
        self.show_condition()
        # App-wide options: their variables live here, their boxes on the SETTINGS page (app_options).
        self.borderless_var = tk.BooleanVar(value=self.read_borderless())
        self.skip_intro_var = tk.BooleanVar(value=self.read_skip_intro())
        self.unlock_looks_var = tk.BooleanVar(value=self.read_unlock_looks())
        self.minimize_var = tk.BooleanVar(value=self.read_minimize())
        self.update_check_var = tk.BooleanVar(value=self.read_update_check())
        # Shown top right only when a newer build is out (check_update)
        # Always shown, so players know the launcher updates itself: greyed out with why (checking, up to date, off, a
        # dev checkout), orange with "!" when a newer build is out (show_update).
        self.update_badge = tk.Frame(self, bg=INK)
        self.update_mark = tk.Label(self.update_badge, text="!", bg=ORANGE, fg=INK, font=font(14, "Bold"), width=2)
        self.update_mark.pack(side="left", fill="y")
        self.update_button = Button(self.update_badge, "UPDATE", self.offer_update, "plain", 11, (12, 6))
        self.update_button.pack(side="left")
        self.update_button.bind("<Enter>", lambda e: None if self.update_button.enabled else self.say(
            "Updates: the launcher installs new builds itself and keeps your saves. When one is out this button lights "
            "up. " + ("Checking is off (SETTINGS)." if not self.update_check_var.get() else "")))
        self.update_badge.place(relx=1.0, x=-36, y=40, anchor="ne")

        # width=1: the label asks for no room of its own and just fills its column (sticky ew). Sized to its text, a long
        # line (a raid condition's about, #188) widened column 0 and pushed the right-hand panel out of the window.
        self.status = tk.Label(self, text="", bg=INK, fg=MUTED, font=font(11), anchor="w", bd=0, width=1)
        # the installed build (version.txt, "public-test-20261117.6"), so players can say which one they're on
        build = (update.installed() or "").replace("public-test-", "") or "dev"
        tag = tk.Label(self, text=f"OFFLINE  PvE   ·   build {build}", bg=INK, fg=ORANGE_DIM, font=font(11, "SemiBold"))

        self.status.grid(row=2, column=0, sticky="ew", padx=(36, 0), pady=18)
        self.status.grid_remove()  # until there's something to say (say)
        tag.grid(row=2, column=1, sticky="e", padx=(0, 36), pady=18)
        # The window is as big as the grid needs once the details panel holds stand-ins as tall as what refresh() writes.
        self.d_name.config(text="Save")
        self.d_mode.config(text="Save")
        self.d_info.config(text="Cash   ·   XP\nStash\nStarted")
        longest = max((a for _, a in self.raid_conditions()), key=len, default="")
        self.cond_about.config(text=longest)
        self.update_idletasks()
        w, h = max(W, self.winfo_reqwidth()), max(H, self.winfo_reqheight())
        self.geometry(f"{w}x{h}")
        self.show_condition()

        canvas = tk.Canvas(self, width=w, height=h, bg=INK, highlightthickness=0)
        canvas.place(x=0, y=0, relwidth=1, relheight=1)  # the backdrop, behind the grid
        tk.Misc.lower(canvas)  # behind the panels (Canvas.lower is for its own items)
        back = Image.open(os.path.join(ROOT, "assets", "loading", "backdrop.png")).convert("RGB")
        scale = max(w / back.width, h / back.height)
        back = back.resize((int(back.width * scale) + 1, int(back.height * scale) + 1))
        back = back.crop((0, 0, w, h))
        back = ImageEnhance.Brightness(back).enhance(0.28)
        logo = Image.open(os.path.join(ROOT, "assets", "menu", "logo.png")).convert("RGBA")
        logo.thumbnail((400, 100))
        back.paste(logo, (36, 26), logo)
        self.back_art = ImageTk.PhotoImage(back)
        canvas.create_image(0, 0, image=self.back_art, anchor="nw")

    def toggle(self, text, var, command, parent=None):
        check(parent or self.right, text, var, command=command, anchor="w", justify="left",
              wraplength=wrap(300)).pack(fill="x")

    def app_options(self, parent):
        """The options that apply to every save and to the app (the SETTINGS page's top section)."""
        box = tk.Frame(parent, bg=PANEL)
        box.pack(fill="x", pady=(0, 6))
        tk.Label(box, text="GAME AND LAUNCHER", bg=PANEL, fg=MUTED, font=font(10, "SemiBold"), anchor="w").pack(fill="x")
        cols = tk.Frame(box, bg=PANEL)
        cols.pack(fill="x")
        left, right = tk.Frame(cols, bg=PANEL), tk.Frame(cols, bg=PANEL)
        left.pack(side="left", fill="x", expand=True, anchor="n")
        right.pack(side="left", fill="x", expand=True, anchor="n", padx=(16, 0))
        if IS_WIN:  # (launch-offline.ps1 applies it; on Linux the game's own video settings do)
            self.toggle("Borderless fullscreen", self.borderless_var, self.toggle_borderless, left)
        self.toggle("Skip the intro video", self.skip_intro_var, self.toggle_skip_intro, left)
        self.toggle("Unlock all looks and voices", self.unlock_looks_var, self.toggle_unlock_looks, left)
        self.toggle("Minimize while playing", self.minimize_var, self.toggle_minimize, right)
        self.toggle("Check for new builds", self.update_check_var, self.toggle_update_check, right)
        share = tk.Frame(box, bg=PANEL)
        share.pack(fill="x", pady=(4, 0))
        tk.Label(share, text="Female enemies and crew", bg=PANEL, fg=TEXT, font=font(12), anchor="w").pack(side="left")
        self.share_label = tk.Label(share, bg=PANEL, fg=ORANGE, font=font(12, "SemiBold"), width=5, anchor="e")
        self.share_label.pack(side="right")
        tk.Scale(share, from_=0, to=100, resolution=5, orient="horizontal", variable=self.share_var, showvalue=False,
                 command=self.change_share, bg=ORANGE, troughcolor=PANEL_HI, activebackground=ORANGE, highlightthickness=0,
                 bd=0, sliderrelief="flat", sliderlength=18, width=10,
                 cursor="hand2").pack(side="left", fill="x", expand=True, padx=(12, 4))
        self.share_label.config(text=f"{self.share_var.get()}%")
        tk.Frame(box, bg=LINE, height=1).pack(fill="x", pady=(10, 0))

    def refresh(self):
        for w in self.list_box.winfo_children():
            w.destroy()
        self.cards = {}
        self.items = saves.listing()
        if self.selected not in [s["id"] for s in self.items]:
            self.selected = self.items[0]["id"] if self.items else None
        for s in self.items:
            self.card(s)
        self.show_selected()

    def card(self, s):
        on = s["id"] == self.selected
        bg = PANEL_HI if on else PANEL
        f = tk.Frame(self.list_box, bg=bg, cursor="hand2")
        f.pack(fill="x", pady=(0, 6))
        bar = tk.Frame(f, bg=ORANGE if on else bg, width=4)
        bar.pack(side="left", fill="y")
        inner = tk.Frame(f, bg=bg, padx=12, pady=8)
        inner.pack(side="left", fill="x", expand=True)
        name = s["name"] + ("     DAMAGED" if s.get("damaged") else "     CHEAT" if s.get("cheat") else "")
        a = tk.Label(inner, text=name, bg=bg, fg=TEXT, font=font(13, "SemiBold"), anchor="w")
        a.pack(fill="x")
        line = (f"Can't read this save   ·   last changed {when(s.get('played'))}" if s.get("damaged") else
                f"{s['cash']:,} cash   ·   {s['items']} items   ·   last played {when(s.get('played'))}")
        b = tk.Label(inner, text=line, bg=bg, fg=DANGER if s.get("damaged") else MUTED,
                     font=font(10), anchor="w")
        b.pack(fill="x")
        for w in (f, inner, a, b):
            w.bind("<Button-1>", lambda e, i=s["id"]: self.select(i))
            w.bind("<Double-Button-1>", lambda e, i=s["id"]: (self.select(i), self.launch()))

    def select(self, sid):
        self.selected = sid
        self.refresh()

    def current(self):
        return next((s for s in self.items if s["id"] == self.selected), None)

    def show_selected(self):
        s = self.current()
        live = not self.running and not self.updating and not self.tidying and s is not None
        ok = live and not s.get("damaged")
        for b in (self.b_rename, self.b_copy, self.play):
            b.enable(ok)
        self.b_delete.enable(live)
        self.b_undo.enable(ok and s.get("can_undo"))
        self.b_backup.enable(ok)
        self.b_give.enable(ok)
        if not s:
            self.d_name.config(text="No saves yet")
            self.d_mode.config(text="")
            self.d_info.config(text="Make a new save to start.")
            return
        self.d_name.config(text=s["name"])
        if s.get("damaged"):
            self.d_mode.config(text="Can't read this save")
            self.d_info.config(text=f"Its files in backend\\saves\\{s['id']}\nare missing or damaged. Share them on the\n"
                                    "Discord if you'd like help, or delete it.")
            self.cheat_var.set(False)
            return
        self.d_mode.config(text="Infinite money is on" if s.get("cheat") else "Normal save")
        self.d_info.config(text=f"Cash   {s['cash']:,}   ·   XP   {s['xp']:,}\nStash   {s['items']} items, {s['stash_rows']} rows\n"
                                f"Started   {when(s.get('created'))}")
        self.cheat_var.set(bool(s.get("cheat")))

    def say(self, text):
        self.status.config(text=text)
        if text:
            self.status.grid()
        else:
            self.status.grid_remove()

    # Save actions ---------------------------------------------------------------------------------------------------
    def new_save(self):
        if self.running:
            return
        d = Dialog(self, "New save")
        tk.Label(d.body, text="Name", bg=PANEL, fg=MUTED, font=font(11)).pack(anchor="w")
        name = entry(d.body)
        name.pack(fill="x", ipady=5, pady=(2, 12))
        name.insert(0, f"Save {len(self.items) + 1}")
        name.select_range(0, "end")
        tk.Label(d.body, text=f"Stash size in rows  ({saves.STASH_H} is normal, {saves.STASH_MIN} to {saves.STASH_MAX})",
                 bg=PANEL, fg=MUTED, font=font(11)).pack(anchor="w")
        rows = entry(d.body, width=8)
        rows.pack(anchor="w", ipady=5, pady=(2, 2))
        rows.insert(0, str(saves.STASH_H))
        tk.Label(d.body, text="This can't be changed later.", bg=PANEL, fg=MUTED, font=font(10)).pack(anchor="w", pady=(0, 10))
        gear, money = tk.BooleanVar(), tk.BooleanVar()
        check(d.body, "Start with lots of gear (a packed stash)", gear).pack(anchor="w")
        check(d.body, "Infinite money", money).pack(anchor="w")
        tk.Label(d.body, text="A new save starts from scratch: level 1, nothing unlocked,\nand just a pistol in your stash.\n"
                 "Infinite money can be switched later from the panel;\nthe starting gear can't (Give items can add more).",
                 bg=PANEL, fg=MUTED, font=font(10), justify="left").pack(anchor="w", pady=(8, 0))
        problem = tk.Label(d.body, text="", bg=PANEL, fg=ORANGE, font=font(11), justify="left")
        problem.pack(anchor="w", pady=(6, 0))

        def make():
            text = name.get().strip()
            if not text:
                return
            try:
                n = int(rows.get().strip())
            except ValueError:
                n = 0
            if not saves.STASH_MIN <= n <= saves.STASH_MAX:
                problem.config(text=f"Stash size: enter a number from {saves.STASH_MIN} to {saves.STASH_MAX}.")
                rows.focus_set()
                return
            try:
                sid = saves.create(text, gear.get(), money.get(), n)
            except (OSError, ValueError) as e:
                problem.config(text=f"Couldn't make the save: {e}")
                return
            d.destroy()
            self.selected = sid
            self.refresh()
            self.say(f"Made the save {text}.")

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "CREATE", make, "main", 11, (14, 6)).pack(side="left")
        d.show()
        name.focus_set()
        name.bind("<Return>", lambda e: make())

    def show_controls(self):
        d = Dialog(self, "Controls")
        grid = tk.Frame(d.body, bg=PANEL)
        grid.pack(anchor="w")
        for i, (key, what, where) in enumerate(CONTROLS):
            tk.Label(grid, text=key, bg=PANEL, fg=ORANGE, font=font(12, "SemiBold"), anchor="w").grid(row=i, column=0, sticky="nw", padx=(0, 14), pady=2)
            tk.Label(grid, text=what, bg=PANEL, fg=TEXT, font=font(11), anchor="w", justify="left", wraplength=wrap(380)).grid(row=i, column=1, sticky="w", pady=2)
            tk.Label(grid, text=where, bg=PANEL, fg=MUTED, font=font(10), anchor="w").grid(row=i, column=2, sticky="w", padx=(14, 0), pady=2)
        r = d.row()
        Button(r, "Close", d.destroy, "main", 11, (14, 6)).pack(side="left")
        d.show()

    @staticmethod
    def local_addresses():
        """This PC's IPv4 addresses a friend could join on: the LAN and any virtual LAN (ZeroTier, Hamachi, Tailscale)."""
        found = []
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                ip = info[4][0]
                if not ip.startswith("127.") and not ip.startswith("169.254.") and ip not in found:
                    found.append(ip)
        except OSError:
            pass
        return found

    def read_coop_host(self):
        try:
            with open(COOP_HOST, encoding="utf-8") as f:
                return f.read().strip() == "on"
        except OSError:
            return False

    def show_coop(self):
        """Co-op, direct (#201): host your raids for friends, or join a friend's raid by address. Each player plays from
        their own save; nothing of the stash is shared. Network setup: docs/COOP.md (#202)."""
        d = Dialog(self, "Co-op")
        host_var = tk.BooleanVar(value=self.read_coop_host())

        def toggle_host():
            self.write_setting(COOP_HOST, "on\n" if host_var.get() else "off\n")

        check(d.body, "Host: friends can join my raids", host_var, command=toggle_host, anchor="w").pack(fill="x")
        addrs = self.local_addresses()
        tk.Label(d.body, text=("Your addresses: " + ", ".join(addrs)) if addrs else "No network address found.",
                 bg=PANEL, fg=MUTED, font=font(11), anchor="w", justify="left", wraplength=wrap(400)).pack(fill="x", pady=(4, 0))
        tk.Label(d.body, text="Friends join on UDP port 7777. Start a raid as usual; they can join once you're in it.",
                 bg=PANEL, fg=MUTED, font=font(11), anchor="w", justify="left", wraplength=wrap(400)).pack(fill="x")
        tk.Frame(d.body, bg=LINE, height=1).pack(fill="x", pady=(14, 10))
        tk.Label(d.body, text="Join a friend's raid (their address, from their CO-OP box)", bg=PANEL, fg=TEXT,
                 font=font(12), anchor="w").pack(fill="x")
        box = entry(d.body, 13, 28)
        box.pack(fill="x", pady=(6, 0))
        try:
            with open(COOP_LAST, encoding="utf-8") as f:
                box.insert(0, f.read().strip())
        except OSError:
            pass
        tk.Label(d.body, text="Plays the selected save. The game starts and connects from its menu.", bg=PANEL, fg=MUTED,
                 font=font(11), anchor="w", justify="left", wraplength=wrap(400)).pack(fill="x", pady=(4, 0))

        def join():
            addr = box.get().strip()
            if not addr or any(c.isspace() or c in "?/\\" for c in addr):
                self.say("Type your friend's address, like 192.168.1.20 or 10.147.17.5:7777.")
                return
            if self.write_setting(COOP_LAST, addr) and self.write_setting(COOP_JOIN, addr + "\n"):
                d.destroy()
                self.launch(join=addr)

        r = d.row()
        Button(r, "Close", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "JOIN", join, "main", 11, (14, 6)).pack(side="left")
        box.bind("<Return>", lambda e: join())
        d.show()
        box.focus_set()

    def show_settings(self):
        """Every F10 setting, before a raid (#324, inspired by SPT's SVM): tabs on the left, the tab's settings on the
        right, difficulty and your own presets on top, which you can save, export to share, and import. Changes are
        written at once to the file F10 uses (config/ai_tuning.txt), which the game reads when it starts; F10 in a raid
        still changes things live. The list of settings comes from the mod (config/settings_schema.json)."""
        d = Dialog(self, "Settings")
        self.app_options(d.body)
        schema = settings.load_schema()
        if not schema:
            tk.Label(d.body, text="Start the game once with this build (to the lobby is enough): it writes the list of "
                     "settings this page shows. Until then, press F10 in a raid to change them.", bg=PANEL, fg=TEXT,
                     font=font(11), justify="left", wraplength=wrap(460)).pack(anchor="w")
            r = d.row()
            Button(r, "Close", d.destroy, size=11, pad=(14, 6)).pack(side="left")
            d.show()
            return
        values = settings.read_values()
        mine = settings.read_presets()
        known = {r["id"]: r for r in settings.rows(schema)}
        state = {"tab": 0}
        status = None

        def value(r):
            return values.get(r["id"], r["default"])

        def status_text():
            n = settings.changed_count(schema, values)
            run = "  The game is running: these apply next time it starts (F10 changes them now)." if game_running() else ""
            return (f"{n} setting(s) changed from the defaults." if n else "Everything at its default.") + run

        def save():
            try:
                settings.write_values(schema, values)
            except OSError as e:
                self.say(f"Couldn't save the settings: {e}")
            if status is not None:
                status.config(text=status_text())

        # Presets: the difficulty levels (they set the values they name, and put the ones another level names back to
        # their defaults), then your own (a whole setup: anything a preset leaves out is at its default).
        top = tk.Frame(d.body, bg=PANEL)
        top.pack(fill="x")
        tk.Label(top, text="Difficulty", bg=PANEL, fg=MUTED, font=font(11)).pack(side="left", padx=(0, 8))

        def apply_builtin(p):
            for other in schema["presets"]:
                for key in other["values"]:
                    if key in known and key not in p["values"]:
                        values.pop(key, None)
            for key, v in p["values"].items():
                if key in known:
                    values[key] = v
            save()
            show_tab(state["tab"])
            self.say(f"Difficulty: {p['name']}.")

        for p in schema["presets"]:
            Button(top, p["name"], lambda p=p: apply_builtin(p), size=10, pad=(10, 4)).pack(side="left", padx=(0, 4))
        mine_row = tk.Frame(d.body, bg=PANEL)
        mine_row.pack(fill="x", pady=(8, 0))
        tk.Label(mine_row, text="My presets", bg=PANEL, fg=MUTED, font=font(11)).pack(side="left", padx=(0, 8))
        pick = tk.StringVar(value=mine[0]["name"] if mine else "")
        menu_holder = tk.Frame(mine_row, bg=PANEL)
        menu_holder.pack(side="left")

        def rebuild_menu():
            for w in menu_holder.winfo_children():
                w.destroy()
            names = [m["name"] for m in mine] or ["(none yet)"]
            if pick.get() not in names:
                pick.set(names[0])
            om = tk.OptionMenu(menu_holder, pick, *names)
            om.config(bg=PANEL_HI, fg=TEXT, activebackground=LINE, activeforeground=TEXT, highlightthickness=0, bd=0,
                      font=font(10), width=18)
            om["menu"].config(bg=PANEL_HI, fg=TEXT, activebackground=ORANGE, font=font(10))
            om.pack(side="left")

        def chosen():
            return next((m for m in mine if m["name"] == pick.get()), None)

        def load_mine():
            m = chosen()
            if not m:
                return self.say("No preset picked: save one first, or import one.")
            values.clear()
            values.update(m["values"])
            save()
            show_tab(state["tab"])
            self.say(f"Loaded the preset \"{m['name']}\".")

        def save_mine():
            ask = Dialog(self, "Save as preset")
            box = entry(ask.body, 13, 28)
            box.pack(fill="x")
            box.insert(0, chosen()["name"] if chosen() else "My preset")

            def done():
                name = settings.clean_name(box.get())
                if not name:
                    return
                current = {k: v for k, v in values.items()
                           if k not in known or not settings.same(known[k], v, known[k]["default"])}
                for m in mine:
                    if m["name"] == name:
                        m["values"] = current
                        break
                else:
                    mine.append({"name": name, "values": current})
                try:
                    settings.write_presets(mine)
                except OSError as e:
                    return self.say(f"Couldn't save the preset: {e}")
                pick.set(name)
                rebuild_menu()
                ask.destroy()
                self.say(f"Saved the preset \"{name}\" (F10's Saved setups lists it too).")

            r = ask.row()
            Button(r, "Cancel", ask.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
            Button(r, "SAVE", done, "main", 11, (14, 6)).pack(side="left")
            box.bind("<Return>", lambda e: done())
            ask.show()
            box.focus_set()

        def delete_mine():
            m = chosen()
            if m:
                mine.remove(m)
                settings.write_presets(mine)
                rebuild_menu()
                self.say(f"Deleted the preset \"{m['name']}\".")

        def export_mine():
            m = chosen()
            if not m:
                return self.say("Pick a preset to export (save one first).")
            path = filedialog.asksaveasfilename(parent=d, title="Share a preset", defaultextension=".txt",
                                                initialfile=f"{m['name']}.txt", filetypes=[("Preset", "*.txt")])
            if path:
                try:
                    settings.export_preset(m, path)
                    self.say(f"Exported to {os.path.basename(path)}: send it to a friend, who presses Import...")
                except OSError as e:
                    self.say(f"Couldn't export: {e}")

        def import_mine():
            path = filedialog.askopenfilename(parent=d, title="A shared preset",
                                              filetypes=[("Preset", "*.txt"), ("All files", "*.*")])
            if not path:
                return
            p = settings.import_preset(path)
            if not p:
                return self.say("That file has no preset in it.")
            names = {m["name"] for m in mine}
            base, n = p["name"], 2
            while p["name"] in names:
                p["name"], n = f"{base} ({n})", n + 1
            mine.append(p)
            settings.write_presets(mine)
            pick.set(p["name"])
            rebuild_menu()
            self.say(f"Imported \"{p['name']}\". Press Load to use it.")

        rebuild_menu()
        for label, fn in (("Load", load_mine), ("Save as...", save_mine), ("Delete", delete_mine),
                          ("Export...", export_mine), ("Import...", import_mine)):
            Button(mine_row, label, fn, size=10, pad=(10, 4)).pack(side="left", padx=(6, 0))

        tk.Frame(d.body, bg=LINE, height=1).pack(fill="x", pady=(12, 10))
        main = tk.Frame(d.body, bg=PANEL)
        main.pack(fill="both")
        tab_list = tk.Frame(main, bg=PANEL)
        tab_list.pack(side="left", fill="y", padx=(0, 14))
        holder = tk.Frame(main, bg=PANEL)
        holder.pack(side="left", fill="both")
        k = self.scale_factor()
        canvas = tk.Canvas(holder, bg=PANEL, highlightthickness=0, width=int(560 * k), height=int(400 * k))
        bar = scrollbar(holder, command=canvas.yview)
        canvas.configure(yscrollcommand=bar.set)
        canvas.pack(side="left", fill="both")
        bar.pack(side="left", fill="y")
        inner = tk.Frame(canvas, bg=PANEL)
        canvas.create_window((0, 0), window=inner, anchor="nw", width=int(560 * k))
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))

        def wheel(ev):
            canvas.yview_scroll(-int(ev.delta / 120) or (-1 if ev.delta > 0 else 1), "units")

        canvas.bind("<Enter>", lambda e: canvas.bind_all("<MouseWheel>", wheel))
        canvas.bind("<Leave>", lambda e: canvas.unbind_all("<MouseWheel>"))
        d.bind("<Destroy>", lambda e: e.widget is d and canvas.unbind_all("<MouseWheel>"))
        tab_buttons = []

        def fmt(r, v):
            step = r.get("step") or 1
            return f"{v:.0f}" if step >= 1 else (f"{v:.1f}" if step >= 0.1 else f"{v:.2f}")

        def caption(r, v):
            return fmt(r, v) + ("" if settings.same(r, v, r["default"]) else f"   (normally {fmt(r, r['default'])})")

        def show_tab(i):
            state["tab"] = i
            for j, b in enumerate(tab_buttons):
                b.config(fg=ORANGE if j == i else TEXT)
            for w in inner.winfo_children():
                w.destroy()
            for r in schema["tabs"][i]["rows"]:
                box = tk.Frame(inner, bg=PANEL)
                box.pack(fill="x", pady=(0, 8))
                head_row = tk.Frame(box, bg=PANEL)
                head_row.pack(fill="x")
                tk.Label(head_row, text=r["label"], bg=PANEL, fg=TEXT, font=font(11), anchor="w").pack(side="left")
                shown = tk.Label(head_row, text=caption(r, value(r)), bg=PANEL, fg=ORANGE, font=font(11, "SemiBold"))
                shown.pack(side="right")
                var = tk.DoubleVar(value=value(r))

                def changed(_=None, r=r, var=var, shown=shown):
                    v = settings.clamp(r, var.get())
                    if settings.same(r, v, r["default"]):
                        values.pop(r["id"], None)
                    else:
                        values[r["id"]] = v
                    shown.config(text=caption(r, v))
                    save()

                def reset(r=r, var=var, changed=changed):
                    var.set(r["default"])
                    changed()

                line = tk.Frame(box, bg=PANEL)
                line.pack(fill="x")
                tk.Scale(line, from_=r["min"], to=r["max"], resolution=r.get("step") or 1, orient="horizontal",
                         variable=var, showvalue=False, command=changed, bg=ORANGE, troughcolor=PANEL_HI,
                         activebackground=ORANGE, highlightthickness=0, bd=0, sliderrelief="flat", sliderlength=16,
                         width=9, cursor="hand2").pack(side="left", fill="x", expand=True)
                Button(line, "Default", reset, size=9, pad=(8, 2)).pack(side="left", padx=(8, 0))
                if r.get("help"):
                    tk.Label(box, text=r["help"], bg=PANEL, fg=MUTED, font=font(9), anchor="w", justify="left",
                             wraplength=wrap(520)).pack(fill="x")
            canvas.yview_moveto(0)

        for i, t in enumerate(schema["tabs"]):
            b = tk.Label(tab_list, text=t["name"], bg=PANEL, fg=TEXT, font=font(11), anchor="w", cursor="hand2")
            b.pack(fill="x", pady=1)
            b.bind("<Button-1>", lambda e, i=i: show_tab(i))
            tab_buttons.append(b)

        def reset_tab():
            for r in schema["tabs"][state["tab"]]["rows"]:
                values.pop(r["id"], None)
            save()
            show_tab(state["tab"])

        def reset_all():
            for key in [x for x in values if x in known]:
                values.pop(key)
            save()
            show_tab(state["tab"])

        status = tk.Label(d.body, text=status_text(), bg=PANEL, fg=MUTED, font=font(10), anchor="w", justify="left",
                          wraplength=wrap(700))
        status.pack(fill="x", pady=(10, 0))
        r = d.row()
        Button(r, "Reset this tab", reset_tab, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "Reset all", reset_all, "danger", 11, (14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "Done", d.destroy, "main", 11, (14, 6)).pack(side="left")
        show_tab(0)
        d.show()

    def scale_factor(self):
        """Display scaling (1.0 at 100 %), for sizes given in pixels."""
        try:
            return max(1.0, self.winfo_fpixels("1i") / 96)
        except tk.TclError:
            return 1.0

    def backup(self):
        s = self.current()
        if not s:
            return
        try:
            path = saves.export(s["id"])
        except OSError as e:
            return self.say(f"Couldn't back up: {e}")
        self.say(f"Backed up to {os.path.basename(path)} (Desktop). IMPORT brings it back.")
        reveal(path)

    def import_saves(self):
        d = Dialog(self, "Import saves")
        tk.Label(d.body, text="Bring saves in from a backup zip (made with Back up), or from an older copy of the mod: pick "
                 "its folder and every save in it is copied here. Nothing at the source is changed.",
                 bg=PANEL, fg=TEXT, font=font(11), justify="left", wraplength=wrap(480)).pack(anchor="w")

        def run(path):
            d.destroy()
            if not path:
                return
            try:
                names = saves.import_from(path)
            except (OSError, ValueError, KeyError) as e:
                return self.say(f"Couldn't import: {e}")
            self.refresh()
            self.say(f"Imported: {', '.join(names)}." if names else "No saves found there.")

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "Old install folder...", lambda: run(filedialog.askdirectory(parent=d, title="The older Marauders Offline folder")),
               size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "Backup zip...", lambda: run(filedialog.askopenfilename(parent=d, title="A save backup",
               filetypes=[("Save backup", "*.zip")])), "main", 11, (14, 6)).pack(side="left")
        d.show()

    def report_problem(self):
        d = Dialog(self, "Report a problem")
        tk.Label(d.body, wraplength=wrap(520), text="Makes one zip on your Desktop with the logs from your last game, for a Discord post or a "
                 "GitHub issue. Your Windows user name, Steam IDs and in-game name are taken out first.",
                 bg=PANEL, fg=TEXT, font=font(11), justify="left").pack(anchor="w")
        with_save = tk.BooleanVar(value=False)
        with_dump = tk.BooleanVar(value=True)
        for text, var in (("Include the selected save (helps with stash and progress problems)", with_save),
                          ("Include the last crash dump (helps most with crashes; it holds part of the game's memory)", with_dump)):
            check(d.body, text, var, size=11, anchor="w").pack(anchor="w", pady=(8, 0))

        def make():
            s = self.current()
            save_dir = os.path.join(saves.SAVES, s["id"]) if with_save.get() and s else None
            try:
                path, files = report.build(ROOT, game_folder(), save_dir, with_dump.get())
            except Exception as e:  # (a report must never take the launcher down)
                d.destroy()
                return self.say(f"Couldn't make the report: {e}")
            d.destroy()
            self.say(f"Report saved: {os.path.basename(path)} ({len(files)} files). Attach it to your Discord post or issue.")
            reveal(path)

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "MAKE REPORT", make, "main", 11, (14, 6)).pack(side="left")
        d.show()

    def rename(self):
        s = self.current()
        d = Dialog(self, "Rename save")
        name = entry(d.body)
        name.pack(fill="x", ipady=5)
        name.insert(0, s["name"])
        name.select_range(0, "end")

        def done():
            text = name.get().strip()
            if text:
                saves.rename(s["id"], text)
                self.refresh()
            d.destroy()

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "RENAME", done, "main", 11, (14, 6)).pack(side="left")
        d.show()
        name.focus_set()
        name.bind("<Return>", lambda e: done())

    def copy(self):
        self.selected = saves.copy(self.selected)
        self.refresh()
        self.say("Save copied.")

    def confirm(self, title, text, label, action):
        d = Dialog(self, title)
        tk.Label(d.body, text=text, bg=PANEL, fg=TEXT, font=font(12), justify="left", wraplength=wrap(400)).pack(anchor="w")

        def yes():
            d.destroy()
            action()

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, label, yes, "danger", 11, (14, 6)).pack(side="left")
        d.show()

    def delete(self):
        s = self.current()

        def gone():
            saves.delete(s["id"])
            self.selected = None
            self.refresh()
            self.say(f"Deleted {s['name']}.")

        self.confirm("Delete save", f"Delete {s['name']} for good? This can't be undone.", "DELETE", gone)

    def undo(self):
        s = self.current()

        def back():
            saves.undo_last_raid(s["id"])
            self.refresh()
            self.say("Back to the start of your last raid.")

        self.confirm("Undo last raid", f"Put {s['name']} back to the moment the last raid started? Your ship and gear come back, and "
                                       "anything you gained in that raid is lost.", "UNDO RAID", back)

    def give_items(self):
        """Debug: adds chosen items to the selected save's stash and sets its cash (issue #136). Only while the game is
        closed: a running game works on backend/state.json and would write over the save when it ends."""
        s = self.current()
        if not s or s.get("damaged") or self.running:
            return
        sid = s["id"]
        rows = saves.item_rows()
        d = Dialog(self, "Give items or cash")
        tk.Label(d.body, text=f"Into {s['name']}'s stash. Type to search the item list.", bg=PANEL, fg=MUTED,
                 font=font(11)).pack(anchor="w")
        search = entry(d.body, 13)
        search.pack(fill="x", ipady=4, pady=(4, 6))
        box = tk.Frame(d.body, bg=PANEL)
        box.pack(fill="x")
        pick = tk.Listbox(box, bg=INK, fg=TEXT, selectbackground=ORANGE, selectforeground=INK, relief="flat", font=font(12),
                          height=10, activestyle="none", highlightthickness=0, exportselection=False)
        bar = scrollbar(box, command=pick.yview)
        pick.config(yscrollcommand=bar.set)
        pick.pack(side="left", fill="both", expand=True)
        bar.pack(side="right", fill="y")
        shown = []

        def filter_list(_=None):
            text = search.get().strip().lower()
            shown[:] = [r for r in rows if text in r.lower()]
            pick.delete(0, "end")
            for r in shown:
                pick.insert("end", r)
            if shown:
                pick.selection_set(0)

        line = tk.Frame(d.body, bg=PANEL)
        line.pack(fill="x", pady=(8, 0))
        tk.Label(line, text="How many", bg=PANEL, fg=MUTED, font=font(11)).pack(side="left")
        count = entry(line, 13, 6)
        count.pack(side="left", ipady=3, padx=(8, 8))
        count.insert(0, "1")
        tk.Frame(d.body, bg=LINE, height=1).pack(fill="x", pady=(12, 10))
        cash_line = tk.Frame(d.body, bg=PANEL)
        cash_line.pack(fill="x")
        tk.Label(cash_line, text="Cash", bg=PANEL, fg=MUTED, font=font(11)).pack(side="left")
        cash = entry(cash_line, 13, 12)
        cash.pack(side="left", ipady=3, padx=(8, 8))
        cash.insert(0, str(s["cash"]))
        note = tk.Label(d.body, text="", bg=PANEL, fg=ORANGE, font=font(11), justify="left", wraplength=wrap(400))
        note.pack(anchor="w", pady=(10, 0))

        def add():
            sel = pick.curselection()
            if not sel:
                note.config(text="Pick an item from the list first.")
                return
            row = shown[sel[0]]
            try:
                n = int(count.get().strip())
            except ValueError:
                n = 0
            if not 1 <= n <= 9999:
                note.config(text="How many: enter a number from 1 to 9999.")
                count.focus_set()
                return
            try:
                got = saves.give(sid, row, n)
            except (OSError, ValueError) as e:
                note.config(text=f"Couldn't add it: {e}")
                return
            self.refresh()
            note.config(text=f"Added {got} {row}." if got == n else
                        f"Added {got} of {n} {row}: the stash is full." if got else "No room in the stash for that.")

        def set_money():
            try:
                n = int(cash.get().strip().replace(",", ""))
            except ValueError:
                n = -1
            if not 0 <= n <= saves.CHEAT_CASH:
                note.config(text=f"Cash: enter a number from 0 to {saves.CHEAT_CASH:,}.")
                cash.focus_set()
                return
            saves.set_cash(sid, n)
            self.refresh()
            note.config(text=f"Cash set to {n:,}." + ("  (Infinite money is on for this save.)" if s.get("cheat") else ""))

        Button(line, "ADD TO STASH", add, "main", 11, (12, 4)).pack(side="left")
        Button(cash_line, "SET CASH", set_money, "main", 11, (12, 4)).pack(side="left")
        r = d.row()
        Button(r, "Close", d.destroy, size=11, pad=(14, 6)).pack(side="left")
        search.bind("<KeyRelease>", filter_list)
        search.bind("<Return>", lambda e: add())
        pick.bind("<Double-Button-1>", lambda e: add())
        count.bind("<Return>", lambda e: add())
        cash.bind("<Return>", lambda e: set_money())
        filter_list()
        d.show()
        search.focus_set()

    def toggle_cheat(self):
        s = self.current()
        if s and not s.get("damaged") and not self.running:
            saves.set_cheat(self.selected, self.cheat_var.get())
            self.refresh()
        else:
            self.show_selected()

    def write_setting(self, path, text):
        """Writes one of the small settings files. Says so on the status line if it can't: the box would look set but
        not be."""
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            return True
        except OSError as e:
            self.say(f"Couldn't save that setting ({os.path.relpath(path, ROOT)}): {e.strerror or e}")
            return False

    def read_female(self):
        try:
            with open(FEMALE_SETTING, encoding="utf-8") as f:
                return f.read().strip() == "on"
        except OSError:
            return False

    def toggle_female(self):
        self.write_setting(FEMALE_SETTING, "on\n" if self.female_var.get() else "off\n")

    def read_share(self):
        try:
            with open(FEMALE_SHARE, encoding="utf-8") as f:
                return max(0, min(100, int(round(float(f.read().strip())))))
        except (OSError, ValueError):
            return FEMALE_SHARE_DEFAULT

    def change_share(self, _=None):
        # rivals, soldiers, station guards and new crew recruits; the game picks it up within a few seconds
        value = self.share_var.get()
        self.share_label.config(text=f"{value}%")
        self.write_setting(FEMALE_SHARE, f"{value}\n")

    def read_raid_length(self):
        try:
            with open(RAID_LENGTH, encoding="utf-8") as f:
                return RAID_LENGTHS.index(f.read().strip().lower())
        except (OSError, ValueError):
            return 0

    @staticmethod
    def raid_length_text(i):
        v = RAID_LENGTHS[i]
        return {"default": "25 min", "none": "no limit"}.get(v, f"{v} min")

    def change_raid_length(self, _=None):
        # the oxygen countdown of the next raid (raidtime.lua sets the game's own timer at raid start)
        i = self.length_var.get()
        self.length_label.config(text=self.raid_length_text(i))
        self.write_setting(RAID_LENGTH, RAID_LENGTHS[i] + "\n")

    def read_gate_time(self):
        try:
            with open(GATE_TIME, encoding="utf-8") as f:
                return GATE_TIMES.index(f.read().strip().lower())
        except (OSError, ValueError):
            return 0

    @staticmethod
    def gate_time_text(i):
        v = GATE_TIMES[i]
        return v if v in ("default", "instant") else f"{v} min"

    def change_gate_time(self, _=None):
        # when the space gate arrives in the next raid, counted from the start of the raid (raidtime.lua)
        i = self.gate_var.get()
        self.gate_label.config(text=self.gate_time_text(i))
        self.write_setting(GATE_TIME, GATE_TIMES[i] + "\n")

    @staticmethod
    def raid_conditions():
        """[(name, about)] from the shipped and your own conditions files, Normal first (conditions.lua's order)."""
        out = {"Normal": "The usual raid."}
        for path in RAID_CONDITIONS:
            try:
                with open(path, encoding="utf-8") as f:
                    name = None
                    for line in f:
                        line = line.strip()
                        if line.startswith("[") and line.endswith("]"):
                            name = line[1:-1]
                            out[name] = ""
                        elif name and line.split("=", 1)[0].strip() == "about" and "=" in line:
                            out[name] = line.split("=", 1)[1].strip()
            except OSError:
                pass
        return list(out.items())

    def read_condition(self):
        try:
            with open(RAID_CONDITION, encoding="utf-8") as f:
                return f.read().strip() or "Normal"
        except OSError:
            return "Normal"

    def show_condition(self, tell=False):
        conds = dict(self.raid_conditions())
        name = self.read_condition()
        if name not in conds:
            name = "Normal"
        self.cond_label.config(text=name)
        self.cond_about.config(text=conds[name] or "")
        if tell:
            self.say(f"Raid conditions: {name}")

    def cycle_condition(self, step):
        names = [n for n, _ in self.raid_conditions()]
        cur = self.read_condition()
        i = names.index(cur) if cur in names else 0
        name = names[(i + step) % len(names)]
        if name == "Normal":
            try:
                os.remove(RAID_CONDITION)
            except OSError:
                pass
        else:
            self.write_setting(RAID_CONDITION, name + "\n")
        self.show_condition(tell=True)

    def read_borderless(self):
        try:
            with open(WINDOW_SETTING, encoding="utf-8") as f:
                return f.read().strip() == "borderless"
        except OSError:
            return False

    def read_skip_intro(self):
        try:
            with open(SKIP_INTRO_SETTING, encoding="utf-8") as f:
                return f.read().strip() == "on"
        except OSError:
            return False

    def read_unlock_looks(self):
        try:
            with open(UNLOCK_LOOKS_SETTING, encoding="utf-8") as f:
                return f.read().strip() == "on"
        except OSError:
            return False

    def toggle_unlock_looks(self):
        # every head, body and voice unlocked from the next login on; off brings back what the save earned
        self.write_setting(UNLOCK_LOOKS_SETTING, "on\n" if self.unlock_looks_var.get() else "off\n")

    def read_minimize(self):
        try:
            with open(MINIMIZE_SETTING, encoding="utf-8") as f:
                return f.read().strip() != "off"
        except OSError:
            return True

    def toggle_minimize(self):
        self.write_setting(MINIMIZE_SETTING, "on\n" if self.minimize_var.get() else "off\n")

    def read_update_check(self):
        try:
            with open(UPDATE_CHECK_SETTING, encoding="utf-8") as f:
                return f.read().strip() != "off"
        except OSError:
            return True

    def toggle_update_check(self):
        self.write_setting(UPDATE_CHECK_SETTING, "on\n" if self.update_check_var.get() else "off\n")
        if self.update_check_var.get():
            self.check_update()
        else:
            self.show_update(None)

    # Updates --------------------------------------------------------------------------------------------------------
    def check_update(self):
        """Asks GitHub for the latest build off the UI thread; the update button lights up only if it's newer than
        version.txt, and otherwise says why not (up to date, can't check when offline or rate-limited, a dev checkout)."""
        current = update.installed()
        if not current:
            self.show_update(None, "DEV BUILD")
            return
        if not self.update_check_var.get():
            self.show_update(None, "UPDATES OFF")
            return
        self.show_update(None, "CHECKING...")

        def work():
            latest = update.latest()
            rel = update.newer(latest, current)
            self.ui(lambda: self.show_update(rel, "UP TO DATE" if latest else "CAN'T CHECK"))
            if rel:
                return  # updating fetches the changed dependencies anyway
            # Dependencies that don't match this build's deps.json (an update by a launcher from before deps.json, or
            # files gone missing): put back from this build's own release.
            parts = update.stale_deps(update.installed_deps())
            own = parts and update.release(current)
            if own:
                self.ui(lambda: self.start_repair(own, parts))
        threading.Thread(target=work, daemon=True).start()

    def show_update(self, release, idle="UP TO DATE"):
        """The update button: lit with the new build's name, or greyed out with `idle` (why there's nothing to do)."""
        self.release = release
        if release and self.update_check_var.get():
            self.update_button.config(text=f"UPDATE TO {release['tag'].replace('public-test-', 'BUILD ')}")
            self.update_button.enable(True)
            self.update_mark.pack(side="left", fill="y", before=self.update_button)
        else:
            if not self.update_check_var.get() and update.installed():
                idle = "UPDATES OFF"
            self.update_button.config(text=idle)
            self.update_button.enable(False)
            self.update_mark.pack_forget()

    def offer_update(self):
        rel = self.release
        if not rel or self.updating:
            return
        if self.running or game_running():
            self.say("Close the game before updating.")
            return
        d = Dialog(self, "New build")
        size = f" ({rel['size'] / 1e6:.0f} MB, more if UE4SS or the outfit meshes changed)" if rel.get("size") else ""
        tk.Label(d.body, text=f"{rel['tag']} is out; you have {update.installed()}.\n\nUPDATE downloads it{size}, checks it, and "
                              "installs it over this folder. Your saves and launcher settings are kept. The launcher restarts "
                              "when it's done.", bg=PANEL, fg=TEXT, font=font(12), justify="left", wraplength=wrap(400)).pack(anchor="w")

        def page():
            d.destroy()
            webbrowser.open(rel["page"])

        def go():
            d.destroy()
            self.start_update(rel)

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "What's new", page, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        if rel.get("sha256"):
            Button(r, "UPDATE", go, "main", 11, (14, 6)).pack(side="left")
        d.show()

    def start_update(self, rel):
        self.updating = True
        self.play.enable(False)
        self.update_button.enable(False)

        progress = self.download_progress(f"Downloading {rel['tag']}")

        def work():
            tmp = tempfile.mkdtemp(prefix="pve-update-")
            try:
                paths = update.download_update(rel, tmp, progress)
                self.ui(lambda: self.say("Installing..."))
                version = update.install(paths)
            except Exception as e:
                err = str(e) or type(e).__name__
                self.ui(lambda: self.update_failed(rel, err))
                return
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
            self.ui(lambda: self.update_done(version))
        threading.Thread(target=work, daemon=True).start()

    def download_progress(self, what):
        """progress(done, total) for update.py: a status line in MB, from any thread."""
        def progress(done, total):
            text = f"{what}... {done / 1e6:.1f} of {total / 1e6:.1f} MB" if total else f"{what}..."
            self.ui(lambda: self.say(text))
        return progress

    def start_repair(self, rel, parts):
        """Downloads the dependency parts (UE4SS, outfit meshes) this build needs and doesn't have, from its release.
        PLAY waits for it."""
        if self.updating or self.running or game_running():
            return
        self.updating = True
        self.play.enable(False)
        self.update_button.enable(False)
        progress = self.download_progress(f"Fetching files {rel['tag']} changed")

        def work():
            tmp = tempfile.mkdtemp(prefix="pve-update-")
            try:
                update.install(update.download_repair(rel, parts, tmp, progress), release_zip=False)
                text = "Fetched the files this build changed."
            except Exception as e:
                text = f"Couldn't fetch the files this build changed ({str(e) or type(e).__name__}): the release page has them."
            finally:
                shutil.rmtree(tmp, ignore_errors=True)

            def done():
                self.updating = False
                self.update_button.enable(True)
                self.show_selected()
                self.say(text)
            self.ui(done)
        threading.Thread(target=work, daemon=True).start()

    def update_failed(self, rel, err):
        self.updating = False
        self.update_button.enable(True)
        self.show_selected()
        self.say(f"Update failed, nothing changed: {err}. You can get it from the release page instead.")

    def update_done(self, version):
        self.say(f"Updated to {version}. Restarting...")
        # --after-update: the new launcher waits for this one to close instead of stepping aside for it
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--after-update"], cwd=ROOT)
        self.after(500, self.destroy)

    def toggle_skip_intro(self):
        # takes effect at the next Play (scripts/mode.ps1 offline swaps the startup video)
        self.write_setting(SKIP_INTRO_SETTING, "on\n" if self.skip_intro_var.get() else "off\n")

    def toggle_borderless(self):
        # takes effect at the next Play
        self.write_setting(WINDOW_SETTING, "borderless\n" if self.borderless_var.get() else "windowed\n")

    # Playing --------------------------------------------------------------------------------------------------------
    def launch(self, join=None):
        if not join:  # PLAY: no join left over from a JOIN whose game never started (the mod deletes it when it joins)
            try:
                os.remove(COOP_JOIN)
            except OSError:
                pass
        if self.running or self.updating or self.tidying or not self.current() or self.current().get("damaged"):
            return
        if game_running():
            self.say("The game is already running. Close it first.")
            return
        problem = preflight()
        if problem and not steam_running() and problem.startswith("Start Steam"):
            try:  # (#98) start it for you rather than only saying so
                open_url("steam://open/main")
                self.say("Starting Steam... press PLAY again once it's up.")
            except OSError:
                self.say(problem)
            return
        if problem:
            self.say(problem)
            return
        self.launch_error = None
        self.running = True
        self.seen = False
        self.started = time.time()
        s = self.current()
        self.show_selected()
        self.say(f"Starting {s['name']} to join {join}..." if join else f"Starting {s['name']}...")
        threading.Thread(target=self.start_game if IS_WIN else self.start_game_linux, args=(s["id"],), daemon=True).start()

    def start_game_linux(self, sid):
        """Linux: the launch option does the rest (pvemode.py steam-run plays the save named in config/linux_save.txt)."""
        if linux_launch_option() is False:
            self.launch_error = ("Steam's launch option for Marauders isn't set: run linux/install.sh and paste the line it "
                                 "prints into Marauders > Properties > Launch options.")
            self.started = 0
            return
        with open(pvemode.SAVE_SETTING, "w", encoding="utf-8") as f:
            f.write(sid + "\n")
        if pvemode.setting(pvemode.STEAM_SETTING, "on") == "off":
            with open(pvemode.STEAM_SETTING, "w", encoding="utf-8") as f:
                f.write("on\n")  # PLAY here means the mod, even if the launch option was switched to the stock game
        try:
            open_url("steam://rungameid/" + STEAM_APPID)
        except OSError as e:
            self.launch_error = f"couldn't ask Steam to start the game ({e})."
            self.started = 0
            return
        self.ui(lambda: self.say("Steam is starting the game. Leave this window open: it shows when your game is saved."))

    def start_game(self, sid):
        stop_standin()
        saves.activate(sid)
        result = ps("-File", os.path.join(ROOT, "scripts", "launch-offline.ps1"))
        if result.returncode != 0:
            # Tidy up at once (watch() sees the timeout) and say why, instead of waiting START_TIMEOUT in silence.
            self.launch_error = ps_error(result)
            self.started = 0
            return
        self.ui(lambda: self.say("Playing. Leave this window open: it saves when you close the game."))

    def watch(self):
        # Tidying up only starts once the game has been seen running: until then "no game" just means it's still starting.
        if self.running:
            if game_running():
                if not self.seen and self.minimize_var.get():
                    self.iconify()  # (#98) out of the way while playing; done() brings it back after saving
                self.seen = True
            elif self.seen or time.time() - self.started > START_TIMEOUT:
                if not self.seen:
                    self.say("The game didn't start.")
                else:
                    self.say("Saving...")
                self.running = None
                threading.Thread(target=self.finish, daemon=True).start()
        self.after(1500, self.watch)

    def finish(self):
        time.sleep(3)
        if not IS_WIN:
            # steam-run settles the save and puts the folder back once the game is gone: wait for it to finish
            deadline = time.time() + 60
            while os.path.exists(pvemode.DIRTY) and time.time() < deadline:
                time.sleep(1)
            if os.path.exists(pvemode.DIRTY):
                pvemode.recover()
            self.ui(self.done)
            return
        stop_standin()
        saves.settle()
        try:  # going back to stock removes the game log: this keeps the last one
            shutil.copyfile(GAME_LOG, os.path.join(ROOT, "backend", "last_game.log"))
        except OSError:
            pass
        ps("-File", os.path.join(ROOT, "scripts", "mode.ps1"), "online")
        self.ui(self.done)

    def done(self):
        self.running = False
        if self.state() == "iconic":
            self.deiconify()
            self.lift()
        self.refresh()
        if self.launch_error and not self.seen:
            self.say(f"The game didn't start: {self.launch_error} Nothing changed; the normal online game works as usual.")
            return
        self.say(("Saved. " if self.seen else "The game didn't start, so nothing changed. ") + "The normal online game works as usual.")


def single_instance(wait=0.0):
    """True if this is the only launcher. A second one used to tidy up a game the first had just started (settle()
    before the game was up), so that raid's progress never reached the save. A second launch now brings the first
    window forward and quits. Windows drops the mutex when the process ends, even in a crash; on Linux the lock file's
    lock goes with the process the same way (the window can't be brought forward there: it says so instead)."""
    if not IS_WIN:
        import fcntl
        single_instance.handle = open(os.path.join(tempfile.gettempdir(), "marauders-offline-launcher.lock"), "w")
        deadline = time.time() + wait
        while True:
            try:
                fcntl.flock(single_instance.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if time.time() >= deadline:
                    print("The Marauders Offline launcher is already open.")
                    return False
                time.sleep(0.25)
    kernel, user = ctypes.windll.kernel32, ctypes.windll.user32
    kernel.CreateMutexW.restype = ctypes.c_void_p
    deadline = time.time() + wait
    while True:
        handle = kernel.CreateMutexW(None, False, "Local\\MaraudersOfflineLauncher")
        if handle and kernel.GetLastError() != 183:  # ERROR_ALREADY_EXISTS
            single_instance.handle = handle  # held for the life of the process
            return True
        if handle:
            kernel.CloseHandle(ctypes.c_void_p(handle))
        if time.time() >= deadline:
            break
        time.sleep(0.25)
    hwnd = user.FindWindowW(None, "Marauders Offline")
    if hwnd:
        user.ShowWindow(hwnd, 9)  # SW_RESTORE
        user.SetForegroundWindow(hwnd)
    return False


if __name__ == "__main__":
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (OSError, AttributeError):
        pass
    if single_instance(wait=15 if "--after-update" in sys.argv else 0):
        App().mainloop()
