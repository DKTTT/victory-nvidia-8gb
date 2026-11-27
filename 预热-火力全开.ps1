# GTA6 CN —— 预热「火力全开」脚本
# 把每一步都做满：全核编译全部着色器 → 反复预热全部管线 → 写入管线库 → 报告耗时。
# 可以随时 Ctrl+C 停止；已经做完的会保留，下次接着做。
param(
    [string]$GameDir = '',
    [int]$Jobs = 0,            # 0 = 全部逻辑核心（着色器编译）
    [int]$WarmJobs = 0,        # 0 = 逻辑核心的 3/4（管线预热，每个进程都很吃 CPU）
    [int]$MaxWarmRounds = 40,  # 最多反复预热多少轮，直到没有新管线可做
    [switch]$SkipShaders,
    [switch]$SkipIntoLibrary,
    [switch]$FullRebuild,      # 连之前做过的管线也重做（驱动/构建更新后用）
    [int]$WarmLimit = 0,       # >0：这一轮最多做这么多条（试跑用）
    [switch]$Fast,             # 快速模式：只做加载期用到的管线（--used），不跑全量、不写管线库
    [switch]$Used,             # 用 --used：只预热加载期真正画过的管线
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath = Join-Path $ScriptDir ('预热日志-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

function Say([string]$text) {
    Write-Host $text
    Add-Content -LiteralPath $LogPath -Value $text -Encoding UTF8
}
function Phase([string]$title) {
    Say ''
    Say ('=' * 78)
    Say ('== ' + $title)
    Say ('=' * 78)
}
function Run([string]$exe, [string[]]$arguments, [string]$what) {
    $began = Get-Date
    # 输出同时进控制台和日志
    & $exe @arguments 2>&1 | ForEach-Object {
        $line = "$_"
        Write-Host $line
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    $code = $LASTEXITCODE
    $mins = ((Get-Date) - $began).TotalMinutes
    Say ('-- {0}：{1:N1} 分钟，退出码 {2}' -f $what, $mins, $code)
    return @{ code = $code; minutes = $mins }
}

# ---------- 0. 基本信息 ----------
Say 'GTA6 CN 预热（火力全开）'
Say ('时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Say ('脚本：' + $ScriptDir)

# 找游戏目录：参数 → 本文件夹 → game-path.txt → VICTORY_GAME_DIR → 常见路径 → 各盘 *GTA6*
function Test-Game([string]$path) {
    return ($path -and (Test-Path -LiteralPath (Join-Path $path 'game_scarlett_master.exe')))
}
if (-not (Test-Game $GameDir)) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($ScriptDir)
    $candidates.Add((Split-Path -Parent $ScriptDir))
    $pathFile = Join-Path $ScriptDir 'game-path.txt'
    if (Test-Path -LiteralPath $pathFile) {
        $saved = (Get-Content -LiteralPath $pathFile -TotalCount 1)
        if ($saved) { $candidates.Add($saved.Trim()) }
    }
    if ($env:VICTORY_GAME_DIR) { $candidates.Add($env:VICTORY_GAME_DIR) }
    foreach ($p in @('E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK', 'D:\GTA6.Xbox.v1.0.2.1-CYBERLEEK', 'C:\GTA6.Xbox.v1.0.2.1-CYBERLEEK')) { $candidates.Add($p) }
    foreach ($drive in @('C', 'D', 'E', 'F', 'G', 'H')) {
        $root = "${drive}:\"
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -Filter '*GTA6*' -ErrorAction SilentlyContinue |
                ForEach-Object { $candidates.Add($_.FullName) }
        }
    }
    foreach ($c in $candidates) {
        if (Test-Game $c) { $GameDir = $c; break }
    }
}
if (-not (Test-Game $GameDir)) {
    Say '找不到游戏文件夹（里面要有 game_scarlett_master.exe）。'
    Say '把本脚本放进游戏目录，或用「设置游戏目录.bat」选一次，或者这样运行：'
    Say ('   预热-火力全开.bat "D:\你的游戏目录"')
    exit 1
}
Say ('游戏目录：' + $GameDir)
$exe = Join-Path $ScriptDir 'victory.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Say '本文件夹里没有 victory.exe —— 请把脚本和 victory.exe 放在一起。'
    exit 1
}

# 正在运行游戏就别预热了（会抢 CPU/显存，还会锁缓存）
$running = Get-Process -Name 'victory' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($running) {
    Say '检测到 victory.exe 正在运行（游戏或另一个预热）。'
    if (-not $Yes) {
        Say '请先关掉它，或加 -Yes 参数强制继续。'
        exit 1
    }
    Say '已按 -Yes 继续。'
}

# ---------- 1. 环境 ----------
$cores = [Environment]::ProcessorCount
if ($Jobs -le 0) { $Jobs = $cores }
if ($WarmJobs -le 0) { $WarmJobs = [Math]::Max(2, $cores) }
$env:VICTORY_GAME_DIR = $GameDir
if (-not $env:VICTORY_CACHE_DIR) {
    $env:VICTORY_CACHE_DIR = Join-Path $ScriptDir 'cache'
}
if (-not $env:VICTORY_DATA_DIR) {
    $env:VICTORY_DATA_DIR = Join-Path $env:LOCALAPPDATA 'victory\data'
}
New-Item -ItemType Directory -Force -Path $env:VICTORY_CACHE_DIR | Out-Null
$env:VICTORY_PROCESS_PRIORITY = 'high'
Say ('逻辑核心：{0}；着色器编译线程：{1}；管线预热进程：{2}' -f $cores, $Jobs, $WarmJobs)
Say ('缓存目录：' + $env:VICTORY_CACHE_DIR)
Say ('日志：' + $LogPath)

# ---------- 2. 着色器全量编译 ----------
if (-not $SkipShaders) {
    Phase '第 1 步 / 共 3 步：编译全部着色器（全核）'
    $r = Run $exe @('shaders', $GameDir, '--jobs', "$Jobs") '编译全部着色器'
    if ($r.code -ne 0) { Say '（着色器编译有报错，后面仍会继续，可能还有个别着色器没编好）' }
} else {
    Say '（跳过着色器编译）'
}

# ---------- 3. 管线预热：反复做到没有新管线 ----------
if ($Fast) {
    Phase '第 2 步 / 共 3 步：快速预热（只做加载期用到的管线）'
    $r = Run $exe @('warm', '--used', '--jobs', "$WarmJobs") '快速预热加载期管线'
    if ($r.code -ne 0) { Say '（快速预热返回非 0，可忽略）' }
    Phase '完成（快速模式）'
    Say '快速模式：没有预热全部管线，也没有写管线库。'
    Say '先进游戏玩一次——游戏里用到的管线会被驱动缓存下来，下次启动就顺了；'
    Say '想一次做到底就再跑一次不带 -Fast 的本脚本（支持断点续跑）。'
    Say ('完整日志：' + $LogPath)
    exit 0
}
Phase '第 2 步 / 共 3 步：预热全部管线（反复做到没有新管线）'
$round = 0
$stalled = 0
$lastTodo = -1
while ($round -lt $MaxWarmRounds) {
    $round++
    $warmArgs = @('warm', '--jobs', "$WarmJobs")
    if ($Used) { $warmArgs += '--used' }
    if ($WarmLimit -gt 0) { $warmArgs += @('--limit', "$WarmLimit") }
    if ($FullRebuild -and $round -eq 1) { $warmArgs += '--again' }
    Say ''
    Say ("-- 第 $round 轮")
    $began = Get-Date
    $lines = @()
    & $exe @warmArgs 2>&1 | ForEach-Object {
        $line = "$_"
        $lines += $line
        Write-Host $line
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    $code = $LASTEXITCODE
    $todo = $null
    foreach ($line in $lines) {
        if ($line -match '(\d+)\s+to make') { $todo = [int]$matches[1] }
    }
    $mins = ((Get-Date) - $began).TotalMinutes
    Say ('-- 第 {0} 轮：{1:N1} 分钟，退出码 {2}，待做 {3}' -f $round, $mins, $code, $todo)
    if ($null -eq $todo) {
        Say '（这一轮没看到“to make”统计，按完成处理）'
        break
    }
    if ($todo -le 0) { break }
    if ($todo -eq $lastTodo) {
        $stalled++
        if ($stalled -ge 2) {
            Say '连续两轮待做数量不变，停止反复预热（剩下的可能反复失败）。'
            break
        }
    } else {
        $stalled = 0
    }
    $lastTodo = $todo
}

# ---------- 4. 写成管线库（进游戏加载时用）----------
if (-not $SkipIntoLibrary) {
    Phase '第 3 步 / 共 3 步：把加载期与慢管线写进管线库'
    $r = Run $exe @('preload', $GameDir) '写入管线库'
    if ($r.code -ne 0) { Say '（写入管线库返回非 0，可以忽略或重跑一次）' }
} else {
    Say '（跳过写入管线库）'
}

# ---------- 5. 报告 ----------
Phase '完成'
$shaders = Join-Path $env:VICTORY_CACHE_DIR 'shaders'
$pipes = Join-Path $env:VICTORY_CACHE_DIR 'pipelines'
foreach ($pair in @(@{name = '着色器缓存'; path = $shaders }, @{name = '管线缓存'; path = $pipes })) {
    if (Test-Path -LiteralPath $pair.path) {
        $mb = [Math]::Round(((Get-ChildItem -LiteralPath $pair.path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 0)
        Say ('{0}：{1} MB  （{2}）' -f $pair.name, $mb, $pair.path)
    }
}
Say ''
Say '预热完成。现在双击「启动.bat」进游戏，第一次进世界会明显更顺。'
Say '以后更新了构建或显卡驱动，建议再跑一次本脚本。'
Say ('完整日志：' + $LogPath)