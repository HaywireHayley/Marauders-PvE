import re
import os; from pvepaths import GAME  # noqa: E402
def base():
    t=open(os.path.join(GAME, r'RaidGame/Binaries/Win64/UE4SS.log'),encoding='utf-8',errors='ignore').read()
    return int(re.findall(r'MainExe @ (0x[0-9a-f]+)',t)[-1],16)
