# Pieces of launch-offline.ps1 that can be tested without starting the game (dot-source this file).

# Starts the local Nakama stand-in and waits until it answers on 127.0.0.1:$Port. Returns $null when it's up, else a
# sentence saying why not. The stand-in used to be started hidden with a fixed 2 s wait and never checked, so when it
# couldn't start (issue #75) the game sat on "CONNECTING TO BACKEND" forever with nothing to say why.
function Start-Standin($Project, $Python, $Port = 7350, $TimeoutSec = 15, $DataDir = $null, $Name = $null) {
    if (Test-StandinPort $Port) { return $null }
    $Backend = Join-Path $Project 'backend'
    $Err = Join-Path $Backend 'standin_err.log'  # the stand-in writes its startup crash here
    Remove-Item $Err -ErrorAction SilentlyContinue
    # No -Redirect*: with it the stand-in inherits this script's output pipe and the launcher's call never returns.
    # The path is quoted by hand: Windows PowerShell joins -ArgumentList with plain spaces, so an install folder with
    # a space in its path ran "python -I C:\My" and the stand-in never started (the likely cause of #75).
    $standinArgs = @('-I', "`"$(Join-Path $Backend 'nakama_standin.py')`"", '--port', $Port)
    # A co-op joiner's own save (scripts/launch-joiner.ps1): its folder and, for a new account, its name.
    if ($DataDir) { $standinArgs += '--dir', "`"$DataDir`"" }
    if ($Name) { $standinArgs += '--name', $Name }
    try {
        $proc = Start-Process $Python -ArgumentList $standinArgs -WindowStyle Hidden -PassThru
    } catch {
        return "the offline backend couldn't start ($Python): $($_.Exception.Message)"
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-StandinPort $Port) { return $null }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }
    $why = ''
    if (Test-Path $Err) {
        $why = Get-Content $Err -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 1
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if ($why) { return "the offline backend stopped: $($why.Trim()) (backend\standin_err.log)" }
    return "the offline backend didn't answer on port $Port within $TimeoutSec s (backend\server.log)"
}

function Test-StandinPort($Port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $Port).Wait(300) -and $c.Connected } catch { return $false } finally { $c.Close() }
}

# The windowed size: 1600x900 when it fits, else the biggest 16:9 that leaves room for the title bar and taskbar.
# A fixed 1600x900 ran off a 1366x768 laptop screen.
function Get-WindowedSize($ScreenX, $ScreenY) {
    if (-not $ScreenX -or -not $ScreenY) { return 1600, 900 }
    $w = [Math]::Min(1600, [Math]::Min([Math]::Floor($ScreenX * 0.9), [Math]::Floor(($ScreenY - 120) * 16 / 9)))
    $w = [Math]::Max(960, $w - ($w % 16))
    return [int]$w, [int]($w * 9 / 16)
}

function Get-ScreenSize {
    $Screen = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
    if ($Screen) { return $Screen.CurrentHorizontalResolution, $Screen.CurrentVerticalResolution }
    return $null, $null
}
