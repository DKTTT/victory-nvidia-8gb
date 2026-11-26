# GTA VI PC 移植 - 自动检测启动器 v1.0
# 功能：检测硬件 -> 推荐构建与画质；自定义路径；从 GitHub 下载构建；预热；启动
# 运行：双击同目录 GTA6-Launcher.bat

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 单实例
$script:mutex = New-Object System.Threading.Mutex($false, 'Global\GTA6AutoLauncher')
if (-not $script:mutex.WaitOne(0)) {
    [System.Windows.Forms.MessageBox]::Show('启动器已经在运行了。', 'GTA VI 启动器')
    exit
}

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'launcher-config.json'

# ---------------------------------------------------------------- 配置
$DefaultCfg = @{
    GameDir   = 'E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK'
    BuildRoot = 'E:\gta6\work'
    CacheRoot = 'E:\gta6'
    SaveRoot  = 'E:\gta6\work'
    Repo      = 'DKTTT/victory-nvidia-8gb'
    Branch    = 'tools-and-patches'
    Console   = 'auto'
    Height    = 'auto'
    Build     = 'auto'
    Preset    = 'auto'
    RaceUrl   = 'https://vuyp.github.io/gta6-pc-race/src/data.json'
    KeyMap    = ''
    KeyMapOn  = $false
}
$Cfg = $DefaultCfg.Clone()
if (Test-Path $ConfigPath) {
    try {
        $loaded = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($loaded.PSObject.Properties.Name)) { if ($Cfg.ContainsKey($k)) { $Cfg[$k] = $loaded.$k } }
    } catch { }
}
function Save-Cfg {
    try {
        $Cfg.GameDir = $tbGame.Text.Trim()
        $Cfg.BuildRoot = $tbBuildRoot.Text.Trim()
        $Cfg.CacheRoot = $tbCacheRoot.Text.Trim()
        $Cfg.SaveRoot = $tbSaveRoot.Text.Trim()
        $Cfg.Repo = $tbRepo.Text.Trim()
        $Cfg.Branch = $tbBranch.Text.Trim()
        $Cfg.Console = if ($rbAutoCon.Checked) { 'auto' } elseif ($rbSX.Checked) { 'series-x' } else { 'series-s' }
        $selH = ($heights | Where-Object { $rbResMap[$_].Checked } | Select-Object -First 1)
        $Cfg.Height = if ($rbAutoRes.Checked -or -not $selH) { 'auto' } else { "$selH" }
        $Cfg.KeyMap = if ($txtKeyMap) { $txtKeyMap.Text } else { '' }
        $Cfg.KeyMapOn = if ($chkKeyAuto) { [bool]$chkKeyAuto.Checked } else { $false }
        $Cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 构建元数据 / 版本检测
$script:metaPath = Join-Path $Root 'builds-meta.json'
function Get-Meta {
    if (-not (Test-Path $script:metaPath)) { return @{} }
    try {
        $raw = Get-Content $script:metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $h = @{}
        foreach ($p in $raw.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return @{} }
}
function Save-Meta($m) { try { $m | ConvertTo-Json -Depth 6 | Set-Content -Path $script:metaPath -Encoding UTF8 } catch { } }
function Get-ProjectInfo([string]$proj) {
    $info = [pscustomobject]@{ Project = $proj; Git = $false; Commit = ''; Branch = ''; Remote = ''; Translator = '' }
    if (Test-Path (Join-Path $proj '.git')) {
        $info.Git = $true
        try { $info.Commit = (& git -C $proj rev-parse --short HEAD 2>$null | Select-Object -First 1) } catch { }
        try { $info.Branch = (& git -C $proj rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1) } catch { }
        try { $info.Remote = (& git -C $proj remote get-url origin 2>$null | Select-Object -First 1) } catch { }
    }
    $lib = Join-Path $proj 'crates\victory-shader\src\lib.rs'
    if (Test-Path $lib) {
        try {
            $m = Select-String -Path $lib -Pattern 'TRANSLATOR_VERSION: u32 = (\d+)' | Select-Object -First 1
            if ($m) { $info.Translator = $m.Matches[0].Groups[1].Value }
        } catch { }
    }
    return $info
}
function Get-CacheState([string]$proj, [datetime]$exeTime, [string]$translator, [string]$cacheDir) {
    $meta = Get-Meta
    $m = $meta[$proj]
    $warmDone = Join-Path $cacheDir 'pipelines\warm-done.txt'
    if (-not $m) {
        # 无启动器记录：看缓存目录里有没有已有的预热结果
        if ((Test-Path $warmDone) -and ((Get-Item $warmDone).Length -gt 0)) {
            $wt = (Get-Item $warmDone).LastWriteTime
            if ($exeTime -gt $wt) {
                return [pscustomobject]@{ State = 'stale'; Text = "⚠ 构建比缓存新（缓存 {0:MM-dd HH:mm}），建议重新「全部预热」" -f $wt }
            }
            return [pscustomobject]@{ State = 'ok'; Text = ("检测到已有管线缓存（{0:MM-dd HH:mm}）" -f $wt) }
        }
        return [pscustomobject]@{ State = 'never'; Text = '从未预热过，首次启动前必须预热' }
    }
    $stale = $false
    if ($m.prewarmTime) { try { if ($exeTime -gt [datetime]$m.prewarmTime) { $stale = $true } } catch { } }
    if ($m.translator -and $translator -and ("$($m.translator)" -ne "$translator")) { $stale = $true }
    if (-not $m.prewarmTime) { $stale = $true }
    if ($stale) { return [pscustomobject]@{ State = 'stale'; Text = '⚠ 构建比上次预热新（或翻译器版本变了），建议重新「全部预热」' } }
    return [pscustomobject]@{ State = 'ok'; Text = "缓存新鲜（上次预热 $($m.prewarmTime)）" }
}

# ---------------------------------------------------------------- 界面
$Bg = [System.Drawing.Color]::FromArgb(24, 20, 40)
$Panel = [System.Drawing.Color]::FromArgb(38, 30, 64)
$Accent = [System.Drawing.Color]::FromArgb(230, 70, 90)
$TextCol = [System.Drawing.Color]::FromArgb(235, 235, 245)
$Muted = [System.Drawing.Color]::FromArgb(150, 150, 175)
$Green = [System.Drawing.Color]::FromArgb(46, 160, 100)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GTA VI PC 移植 - 自动启动器'
$form.Size = New-Object System.Drawing.Size(1120, 900)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Bg
$form.ForeColor = $TextCol
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [int]$size = 9, [System.Drawing.Color]$color = $TextCol) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $size)
    $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}
function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [System.Drawing.Color]$color = $Panel) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.BackColor = $color; $b.ForeColor = $TextCol
    return $b
}
function New-Tb([string]$text, [int]$x, [int]$y, [int]$w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 26)
    $t.BackColor = $Panel; $t.ForeColor = $TextCol; $t.BorderStyle = 'FixedSingle'
    $t.Text = $text
    return $t
}
function New-Radio([string]$text, [int]$x, [int]$y, [int]$w, [bool]$checked, $parent) {
    $r = New-Object System.Windows.Forms.RadioButton
    $r.Text = $text; $r.Location = New-Object System.Drawing.Point($x, $y)
    $r.Size = New-Object System.Drawing.Size($w, 24)
    $r.FlatStyle = 'Flat'; $r.ForeColor = $TextCol; $r.BackColor = $Bg
    $r.Checked = $checked
    $parent.Controls.Add($r)
    return $r
}

# 标题
$lblTitle = New-Label 'GTA VI PC 移植 · 自动启动器' 20 12 500 32 16 $Accent
$form.Controls.Add($lblTitle)
$lblSub = New-Label '自动检测硬件并推荐配置 · 支持自定义目录 · 支持从 GitHub 拉取构建' 20 44 800 22 9 $Muted
$form.Controls.Add($lblSub)

# Tab
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(16, 72)
$tabs.Size = New-Object System.Drawing.Size(1072, 600)
$tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$form.Controls.Add($tabs)
$tabHw = New-Object System.Windows.Forms.TabPage
$tabHw.Text = '① 设备与配置'; $tabHw.BackColor = $Bg
$tabBuild = New-Object System.Windows.Forms.TabPage
$tabBuild.Text = '② 构建与下载'; $tabBuild.BackColor = $Bg
$tabRun = New-Object System.Windows.Forms.TabPage
$tabRun.Text = '③ 预热与启动'; $tabRun.BackColor = $Bg
$tabKeys = New-Object System.Windows.Forms.TabPage
$tabKeys.Text = '⑤ 键盘映射'; $tabKeys.BackColor = $Bg
$tabRace = New-Object System.Windows.Forms.TabPage
$tabRace.Text = '④ 排行榜与推荐'; $tabRace.BackColor = $Bg
$tabs.TabPages.Add($tabHw); $tabs.TabPages.Add($tabBuild); $tabs.TabPages.Add($tabRun); $tabs.TabPages.Add($tabRace); $tabs.TabPages.Add($tabKeys)

# ---------------- Tab1: 设备与配置 ----------------
$tabHw.Controls.Add((New-Label '本机硬件（自动检测）' 14 12 400 22 10))
$txtHw = New-Object System.Windows.Forms.TextBox
$txtHw.Location = New-Object System.Drawing.Point(14, 38)
$txtHw.Size = New-Object System.Drawing.Size(960, 150)
$txtHw.Multiline = $true; $txtHw.ReadOnly = $true; $txtHw.ScrollBars = 'Vertical'
$txtHw.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $txtHw.ForeColor = $TextCol
$txtHw.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabHw.Controls.Add($txtHw)
$tabHw.Controls.Add((New-Label '推荐配置（可手动覆盖）' 14 196 400 22 10))
$txtRec = New-Object System.Windows.Forms.TextBox
$txtRec.Location = New-Object System.Drawing.Point(14, 222)
$txtRec.Size = New-Object System.Drawing.Size(960, 90)
$txtRec.Multiline = $true; $txtRec.ReadOnly = $true
$txtRec.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $txtRec.ForeColor = [System.Drawing.Color]::FromArgb(180, 230, 180)
$txtRec.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabHw.Controls.Add($txtRec)

# 路径区
$tabHw.Controls.Add((New-Label '目录设置' 14 322 200 22 10))
$labels = @('游戏目录', '构建根目录', '缓存根目录', '存档根目录')
$defaults = @($Cfg.GameDir, $Cfg.BuildRoot, $Cfg.CacheRoot, $Cfg.SaveRoot)
$tbPath = @()
$btnBrowse = @()
for ($i = 0; $i -lt 4; $i++) {
    $y = 348 + $i * 34
    $tabHw.Controls.Add((New-Label $labels[$i] 14 $y 90 22))
    $t = New-Tb $defaults[$i] 110 $y 760
    $tabHw.Controls.Add($t); $tbPath += $t
    $b = New-Btn '浏览…' 880 $y 90 26
    $b.Tag = $i
    $tabHw.Controls.Add($b); $btnBrowse += $b
}
$tbGame = $tbPath[0]; $tbBuildRoot = $tbPath[1]; $tbCacheRoot = $tbPath[2]; $tbSaveRoot = $tbPath[3]

# 主机模式 + 分辨率 + 预设
$tabHw.Controls.Add((New-Label '主机模式' 14 494 120 22))
$panelCon = New-Object System.Windows.Forms.Panel
$panelCon.Location = New-Object System.Drawing.Point(110, 490); $panelCon.Size = New-Object System.Drawing.Size(300, 26); $panelCon.BackColor = $Bg
$tabHw.Controls.Add($panelCon)
$rbAutoCon = New-Radio '自动（按显卡推荐）' 0 0 150 $true $panelCon
$rbSS = New-Radio 'Series S（快）' 150 0 70 ($Cfg.Console -eq 'series-s') $panelCon
$rbSX = New-Radio 'Series X（清晰）' 220 0 80 ($Cfg.Console -eq 'series-x') $panelCon

$tabHw.Controls.Add((New-Label '渲染分辨率' 430 494 90 22))
$panelRes = New-Object System.Windows.Forms.Panel
$panelRes.Location = New-Object System.Drawing.Point(520, 490); $panelRes.Size = New-Object System.Drawing.Size(460, 26); $panelRes.BackColor = $Bg
$tabHw.Controls.Add($panelRes)
$rbAutoRes = New-Radio '自动' 0 0 50 $true $panelRes
$heights = @(2160, 1440, 1080, 720, 540, 480)
$rbResMap = @{}
$x = 52
foreach ($hgt in $heights) {
    $r = New-Radio "${hgt}p" $x 0 56 $false $panelRes
    $rbResMap[$hgt] = $r
    $x += 58
}

# ---------------- Tab2: 构建与下载 ----------------
$tabBuild.Controls.Add((New-Label '本地构建（自动扫描构建根目录）' 14 12 500 22 10))
$lstBuilds = New-Object System.Windows.Forms.ListBox
$lstBuilds.Location = New-Object System.Drawing.Point(14, 38)
$lstBuilds.Size = New-Object System.Drawing.Size(960, 150)
$lstBuilds.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $lstBuilds.ForeColor = $TextCol
$lstBuilds.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabBuild.Controls.Add($lstBuilds)
$btnScan = New-Btn '重新扫描本地构建' 14 196 180 30
$tabBuild.Controls.Add($btnScan)
$lblBuildInfo = New-Label '' 210 200 740 22 9 $Muted
$tabBuild.Controls.Add($lblBuildInfo)

$tabBuild.Controls.Add((New-Label '从 GitHub 下载构建' 14 240 300 22 10))
$tabBuild.Controls.Add((New-Label '仓库' 14 268 60 22))
$tbRepo = New-Tb $Cfg.Repo 76 264 300
$tabBuild.Controls.Add($tbRepo)
$tabBuild.Controls.Add((New-Label '分支' 392 268 40 22))
$tbBranch = New-Tb $Cfg.Branch 436 264 180
$tabBuild.Controls.Add($tbBranch)
$tabBuild.Controls.Add((New-Label '下载到' 630 268 60 22))
$dlDefault = $Cfg.BuildRoot
try { $dlDefault = Join-Path $Cfg.BuildRoot 'downloaded' -ErrorAction Stop } catch { $dlDefault = $Cfg.BuildRoot + '\downloaded' }
$tbDlDir = New-Tb $dlDefault 694 264 270
$tabBuild.Controls.Add($tbDlDir)
$btnDlSrc = New-Btn '下载源码 ZIP' 14 300 160 32 $Accent
$btnDlRel = New-Btn '下载 Release' 184 300 140 32
$btnCargo = New-Btn '编译选中的源码构建' 334 300 200 32 $Green
$tabBuild.Controls.Add($btnDlSrc); $tabBuild.Controls.Add($btnDlRel); $tabBuild.Controls.Add($btnCargo)
$lblDl = New-Label '下载/编译会使用系统代理（墙内需要代理）' 544 306 430 22 9 $Muted
$tabBuild.Controls.Add($lblDl)

$tabBuild.Controls.Add((New-Label '说明：源码 ZIP 下载后需要编译才能得到 victory.exe；编译需要 Rust 工具链（rustup/cargo）。' 14 344 960 44 9 $Muted))
$tabBuild.Controls.Add((New-Label '上游更新与回滚（构建需是 git 工程）' 14 390 400 22 10))
$lblVerInfo = New-Label '未检查' 14 416 700 22 9 $Muted
$tabBuild.Controls.Add($lblVerInfo)
$tabBuild.Controls.Add((New-Label '代理' 724 416 40 22))
$tbProxy = New-Tb 'http://127.0.0.1:7890' 764 412 200
$tabBuild.Controls.Add($tbProxy)
$btnCheck = New-Btn '检查上游更新' 14 444 150 32
$btnUpdate = New-Btn '更新并编译' 174 444 140 32 $Accent
$btnRollback = New-Btn '回滚上一版本' 324 444 140 32
$tabBuild.Controls.Add($btnCheck); $tabBuild.Controls.Add($btnUpdate); $tabBuild.Controls.Add($btnRollback)
$lblKnown = New-Label '已知问题：上游 2026-11-26 的 93 提交版本在 8GB NVIDIA 上实测白屏/崩溃，暂不建议更新；更新前启动器会自动备份旧 exe。' 14 484 960 40 9 $Muted
$tabBuild.Controls.Add($lblKnown)

# ---------------- Tab3: 预热与启动 ----------------
$tabRun.Controls.Add((New-Label '预热（首次/更新后执行一次）' 14 12 400 22 10))
$btnWarmShaders = New-Btn '预热着色器' 14 40 160 38
$btnWarmPipes = New-Btn '预编译管线' 184 40 160 38
$btnWarmAll = New-Btn '全部预热' 354 40 160 38 $Accent
$btnStop = New-Btn '停止' 524 40 100 38
$tabRun.Controls.Add($btnWarmShaders); $tabRun.Controls.Add($btnWarmPipes); $tabRun.Controls.Add($btnWarmAll); $tabRun.Controls.Add($btnStop)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(14, 88)
$progress.Size = New-Object System.Drawing.Size(960, 16)
$tabRun.Controls.Add($progress)
$lblStatus = New-Label '就绪' 14 110 960 22 9 $Muted
$tabRun.Controls.Add($lblStatus)

$btnLaunch = New-Btn '启动游戏' 14 142 960 60 $Green
$btnLaunch.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$tabRun.Controls.Add($btnLaunch)
$chkOpenDir = New-Object System.Windows.Forms.CheckBox
$chkOpenDir.Text = '关闭启动器时一并结束游戏'
$chkOpenDir.Location = New-Object System.Drawing.Point(14, 214)
$chkOpenDir.Size = New-Object System.Drawing.Size(300, 24)
$chkOpenDir.ForeColor = $TextCol; $chkOpenDir.BackColor = $Bg; $chkOpenDir.Checked = $true
$tabRun.Controls.Add($chkOpenDir)
$lblCrash = New-Label '崩溃记录：0 次 / 10（满 10 次自动清理日志）' 14 248 720 22 9
$tabRun.Controls.Add($lblCrash)
$btnOpenLogs = New-Btn '打开日志目录' 748 244 226 32
$tabRun.Controls.Add($btnOpenLogs)

# ---------------- Tab4: 排行榜 ----------------
$tabRace.Controls.Add((New-Label 'GTA VI PC Race 排行榜（每次启动自动更新）' 14 12 500 22 10))
$lblRaceUpdated = New-Label '尚未更新' 500 12 470 22 9 $Muted
$tabRace.Controls.Add($lblRaceUpdated)
$lstRace = New-Object System.Windows.Forms.ListBox
$lstRace.Location = New-Object System.Drawing.Point(14, 40)
$lstRace.Size = New-Object System.Drawing.Size(1030, 300)
$lstRace.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $lstRace.ForeColor = $TextCol
$lstRace.Font = New-Object System.Drawing.Font('Consolas', 9)
$lstRace.HorizontalScrollbar = $true
$tabRace.Controls.Add($lstRace)
$btnRaceNow = New-Btn '立即刷新排名' 14 350 150 32
$btnRacePull = New-Btn '拉取选中项目构建' 174 350 180 32 $Green
$lblRaceSrc = New-Label '数据源: vuyp.github.io/gta6-pc-race（启动时自动拉取；双击列表行也可拉取）' 364 356 620 22 9 $Muted
$tabRace.Controls.Add($btnRaceNow); $tabRace.Controls.Add($btnRacePull)
$tabRace.Controls.Add($lblRaceSrc)
$tabRace.Controls.Add((New-Label '为本机推荐（点选/双击可直接拉取对应构建）' 14 388 700 22 10))
$lstRec = New-Object System.Windows.Forms.ListBox
$lstRec.Location = New-Object System.Drawing.Point(14, 414)
$lstRec.Size = New-Object System.Drawing.Size(1030, 84)
$lstRec.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $lstRec.ForeColor = $Green
$lstRec.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$lstRec.HorizontalScrollbar = $true
$tabRace.Controls.Add($lstRec)
$btnRecPull = New-Btn '拉取选中推荐构建' 14 506 190 32 $Green
$btnRecRepo = New-Btn '打开项目仓库' 214 506 160 32
$tabRace.Controls.Add($btnRecPull); $tabRace.Controls.Add($btnRecRepo)
$lblLocalBuilds = New-Label '本地构建在榜情况：等待更新…' 384 510 660 22 9 $Muted
$tabRace.Controls.Add($lblLocalBuilds)

# ---------------- Tab5: 键盘映射 ----------------
$tabKeys.Controls.Add((New-Label '键盘映射（每行一条：源键 = 目标键，例如 CapsLock = Escape）' 14 12 700 22 10))
$txtKeyMap = New-Object System.Windows.Forms.TextBox
$txtKeyMap.Location = New-Object System.Drawing.Point(14, 40)
$txtKeyMap.Size = New-Object System.Drawing.Size(960, 240)
$txtKeyMap.Multiline = $true; $txtKeyMap.ScrollBars = 'Vertical'
$txtKeyMap.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $txtKeyMap.ForeColor = $TextCol
$txtKeyMap.Font = New-Object System.Drawing.Font('Consolas', 10)
$tabKeys.Controls.Add($txtKeyMap)
$tabKeys.Controls.Add((New-Label '可用键名：A-Z 0-9 F1-F12 Space Enter Esc Tab Shift Ctrl Alt CapsLock Backspace Up Down Left Right Home End PgUp PgDn Insert Delete Num0-Num9；也可写 0x41 这样的 VK 值' 14 286 960 22 8.5 $Muted))
$btnKeyStart = New-Btn '启动映射' 14 316 150 36 $Green
$btnKeyStop = New-Btn '停止映射' 174 316 150 36
$btnKeySave = New-Btn '保存映射' 334 316 150 36
$btnKeyTest = New-Btn '测试按键（显示最后捕获的键）' 494 316 280 36
$tabKeys.Controls.Add($btnKeyStart); $tabKeys.Controls.Add($btnKeyStop); $tabKeys.Controls.Add($btnKeySave); $tabKeys.Controls.Add($btnKeyTest)
$lblKeyStatus = New-Label '映射未启动' 14 364 960 22 9 $Muted
$tabKeys.Controls.Add($lblKeyStatus)
$chkKeyAuto = New-Object System.Windows.Forms.CheckBox
$chkKeyAuto.Text = '启动游戏时自动开启映射'
$chkKeyAuto.Location = New-Object System.Drawing.Point(14, 390)
$chkKeyAuto.Size = New-Object System.Drawing.Size(260, 24)
$chkKeyAuto.ForeColor = $TextCol; $chkKeyAuto.BackColor = $Bg; $chkKeyAuto.Checked = $true
$tabKeys.Controls.Add($chkKeyAuto)
$tabKeys.Controls.Add((New-Label '说明：只在游戏窗口聚焦时生效；Ctrl+Alt+M 随时开/关；停止启动器自动卸载。' 14 418 1000 22 9 $Muted))
$txtKeyLast = New-Object System.Windows.Forms.TextBox
$txtKeyLast.Location = New-Object System.Drawing.Point(14, 448)
$txtKeyLast.Size = New-Object System.Drawing.Size(960, 26)
$txtKeyLast.ReadOnly = $true
$txtKeyLast.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28); $txtKeyLast.ForeColor = $TextCol
$txtKeyLast.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabKeys.Controls.Add($txtKeyLast)

# 日志
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(16, 684)
$logBox.Size = New-Object System.Drawing.Size(1072, 180)
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [System.Drawing.Color]::FromArgb(14, 10, 24); $logBox.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 210)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

# ---------------------------------------------------------------- 状态
$script:exe = $null
$script:buildName = ''
$script:cacheDir = ''
$script:dataDir = ''
$script:skipFile = ''
$script:proc = $null
$script:game = $null
$script:warmKind = ''
$script:warmDone = 0
$script:warmTotal = 0
$script:warmSawDone = $false
$script:autoStage = 0
$script:race = $null
$script:raceRec = $null
$script:mapperWanted = $false
$script:raceList = @()
$script:recProjects = @()
$script:logDir = Join-Path $Root 'logs'
$script:gameLog = $null
$script:compile = $null
$script:gameStart = $null
$script:crashFile = Join-Path $script:logDir 'crashes.jsonl'
$script:crashCount = 0
$script:raceCache = Join-Path $Root 'race-cache.json'
$script:outLog = Join-Path $env:TEMP 'gta6-launcher-warm.out.log'
$script:errLog = Join-Path $env:TEMP 'gta6-launcher-warm.err.log'
$script:posOut = 0
$script:posErr = 0
$script:hw = $null
$script:rec = $null

function Add-Log([string]$s) {
    try { $logBox.AppendText(("{0:HH:mm:ss} {1}" -f (Get-Date), $s) + "`r`n"); $logBox.SelectionStart = $logBox.TextLength; $logBox.ScrollToCaret() } catch { }
}

# ---------------------------------------------------------------- 硬件检测
function Detect-Hardware {
    $gpus = @()
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue | Select-Object Name, AdapterRAM, DriverVersion)
    } catch { }
    $cpu = $null; $ram = 0; $os = ''
    try { $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors } catch { }
    try { $cs = Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue; $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } catch { }
    try { $o = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue; $os = "$($o.Caption) build $($o.BuildNumber)" } catch { }

    # NVIDIA 用 nvidia-smi 取准确显存
    $nv = $null
    if (Get-Command nvidia-smi -EA SilentlyContinue) {
        try {
            $q = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null | Select-Object -First 1
            if ($q) { $parts = $q -split ','; $nv = @{ Name = $parts[0].Trim(); VramMB = [int]($parts[1] -replace '[^\d]', ''); Driver = $parts[2].Trim() } }
        } catch { }
    }
    $name = ''; $vendor = ''; $vramMB = 0
    if ($nv) {
        $name = $nv.Name; $vramMB = $nv.VramMB
        if ($name -match 'NVIDIA') { $vendor = 'NVIDIA' }
    } else {
        $best = $gpus | Where-Object { $_.Name -notmatch 'Microsoft Basic|Parsec|Virtual' } | Select-Object -First 1
        if ($best) {
            $name = $best.Name
            if ($best.Name -match 'NVIDIA') { $vendor = 'NVIDIA' }
            elseif ($best.Name -match 'AMD|Radeon') { $vendor = 'AMD' }
            elseif ($best.Name -match 'Intel') { $vendor = 'Intel' }
            else { $vendor = 'Other' }
            try { $vramMB = [int]([math]::Round($best.AdapterRAM / 1MB)) } catch { }
            if ($vramMB -le 0) { $vramMB = 0 }
        }
    }
    if (-not $vendor) { $vendor = 'Unknown' }
    return [pscustomobject]@{
        GpuName = $name; Vendor = $vendor; VramMB = $vramMB
        CpuName = $(if ($cpu) { $cpu.Name.Trim() } else { '未知' })
        CpuCores = $(if ($cpu) { $cpu.NumberOfCores } else { 0 })
        CpuThreads = $(if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 0 })
        RamGB = $ram; OS = $os
        Gpus = $gpus
    }
}

function Recommend($hw) {
    $vramGB = [math]::Round($hw.VramMB / 1024, 1)
    $buildWhy = ''
    $build = 'nvidia'
    if ($hw.Vendor -eq 'NVIDIA') { $build = 'nvidia'; $buildWhy = 'NVIDIA 显卡：用 NVIDIA 分支（wave32 兼容最好）' }
    elseif ($hw.Vendor -eq 'AMD') { $build = 'amd'; $buildWhy = 'AMD 显卡：用上游主线（原生 wave64，无需模拟）' }
    elseif ($hw.Vendor -eq 'Intel') { $build = 'unknown'; $buildWhy = 'Intel 显卡：不支持（需要 RDNA2/NVIDIA 桌面卡）' }
    else { $build = 'unknown'; $buildWhy = '未知显卡：按 NVIDIA 分支尝试' }

    $height = 540
    if ($vramGB -ge 12) { $height = 1080 }
    elseif ($vramGB -ge 10) { $height = 720 }
    elseif ($vramGB -ge 7) { $height = 540 }
    else { $height = 480 }
    if ($hw.Vendor -eq 'AMD' -and $vramGB -ge 12) { $height = 1080 }

    $console = if ($hw.Vendor -eq 'AMD') { 'series-x' } else { 'series-s' }
    $scale = [math]::Round($height / $(if ($console -eq 'series-x') { 2160 } else { 1080 }), 4)
    $preset = if ($vramGB -le 6) { 'low' } elseif ($vramGB -le 9) { 'balanced' } else { 'quality' }

    return [pscustomobject]@{
        Vendor = $hw.Vendor; VramGB = $vramGB; Build = $build; BuildWhy = $buildWhy
        Console = $console; Height = $height; Scale = $scale; Preset = $preset
    }
}

function Refresh-Hw {
    Add-Log '检测硬件…'
    $hw = Detect-Hardware
    $script:hw = $hw
    $lines = @()
    $lines += "显卡: $($hw.GpuName)"
    $lines += "厂商: $($hw.Vendor)    显存: $([math]::Round($hw.VramMB/1024,1)) GB"
    $lines += "CPU : $($hw.CpuName)  ($($hw.CpuCores) 核 / $($hw.CpuThreads) 线程)"
    $lines += "内存: $($hw.RamGB) GB"
    $lines += "系统: $($hw.OS)"
    if ($hw.Gpus.Count -gt 1) { $lines += "其他显示适配器: " + (($hw.Gpus | Select-Object -Skip 1 | ForEach-Object { $_.Name }) -join '; ') }
    $txtHw.Text = $lines -join "`r`n"

    $rec = Recommend $hw
    $script:rec = $rec
    $recLines = @()
    $recLines += "推荐构建: $($rec.Build)（$($rec.BuildWhy)）"
    $recLines += "主机模式: $($rec.Console)    渲染分辨率: $($rec.Height)p（渲染缩放 $($rec.Scale)）"
    $recLines += "画质预设: $($rec.Preset)    显存判断: $($rec.VramGB) GB"
    if ($rec.Build -eq 'unknown') { $recLines += '⚠ 该显卡可能无法运行，仍可尝试' }
    $txtRec.Text = $recLines -join "`r`n"
    Add-Log ("硬件: {0} / {1} / 显存 {2} GB" -f $hw.Vendor, $hw.GpuName, [math]::Round($hw.VramMB / 1024, 1))
}

# ---------------------------------------------------------------- 构建扫描
function Find-VictoryBuilds([string]$root) {
    $found = @()
    if (-not $root -or -not (Test-Path $root)) { return @() }
    # 1) 标准构建：*/target/diag|release/victory.exe
    foreach ($profile in 'diag', 'release') {
        Get-ChildItem $root -Recurse -Depth 6 -Filter 'victory.exe' -EA SilentlyContinue |
            Where-Object { $_.FullName -match "\\target\\$profile\\victory\.exe$" } |
            ForEach-Object {
                $proj = $_.FullName -replace "\\target\\$profile\\victory\.exe$", ''
                $found += [pscustomobject]@{
                    Name = (Split-Path $proj -Leaf); Project = $proj; Exe = $_.FullName
                    Profile = $profile; SizeMB = [math]::Round($_.Length / 1MB, 1); Time = $_.LastWriteTime
                }
            }
    }
    # 2) 预编译/Release 解压版：任意位置的 victory*.exe（排除 deps 和 launcher）
    Get-ChildItem $root -Recurse -Depth 6 -Filter 'victory*.exe' -EA SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\target\\' -and $_.FullName -notmatch '\\deps\\' -and $_.Name -notmatch 'launcher' } |
        ForEach-Object {
            $proj = Split-Path $_.FullName -Parent
            $found += [pscustomobject]@{
                Name = (Split-Path $proj -Leaf); Project = $proj; Exe = $_.FullName
                Profile = 'exe'; SizeMB = [math]::Round($_.Length / 1MB, 1); Time = $_.LastWriteTime
            }
        }
    return @($found | Sort-Object Exe -Unique | Sort-Object @{Expression={ if($_.Profile -in @('diag','release')){0}else{1} }}, Project, Profile)
}

function Scan-Builds {
    $lstBuilds.Items.Clear()
    $root = $tbBuildRoot.Text.Trim()
    $found = @(Find-VictoryBuilds $root)
    if ($found.Count -eq 0) {
        Add-Log ("构建根目录 {0} 没找到构建，自动尝试其它常见目录…" -f $(if ($root) { $root } else { '(空)' }))
        $candidates = @(
            'E:\gta6\work',
            'D:\gta6\work',
            (Join-Path $env:USERPROFILE 'gta6\work'),
            (Join-Path $Root 'work'),
            $Root
        )
        $driveCands = @()
        foreach ($d in @(Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue)) {
            $driveCands += ($d.Name + ':\gta6\work')
            $driveCands += ($d.Name + ':\gta6')
        }
        $candidates = @($candidates + $driveCands) | Where-Object { $_ -and ($_ -ne $root) } | Select-Object -Unique
        foreach ($c in $candidates) {
            if (-not (Test-Path $c)) { continue }
            $tryFound = @(Find-VictoryBuilds $c)
            Add-Log ("  尝试 {0} → {1} 个构建" -f $c, $tryFound.Count)
            if ($tryFound.Count -gt 0) {
                $root = $c; $found = $tryFound
                $tbBuildRoot.Text = $c
                Add-Log ("已自动切换到构建根目录: {0}" -f $c)
                try { $Cfg.BuildRoot = $c } catch { }
                break
            }
        }
    }
    if ($found.Count -eq 0) {
        Add-Log ("没有找到任何 victory.exe。请在「构建根目录」选择含 */target/diag|release/victory.exe 的目录（当前: {0}）" -f $root)
        try { [System.Windows.Forms.MessageBox]::Show(("没有扫描到任何 victory.exe。`r`n`r`n当前构建根目录：{0}`r`n`r`n请点「构建根目录」旁的「浏览…」选择包含以下结构的目录：`r`n  工程名\target\diag\victory.exe`r`n  工程名\target\release\victory.exe" -f $root), '未找到本地构建', 'OK', 'Warning') } catch { }
        return
    }
    foreach ($f in $found) {
        $lstBuilds.Items.Add(('{0}  [{1}]  {2} MB  {3:MM-dd HH:mm}' -f $f.Name, $f.Profile, $f.SizeMB, $f.Time)) | Out-Null
    }
    $script:builds = $found
    Add-Log ("扫描到 {0} 个本地构建" -f $found.Count)
    if ($lstBuilds.Items.Count -gt 0) {
        $pref = 'vf-main'
        if ($script:hw) {
            if ($script:hw.Vendor -eq 'NVIDIA') { $pref = 'vf-nvidia|nvidia' }
            elseif ($script:hw.Vendor -eq 'AMD') { $pref = 'vf-main|upstream|7900' }
        }
        $idx = -1
        for ($i = 0; $i -lt $found.Count; $i++) {
            if ($found[$i].Name -match $pref) { $idx = $i; break }
        }
        if ($idx -lt 0) { $idx = 0 }
        $lstBuilds.SelectedIndex = $idx
        Add-Log ("默认构建: {0}" -f $found[$idx].Name)
    }
}

function Select-Build {
    if ($lstBuilds.SelectedIndex -lt 0 -or -not $script:builds) { return }
    $b = $script:builds[$lstBuilds.SelectedIndex]
    $script:exe = $b.Exe
    $script:buildName = "$($b.Name) [$($b.Profile)]"
    $script:skipFile = Join-Path $b.Project 'scripts\rt_off_hashes.txt'
    # 缓存/存档目录：优先用构建根下的约定目录
    $cacheBase = $tbCacheRoot.Text.Trim()
    $saveBase = $tbSaveRoot.Text.Trim()
    $known = @{
        'vf-nvidia' = @{ Cache = 'cache-nvidia'; Data = 'perf-data' }
        'vf-main'   = @{ Cache = 'cache-upstream'; Data = 'perf-data-up' }
        'cool_fox'  = @{ Cache = 'cache-coolfox'; Data = 'perf-data-cool' }
    }
    if ($known.ContainsKey($b.Name)) {
        $script:cacheDir = Join-Path $cacheBase $known[$b.Name].Cache
        $script:dataDir = Join-Path $saveBase $known[$b.Name].Data
    } else {
        $script:cacheDir = Join-Path $cacheBase ("cache-" + $b.Name)
        $script:dataDir = Join-Path $saveBase ("perf-data-" + $b.Name)
    }
    New-Item -ItemType Directory -Force -Path $script:cacheDir, $script:dataDir -EA SilentlyContinue | Out-Null
    $info = Get-ProjectInfo $b.Project
    $script:projInfo = $info
    $cache = Get-CacheState $b.Project $b.Time $info.Translator $script:cacheDir
    $script:cacheState = $cache
    $ver = if ($info.Git) { "$($info.Branch)@$($info.Commit)" } else { '非 git 工程' }
    $tr = if ($info.Translator) { "翻译器 v$($info.Translator)" } else { '翻译器版本未知' }
    $lblBuildInfo.Text = "已选: $($script:buildName)  |  $ver  |  $tr  |  $($cache.Text)"
    Add-Log ("选中构建: {0} -> {1}" -f $script:buildName, $b.Exe)
    Add-Log ("  版本: {0}  {1}  {2}" -f $ver, $tr, $cache.Text)
}

# ---------------------------------------------------------------- 环境与启动
$script:exeCapCache = @{}
function Test-BuildSupportsRenderScale([string]$exePath) {
    try {
        if (-not $exePath -or -not (Test-Path $exePath)) { return $false }
        if ($script:exeCapCache.ContainsKey($exePath)) { return $script:exeCapCache[$exePath] }
        $bytes = [System.IO.File]::ReadAllBytes($exePath)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $supports = $text.Contains('VICTORY_RENDER_SCALE')
        $script:exeCapCache[$exePath] = $supports
        return $supports
    } catch { return $false }
}

function Build-Env {
    $b = $script:builds[$lstBuilds.SelectedIndex]
    $rec = $script:rec
    $console = if ($rbAutoCon.Checked -and $rec) { $rec.Console } elseif ($rbSX.Checked) { 'series-x' } else { 'series-s' }
    $height = if ($rbAutoRes.Checked -and $rec) { $rec.Height } else { ($heights | Where-Object { $rbResMap[$_].Checked } | Select-Object -First 1) }
    if (-not $height) { $height = $(if ($rec) { $rec.Height } else { 540 }) }
    $out = if ($console -eq 'series-x') { 2160 } else { 1080 }
    $scale = [math]::Round($height / $out, 4)
    if ($scale -lt 0.2) { $scale = 0.2 }
    if ($scale -gt 1.0) { $scale = 1.0 }

    $env:VICTORY_GAME_DIR = $tbGame.Text.Trim()
    $env:VICTORY_CACHE_DIR = $script:cacheDir
    $env:VICTORY_DATA_DIR = $script:dataDir
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
    Remove-Item Env:VICTORY_RESOLUTION,Env:VICTORY_RENDER_SCALE -EA SilentlyContinue
    # 窗口大小：不要盖满屏幕（否则 flip chain 黑屏），所有构建统一 88%
    $env:VICTORY_WINDOW_PERCENT = '88'
    # 按构建能力选择画面缩放方式
    $supportsScale = Test-BuildSupportsRenderScale $b.Exe
    if ($supportsScale) {
        $env:VICTORY_RENDER_SCALE = [string]$scale
        $env:VICTORY_OWN_UPSCALER = '1'
        $env:VICTORY_COMPOSE = '1'
        Add-Log ("构建类型: 新构建（支持 RENDER_SCALE）→ VICTORY_RENDER_SCALE={0}, WINDOW_PERCENT=88" -f $scale)
    } else {
        Remove-Item Env:VICTORY_RENDER_SCALE -EA SilentlyContinue
        $legacyW = [math]::Round($height * 16 / 9 / 2) * 2
        if ($legacyW -lt 320) { $legacyW = 320 }
        $env:VICTORY_RESOLUTION = ("{0}x{1}" -f $legacyW, $height)
        if (-not $env:VICTORY_CARD_BUFFERS_MB) { $env:VICTORY_CARD_BUFFERS_MB = '1024' }
        Add-Log ("构建类型: legacy（不支持 RENDER_SCALE）→ VICTORY_RESOLUTION={0}x{1}, WINDOW_PERCENT=88, CARD_BUFFERS_MB=1024" -f $legacyW, $height)
        Add-Log '提示：legacy 构建建议改用 20261126b 包；若黑屏/白屏请先试这个包'
    }
    try { if (Test-Path $script:skipFile) { $env:VICTORY_SKIP_PIPELINES = (Get-Content $script:skipFile -Raw).Trim() } } catch { }
    return @{ Console = $console; Height = $height; Scale = $scale; Legacy = (-not $supportsScale) }
}

function Start-Warm([string]$kind) {
    try {
        if ($script:proc -and -not $script:proc.HasExited) { Add-Log '预热已在运行'; return }
        if (-not $script:exe) { Add-Log '请先选择构建'; return }
        $rpf = Join-Path $tbGame.Text.Trim() 'shaders.rpf'
        if ($kind -ne 'pipelines' -and -not (Test-Path $rpf)) { Add-Log "找不到 $rpf"; return }
        $null = Build-Env
        Remove-Item $script:outLog, $script:errLog -Force -EA SilentlyContinue
        $script:posOut = 0; $script:posErr = 0; $script:warmDone = 0; $script:warmSawDone = $false
        $script:warmKind = $kind
        $procArgs = if ($kind -eq 'pipelines') { @('warm', '--used') } else { @('shaders', $rpf) }
        $script:warmTotal = if ($kind -eq 'pipelines') { 2400 } else { 26000 }
        $lblStatus.Text = if ($kind -eq 'pipelines') { '正在预编译管线…' } else { '正在预翻译着色器…' }
        $script:proc = Start-Process -FilePath $script:exe -ArgumentList $procArgs -WorkingDirectory (Split-Path $script:exe) `
            -RedirectStandardOutput $script:outLog -RedirectStandardError $script:errLog -PassThru -WindowStyle Hidden
        Add-Log ("预热[{0}] PID={1}" -f $kind, $script:proc.Id)
        $btnWarmAll.Enabled = $false; $btnWarmShaders.Enabled = $false; $btnWarmPipes.Enabled = $false
        $btnStop.Enabled = $true; $btnLaunch.Enabled = $false
        $progress.Value = 0
    } catch {
        Add-Log ("预热失败: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '预热失败')
    }
}

function Read-Log([string]$path, [ref]$pos) {
    try {
        if (-not (Test-Path $path)) { return @() }
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $pos.Value) { $pos.Value = 0 }
            $fs.Position = $pos.Value
            $sr = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd(); $pos.Value = $fs.Position; $sr.Dispose()
        } finally { $fs.Dispose() }
        if ($text) { return $text -split "`r?`n" | Where-Object { $_ -ne '' } }
        return @()
    } catch { return @() }
}

function Update-Warm {
    if (-not $script:proc) { return }
    $lines = @()
    $lines += Read-Log $script:outLog ([ref]$script:posOut)
    $lines += Read-Log $script:errLog ([ref]$script:posErr)
    foreach ($line in $lines) {
        Add-Log $line
        if ($line -match '(\d+)\s+of\s+(\d+),\s+(\d+)\s*s') { $script:warmDone = [int]$matches[1]; $script:warmTotal = [int]$matches[2] }
        elseif ($line -match '(\d+)\s+shaders in the cache') { $script:warmDone = [int]$matches[1]; if ($script:warmTotal -lt $script:warmDone) { $script:warmTotal = $script:warmDone } }
        if ($line -match 'shaders in the cache|file scan complete|made in \d+') { $script:warmSawDone = $true }
    }
    if ($script:warmTotal -gt 0) {
        $v = [int](100 * $script:warmDone / $script:warmTotal); if ($v -gt 100) { $v = 100 }
        if ($v -ne $progress.Value) { $progress.Value = $v; $lblStatus.Text = ('预热中 {0}%' -f $v) }
    }
    if ($script:proc.HasExited) {
        try { $null = $script:proc.WaitForExit(2000); $code = $script:proc.ExitCode } catch { $code = $null }
        $script:proc = $null
        try {
            $tail = @()
            $tail += Read-Log $script:outLog ([ref]$script:posOut)
            $tail += Read-Log $script:errLog ([ref]$script:posErr)
            foreach ($l in $tail) { Add-Log $l; if ($l -match 'shaders in the cache|file scan complete|made in \d+') { $script:warmSawDone = $true } }
        } catch { }
        $ok = ($null -eq $code) -or ("$code" -eq '') -or ($code -eq 0) -or $script:warmSawDone -or ($script:warmDone -gt 0)
        Add-Log ("预热结束（退出码 {0}）" -f $(if ("$code" -eq '') { '未知' } else { $code }))
        if ($script:warmKind -eq 'all' -and $ok -and $script:autoStage -eq 0) {
            $script:autoStage = 1
            Start-Warm 'pipelines'
            return
        }
        $script:autoStage = 0
        $progress.Value = 100
        $btnWarmAll.Enabled = $true; $btnWarmShaders.Enabled = $true; $btnWarmPipes.Enabled = $true
        $btnStop.Enabled = $false; $btnLaunch.Enabled = $true
        $lblStatus.Text = '预热完成'
        try {
            if ($script:builds -and $lstBuilds.SelectedIndex -ge 0) {
                $bb = $script:builds[$lstBuilds.SelectedIndex]
                $mm = Get-Meta
                $mm[$bb.Project] = [pscustomobject]@{
                    commit = $script:projInfo.Commit; branch = $script:projInfo.Branch
                    translator = $script:projInfo.Translator
                    exeTime = $bb.Time.ToString('o'); prewarmTime = (Get-Date).ToString('o')
                }
                Save-Meta $mm
                Add-Log '已记录预热时间戳'
            }
        } catch { }
    }
}

function Stop-Warm {
    try { if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill($true); Add-Log '已停止预热' } } catch { }
    $script:proc = $null; $script:autoStage = 0
    $btnWarmAll.Enabled = $true; $btnWarmShaders.Enabled = $true; $btnWarmPipes.Enabled = $true
    $btnStop.Enabled = $false; $btnLaunch.Enabled = $true
    $lblStatus.Text = '已停止'
}

function Launch-Game {
    try {
        if (-not $script:exe) { Add-Log '请先选择构建'; return }
        $already = @(Get-Process victory -EA SilentlyContinue)
        if ($already.Count -gt 0) {
            $pids = ($already | ForEach-Object { $_.Id }) -join ', '
            Add-Log ("检测到已有 victory 进程（PID: {0}），拒绝重复启动（否则会因文件锁报 0x80070005）" -f $pids)
            [System.Windows.Forms.MessageBox]::Show(("已经有游戏/预热进程在运行（PID: {0}）。`r`n`r`n请先关闭游戏窗口或结束这些进程，否则会报 0x80070005（拒绝访问）。" -f $pids), '已有实例在运行')
            return
        }
        if ($script:cacheState -and $script:cacheState.State -ne 'ok') {
            $r = [System.Windows.Forms.MessageBox]::Show("$($script:cacheState.Text)`r`n`r`n仍然启动吗？（建议先「全部预热」）", '缓存可能过期', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        $envInfo = Build-Env
        $gameExe = Join-Path $tbGame.Text.Trim() 'game_scarlett_master.exe'
        if (-not (Test-Path $gameExe)) { Add-Log "找不到游戏: $gameExe"; return }
        Save-Cfg
        Add-Log ("启动: {0} / {1} / {2}p (scale {3})" -f $script:buildName, $envInfo.Console, $envInfo.Height, $envInfo.Scale)
        Add-Log ("缓存: {0}" -f $script:cacheDir)
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        $script:gameLog = Join-Path $script:logDir ("game-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
        $script:gameStart = Get-Date
        $script:game = Start-Process -FilePath $script:exe -ArgumentList @('run', $gameExe, '--execute', '--console', $envInfo.Console) `
            -WorkingDirectory (Split-Path $script:exe) -PassThru `
            -RedirectStandardOutput $script:gameLog -RedirectStandardError ($script:gameLog + '.err')
        Add-Log ("游戏日志: {0}" -f $script:gameLog)
        Add-Log ("游戏已启动 PID={0}" -f $script:game.Id)
        if ($chkKeyAuto.Checked) {
            Start-Sleep -Milliseconds 800
            Start-Mapper
            Add-Log '已按设置自动开启键盘映射'
        }
        $lblStatus.Text = '游戏运行中…'
        $btnLaunch.Enabled = $false
    } catch {
        Add-Log ("启动失败: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败')
    }
}

# ---------------------------------------------------------------- GitHub 下载
function Download-FromGitHub([string]$repo, [string]$branch, [string]$destDir, [switch]$Release) {
    try {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        $url = ''
        $file = ''
        if ($Release) {
            $api = "https://api.github.com/repos/$repo/releases/latest"
            $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'gta6-launcher' } -TimeoutSec 30
            $asset = $rel.assets | Where-Object { $_.name -match '(?i)windows|win64|x64' } | Select-Object -First 1
            if (-not $asset) { $asset = $rel.assets | Select-Object -First 1 }
            if (-not $asset) { Add-Log '该仓库没有 Release 附件，请改下载源码'; return }
            $url = $asset.browser_download_url; $file = Join-Path $destDir $asset.name
            Add-Log ("下载 Release: {0}" -f $asset.name)
        } else {
            $url = "https://codeload.github.com/$repo/zip/refs/heads/$branch"
            $file = Join-Path $destDir ("$($repo -replace '/', '_')-$branch.zip")
            Add-Log ("下载源码: {0} @ {1}" -f $repo, $branch)
        }
        $lblStatus.Text = '正在下载…'
        Invoke-WebRequest -Uri $url -OutFile $file -TimeoutSec 600 -UseBasicParsing
        $size = [math]::Round((Get-Item $file).Length / 1MB, 1)
        Add-Log ("下载完成: {0} ({1} MB)" -f $file, $size)
        if (-not $Release) {
            $extract = Join-Path $destDir ([System.IO.Path]::GetFileNameWithoutExtension($file))
            if (Test-Path $extract) { Remove-Item $extract -Recurse -Force -EA SilentlyContinue }
            Expand-Archive -Path $file -DestinationPath $extract -Force
            Add-Log ("已解压到: {0}" -f $extract)
        }
        $lblStatus.Text = '下载完成'
        Scan-Builds
    } catch {
        Add-Log ("下载失败: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '下载失败')
    }
}

function Set-CompileButtons([bool]$enabled) {
    try {
        foreach ($btn in @($btnCargo, $btnLaunch)) { if ($btn) { $btn.Enabled = $enabled } }
    } catch { }
}

function Start-CompileAsync([string]$cargoRoot, [string]$labelName) {
    try {
        if (-not (Get-Command cargo -EA SilentlyContinue)) { Add-Log '找不到 cargo，请先安装 Rust 工具链'; return $false }
        if ($script:compile -and $script:compile.Proc -and -not $script:compile.Proc.HasExited) { Add-Log '已有编译在运行，请等它结束'; return $false }
        $logOut = Join-Path $env:TEMP ("gta6-compile-out-" + (Get-Date -Format 'HHmmss') + '.log')
        $logErr = Join-Path $env:TEMP ("gta6-compile-err-" + (Get-Date -Format 'HHmmss') + '.log')
        Remove-Item $logOut,$logErr -EA SilentlyContinue
        $script:compile = [pscustomobject]@{
            Root = $cargoRoot; Label = $labelName; LogOut = $logOut; LogErr = $logErr
            Attempts = @(@('build','--profile','diag','-p','victory','--features','diagnostics'), @('build','--release'))
            Idx = 0; Start = Get-Date; Proc = $null; Done = $false; Ok = $false; LastShown = 0
        }
        $c = $script:compile
        Add-Log ("开始编译: {0}（后台进行，界面不会卡）" -f $labelName)
        $a = $c.Attempts[0]
        $c.Proc = Start-Process -FilePath 'cargo' -ArgumentList $a -WorkingDirectory $c.Root `
            -RedirectStandardOutput $c.LogOut -RedirectStandardError $c.LogErr -PassThru -WindowStyle Hidden
        $lblStatus.Text = '编译中…（界面可正常操作）'
        try { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30 } catch { }
        Set-CompileButtons $false
        return $true
    } catch { Add-Log ("编译启动失败: " + $_.Exception.Message); return $false }
}

function Stop-Compile {
    try {
        if ($script:compile -and $script:compile.Proc -and -not $script:compile.Proc.HasExited) {
            $script:compile.Proc.Kill($true)
            Add-Log '已取消编译'
        }
        $script:compile = $null
        try { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0 } catch { }
        Set-CompileButtons $true
        $lblStatus.Text = '编译已取消'
    } catch { }
}

function Get-CompileTail([string]$path, [int]$n) {
    try { if ($path -and (Test-Path $path)) { return @(Get-Content $path -Tail $n -EA SilentlyContinue) } } catch { }
    return @()
}

function Finish-CompileAttempt([bool]$ok) {
    $c = $script:compile
    if (-not $c) { return }
    if ($ok) {
        $built = @(Get-ChildItem $c.Root -Recurse -Depth 6 -File -Filter 'victory*.exe' -EA SilentlyContinue |
            Where-Object { $_.FullName -match '\\target\\(diag|release)\\victory\.exe$' } | Sort-Object LastWriteTime -Descending)
        if ($built.Count -gt 0) {
            $exe = $built[0]
            Add-Log ("编译成功: {0} ({1:N1} MB)" -f $exe.FullName, ($exe.Length / 1MB))
            # 部署到规范目录
            try {
                $dest = $tbDlDir.Text.Trim()
                $name = ($c.Label -replace '[/:.]', '_')
                $dst = Join-Path $dest (Join-Path $name 'target\release')
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                Copy-Item $exe.FullName (Join-Path $dst 'victory.exe') -Force
                Add-Log ("已部署: {0}" -f (Join-Path $dst 'victory.exe'))
            } catch { Add-Log ("部署失败: " + $_.Exception.Message) }
            $c.Ok = $true; $c.Done = $true
            Scan-Builds
            $lblStatus.Text = ('编译完成: ' + $c.Label)
            try { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0 } catch { }
            Set-CompileButtons $true
            return
        }
    }
    # 失败或没产物 → 尝试下一个方案
    if ($c.Idx + 1 -lt $c.Attempts.Count) {
        $c.Idx++
        $a = $c.Attempts[$c.Idx]
        Add-Log ("上一方案失败，改用: cargo {0}" -f ($a -join ' '))
        try {
            $c.Proc = Start-Process -FilePath 'cargo' -ArgumentList $a -WorkingDirectory $c.Root `
                -RedirectStandardOutput $c.LogOut -RedirectStandardError $c.LogErr -PassThru -WindowStyle Hidden
            return
        } catch { Add-Log ("启动编译失败: " + $_.Exception.Message) }
    }
    $tail = @(Get-CompileTail $c.LogErr 12) + @(Get-CompileTail $c.LogOut 8)
    foreach ($l in ($tail | Where-Object { $_ } | Select-Object -Last 12)) { Add-Log ('  │ ' + $l) }
    Add-Log ("编译失败（日志: {0} / {1}）" -f $c.LogOut, $c.LogErr)
    $c.Done = $true; $c.Ok = $false
    $lblStatus.Text = '编译失败（见日志）'
    try { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0 } catch { }
    Set-CompileButtons $true
}

function Update-Compile {
    $c = $script:compile
    if (-not $c -or $c.Done) { return }
    try {
        $elapsed = [int]((Get-Date) - $c.Start).TotalSeconds
        if ($env:GTA6_LAUNCHER_TRACE) { Add-Content -Path $env:GTA6_LAUNCHER_TRACE -Value ((Get-Date).ToString('HH:mm:ss') + ' tick elapsed=' + $elapsed) -Encoding UTF8 }
        $lastLine = (@(Get-CompileTail $c.LogOut 1) + @(Get-CompileTail $c.LogErr 1) | Where-Object { $_ } | Select-Object -Last 1)
        $lblStatus.Text = ("编译中… {0:00}:{1:00} | {2}" -f [math]::Floor($elapsed/60), ($elapsed % 60), $(if ($lastLine) { $lastLine.Trim() } else { '准备中' }))
        if (($elapsed - $c.LastShown) -ge 3 -and $lastLine) {
            $c.LastShown = $elapsed
            Add-Log ('  │ ' + $lastLine.Trim())
        }
        if ($c.Proc -and $c.Proc.HasExited) {
            $code = $null
            try { if ("$($c.Proc.ExitCode)" -ne '') { $code = $c.Proc.ExitCode } } catch { }
            Add-Log ("编译进程退出（退出码 {0}）" -f $(if ($null -eq $code) { '未知' } else { $code }))
            Finish-CompileAttempt ($null -eq $code -or $code -eq 0)
        }
    } catch { }
}

function Compile-Selected {
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先在「② 构建与下载」选中一个构建'; return }
        $b = $script:builds[$lstBuilds.SelectedIndex]
        $cargoRoot = $b.Project
        if (-not (Test-Path (Join-Path $cargoRoot 'Cargo.toml'))) { Add-Log '该构建目录没有 Cargo.toml（不是源码工程）'; return }
        [void](Start-CompileAsync $cargoRoot $b.Name)
    } catch { Add-Log ("编译失败: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 上游更新
function Check-Update {
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先选中一个构建'; return }
        $b = $script:builds[$lstBuilds.SelectedIndex]
        $info = Get-ProjectInfo $b.Project
        $script:projInfo = $info
        $proxy = $tbProxy.Text.Trim()
        if ($info.Git) {
            $gp = if ($proxy) { @('-c', "http.proxy=$proxy", '-c', "https.proxy=$proxy") } else { @() }
            Add-Log ("检查上游: {0} 分支 {1}" -f $info.Remote, $info.Branch)
            $null = & git -C $b.Project @gp fetch origin 2>&1 | Select-Object -Last 2 | ForEach-Object { if ($_) { Add-Log ("  git: " + $_) } }
            $behind = & git -C $b.Project rev-list --count "HEAD..origin/$($info.Branch)" 2>$null
            $head = & git -C $b.Project log -1 --format='%h %s' "origin/$($info.Branch)" 2>$null
            if ("$behind" -match '^\d+$') {
                if ([int]$behind -gt 0) {
                    $lblVerInfo.Text = "落后上游 $behind 个提交 | 上游最新: $head"
                    Add-Log ("有更新：落后 {0} 个提交，上游最新 {1}" -f $behind, $head)
                } else {
                    $lblVerInfo.Text = '已是最新'
                    Add-Log '已是最新'
                }
            } else { Add-Log '无法比较（分支或远端缺失）' }
        } else {
            $repo = $tbRepo.Text.Trim(); $branch = $tbBranch.Text.Trim()
            $c = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$branch" -Headers @{ 'User-Agent' = 'gta6-launcher' } -TimeoutSec 20
            $msg = ($c.commit.message -split "`n")[0]
            $lblVerInfo.Text = ("上游最新: {0} {1}" -f $c.sha.Substring(0, 7), $msg)
            Add-Log ("上游最新: {0} {1}" -f $c.sha.Substring(0, 7), $msg)
        }
    } catch { Add-Log ("检查更新失败: " + $_.Exception.Message); $lblVerInfo.Text = '检查失败' }
}

function Update-Build {
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先选中一个构建'; return }
        $b = $script:builds[$lstBuilds.SelectedIndex]
        $info = Get-ProjectInfo $b.Project
        if (-not $info.Git) { Add-Log '该构建不是 git 工程：请用「下载源码 ZIP」重新获取'; return }
        $r = [System.Windows.Forms.MessageBox]::Show("将更新 $($b.Name) 并重新编译。`r`n更新前会自动备份当前 exe。`r`n`r`n继续吗？", '更新构建', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $bak = "$($b.Exe).bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $b.Exe $bak -Force
        Add-Log ("已备份 exe: {0}" -f (Split-Path $bak -Leaf))
        $proxy = $tbProxy.Text.Trim()
        $gp = if ($proxy) { @('-c', "http.proxy=$proxy", '-c', "https.proxy=$proxy") } else { @() }
        $null = & git -C $b.Project @gp pull --ff-only 2>&1 | Select-Object -Last 3 | ForEach-Object { if ($_) { Add-Log ("  git: " + $_) } }
        $mm = Get-Meta
        if ($mm[$b.Project]) { $mm[$b.Project].prewarmTime = ''; Save-Meta $mm }
        Add-Log '源码已更新，开始编译…'
        Compile-Selected
        $lblVerInfo.Text = '更新+编译完成 → 需要重新「全部预热」'
        Add-Log '更新完成：请重新执行「全部预热」'
    } catch { Add-Log ("更新失败: " + $_.Exception.Message) }
}

function Rollback-Build {
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先选中一个构建'; return }
        $b = $script:builds[$lstBuilds.SelectedIndex]
        $baks = @(Get-ChildItem ("$($b.Exe).bak-*") -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($baks.Count -eq 0) { Add-Log '没有可回滚的备份'; return }
        Copy-Item $baks[0].FullName $b.Exe -Force
        Add-Log ("已回滚到 {0}（{1:MM-dd HH:mm}）" -f $baks[0].Name, $baks[0].LastWriteTime)
        $lblVerInfo.Text = "已回滚到 $($baks[0].Name)"
        Scan-Builds
    } catch { Add-Log ("回滚失败: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 排行榜（GTA VI PC Race）
function LaneStep($lane) {
    if ($null -eq $lane) { return 0.0 }
    try {
        if ($lane.PSObject.Properties['step']) { return [double]$lane.step }
    } catch { }
    try { return [double]$lane } catch { return 0.0 }
}

function SpeedStep($lane) {
    if ($null -eq $lane) { return -1.0 }
    try { if ($lane.PSObject.Properties['step'] -and $null -ne $lane.step) { return [double]$lane.step } } catch { }
    $v = -1.0
    # 保守：优先用最低 fps（最差场景）
    try { if ($lane.PSObject.Properties['low'] -and $null -ne $lane.low) { $v = [double]$lane.low } } catch { }
    if ($v -lt 0) { try { if ($lane.PSObject.Properties['high'] -and $null -ne $lane.high) { $v = [double]$lane.high } } catch { } }
    if ($v -le 0) { return -1.0 }
    if ($v -lt 2) { return 1.0 } elseif ($v -lt 5) { return 2.0 } elseif ($v -lt 10) { return 3.0 }
    elseif ($v -lt 20) { return 4.0 } elseif ($v -lt 30) { return 5.0 } else { return 6.0 }
}
function StabilityStep($lane) {
    if ($null -eq $lane) { return -1.0 }
    try { if ($lane.PSObject.Properties['step'] -and $null -ne $lane.step) { return [double]$lane.step } } catch { }
    $m = -1.0
    try { if ($lane.PSObject.Properties['minutes'] -and $null -ne $lane.minutes) { $m = [double]$lane.minutes } } catch { }
    if ($m -le 0) { return -1.0 }
    if ($m -lt 10) { return 1.0 } elseif ($m -lt 30) { return 2.0 } elseif ($m -lt 60) { return 3.0 } else { return 4.0 }
}
$script:badBuilds = @{ 'cool_fox' = '白屏（已知问题，不建议）' }
function Get-RepoCandidates([string]$proj) {
    $ordered = @()
    # 先放当前分支跟踪的远端（worktree 的 upstream 才是真实上游）
    try {
        $u = & git -C $proj rev-parse --abbrev-ref '@{u}' 2>$null | Select-Object -First 1
        if ($u -match '^([^/]+)/') {
            $remoteName = $matches[1]
            $url = & git -C $proj remote get-url $remoteName 2>$null | Select-Object -First 1
            if ($url -and ($url -match 'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?$')) { $ordered += $matches[1] }
        }
    } catch { }
    try {
        $raw = & git -C $proj remote -v 2>$null
        foreach ($line in @($raw)) {
            if ($line -match 'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?\s') { $ordered += $matches[1] }
            elseif ($line -match 'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?$') { $ordered += $matches[1] }
        }
    } catch { }
    return @($ordered | Select-Object -Unique)
}

function Get-RaceRecommendation($data) {
    $hw = $script:hw
    if (-not $hw) { return @() }
    $userGB = 0
    try { $userGB = [math]::Round($hw.VramMB / 1024, 0) } catch { }
    # 预先构建 本地仓库 -> 构建名 映射（每个工程只跑一次 git，避免打分时数千次进程调用）
    $localMap = @{}
    foreach ($b in @($script:builds)) {
        try {
            foreach ($c in @(Get-RepoCandidates $b.Project)) {
                if ($c) { $k = $c.ToLower(); if (-not $localMap.ContainsKey($k)) { $localMap[$k] = $b.Name } }
            }
        } catch { }
    }
    $scored = @()
    foreach ($p in @($data.projects | Where-Object { $_.repo -and $_.stage -ge 6 })) {
        $gpuList = @($p.tested.gpu)
        $gpuText = ($gpuList -join ' ')
        $text = ("$($p.status) $($p.kind) $($p.basis) $gpuText")

        $vendorScore = 0.5
        $vendorNote = '厂商未注明'
        if ($gpuList.Count -gt 0) {
            $hasUser = $false; $hasOther = $false
            foreach ($g in $gpuList) {
                $gs = "$g"
                if ($hw.Vendor -eq 'NVIDIA' -and $gs -match 'NVIDIA|RTX|GTX') { $hasUser = $true }
                elseif ($hw.Vendor -eq 'AMD' -and $gs -match 'AMD|Radeon') { $hasUser = $true }
                elseif ($gs -match 'NVIDIA|AMD|RTX|GTX|Radeon') { $hasOther = $true }
            }
            if ($hasUser) { $vendorScore = 1.0; $vendorNote = '厂商匹配' }
            elseif ($hasOther) { $vendorScore = 0.0; $vendorNote = '只在另一家显卡上测试' }
        }

        $vramNums = @()
        foreach ($pat in 'with\s+(\d+)\s*GB', '(\d+)\s*GB\s*(?:card|VRAM|version|model|variant)', 'RTX\s*\d{4}\s*(?:Ti|SUPER)?\s*[^\d]{0,6}?(\d+)\s*GB', 'RX\s*\d{4}\s*(?:XT|XTX)?\s*[^\d]{0,6}?(\d+)\s*GB') {
            foreach ($m0 in [regex]::Matches($text, $pat, 'IgnoreCase')) { $vramNums += [int]$m0.Groups[1].Value }
        }
        $vramNums = @($vramNums | Where-Object { $_ -ge 4 -and $_ -le 32 } | Sort-Object -Unique)
        $vramClose = 0.5
        $vramNote = '显存未注明'
        if ($vramNums.Count -gt 0 -and $userGB -gt 0) {
            $minDiff = ($vramNums | ForEach-Object { [math]::Abs($_ - $userGB) } | Measure-Object -Minimum).Minimum
            $vramClose = [math]::Max(0.0, 1.0 - $minDiff / 8.0)
            $vramNote = ("测试显存 {0}GB" -f ($vramNums -join '/'))
        }

        $lowVramBonus = 0.0
        if ($userGB -gt 0 -and $userGB -le 10 -and $text -match '(?i)\b8\s*GB\b') { $lowVramBonus = 0.3 }

        $sp = SpeedStep $p.lanes.speed
        $st = StabilityStep $p.lanes.stability
        $pc = LaneStep $p.lanes.picture
        $spScore = 0.5; if ($sp -ge 0) { $spScore = $sp / 6.0 }
        $stScore = 0.5; if ($st -ge 0) { $stScore = $st / 4.0 }
        $pcScore = 0.5; if ($pc -ge 0) { $pcScore = $pc / 5.0 }

        $rankBonus = 0.2 * [math]::Max(0.0, (50.0 - [double]$p.pos) / 48.0)
        $localBuild = ''
        if ($p.repo -and $localMap.ContainsKey($p.repo.ToLower())) { $localBuild = $localMap[$p.repo.ToLower()] }
        $localBonus = 0.0
        if ($localBuild) { $localBonus = 0.4 }

        $score = 4.0 * $vendorScore + 2.0 * $vramClose + 1.5 * $spScore + 1.0 * $stScore + 1.0 * $pcScore + $rankBonus + $lowVramBonus + $localBonus

        $reasons = @()
        if ($vendorScore -eq 1.0) { $reasons += '厂商匹配' } elseif ($vendorScore -eq 0.0) { $reasons += '只在另一家测试' }
        if ($vramClose -ge 0.75) { $reasons += '显存接近' } elseif ($vramClose -le 0.2 -and $vramNums.Count -gt 0) { $reasons += '测试显存偏大' }
        if ($sp -ge 5) { $reasons += '速度快' } elseif ($sp -lt 0) { $reasons += '速度未测' }
        if ($st -lt 0) { $reasons += '稳定性未测' }
        if ($lowVramBonus -gt 0) { $reasons += '8GB实测' }
        if ($localBuild) { $reasons += ('本地已有:' + $localBuild) }

        $scored += [pscustomobject]@{
            Project = $p; Score = [math]::Round($score, 2)
            VendorMatch = $vendorScore; VramClose = $vramClose
            VramNote = $vramNote; Reasons = $reasons
        }
    }
    return @($scored | Sort-Object Score -Descending)
}
if ($env:GTA6_LAUNCHER_ALGO_TEST) {
    try {
        $dataPath = $env:GTA6_LAUNCHER_ALGO_DATA
        if (-not $dataPath -or -not (Test-Path $dataPath)) {
            foreach ($cand in @((Join-Path $Root 'race-cache.json'), 'E:\gta6\work\race-data.json')) {
                if (Test-Path $cand) { $dataPath = $cand; break }
            }
        }
        $data = Get-Content $dataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:builds = @()
        if (-not (Get-Command Find-LocalBuildForRepo -EA SilentlyContinue)) { function Find-LocalBuildForRepo([string]$repo) { return '' } }
        $out = @()
        foreach ($cfg in @(
            @{ Name = 'NVIDIA 8GB'; Vendor = 'NVIDIA'; VramMB = 8192 },
            @{ Name = 'NVIDIA 16GB'; Vendor = 'NVIDIA'; VramMB = 16384 },
            @{ Name = 'AMD 16GB'; Vendor = 'AMD'; VramMB = 16384 }
        )) {
            $script:hw = [pscustomobject]@{ Vendor = $cfg.Vendor; VramMB = $cfg.VramMB; GpuName = 'test'; RamGB = 32 }
            $r = @(Get-RaceRecommendation $data)
            $out += ("=== {0} ===" -f $cfg.Name)
            $n = 0
            foreach ($s in $r) {
                $n++
                if ($n -gt 8) { break }
                $out += ("{0,2}. {1,-22} score={2,-5} vendor={3} vram={4} reasons={5}" -f $n, $s.Project.name, $s.Score, $s.VendorMatch, $s.VramClose, (@($s.Reasons) -join ','))
            }
            # 检查 AMD-only 项目是否被正确压低
            $amdOnly = @($r | Where-Object { $_.VendorMatch -eq 0.0 } | Select-Object -First 3)
            $out += ("AMD-only 项目最低分检查: " + (($amdOnly | ForEach-Object { $_.Project.name + '(' + $_.Score + ')' }) -join ', '))
        }
        Set-Content -Path $env:GTA6_LAUNCHER_ALGO_TEST -Value ($out -join "`r`n") -Encoding UTF8
    } catch { Set-Content -Path $env:GTA6_LAUNCHER_ALGO_TEST -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
    exit
}

function Find-LocalBuildForRepo([string]$repo) {
    if (-not $repo) { return '' }
    foreach ($b in @($script:builds)) {
        try {
            foreach ($r in (Get-RepoCandidates $b.Project)) {
                if ($r -ieq $repo) { return $b.Name }
            }
        } catch { }
    }
    return ''
}

function Update-Race {
    try {
        $url = $Cfg.RaceUrl
        if (-not $url) { $url = 'https://vuyp.github.io/gta6-pc-race/src/data.json' }
        $tmp = Join-Path $env:TEMP 'gta6-race.json'
        $fetched = $false
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 40
            Copy-Item $tmp $script:raceCache -Force
            $fetched = $true
            Add-Log '排行榜已更新'
        } catch {
            Add-Log ("排行榜下载失败: " + $_.Exception.Message)
            if (Test-Path $script:raceCache) { Add-Log '使用本地缓存排行' } else { $lblRaceUpdated.Text = '排行榜获取失败（无缓存）'; return }
        }
        $data = Get-Content $script:raceCache -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:race = $data
        $rows = @()
        $rows += ("已检查: {0}    领跑: {1}" -f $data.checked, $data.projects[0].name)
        $rows += ''
        foreach ($p in @($data.projects | Sort-Object pos | Select-Object -First 25)) {
            $repo = if ($p.repo) { $p.repo } else { '(无公开代码)' }
            $rows += ("{0,2}. {1,-24} st{2}  画面{3}/5 速度{4}/6 稳定{5}/4  {6}" -f $p.pos, $p.name, $p.stage, (LaneStep $p.lanes.picture), (SpeedStep $p.lanes.speed), (StabilityStep $p.lanes.stability), $repo)
        }
        if ($data.watching -and @($data.watching).Count -gt 0) {
            $rows += ''
            $rows += '--- 关注中（尚无阶段）---'
            foreach ($w in @($data.watching | Select-Object -First 8)) { $rows += ("    {0}  {1}" -f $w.name, $w.repo) }
        }
        $lstRace.Items.Clear()
        $script:raceList = @()
$script:recProjects = @()
        foreach ($p in @($data.projects | Sort-Object pos | Select-Object -First 25)) {
            $repoTxt = if ($p.repo) { $p.repo } else { '(无公开代码)' }
            $lstRace.Items.Add(("{0,2}. {1,-22} st{2}  画面{3}/5 速度{4}/6 稳定{5}/4   {6}" -f $p.pos, $p.name, $p.stage, (LaneStep $p.lanes.picture), (SpeedStep $p.lanes.speed), (StabilityStep $p.lanes.stability), $repoTxt)) | Out-Null
            $script:raceList += $p
        }
        $lblRaceUpdated.Text = ("数据时间: {0}（每启动更新；双击行拉取构建）" -f $data.checked)
        if ($env:GTA6_LAUNCHER_TRACE) { Add-Content -Path $env:GTA6_LAUNCHER_TRACE -Value ((Get-Date).ToString('HH:mm:ss') + ' list filled') -Encoding UTF8 }

        try { $scored = Get-RaceRecommendation $data } catch { if ($env:GTA6_LAUNCHER_TRACE) { Add-Content -Path $env:GTA6_LAUNCHER_TRACE -Value ("REC ERROR: " + $_.Exception.Message) -Encoding UTF8 }; Add-Log ("推荐计算失败: " + $_.Exception.Message); $scored = @() }
        if ($env:GTA6_LAUNCHER_TRACE) { Add-Content -Path $env:GTA6_LAUNCHER_TRACE -Value ((Get-Date).ToString('HH:mm:ss') + ' scored=' + @($scored).Count) -Encoding UTF8 }
        if ($scored.Count -gt 0) {
            $lstRec.Items.Clear()
            $script:recProjects = @()
            $i = 0
            $lines = @()
            $marks = @('①', '②', '③')
            foreach ($s in ($scored | Select-Object -First 3)) {
                $i++
                $p = $s.Project
                $local = Find-LocalBuildForRepo $p.repo
                $locTxt = "本地没有（双击拉取）"
                if ($local) { $locTxt = "本地已有: " + $local }
                $row = ("{0} {1}  第{2}名 分{3} 画面{4}/5 速度{5}/6 稳定{6}/4  {7}" -f $marks[$i-1], $p.name, $p.pos, $s.Score, (LaneStep $p.lanes.picture), (SpeedStep $p.lanes.speed), (StabilityStep $p.lanes.stability), $locTxt)
                [void]$lstRec.Items.Add($row)
                $script:recProjects += $p
                $lines += $row
            }
            # 你的本地构建在榜上排第几
            $lines += ''
            $lines += '你的本地构建在榜情况：'
            $seen = @{}
            foreach ($b in @($script:builds)) {
                if ($seen.ContainsKey($b.Name)) { continue }
                $seen[$b.Name] = 1
                $cands = @(Get-RepoCandidates $b.Project)
                $mp = $null
                foreach ($c in $cands) { $m2 = @($data.projects | Where-Object { $_.repo -and ($_.repo -ieq $c) } | Select-Object -First 1); if ($m2.Count -gt 0) { $mp = $m2[0]; break } }
                if ($mp) {
                    $tag = if ($script:badBuilds.ContainsKey($b.Name)) { '  ⚠ ' + $script:badBuilds[$b.Name] } else { '' }
                    $lines += ("  {0,-12} → 榜上 {1}（第 {2} 名, 画面{3}/5 速度{4}/6 稳定{5}/4）{6}" -f $b.Name, $mp.name, $mp.pos, (LaneStep $mp.lanes.picture), (SpeedStep $mp.lanes.speed), (StabilityStep $mp.lanes.stability), $tag)
                } else {
                    $lines += ("  {0,-12} → 未上榜" -f $b.Name)
                }
            }
            # 本地最佳选择
            $bestLocal = $null
            $bestLocalScore = -1
            foreach ($b in @($script:builds)) {
                if ($script:badBuilds.ContainsKey($b.Name)) { continue }
                $cands = @(Get-RepoCandidates $b.Project)
                if ($cands.Count -eq 0) { continue }
                foreach ($s in $scored) {
                    $p2 = $s.Project
                    if (-not $p2.repo) { continue }
                    if (($cands | Where-Object { $_ -ieq $p2.repo }) -and $s.Score -gt $bestLocalScore) {
                        $bestLocalScore = $s.Score
                        $bestLocal = "$($b.Name)（对应 $($p2.name) 第 $($p2.pos) 名）"
                    }
                }
            }
            if ($bestLocal) { $lines += ("★ 本地最适合: {0}" -f $bestLocal) }
            $sum = @()
            $sumSeen = @{}
            foreach ($b in @($script:builds)) {
                if ($sumSeen.ContainsKey($b.Name)) { continue }
                $sumSeen[$b.Name] = 1
                $cands = @(Get-RepoCandidates $b.Project)
                foreach ($c in $cands) {
                    $m3 = @($data.projects | Where-Object { $_.repo -and ($_.repo -ieq $c) } | Select-Object -First 1)
                    if ($m3.Count -gt 0) { $sum += ("{0}→{1}#{2}" -f $b.Name, $m3[0].name, $m3[0].pos); break }
                }
            }
            $sumTxt = '无匹配'
            if ($sum.Count -gt 0) { $sumTxt = ($sum -join ' | ') }
            if ($sumTxt.Length -gt 115) { $sumTxt = $sumTxt.Substring(0, 115) + '…' }
            $bestTxt = ''
            if ($bestLocal) { $bestTxt = "  ★ 本地最佳: " + $bestLocal }
            $lblLocalBuilds.Text = ("本地构建在榜：{0}{1}" -f $sumTxt, $bestTxt)
            if ($env:GTA6_LAUNCHER_TRACE) { Add-Content -Path $env:GTA6_LAUNCHER_TRACE -Value ((Get-Date).ToString('HH:mm:ss') + ' recRows=' + $lstRec.Items.Count) -Encoding UTF8 }
            Add-Log ("推荐: " + ($lines -join ' / '))
            $script:raceRec = $scored
            Add-Log ("排行榜推荐已生成（{0} 行）：{1}" -f $lines.Count, ((@($scored | Select-Object -First 3) | ForEach-Object { $_.Project.name }) -join ' > '))
        }
    } catch {
        if ($env:GTA6_LAUNCHER_TRACE) { Add-Content -Path $env:GTA6_LAUNCHER_TRACE -Value ((Get-Date).ToString('HH:mm:ss') + ' UPDATE ERROR: ' + $_.Exception.Message) -Encoding UTF8 }
        Add-Log ("排行榜处理失败: " + $_.Exception.Message)
        $lblRaceUpdated.Text = '排行榜处理失败'
    }
}

# ---------------------------------------------------------------- 排行榜拉取构建
function Get-RaceCompat($p) {
    $hw = $script:hw
    if (-not $hw -or -not $p) { return [pscustomobject]@{ Ok = $true; Reasons = @() } }
    $reasons = @()
    $gpuTxt = (@($p.tested.gpu) -join ' ')
    $text = "$($p.status) $($p.kind) $gpuTxt"
    if ($hw.Vendor -eq 'NVIDIA' -and $gpuTxt -match 'AMD|Radeon' -and $gpuTxt -notmatch 'NVIDIA') { $reasons += '该项目只在 AMD 显卡上测试' }
    if ($hw.Vendor -eq 'AMD' -and $gpuTxt -match 'NVIDIA' -and $gpuTxt -notmatch 'AMD') { $reasons += '该项目只在 NVIDIA 显卡上测试' }
    $nums = @()
    foreach ($pat in 'RTX\s*\d{4}\s*(?:Ti|SUPER)?[^\d]{0,20}?(\d+)\s*GB', 'RX\s*\d{4}\s*(?:XT|XTX)?[^\d]{0,20}?(\d+)\s*GB', '(\d+)\s*GB\s*(?:card|VRAM)') {
        foreach ($m0 in [regex]::Matches($text, $pat, 'IgnoreCase')) { $nums += [int]$m0.Groups[1].Value }
    }
    $nums = @($nums | Where-Object { $_ -ge 4 -and $_ -le 48 } | Sort-Object -Unique)
    $userGB = [math]::Round($hw.VramMB / 1024, 0)
    if ($nums.Count -gt 0 -and $userGB -gt 0) {
        $minNeeded = ($nums | Measure-Object -Minimum).Minimum
        if ($minNeeded -gt ($userGB + 2)) { $reasons += ("测试用显存 {0} GB，你的显存 {1} GB" -f $minNeeded, $userGB) }
    }
    return [pscustomobject]@{ Ok = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Get-ReleaseAssets([string]$repo) {
    $out = @()
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'gta6-launcher' } -TimeoutSec 20
        foreach ($a in @($rel.assets)) { $out += [pscustomobject]@{ Name = $a.name; Size = [int64]$a.size; Url = $a.browser_download_url } }
    } catch { }
    return $out
}

function Expand-Any([string]$file, [string]$dest) {
    try {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        $low = $file.ToLower()
        if ($ext -eq '.zip') {
            Expand-Archive -Path $file -DestinationPath $dest -Force
            return $true
        }
        if ($low.EndsWith('.tar.gz') -or $low.EndsWith('.tgz')) {
            $tar = Get-Command tar.exe -EA SilentlyContinue
            if ($tar) { & tar.exe -xzf $file -C $dest 2>&1 | Out-Null; return $true }
            return $false
        }
        if ($ext -eq '.7z') {
            $seven = @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $seven) { $seven = (Get-Command 7z.exe -EA SilentlyContinue).Source }
            if ($seven) { & $seven x $file "-o$dest" -y 2>&1 | Out-Null; return $true }
            return $false
        }
        if ($ext -eq '.exe') { return $true }  # 单文件直接保留
        return $false
    } catch { return $false }
}

function Find-PrebuiltExe([string]$dir) {
    try {
        return @(Get-ChildItem $dir -Recurse -File -Filter 'victory*.exe' -EA SilentlyContinue | Where-Object { $_.Name -notmatch 'launcher' } | Sort-Object Length -Descending | Select-Object -First 1)
    } catch { return @() }
}

function Find-CargoRoot([string]$dir) {
    try {
        if (Test-Path (Join-Path $dir 'Cargo.toml')) { return $dir }
        $sub = Get-ChildItem $dir -Directory -EA SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'Cargo.toml') } | Select-Object -First 1
        if ($sub) { return $sub.FullName }
        $any = Get-ChildItem $dir -Recurse -File -Filter 'Cargo.toml' -EA SilentlyContinue | Select-Object -First 1
        if ($any) { return $any.DirectoryName }
        return ''
    } catch { return '' }
}

function Register-Prebuilt([string]$exePath, [string]$repo) {
    try {
        $name = ($repo -replace '[/:.]', '_')
        $dst = Join-Path $tbDlDir.Text.Trim (Join-Path $name 'target\release')
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item $exePath (Join-Path $dst 'victory.exe') -Force
        Add-Log ("已登记预编译 exe: {0}" -f (Join-Path $dst 'victory.exe'))
        Scan-Builds
        return $true
    } catch { Add-Log ("登记失败: " + $_.Exception.Message); return $false }
}

function Build-And-Deploy([string]$cargo) {
    try {
        if (-not (Get-Command cargo -EA SilentlyContinue)) { Add-Log '没有 cargo，无法编译'; return $false }
        try { if ($tbProxy -and $tbProxy.Text.Trim()) { $env:HTTP_PROXY = $tbProxy.Text.Trim(); $env:HTTPS_PROXY = $tbProxy.Text.Trim(); Add-Log ("cargo 代理: " + $tbProxy.Text.Trim()) } } catch { }
        $bLog = Join-Path $env:TEMP ("gta6-race-build-" + [System.IO.Path]::GetFileName($cargo) + ".log")
        Remove-Item $bLog -EA SilentlyContinue
        $attempts = @(
            @('-profile', 'diag', '-p', 'victory', '--features', 'diagnostics'),
            @('build', '--release')
        )
        $built = @()
        foreach ($at in $attempts) {
            $args2 = if ($at[0] -eq '-profile') { @('build') + $at } else { $at }
            Add-Log ("编译命令: cargo " + ($args2 -join ' '))
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'cargo'
            $psi.Arguments = ($args2 -join ' ')
            $psi.WorkingDirectory = $cargo
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $bp = [System.Diagnostics.Process]::Start($psi)
            $out = $bp.StandardOutput.ReadToEnd() + "`r`n" + $bp.StandardError.ReadToEnd()
            $bp.WaitForExit()
            Add-Content -Path $bLog -Value $out -Encoding UTF8
            $built = @(Get-ChildItem $cargo -Recurse -Depth 6 -File -Filter 'victory*.exe' -EA SilentlyContinue | Where-Object { $_.FullName -match '\\target\\(diag|release)\\' } | Sort-Object LastWriteTime -Descending)
            if ($built.Count -gt 0) { break }
            $tail = ($out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join ' | '
            Add-Log ("编译失败/无产物，尾部: " + $tail)
        }
        if ($built.Count -eq 0) {
            Add-Log ("编译结束但没找到 victory.exe（日志: {0}）" -f $bLog)
            return $false
        }
        $exe = $built[0]
        Add-Log ("编译成功: {0} ({1:N1} MB)" -f $exe.FullName, ($exe.Length/1MB))
        # 复制到规范路径，确保扫描器能找到并可直接使用
        $repoName = Split-Path $cargo -Leaf
        $dst = Join-Path $tbDlDir.Text.Trim (Join-Path $repoName 'target\release')
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item $exe.FullName (Join-Path $dst 'victory.exe') -Force
        Add-Log ("已部署: {0}" -f (Join-Path $dst 'victory.exe'))
        Scan-Builds
        return $true
    } catch { Add-Log ("编译失败: " + $_.Exception.Message); return $false }
}

function Test-HasSubmodules([string]$repo) {
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/contents/.gitmodules" -Headers @{ 'User-Agent' = 'gta6-launcher' } -TimeoutSec 15
        return $true
    } catch { return $false }
}

function Clone-RepoRecursive([string]$repo, [string]$dest) {
    try {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $dir = Join-Path $dest ($repo -replace '/', '_')
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -EA SilentlyContinue }
        $proxy = ''
        try { if ($tbProxy) { $proxy = $tbProxy.Text.Trim() } } catch { }
        $gitArgs = @()
        if ($proxy) { $gitArgs += @('-c', ("http.proxy=" + $proxy)) }
        $gitArgs += @('clone', '--recursive', '--depth', '1', ("https://github.com/$repo.git"), $dir)
        $env:GIT_TERMINAL_PROMPT = '0'
        Add-Log ("克隆（含 submodule）: {0}" -f $repo)
        $out = & git @gitArgs 2>&1
        $tail = ($out | Select-Object -Last 3) -join ' | '
        Add-Log ("git clone 完成: {0}" -f $dir)
        return $dir
    } catch { Add-Log ("clone 失败: " + $_.Exception.Message); return '' }
}

function Pull-RaceBuildAuto($p) {
    $lines = @()
    $lines += ("repo=" + $p.repo)
    $assets = @(Get-ReleaseAssets $p.repo)
    $lines += ("releaseAssets=" + $assets.Count)
    $prefer = $null
    if ($assets.Count -gt 0) {
        $prefer = $assets | Where-Object { $_.Name -match '(?i)(win|windows|x64|win64)' -and $_.Name -match '(?i)\.(zip|7z|tar\.gz|tgz|exe)$' } | Select-Object -First 1
        if (-not $prefer) { $prefer = $assets | Where-Object { $_.Name -match '(?i)\.(zip|7z|tar\.gz|tgz|exe)$' } | Select-Object -First 1 }
        if ($prefer) { $lines += ("pickedAsset=" + $prefer.Name + " " + [math]::Round($prefer.Size/1MB,1) + "MB") }
    }
    $dest = $tbDlDir.Text.Trim()
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if ($prefer) {
        $file = Join-Path $dest $prefer.Name
        try { Invoke-WebRequest -Uri $prefer.Url -OutFile $file -UseBasicParsing -TimeoutSec 600 } catch { $lines += ("downloadError=" + $_.Exception.Message); return $lines }
        $lines += ("downloaded=" + $prefer.Name + " " + (Get-Item $file).Length + "B")
        $extract = Join-Path $dest ([System.IO.Path]::GetFileNameWithoutExtension($prefer.Name))
        $okEx = Expand-Any $file $extract
        $lines += ("extracted=" + $okEx + " -> " + $extract)
        if ($okEx) {
            $found = @(Find-PrebuiltExe $extract)
            $lines += ("prebuiltFound=" + $found.Count)
            if ($found.Count -gt 0) { [void](Register-Prebuilt $found[0].FullName $p.repo); $lines += "registered=yes" ; return $lines }
            $cargo = Find-CargoRoot $extract
            $lines += ("cargoRoot=" + $cargo)
            if ($cargo -and $env:GTA6_LAUNCHER_PULLTEST_COMPILE -eq '1') {
                if (Get-Command cargo -EA SilentlyContinue) {
                    $lines += "compiling=yes"
                    $okB = Build-And-Deploy $cargo
                    $lines += ("compileOk=" + $okB)
                } else { $lines += "cargo=missing" }
            }
        }
        return $lines
    }
    # 无 release → 源码
    $branch = 'main'
    try { $info = Invoke-RestMethod -Uri "https://api.github.com/repos/$($p.repo)" -Headers @{ 'User-Agent'='gta6-launcher' } -TimeoutSec 20; if ($info.default_branch) { $branch = $info.default_branch } } catch { }
    $lines += ("noReleaseUsingSource=yes branch=" + $branch)
    $hasSub = Test-HasSubmodules $p.repo
    $lines += ("hasSubmodules=" + $hasSub)
    if ($hasSub) {
        $repoDir = Clone-RepoRecursive $p.repo $dest
        $lines += ("cloneDir=" + $repoDir + " exists=" + (Test-Path $repoDir))
        if (-not $repoDir -or -not (Test-Path $repoDir)) { return $lines }
        $extract = $repoDir
    } else {
        Download-FromGitHub $p.repo $branch $dest
        $zipName = ($p.repo -replace '/', '_') + "-$branch.zip"
        $extract = Join-Path $dest ([System.IO.Path]::GetFileNameWithoutExtension($zipName))
        $lines += ("zipExists=" + (Test-Path (Join-Path $dest $zipName)) + " path=" + (Join-Path $dest $zipName))
        $lines += ("extractedDir=" + $extract + " exists=" + (Test-Path $extract))
        if (-not (Test-Path $extract)) { return $lines }
    }
    $cargo = Find-CargoRoot $extract
    $lines += ("cargoRoot=" + $cargo)
    $found = @(Find-PrebuiltExe $extract)
    $lines += ("prebuiltFound=" + $found.Count)
    if ($found.Count -gt 0) { [void](Register-Prebuilt $found[0].FullName $p.repo); $lines += "registered=yes"; return $lines }
    if ($cargo -and $env:GTA6_LAUNCHER_PULLTEST_COMPILE -eq '1') {
        $lines += "compiling=yes"
        $okB = Build-And-Deploy $cargo
        $lines += ("compileOk=" + $okB)
    }
    return $lines
}

function Pull-RaceBuild($p) {
    try {
        if (-not $p) { Add-Log '先在排行榜列表里选一个项目'; return }
        if (-not $p.repo) { [System.Windows.Forms.MessageBox]::Show('该项目没有公开仓库（可能已删除/私有），无法拉取。', '无法拉取'); return }

        # 1) 硬件适配检查
        $compat = Get-RaceCompat $p
        if (-not $compat.Ok) {
            $hw = $script:hw
            $msg = ("选中项目：{0}（榜上第 {1} 名）`r`n测试硬件：{2}`r`n`r`n可能的适配问题：`r`n  - {3}`r`n`r`n你的配置：{4} / {5} GB 显存 / {6} GB 内存`r`n`r`n仍然继续拉取吗？`r`n  是 = 继续`r`n  否 = 取消" -f $p.name, $p.pos, ((@($p.tested.gpu) -join ', ')), ($compat.Reasons -join "`r`n  - "), $hw.Vendor, [math]::Round($hw.VramMB/1024,0), $hw.RamGB)
            if ([System.Windows.Forms.MessageBox]::Show($msg, '配置可能不适配', 'YesNo', 'Warning') -ne 'Yes') { Add-Log ("已取消拉取 {0}（配置不适配）" -f $p.name); return }
        }

        # 2) 查 Release
        Add-Log ("检查 {0} 的 Release…" -f $p.repo)
        $assets = Get-ReleaseAssets $p.repo
        $prefer = $null
        if ($assets.Count -gt 0) {
            $prefer = $assets | Where-Object { $_.Name -match '(?i)(win|windows|x64|win64)' -and $_.Name -match '(?i)\.(zip|7z|tar\.gz|tgz|exe)$' } | Select-Object -First 1
            if (-not $prefer) { $prefer = $assets | Where-Object { $_.Name -match '(?i)\.(zip|7z|tar\.gz|tgz|exe)$' } | Select-Object -First 1 }
        }

        $dest = $tbDlDir.Text.Trim()
        if ($prefer) {
            $sz = [math]::Round($prefer.Size / 1MB, 1)
            $msg = ("该项目有 Release 附件：`r`n  {0}（{1} MB）`r`n`r`n拉取方式：`r`n  是 = 下载 Release 附件（推荐）`r`n  否 = 下载源码 ZIP 并编译`r`n  取消 = 不拉取" -f $prefer.Name, $sz)
            $choice = [System.Windows.Forms.MessageBox]::Show($msg, '拉取构建', 'YesNoCancel', 'Question')
            if ($choice -eq 'Cancel') { return }
            if ($choice -eq 'Yes') {
                Add-Log ("下载 Release: {0} ({1} MB)" -f $prefer.Name, $sz)
                $file = Join-Path $dest $prefer.Name
                Invoke-WebRequest -Uri $prefer.Url -OutFile $file -UseBasicParsing -TimeoutSec 600
                $extract = Join-Path $dest ([System.IO.Path]::GetFileNameWithoutExtension($prefer.Name))
                $okEx = Expand-Any $file $extract
                if (-not $okEx) { Add-Log '未知压缩格式（需要 7z/tar）；文件已下载到: ' + $file; return }
                $found = Find-PrebuiltExe $extract
                if ($found -and $found.Count -gt 0) {
                    [void](Register-Prebuilt $found[0].FullName $p.repo)
                    Add-Log 'Release 附件已解压并登记为构建（去 ② 选择）'
                } else {
                    $cargo = Find-CargoRoot $extract
                    if ($cargo) { Add-Log ("Release 附件里没有 victory.exe；发现了源码工程: {0}，可点「编译选中的源码构建」" -f $cargo) }
                    else { Add-Log 'Release 附件已解压，但没有找到 victory.exe 或 Cargo.toml'; }
                }
                return
            }
            # choice == No → 走源码
        } else {
            $msg = ("{0} 没有可用的 Release 附件。`r`n`r`n是否改为下载源码 ZIP？（下载后可选择编译）`r`n  是 = 下载源码 ZIP`r`n  否 = 取消" -f $p.name)
            if ([System.Windows.Forms.MessageBox]::Show($msg, '没有 Release', 'YesNo', 'Question') -ne 'Yes') { Add-Log '已取消（没有 Release）'; return }
        }

        # 3) 源码 ZIP
        $branch = 'main'
        try {
            $info = Invoke-RestMethod -Uri "https://api.github.com/repos/$($p.repo)" -Headers @{ 'User-Agent' = 'gta6-launcher' } -TimeoutSec 20
            if ($info.default_branch) { $branch = $info.default_branch }
        } catch { }
        Add-Log ("拉取源码: {0} @ {1}" -f $p.repo, $branch)
        $extract = ''
        if (Test-HasSubmodules $p.repo) {
            Add-Log '检测到 git submodule，改用 git clone --recursive（ZIP 不含子模块）'
            $extract = Clone-RepoRecursive $p.repo $dest
        } else {
            Download-FromGitHub $p.repo $branch $dest
            $zipName = ($p.repo -replace '/', '_') + "-$branch.zip"
            $extract = Join-Path $dest ([System.IO.Path]::GetFileNameWithoutExtension($zipName))
        }
        if (-not $extract -or -not (Test-Path $extract)) { Add-Log '源码下载/克隆失败'; return }
        $cargo = Find-CargoRoot $extract
        if (-not $cargo) { Add-Log '没找到 Cargo.toml（可能是非 Rust 项目）'; return }
        $foundExe = Find-PrebuiltExe $cargo
        if ($foundExe -and $foundExe.Count -gt 0) {
            [void](Register-Prebuilt $foundExe[0].FullName $p.repo)
            return
        }
        if (-not (Get-Command cargo -EA SilentlyContinue)) { Add-Log ("源码已下载到 {0}，但本机没有 cargo，无法编译" -f $cargo); return }
        if ([System.Windows.Forms.MessageBox]::Show(("源码已下载：`r`n{0}`r`n`r`n现在编译吗？（可能需要几分钟）" -f $cargo), '编译源码', 'YesNo', 'Question') -ne 'Yes') { Add-Log '已跳过编译'; return }
        [void](Start-CompileAsync $cargo ($p.name + ' 拉取构建'))
    } catch { Add-Log ("拉取构建失败: " + $_.Exception.Message) }
}
# ---------------------------------------------------------------- 键盘映射
function KeyNameToVk([string]$name) {
    if (-not $name) { return -1 }
    $n = $name.Trim()
    if (-not $n) { return -1 }
    if ($n -match '^0x[0-9a-fA-F]+$') { return [Convert]::ToInt32($n, 16) }
    if ($n -match '^\d+$') { return [int]$n }
    $up = $n.ToUpper()
    if ($up.Length -eq 1 -and $up -match '^[A-Z0-9]$') { return [int][char]$up }
    $table = @{
        'F1' = 0x70; 'F2' = 0x71; 'F3' = 0x72; 'F4' = 0x73; 'F5' = 0x74; 'F6' = 0x75
        'F7' = 0x76; 'F8' = 0x77; 'F9' = 0x78; 'F10' = 0x79; 'F11' = 0x7A; 'F12' = 0x7B
        'SPACE' = 0x20; 'ENTER' = 0x0D; 'RETURN' = 0x0D; 'ESC' = 0x1B; 'ESCAPE' = 0x1B
        'TAB' = 0x09; 'SHIFT' = 0x10; 'CTRL' = 0x11; 'CONTROL' = 0x11; 'ALT' = 0x12
        'CAPSLOCK' = 0x14; 'BACKSPACE' = 0x08; 'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
        'HOME' = 0x24; 'END' = 0x23; 'PGUP' = 0x21; 'PAGEUP' = 0x21; 'PGDN' = 0x22; 'PAGEDOWN' = 0x22
        'INSERT' = 0x2D; 'INS' = 0x2D; 'DELETE' = 0x2E; 'DEL' = 0x2E
        'SEMICOLON' = 0xBA; 'EQUALS' = 0xBB; 'COMMA' = 0xBC; 'MINUS' = 0xBD; 'PERIOD' = 0xBE
        'SLASH' = 0xBF; 'BACKSLASH' = 0xDC; 'LBRACKET' = 0xDB; 'RBRACKET' = 0xDD; 'QUOTE' = 0xDE; 'TILDE' = 0xC0
    }
    for ($i = 0; $i -le 9; $i++) { $table["NUM$i"] = 0x60 + $i; $table["NUMPAD$i"] = 0x60 + $i }
    if ($table.ContainsKey($up)) { return [int]$table[$up] }
    return -1
}

function Parse-KeyMap {
    $d = New-Object 'System.Collections.Generic.Dictionary[int,int]'
    $errs = @()
    $lines = @()
    if ($txtKeyMap) { $lines = $txtKeyMap.Text -split "`r?`n" }
    foreach ($line in $lines) {
        $s = $line.Trim()
        if (-not $s) { continue }
        if ($s.StartsWith('#')) { continue }
        if ($s -notmatch '=') { $errs += "格式错误: $s"; continue }
        $parts = $s -split '=', 2
        $a = KeyNameToVk $parts[0]
        $b = KeyNameToVk $parts[1]
        if ($a -lt 0) { $errs += "未知源键: $($parts[0].Trim())"; continue }
        if ($b -lt 0) { $errs += "未知目标键: $($parts[1].Trim())"; continue }
        $d[[int]$a] = [int]$b
    }
    return [pscustomobject]@{ Map = $d; Errors = $errs }
}

function Start-Mapper {
    try {
        if (-not ('KeyMap' -as [type])) {
            $csPath = Join-Path $Root 'keymap.cs'
            if (-not (Test-Path $csPath)) { Add-Log '缺少 keymap.cs，无法启动映射'; return }
            Add-Type -TypeDefinition (Get-Content $csPath -Raw -Encoding UTF8)
        }
        $parsed = Parse-KeyMap
        if ($parsed.Errors.Count -gt 0) {
            Add-Log ("映射表有错误: " + ($parsed.Errors -join '; '))
            [System.Windows.Forms.MessageBox]::Show(($parsed.Errors -join "`r`n"), '映射表错误')
            return
        }
        if ($parsed.Map.Count -eq 0) { Add-Log '映射表为空，先写几条映射'; return }
        [KeyMap]::Map = $parsed.Map
        if ($script:game -and -not $script:game.HasExited) {
            try { if ($script:game.MainWindowHandle -ne [IntPtr]::Zero) { [KeyMap]::GameWindow = $script:game.MainWindowHandle } } catch { }
        }
        [KeyMap]::Enabled = $true
        $ok = [KeyMap]::Install()
        if ($ok) {
            $script:mapperWanted = $true
            $lblKeyStatus.Text = ("映射已启动：{0} 条（仅在游戏窗口聚焦时生效，Ctrl+Alt+M 开关）" -f $parsed.Map.Count)
            Add-Log ("键盘映射已启动: {0} 条" -f $parsed.Map.Count)
        } else {
            $lblKeyStatus.Text = '钩子安装失败（可能被杀毒/安全软件拦截）'
            Add-Log '键盘钩子安装失败'
        }
    } catch { Add-Log ("键盘映射启动失败: " + $_.Exception.Message) }
}

function Stop-Mapper {
    try {
        if ('KeyMap' -as [type]) { [KeyMap]::Uninstall() }
        $script:mapperWanted = $false
$script:raceList = @()
$script:recProjects = @()
        $lblKeyStatus.Text = '映射已停止'
        Add-Log '键盘映射已停止'
    } catch { }
}

# ---------------------------------------------------------------- 崩溃记录与自动清理
function Get-CrashCount {
    try {
        if (-not (Test-Path $script:crashFile)) { return 0 }
        return @(Get-Content $script:crashFile -EA SilentlyContinue | Where-Object { $_.Trim() }).Count
    } catch { return 0 }
}

function Update-CrashLabel {
    try {
        $script:crashCount = Get-CrashCount
        if ($lblCrash) {
            $lblCrash.Text = ("崩溃记录：{0} 次 / 10（满 10 次自动清理日志）" -f $script:crashCount)
        }
    } catch { }
}

function Auto-Clean-Crashes {
    try {
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        $archive = Join-Path $script:logDir ("crashes-archive-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".jsonl")
        if (Test-Path $script:crashFile) { Move-Item $script:crashFile $archive -Force }
        Set-Content -Path $script:crashFile -Value ('{"event":"auto-cleaned","time":"' + (Get-Date).ToString('o') + '"}') -Encoding UTF8
        # 只保留最近 2 个游戏日志，其余删除
        $logs = @(Get-ChildItem $script:logDir -Filter 'game-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)
        for ($i = 2; $i -lt $logs.Count; $i++) { Remove-Item $logs[$i].FullName -Force -EA SilentlyContinue }
        Add-Log ('崩溃记录已达 10 次：旧日志已归档到 {0}，游戏日志仅保留最近 2 个' -f (Split-Path $archive -Leaf))
        Update-CrashLabel
    } catch { Add-Log ("自动清理崩溃日志失败: " + $_.Exception.Message) }
}

function Record-Crash([string]$reason, $tail) {
    try {
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        $entry = [pscustomobject]@{
            time = (Get-Date).ToString('o')
            reason = $reason
            build = $script:buildName
            console = $(if ($rbSX.Checked) { 'series-x' } else { 'series-s' })
            height = $(if ($rbAutoRes.Checked) { 'auto' } else { ($heights | Where-Object { $rbResMap[$_].Checked } | Select-Object -First 1) })
            cacheDir = $script:cacheDir
            gameLog = $script:gameLog
            ranSeconds = $(if ($script:gameStart) { [math]::Round(((Get-Date) - $script:gameStart).TotalSeconds, 1) } else { 0 })
            tail = @($tail | Select-Object -Last 30)
        }
        Add-Content -Path $script:crashFile -Value ($entry | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
        # 单独存一份完整尾部，方便排查
        if ($tail -and $tail.Count -gt 0) {
            $dump = Join-Path $script:logDir ("crash-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
            Set-Content -Path $dump -Value ($tail -join "`r`n") -Encoding UTF8
        }
        $script:crashCount = Get-CrashCount
        Add-Log ("已记录崩溃 #{0}：{1}（运行 {2} 秒）" -f $script:crashCount, $reason, $entry.ranSeconds)
        Update-CrashLabel
        if ($script:crashCount -ge 10) { Auto-Clean-Crashes }
    } catch { Add-Log ("记录崩溃失败: " + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 事件
foreach ($b in $btnBrowse) {
    $b.Add_Click({
        $i = [int]$this.Tag
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择目录'
        if (Test-Path $tbPath[$i].Text) { $dlg.SelectedPath = $tbPath[$i].Text }
        if ($dlg.ShowDialog() -eq 'OK') { $tbPath[$i].Text = $dlg.SelectedPath; Save-Cfg }
    })
}
$btnScan.Add_Click({ Scan-Builds })
$btnRaceNow.Add_Click({ Update-Race })
$btnRacePull.Add_Click({
    if ($lstRace.SelectedIndex -ge 0 -and $script:raceList) { Pull-RaceBuild $script:raceList[$lstRace.SelectedIndex] }
    else { Add-Log '先在排行榜列表里点选一个项目' }
})
$lstRace.Add_DoubleClick({
    if ($lstRace.SelectedIndex -ge 0 -and $script:raceList) { Pull-RaceBuild $script:raceList[$lstRace.SelectedIndex] }
})
$lstRec.Add_DoubleClick({
    if ($lstRec.SelectedIndex -ge 0 -and $script:recProjects -and $script:recProjects.Count -gt $lstRec.SelectedIndex) { Pull-RaceBuild $script:recProjects[$lstRec.SelectedIndex] }
})
$btnRecPull.Add_Click({
    if ($lstRec.SelectedIndex -ge 0 -and $script:recProjects -and $script:recProjects.Count -gt $lstRec.SelectedIndex) { Pull-RaceBuild $script:recProjects[$lstRec.SelectedIndex] }
    else { Add-Log '先在上面的推荐列表里选一个项目' }
})
$btnRecRepo.Add_Click({
    try {
        if ($lstRec.SelectedIndex -ge 0 -and $script:recProjects -and $script:recProjects.Count -gt $lstRec.SelectedIndex) {
            $rp = $script:recProjects[$lstRec.SelectedIndex]
            if ($rp.repo) { Start-Process ("https://github.com/" + $rp.repo) } else { Add-Log '该项目没有公开仓库' }
        } else { Add-Log '先选一个推荐项目' }
    } catch { }
})
$btnKeyStart.Add_Click({ Start-Mapper })
$btnKeyStop.Add_Click({ Stop-Mapper })
$btnKeySave.Add_Click({ Save-Cfg; try { $r = Parse-KeyMap; Add-Log ("映射已保存：{0} 条（{1} 个错误）" -f $r.Map.Count, $r.Errors.Count) } catch { } })
$btnKeyTest.Add_Click({
    Start-Mapper
    Add-Log '按键测试：请按下任意键，下面状态栏会显示最后捕获的键'
})
$btnCheck.Add_Click({ Check-Update })
$btnUpdate.Add_Click({ Update-Build })
$btnRollback.Add_Click({ Rollback-Build })
$lstBuilds.Add_SelectedIndexChanged({ try { Select-Build } catch { Add-Log "选择构建出错: $($_.Exception.Message)" } })
$btnDlSrc.Add_Click({ Download-FromGitHub $tbRepo.Text.Trim() $tbBranch.Text.Trim() $tbDlDir.Text.Trim() })
$btnDlRel.Add_Click({ Download-FromGitHub $tbRepo.Text.Trim() $tbBranch.Text.Trim() $tbDlDir.Text.Trim() -Release })
$btnCargo.Add_Click({ Compile-Selected })
$btnWarmShaders.Add_Click({ Start-Warm 'shaders' })
$btnWarmPipes.Add_Click({ Start-Warm 'pipelines' })
$btnWarmAll.Add_Click({ Start-Warm 'all' })
$btnStop.Add_Click({ Stop-Warm })
$btnLaunch.Add_Click({ Launch-Game })
$btnOpenLogs.Add_Click({
    try {
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        Start-Process 'explorer.exe' $script:logDir
    } catch { }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    try { Update-Warm } catch { Add-Log ("更新出错: " + $_.Exception.Message) }
    try { Update-Compile } catch { }
    try {
        if ('KeyMap' -as [type]) {
            if ($script:game -and -not $script:game.HasExited) {
                try { if ($script:game.MainWindowHandle -ne [IntPtr]::Zero) { [KeyMap]::GameWindow = $script:game.MainWindowHandle } } catch { }
            } else { [KeyMap]::GameWindow = [IntPtr]::Zero }
            $txtKeyLast.Text = [KeyMap]::Status()
            if ([KeyMap]::Map.Count -gt 0) {
                $st = if ([KeyMap]::Enabled) { '启用中' } else { '暂停（Ctrl+Alt+M 开启）' }
                $lblKeyStatus.Text = ("映射已安装：{0} 条 | {1}" -f [KeyMap]::Map.Count, $st)
            }
        }
    } catch { }
    try {
        if ($script:game -and $script:game.HasExited) {
            $code = $null
            try { $null = $script:game.WaitForExit(1000); $code = $script:game.ExitCode; if ("$code" -eq '') { $code = $null } } catch { }
            $ran = if ($script:gameStart) { ((Get-Date) - $script:gameStart).TotalSeconds } else { 0 }
            $tail = @()
            foreach ($lf in @($script:gameLog, $(if ($script:gameLog) { $script:gameLog + '.err' } else { $null }))) {
                if ($lf -and (Test-Path $lf)) { $tail += @(Get-Content $lf -Tail 80 -EA SilentlyContinue) }
            }
            $text = ($tail -join "`n")
            $crash = $false; $reason = ''
            if ($text -match 'upload_file_minidump|BacktraceBreakpad|panic|device removed|0x887A0006|DXGI_ERROR_DEVICE') { $crash = $true; $reason = 'breakpad/设备移除/panic' }
            elseif ($null -ne $code -and $code -ne 0) { $crash = $true; $reason = ("退出码 {0}" -f $code) }
            elseif ($ran -gt 0 -and $ran -lt 10) { $crash = $true; $reason = ("启动 {0} 秒即退出" -f [math]::Round($ran, 1)) }
            if ($crash) { Record-Crash $reason $tail } else { Add-Log ("游戏正常退出（运行 {0:N0} 秒）" -f $ran) }
            $script:game = $null; $script:gameStart = $null
            $btnLaunch.Enabled = $true; $lblStatus.Text = '游戏已退出'
        }
    } catch { }
})
$timer.Start()

$form.Add_FormClosing({
    try { Save-Cfg } catch { }
    try { if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill($true) } } catch { }
    try { if ($chkOpenDir.Checked -and $script:game -and -not $script:game.HasExited) { $script:game.Kill($true) } } catch { }
    try { if ('KeyMap' -as [type]) { [KeyMap]::Uninstall() } } catch { }
})
$form.Add_Shown({
    Refresh-Hw
    Scan-Builds
    try {
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        Update-CrashLabel
    } catch { }
    try {
        if ($Cfg.KeyMap) { $txtKeyMap.Text = $Cfg.KeyMap }
        else { $txtKeyMap.Text = "# 每行一条：源键 = 目标键`r`n# CapsLock = Escape`r`n# F1 = Tab" }
        if ($Cfg.ContainsKey('KeyMapOn')) { $chkKeyAuto.Checked = [bool]$Cfg.KeyMapOn }
    } catch { }
    $raceTimer = New-Object System.Windows.Forms.Timer
    $raceTimer.Interval = 1500
    $raceTimer.Add_Tick({ $this.Stop(); try { Update-Race } catch { } })
    $raceTimer.Start()
    if ($env:GTA6_LAUNCHER_ASYNCTEST_ROOT) {
        try {
            [void](Start-CompileAsync $env:GTA6_LAUNCHER_ASYNCTEST_ROOT 'asynctest')
        } catch { }
        $at = New-Object System.Windows.Forms.Timer
        $at.Interval = 90000
        $at.Add_Tick({
            $this.Stop()
            try {
                $out = @(
                    ("status=" + $lblStatus.Text),
                    ("compileDone=" + $(if ($script:compile) { $script:compile.Done } else { 'no-compile' })),
                    ("compileOk=" + $(if ($script:compile) { $script:compile.Ok } else { 'no-compile' })),
                    ("buildsNow=" + @($script:builds).Count)
                )
                Set-Content -Path $env:GTA6_LAUNCHER_ASYNCTEST_ROOT_OUT -Value ($out -join "`r`n") -Encoding UTF8
            } catch { }
            $form.Close()
        })
        $at.Start()
    }
    if ($env:GTA6_LAUNCHER_ENVDUMP) {
        try {
            $outLines = @()
            for ($bi = 0; $bi -lt $script:builds.Count; $bi++) {
                $lstBuilds.SelectedIndex = $bi
                Start-Sleep -Milliseconds 150
                $null = Build-Env
                $outLines += ("build={0} exe={1}" -f $script:builds[$bi].Name, $script:builds[$bi].Exe)
                $outLines += ("  supportsScale={0}" -f (Test-BuildSupportsRenderScale $script:builds[$bi].Exe))
                $outLines += ("  RENDER_SCALE={0} RESOLUTION={1} WINDOW_PERCENT={2} CARD_BUFFERS_MB={3}" -f $env:VICTORY_RENDER_SCALE, $env:VICTORY_RESOLUTION, $env:VICTORY_WINDOW_PERCENT, $env:VICTORY_CARD_BUFFERS_MB)
            }
            Set-Content -Path $env:GTA6_LAUNCHER_ENVDUMP -Value ($outLines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_ENVDUMP -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_LAYOUTTEST) {
        try {
            $lines = @()
            $lines += ("form=" + $form.ClientSize.Width + "x" + $form.ClientSize.Height)
            $lines += ("racePage=" + $tabRace.ClientSize.Width + "x" + $tabRace.ClientSize.Height)
            $lines += ("runPage=" + $tabRun.ClientSize.Width + "x" + $tabRun.ClientSize.Height)
            foreach ($pg in @($tabRace, $tabRun, $tabKeys)) {
                $lines += ("--- " + $pg.Text + " ---")
                $maxB = 0
                foreach ($c in $pg.Controls) {
                    $b = $c.Bounds
                    $txt = ''
                    try { if ($c.Text) { $txt = ($c.Text -replace "`r?`n", ' '); if ($txt.Length -gt 28) { $txt = $txt.Substring(0,28) } } } catch { }
                    $lines += ("  {0,-18} x={1,3} y={2,3} w={3,3} h={4,3}  bottom={5,3}  {6}" -f $c.GetType().Name, $b.X, $b.Y, $b.Width, $b.Height, ($b.Y + $b.Height), $txt)
                    if (($b.Y + $b.Height) -gt $maxB) { $maxB = $b.Y + $b.Height }
                }
                $lines += ("  MAX_BOTTOM={0}  PAGE_HEIGHT={1}  OVERFLOW={2}" -f $maxB, $pg.ClientSize.Height, ($maxB -gt $pg.ClientSize.Height))
            }
            Set-Content -Path $env:GTA6_LAUNCHER_LAYOUTTEST -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_LAYOUTTEST -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_CRASHTEST) {
        try {
            New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
            Remove-Item $script:crashFile -EA SilentlyContinue
            $simTail = @('BacktraceBreakpad', "Added file 'upload_file_minidump'", '0x887A0006 DXGI_ERROR_DEVICE_HUNG')
            for ($k = 1; $k -le 11; $k++) { Record-Crash ("模拟崩溃 #" + $k) $simTail }
            $lines = @()
            $lines += ("crashFile=" + $script:crashFile)
            $lines += ("crashEntries=" + (Get-CrashCount))
            $lines += ("logFiles=" + @(Get-ChildItem $script:logDir -Filter 'game-*.log' -EA SilentlyContinue).Count)
            $lines += ("archives=" + @(Get-ChildItem $script:logDir -Filter 'crashes-archive-*' -EA SilentlyContinue).Count)
            $lines += ("label=" + $lblCrash.Text)
            Set-Content -Path $env:GTA6_LAUNCHER_CRASHTEST -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_CRASHTEST -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_PULLTEST_REPO) {
        try {
            $repo = $env:GTA6_LAUNCHER_PULLTEST_REPO.Trim()
            $pout = $env:GTA6_LAUNCHER_PULLTEST_OUT
            if (-not $pout) { $pout = (Join-Path $Root 'pulltest.result.txt') }
            $fake = [pscustomobject]@{ name = ($repo -split '/')[-1]; repo = $repo; pos = 99; stage = 6; status = ''; kind = ''; tested = [pscustomobject]@{ os = @('Windows'); gpu = @('NVIDIA') }; lanes = [pscustomobject]@{ picture = [pscustomobject]@{ step = 3 }; speed = [pscustomobject]@{ high = 10 }; stability = [pscustomobject]@{ minutes = 30 } } }
            $lines = @(Pull-RaceBuildAuto $fake)
            $lines += ("buildsNow=" + @($script:builds).Count)
            $lines += ("buildNames=" + ((@($script:builds) | ForEach-Object { $_.Name } | Select-Object -Unique) -join ','))
            Set-Content -Path $pout -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $pout -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_COMPATTEST) {
        try {
            Update-Race
            $lines = @()
            $lines += "raceItems=" + $lstRace.Items.Count
            $lines += "raceList=" + $script:raceList.Count
            $lines += "firstRow=" + $lstRace.Items[0]
            $i = 0
            foreach ($p in @($script:raceList | Select-Object -First 6)) {
                $c = Get-RaceCompat $p
                $lines += ("compat: {0} -> ok={1} reasons={2}" -f $p.name, $c.Ok, ($c.Reasons -join '/'))
                $i++
            }
            Set-Content -Path $env:GTA6_LAUNCHER_COMPATTEST -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_COMPATTEST -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_KEYTEST) {
        try {
            $txtKeyMap.Text = "CapsLock = Escape`r`nF1 = Tab`r`nW = Up`r`n# 注释行会被忽略"
            $parsed = Parse-KeyMap
            $errTxt = "BadKey = A"
            $txtKeyMap.Text = $txtKeyMap.Text + "`r`n" + $errTxt
            $parsedErr = Parse-KeyMap
            $txtKeyMap.Text = "CapsLock = Escape`r`nF1 = Tab`r`nW = Up"
            Start-Mapper
            Start-Sleep -Milliseconds 500
            $lines = @()
            $lines += "mapCount=" + $parsed.Map.Count
            $lines += "parseGood=" + $parsed.Map.Count + " errors=0"
            $lines += "parseBadDetected=" + $parsedErr.Errors.Count
            if ('KeyMap' -as [type]) { $lines += "status=" + [KeyMap]::Status(); [KeyMap]::Uninstall() }
            $lines += "uninstall=" + $(if ('KeyMap' -as [type]) { [KeyMap]::Status() } else { 'n/a' })
            Set-Content -Path $env:GTA6_LAUNCHER_KEYTEST -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_KEYTEST -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_ROLLTEST) {
        try {
            $idx = -1
            for ($i = 0; $i -lt $script:builds.Count; $i++) { if ($script:builds[$i].Name -eq 'vf-nvidia') { $idx = $i; break } }
            if ($idx -ge 0) { $lstBuilds.SelectedIndex = $idx }
            $exe = $script:builds[$idx].Exe
            $bak = "$exe.bak-rolltest"
            Copy-Item $exe $bak -Force
            $before = (Get-FileHash $exe).Hash
            Rollback-Build
            $after = (Get-FileHash $exe).Hash
            $lines = @()
            $lines += "selected=" + $script:buildName
            $lines += "backupFound=" + (Test-Path $bak)
            $lines += "restoredSameHash=" + ($before -eq $after)
            Set-Content -Path $env:GTA6_LAUNCHER_ROLLTEST -Value ($lines -join "`r`n") -Encoding UTF8
            Remove-Item $bak -Force -EA SilentlyContinue
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_ROLLTEST -Value ("ERR " + $_.Exception.Message) -Encoding UTF8 }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_WARMTEST) {
        Start-Warm 'all'
        $wt = New-Object System.Windows.Forms.Timer
        $wt.Interval = 45000
        $wt.Add_Tick({
            $this.Stop()
            try {
                $lines = @()
                $lines += "warmKind=" + $script:warmKind
                $lines += "warmDone=" + $script:warmDone + " / " + $script:warmTotal
                $lines += "sawPipelines=" + ((Get-Content $script:outLog -EA SilentlyContinue | Select-String 'pipelines known|to make|made in' | Measure-Object).Count)
                Set-Content -Path $env:GTA6_LAUNCHER_WARMTEST -Value ($lines -join "`r`n") -Encoding UTF8
            } catch { }
            Stop-Warm
            $form.Close()
        })
        $wt.Start()
    }
    if ($env:GTA6_LAUNCHER_LAUNCHTEST) {
        Start-Sleep -Milliseconds 500
        Launch-Game
        $lt = New-Object System.Windows.Forms.Timer
        $lt.Interval = 75000
        $lt.Add_Tick({
            $this.Stop()
            try {
                $lines = @()
                $p = Get-Process victory -EA SilentlyContinue | Select-Object -First 1
                $lines += "gameRunning=" + $(if ($p) { 'yes' } else { 'no' })
                if ($p) { $lines += "title=" + $p.MainWindowTitle }
                $lines += "cacheDir=" + $script:cacheDir
                Set-Content -Path $env:GTA6_LAUNCHER_LAUNCHTEST -Value ($lines -join "`r`n") -Encoding UTF8
            } catch { }
            Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
            $form.Close()
        })
        $lt.Start()
    }
    if ($env:GTA6_LAUNCHER_RACEDUMP) {
        $dumpTimer = New-Object System.Windows.Forms.Timer
        $dumpTimer.Interval = 20000
        $dumpTimer.Add_Tick({
            $this.Stop()
            try { Set-Content -Path $env:GTA6_LAUNCHER_RACEDUMP -Value ("updated=" + $lblRaceUpdated.Text + "`r`nrec=`r`n" + ((@($lstRec.Items) -join "`r`n") + "`r`n" + $lblLocalBuilds.Text)) -Encoding UTF8 } catch { }
            $form.Close()
        })
        $dumpTimer.Start()
    }
    if ($env:GTA6_LAUNCHER_RACETEST) {
    try { Update-Race } catch { }
    try {
        $outLines = @()
        $outLines += "updated=" + $lblRaceUpdated.Text
        $outLines += "--- race rows ---"
        $outLines += @($lstRace.Items | Select-Object -First 6)
        $outLines += "--- recommendation ---"
        $outLines += @($lstRec.Items)
        Set-Content -Path $env:GTA6_LAUNCHER_RACETEST -Value ($outLines -join "`r`n") -Encoding UTF8
    } catch { }
    $form.Close()
}
if ($env:GTA6_LAUNCHER_CHECKUPDATE) {
        try { Check-Update } catch { }
        try { Set-Content -Path $env:GTA6_LAUNCHER_CHECKUPDATE -Value ("check=" + $lblVerInfo.Text) -Encoding UTF8 } catch { }
        $form.Close()
    }
    if ($env:GTA6_LAUNCHER_SHOWTAB) { try { $tabs.SelectedIndex = [int]$env:GTA6_LAUNCHER_SHOWTAB } catch { } }
    if ($env:GTA6_LAUNCHER_SELFTEST) {
        try {
            $lines = @()
            $lines += "vendor=$($script:hw.Vendor) vramGB=$([math]::Round($script:hw.VramMB/1024,1))"
            $lines += "cpu=$($script:hw.CpuName) ramGB=$($script:hw.RamGB)"
            $lines += "recBuild=$($script:rec.Build) recConsole=$($script:rec.Console) recHeight=$($script:rec.Height) recPreset=$($script:rec.Preset)"
            $lines += "builds=$($script:builds.Count)"
            foreach ($b in $script:builds) { $lines += "  build: $($b.Name) [$($b.Profile)] $($b.SizeMB)MB" }
            $lines += "selected=$($script:buildName)"
            $info = Get-ProjectInfo $script:builds[$lstBuilds.SelectedIndex].Project
            $lines += "git=$($info.Git) branch=$($info.Branch) commit=$($info.Commit) remote=$($info.Remote)"
            $lines += "translator=$($info.Translator)"
            $lines += "cacheState=$(($script:cacheState).State) | $(($script:cacheState).Text)"
            $lines += "cacheDir=$($script:cacheDir)"
            $lines += "dataDir=$($script:dataDir)"
            Set-Content -Path $env:GTA6_LAUNCHER_SELFTEST -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_SELFTEST -Value ("ERR " + $_.Exception.Message) }
        $form.Close()
    }
})

$lblAuthor = New-Label '作者: DKTTT (github.com/DKTTT)  ·  基于 VIctory 社区项目 (avatarmanz / trustno1-coder / fxceless / codec-d)  ·  v1.0' 16 776 1012 20 8.5 $Muted
$form.Controls.Add($lblAuthor)
Add-Log 'GTA VI 自动启动器 v1.9.0 by DKTTT'
[void]$form.ShowDialog()
