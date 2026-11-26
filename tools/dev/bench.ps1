param(
    [string]$Exe = 'E:\gta6\work\vf-main\target\diag\victory.exe',
    [string]$Cache = 'E:\gta6\cache-upstream',
    [string]$Tag = 'bench',
    [string]$Scale = '0.5',
    [string]$Extra = '',          # 额外环境变量，形如 "A=1;B=2"
    [int]$SweepSeconds = 30,
    [int]$WorldWaitSeconds = 170,
    [switch]$NoSweep
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
$env:VICTORY_RENDER_SCALE = $Scale; $env:VICTORY_OWN_UPSCALER = '1'; $env:VICTORY_COMPOSE = '1'
$env:VICTORY_KEYS = '20:Enter,30:Enter,40:Enter,50:Enter,60:Enter,70:Enter'
try { $env:VICTORY_SKIP_PIPELINES = (Get-Content "$w\scripts\rt_off_hashes.txt" -Raw).Trim() } catch { }
if ($Extra) {
    foreach ($pair in $Extra.Split(';')) {
        if ($pair -match '=') { $k, $v = $pair.Split('=', 2); Set-Item -Path "Env:$k" -Value $v }
    }
}
Set-Location $w
$log = "E:\gta6\work\$Tag.err"
Remove-Item $log -EA SilentlyContinue
Start-Process -FilePath $Exe -ArgumentList 'run', 'E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe', '--execute', '--console', 'series-s' `
    -WorkingDirectory $w -RedirectStandardError $log -PassThru | Out-Null

# 等进入世界：日志里出现 draws/frame 且 >1500
$entered = $false
$deadline = (Get-Date).AddSeconds($WorldWaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (-not (Get-Process victory -EA SilentlyContinue)) { break }
    $hit = Get-Content $log -EA SilentlyContinue | Select-String 'fps, ' | Select-Object -Last 1
    if ($hit -and $hit.Line -match '(\d+) draws/frame' -and [int]$matches[1] -gt 1500) { $entered = $true; break }
}
"[{0}] 进入世界: {1}" -f $Tag, $entered
if ($entered -and -not $NoSweep) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'E:\gta6\work\camera_sweep.ps1' -Seconds $SweepSeconds -Out "E:\gta6\work\$Tag-sweep.csv" -Dx 60 -SleepMs 120 | Out-Null
} else {
    Start-Sleep -Seconds $SweepSeconds
}
# 统计
$frames = @(); $gpus = @(); $draws = @(); $wait = @()
Get-Content $log -EA SilentlyContinue | Select-String 'fps, ' | Select-Object -Last 40 | ForEach-Object {
    $l = $_.Line
    if ($l -match '([\d.]+) ms/frame') { $frames += [double]$matches[1] }
    if ($l -match '([\d.]+) on the GPU') { $gpus += [double]$matches[1] }
    if ($l -match '(\d+) draws/frame') { $draws += [int]$matches[1] }
}
Get-Content $log -EA SilentlyContinue | Select-String 'waited for flights, per frame: ([\d.]+) ms' | Select-Object -Last 10 | ForEach-Object { $wait += [double]$matches[1] }
function Stat($a) { if ($a.Count) { "min {0} 中位 {1} max {2}" -f ($a | Measure-Object -Minimum).Minimum, [math]::Round(($a | Sort-Object)[[int]($a.Count / 2)], 1), ($a | Measure-Object -Maximum).Maximum } else { '无' } }
"  帧时间ms: $(Stat $frames)"
"  GPU ms:   $(Stat $gpus)"
"  绘制数:   $(Stat $draws)"
"  等待上传ms: $(Stat $wait)"
# 显存
Get-Content $log -EA SilentlyContinue | Select-String 'budget (\d+) MB, in use (\d+) MB' | Select-Object -Last 1 | ForEach-Object { "  显存: $($_.Line.Substring([math]::Max(0,$_.Line.IndexOf('budget')),60))" }
Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
"[{0}] 结束" -f $Tag