# Saves the game window to a PNG without bringing it forward (PrintWindow, full content): grab.ps1 <file.png> [-ProcessId <pid>]
# -ProcessId picks one copy when several are running (co-op host + client).
param([string]$Out, [int]$ProcessId = 0)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class PW { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
public struct RECT { public int L,T,R,B; } }
"@
[PW]::SetProcessDPIAware() | Out-Null
$h = if ($ProcessId) { (Get-Process -Id $ProcessId).MainWindowHandle } else { (Get-Process RaidGame-Win64-Shipping | Select-Object -First 1).MainWindowHandle }
$r = New-Object PW+RECT; [PW]::GetWindowRect($h, [ref]$r) | Out-Null
"window {0}x{1} at {2},{3} minimized={4}" -f ($r.R-$r.L), ($r.B-$r.T), $r.L, $r.T, [PW]::IsIconic($h)
$bmp = New-Object System.Drawing.Bitmap ($r.R-$r.L), ($r.B-$r.T)
$g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
[PW]::PrintWindow($h, $dc, 2) | Out-Null
$g.ReleaseHdc($dc); $g.Dispose(); $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
