#!/bin/sh
# Builds the native DLLs with MinGW-w64 GCC (Git Bash on Windows with WinLibs, or Linux with the mingw-w64 package).
#   build.sh [target] [suffix] [outdir]
#     target   pvenative (default), pvepatch, pvenet, or all (the three shipped DLLs)
#     suffix   pvenative only: "2" -> pvenative2.dll talking through native2_cmd.txt (the game keeps a loaded DLL locked)
#     outdir   where the DLLs go (default native/); CI builds to a temp folder so the committed DLLs stay as they are
# Compiler: $CC, else x86_64-w64-mingw32-gcc from PATH, else gcc (WinLibs gcc targets Windows), else the winget
# WinLibs package of whoever runs this.
set -e
TARGET="${1:-pvenative}"
SUFFIX="$2"
# The old form `build.sh 2` (suffix only) still builds pvenative2.dll.
case "$TARGET" in pvenative|pvepatch|pvenet|all) ;; *) SUFFIX="$TARGET"; TARGET=pvenative ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${3:-$HERE}"
mkdir -p "$OUT"
if [ -z "$CC" ]; then
  command -v x86_64-w64-mingw32-gcc >/dev/null || command -v gcc >/dev/null ||
    export PATH="$PATH:$(ls -d "$LOCALAPPDATA"/Microsoft/WinGet/Packages/BrechtSanders*/mingw64/bin 2>/dev/null | head -1)"
  if command -v x86_64-w64-mingw32-gcc >/dev/null; then CC=x86_64-w64-mingw32-gcc; else CC=gcc; fi
fi
ROOT="$(cd "$HERE/.." && (pwd -W 2>/dev/null || pwd))/"
FLAGS="-shared -O2 -Wall -Wextra"

build() {
  case "$1" in
    # In-memory code patches; kernel32 and the CRT only.
    pvepatch)  $CC $FLAGS -o "$OUT/pvepatch.dll" "$HERE/pvepatch.c" ;;
    # WinHTTP hooks: winhttp is reached through the import tables it rewrites (not linked); DNS hooks need ws2_32.
    pvenet)    $CC $FLAGS -o "$OUT/pvenet.dll" "$HERE/pvenet.c" -lws2_32 ;;
    # Dev helper: needs the repo root baked in for its command/reply files.
    pvenative) $CC $FLAGS -DPVE_ROOT="\"$ROOT\"" -DPREFIX="\"native$SUFFIX\"" -o "$OUT/pvenative$SUFFIX.dll" "$HERE/pvenative.c" ;;
    *) echo "unknown target: $1 (pvenative, pvepatch, pvenet, all)" >&2; exit 2 ;;
  esac
  echo "built $OUT/$1$( [ "$1" = pvenative ] && printf %s "$SUFFIX").dll"
}

if [ "$TARGET" = all ]; then
  for t in pvepatch pvenet pvenative; do build $t; done
else
  build "$TARGET"
fi
