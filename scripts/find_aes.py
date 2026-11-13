"""Finds the pak AES-256 key in the game exe: UE writes it with 8 'mov dword [reg+off], imm32'.
Each candidate is checked by decrypting the first block of the pak index (mount point "../../../")."""
import re, struct, sys
import os; from pvepaths import ROOT, GAME  # noqa: E402
from Crypto.Cipher import AES

EXE = os.path.join(GAME, r'RaidGame/Binaries/Win64/RaidGame-Win64-Shipping.exe')
PAK = os.path.join(GAME, r'RaidGame/Content/Paks/pakchunk0-WindowsNoEditor.pak')

with open(PAK, 'rb') as f:
    f.seek(0, 2); n = f.tell(); f.seek(n - 300); tail = f.read()
    i = tail.rfind(struct.pack('<I', 0x5A6F12E1))
    _, off, size = struct.unpack('<IQQ', tail[i + 4:i + 24])
    f.seek(off); block = f.read(16)

def ok(key):
    p = AES.new(key, AES.MODE_ECB).decrypt(block)
    ln = struct.unpack('<i', p[:4])[0]
    return 0 < ln < 256 and p[4:7] == b'../'

data = open(EXE, 'rb').read()
# mov dword [r + disp8], imm32  =  C7 (40..47 | 41 xx with REX) ... ; collect runs of 8 such movs
mov = re.compile(rb'(?:\x41)?\xC7([\x40-\x47])([\x00-\x1C])(....)|(?:\x41)?\xC7([\x00-\x07])(....)', re.S)
tried = 0
for m in re.finditer(rb'(?:(?:\x41)?\xC7[\x00-\x07\x40-\x47][\x00-\x1C]?....){8}', data, re.S):
    chunk = m.group()
    parts = {}
    for mm in mov.finditer(chunk):
        if mm.group(1) is not None:
            parts[mm.group(2)[0]] = mm.group(3)
        else:
            parts[0] = mm.group(5)
    if sorted(parts) == list(range(0, 32, 4)):
        key = b''.join(parts[o] for o in range(0, 32, 4))
        tried += 1
        if ok(key):
            print('KEY 0x' + key.hex().upper(), 'at', hex(m.start()))
            sys.exit(0)
print('no key; candidates tried:', tried)
