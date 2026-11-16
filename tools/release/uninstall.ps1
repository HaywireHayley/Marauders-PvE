# Marauders Offline uninstaller: puts the game folder back to stock and removes the shortcuts. Your saves stay in
# backend\saves until you delete this folder yourself.
$ErrorActionPreference = 'Continue'
$Root = Split-Path $PSScriptRoot -Parent

Write-Host "`nMARAUDERS OFFLINE  -  uninstall`n" -ForegroundColor Yellow
if (Get-Process RaidGame-Win64-Shipping, RaidGame -ErrorAction SilentlyContinue) {
    Write-Host 'Close the game first, then run Uninstall.bat again.' -ForegroundColor Red
    Read-Host "`nPress Enter to close"; exit 1
}
if (Test-Path (Join-Path $Root 'config\game_path.txt')) {
    & (Join-Path $PSScriptRoot 'mode.ps1') online
}
foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    Remove-Item (Join-Path $dir 'Marauders Offline.lnk') -ErrorAction SilentlyContinue
}
Write-Host "`nThe game is back to stock and the shortcuts are gone." -ForegroundColor Green
Write-Host "To remove everything, delete this folder (your saves are in backend\saves):`n  $Root"
Read-Host "`nPress Enter to close"
