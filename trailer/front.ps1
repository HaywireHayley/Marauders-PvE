# Bring the game to the front and park the cursor off its window (used by rec.sh before each take).
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WF { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e); }
"@
[WF]::SetProcessDPIAware() | Out-Null
$h = (Get-Process RaidGame-Win64-Shipping).MainWindowHandle
[WF]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [WF]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[WF]::SetForegroundWindow($h) | Out-Null
[WF]::SetCursorPos(1900, 1430) | Out-Null
