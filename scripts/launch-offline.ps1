# Starts the game in offline mode, without Easy Anti-Cheat. Extra arguments go to the game.
#   powershell -File launch-offline.ps1 [args...]
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'mode.ps1') offline | Out-Host
# With bridge\offline_backend present the game talks to the local Nakama stand-in instead of the live backend.
$Project = Split-Path $PSScriptRoot
if (Test-Path (Join-Path $Project 'bridge\offline_backend')) {
    if (-not (Get-NetTCPConnection -LocalPort 7350 -State Listen -ErrorAction SilentlyContinue)) {
        # PVE_PYTHON: the launcher's own interpreter (a bare "python" can be the Microsoft Store stub).
        $Python = if ($env:PVE_PYTHON) { $env:PVE_PYTHON } else { 'python' }
        Start-Process $Python -ArgumentList '-I', (Join-Path $Project 'backend\nakama_standin.py') -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
    'Nakama: local stand-in on 127.0.0.1:7350 (backend\server.log)'
} else { 'Nakama: live backend' }
$Game = 'C:\Program Files (x86)\Steam\steamapps\common\PHtest'
$GamePath = Join-Path $Project 'config\game_path.txt'
if (Test-Path $GamePath) { $Game = (Get-Content $GamePath -TotalCount 1).Trim() }
$Exe = Join-Path $Game 'RaidGame\Binaries\Win64\RaidGame-Win64-Shipping.exe'
# config\window_mode.txt (the launcher's "Borderless fullscreen" box): "borderless" or "windowed" (the default).
$WindowMode = 'windowed'
$ModePath = Join-Path $Project 'config\window_mode.txt'
if (Test-Path $ModePath) { $WindowMode = (Get-Content $ModePath -TotalCount 1).Trim().ToLower() }
if ($WindowMode -eq 'borderless') {
    # Borderless is the game's own "windowed fullscreen" (FullscreenMode=1 in GameUserSettings.ini) at the desktop's
    # resolution; there's no command-line switch for it, and -windowed / -ResX would override it.
    $Screen = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
    $ResX, $ResY = 1920, 1080
    if ($Screen) { $ResX, $ResY = $Screen.CurrentHorizontalResolution, $Screen.CurrentVerticalResolution }
    $IniDir = Join-Path $env:LOCALAPPDATA 'RaidGame\Saved\Config\WindowsNoEditor'
    $Ini = Join-Path $IniDir 'GameUserSettings.ini'
    $Section = '[/Script/Engine.GameUserSettings]'
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Ini) { $lines.AddRange([string[]](Get-Content $Ini)) }
    if (-not $lines.Contains($Section)) { $lines.Add($Section) }
    $want = [ordered]@{ FullscreenMode = 1; LastConfirmedFullscreenMode = 1; PreferredFullscreenMode = 1
        ResolutionSizeX = $ResX; ResolutionSizeY = $ResY; LastUserConfirmedResolutionSizeX = $ResX; LastUserConfirmedResolutionSizeY = $ResY }
    foreach ($key in $want.Keys) {
        $i = $lines.FindIndex([Predicate[string]] { param($l) $l -like "$key=*" })
        if ($i -ge 0) { $lines[$i] = "$key=$($want[$key])" }
        else { $lines.Insert($lines.IndexOf($Section) + 1, "$key=$($want[$key])") }
    }
    New-Item -ItemType Directory -Force $IniDir | Out-Null
    Set-Content $Ini $lines -Encoding Ascii
    $gameArgs = @('-nosplash') + $args
} else {
    $gameArgs = @('-windowed', '-ResX=1600', '-ResY=900', '-nosplash') + $args
}
Start-Process $Exe -ArgumentList $gameArgs -WorkingDirectory (Split-Path $Exe)
"Started: $($gameArgs -join ' ')"
