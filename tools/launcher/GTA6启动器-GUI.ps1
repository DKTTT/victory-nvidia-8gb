# GTA VI 启动器（图形界面）
# 功能：选择构建、主机模式、渲染分辨率；预翻译着色器 / 预编译管线（带进度）；启动游戏。
# 运行：双击同目录的「GTA6启动器-GUI.bat」
# 自测：set GTA6_GUI_TEST=1 后运行（自动点一次预热，10 秒后关闭）

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 单实例：已经有启动器在运行时直接退出，避免重复开游戏
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\GTA6LauncherSingleInstance')
if (-not $script:mutex.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show('启动器已经在运行了，请用已打开的那个窗口。', 'GTA VI 启动器')
    exit
}

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 路径
$Root = 'E:\gta6'
$Builds = @{
    'nv' = @{
        Name   = '构建 1 · NVIDIA 分支（最快）'
        Dir    = 'E:\gta6\work\vf-nvidia'
        Cache  = 'E:\gta6\cache-nvidia'
        Data   = 'E:\gta6\work\perf-data'
        Skip   = 'E:\gta6\work\vf-nvidia\scripts\rt_off_hashes.txt'
    }
    'mn' = @{
        Name   = '构建 2 · 最新上游（668 提交，已修白屏）'
        Dir    = 'E:\gta6\work\vf-main'
        Cache  = 'E:\gta6\cache-upstream'
        Data   = 'E:\gta6\work\perf-data-up'
        Skip   = 'E:\gta6\work\vf-main\scripts\rt_off_hashes.txt'
    }
}

$SettingsPath = Join-Path $Root 'gui-settings.json'
$DefaultSettings = @{
    Game    = 'E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK'
    Build   = 'nv'
    Console = 'series-s'
    Height  = 540
}
$S = $DefaultSettings.Clone()
if (Test-Path $SettingsPath) {
    try {
        $loaded = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($loaded.PSObject.Properties.Name)) { if ($S.ContainsKey($k)) { $S[$k] = $loaded.$k } }
    } catch { }
}

# ---------------------------------------------------------------- 界面
$Bg = [System.Drawing.Color]::FromArgb(26, 20, 46)
$Panel = [System.Drawing.Color]::FromArgb(38, 30, 66)
$Accent = [System.Drawing.Color]::FromArgb(230, 60, 90)
$TextCol = [System.Drawing.Color]::FromArgb(235, 235, 245)
$Muted = [System.Drawing.Color]::FromArgb(150, 150, 175)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GTA VI 启动器'
$form.Size = New-Object System.Drawing.Size(1000, 720)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Bg
$form.ForeColor = $TextCol
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [int]$size = 10, [System.Drawing.Color]$color = $TextCol) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $size)
    $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($l)
    return $l
}

function New-Radio([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$checked = $false, $parent = $null) {
    $r = New-Object System.Windows.Forms.RadioButton
    $r.Text = $text; $r.Location = New-Object System.Drawing.Point($x, $y)
    $r.Size = New-Object System.Drawing.Size($w, $h)
    $r.FlatStyle = 'Flat'; $r.ForeColor = $TextCol; $r.BackColor = $Bg
    $r.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $r.Checked = $checked
    if ($parent) { $parent.Controls.Add($r) } else { $form.Controls.Add($r) }
    return $r
}

function New-Panel([int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.BackColor = $Bg
    $form.Controls.Add($p)
    return $p
}

$title = New-Label 'GTA VI  ·  PC 移植启动器' 24 16 600 40 20 $Accent

$null = New-Label '游戏目录' 24 66 200 22
$tbGame = New-Object System.Windows.Forms.TextBox
$tbGame.Location = New-Object System.Drawing.Point(24, 92)
$tbGame.Size = New-Object System.Drawing.Size(700, 30)
$tbGame.BackColor = $Panel; $tbGame.ForeColor = $TextCol; $tbGame.BorderStyle = 'FixedSingle'
$tbGame.Text = $S.Game
$form.Controls.Add($tbGame)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览…'; $btnBrowse.Location = New-Object System.Drawing.Point(736, 91)
$btnBrowse.Size = New-Object System.Drawing.Size(110, 30)
$btnBrowse.FlatStyle = 'Flat'; $btnBrowse.BackColor = $Panel; $btnBrowse.ForeColor = $TextCol
$form.Controls.Add($btnBrowse)

$null = New-Label '构建' 24 136 200 22
$panelBuild = New-Panel 24 162 450 62
$rbBuildNv = New-Radio '构建 1 · NVIDIA 分支（最快 12-15 fps）' 0 0 430 26 ($S.Build -eq 'nv') $panelBuild
$rbBuildMn = New-Radio '构建 2 · 最新上游 668 提交（已修白屏）' 0 30 430 26 ($S.Build -eq 'mn') $panelBuild

$null = New-Label '主机模式' 500 136 200 22
$panelConsole = New-Panel 500 162 320 62
$rbSS = New-Radio 'Series S（较快 12-22 fps）' 0 0 300 26 ($S.Console -eq 'series-s') $panelConsole
$rbSX = New-Radio 'Series X（更清晰 6-7 fps）' 0 30 300 26 ($S.Console -eq 'series-x') $panelConsole

$null = New-Label '世界渲染分辨率（再放大到输出分辨率）' 24 236 500 22
$panelRes = New-Panel 24 262 950 30
$heights = @(2160, 1440, 1080, 720, 540, 480)
$rbRes = @{}
$x = 0
foreach ($hgt in $heights) {
    $r = New-Radio "${hgt}p" $x 0 108 26 ($S.Height -eq $hgt) $panelRes
    $rbRes[$hgt] = $r
    $x += 108
}

$btnWarmAll = New-Object System.Windows.Forms.Button
$btnWarmAll.Text = '预热全部（着色器 + 管线）'
$btnWarmAll.Location = New-Object System.Drawing.Point(24, 310)
$btnWarmAll.Size = New-Object System.Drawing.Size(300, 44)
$btnWarmAll.FlatStyle = 'Flat'; $btnWarmAll.BackColor = $Accent; $btnWarmAll.ForeColor = [System.Drawing.Color]::White
$btnWarmAll.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnWarmAll)

$btnWarmShaders = New-Object System.Windows.Forms.Button
$btnWarmShaders.Text = '只预热着色器'
$btnWarmShaders.Location = New-Object System.Drawing.Point(340, 310)
$btnWarmShaders.Size = New-Object System.Drawing.Size(170, 44)
$btnWarmShaders.FlatStyle = 'Flat'; $btnWarmShaders.BackColor = $Panel; $btnWarmShaders.ForeColor = $TextCol
$form.Controls.Add($btnWarmShaders)

$btnWarmWarm = New-Object System.Windows.Forms.Button
$btnWarmWarm.Text = '只预编译管线'
$btnWarmWarm.Location = New-Object System.Drawing.Point(526, 310)
$btnWarmWarm.Size = New-Object System.Drawing.Size(170, 44)
$btnWarmWarm.FlatStyle = 'Flat'; $btnWarmWarm.BackColor = $Panel; $btnWarmWarm.ForeColor = $TextCol
$form.Controls.Add($btnWarmWarm)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止'
$btnStop.Location = New-Object System.Drawing.Point(712, 310)
$btnStop.Size = New-Object System.Drawing.Size(110, 44)
$btnStop.FlatStyle = 'Flat'; $btnStop.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 90); $btnStop.ForeColor = $TextCol
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Text = '启动游戏'
$btnLaunch.Location = New-Object System.Drawing.Point(24, 372)
$btnLaunch.Size = New-Object System.Drawing.Size(798, 54)
$btnLaunch.FlatStyle = 'Flat'; $btnLaunch.BackColor = [System.Drawing.Color]::FromArgb(46, 160, 100); $btnLaunch.ForeColor = [System.Drawing.Color]::White
$btnLaunch.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnLaunch)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(24, 440)
$progress.Size = New-Object System.Drawing.Size(798, 16)
$progress.Style = 'Continuous'
$form.Controls.Add($progress)

$lblStatus = New-Label '就绪。预热可随时停止，下次继续。' 24 464 900 24 10 $Muted

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(24, 500)
$logBox.Size = New-Object System.Drawing.Size(930, 170)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 30)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 210)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

# ---------------------------------------------------------------- 状态
$script:proc = $null
$script:warmKind = ''
$script:warmTotal = 0
$script:warmDone = 0
$script:outLog = Join-Path $env:TEMP 'gta6-launcher-warm.out.log'
$script:errLog = Join-Path $env:TEMP 'gta6-launcher-warm.err.log'
$script:readPosOut = 0
$script:readPosErr = 0
$script:autoWarmStage = 0

function Add-Log([string]$text) {
    try {
        $logBox.AppendText($text + "`r`n")
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.ScrollToCaret()
    } catch { }
}

function Save-Settings {
    try {
        $S.Game = $tbGame.Text.Trim()
        $S.Build = if ($rbBuildMn.Checked) { 'mn' } else { 'nv' }
        $S.Console = if ($rbSX.Checked) { 'series-x' } else { 'series-s' }
        $S.Height = ($heights | Where-Object { $rbRes[$_].Checked } | Select-Object -First 1)
        $S | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
    } catch { }
}

function Current-Build {
    $k = if ($rbBuildMn.Checked) { 'mn' } else { 'nv' }
    return $Builds[$k]
}

function Render-Scale {
    $hgt = ($heights | Where-Object { $rbRes[$_].Checked } | Select-Object -First 1)
    $out = if ($rbSX.Checked) { 2160 } else { 1080 }
    $scale = [math]::Round($hgt / $out, 4)
    if ($scale -lt 0.2) { $scale = 0.2 }
    if ($scale -gt 1.0) { $scale = 1.0 }
    return $scale
}

function Set-BuildEnv($b) {
    if (-not $b -or -not $b.Cache -or -not $b.Data) {
        throw "构建配置无效：$($b | Out-String)"
    }
    $env:VICTORY_GAME_DIR = $tbGame.Text.Trim()
    $env:VICTORY_CACHE_DIR = $b.Cache
    $env:VICTORY_DATA_DIR = $b.Data
    $env:VICTORY_TEXTURE_NO_WAIT = '0'
    $env:VICTORY_TEXTURE_STAGE_MS = '500'
    $env:VICTORY_RELAY = '2'
    $env:VICTORY_WIDE_BACK = '1'
    $env:VICTORY_CARD_REHASH_RUNS = '1'
    $env:VICTORY_JOIN_COPIES = '1'
    $env:VICTORY_INDIRECT_WINDOW = '1'
    $env:VICTORY_RELAY_COPY = '1'
    $env:VICTORY_CARD_STEPS = '2'
    $env:VICTORY_INDIRECT_BATCH = '2'
    $env:VICTORY_MAP_THREADS = '1'
    $env:VICTORY_TITLE_PRIORITIES = '0'
    $env:VICTORY_CARD_AWAKE = '1'
    $env:VICTORY_SHOW_AFTER = '1'
    $env:VICTORY_AMBIENT = '0.8'
    $env:VICTORY_AMBIENT_AIR = '1.5'
    $env:VICTORY_AMBIENT_MOST = '2'
    $env:VICTORY_NAN_SCRUB = '1'
    $env:VICTORY_THIN = '1'
    $env:VICTORY_JOIN_PARTS = '8'
    $env:VICTORY_UPLOAD_AHEAD = '1'
    $env:VICTORY_D3D12_DRED = 'light'
    $env:VICTORY_DYNAMIC_SLOTS = '524288'
    $env:VICTORY_BVH_MISS = '1'
    $env:VICTORY_PIPELINE_WAIT_MS = '10000'
    $env:VICTORY_CARD_BUFFERS_MIN_MB = '1'
    $env:VICTORY_CARD_BUFFERS_MB = '1536'
}

function Start-Warm([string]$kind) {
    try {
        if ($script:proc -and -not $script:proc.HasExited) { Add-Log '预热已经在运行中。'; return }
        $b = Current-Build
        $exe = Join-Path $b.Dir 'target\diag\victory.exe'
        if (-not (Test-Path $exe)) { Add-Log "找不到: $exe"; return }
        $game = $tbGame.Text.Trim()
        $rpf = Join-Path $game 'shaders.rpf'
        if ($kind -ne 'pipelines' -and -not (Test-Path $rpf)) { Add-Log "找不到着色器包: $rpf"; return }

        Set-BuildEnv $b
        Remove-Item $script:outLog, $script:errLog -Force -ErrorAction SilentlyContinue
        $script:readPosOut = 0; $script:readPosErr = 0
        $script:warmDone = 0
        $script:warmSawDone = $false
        $script:warmKind = $kind

        $procArgs = if ($kind -eq 'shaders' -or $kind -eq 'all') { @('shaders', $rpf) } else { @('warm', '--used') }
        $script:warmTotal = if ($kind -eq 'pipelines') { 2400 } else { 26000 }
        $lblStatus.Text = if ($kind -eq 'pipelines') { '正在预编译管线…' } else { '正在预翻译着色器…' }

        $script:proc = Start-Process -FilePath $exe -ArgumentList $procArgs -WorkingDirectory $b.Dir `
            -RedirectStandardOutput $script:outLog -RedirectStandardError $script:errLog `
            -PassThru -WindowStyle Hidden
        Add-Log ("开始预热 [{0}] PID={1}" -f $kind, $script:proc.Id)
        $btnWarmAll.Enabled = $false; $btnWarmShaders.Enabled = $false; $btnWarmWarm.Enabled = $false
        $btnStop.Enabled = $true; $btnLaunch.Enabled = $false
        $progress.Value = 0
    } catch {
        Add-Log ("预热启动失败: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '预热启动失败')
    }
}

function Read-New-Log([string]$path, [ref]$pos) {
    try {
        if (-not (Test-Path $path)) { return @() }
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $pos.Value) { $pos.Value = 0 }
            $fs.Position = $pos.Value
            $sr = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd()
            $pos.Value = $fs.Position
            $sr.Dispose()
        } finally { $fs.Dispose() }
        if ($text) { return $text -split "`r?`n" | Where-Object { $_ -ne '' } }
        return @()
    } catch { return @() }
}

function Update-Warm {
    if (-not $script:proc) { return }
    $lines = @()
    $lines += Read-New-Log $script:outLog ([ref]$script:readPosOut)
    $lines += Read-New-Log $script:errLog ([ref]$script:readPosErr)
    foreach ($line in $lines) {
        Add-Log $line
        if ($line -match 'shaders in the cache|file scan complete|made in \d+') { $script:warmSawDone = $true }
        if ($line -match '(\d+)\s+of\s+(\d+),\s+(\d+)\s*s') {
            $script:warmDone = [int]$matches[1]; $script:warmTotal = [int]$matches[2]
        } elseif ($line -match '(\d+)\s+shaders in the cache') {
            $script:warmDone = [int]$matches[1]
            if ($script:warmTotal -lt $script:warmDone) { $script:warmTotal = $script:warmDone }
        } elseif ($line -match '(\d+)\s+pipelines known') {
            if ($matches[1] -match '^\d+$') {
                $known = [int]$matches[1]
                if ($known -lt 20000) { $script:warmTotal = [math]::Max($script:warmTotal, $known) }
            }
        }
    }
    if ($script:warmTotal -gt 0) {
        $v = [int](100 * $script:warmDone / $script:warmTotal)
        if ($v -gt 100) { $v = 100 }
        if ($v -ne $progress.Value) { $progress.Value = $v; $lblStatus.Text = ('预热中 {0}%（可停止，下次继续）' -f $v) }
    }
    if ($script:proc.HasExited) {
        $code = $null
        try {
            $finished = $script:proc
            # Start-Process -PassThru 的进程在 WaitForExit 之前 ExitCode 是空的
            $null = $finished.WaitForExit(2000)
            $code = $finished.ExitCode
            if ("$code" -eq '') { $code = $null }
        } catch { $code = $null }
        $script:proc = $null
        # 进程退出前最后一批输出可能还没读：这里再读一遍
        try {
            $tail = @()
            $tail += Read-New-Log $script:outLog ([ref]$script:readPosOut)
            $tail += Read-New-Log $script:errLog ([ref]$script:readPosErr)
            foreach ($l in $tail) {
                Add-Log $l
                if ($l -match 'shaders in the cache|file scan complete|made in \d+') { $script:warmSawDone = $true }
            }
        } catch { }
        $shown = if ($null -eq $code) { '未知' } else { $code }
        $ok = ($null -eq $code) -or ($code -eq 0) -or $script:warmSawDone -or ($script:warmDone -gt 0)
        Add-Log ("预热进程结束（退出码 {0}{1}）" -f $shown, $(if ($script:warmSawDone) { '，已输出完成汇总' } else { '' }))
        if ($script:warmKind -eq 'all' -and $ok -and $script:autoWarmStage -eq 0) {
            $script:autoWarmStage = 1
            Start-Warm 'pipelines'
            return
        }
        $script:autoWarmStage = 0
        if (-not $ok) { Add-Log ("预热失败（退出码 {0}），请看上面的日志" -f $shown) }
        $progress.Value = 100
        $btnWarmAll.Enabled = $true; $btnWarmShaders.Enabled = $true; $btnWarmWarm.Enabled = $true
        $btnStop.Enabled = $false; $btnLaunch.Enabled = $true
        $lblStatus.Text = '预热完成。'
    }
}

function Stop-Warm {
    try {
        if ($script:proc -and -not $script:proc.HasExited) {
            try { $script:proc.Kill($true) } catch { }
            Add-Log '已停止预热（下次继续）。'
        }
    } catch { }
    $script:proc = $null
    $script:autoWarmStage = 0
    $btnWarmAll.Enabled = $true; $btnWarmShaders.Enabled = $true; $btnWarmWarm.Enabled = $true
    $btnStop.Enabled = $false; $btnLaunch.Enabled = $true
    $lblStatus.Text = '已停止。'
}

function Launch-Game {
    try {
        Save-Settings
        $b = Current-Build
        $launcher = Join-Path $b.Dir 'target\diag\victory.exe'
        $game = $tbGame.Text.Trim()
        if (-not (Test-Path $launcher)) { Add-Log "找不到: $launcher"; return }
        $already = @(Get-Process victory -EA SilentlyContinue | Where-Object { $_.MainWindowTitle -ne '' })
        if ($already.Count -gt 0) {
            Add-Log '游戏已经在运行：先关掉游戏窗口再点启动。'
            [System.Windows.Forms.MessageBox]::Show('游戏已经在运行了，请先关闭游戏窗口。', 'GTA VI 启动器')
            return
        }
        Set-BuildEnv $b
        $env:VICTORY_RENDER_SCALE = [string](Render-Scale)
        $env:VICTORY_OWN_UPSCALER = '1'
        $env:VICTORY_COMPOSE = '1'
        try { $env:VICTORY_SKIP_PIPELINES = (Get-Content $b.Skip -Raw).Trim() } catch { }
        $consoleArg = if ($rbSX.Checked) { 'series-x' } else { 'series-s' }
        Add-Log ("启动游戏：{0} / {1} / 渲染缩放 {2}" -f $b.Name, $consoleArg, $env:VICTORY_RENDER_SCALE)
        Add-Log ("  缓存目录: {0}" -f $env:VICTORY_CACHE_DIR)
        Add-Log ("  数据目录: {0}" -f $env:VICTORY_DATA_DIR)
        if ($env:GTA6_GUI_STATE) {
            Add-Content -Path $env:GTA6_GUI_STATE -Value ("cache=" + $env:VICTORY_CACHE_DIR + " data=" + $env:VICTORY_DATA_DIR + " game=" + $env:VICTORY_GAME_DIR + " scale=" + $env:VICTORY_RENDER_SCALE + " console=" + $consoleArg)
        }
        $lblStatus.Text = '游戏运行中…'
        $script:game = Start-Process -FilePath $launcher `
            -ArgumentList @('run', (Join-Path $game 'game_scarlett_master.exe'), '--execute', '--console', $consoleArg) `
            -WorkingDirectory $b.Dir -PassThru
        Add-Log ("游戏已启动，PID={0}" -f $script:game.Id)
        $lblStatus.Text = '游戏运行中…（关闭启动器会结束游戏）'
        $btnLaunch.Enabled = $false
    } catch {
        Add-Log ("启动失败: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败')
    }
}

# ---------------------------------------------------------------- 事件
$btnBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择游戏目录（含 game_scarlett_master.exe）'
        if (Test-Path $tbGame.Text) { $dlg.SelectedPath = $tbGame.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $tbGame.Text = $dlg.SelectedPath }
    } catch { Add-Log ("浏览失败: " + $_.Exception.Message) }
})
$btnWarmAll.Add_Click({ Start-Warm 'all' })
$btnWarmShaders.Add_Click({ Start-Warm 'shaders' })
$btnWarmWarm.Add_Click({ Start-Warm 'pipelines' })
$btnStop.Add_Click({ Stop-Warm })
$btnLaunch.Add_Click({ Launch-Game })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    try { Update-Warm } catch { Add-Log ("更新日志出错: " + $_.Exception.Message) }
    try {
        if ($script:game -and $script:game.HasExited) {
            Add-Log ("游戏已退出（退出码 {0}）。" -f $script:game.ExitCode)
            $script:game = $null
            $lblStatus.Text = '游戏已退出。'
            $btnLaunch.Enabled = $true
        }
    } catch { }
})
$timer.Start()

$form.Add_FormClosing({
    try { Save-Settings } catch { }
    try { if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill($true) } } catch { }
    try { if ($script:game -and -not $script:game.HasExited) { $script:game.Kill($true) } } catch { }
})

# 诊断（设置 GTA6_GUI_STATE=路径 时导出单选状态）
if ($env:GTA6_GUI_STATE) {
    $resChecked = ($heights | Where-Object { $rbRes[$_].Checked } | Select-Object -First 1)
    $state = 'buildNv={0} buildMn={1} consoleSS={2} consoleSX={3} height={4}' -f `
        $rbBuildNv.Checked, $rbBuildMn.Checked, $rbSS.Checked, $rbSX.Checked, $resChecked
    Set-Content -Path $env:GTA6_GUI_STATE -Value $state
}
Add-Log '就绪。'
if ($env:GTA6_GUI_TEST -eq 'launch') {
    $testTimer = New-Object System.Windows.Forms.Timer
    $testTimer.Interval = 1500
    $testTimer.Add_Tick({
        $testTimer.Stop()
        Set-Content -Path 'E:\gta6\work\gui_test_launch.txt' -Value 'starting'
        try { Launch-Game } catch { Set-Content -Path 'E:\gta6\work\gui_test_launch_err.txt' -Value $_.Exception.Message }
    })
    $testTimer.Start()
    $closeTimer = New-Object System.Windows.Forms.Timer
    $closeTimer.Interval = 30000
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $gpp = Get-Process victory -EA SilentlyContinue | Select-Object -First 1
        $state = if ($gpp) { 'ALIVE ' + $gpp.MainWindowTitle } else { 'EXITED' }
        Set-Content -Path 'E:\gta6\work\gui_test_launch.txt' -Value $state
        Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        $form.Close()
    })
    $closeTimer.Start()
}
elseif ($env:GTA6_GUI_TEST -eq '1') {
    $testTimer = New-Object System.Windows.Forms.Timer
    $testTimer.Interval = 1500
    $testTimer.Add_Tick({
        $testTimer.Stop()
        try {
            $testKind = if ($env:GTA6_GUI_TEST_KIND) { $env:GTA6_GUI_TEST_KIND } else { 'pipelines' }
            Add-Log ("（自测：自动开始预热 {0}）" -f $testKind)
            Start-Warm $testKind
            $script:stopTimer = New-Object System.Windows.Forms.Timer
            $script:stopTimer.Interval = 8000
            $script:stopTimer.Add_Tick({
                $script:stopTimer.Stop()
                Stop-Warm
                Set-Content -Path 'E:\gta6\work\gui_test_ok.txt' -Value ('OK ' + (Get-Date -Format 'HH:mm:ss'))
                $form.Close()
            })
            $script:stopTimer.Start()
        } catch {
            Set-Content -Path 'E:\gta6\work\gui_test_fail.txt' -Value $_.Exception.Message
            $form.Close()
        }
    })
    $testTimer.Start()
}
[void]$form.ShowDialog()