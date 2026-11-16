#!/bin/sh
# Grab the game window to a PNG (no focus change): trailer/peek.sh <out.png>
cd "$(dirname "$0")"
powershell -NoProfile -ExecutionPolicy Bypass -File grab.ps1 "$(cygpath -w "$1")" > /dev/null
