# Co-op over ZeroTier (#202, docs/COOP.md): joins a ZeroTier network and prints your address on it.
#   powershell -ExecutionPolicy Bypass -File scripts\coop-zerotier.ps1 -Network <16-char id> [-Install]
#   ... -Network <id> -Leave       leaves that network
#   ... -Firewall                  host: allows the game in on UDP 7777 (one inbound rule, the game's program only)
#   ... (no arguments)             lists the networks you're on and your addresses
# ZeroTier's command line needs admin rights on Windows: the script asks for them once (a UAC prompt) and runs itself
# again elevated in its own window. -Install uses winget (ZeroTier.ZeroTierOne); nothing is installed without it.
param([string]$Network = '', [switch]$Install, [switch]$Leave, [switch]$Firewall, [switch]$Elevated)
$ErrorActionPreference = 'Stop'
$Project = Split-Path $PSScriptRoot

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Cli {
    foreach ($dir in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $dir) { continue }
        $cli = Join-Path $dir 'ZeroTier\One\zerotier-cli.bat'
        if (Test-Path $cli) { return $cli }
    }
    return $null
}

function Stop-WithPause($code) {
    if ($Elevated) { Read-Host 'Press Enter to close' | Out-Null }
    exit $code
}

if ($Network -and $Network -notmatch '^[0-9a-fA-F]{16}$') {
    [Console]::Error.WriteLine("A ZeroTier network ID is 16 characters, 0-9 and a-f (got '$Network').")
    exit 1
}

# Installing runs as you (winget asks for admin itself); the rest needs admin.
if ($Install -and -not (Find-Cli)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('winget is not available: install ZeroTier from https://www.zerotier.com/download/ and run this again.')
        exit 1
    }
    'Installing ZeroTier One (winget)...'
    winget install -e --id ZeroTier.ZeroTierOne --accept-source-agreements
    if (-not (Find-Cli)) {
        [Console]::Error.WriteLine('ZeroTier did not install. Install it from https://www.zerotier.com/download/ and run this again.')
        exit 1
    }
}

if (-not (Test-Admin)) {
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated')
    if ($Network) { $args2 += '-Network', $Network }
    if ($Leave) { $args2 += '-Leave' }
    if ($Firewall) { $args2 += '-Firewall' }
    'ZeroTier and the firewall need admin rights: Windows will ask, and the rest runs in a new window.'
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $args2 -Wait
    } catch {
        [Console]::Error.WriteLine('Admin rights were refused, so nothing was changed.')
        exit 1
    }
    exit 0
}

if ($Firewall) {
    $game = 'C:\Program Files (x86)\Steam\steamapps\common\PHtest'
    $gamePath = Join-Path $Project 'config\game_path.txt'
    if (Test-Path $gamePath) { $game = (Get-Content $gamePath -TotalCount 1).Trim() }
    $exe = Join-Path $game 'RaidGame\Binaries\Win64\RaidGame-Win64-Shipping.exe'
    if (-not (Test-Path $exe)) {
        [Console]::Error.WriteLine("The game isn't at $exe (config\game_path.txt).")
        Stop-WithPause 1
    }
    $name = 'Marauders Offline co-op (UDP 7777)'
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol UDP -LocalPort 7777 `
        -Program $exe -Profile Any | Out-Null
    "Firewall: '$name' allows $exe in on UDP 7777 (any network). Remove it from Windows Defender Firewall to undo."
    if (-not $Network) { Stop-WithPause 0 }
}

$cli = Find-Cli
if (-not $cli) {
    [Console]::Error.WriteLine('ZeroTier is not installed. Run again with -Install, or get it from https://www.zerotier.com/download/.')
    Stop-WithPause 1
}

function Get-Networks { (& $cli -j listnetworks | Out-String) | ConvertFrom-Json }

function Show-Networks {
    $nets = @(Get-Networks)
    if ($nets.Count -eq 0) { 'Not on any ZeroTier network.'; return }
    foreach ($n in $nets) {
        $ips = ($n.assignedAddresses | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ -match '^\d+\.' }) -join ', '
        "$($n.nwid)  $($n.name)  $($n.status)  your address: $(if ($ips) { $ips } else { '(none yet)' })"
    }
}

if ($Network -and $Leave) {
    & $cli leave $Network | Out-Null
    "Left $Network."
    Stop-WithPause 0
}

if ($Network) {
    & $cli join $Network | Out-Null
    "Joined $Network. Waiting for the host to authorise you (Members > Auth on my.zerotier.com)..."
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $n = @(Get-Networks) | Where-Object { $_.nwid -eq $Network.ToLower() } | Select-Object -First 1
        $ip = $n.assignedAddresses | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1
        if ($n -and $n.status -eq 'OK' -and $ip) {
            "Connected. Your ZeroTier address: $ip"
            'Hosting? Give this address to your friends. Joining? Type the HOST''s address in the launcher''s CO-OP box.'
            Stop-WithPause 0
        }
        if ($n -and $n.status -eq 'NOT_FOUND') {
            [Console]::Error.WriteLine("No ZeroTier network $Network. Check the ID with the host.")
            Stop-WithPause 1
        }
        Start-Sleep -Seconds 3
    }
    'Still waiting after 5 minutes. Ask the host to tick Auth for you, then run this again.'
    Stop-WithPause 1
}

Show-Networks
Stop-WithPause 0
