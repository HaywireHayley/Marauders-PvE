#!/bin/sh
# Builds the native helper with the WinLibs MinGW-w64 GCC installed by winget.
#   build.sh [suffix]   suffix "2" -> pvenative2.dll talking through native2_cmd.txt (the game keeps a loaded DLL locked)
# gcc from PATH, else the winget WinLibs package of whoever runs this.
command -v gcc >/dev/null || export PATH="$PATH:$(ls -d "$LOCALAPPDATA"/Microsoft/WinGet/Packages/BrechtSanders*/mingw64/bin 2>/dev/null | head -1)"
ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))/"
cd "$(dirname "$0")" && gcc -shared -O2 -Wall -Wextra -DPVE_ROOT="\"$ROOT\"" -DPREFIX="\"native$1\"" -o pvenative$1.dll pvenative.c
