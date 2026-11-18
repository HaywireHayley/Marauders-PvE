# Puts the armour test into a test install (or takes it out again):
#   powershell -File tools\armour_test\install.ps1 -Scripts <folder holding botdamage.lua>
#   powershell -File tools\armour_test\install.ps1 -Scripts <folder> -Remove
# It copies armourtest.lua and armourtest_hook.lua next to botdamage.lua and adds ONE line before that file's final "return B".
# Nothing else is touched, and the menu code is not changed: the hook adds the F9 button through debugmenu.addActions.
# Refuses a folder inside a git working tree, so the shipped mod can never pick the test up by accident. Run it on a copy.
param(
    [Parameter(Mandatory = $true)][string]$Scripts,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$Marker = '-- ARMOUR TEST HOOK (tools/armour_test)'
$Hook = 'pcall(function() require("armourtest_hook")(B) end) ' + $Marker
$Files = 'armourtest.lua', 'armourtest_hook.lua'

$Scripts = (Resolve-Path $Scripts).Path
$bd = Join-Path $Scripts 'botdamage.lua'
if (-not (Test-Path $bd)) { throw "No botdamage.lua in $Scripts. Point -Scripts at the Scripts folder of a test install." }
if ((Get-Process RaidGame-Win64-Shipping, RaidGame -ErrorAction SilentlyContinue)) { throw 'Close the game first.' }

$d = $Scripts
while ($d) {
    if (Test-Path (Join-Path $d '.git')) { throw "$Scripts is inside a git working tree ($d). Install the test into a test install, not the repo." }
    $up = Split-Path $d -Parent
    if (-not $up -or $up -eq $d) { break }
    $d = $up
}

$text = [IO.File]::ReadAllText($bd)
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = @($text -split "`r?`n" | Where-Object { -not $_.Contains($Marker) })

if (-not $Remove) {
    if ($text -match 'valuedump|testtools|TEST LOGGING') { throw 'This botdamage.lua already carries an older test wrapper. Start from the repo copy of botdamage.lua.' }
    $at = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^return B\s*$') { $at = $i; break } }
    if ($at -lt 0) { throw 'botdamage.lua has no final "return B" line.' }
    $lines = @($lines[0..($at - 1)]) + $Hook + @($lines[$at..($lines.Count - 1)])
    foreach ($f in $Files) { Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $Scripts $f) -Force }
} else {
    foreach ($f in $Files) { Remove-Item (Join-Path $Scripts $f) -Force -ErrorAction SilentlyContinue }
}
[IO.File]::WriteAllText($bd, ($lines -join $nl), (New-Object Text.UTF8Encoding $false))
if ($Remove) { Write-Host "Armour test removed from $Scripts" } else { Write-Host "Armour test installed in $Scripts. In a raid, open F9 and click Armour test." }
