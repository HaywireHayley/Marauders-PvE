# Marauders Offline installer: finds Python and the game, installs Pillow, and makes the shortcuts.
# Run through Install.bat. Nothing in the game folder changes until you press PLAY in the launcher.
# Continue, not Stop: Windows PowerShell turns a native program's stderr output into a terminating error under Stop.
$ErrorActionPreference = 'Continue'
$Root = Split-Path $PSScriptRoot -Parent
$ExeRel = 'RaidGame\Binaries\Win64\RaidGame-Win64-Shipping.exe'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fail($text) { Say "`n$text" Red; Read-Host "`nPress Enter to close"; exit 1 }

Say "`nMARAUDERS OFFLINE  -  install`n" Yellow

# 1. The folder. The mods open files by this path, and non-English letters in it don't survive that.
if ($Root -match '[^\x20-\x7E]') {
    Fail "This folder's path has letters the mods can't open:`n  $Root`nMove the MaraudersOffline folder somewhere like C:\Games\MaraudersOffline and run Install.bat again."
}
if ($Root -match '\\(Program Files|Program Files \(x86\))\\') {
    Fail "Don't keep this in Program Files (the launcher saves your game here). Move it to e.g. C:\Games\MaraudersOffline."
}
Say "Folder:  $Root"

# 2. Python 3.9+ with tkinter (the launcher's window) - the installer can fetch it with winget.
function Find-Python {
    $tries = @(@('py', '-3'), @('python'))
    $local = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending
    foreach ($p in $local) { $tries += , @($p.FullName) }
    foreach ($t in $tries) {
        try {
            $exe = $t[0]; $pre = @($t | Select-Object -Skip 1)
            $out = & $exe @pre -c "import sys, tkinter; print(sys.executable); print(sys.version_info >= (3, 9))" 2>$null
            if ($LASTEXITCODE -eq 0 -and $out -and $out[1] -eq 'True' -and (Test-Path $out[0])) { return $out[0] }
        } catch {}
    }
    return $null
}

$Python = Find-Python
if (-not $Python) {
    Say "`nPython 3 isn't installed (the launcher and the offline backend run on it)." Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if ((Read-Host "Install Python 3.13 now with winget? [Y/n]") -notmatch '^[Nn]') {
            winget install -e --id Python.Python.3.13 --scope user --accept-package-agreements --accept-source-agreements
            $Python = Find-Python
        }
    }
    if (-not $Python) {
        Fail "Install Python 3 from https://www.python.org/downloads/ (tick 'tcl/tk' - it's on by default), then run Install.bat again."
    }
}
$Pythonw = Join-Path (Split-Path $Python) 'pythonw.exe'
if (-not (Test-Path $Pythonw)) { $Pythonw = $Python }
Say "Python:  $Python"

# 3. Pillow, for the launcher's artwork.
& $Python -c "import PIL" 2>$null
if ($LASTEXITCODE -ne 0) {
    Say "Installing Pillow (the launcher's image library)..."
    & $Python -m pip install --user --disable-pip-version-check --quiet pillow
    & $Python -c "import PIL" 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "Couldn't install Pillow. Try:  `"$Python`" -m pip install --user pillow" }
}
Say "Pillow:  ok"

# 4. The game: every Steam library, then ask.
function Find-Game {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value -replace '\\\\', '\' }
        }
    }
    foreach ($lib in $libs | Select-Object -Unique) {
        $common = Join-Path $lib 'steamapps\common'
        if (-not (Test-Path $common)) { continue }
        foreach ($d in Get-ChildItem $common -Directory -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $d.FullName $ExeRel)) { return $d.FullName }
        }
    }
    return $null
}

$Game = Find-Game
if (-not $Game) {
    Say "`nCouldn't find Marauders in your Steam libraries. Pick the game's folder (the one with RaidGame inside)." Yellow
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'The Marauders folder (it holds RaidGame)'
    while ($true) {
        if ($dlg.ShowDialog() -ne 'OK') { Fail 'No game folder chosen.' }
        $pick = $dlg.SelectedPath
        foreach ($c in @($pick, (Split-Path $pick), (Split-Path (Split-Path $pick)))) {
            if ($c -and (Test-Path (Join-Path $c $ExeRel))) { $Game = $c; break }
        }
        if ($Game) { break }
        Say "That folder doesn't have $ExeRel in it. Try again." Yellow
    }
}
[IO.File]::WriteAllText((Join-Path $Root 'config\game_path.txt'), "$Game`n")
Say "Game:    $Game"

# 5. Shortcuts: desktop and Start menu.
$shell = New-Object -ComObject WScript.Shell
$places = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
foreach ($dir in $places) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Marauders Offline.lnk'))
    $lnk.TargetPath = $Pythonw
    $lnk.Arguments = "`"$Root\launcher\launcher.pyw`""
    $lnk.WorkingDirectory = $Root
    $lnk.IconLocation = "$Root\assets\launcher\icon.ico,0"
    $lnk.Description = 'Marauders Offline PvE'
    $lnk.Save()
}
Say "Shortcuts: desktop and Start menu ('Marauders Offline')"

Say "`nDone. Start 'Marauders Offline' from your desktop, make a save, and press PLAY." Green
Say "Steam has to be running. The launcher puts the game folder back to stock when you close the game." Gray
if ((Read-Host "`nOpen the launcher now? [Y/n]") -notmatch '^[Nn]') {
    Start-Process $Pythonw -ArgumentList "`"$Root\launcher\launcher.pyw`"" -WorkingDirectory $Root
}
