"""Drives the real launcher window: shows a save, captures the window, opens dialogs, then presses Play on the save named on
the command line. test_launcher.py <save id> <out folder> [play]"""
import ctypes
import importlib.machinery
import importlib.util
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_loader("launcher", importlib.machinery.SourceFileLoader("launcher", os.path.join(HERE, "launcher.pyw")))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sid, out = sys.argv[1], sys.argv[2]
play = len(sys.argv) > 3


def grab(window, name):
    window.update()
    hwnd = ctypes.windll.user32.GetAncestor(window.winfo_id(), 2)
    w, h = window.winfo_width(), window.winfo_height()
    gdi, user = ctypes.windll.gdi32, ctypes.windll.user32
    dc = user.GetDC(hwnd)
    mem = gdi.CreateCompatibleDC(dc)
    bmp = gdi.CreateCompatibleBitmap(dc, w + 40, h + 80)
    gdi.SelectObject(mem, bmp)
    user.PrintWindow(hwnd, mem, 2)
    raw = ctypes.create_string_buffer((w + 40) * (h + 80) * 4)
    info = (ctypes.c_uint32 * 10)(40, w + 40, -(h + 80), 0x200001, 0, 0, 0, 0, 0, 0)
    gdi.GetDIBits(mem, bmp, 0, h + 80, raw, info, 0)
    Image.frombuffer("RGBA", (w + 40, h + 80), raw, "raw", "BGRA", 0, 1).convert("RGB").save(os.path.join(out, name))


app = mod.App()
app.select(sid)


def step1():
    grab(app, "ui_main.png")
    app.new_save()
    app.after(400, step2)


def step2():
    top = [w for w in app.winfo_children() if isinstance(w, mod.Dialog)][0]
    grab(top, "ui_new.png")
    top.destroy()
    if play:
        app.launch()
        app.after(1000, wait)
    else:
        app.destroy()


def wait():
    if app.running is False and not mod.game_running():
        grab(app, "ui_after.png")
        print("finished:", app.status.cget("text"))
        app.destroy()
        return
    app.after(2000, wait)


app.after(900, step1)
app.mainloop()
