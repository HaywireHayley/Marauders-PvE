# Switches the Marauders install between ONLINE (stock, safe for the real servers) and
# OFFLINE (UE4SS mods loaded, backend pointed at localhost so nothing reaches the live servers).
#   powershell -File mode.ps1 offline|online|status
param([ValidateSet('offline', 'online', 'status')][string]$Mode = 'status')
$ErrorActionPreference = 'Stop'

$Project = Split-Path $PSScriptRoot -Parent
# The game folder (the one holding RaidGame\): config\game_path.txt when the installer has written it.
$Game = 'C:\Program Files (x86)\Steam\steamapps\common\PHtest'
$GamePath = Join-Path $Project 'config\game_path.txt'
if (Test-Path $GamePath) { $Game = (Get-Content $GamePath -TotalCount 1).Trim() }
$Bin = Join-Path $Game 'RaidGame\Binaries\Win64'
$PgosIni = Join-Path $Game 'RaidGame\Binaries\pgos_res\pgos_config.ini'
$Ue4ss = Join-Path $Project 'tools\ue4ss'
$OurMods = Join-Path $Project 'mods'
$Backup = Join-Path $Project 'backup'
# Every file/folder the offline mode adds to Win64 (incl. UE4SS output); online mode removes exactly these.
$Added = @('dwmapi.dll', 'UE4SS.dll', 'UE4SS-settings.ini', 'Mods', 'UE4SS.log', 'UE4SS_ObjectDump.txt',
    'CXXHeaderDump', 'Mappings.usmap', '..\..\Content\Paks\LogicMods',
    '..\..\Content\Characters\MainPlayer\Meshes\BodieF', '..\..\Content\Characters\MainPlayer\Meshes\HeadF',
    '..\..\Content\Characters\MainPlayer\Meshes\AccessorieF', '..\..\Content\Characters\MainPlayer\MesheF')

function Get-Mode {
    if (Test-Path (Join-Path $Bin 'dwmapi.dll')) { 'offline' } else { 'online' }
}

if ((Get-Process RaidGame-Win64-Shipping, RaidGame -ErrorAction SilentlyContinue) -and $Mode -ne 'status') {
    throw 'Close the game first.'
}

New-Item -ItemType Directory -Force $Backup | Out-Null
$IniBackup = Join-Path $Backup 'pgos_config.ini.original'
if (-not (Test-Path $IniBackup)) { Copy-Item $PgosIni $IniBackup }
# The startup video: our re-cut offline, the game's own online (trailer/make_intro.py).
$Intro = Join-Path $Game 'RaidGame\Content\Movies\LoadingScreen.mp4'
$IntroBackup = Join-Path $Backup 'LoadingScreen.mp4.original'
$IntroOurs = Join-Path $Project 'assets\intro\LoadingScreen.mp4'
# config\skip_intro.txt "on" (the launcher's "Skip the intro video" box): a 1 s black clip instead. The game plays the
# 60 s startup video to the end before the menu, so this takes launch-to-menu from ~69 s to ~20 s.
$IntroSkip = Join-Path $Project 'assets\loading\skip_intro.mp4'
$SkipIntroPath = Join-Path $Project 'config\skip_intro.txt'
if ((Test-Path $SkipIntroPath) -and (Get-Content $SkipIntroPath -TotalCount 1).Trim() -eq 'on' -and (Test-Path $IntroSkip)) {
    $IntroOurs = $IntroSkip
}
if (-not (Test-Path $IntroBackup)) { Copy-Item $Intro $IntroBackup }

switch ($Mode) {
    'status' { "Mode: $(Get-Mode)"; break }
    'offline' {
        Copy-Item (Join-Path $Ue4ss 'dwmapi.dll'), (Join-Path $Ue4ss 'UE4SS.dll') $Bin -Force
        Copy-Item (Join-Path $Project 'config\UE4SS-settings.ini') $Bin -Force
        $mods = Join-Path $Bin 'Mods'
        if (Test-Path $mods) { Remove-Item $mods -Recurse -Force }
        Copy-Item (Join-Path $Ue4ss 'Mods') $mods -Recurse
        Get-ChildItem $OurMods -Directory | ForEach-Object { Copy-Item $_.FullName $mods -Recurse -Force }
        Copy-Item (Join-Path $Project 'config\mods.txt') $mods -Force
        # The mods find the project's files (saves, art, native\*.dll) through require("pveproject").
        $root = "return `"$(($Project -replace '\\', '/').TrimEnd('/'))/`"`n"
        foreach ($m in 'PvEDirector', 'PvEBridge') {
            $scripts = Join-Path $mods "$m\Scripts"
            if (Test-Path $scripts) { [IO.File]::WriteAllText((Join-Path $scripts 'pveproject.lua'), $root) }
        }
        if (Test-Path $IntroOurs) { Copy-Item $IntroOurs $Intro -Force }
        # The female outfits: loose cooked assets (tools/female/make_female.py), read through pve_loose_assets.
        $Female = Join-Path $Project 'assets\female\pak\RaidGame\Content'
        if (Test-Path $Female) { Copy-Item (Join-Path $Female '*') (Join-Path $Game 'RaidGame\Content') -Recurse -Force }
        # Backend → localhost port 1: every PGOS request fails locally instead of reaching the live service.
        (Get-Content $IniBackup) -replace '^socket_base_url\s*=.*', 'socket_base_url = wss://127.0.0.1:1' `
            -replace '^http_base_url\s*=.*', 'http_base_url = https://127.0.0.1:1' |
            Set-Content $PgosIni -Encoding ascii
        'Mode: offline'
    }
    'online' {
        foreach ($f in $Added) {
            $p = Join-Path $Bin $f
            if (Test-Path $p) { Remove-Item $p -Recurse -Force }
        }
        Copy-Item $IniBackup $PgosIni -Force
        Copy-Item $IntroBackup $Intro -Force
        'Mode: online (stock files restored; launch through Steam as usual)'
    }
}
