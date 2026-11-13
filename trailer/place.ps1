# Put the game window where rec.sh records: top-left corner, client 1840x1035 at 3,39 (after r.setres 1472x828w).
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WP { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
public struct RECT { public int L,T,R,B; } public struct POINT { public int X,Y; } }
"@
[WP]::SetProcessDPIAware() | Out-Null
$h = (Get-Process RaidGame-Win64-Shipping).MainWindowHandle
[WP]::SetWindowPos($h, [IntPtr]::Zero, -8, 0, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010) | Out-Null
$r = New-Object WP+RECT; [WP]::GetClientRect($h, [ref]$r) | Out-Null
$p = New-Object WP+POINT; [WP]::ClientToScreen($h, [ref]$p) | Out-Null
"client {0}x{1} at {2},{3}" -f $r.R, $r.B, $p.X, $p.Y
