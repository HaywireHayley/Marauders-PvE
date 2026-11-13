# Finds offline-relevant gates in game code: net-mode compares and Role (+0xF0) compares, works out which side
# runs offline (NetMode = 0 Standalone, Role = 3 Authority) and lists the named calls on the side that never runs.
import sys, json, re, struct, collections
import os; sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'scripts')); from pvepaths import ROOT, GAME  # noqa: E402
import procmem as m, gbase
from capstone import *
base = gbase.base(); md = Cs(CS_ARCH_X86, CS_MODE_64); md.detail = False
names = {int(k, 16): v for k, v in json.load(open(sys.argv[1])).items()}
names.update({0x1884b80: 'RaidWeapon::FireWeapon', 0x189a490: 'RaidWeapon::SimulateWeaponFire', 0x18a1c70: 'RaidWeapon client hit simulation',
    0x189bc80: 'RaidProjectile client hit simulation', 0x189f890: 'RaidWeapon recoil tick', 0x189c0f0: 'RaidWeapon::StartFire',
    0x18875a0: 'RaidWeapon ammo-in-clip getter', 0x187aa60: 'RaidWeapon::CanFire', 0x2e465b0: 'AActor::GetNetMode',
    0x316ebe0: 'IsStandalone', 0x1832420: 'RaidPlayerController get pooled impact', 0x17edf20: 'RaidBot death'})
RANGES = [(0x7e0000, 0xb20000), (0x1700000, 0x1a00000)]
code = {}
for lo, hi in RANGES:
    buf = bytearray()
    for off in range(lo, hi, 0x100000): buf += m.read(base + off, min(0x100000, hi - off))
    code[lo] = bytes(buf)
def rd(rva, n):
    for lo, hi in RANGES:
        if lo <= rva < hi: return code[lo][rva - lo: rva - lo + n]
    return m.read(base + rva, n)
def dis(rva, n): return list(md.disasm(rd(rva, n), base + rva))
def fstart(rva):
    for lo, hi in RANGES:
        if lo <= rva < hi:
            c = code[lo]; p = rva - lo
            while p > 0 and not (c[p-1] == 0xcc and p % 16 == 0): p -= 1
            # skip forward over padding to the first instruction
            return lo + p
    return rva
def tgt(ins):
    try: return int(ins.op_str, 16) - base
    except ValueError: return None
# pass 1: linear disassembly of all ranges; find call -> cmp eax,imm patterns to rank net-mode helpers
ins_all = []
for lo, hi in RANGES:
    c = code[lo]; p = 0
    while p < len(c):
        got = False
        for ins in md.disasm(c[p:p + 0x4000], base + lo + p):
            ins_all.append(ins); got = True
            last = ins.address + ins.size - base - lo
        p = last if got and last > p else p + 1
print('instructions', len(ins_all), file=sys.stderr)

ROLE_GET = {0x2f65dd0}; NET_GET = {0x2e465b0, 0x35054b0, 0x3212ab0}; STANDALONE = {0x316ebe0}
JCC = {'je','jne','jb','jae','ja','jbe','jl','jge','jg','jle','js','jns'}
def taken(j, x, imm):
    return {'je': x == imm, 'jne': x != imm, 'jb': x < imm, 'jae': x >= imm, 'ja': x > imm, 'jbe': x <= imm,
            'jl': x < imm, 'jge': x >= imm, 'jg': x > imm, 'jle': x <= imm}.get(j)
gates = []
idx = {ins.address: i for i, ins in enumerate(ins_all)}
for i, ins in enumerate(ins_all[:-4]):
    kind = val = None; cmpi = None
    if ins.mnemonic == 'cmp':
        mt = re.match(r'byte ptr \[(r\w+) \+ 0xf0\], ([1-3])$', ins.op_str)
        if mt and mt.group(1) not in ('rsp', 'rbp'): kind, val, cmpi = 'Role', 3, (i, int(mt.group(2)))
    elif ins.mnemonic == 'movzx':
        mt = re.match(r'(e\w+), byte ptr \[(r\w+) \+ 0xf0\]$', ins.op_str)
        if mt and mt.group(2) not in ('rsp', 'rbp'):
            reg = mt.group(1); low = {'eax':'al','ecx':'cl','edx':'dl','ebx':'bl'}.get(reg, reg)
            for k in range(i+1, i+4):
                c = ins_all[k]; mm = re.match(r'(\w+), ([0-3])$', c.op_str)
                if c.mnemonic == 'cmp' and mm and mm.group(1) in (reg, low): kind, val, cmpi = 'Role', 3, (k, int(mm.group(2))); break
    elif ins.mnemonic == 'call':
        t = tgt(ins)
        if t in ROLE_GET or t in NET_GET:
            for k in range(i+1, i+4):
                c = ins_all[k]; mm = re.match(r'(eax|al), ([0-3])$', c.op_str)
                if c.mnemonic == 'cmp' and mm:
                    kind, val = ('Role', 3) if t in ROLE_GET else ('NetMode', 0); cmpi = (k, int(mm.group(2))); break
        elif t in STANDALONE:
            for k in range(i+1, i+3):
                c = ins_all[k]
                if c.mnemonic == 'test' and c.op_str == 'al, al': kind, val, cmpi = 'IsStandalone', 1, (k, 0); break
    if not kind: continue
    k, imm = cmpi
    j = None
    for q in range(k+1, k+5):
        c = ins_all[q]
        if c.mnemonic in JCC: j = c; break
        if c.mnemonic == 'nop' and c.size in (2, 6):   # one of our patches (66 90 / 66 0f 1f 44 00 00)
            gates.append(dict(at=ins.address - base, fn=fstart(ins.address - base), fname=names.get(fstart(ins.address - base)),
                              kind=kind, cmp='PATCHED', offline='patched', skipped=None, skipped_calls=[])); break
        if c.mnemonic in ('cmp','test','add','sub','and','or','xor','inc','dec','call','ret','jmp','neg','sete','setne'): break
    if j is None: continue
    tk = taken(j.mnemonic, val, imm) if kind != 'IsStandalone' else {'je': False, 'jne': True}.get(j.mnemonic)
    if tk is None: continue
    jt = tgt(j); fall = j.address + j.size - base
    skipped = fall if tk else jt
    calls = []; n = 0
    for s in dis(skipped, 0x200):
        n += 1
        if s.mnemonic == 'call':
            t = tgt(s)
            calls.append(names.get(t, hex(t)) if t is not None else 'vcall ' + s.op_str.replace('qword ptr ', ''))
        if s.mnemonic in ('ret', 'jmp') or n > 60: break
    fs = fstart(ins.address - base)
    gates.append(dict(at=ins.address - base, fn=fs, fname=names.get(fs), kind=kind, cmp='%s %s %d' % (ins_all[k].mnemonic, j.mnemonic, imm),
                      offline='jump' if tk else 'fallthrough', skipped=skipped, skipped_calls=calls))
print('gates', len(gates), file=sys.stderr)
# callers for unnamed functions (rel32 calls inside the scanned ranges)
need = {g['fn'] for g in gates if not g['fname']}
callers = collections.defaultdict(list)
for ins in ins_all:
    if ins.mnemonic in ('call', 'jmp'):
        t = tgt(ins)
        if t in need: callers[t].append(ins.address - base)
for g in gates:
    if not g['fname']:
        cs = callers.get(g['fn'], [])
        g['callers'] = sorted({names.get(fstart(c)) or hex(fstart(c)) for c in cs})[:6]
json.dump(gates, open(sys.argv[2], 'w'), indent=1)
