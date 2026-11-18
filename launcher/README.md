# launcher/: the window players start from

`launcher.pyw` (Tkinter) manages saves, settings and difficulty, starts the stand-in backend and the game in offline
mode, and puts the game folder back to stock when the game closes.

| File | What it's for |
|---|---|
| `launcher.pyw` | The window. Background threads hand UI work back with `self.ui(fn)`, never touching Tk directly |
| `saves.py` | Save slots: new, copy, export, import |
| `report.py` | "Report a problem": one zip of logs and the latest crash, with player names and IDs scrubbed |
| `update.py` | Checks for a newer release |
| `test_ui.py`, `test_launcher.py` | Opens every dialog with temporary saves, at 150 % scaling too (`python launcher/test_ui.py`) |
