param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Cache,
    [Parameter(Mandatory = $true)][string]$Tag,
    [int]$Seconds = 80,
    [string]$Compose = '1'
)
$w = 'E:\gta6\work\vf-main'
Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 1
Get-ChildItem Env: | Where-Object { $_.Name -like 'VICTORY_*' } -EA SilentlyContinue | ForEach-Object { Remove-Item "Env:$($_.Name)" -EA SilentlyContinue }
$env:VICTORY_GAME_DIR = 'E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK'
$env:VICTORY_CACHE_DIR = $Cache
$env:VICTORY_DATA_DIR = 'E:\gta6\work\perf-data-up'
$env:VICTORY_TEXTURE_NO_WAIT = '0'; $env:VICTORY_TEXTURE_STAGE_MS = '500'
$env:VICTORY_AMBIENT = '0.8'; $env:VICTORY_AMBIENT_AIR = '1.5'; $env:VICTORY_AMBIENT_MOST = '2'
$env:VICTORY_NAN_SCRUB = '1'; $env:VICTORY_BVH_MISS = '1'; $env:VICTORY_THIN = '1'
$env:VICTORY_JOIN_PARTS = '8'; $env:VICTORY_UPLOAD_AHEAD = '1'
$env:VICTORY_RELAY = '2'; $env:VICTORY_WIDE_BACK = '1'; $env:VICTORY_CARD_REHASH_RUNS = '1'
$env:VICTORY_JOIN_COPIES = '1'; $env:VICTORY_INDIRECT_WINDOW = '1'; $env:VICTORY_RELAY_COPY = '1'
$env:VICTORY_CARD_STEPS = '2'; $env:VICTORY_INDIRECT_BATCH = '2'; $env:VICTORY_MAP_THREADS = '1'
$env:VICTORY_TITLE_PRIORITIES = '0'; $env:VICTORY_CARD_AWAKE = '1'; $env:VICTORY_SHOW_AFTER = '1'
$env:VICTORY_PIPELINE_WAIT_MS = '10000'; $env:VICTORY_DYNAMIC_SLOTS = '524288'
$env:VICTORY_CARD_BUFFERS_MIN_MB = '1'; $env:VICTORY_CARD_BUFFERS_MB = '1536'
$env:VICTORY_RENDER_SCALE = '0.5'; $env:VICTORY_OWN_UPSCALER = '1'; $env:VICTORY_COMPOSE = $Compose
$env:VICTORY_KEYS = '20:Enter,30:Enter,40:Enter,50:Enter'
try { $env:VICTORY_SKIP_PIPELINES = (Get-Content "$w\scripts\rt_off_hashes.txt" -Raw).Trim() } catch { }
Set-Location $w
$log = "E:\gta6\work\$Tag.err"
Remove-Item $log -EA SilentlyContinue
Start-Process -FilePath $Exe -ArgumentList 'run', 'E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe', '--execute', '--console', 'series-s' `
    -WorkingDirectory $w -RedirectStandardError $log -PassThru | Out-Null

Add-Type -AssemblyName System.Windows.Forms, System.Drawing -EA SilentlyContinue
Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
public class CAPT{
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x,int y,int cx,int cy,uint flags);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
 [StructLayout(LayoutKind.Sequential)] public struct RECT{ public int L,T,R,B; }
 public static IntPtr Find(string part){ IntPtr f=IntPtr.Zero;
   EnumWindows((h,l)=>{ if(!IsWindowVisible(h)) return true;
     var t=new StringBuilder(256); GetWindowTextW(h,t,256);
     if(t.ToString().Contains(part)){ f=h; return false; } return true; }, IntPtr.Zero);
   return f; }
}
'@ -ErrorAction SilentlyContinue

Start-Sleep -Seconds $Seconds
$h = [CAPT]::Find('Americas')
if ($h -eq [IntPtr]::Zero) { "  [$Tag] 未找到游戏窗口"; exit }
[CAPT]::ShowWindow($h, 9) | Out-Null
[CAPT]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 3) | Out-Null
[CAPT]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Seconds 3
$r = New-Object CAPT+RECT
[CAPT]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size ($r.R - $r.L), ($r.B - $r.T)))
$g.Dispose()
$bmp.Save("E:\gta6\work\$Tag.png", [System.Drawing.Imaging.ImageFormat]::Png)
$white = 0; $tot = 0
for ($x = 40; $x -lt $bmp.Width - 40; $x += 20) {
    for ($y = 40; $y -lt $bmp.Height - 40; $y += 20) {
        $tot++; $px = $bmp.GetPixel($x, $y)
        if ($px.R -gt 240 -and $px.G -gt 240 -and $px.B -gt 240) { $white++ }
    }
}
$bmp.Dispose()
[CAPT]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 3) | Out-Null
$pct = [math]::Round($white / $tot * 100, 1)
$fps = (Get-Content $log -EA SilentlyContinue | Select-String 'fps, ' | Select-Object -Last 1)
$fpsLine = if ($fps) { $fps.Line.Substring([math]::Max(0, $fps.Line.IndexOf('fps,')), [math]::Min(110, $fps.Line.Length - [math]::Max(0, $fps.Line.IndexOf('fps,')))) } else { '无帧率' }
"  [$Tag] 白色 $pct%   $fpsLine"
Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue