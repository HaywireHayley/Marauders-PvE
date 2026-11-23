"""Per-thread CPU use of the game over a window, read-only (GetThreadTimes deltas; no suspending).
threadcpu.py <seconds>: prints the top threads' CPU share (100 = one full core) and the process total."""
import ctypes as C
import sys
import time
import subprocess
from ctypes import wintypes as W
k = C.WinDLL("kernel32", use_last_error=True)
class TE(C.Structure):
    _fields_ = [("dwSize", W.DWORD), ("cntUsage", W.DWORD), ("th32ThreadID", W.DWORD), ("th32OwnerProcessID", W.DWORD),
                ("tpBasePri", C.c_long), ("tpDeltaPri", C.c_long), ("dwFlags", W.DWORD)]
k.CreateToolhelp32Snapshot.restype = W.HANDLE; k.OpenThread.restype = W.HANDLE
o = subprocess.check_output('tasklist /FI "IMAGENAME eq RaidGame-Win64-Shipping.exe" /FO CSV /NH', shell=True, text=True)
P = int(o.split(',')[1].strip('"'))
def threads():
    snap = k.CreateToolhelp32Snapshot(4, 0); te = TE(); te.dwSize = C.sizeof(TE); out = []
    ok = k.Thread32First(snap, C.byref(te))
    while ok:
        if te.th32OwnerProcessID == P: out.append(te.th32ThreadID)
        ok = k.Thread32Next(snap, C.byref(te))
    k.CloseHandle(snap); return out
def times(tids):
    r = {}
    for t in tids:
        h = k.OpenThread(0x0800, False, t)  # THREAD_QUERY_LIMITED_INFORMATION
        if not h: continue
        a, b, c, d = W.FILETIME(), W.FILETIME(), W.FILETIME(), W.FILETIME()
        if k.GetThreadTimes(h, C.byref(a), C.byref(b), C.byref(c), C.byref(d)):
            r[t] = ((c.dwHighDateTime << 32 | c.dwLowDateTime) + (d.dwHighDateTime << 32 | d.dwLowDateTime)) / 1e7
        k.CloseHandle(h)
    return r
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10
tids = threads(); t0 = times(tids); w0 = time.time(); time.sleep(secs); t1 = times(tids); w = time.time() - w0
use = sorted(((t1[t] - t0[t]) / w * 100, t) for t in t1 if t in t0)[::-1]
print("total %.0f%% | top: %s" % (sum(u for u, _ in use), ", ".join("%d:%.0f" % (t, u) for u, t in use[:6])))
