# Lists packed asset paths from the running game's memory, without the pak key (#228, #230, #231): the game keeps its
# decrypted pak index in memory, so every packed file's path ("Characters/MainPlayer/Meshes/Bodies/...") is there as
# plain ASCII. Read-only (PROCESS_QUERY_INFORMATION | PROCESS_VM_READ).
#   python -I tools/offline-audit/paknames.py <pid> Characters/ out.txt      (pid: tasklist /FI "IMAGENAME eq RaidGame*")
# A prefix starting with /Game/ finds nothing: the index holds paths relative to Content.
import ctypes
import ctypes.wintypes as W
import re
import sys
pid, prefix, outp = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3]
k = ctypes.WinDLL("kernel32", use_last_error=True)
h = k.OpenProcess(0x0410, False, pid)
class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p), ("AllocationProtect", W.DWORD),
                ("PartitionId", W.WORD), ("RegionSize", ctypes.c_size_t), ("State", W.DWORD), ("Protect", W.DWORD), ("Type", W.DWORD)]
k.VirtualQueryEx.argtypes = [W.HANDLE, ctypes.c_void_p, ctypes.POINTER(MBI), ctypes.c_size_t]
k.ReadProcessMemory.argtypes = [W.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
pat = re.compile(re.escape(prefix) + rb"[A-Za-z0-9_/\.\-]{1,200}")
found = set(); addr = 0; m = MBI()
while k.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(m), ctypes.sizeof(m)):
    size = m.RegionSize
    if m.State == 0x1000 and m.Protect in (0x04, 0x02, 0x20, 0x40) and size < 1 << 31:
        step = 1 << 24
        for off in range(0, size, step):
            n = min(step, size - off); buf = ctypes.create_string_buffer(n); got = ctypes.c_size_t()
            if k.ReadProcessMemory(h, ctypes.c_void_p(addr + off), buf, n, ctypes.byref(got)):
                for s in pat.findall(buf.raw[:got.value]): found.add(s.decode())
    addr += size
    if addr >= 1 << 47: break
open(outp, "w").write("\n".join(sorted(found)))
print(len(found))
