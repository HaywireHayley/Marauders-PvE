# Find-Game: the Marauders folder (the one holding RaidGame\), looked for in every Steam library; $null if none.
# Dot-sourced by the player installer (tools/release/install.ps1) and scripts/setup-dev.ps1.
$ExeRel = 'RaidGame\Binaries\Win64\RaidGame-Win64-Shipping.exe'

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
