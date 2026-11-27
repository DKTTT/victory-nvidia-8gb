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
    [switch]$NoGui,            # 不弹确认窗（自动化/远程用）
    [switch]$Turbo,            # 暴力模式：进程数加倍 + 较高优先级（安全，不会导致蓝屏/系统中断）
    [switch]$Extreme,          # 更暴力：High 优先级 + 批量160（仍不用 Realtime，仍会随时可停）
    [switch]$Used,             # 用 --used：只预热加载期真正画过的管线
    [switch]$ShadersOnly,      # 只编译着色器，不预热管线
    [switch]$Quiet,            # 静音档：少开线程/进程、优先级 idle，边用电脑边预热
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
function Convert-Progress([string]$line) {
    if ($line -match '^\[progress\] (\d+)/(\d+) \(([\d.]+)%\) \| ([^|]+) \| ([^|]+) \| ETA (.+)$') {
        $show = '进度 {0}/{1}（{2}%）| 已用 {3} | {4} | 预计剩余 {5}' -f $matches[1], $matches[2], $matches[3], $matches[4].Trim(), $matches[5].Trim(), $matches[6].Trim()
        try { $Host.UI.RawUI.WindowTitle = ('预热 {0}/{1} ({2}%) 剩余 {3}' -f $matches[1], $matches[2], $matches[3], $matches[6].Trim()) } catch {}
        return $show
    }
    if ($line -match '^\[library\] (\d+)/(\d+) in the pipeline library \| ([^|]+) \| ([^|]+) \| ETA (.+)$') {
        $show = '写管线库 {0}/{1} | 已用 {2} | {3} | 预计剩余 {4}' -f $matches[1], $matches[2], $matches[3].Trim(), $matches[4].Trim(), $matches[5].Trim()
        try { $Host.UI.RawUI.WindowTitle = ('写管线库 {0}/{1} 剩余 {2}' -f $matches[1], $matches[2], $matches[5].Trim()) } catch {}
        return $show
    }
    if ($line -match '^\[done\] (\d+) made in ([\d.]+) s \(average ([\d.]+)/s') {
        return ('[完成] 共 {0} 条，用了 {1} 秒，平均 {2} 条/秒' -f $matches[1], $matches[2], $matches[3])
    }
    return $line
}
function Format-Span([double]$seconds) {
    $s = [Math]::Max(0, [int]$seconds)
    if ($s -ge 3600) { return ('{0} 小时 {1} 分' -f [int]($s / 3600), [int](($s % 3600) / 60)) }
    if ($s -ge 60) { return ('{0} 分 {1} 秒' -f [int]($s / 60), [int]($s % 60)) }
    return ('{0} 秒' -f $s)
}
function Get-WarmCounts([string[]]$extra) {
    $a = @('warm', '--jobs', '1', '--limit', '0') + $extra
    $out = & $exe @a 2>&1 | Out-String
    if ($out -match '(\d+) pipelines known.*?(\d+) to make') {
        return [pscustomobject]@{ known = [int]$matches[1]; todo = [int]$matches[2] }
    }
    return $null
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
        $line = Convert-Progress "$_"
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

# 探测这个 victory.exe 支持什么：v5 没有 preload（写管线库），但有 warm --used
function Test-Subcommand([string]$name) {
    $o = & $exe $name --help 2>&1
    return ($LASTEXITCODE -eq 0)
}
$hasPreload = Test-Subcommand 'preload'
$warmHelp = (& $exe warm --help 2>&1 | Out-String)
$hasUsed = $warmHelp -match '--used'
Say ('功能探测：preload（写管线库）=' + $(if ($hasPreload) { '有' } else { '无（v5 正式版没有，会自动跳过）' }) + '；warm --used=' + $(if ($hasUsed) { '有' } else { '无' }))

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
# 按核心数分档：核心少就少开进程，别把桌面拖死；核心多就吃满
if ($cores -le 4) {
    $tier = '低配'
    if ($Jobs -le 0) { $Jobs = $cores }
    if ($WarmJobs -le 0) { $WarmJobs = [Math]::Max(2, [int][Math]::Floor($cores / 2)) }
    $estimate = '大约 6–10 小时'
} elseif ($cores -le 8) {
    $tier = '中配'
    if ($Jobs -le 0) { $Jobs = $cores }
    if ($WarmJobs -le 0) { $WarmJobs = [Math]::Max(2, [int][Math]::Floor($cores / 2)) }
    $estimate = '大约 4–6 小时'
} elseif ($cores -le 16) {
    $tier = '高配'
    if ($Jobs -le 0) { $Jobs = $cores }
    if ($WarmJobs -le 0) { $WarmJobs = [Math]::Max(2, [int][Math]::Round($cores * 0.75)) }
    $estimate = '大约 2.5–4 小时'
} else {
    $tier = '极高配'
    if ($Jobs -le 0) { $Jobs = $cores }
    if ($WarmJobs -le 0) { $WarmJobs = [Math]::Max(2, $cores) }
    $estimate = '大约 2–3 小时'
}
$env:VICTORY_GAME_DIR = $GameDir
if (-not $env:VICTORY_CACHE_DIR) {
    $env:VICTORY_CACHE_DIR = Join-Path $ScriptDir 'cache'
}
if (-not $env:VICTORY_DATA_DIR) {
    $env:VICTORY_DATA_DIR = Join-Path $env:LOCALAPPDATA 'victory\data'
}
New-Item -ItemType Directory -Force -Path $env:VICTORY_CACHE_DIR | Out-Null
$env:VICTORY_PROCESS_PRIORITY = 'high'

# 暴力模式：进程数加倍、子进程提优先级、每进程做更多管线（少开关进程）。
# 安全上限：优先级最高只到 High（绝不用 Realtime），进程数封顶 48，批量封顶 160；
# 内存紧张时看护进程会自动把预热进程降到 BelowNormal，防止页面风暴拖死系统。
if ($Turbo -or $Extreme) {
    $WarmJobs = [Math]::Min([Math]::Max(4, $cores * 2), 48)
    if ($Extreme) {
        $env:VICTORY_WARM_PRIORITY = 'high'
        $env:VICTORY_WARM_BATCH = '160'
        $watchClass = 'High'
        $watchText = 'High'
    } else {
        $env:VICTORY_WARM_PRIORITY = 'above'
        $env:VICTORY_WARM_BATCH = '80'
        $watchClass = 'AboveNormal'
        $watchText = 'AboveNormal（安全档）'
    }
    # 内存保险：每个预热进程预留 1 GB，剩余内存不够就自动少开，绝不让系统进入页面风暴
    $freeGB = 0
    try { $freeGB = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).FreePhysicalMemory / 1MB } catch {}
    if ($freeGB -gt 0) {
        $ramCap = [Math]::Max(2, [int][Math]::Floor($freeGB - 3))
        if ($WarmJobs -gt $ramCap) {
            Say ('内存只有 {0:N1} GB 空闲，预热进程数从 {1} 降到 {2}（安全起见）' -f $freeGB, $WarmJobs, $ramCap)
            $WarmJobs = [Math]::Max(2, $ramCap)
        }
    }
    if (-not $env:VICTORY_LOG) { $env:VICTORY_LOG = 'warn' }
} else {
    $watchClass = $null
}
Say ('逻辑核心：{0}（{1}）；着色器编译线程：{2}；管线预热进程：{3}' -f $cores, $tier, $Jobs, $WarmJobs)

# ---------- 1.5 档位与预计时间（按核心数 + 缓存里的真实待做数量实时算） ----------
Say ('缓存目录：' + $env:VICTORY_CACHE_DIR)
$rateFile = Join-Path $env:VICTORY_CACHE_DIR 'warm-rate.txt'
$perProc = 0.6
if (Test-Path -LiteralPath $rateFile) {
    try { $perProc = [double](Get-Content -LiteralPath $rateFile -TotalCount 1) } catch {}
}
$counts = $null
if (-not $ShadersOnly) {
    try {
        if ($Fast) { $counts = Get-WarmCounts @('--used') } else { $counts = Get-WarmCounts @() }
    } catch {}
}
$todo = if ($counts) { [int]$counts.todo } else { 0 }
$known = if ($counts) { [int]$counts.known } else { 0 }
if ($counts) { Say ('缓存里的管线：已知 {0} 条，待做 {1} 条' -f $known, $todo) }

function New-Tier([string]$key) {
    switch ($key) {
        'quiet'    { $warm = [Math]::Max(1, [int][Math]::Floor($cores / 8)); $prio = 'idle';   $batch = '40';  $watch = $null;         $name = '静音' }
        'balanced' { $warm = [Math]::Max(2, [int][Math]::Floor($cores * 0.75)); $prio = 'normal'; $batch = '40';  $watch = $null;         $name = '平衡' }
        'turbo'    { $warm = [Math]::Min([Math]::Max(4, $cores * 2), 48);      $prio = 'above';  $batch = '80';  $watch = 'AboveNormal'; $name = '暴力' }
        'extreme'  { $warm = [Math]::Min([Math]::Max(4, $cores * 2), 48);      $prio = 'high';   $batch = '160'; $watch = 'High';        $name = '极限' }
    }
    $eta = '已预热完'
    if ($Fast) { $eta = '几分钟' }
    elseif ($todo -gt 0) {
        $rate = [Math]::Max(0.05, $perProc * [Math]::Max(1, $warm))
        $eta = (Format-Span ($todo / $rate))
    }
    [pscustomobject]@{ key = $key; name = $name; jobs = $cores; warm = $warm; priority = $prio; batch = $batch; watch = $watch; eta = $eta }
}
$tierList = @('quiet', 'balanced', 'turbo', 'extreme') | ForEach-Object { New-Tier $_ }
$defaultTier = 'balanced'
if ($Turbo) { $defaultTier = 'turbo' } elseif ($Extreme) { $defaultTier = 'extreme' } elseif ($Quiet) { $defaultTier = 'quiet' }
$chosen = $null
$script:chosen = $null

if ($ShadersOnly) {
    Say '只编译着色器模式：跳过档位选择。'
    $chosen = New-Tier 'balanced'
} elseif ($Fast -or $Yes) {
    $chosen = $tierList | Where-Object { $_.key -eq $defaultTier } | Select-Object -First 1
} else {
    $gui = (-not $NoGui) -and (-not $env:VICTORY_NO_GUI) -and [Environment]::UserInteractive
    if ($gui) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            Add-Type -AssemblyName System.Drawing | Out-Null
            $form = New-Object System.Windows.Forms.Form
            $form.Text = 'GTA6 预热 — 选择档位'
            $form.ClientSize = New-Object System.Drawing.Size(640, 430)
            $form.StartPosition = 'CenterScreen'
            $form.FormBorderStyle = 'FixedDialog'
            $form.MaximizeBox = $false
            $form.MinimizeBox = $false
            $label = New-Object System.Windows.Forms.Label
            $label.AutoSize = $false
            $label.Location = New-Object System.Drawing.Point(16, 12)
            $label.Size = New-Object System.Drawing.Size(608, 290)
            $label.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
            $lines = @()
            $lines += '【GTA6 管线预热】选择档位 — 预计时间按你的 CPU 和缓存里的待做数量实时计算'
            $lines += ''
            $lines += ('你的 CPU：{0} 核（{1}）' -f $cores, $tier)
            if ($counts) { $lines += ('缓存里的管线：已知 {0} 条，待做 {1} 条' -f $known, $todo) } else { $lines += '缓存里的管线：数量未知（先跑一次预热后就有了）' }
            $lines += ('预计速度：每个预热进程约 {0:N2} 条/秒（来自上次实测）' -f $perProc)
            $lines += ''
            foreach ($t in $tierList) {
                $lines += ('  {0}：{1} 个进程，优先级 {2} —— 预计 {3}' -f $t.name.PadRight(6), $t.warm, $t.priority, $t.eta)
            }
            $lines += ''
            $lines += '⚠ 预热会吃满 CPU，期间玩别的游戏/看视频/开网页会卡顿；'
            $lines += '   可以随时 Ctrl+C 中止，进度保留，下次接着做。'
            $lines += '   安全：优先级最高只到 High（绝不用 Realtime），内存不足会自动降速，不会蓝屏或系统中断。'
            $label.Text = ($lines -join "`r`n")
            $form.Controls.Add($label)
            $x = 20
            $y = 318
            foreach ($t in $tierList) {
                $b = New-Object System.Windows.Forms.Button
                $b.Text = ('{0}（{1}）' -f $t.name, $t.eta)
                $b.Location = New-Object System.Drawing.Point($x, $y)
                $b.Size = New-Object System.Drawing.Size(140, 40)
                $b.Tag = $t.key
                $b.Add_Click({ $script:chosen = $this.Tag; $this.FindForm().Close() })
                $form.Controls.Add($b)
                $x += 148
            }
            $cancel = New-Object System.Windows.Forms.Button
            $cancel.Text = '取消'
            $cancel.Location = New-Object System.Drawing.Point(20, $y + 52)
            $cancel.Size = New-Object System.Drawing.Size(120, 34)
            $cancel.Add_Click({ $script:chosen = 'cancel'; $this.FindForm().Close() })
            $form.Controls.Add($cancel)
            $form.TopMost = $true
            [void]$form.ShowDialog()
            $form.Dispose()
            if (-not $script:chosen -or $script:chosen -eq 'cancel') {
                Say '已取消，没有做任何预热。'
                exit 0
            }
            $chosen = $tierList | Where-Object { $_.key -eq $script:chosen } | Select-Object -First 1
        } catch {
            Say ('档位选择窗打不开（{0}），改用控制台选择。' -f $_.Exception.Message)
            $chosen = $null
        }
    }
    if (-not $chosen) {
        Say ''
        Say '请选择预热档位：'
        for ($i = 0; $i -lt $tierList.Count; $i++) {
            $t = $tierList[$i]
            Say ('  {0}) {1}：{2} 个进程，优先级 {3} —— 预计 {4}' -f ($i + 1), $t.name, $t.warm, $t.priority, $t.eta)
        }
        Say ''
        $answer = Read-Host '输入 1-4 选择，回车取消'
        if ($answer -match '^[1-4]$') {
            $chosen = $tierList[[int]$answer - 1]
        } else {
            Say '已取消，没有做任何预热。'
            exit 0
        }
    }
}

# 应用所选档位
$Jobs = $chosen.jobs
$WarmJobs = $chosen.warm
$env:VICTORY_WARM_PRIORITY = $chosen.priority
$env:VICTORY_WARM_BATCH = $chosen.batch
$watchClass = $chosen.watch
$watchText = if ($chosen.watch) { $chosen.watch } else { 'normal' }
Say ('已选择：{0} 档 —— 着色器线程 {1}、预热进程 {2}、优先级 {3}、预计 {4}' -f $chosen.name, $Jobs, $WarmJobs, $chosen.priority, $chosen.eta)

# 内存保险：每个预热进程预留 1 GB，剩余内存不够就自动少开，绝不让系统进入页面风暴
$freeGB = 0
try { $freeGB = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).FreePhysicalMemory / 1MB } catch {}
if ($freeGB -gt 0 -and $freeGB -lt ($WarmJobs * 0.75 + 4)) {
    $ramCap = [Math]::Max(2, [int][Math]::Floor(($freeGB - 3) / 0.75))
    if ($WarmJobs -gt $ramCap) {
        Say ('内存只有 {0:N1} GB 空闲，预热进程数从 {1} 降到 {2}（安全起见）' -f $freeGB, $WarmJobs, $ramCap)
        $WarmJobs = [Math]::Max(2, $ramCap)
    }
}
if (-not $env:VICTORY_LOG) { $env:VICTORY_LOG = 'warn' }
# 把预热子进程的优先级提上来：新版 exe 自己会照 VICTORY_WARM_PRIORITY 执行，
# 旧版（v5）子进程生来是 Idle，这里每 2 秒扫一次帮它们升到 High。
$watcher = $null
if ($watchClass) {
    # 每 2 秒：把 warm 子进程提到 $watchClass；可用内存 < 1.5 GB 时降到 BelowNormal（防卡死/页面风暴）
    $cmd = @"
while (`$true) {
    `$free = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).FreePhysicalMemory / 1024
    `$want = if (`$free -lt 1536) { 'BelowNormal' } else { '$watchClass' }
    Get-CimInstance Win32_Process -Filter "Name='victory.exe'" -EA SilentlyContinue |
        Where-Object { `$_.CommandLine -match '--these' } |
        ForEach-Object { try { (Get-Process -Id `$_.ProcessId -EA SilentlyContinue).PriorityClass = `$want } catch {} }
    Start-Sleep -Seconds 2
}
"@
    $watcher = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', $cmd) -PassThru -WindowStyle Hidden
}
Say ('日志：' + $LogPath)

# ---------- 2. 着色器全量编译 ----------
if (-not $SkipShaders) {
    Phase '第 1 步 / 共 3 步：编译全部着色器（全核）'
    $r = Run $exe @('shaders', $GameDir, '--jobs', "$Jobs") '编译全部着色器'
    if ($r.code -ne 0) { Say '（着色器编译有报错，后面仍会继续，可能还有个别着色器没编好）' }

    if ($ShadersOnly) {
        Phase '完成（只编译着色器）'
        Say '着色器已全部编译。要预热管线请再运行 预热-火力全开.bat（或 平衡/暴力档）。'
        Say ('完整日志：' + $LogPath)
        exit 0
    }
} else {
    Say '（跳过着色器编译）'
}

# 上一次被 Ctrl+C 打断时，正在做的管线会被误记进 warm-bad.txt（exit code 0xc000013a）。
# 先剔掉这些误记，否则那几条永远不会再预热。
$badFile = Join-Path (Join-Path $env:VICTORY_CACHE_DIR 'pipelines') 'warm-bad.txt'
if (Test-Path -LiteralPath $badFile) {
    $badLines = Get-Content -LiteralPath $badFile -Encoding UTF8 -ErrorAction SilentlyContinue
    $kept = @($badLines | Where-Object { $_ -notmatch '0xc000013a' })
    if ($kept.Count -ne $badLines.Count) {
        Set-Content -LiteralPath $badFile -Value $kept -Encoding UTF8
        Say ('已清理上次 Ctrl+C 误记的管线：{0} 条（会重新预热）' -f ($badLines.Count - $kept.Count))
    }
}

# ---------- 3. 管线预热：反复做到没有新管线 ----------
if ($Fast) {
    Phase '第 2 步 / 共 3 步：快速预热（只做加载期用到的管线）'
    if ($hasUsed) {
        $r = Run $exe @('warm', '--used', '--jobs', "$WarmJobs") '快速预热加载期管线'
    } else {
        # 没有 --used：warm 本来就先做加载期管线，用 --limit 截前 4000 条（几分钟）
        $r = Run $exe @('warm', '--limit', '4000', '--jobs', "$WarmJobs") '快速预热（先做加载期优先的 4000 条）'
    }
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
    if ($Used) {
        if ($hasUsed) { $warmArgs += '--used' } else { Say '（这个版本没有 warm --used，按全部管线预热）' }
    }
    if ($WarmLimit -gt 0) { $warmArgs += @('--limit', "$WarmLimit") }
    if ($FullRebuild -and $round -eq 1) { $warmArgs += '--again' }
    Say ''
    Say ("-- 第 $round 轮")
    $began = Get-Date
    $lines = @()
    & $exe @warmArgs 2>&1 | ForEach-Object {
        $line = Convert-Progress "$_"
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
    foreach ($l in $lines) { if ($l -match '平均 ([\d.]+) 条/秒') { try { Set-Content -LiteralPath $rateFile -Value ('{0:N3}' -f ([double]$matches[1] / [Math]::Max(1, $WarmJobs))) -Encoding ASCII } catch {} } }
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
if (-not $SkipIntoLibrary -and $hasPreload) {
    Phase '第 3 步 / 共 3 步：把加载期与慢管线写进管线库'
    $r = Run $exe @('preload', $GameDir) '写入管线库'
    if ($r.code -ne 0) { Say '（写入管线库返回非 0，可以忽略或重跑一次）' }
} elseif (-not $SkipIntoLibrary) {
    Say '这一版 victory.exe 没有 preload（写管线库）命令（v5 正式版就是这样），跳过第 3 步。'
    Say '着色器编译 + 管线预热已经完成，直接启动游戏即可。'
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
if ($watcher) { Stop-Process -Id $watcher.Id -Force -EA SilentlyContinue }
try { $Host.UI.RawUI.WindowTitle = 'GTA6 CN 预热完成' } catch {}
Say '预热完成。现在双击「启动.bat」进游戏，第一次进世界会明显更顺。' 
Say '以后更新了构建或显卡驱动，建议再跑一次本脚本。'
Say ('完整日志：' + $LogPath)