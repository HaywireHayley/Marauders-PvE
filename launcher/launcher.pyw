"""Marauders Offline launcher: pick or manage a save and play. Same look as the trailer and the loading screens: Bahnschrift,
the orange (255,138,36), the title art on the raid backdrop, thin rules and lower-left captions."""
import ctypes
import os
import shutil
import subprocess
import sys
import threading
import time
import tkinter as tk
from datetime import datetime

from PIL import Image, ImageDraw, ImageEnhance, ImageTk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import saves

ROOT = saves.ROOT
GAME_EXE = "RaidGame-Win64-Shipping.exe"
FEMALE_SETTING = os.path.join(ROOT, "config", "female_player.txt")
FEMALE_SHARE = os.path.join(ROOT, "config", "female_share.txt")  # percent of other characters who are women (rivals.lua)
FEMALE_SHARE_DEFAULT = 35
WINDOW_SETTING = os.path.join(ROOT, "config", "window_mode.txt")  # read by scripts/launch-offline.ps1
SKIP_INTRO_SETTING = os.path.join(ROOT, "config", "skip_intro.txt")  # read by scripts/mode.ps1
UNLOCK_LOOKS_SETTING = os.path.join(ROOT, "config", "unlock_all_looks.txt")  # read by the Nakama stand-in at login
GAME_PATH = os.path.join(ROOT, "config", "game_path.txt")  # written by the installer; scripts/mode.ps1 has the same default


def game_folder():
    try:
        with open(GAME_PATH, encoding="utf-8") as f:
            return f.readline().strip()
    except OSError:
        return "C:/Program Files (x86)/Steam/steamapps/common/PHtest"


GAME_LOG = os.path.join(game_folder(), "RaidGame", "Binaries", "Win64", "UE4SS.log")
NO_WINDOW = 0x08000000
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


def font(size, weight=""):
    return ("Bahnschrift " + weight if weight else "Bahnschrift", size)


def ps(*args):
    # PVE_PYTHON: launch-offline.ps1 starts the stand-in with this interpreter, not whatever "python" is on PATH.
    env = dict(os.environ, PVE_PYTHON=sys.executable)
    return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", *args], cwd=ROOT,
                          creationflags=NO_WINDOW, capture_output=True, text=True, env=env)


def game_running():
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {GAME_EXE}", "/NH"], capture_output=True, text=True,
                         creationflags=NO_WINDOW).stdout
    return GAME_EXE[:20].lower() in out.lower()


def ps_error(result):
    """The first line of a failed PowerShell script's error, short enough for the status line."""
    lines = [l.strip() for l in (result.stderr or "").splitlines() if l.strip()]
    text = lines[0] if lines else f"exit code {result.returncode}"
    return text if len(text) <= 160 else text[:157] + "..."


def steam_running():
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq steam.exe", "/NH"], capture_output=True, text=True,
                         creationflags=NO_WINDOW).stdout
    return "steam.exe" in out.lower()


def preflight():
    """Why PLAY can't work right now, in words a player can act on; None when everything it needs is in place.
    Without this a missing piece only showed as "The game didn't start" after START_TIMEOUT."""
    game = game_folder()
    if not os.path.isfile(os.path.join(game, "RaidGame", "Binaries", "Win64", GAME_EXE)):
        return f"Can't find the game in {game}. Run Install.bat again (developers: set config\\game_path.txt)."
    for need in ("dwmapi.dll", "UE4SS.dll", "Mods"):
        if not os.path.exists(os.path.join(ROOT, "tools", "ue4ss", need)):
            return f"UE4SS is missing (tools\\ue4ss\\{need}). Unzip the mod again (developers: see the README's setup)."
    if not steam_running():
        return "Start Steam first: the game needs it running."
    return None


def stop_standin():
    ps("-Command", "Get-CimInstance Win32_Process -Filter \"Name LIKE 'python%.exe'\" | Where-Object { $_.CommandLine -match "
                   "'nakama_standin' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }")


def when(t):
    return datetime.fromtimestamp(t).strftime("%d %b %Y, %H:%M") if t else "never"


class Button(tk.Label):
    """A flat button: the game's menus have no bevels."""

    def __init__(self, parent, text, command, kind="plain", size=12, pad=(16, 8)):
        self.colors = {"main": (ORANGE, INK, "#FFA64F"), "plain": (PANEL_HI, TEXT, "#2A313B"), "danger": (PANEL_HI, DANGER, "#2A313B")}[kind]
        super().__init__(parent, text=text, bg=self.colors[0], fg=self.colors[1], font=font(size, "SemiBold"), padx=pad[0], pady=pad[1],
                         cursor="hand2")
        self.command, self.enabled = command, True
        self.bind("<Button-1>", lambda e: self.enabled and self.command())
        self.bind("<Enter>", lambda e: self.enabled and self.config(bg=self.colors[2]))
        self.bind("<Leave>", lambda e: self.enabled and self.config(bg=self.colors[0]))

    def enable(self, on):
        self.enabled = on
        self.config(bg=self.colors[0] if on else PANEL, fg=self.colors[1] if on else "#4A525E", cursor="hand2" if on else "arrow")


class Dialog(tk.Toplevel):
    """A small dark window in the launcher's style."""

    def __init__(self, app, title):
        super().__init__(app)
        self.app = app
        self.overrideredirect(True)
        self.configure(bg=LINE)
        self.body = tk.Frame(self, bg=PANEL, padx=26, pady=20)
        self.body.pack(padx=1, pady=1)
        tk.Label(self.body, text=title.upper(), bg=PANEL, fg=ORANGE, font=font(15, "SemiBold")).pack(anchor="w")
        tk.Frame(self.body, bg=ORANGE, height=2, width=400).pack(anchor="w", pady=(6, 14))
        self.transient(app)

    def show(self):
        self.update_idletasks()
        x = self.app.winfo_rootx() + (W - self.winfo_width()) // 2
        y = self.app.winfo_rooty() + (H - self.winfo_height()) // 2
        # A borderless window can open underneath the launcher, and with the grab set it then blocks every click while
        # out of sight (the launcher looked frozen). Kept above it, and Escape always closes it. (Placed after -topmost,
        # which otherwise moves it to the screen's corner.)
        self.attributes("-topmost", True)
        self.lift()
        self.geometry(f"+{x}+{y}")
        self.update_idletasks()
        self.grab_set()
        self.focus_force()
        self.bind("<Escape>", lambda e: self.destroy())

    def row(self):
        f = tk.Frame(self.body, bg=PANEL)
        f.pack(anchor="e", pady=(18, 0))
        return f


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Marauders Offline")
        self.geometry(f"{W}x{H}")
        self.resizable(False, False)
        self.configure(bg=INK)
        icon = os.path.join(ROOT, "assets", "launcher", "icon.ico")
        if os.path.exists(icon):
            self.iconbitmap(icon)
        saves.adopt_existing()
        if not game_running():
            saves.settle()
        self.selected = None
        self.running = False
        self.launch_error = None
        self.cards = {}
        self.build()
        self.refresh()
        self.after(1000, self.watch)

    # Layout ---------------------------------------------------------------------------------------------------------
    def build(self):
        left = tk.Frame(self, bg=INK)
        left.place(x=36, y=130, width=620, height=474)
        head = tk.Frame(left, bg=INK)
        head.pack(fill="x")
        tk.Label(head, text="SAVES", bg=INK, fg=TEXT, font=font(17, "SemiBold")).pack(side="left")
        Button(head, "NEW SAVE", self.new_save, "main", 11, (14, 5)).pack(side="right")
        tk.Frame(left, bg=ORANGE, height=2).pack(fill="x", pady=(7, 8))
        self.list_box = tk.Frame(left, bg=INK)
        self.list_box.pack(fill="both", expand=True)

        right = tk.Frame(self, bg=PANEL)
        right.place(x=656, y=130, width=368, height=474)
        self.right = tk.Frame(right, bg=PANEL, padx=22, pady=18)
        self.right.pack(fill="both", expand=True)
        # PLAY first, so it keeps its place at the bottom whatever else the panel holds
        self.play = Button(self.right, "PLAY", self.launch, "main", 20, (10, 12))
        self.play.pack(side="bottom", fill="x", pady=(12, 0))
        self.d_name = tk.Label(self.right, bg=PANEL, fg=TEXT, font=font(18, "SemiBold"), anchor="w", wraplength=310, justify="left")
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
        self.b_undo = Button(self.right, "Undo last raid", self.undo, size=11, pad=(10, 6))
        self.b_undo.pack(fill="x", pady=(6, 0))

        tk.Frame(self.right, bg=LINE, height=1).pack(fill="x", pady=(14, 8))
        self.cheat_var = tk.BooleanVar()
        self.female_var = tk.BooleanVar(value=self.read_female())
        self.toggle("Infinite money", self.cheat_var, self.toggle_cheat)
        self.toggle("Play as a woman  (F2 switches in game)", self.female_var, self.toggle_female)
        share = tk.Frame(self.right, bg=PANEL)
        share.pack(fill="x", pady=(4, 0))
        tk.Label(share, text="Female enemies and crew", bg=PANEL, fg=TEXT, font=font(12), anchor="w").pack(side="left")
        self.share_label = tk.Label(share, bg=PANEL, fg=ORANGE, font=font(12, "SemiBold"), width=5, anchor="e")
        self.share_label.pack(side="right")
        self.share_var = tk.IntVar(value=self.read_share())
        tk.Scale(self.right, from_=0, to=100, resolution=5, orient="horizontal", variable=self.share_var, showvalue=False,
                 command=self.change_share, bg=ORANGE, troughcolor=PANEL_HI, activebackground=ORANGE, highlightthickness=0, bd=0,
                 sliderrelief="flat", sliderlength=18, width=10, cursor="hand2").pack(fill="x", pady=(0, 6))
        self.share_label.config(text=f"{self.share_var.get()}%")
        self.borderless_var = tk.BooleanVar(value=self.read_borderless())
        self.toggle("Borderless fullscreen", self.borderless_var, self.toggle_borderless)
        self.skip_intro_var = tk.BooleanVar(value=self.read_skip_intro())
        self.toggle("Skip the intro video", self.skip_intro_var, self.toggle_skip_intro)
        self.unlock_looks_var = tk.BooleanVar(value=self.read_unlock_looks())
        self.toggle("Unlock all looks and voices", self.unlock_looks_var, self.toggle_unlock_looks)

        self.status = tk.Label(self, text="", bg=INK, fg=MUTED, font=font(11), anchor="w", bd=0)
        tag = tk.Label(self, text="OFFLINE  PvE", bg=INK, fg=ORANGE_DIM, font=font(11, "SemiBold"))

        # Fonts grow with Windows display scaling (the launcher is DPI aware) but these pixel sizes don't: make the panels
        # as tall as the details panel needs, and the window to match.
        self.d_name.config(text="Save")  # stand-ins as tall as what refresh() writes there
        self.d_mode.config(text="Save")
        self.d_info.config(text="Cash\nXP\nStash\nStarted")
        self.update_idletasks()
        ph =max(474, right.winfo_reqheight(), self.right.winfo_reqheight())
        left.place_configure(height=ph)
        right.place_configure(height=ph)
        y = 130 + ph + 18
        h = max(H, y + self.status.winfo_reqheight() + 18)
        self.status.place(x=36, y=y, width=800)
        tag.place(x=W - 36, y=y, anchor="ne")
        self.geometry(f"{W}x{h}")

        canvas = tk.Canvas(self, width=W, height=h, bg=INK, highlightthickness=0)
        canvas.place(x=0, y=0)
        tk.Misc.lower(canvas)  # behind the panels (Canvas.lower is for its own items)
        back = Image.open(os.path.join(ROOT, "assets", "loading", "backdrop.png")).convert("RGB")
        scale = max(W / back.width, h / back.height)
        back = back.resize((int(back.width * scale) + 1, int(back.height * scale) + 1))
        back = back.crop((0, 0, W, h))
        back = ImageEnhance.Brightness(back).enhance(0.28)
        logo = Image.open(os.path.join(ROOT, "assets", "menu", "logo.png")).convert("RGBA")
        logo.thumbnail((400, 100))
        back.paste(logo, (36, 26), logo)
        self.back_art = ImageTk.PhotoImage(back)
        canvas.create_image(0, 0, image=self.back_art, anchor="nw")

    def toggle(self, text, var, command):
        tk.Checkbutton(self.right, text=text, variable=var, command=command, bg=PANEL, fg=TEXT, selectcolor=INK, activebackground=PANEL,
                       activeforeground=TEXT, font=font(12), anchor="w", justify="left", wraplength=300, bd=0, highlightthickness=0,
                       cursor="hand2").pack(fill="x")

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
        name = s["name"] + ("     CHEAT" if s.get("cheat") else "")
        a = tk.Label(inner, text=name, bg=bg, fg=TEXT, font=font(13, "SemiBold"), anchor="w")
        a.pack(fill="x")
        b = tk.Label(inner, text=f"{s['cash']:,} cash   ·   {s['items']} items   ·   last played {when(s.get('played'))}", bg=bg, fg=MUTED,
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
        live = not self.running and s is not None
        for b in (self.b_rename, self.b_copy, self.b_delete, self.play):
            b.enable(live)
        self.b_undo.enable(live and s.get("can_undo"))
        if not s:
            self.d_name.config(text="No saves yet")
            self.d_mode.config(text="")
            self.d_info.config(text="Make a new save to start.")
            return
        self.d_name.config(text=s["name"])
        self.d_mode.config(text="Infinite money is on" if s.get("cheat") else "Normal save")
        self.d_info.config(text=f"Cash   {s['cash']:,}\nXP   {s['xp']:,}\nStash   {s['items']} items, {s['stash_rows']} rows\n"
                                f"Started   {when(s.get('created'))}")
        self.cheat_var.set(bool(s.get("cheat")))

    def say(self, text):
        self.status.config(text=text)

    # Save actions ---------------------------------------------------------------------------------------------------
    def new_save(self):
        if self.running:
            return
        d = Dialog(self, "New save")
        tk.Label(d.body, text="Name", bg=PANEL, fg=MUTED, font=font(11)).pack(anchor="w")
        name = tk.Entry(d.body, bg=INK, fg=TEXT, insertbackground=ORANGE, relief="flat", font=font(14), width=32)
        name.pack(fill="x", ipady=5, pady=(2, 12))
        name.insert(0, f"Save {len(self.items) + 1}")
        name.select_range(0, "end")
        tk.Label(d.body, text=f"Stash size in rows  ({saves.STASH_H} is normal, {saves.STASH_MIN} to {saves.STASH_MAX})",
                 bg=PANEL, fg=MUTED, font=font(11)).pack(anchor="w")
        rows = tk.Entry(d.body, bg=INK, fg=TEXT, insertbackground=ORANGE, relief="flat", font=font(14), width=8)
        rows.pack(anchor="w", ipady=5, pady=(2, 2))
        rows.insert(0, str(saves.STASH_H))
        tk.Label(d.body, text="This can't be changed later.", bg=PANEL, fg=MUTED, font=font(10)).pack(anchor="w", pady=(0, 10))
        cheat = tk.BooleanVar()
        tk.Checkbutton(d.body, text="Start with lots of gear and infinite money (for testing)", variable=cheat, bg=PANEL, fg=TEXT, selectcolor=INK,
                       activebackground=PANEL, activeforeground=TEXT, font=font(12), bd=0, highlightthickness=0).pack(anchor="w")
        tk.Label(d.body, text="A new save starts from scratch: level 1, nothing unlocked,\nand just a pistol in your stash.", bg=PANEL,
                 fg=MUTED, font=font(10), justify="left").pack(anchor="w", pady=(8, 0))
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
            d.destroy()
            self.selected = saves.create(text, cheat.get(), n)
            self.refresh()
            self.say(f"Made the save {text}.")

        r = d.row()
        Button(r, "Cancel", d.destroy, size=11, pad=(14, 6)).pack(side="left", padx=(0, 8))
        Button(r, "CREATE", make, "main", 11, (14, 6)).pack(side="left")
        d.show()
        name.focus_set()
        name.bind("<Return>", lambda e: make())

    def rename(self):
        s = self.current()
        d = Dialog(self, "Rename save")
        name = tk.Entry(d.body, bg=INK, fg=TEXT, insertbackground=ORANGE, relief="flat", font=font(14), width=32)
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
        tk.Label(d.body, text=text, bg=PANEL, fg=TEXT, font=font(12), justify="left", wraplength=400).pack(anchor="w")

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

    def toggle_cheat(self):
        if self.selected and not self.running:
            saves.set_cheat(self.selected, self.cheat_var.get())
            self.refresh()
        else:
            self.show_selected()

    def read_female(self):
        try:
            with open(FEMALE_SETTING, encoding="utf-8") as f:
                return f.read().strip() == "on"
        except OSError:
            return False

    def toggle_female(self):
        with open(FEMALE_SETTING, "w", encoding="utf-8") as f:
            f.write("on\n" if self.female_var.get() else "off\n")

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
        with open(FEMALE_SHARE, "w", encoding="utf-8") as f:
            f.write(f"{value}\n")

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
        with open(UNLOCK_LOOKS_SETTING, "w", encoding="utf-8") as f:
            f.write("on\n" if self.unlock_looks_var.get() else "off\n")

    def toggle_skip_intro(self):
        # takes effect at the next Play (scripts/mode.ps1 offline swaps the startup video)
        with open(SKIP_INTRO_SETTING, "w", encoding="utf-8") as f:
            f.write("on\n" if self.skip_intro_var.get() else "off\n")

    def toggle_borderless(self):
        # takes effect at the next Play
        with open(WINDOW_SETTING, "w", encoding="utf-8") as f:
            f.write("borderless\n" if self.borderless_var.get() else "windowed\n")

    # Playing --------------------------------------------------------------------------------------------------------
    def launch(self):
        if self.running or not self.selected:
            return
        if game_running():
            self.say("The game is already running. Close it first.")
            return
        problem = preflight()
        if problem:
            self.say(problem)
            return
        self.launch_error = None
        self.running = True
        self.seen = False
        self.started = time.time()
        s = self.current()
        self.show_selected()
        self.say(f"Starting {s['name']}...")
        threading.Thread(target=self.start_game, args=(s["id"],), daemon=True).start()

    def start_game(self, sid):
        stop_standin()
        saves.activate(sid)
        result = ps("-File", os.path.join(ROOT, "scripts", "launch-offline.ps1"))
        if result.returncode != 0:
            # Tidy up at once (watch() sees the timeout) and say why, instead of waiting START_TIMEOUT in silence.
            self.launch_error = ps_error(result)
            self.started = 0
            return
        self.after(0, lambda: self.say("Playing. Leave this window open: it saves when you close the game."))

    def watch(self):
        # Tidying up only starts once the game has been seen running: until then "no game" just means it's still starting.
        if self.running:
            if game_running():
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
        stop_standin()
        saves.settle()
        try:  # going back to stock removes the game log: this keeps the last one
            shutil.copyfile(GAME_LOG, os.path.join(ROOT, "backend", "last_game.log"))
        except OSError:
            pass
        ps("-File", os.path.join(ROOT, "scripts", "mode.ps1"), "online")
        self.after(0, self.done)

    def done(self):
        self.running = False
        self.refresh()
        if self.launch_error and not self.seen:
            self.say(f"The game didn't start: {self.launch_error} Nothing changed; the normal online game works as usual.")
            return
        self.say(("Saved. " if self.seen else "The game didn't start, so nothing changed. ") + "The normal online game works as usual.")


if __name__ == "__main__":
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (OSError, AttributeError):
        pass
    App().mainloop()
