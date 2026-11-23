"""Disassembles the code dumps pvetrace.dll writes at the second-instance quit (DUMP rva=<hex> <bytes> lines).

    python -I scripts/quitsite.py capture/trace-<pid>.log [rva_from rva_to]

Prints each dumped region (addresses are RVAs in RaidGame-Win64-Shipping.exe) and flags byte stores of 1 to a
RIP-relative global (`mov byte ptr [rip+X], 1`) with the global's RVA: GIsRequestingExit is set that way.
"""
import re
import sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

md = Cs(CS_ARCH_X86, CS_MODE_64)
log = sys.argv[1]
lo, hi = (int(sys.argv[2], 16), int(sys.argv[3], 16)) if len(sys.argv) > 3 else (None, None)
for line in open(log, encoding="utf-8", errors="replace"):
    m = re.match(r"DUMP rva=([0-9a-f]+) ([0-9a-f]+)$", line.strip())
    if not m:
        continue
    rva, code = int(m.group(1), 16), bytes.fromhex(m.group(2))
    print(f"==== region rva {rva:#x} len {len(code):#x}")
    for ins in md.disasm(code, rva):
        if lo is not None and not (lo <= ins.address < hi):
            continue
        note = ""
        if ins.mnemonic == "mov" and ins.op_str.startswith("byte ptr [rip") and ins.op_str.endswith(", 1"):
            disp = int(re.search(r"rip ([+-]) (0x[0-9a-f]+|\d+)", ins.op_str).group(2), 0)
            sign = -1 if "rip -" in ins.op_str else 1
            note = f"   <== store 1 to global rva {ins.address + ins.size + sign * disp:#x}"
        print(f"  {ins.address:#010x}: {ins.bytes.hex():<24} {ins.mnemonic} {ins.op_str}{note}")
