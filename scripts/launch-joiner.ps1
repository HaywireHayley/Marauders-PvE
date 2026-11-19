# Co-op (#26): starts a second copy of the game on this PC as another player, with its own offline save, to join a
# listen host. Run the host first (the launcher or launch-offline.ps1; that puts the game folder in offline mode),
# open its raid with ?listen, then:
#   powershell -File scripts\launch-joiner.ps1 [-N 2] [-Name Marauder2]
#   scripts/bsend.sh bridge2 join            (Git Bash; "join" takes [host[:port]] [name] [n])
# The joiner gets its own:
#   save       backend\joiners\<N>\ (a new account from seed.json the first time), served by a second stand-in on
#              port 7349+N; pvenet.dll is pointed at it with PVE_STANDIN_PORT, the PvEDirector mod with PVE_BACKEND.
#              So its raid takes gear from, and writes loot and deaths back to, its own stash, not the host's.
#   bridge     bridge<N>\ (PVE_BRIDGE), so tools can drive each copy apart.
#   TEMP       tmp<N>\: the game's single-instance lock file lives in %TEMP% (NOTES.md, "Co-op host+join attempt").
param([int]$N = 2, [string]$Name = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launch-helpers.ps1')
$Project = Split-Path $PSScriptRoot
if ($N -lt 2 -or $N -gt 9) { [Console]::Error.WriteLine('-N is the player number, 2 to 9.'); exit 1 }
if (-not $Name) { $Name = "Marauder$N" }

$mode = & (Join-Path $PSScriptRoot 'mode.ps1') status
if ("$mode" -notmatch 'offline') {
    [Console]::Error.WriteLine("The game folder isn't in offline mode ($mode). Start the host first."); exit 1
}

$Python = if ($env:PVE_PYTHON) { $env:PVE_PYTHON } else { 'python' }
$Port = 7349 + $N
$Save = Join-Path $Project "backend\joiners\$N"
$problem = Start-Standin $Project $Python $Port 15 $Save $Name
if ($problem) { [Console]::Error.WriteLine("Can't start the joiner's backend: $problem."); exit 1 }
"Backend: stand-in for $Name on 127.0.0.1:$Port ($Save)"

$Bridge = Join-Path $Project "bridge$N"
New-Item -ItemType Directory -Force $Bridge | Out-Null
# PvEBridge loads pvenet.dll (the offline redirect) only while its bridge folder holds this flag.
Copy-Item (Join-Path $Project 'bridge\offline_backend') $Bridge -Force
$Temp = Join-Path $Project "tmp$N"
New-Item -ItemType Directory -Force $Temp | Out-Null

$Game = 'C:\Program Files (x86)\Steam\steamapps\common\PHtest'
$GamePath = Join-Path $Project 'config\game_path.txt'
if (Test-Path $GamePath) { $Game = (Get-Content $GamePath -TotalCount 1).Trim() }
$Exe = Join-Path $Game 'RaidGame\Binaries\Win64\RaidGame-Win64-Shipping.exe'
$env:TEMP = $Temp
$env:TMP = $Temp
$env:PVE_BRIDGE = ($Bridge -replace '\\', '/') + '/'
$env:PVE_BACKEND = ($Save -replace '\\', '/') + '/'
$env:PVE_STANDIN_PORT = "$Port"
$sx, $sy = Get-ScreenSize
$ResX, $ResY = Get-WindowedSize $sx $sy
$ResX = [int]($ResX * 0.8); $ResY = [int]($ResY * 0.8)
Start-Process $Exe -ArgumentList '-windowed', "-ResX=$ResX", "-ResY=$ResY", '-nosplash' -WorkingDirectory (Split-Path $Exe)
"Started player $N ($Name). When its menu is up: scripts/bsend.sh bridge$N join"
