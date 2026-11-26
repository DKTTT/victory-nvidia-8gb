param(
    [int]$Seconds = 45,
    [string]$Out = 'E:\gta6\work\sweep.csv',
    [int]$Dx = 60,
    [int]$SleepMs = 120,
    [switch]$LookUp
)
# 自动转视角测量：找游戏窗口置于前台，发送相对鼠标移动，同时采样窗口标题里的 fps/ms/draws
Add-Type -AssemblyName System.Windows.Forms -EA SilentlyContinue
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class INP {
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT {
        public uint type; public INPUTUNION u;
    }
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    public static void Move(int dx, int dy) {
        INPUT[] a = new INPUT[1];
        a[0].type = 0; // INPUT_MOUSE
        a[0].u.mi.dx = dx; a[0].u.mi.dy = dy;
        a[0].u.mi.dwFlags = 0x0001; // MOUSEEVENTF_MOVE
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
}
public class WIN {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    public static IntPtr Find(string part){ IntPtr f=IntPtr.Zero;
        EnumWindows((h,l)=>{ if(!IsWindowVisible(h)) return true;
            var t=new System.Text.StringBuilder(256); GetWindowTextW(h,t,256);
            if(t.ToString().Contains(part)){ f=h; return false; } return true; }, IntPtr.Zero);
        return f; }
}
'@ -ErrorAction SilentlyContinue

$h = [WIN]::Find('Americas')
if ($h -eq [IntPtr]::Zero) { Write-Host '找不到游戏窗口'; exit 1 }
[WIN]::ShowWindow($h, 9) | Out-Null
[WIN]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 3) | Out-Null
[WIN]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Seconds 1
[INP]::SetCursorPos(960, 540) | Out-Null
Start-Sleep -Milliseconds 300

function Get-Title {
    $sb = New-Object System.Text.StringBuilder 512
    [WIN]::GetWindowTextW($h, $sb, 512) | Out-Null
    return $sb.ToString()
}

$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('t,yaw_ms,title')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dir = 1
$i = 0
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    [INP]::Move($Dx * $dir, 0)
    if ($LookUp -and ($i % 20 -eq 0)) { [INP]::Move(0, -30) }
    Start-Sleep -Milliseconds $SleepMs
    $t = Get-Title
    $rows.Add(('{0:F1},{1},{2}' -f $sw.Elapsed.TotalSeconds, $dir, ($t -replace ',', ';')))
    $i++
    if ($i % 18 -eq 0) { $dir = -$dir }
}
$rows | Set-Content -Path $Out -Encoding UTF8
[WIN]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 3) | Out-Null
Write-Host "已采样 $($rows.Count - 1) 次 -> $Out"