# Click inside the recorded game area: click.ps1 <x> <y> in 1920x1080 frame coordinates (as in rec.sh's output).
param([double]$fx, [double]$fy)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WC { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e); }
"@
[WC]::SetProcessDPIAware() | Out-Null
$h = (Get-Process RaidGame-Win64-Shipping).MainWindowHandle
[WC]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [WC]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[WC]::SetForegroundWindow($h) | Out-Null
$x = [int](24 + $fx * 1796 / 1920); $y = [int](63 + $fy * 1010 / 1080)
[WC]::SetCursorPos($x - 20, $y) | Out-Null; Start-Sleep -Milliseconds 200
[WC]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 400
[WC]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [WC]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 150
[WC]::SetCursorPos(1900, 1430) | Out-Null
