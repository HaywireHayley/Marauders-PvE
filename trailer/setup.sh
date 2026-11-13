#!/bin/sh
# After every map change: game resolution + window position for rec.sh, and the trailer camera loaded.
cd "$(dirname "$0")/.."
./scripts/send.sh "r.setres 1472x828w" > /dev/null
sleep 1
powershell -NoProfile -ExecutionPolicy Bypass -File trailer/place.ps1
./scripts/send.sh "lua return dofile(\"$(pwd -W)/bridge/cine.lua\")" | tail -1
