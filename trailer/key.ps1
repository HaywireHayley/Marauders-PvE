# Press a key in the game: key.ps1 <virtual-key code> [hold ms]
param([int]$vk, [int]$hold = 80)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class WK { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
[DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e); }
"@
$h = (Get-Process RaidGame-Win64-Shipping).MainWindowHandle
[WK]::SetForegroundWindow($h) | Out-Null
$sc = [byte][WK]::MapVirtualKey($vk, 0)
[WK]::keybd_event([byte]$vk, $sc, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds $hold
[WK]::keybd_event([byte]$vk, $sc, 2, [UIntPtr]::Zero)
