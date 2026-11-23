"""Samples the game thread's instruction pointer from outside, read-only (brief SuspendThread per sample).
threadsample.py <seconds> [hz]: prints which module the busiest threads spend time in, and per-thread busy share."""
import ctypes as C
import sys
import time
import collections
from ctypes import wintypes as W
k = C.WinDLL("kernel32", use_last_error=True); psapi = C.WinDLL("psapi")
TH32CS_SNAPTHREAD = 4
class TE(C.Structure):
    _fields_=[("dwSize",W.DWORD),("cntUsage",W.DWORD),("th32ThreadID",W.DWORD),("th32OwnerProcessID",W.DWORD),("tpBasePri",C.c_long),("tpDeltaPri",C.c_long),("dwFlags",W.DWORD)]
k.CreateToolhelp32Snapshot.restype=W.HANDLE; k.OpenThread.restype=W.HANDLE; k.OpenProcess.restype=W.HANDLE
class CTX(C.Structure):
    _fields_=[("pad",C.c_ubyte*0x30),("ContextFlags",W.DWORD),("pad2",C.c_ubyte*(0x98-0x34)),("Rsp",C.c_uint64),("pad3",C.c_ubyte*(0xF8-0xA0)),("Rip",C.c_uint64),("rest",C.c_ubyte*(0x4D0-0x100))]
def pid():
    import subprocess
    o=subprocess.check_output('tasklist /FI "IMAGENAME eq RaidGame-Win64-Shipping.exe" /FO CSV /NH',shell=True,text=True)
    return int(o.split(',')[1].strip('"'))
P=pid(); hp=k.OpenProcess(0x0410,False,P)
mods=(W.HMODULE*2048)(); need=W.DWORD()
psapi.EnumProcessModulesEx.argtypes=[W.HANDLE,C.c_void_p,W.DWORD,C.POINTER(W.DWORD),W.DWORD]
psapi.EnumProcessModulesEx(hp,mods,C.sizeof(mods),C.byref(need),3)
class MI(C.Structure): _fields_=[("base",C.c_void_p),("size",W.DWORD),("entry",C.c_void_p)]
psapi.GetModuleInformation.argtypes=[W.HANDLE,W.HMODULE,C.POINTER(MI),W.DWORD]
psapi.GetModuleBaseNameW.argtypes=[W.HANDLE,W.HMODULE,W.LPWSTR,W.DWORD]
ml=[]
for i in range(need.value//8):
    m=MI(); psapi.GetModuleInformation(hp,mods[i],C.byref(m),C.sizeof(m))
    b=C.create_unicode_buffer(260); psapi.GetModuleBaseNameW(hp,mods[i],b,260)
    ml.append((m.base,m.base+m.size,b.value))
ml.sort()
def who(a):
    for s,e,n in ml:
        if s<=a<e: return n,a-s
    return "?",a
s=k.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD,0); te=TE(); te.dwSize=C.sizeof(TE)
tids=[]; ok=k.Thread32First(W.HANDLE(s),C.byref(te))
while ok:
    if te.th32OwnerProcessID==P: tids.append(te.th32ThreadID)
    ok=k.Thread32Next(W.HANDLE(s),C.byref(te))
hs={}
for t in tids:
    h=k.OpenThread(0x005A,False,t)
    if h: hs[t]=h
def cpu(h):
    a,b,c,d=W.FILETIME(),W.FILETIME(),W.FILETIME(),W.FILETIME()
    k.GetThreadTimes(W.HANDLE(h),C.byref(a),C.byref(b),C.byref(c),C.byref(d))
    return ((c.dwHighDateTime<<32|c.dwLowDateTime)+(d.dwHighDateTime<<32|d.dwLowDateTime))/1e7
c0={t:cpu(h) for t,h in hs.items()}
time.sleep(1.0)
c1={t:cpu(h) for t,h in hs.items()}
busy=sorted(hs,key=lambda t:c1[t]-c0[t],reverse=True)[:8]
print("busiest threads (cpu share of 1 s):",[(t,round(c1[t]-c0[t],2)) for t in busy])
secs=float(sys.argv[1]); hz=float(sys.argv[2]) if len(sys.argv)>2 else 200
gt=sorted(hs)[0] if False else busy[0]
# the game thread = the thread that has run longest of the busy ones
gt=busy[0]
print("sampling thread",gt)
buf=(C.c_ubyte*(0x4D0+16))()
addr=(C.addressof(buf)+15)&~15
ctx=CTX.from_address(addr)
end=time.time()+secs
rd=k.ReadProcessMemory; rd.argtypes=[W.HANDLE,C.c_uint64,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)]
stk=(C.c_uint64*4096)()
targets=sorted(hs,key=lambda t:c1[t]-c0[t],reverse=True)[:5]
R={t:dict(n=0,hist=collections.Counter(),off=collections.Counter(),st=collections.Counter()) for t in targets}
while time.time()<end:
  for t in targets:
    h=hs[t]; D=R[t]
    k.SuspendThread(W.HANDLE(h))
    ctx.ContextFlags=0x100001
    r=k.GetThreadContext(W.HANDLE(h),C.c_void_p(addr))
    rip,rsp=ctx.Rip,ctx.Rsp
    got=C.c_size_t()
    rd(hp,rsp,stk,C.sizeof(stk),C.byref(got))
    k.ResumeThread(W.HANDLE(h))
    if not r: continue
    D['n']+=1
    m,o=who(rip); D['hist'][m]+=1; D['off'][(m,o&~0xff)]+=1
    seen=set()
    for q in stk[:got.value//8]:
        if q>0x10000:
            mm,oo=who(q)
            if mm!="?": seen.add(mm)
    for mm in seen: D['st'][mm]+=1
    if m!="ntdll.dll":
        D['act']=D.get('act',0)+1
        if "UE4SS.dll" in seen: D['actU']=D.get('actU',0)+1
  time.sleep(1/hz)
for t in targets:
    D=R[t]; n=max(D['n'],1)
    print("thread",t,"samples",n,[(m,round(c*100/n,1)) for m,c in D['hist'].most_common(5)])
    print("   on stack:",[(m,round(c*100/n)) for m,c in D['st'].most_common(8)])
    print("   active (IP outside ntdll) %d, UE4SS on stack in %d of them" % (D.get('act',0), D.get('actU',0)))
    print("   UE4SS hot:",[f"{c*100/n:.2f}% +{o:#x}" for (m,o),c in D['off'].most_common(400) if m=="UE4SS.dll"][:8])
    print("   hot:",[f"{c*100/n:.1f}% {m}+{o:#x}" for (m,o),c in D['off'].most_common(6)])
