# Starts the game in offline mode, without Easy Anti-Cheat. Extra arguments go to the game.
#   powershell -File launch-offline.ps1 [args...]
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launch-helpers.ps1')
# With bridge\offline_backend present the game talks to the local Nakama stand-in instead of the live backend.
# It starts first, so if it can't, the game folder is still stock and the launcher can say why.
$Project = Split-Path $PSScriptRoot
if (Test-Path (Join-Path $Project 'bridge\offline_backend')) {
    # PVE_PYTHON: the launcher's own interpreter (a bare "python" can be the Microsoft Store stub).
    $Python = if ($env:PVE_PYTHON) { $env:PVE_PYTHON } else { 'python' }
    $problem = Start-Standin $Project $Python
    if ($problem) { [Console]::Error.WriteLine("Can't start: $problem."); exit 1 }
    'Nakama: local stand-in on 127.0.0.1:7350 (backend\server.log)'
} else { 'Nakama: live backend' }
& (Join-Path $PSScriptRoot 'mode.ps1') offline | Out-Host
$Game = 'C:\Program Files (x86)\Steam\steamapps\common\PHtest'
$GamePath = Join-Path $Project 'config\game_path.txt'
if (Test-Path $GamePath) { $Game = (Get-Content $GamePath -TotalCount 1).Trim() }
$Exe = Join-Path $Game 'RaidGame\Binaries\Win64\RaidGame-Win64-Shipping.exe'
# config\window_mode.txt (the launcher's "Borderless fullscreen" box): "borderless" or "windowed" (the default).
$WindowMode = 'windowed'
$ModePath = Join-Path $Project 'config\window_mode.txt'
if (Test-Path $ModePath) { $WindowMode = (Get-Content $ModePath -TotalCount 1).Trim().ToLower() }
# The window is set in the game's own video save (SaveGames\VideoSettings.sav), which it applies at start-up over
# GameUserSettings.ini. Never -windowed / -ResX / -ResY: the engine re-applies command-line overrides every time settings
# are applied (map load, the Settings menu), so the window snapped back to the launch size whatever the player picked in
# game (issue #292). The launcher's choice is written only when it changes (config\window_applied.txt), so a choice made
# in the game's Settings afterwards stays.
$sx, $sy = Get-ScreenSize
if ($WindowMode -eq 'borderless') {
    $ResX, $ResY = $sx, $sy
    if (-not $ResX) { $ResX, $ResY = 1920, 1080 }
} else {
    $WindowMode = 'windowed'
    $ResX, $ResY = Get-WindowedSize $sx $sy
}
$Want = "$WindowMode ${ResX}x$ResY"
$AppliedPath = Join-Path $Project 'config\window_applied.txt'
$Applied = if (Test-Path $AppliedPath) { (Get-Content $AppliedPath -TotalCount 1).Trim() } else { '' }
if ($Applied -ne $Want) {
    $Python = if ($env:PVE_PYTHON) { $env:PVE_PYTHON } else { 'python' }
    try {
        & $Python -I (Join-Path $PSScriptRoot 'videosettings.py') $WindowMode $ResX $ResY | Out-Host
        if ($LASTEXITCODE -eq 0) { Set-Content $AppliedPath $Want -Encoding Ascii }
    } catch { "Window: couldn't run $Python ($($_.Exception.Message)); the game's own setting this time" }
} else { "Window: the game's own setting (launcher's $Want already applied)" }
$gameArgs = @('-nosplash') + $args
Start-Process $Exe -ArgumentList $gameArgs -WorkingDirectory (Split-Path $Exe)
"Started: $($gameArgs -join ' ')"
