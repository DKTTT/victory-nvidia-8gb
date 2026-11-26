# GTA VI PC 移植 - 自动检测启动器 v1.9.8
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
$ProgressPreference = 'SilentlyContinue'   # 下载时不弹蓝色进度条
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'launcher-config.json'

# 传参给 exe 时必须自己加引号：Start-Process -ArgumentList 不会替带空格的路径加，
# 结果 victory 把 "D:\Game\GTA6 Xbox ...\shaders.rpf" 按空格切成好几个参数（unexpected argument 'Xbox'）
function Quote-Arg([string]$s) {
    if (-not $s) { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    # 结尾是反斜杠时，引号会被转义：补一个反斜杠保住
    if ($s.EndsWith('\')) { return '"' + $s + '\"' }
    return '"' + ($s -replace '"', '\"') + '"'
}

# 纯字符串拼路径：不碰文件系统，盘符不存在也不会报错（Join-Path 会抛 DriveNotFoundException）
function Combine-Path([string]$base, [string]$leaf) {
    try {
        if (-not $base) { $base = $Root }
        return [System.IO.Path]::Combine($base, $leaf)
    } catch {
        return [System.IO.Path]::Combine($Root, $leaf)
    }
}

# 配置里的盘还在不在（U 盘/移动盘/换机器时 D: 以外的盘可能不存在）
function Test-RootUsable([string]$path) {
    if (-not $path) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($path)
        $root = [System.IO.Path]::GetPathRoot($full)
        if (-not $root) { return $false }
        return (Test-Path $root)
    } catch { return $false }
}

# ---------------------------------------------------------------- 配置
# 注意：这里不放任何“作者机器上的路径”。留空 = 启动时自己扫描/就近创建。
$DefaultCfg = @{
    GameDir   = ''
    BuildRoot = ''
    CacheRoot = ''
    SaveRoot  = ''
    Repo      = 'DKTTT/victory-nvidia-8gb'
    Branch    = 'tools-and-patches'
    Console   = 'auto'
    Height    = 'auto'
    Build     = 'auto'
    Preset    = 'auto'
    RaceUrl   = 'https://vuyp.github.io/gta6-pc-race/src/data.json'
    KeyMap    = ''
    KeyMapOn  = $false
    RtOff     = $true
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
        $km = if ($txtKeyMap) { $txtKeyMap.Text } else { '' }
        # 界面上那两行示例注释不算用户配置（否则首次运行会把示例写进配置文件）
        if ($km -and ($km.TrimStart().StartsWith('# 每行一条'))) { $km = '' }
        $Cfg.KeyMap = $km
        $Cfg.KeyMapOn = if ($chkKeyAuto) { [bool]$chkKeyAuto.Checked } else { $false }
        $Cfg.RtOff = if ($chkRtOff) { [bool]$chkRtOff.Checked } else { $true }
        $Cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 路径自动检测（不依赖任何作者机器上的路径）
function Test-DirHasGame([string]$d) {
    if (-not $d) { return $false }
    try { return (Test-Path (Combine-Path $d 'game_scarlett_master.exe')) } catch { return $false }
}

# 列出「值得一看」的目录：各盘根、盘根下名字像游戏的目录（最多两层），数量有上限
function Get-DriveCandidates {
    $out = @()
    foreach ($drv in @(Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue)) {
        if (-not $drv.Root) { continue }
        if ($drv.Root -like '*:\*' -and -not (Test-Path $drv.Root)) { continue }
        $out += $drv.Root
        $tops = @()
        try { $tops = @(Get-ChildItem $drv.Root -Directory -EA SilentlyContinue) } catch { }
        $named = @($tops | Where-Object { $_.Name -match '(?i)gta|game|victory|console|steam|epic' })
        $others = @($tops | Where-Object { $_.Name -notmatch '(?i)gta|game|victory|console|steam|epic' } | Select-Object -First 40)
        foreach ($t in @($named + $others)) {
            $out += $t.FullName
            $subs = @()
            try { $subs = @(Get-ChildItem $t.FullName -Directory -EA SilentlyContinue | Select-Object -First 40) } catch { }
            foreach ($s in @($subs | Where-Object { $_.Name -match '(?i)gta|game|victory' })) { $out += $s.FullName }
        }
    }
    return @($out | Select-Object -Unique)
}

# 找游戏目录：含 game_scarlett_master.exe（shaders.rpf 同目录）
function Find-GameDir {
    foreach ($c in (Get-DriveCandidates)) {
        if (Test-DirHasGame $c) { return $c }
    }
    # 再深一层（比如 X:\Games\GTA6\xxx）
    foreach ($c in (Get-DriveCandidates)) {
        $subs = @()
        try { $subs = @(Get-ChildItem $c -Directory -EA SilentlyContinue | Select-Object -First 40) } catch { }
        foreach ($s in $subs) { if (Test-DirHasGame $s.FullName) { return $s.FullName } }
    }
    return ''
}

# 找构建根目录：含 */target/diag|release/victory.exe 的目录（只在这些候选里找，不整盘递归）
function Find-BuildRoot {
    $cands = @(Combine-Path $Root 'work', Combine-Path $Root 'gta6')
    foreach ($c in (Get-DriveCandidates)) {
        $cands += (Combine-Path $c 'work')
        $cands += (Combine-Path $c 'gta6')
        $cands += (Combine-Path $c 'downloaded')
    }
    foreach ($c in @($cands | Select-Object -Unique)) {
        if (-not (Test-Path $c)) { continue }
        try {
            $hit = @(Get-ChildItem $c -Recurse -Depth 4 -Filter 'victory.exe' -File -EA SilentlyContinue |
                Where-Object { $_.FullName -match '\\target\\(diag|release)\\victory\.exe$' } | Select-Object -First 1)
            if ($hit.Count -gt 0) { return $c }
        } catch { }
    }
    return ''
}

# 就近可写目录（启动器目录优先，写不进去就用 LocalAppData）
function Get-PortableRoot {
    $try = @((Combine-Path $Root 'gta6'), (Combine-Path $env:LOCALAPPDATA 'GTA6Launcher'))
    foreach ($p in $try) {
        try {
            New-Item -ItemType Directory -Force -Path $p -EA Stop | Out-Null
            $probe = Combine-Path $p ('.write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
            Set-Content -Path $probe -Value 'x' -EA Stop
            Remove-Item $probe -Force -EA SilentlyContinue
            return $p
        } catch { }
    }
    return (Combine-Path $env:TEMP 'gta6')
}

# 启动时把空/失效的路径补上（配置里留空或盘不存在都会走这里）
function Initialize-Paths {
    $det = @()
    if (-not (Test-DirHasGame $Cfg.GameDir)) {
        $found = Find-GameDir
        if ($found) {
            if ($Cfg.GameDir) { $det += ("游戏目录改用它: {0}（原 {1} 不对）" -f $found, $Cfg.GameDir) } else { $det += ("自动找到游戏目录: {0}" -f $found) }
            $Cfg.GameDir = $found
        } elseif ($Cfg.GameDir) {
            $det += ("游戏目录 {0} 里没有 game_scarlett_master.exe，请手动选" -f $Cfg.GameDir)
        } else {
            $det += '没自动找到游戏目录，请在①页手动选（含 game_scarlett_master.exe 的那层）'
        }
    }
    if (-not $Cfg.BuildRoot -or -not (Test-Path $Cfg.BuildRoot)) {
        $found = Find-BuildRoot
        if ($found) {
            if ($Cfg.BuildRoot) { $det += ("构建根目录改用它: {0}（原 {1} 不存在）" -f $found, $Cfg.BuildRoot) } else { $det += ("自动找到构建根目录: {0}" -f $found) }
            $Cfg.BuildRoot = $found
        } elseif ($Cfg.BuildRoot) {
            $det += ("构建根目录 {0} 不存在，请手动选" -f $Cfg.BuildRoot)
            $Cfg.BuildRoot = ''
        } else {
            $det += '没自动找到本地构建，可在①页选构建根目录，或用②页下载/编译'
        }
    }
    $portable = ''
    if (-not $Cfg.CacheRoot -or -not (Test-RootUsable $Cfg.CacheRoot)) {
        if (-not $portable) { $portable = Get-PortableRoot }
        $det += ("缓存根目录: {0}（放在启动器旁边，可改）" -f $portable)
        $Cfg.CacheRoot = $portable
    }
    if (-not $Cfg.SaveRoot -or -not (Test-RootUsable $Cfg.SaveRoot)) {
        if (-not $portable) { $portable = Get-PortableRoot }
        $save = Combine-Path $portable 'work'
        New-Item -ItemType Directory -Force -Path $save -EA SilentlyContinue | Out-Null
        $det += ("存档根目录: {0}（放在启动器旁边，可改）" -f $save)
        $Cfg.SaveRoot = $save
    }
    return $det
}
# 路径补全（空 = 自己扫描；失效 = 重新扫描。不写死任何作者机器上的路径）
$script:pathNotes = @()
try { $script:pathNotes = @(Initialize-Paths) } catch { $script:pathNotes = @('路径自动检测出错: ' + $_.Exception.Message) }

# ---------------------------------------------------------------- 构建元数据 / 版本检测 / 预热记录
# v1.9.1 起，缓存是否可用不再看 exe 修改时间（重新编译后必然误判“过期”），而看三样东西：
#   1) 预热记录 launcher-warm.json —— 写在缓存目录里（跟着缓存走，换目录/重扫工程都不会丢）
#   2) 版本指纹 —— 翻译器源码指纹（仿 victory-gpu/build.rs 的输入）+ git commit + 显卡驱动版本
#   3) 缓存文件本身 —— shaders 子目录、pipelines\warm-done.txt 里当前指纹的行数
$script:metaPath = Join-Path $Root 'builds-meta.json'
$script:markerName = 'launcher-warm.json'
$script:trIdCache = @{}
$script:driverVer = ''

function Get-NormPath([string]$p) {
    if (-not $p) { return '' }
    $s = $p.Trim()
    try { $s = [System.IO.Path]::GetFullPath($s) } catch { }
    return $s.TrimEnd([char[]]"\/").ToLowerInvariant()
}

function Get-StringHash([string]$s) {
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
        $hex = ($h | ForEach-Object { $_.ToString('x2') }) -join ''
        return $hex.Substring(0, 16)
    } catch { return '' }
}

# 源码树签名（文件数+总字节+最新修改时间）+ 相关文件时间：用来判断缓存的翻译器指纹是否还新鲜
function Get-SourceSignature([string]$proj) {
    $parts = @()
    $src = ''
    if ($proj) { $src = Join-Path $proj 'crates\victory-shader\src' }
    if ($src -and (Test-Path $src)) {
        try {
            $files = @(Get-ChildItem $src -Recurse -File -EA SilentlyContinue)
            $sum = 0; $max = 0
            foreach ($f in $files) { $sum += $f.Length; if ($f.LastWriteTimeUtc.Ticks -gt $max) { $max = $f.LastWriteTimeUtc.Ticks } }
            $parts += ("{0}:{1}:{2}" -f $files.Count, $sum, $max)
        } catch { }
    }
    foreach ($rel in @('crates\victory-shader\Cargo.toml', 'crates\victory-gpu\src\shader_cache.rs', 'Cargo.lock', 'rust-toolchain.toml')) {
        $q = ''
        if ($proj) { $q = Join-Path $proj $rel }
        if ($q -and (Test-Path $q)) {
            try { $fi = Get-Item $q; $parts += ("{0}:{1}" -f $fi.Length, $fi.LastWriteTimeUtc.Ticks) } catch { }
        }
    }
    return ($parts -join '|')
}

# 翻译器指纹：有源码就按 victory-gpu/build.rs 的输入算（victory-shader 的源文件 + Cargo.lock 等），
# 没有源码（预编译包）就退回 exe 内容。同一个翻译器 → 同一个指纹，重新编译不会变。
function Get-TranslatorId([string]$proj, [string]$exe) {
    # 缓存键含文件时间（便宜、用于失效），返回值只含内容（稳定、不会因重新编译/复制就变）
    $sig = Get-SourceSignature $proj
    $exeSig = ''
    if ($exe -and (Test-Path $exe)) {
        try { $fi0 = Get-Item $exe; $exeSig = ("{0}:{1}" -f $fi0.Length, $fi0.LastWriteTimeUtc.Ticks) } catch { }
    }
    $ck = (Get-NormPath $proj) + '|' + (Get-NormPath $exe) + '|' + $sig + '|' + $exeSig
    if ($script:trIdCache.ContainsKey($ck)) { return $script:trIdCache[$ck] }
    if ($script:trIdCache.Count -gt 64) { $script:trIdCache.Clear() }
    $id = ''
    $src = ''
    if ($proj) { $src = Join-Path $proj 'crates\victory-shader\src' }
    if ($src -and (Test-Path $src)) {
        try {
            $files = @(Get-ChildItem $src -Recurse -File -EA SilentlyContinue)
            foreach ($rel in @('crates\victory-shader\Cargo.toml', 'crates\victory-gpu\src\shader_cache.rs', 'Cargo.lock', 'rust-toolchain.toml')) {
                $q = Join-Path $proj $rel
                if (Test-Path $q) { $files += (Get-Item $q) }
            }
            $sb = New-Object System.Text.StringBuilder
            foreach ($f in @($files | Sort-Object FullName)) {
                try { [void]$sb.Append($f.Name).Append(':').Append($f.Length).Append(':').Append((Get-FileHash $f.FullName -Algorithm SHA256).Hash).Append("`n") } catch { }
            }
            $h = Get-StringHash $sb.ToString()
            if ($h) { $id = 'src' + $h }
        } catch { $id = '' }
    }
    if (-not $id -and $exe -and (Test-Path $exe)) {
        try {
            $fi = Get-Item $exe
            $id = 'exe' + (Get-StringHash ("{0}:{1}" -f $fi.Length, (Get-FileHash $exe -Algorithm SHA256).Hash))
        } catch { $id = '' }
    }
    $script:trIdCache[$ck] = $id
    return $id
}

function ConvertTo-TimeOrNull($v) {
    if (-not $v) { return $null }
    try { return [datetime]$v } catch { return $null }
}

# commit 可能是短 sha（7 位）也可能是完整 sha：按前缀比较，别把同一个提交判成“构建已更新”
function Test-CommitSame([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $true }
    $x = $a.Trim().ToLowerInvariant()
    $y = $b.Trim().ToLowerInvariant()
    $n = [math]::Min($x.Length, $y.Length)
    if ($n -lt 4) { return ($x -eq $y) }
    return ($x.Substring(0, $n) -eq $y.Substring(0, $n))
}

function Format-TimeShort($t) {
    if (-not $t) { return '?' }
    return $t.ToString('MM-dd HH:mm')
}

function Get-Meta {
    if (-not (Test-Path $script:metaPath)) { return @{} }
    try {
        $raw = Get-Content $script:metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $h = @{}
        foreach ($p in $raw.PSObject.Properties) {
            $v = $p.Value
            if ($null -eq $v) { continue }
            $proj = $p.Name
            try { if ($v.project) { $proj = [string]$v.project } } catch { }
            $key = Get-NormPath $proj
            if (-not $key) { continue }
            # 同一工程有多条记录：留预热时间更新的那条（旧版本按不同写法存过 key）
            if ($h.ContainsKey($key)) {
                $old = $h[$key]
                $tn = ConvertTo-TimeOrNull $v.prewarmTime
                $to = ConvertTo-TimeOrNull $old.prewarmTime
                if ($tn -and (-not $to -or $tn -gt $to)) { $h[$key] = $v }
            } else { $h[$key] = $v }
        }
        return $h
    } catch { return @{} }
}

function Save-Meta($m) {
    try {
        $out = @{}
        foreach ($k in @($m.Keys)) {
            if ($null -eq $m[$k]) { continue }
            $out[(Get-NormPath $k)] = $m[$k]
        }
        $out | ConvertTo-Json -Depth 6 | Set-Content -Path $script:metaPath -Encoding UTF8
    } catch { }
}

# 老版本 meta 只有工程路径作 key；这里做兼容查找：工程路径 → exe 路径 → 缓存目录
function Find-MetaEntry($meta, [string]$proj, [string]$exe, [string]$cacheDir) {
    if (-not $meta -or $meta.Count -eq 0) { return $null }
    $p = Get-NormPath $proj
    if ($p -and $meta.ContainsKey($p)) { return $meta[$p] }
    $e = Get-NormPath $exe
    $c = Get-NormPath $cacheDir
    $byExe = $null; $byCache = $null
    foreach ($k in @($meta.Keys)) {
        $v = $meta[$k]
        if ($null -eq $v) { continue }
        if (-not $byExe -and $e) {
            try { if ($v.exe -and ((Get-NormPath ([string]$v.exe)) -eq $e)) { $byExe = $v } } catch { }
        }
        if (-not $byCache -and $c) {
            try { if ($v.cache -and ((Get-NormPath ([string]$v.cache)) -eq $c)) { $byCache = $v } } catch { }
        }
        if ($byExe -and $byCache) { break }
    }
    if ($byExe) { return $byExe }
    if ($byCache) { return $byCache }
    return $null
}

# 预热记录：跟着缓存目录走，换工程路径/重扫都不会读不到
function New-WarmRecord {
    return [pscustomobject]@{
        Project = ''; Exe = ''; Commit = ''; Translator = ''; Driver = ''; BuildTime = ''
        ShadersDone = $false; ShadersComplete = $false; ShadersTime = ''; ShadersCount = 0
        ShadersUnsupported = $false; PipesUnsupported = $false;
        PipesDone = $false; PipesComplete = $false; PipesTime = ''; PipesFingerprint = ''; PipesLines = 0; PipesRefused = 0
    }
}

function Get-WarmMarker([string]$cacheDir) {
    if (-not $cacheDir) { return $null }
    $p = Join-Path $cacheDir $script:markerName
    if (-not (Test-Path $p)) { return $null }
    try {
        $raw = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = New-WarmRecord
        $o.Project = [string]$raw.project; $o.Exe = [string]$raw.exe
        $o.Commit = [string]$raw.commit; $o.Translator = [string]$raw.translator
        $o.Driver = [string]$raw.driver; $o.BuildTime = [string]$raw.buildTime
        $o.ShadersDone = [bool]$raw.shadersDone; $o.ShadersTime = [string]$raw.shadersTime
        $o.ShadersComplete = [bool]$raw.shadersComplete
        $o.ShadersCount = [int]$raw.shadersCount
        $o.PipesDone = [bool]$raw.pipesDone; $o.PipesTime = [string]$raw.pipesTime
        $o.PipesComplete = [bool]$raw.pipesComplete
        $o.ShadersUnsupported = [bool]$raw.shadersUnsupported
        $o.PipesUnsupported = [bool]$raw.pipesUnsupported
        $o.PipesFingerprint = [string]$raw.pipesFingerprint; $o.PipesLines = [int]$raw.pipesLines; $o.PipesRefused = [int]$raw.pipesRefused
        return $o
    } catch { return $null }
}

function Save-WarmMarker([string]$cacheDir, $o) {
    if (-not $cacheDir -or -not $o) { return }
    try {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $obj = [ordered]@{
            version        = 1
            project        = $o.Project
            exe            = $o.Exe
            commit         = $o.Commit
            translator     = $o.Translator
            driver         = $o.Driver
            buildTime      = $o.BuildTime
            shadersDone    = [bool]$o.ShadersDone
            shadersComplete = [bool]$o.ShadersComplete
            shadersTime    = $o.ShadersTime
            shadersCount   = [int]$o.ShadersCount
            shadersUnsupported = [bool]$o.ShadersUnsupported
            pipesUnsupported   = [bool]$o.PipesUnsupported
            pipesDone      = [bool]$o.PipesDone
            pipesComplete  = [bool]$o.PipesComplete
            pipesTime      = $o.PipesTime
            pipesFingerprint = $o.PipesFingerprint
            pipesLines     = [int]$o.PipesLines
            pipesRefused   = [int]$o.PipesRefused
            updated        = (Get-Date).ToString('o')
        }
        ($obj | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $cacheDir $script:markerName) -Encoding UTF8
    } catch { }
}

# 缓存目录里到底有什么：shaders 的桶目录、warm-done.txt 的行（按指纹分组）、
# 以及「本机跑图用到的管线里还有多少条没编译」（early-pipelines.txt 差集）
# 读 RT 清单：逗号/换行分隔，只保留 16 位十六进制（和引擎 parse_skip_hashes 的规则一致）
function Get-RtSkipHashes([string]$file) {
    if (-not $file -or -not (Test-Path $file)) { return @() }
    try {
        $raw = (Get-Content $file -Raw) -replace "`r?`n", ','
        return @($raw -split ',' | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^[0-9a-fA-F]{16}$' } |
            ForEach-Object { $_.ToLower() } | Select-Object -Unique)
    } catch { return @() }
}

function Get-WarmArtifacts([string]$cacheDir, [string]$fingerprint) {
    $a = [pscustomobject]@{
        ShaderDirs = 0; ShaderFiles = 0
        PipesFile = ''; PipesLines = 0; PipesTime = $null; PipesBytes = 0
        FpLines = 0; FpFirst = ''; FpLast = ''
        EarlyCount = 0; MissingEarly = -1
    }
    if (-not $cacheDir) { return $a }
    $sh = Join-Path $cacheDir 'shaders'
    if (Test-Path $sh) {
        try {
            $dirs = [System.IO.Directory]::GetDirectories($sh)
            $a.ShaderDirs = $dirs.Count
            $n = 0
            foreach ($d in $dirs) { $n += ([System.IO.Directory]::GetFiles($d)).Length }
            $a.ShaderFiles = $n
        } catch { }
    }
    $wf = Join-Path $cacheDir 'pipelines\warm-done.txt'
    if (Test-Path $wf) {
        try {
            $fi = Get-Item $wf
            $a.PipesFile = $wf; $a.PipesBytes = $fi.Length; $a.PipesTime = $fi.LastWriteTime
            $lines = @([System.IO.File]::ReadAllLines($wf))
            $a.PipesLines = $lines.Count
            $group = @{}
            $done = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($ln in $lines) {
                $sp = $ln.IndexOf(' ')
                if ($sp -le 0) { continue }
                $fp = $ln.Substring(0, $sp)
                if (-not $a.FpFirst) { $a.FpFirst = $fp }
                $a.FpLast = $fp
                if (-not $group.ContainsKey($fp)) { $group[$fp] = 0 }
                $group[$fp] = $group[$fp] + 1
                if ($fingerprint -and ($fp -eq $fingerprint)) { [void]$done.Add($ln.Substring($sp + 1).Trim()) }
            }
            if ($fingerprint -and $group.ContainsKey($fingerprint)) { $a.FpLines = [int]$group[$fingerprint] }
            $ef = Join-Path $cacheDir 'pipelines\early-pipelines.txt'
            if ($fingerprint -and $done.Count -gt 0 -and (Test-Path $ef)) {
                $early = @([System.IO.File]::ReadAllLines($ef))
                $a.EarlyCount = $early.Count
                $miss = 0
                foreach ($k in $early) { $k = $k.Trim(); if ($k -and -not $done.Contains($k)) { $miss++ } }
                $a.MissingEarly = $miss
            }
        } catch { }
    }
    return $a
}

function Get-CacheState([string]$proj, [datetime]$exeTime, [string]$translator, [string]$cacheDir, [string]$commit = '', [string]$exe = '', [string]$driver = '') {
    $trId = if ($translator) { [string]$translator } else { [string](Get-TranslatorId $proj $exe) }
    if (-not $driver) { $driver = [string]$script:driverVer }
    $mk = Get-WarmMarker $cacheDir
    $meta = Get-Meta
    $me = Find-MetaEntry $meta $proj $exe $cacheDir
    $fp = ''
    if ($mk -and $mk.PipesFingerprint) { $fp = [string]$mk.PipesFingerprint }
    elseif ($me) { try { if ($me.pipesFingerprint) { $fp = [string]$me.pipesFingerprint } } catch { } }
    $art = Get-WarmArtifacts $cacheDir $fp
    $pipeCount = if ($fp) { [int]$art.FpLines } else { [int]$art.PipesLines }

    # ---- 证据：缓存里到底有没有东西
    $hasShaders = (([int]$art.ShaderDirs) -ge 8) -and (([int]$art.ShaderFiles) -gt 0)
    $hasPipes = ([int]$art.PipesLines) -gt 0
    if ($fp) { $hasPipes = $hasPipes -and (([int]$art.FpLines) -gt 0) }

    # ---- 记录（marker 优先，其次旧版 meta）
    $src = 'file'
    $recTr = ''; $recCommit = ''; $recDriver = ''
    $shTime = $null; $shCount = 0; $pipeTime = $null
    $shComplete = $true; $pipesComplete = $true; $pipesRefused = 0
    if ($mk) {
        $src = 'record'
        $recTr = [string]$mk.Translator; $recCommit = [string]$mk.Commit; $recDriver = [string]$mk.Driver
        if ($mk.ShadersDone) { $shTime = ConvertTo-TimeOrNull $mk.ShadersTime; $shCount = [int]$mk.ShadersCount }
        if ($mk.PipesDone) { $pipeTime = ConvertTo-TimeOrNull $mk.PipesTime }
        $shComplete = [bool]$mk.ShadersComplete
        $pipesComplete = [bool]$mk.PipesComplete
        $pipesRefused = [int]$mk.PipesRefused
        # 记录说“完成”但缓存里根本没有对应文件（预热其实没跑起来/被参数顶掉）→ 不能算完成
        if ($shComplete -and -not $hasShaders) { $shComplete = $false }
        if ($pipesComplete -and -not $hasPipes) { $pipesComplete = $false }
    } elseif ($me) {
        $src = 'meta'
        try { $recTr = [string]$me.translator } catch { }
        try { $recCommit = [string]$me.commit } catch { }
        try { $recDriver = [string]$me.driver } catch { }
        $t = ConvertTo-TimeOrNull $me.prewarmTime
        if ($t) { $shTime = $t; $pipeTime = $t }
    }

    $why = @()
    if ($recTr -and $trId -and ($recTr -ne $trId)) { $why += "翻译器或构建已变化($recTr→$trId)" }
    if ($recCommit -and $commit -and (-not (Test-CommitSame $recCommit $commit))) { $why += "构建已更新($recCommit→$commit)" }
    if ($recDriver -and $driver -and ($recDriver -ne $driver)) { $why += "显卡驱动已更新($recDriver→$driver)" }

    $details = @(
        ("src={0}" -f $src),
        ("build={0}" -f $(if ($exeTime) { $exeTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })),
        ("warmShaders={0}" -f $(if ($shTime) { $shTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })),
        ("warmPipes={0}" -f $(if ($pipeTime) { $pipeTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })),
        ("translator={0}" -f $trId),
        ("recTranslator={0}" -f $recTr),
        ("commit={0}" -f $commit),
        ("recCommit={0}" -f $recCommit),
        ("driver={0}" -f $driver),
        ("recDriver={0}" -f $recDriver),
        ("pipesFingerprint={0}" -f $fp),
        ("warmDoneLines={0}" -f $art.PipesLines),
        ("fpLines={0}" -f $art.FpLines),
        ("missingEarly={0}" -f $art.MissingEarly),
        ("shadersComplete={0}" -f $shComplete),
        ("pipesComplete={0}" -f $pipesComplete),
        ("shaderDirs={0}" -f $art.ShaderDirs),
        ("shaderFilesProbe={0}" -f $art.ShaderFiles),
        ("shaderCount={0}" -f $shCount),
        ("hasShaders={0}" -f $hasShaders),
        ("hasPipes={0}" -f $hasPipes),
        ("cacheDir={0}" -f $cacheDir)
    )
    $reasonTxt = if ($why.Count -gt 0) { $why -join '，' } else { '' }

    if (-not $hasShaders -and -not $hasPipes) {
        $text = if ($why.Count -gt 0) { "缓存目录是空的（$reasonTxt），需要重新「全部预热」" } else { '从未预热过，首次启动前必须预热（点「全部预热」，约 10-40 分钟）' }
        return [pscustomobject]@{ State = 'never'; Text = $text; Details = $details; Reasons = $why; WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
    }
    if ($why.Count -gt 0) {
        return [pscustomobject]@{ State = 'stale'; Text = ("⚠ {0}，缓存已失效：请重新「全部预热」" -f $reasonTxt); Details = $details; Reasons = $why; WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
    }
    # 旧版 victory.exe 没有 warm / shaders 子命令：不是"没预热"，是这套构建做不了
    if ($mk -and ($mk.PipesUnsupported -or $mk.ShadersUnsupported)) {
        $what = @()
        if ($mk.ShadersUnsupported) { $what += '着色器翻译' }
        if ($mk.PipesUnsupported) { $what += '管线预编译' }
        return [pscustomobject]@{ State = 'partial'; Text = ("这个构建不支持{0}（victory.exe 没有对应子命令，属于旧版构建）：换 20261126a/b 包或新编译的构建" -f ($what -join '、')); Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
    }
    if (-not ($recTr -or $recCommit -or $recDriver)) {
        # 旧缓存：没有版本记录，只能按文件时间判断（给 2 分钟容差）
        $newest = $null
        foreach ($t in @($shTime, $pipeTime, $art.PipesTime)) {
            if ($t -and (-not $newest -or $t -gt $newest)) { $newest = $t }
        }
        if ($newest -and $exeTime -and ($exeTime -gt $newest.AddSeconds(120))) {
            return [pscustomobject]@{ State = 'stale'; Text = ("⚠ 构建（{0}）比缓存（{1}）新，建议重新「全部预热」" -f (Format-TimeShort $exeTime), (Format-TimeShort $newest)); Details = $details; Reasons = @('exe 比缓存新'); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
        }
    }
    $when = $pipeTime
    if (-not $when) { $when = $shTime }
    if (-not $when) { $when = $art.PipesTime }
    if ($hasShaders -and $hasPipes) {
        # 只有「没记成完成」时，差集才算“没跑完”；跑完过（含剩下被驱动拒绝的）只作提示
        if (([int]$art.MissingEarly) -gt 0 -and -not $pipesComplete) {
            return [pscustomobject]@{ State = 'partial'; Text = ("管线预热未完成：还差 {0} 条（可点「预编译管线」续传）· 着色器已就绪" -f $art.MissingEarly); Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
        }
        $cnt = if ($shCount -gt 0) { "着色器 {0} 个 · " -f $shCount } elseif (([int]$art.ShaderFiles) -gt 0) { "着色器 {0} 个 · " -f $art.ShaderFiles } else { '着色器已就绪 · ' }
        if (-not ($shComplete -and $pipesComplete)) {
            # 只报「真的没跑完」的：管线差几条用引擎的差集算，跑完过就不算
            if (-not $pipesComplete -and ([int]$art.MissingEarly) -gt 0) {
                return [pscustomobject]@{ State = 'partial'; Text = ("管线预热未完成：还差 {0} 条（可点「预编译管线」续传）· 着色器已就绪" -f $art.MissingEarly); Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
            }
            $what = @()
            if (-not $shComplete) { $what += '着色器' }
            if (-not $pipesComplete) { $what += '管线' }
            $txt = ("缓存可用（管线 {0} 条），但{1}上次没跑完：可再点「全部预热」续传" -f $pipeCount, ($what -join '、'))
            return [pscustomobject]@{ State = 'partial'; Text = $txt; Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
        }
        # 跑完过：之后游戏又用到新管线只算提示，不再判「没预热」
        $extra = ''
        if ([int]$pipesRefused -gt 0) { $extra += ("；另有 {0} 条被驱动/引擎拒绝编译（不影响已完成的缓存）" -f $pipesRefused) }
        # 只有多出来的（不是那几条“编不出来”的）才提示“之后又用到新管线”，别重复计数`r`n        if (([int]$art.MissingEarly) -gt [int]$pipesRefused) { $extra += ("；之后游戏又用到 {0} 条新管线，想更顺可再点「预编译管线」" -f ($art.MissingEarly - $pipesRefused)) }
        return [pscustomobject]@{ State = 'ok'; Text = ("缓存就绪（{0}管线 {1} 条 · 预热 {2}{3}）" -f $cnt, $pipeCount, (Format-TimeShort $when), $extra); Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
    }
    if ($hasPipes) {
        return [pscustomobject]@{ State = 'partial'; Text = ("已预编译管线（{0} 条），着色器未预翻译：首局会编译着色器，卡顿属正常" -f $pipeCount); Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
    }
    return [pscustomobject]@{ State = 'partial'; Text = '已预翻译着色器，管线未预编译：首局首次出现的特效会顿一下'; Details = $details; Reasons = @(); WarmShaders = $shTime; WarmPipes = $pipeTime; HasShaders = $hasShaders; HasPipes = $hasPipes; Fingerprint = $fp; MissingEarly = $art.MissingEarly }
}

# 预热结果判定（纯函数，便于自测）：不再依赖日志关键字
# $missing：跑完后按「引擎实际用到的管线」重新算的差集（-1 = 不知道）。
# 判断“跑完没跑完”用它，而不是用“开始时还有几条要做”——后者跑完也永远 >0。
function Get-WarmOutcome([string]$kind, $exitCode, [int]$toMake, [int]$shaderCount, [int]$preLines, [int]$postLines, [int]$preShaders, [int]$postShaders, [bool]$sawFingerprint, [int]$missing = -1) {
    $codeOk = ($null -eq $exitCode) -or ("$exitCode" -eq '') -or ([string]$exitCode -eq '0')
    $grew = ($postLines -gt $preLines) -or ($postShaders -gt $preShaders)
    if ($kind -eq 'pipelines') {
        if ($missing -eq 0) { return [pscustomobject]@{ Done = $true; Complete = $true; Note = '用到的管线已全部编译' } }
        if ($missing -gt 0) {
            $done = ($grew -or $codeOk -or $sawFingerprint -or ($toMake -eq 0))
            return [pscustomobject]@{ Done = $done; Complete = $false; Note = ("还差 {0} 条（可续传）" -f $missing) }
        }
        # 拿不到差集：退回“开始时还有几条要做”
        # 注意：空缓存上 warm 也会报 “0 to make”，那只是“还没有管线记录”，不是“全编完了”
        if ($toMake -eq 0) {
            if ($postLines -gt 0) { return [pscustomobject]@{ Done = $true; Complete = $true; Note = '全部管线都已编译' } }
            return [pscustomobject]@{ Done = $true; Complete = $false; Note = '缓存里还没有任何管线记录：先启动一次游戏玩几分钟，再点「预编译管线」才有意义' }
        }
        if ($grew) { return [pscustomobject]@{ Done = $true; Complete = $false; Note = '已编译一部分（可续传）' } }
        if ($codeOk -and $sawFingerprint) { return [pscustomobject]@{ Done = $true; Complete = $false; Note = '引擎报告无需再编译' } }
        return [pscustomobject]@{ Done = $false; Complete = $false; Note = ("没有产出（退出码 {0}）" -f $(if ("$exitCode" -eq '') { '无' } else { $exitCode })) }
    }
    if ($codeOk -and ($shaderCount -gt 0 -or $grew)) { return [pscustomobject]@{ Done = $true; Complete = $true; Note = ("已翻译 {0} 个着色器" -f $shaderCount) } }
    if ($grew -or $shaderCount -gt 0) { return [pscustomobject]@{ Done = $true; Complete = $false; Note = '着色器已翻译一部分（可续传）' } }
    return [pscustomobject]@{ Done = $false; Complete = $false; Note = ("没有产出（退出码 {0}）" -f $(if ("$exitCode" -eq '') { '无' } else { $exitCode })) }
}
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
    $dlDefault = if ($Cfg.BuildRoot) { Combine-Path $Cfg.BuildRoot 'downloaded' } else { Combine-Path (Combine-Path $Root 'gta6') 'downloaded' }
    if (-not $Cfg.BuildRoot) { $dlDefault = Combine-Path $Root 'downloaded' }
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
    $tabRun.Controls.Add((New-Label '预热（首次/更新后执行一次；「全部预热」= 先着色器、自动接管线两步）' 14 12 700 22 10))
$btnWarmShaders = New-Btn '预热着色器' 14 40 160 38
$btnWarmPipes = New-Btn '预编译管线' 184 40 160 38
$btnWarmAll = New-Btn '全部预热' 354 40 160 38 $Accent
$btnStop = New-Btn '停止' 524 40 100 38
$btnCheckCache = New-Btn '检查预热状态' 634 40 160 38
$tabRun.Controls.Add($btnWarmShaders); $tabRun.Controls.Add($btnWarmPipes); $tabRun.Controls.Add($btnWarmAll); $tabRun.Controls.Add($btnStop); $tabRun.Controls.Add($btnCheckCache)

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
# 关光追：跳过 RT 绘制（按 shader 哈希匹配，A 卡 / N 卡通用；引擎侧只在 diag 构建生效）
$chkRtOff = New-Object System.Windows.Forms.CheckBox
$chkRtOff.Text = '关闭光追（跳过 RT 绘制，A/N 卡通用）'
$chkRtOff.Location = New-Object System.Drawing.Point(330, 214)
$chkRtOff.Size = New-Object System.Drawing.Size(420, 24)
$chkRtOff.ForeColor = $TextCol; $chkRtOff.BackColor = $Bg; $chkRtOff.Checked = $true
$tabRun.Controls.Add($chkRtOff)
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
# 这一行经常比窗口宽（以前会被截断）：换成可横向滚动的只读框，一个字都不丢
$lblLocalBuilds = New-Object System.Windows.Forms.TextBox
$lblLocalBuilds.Location = New-Object System.Drawing.Point(384, 508)
$lblLocalBuilds.Size = New-Object System.Drawing.Size(644, 38)
$lblLocalBuilds.Multiline = $true
$lblLocalBuilds.WordWrap = $false
$lblLocalBuilds.ScrollBars = 'Horizontal'
$lblLocalBuilds.ReadOnly = $true
$lblLocalBuilds.TabStop = $false
$lblLocalBuilds.BorderStyle = 'FixedSingle'
$lblLocalBuilds.BackColor = [System.Drawing.Color]::FromArgb(16, 12, 28)
$lblLocalBuilds.ForeColor = $Muted
$lblLocalBuilds.Font = New-Object System.Drawing.Font('Consolas', 9)
$lblLocalBuilds.Text = '本地构建在榜：等待更新…'
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
$script:builds = @()
$script:projInfo = $null
$script:cacheState = $null
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
$script:warmStartedAt = $null
$script:warmBuild = $null
$script:warmBuildIdx = -1
$script:warmProj = ''
$script:warmExe = ''
$script:warmCacheDir = ''
$script:warmBuildTime = $null
$script:warmCommit = ''
$script:warmCommitFull = ''
$script:warmTrId = ''
$script:warmDriver = ''
$script:warmFp = ''
$script:warmToMake = -1
$script:warmKnown = 0
$script:warmMade = 0
$script:warmShaders = 0
$script:warmUnsupported = ''
$script:warmPre = $null
$script:autoStage = 0
$script:pipeRounds = 0
$script:pipeMissing = -1
$script:warmUseJobs = $true
$script:bgProc = $null
$script:bgJob = $null
$script:rootFallbackWarned = $false
$script:updateCtx = $null
$script:checkCtx = $null
$script:updateCompile = $false
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
# WMI 的 AdapterRAM 对 >4GB 的卡会截断/为 0：从显示适配器注册表读 qwMemorySize（字节）
function Get-VramFromRegistry([string]$gpuName, [int]$fallbackMB) {
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        if (-not (Test-Path $base)) { return $fallbackMB }
        $key = $gpuName
        if ($key -match '^(.*?)\s*\(([^)]+)\)\s*$') { $key = $matches[2] }   # 去掉 "Intel(R) UHD Graphics 630" 这种后缀
        foreach ($sub in @(Get-ChildItem $base -EA SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            try {
                $desc = [string](Get-ItemProperty $sub.PSPath -Name 'DriverDesc' -EA SilentlyContinue).DriverDesc
                if (-not $desc) { continue }
                $match = ($desc -eq $gpuName) -or ($desc -eq $key) -or ($gpuName -like "*$desc*") -or ($desc -like "*$key*")
                if (-not $match) { continue }
                $q = (Get-ItemProperty $sub.PSPath -Name 'HardwareInformation.qwMemorySize' -EA SilentlyContinue).'HardwareInformation.qwMemorySize'
                if ($null -ne $q) {
                    $mb = [int]([double]$q / 1MB)
                    if ($mb -gt 0) { return $mb }
                }
            } catch { }
        }
    } catch { }
    return $fallbackMB
}

# 显卡厂商判定：A 卡（AMD）、N 卡（NVIDIA）、Intel 核显都要认
function Get-GpuVendor([string]$n) {
    if (-not $n) { return 'Unknown' }
    if ($n -match '(?i)NVIDIA|GeForce|Quadro|Tesla|\bRTX\b|\bGTX\b') { return 'NVIDIA' }
    if ($n -match '(?i)\bAMD\b|Radeon|ATI\b|FirePro|Instinct') { return 'AMD' }
    if ($n -match '(?i)Intel|\bArc\b|Iris|UHD|HD Graphics') { return 'Intel' }
    return 'Other'
}

# 双显卡机器（核显 + 独显）不能按枚举顺序取：优先 A/N 独显，其次显存大的
function Select-BestGpu($gpus) {
    $cand = @($gpus | Where-Object { $_ -and $_.Name -and $_.Name -notmatch '(?i)Microsoft Basic|Parsec|Virtual|Remote' })
    if ($cand.Count -eq 0) { return $null }
    $discrete = @($cand | Where-Object { (Get-GpuVendor $_.Name) -in @('NVIDIA', 'AMD') })
    $pick = if ($discrete.Count -gt 0) { $discrete } else { $cand }
    return ($pick | Sort-Object @{ Expression = { try { [int]$_.AdapterRAM } catch { 0 } } } -Descending | Select-Object -First 1)
}

function Detect-Hardware {
    $gpus = @()
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue | Select-Object Name, AdapterRAM, DriverVersion)
    } catch { }
    $cpu = $null; $ram = 0; $os = ''
    try { $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors } catch { }
    try { $cs = Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue; $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } catch { }
    try { $o = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue; $os = "$($o.Caption) build $($o.BuildNumber)" } catch { }

    $name = ''; $vendor = ''; $vramMB = 0; $driverVer = ''
    # N 卡优先用 nvidia-smi 取准确显存/驱动；A 卡没有等价工具，走 WMI + 注册表
    $nv = $null
    if (Get-Command nvidia-smi -EA SilentlyContinue) {
        try {
            $q = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null | Select-Object -First 1
            if ($q) { $parts = $q -split ','; $nv = @{ Name = $parts[0].Trim(); VramMB = [int]($parts[1] -replace '[^\d]', ''); Driver = $parts[2].Trim() } }
        } catch { }
    }
    if ($nv) {
        $name = $nv.Name; $vramMB = $nv.VramMB; $driverVer = $nv.Driver
        $vendor = 'NVIDIA'
    }
    if (-not $name) {
        $best = Select-BestGpu $gpus
        if ($best) {
            $name = [string]$best.Name
            $vendor = Get-GpuVendor $name
            try { $vramMB = [int]([math]::Round($best.AdapterRAM / 1MB)) } catch { }
            # WMI 的 AdapterRAM 对大于 4GB 的卡不可靠（A 卡尤其明显）：改读注册表 qwMemorySize
            $vramMB = Get-VramFromRegistry $name $vramMB
            if ($vramMB -le 0) { $vramMB = 0 }
            try { $driverVer = [string]$best.DriverVersion } catch { }
        }
    }
    if (-not $vendor) { $vendor = 'Unknown' }
    return [pscustomobject]@{
        GpuName = $name; Vendor = $vendor; VramMB = $vramMB; Driver = $driverVer
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
    if ($hw.Vendor -eq 'NVIDIA') { $build = 'nvidia'; $buildWhy = 'N 卡（NVIDIA）：用 NVIDIA 分支（wave32 兼容最好）' }
    elseif ($hw.Vendor -eq 'AMD') { $build = 'amd'; $buildWhy = 'A 卡（AMD/Radeon）：用上游主线（原生 wave64，无需模拟）' }
    elseif ($hw.Vendor -eq 'Intel') { $build = 'unknown'; $buildWhy = 'Intel 核显：不支持（需要 AMD RDNA2/NVIDIA 独显）；若有独显请确认它没被核显顶掉' }
    else { $build = 'unknown'; $buildWhy = '未知显卡：先按 NVIDIA 分支尝试，A 卡请手动选上游主线' }

    # A 卡显存普遍大（WMI 会截断到 4GB，已改读注册表），档位按显存给
    $height = 540
    if ($vramGB -ge 20) { $height = 1440 }
    elseif ($vramGB -ge 12) { $height = 1080 }
    elseif ($vramGB -ge 10) { $height = 720 }
    elseif ($vramGB -ge 7) { $height = 540 }
    else { $height = 480 }

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
    $script:driverVer = [string]$hw.Driver
    $lines = @()
    $lines += "使用显卡: $($hw.GpuName)"
    $lines += "厂商: $($hw.Vendor)（A 卡=AMD/Radeon，N 卡=NVIDIA）    显存: $([math]::Round($hw.VramMB/1024,1)) GB    驱动: $($hw.Driver)"
    $lines += "CPU : $($hw.CpuName)  ($($hw.CpuCores) 核 / $($hw.CpuThreads) 线程)"
    $lines += "内存: $($hw.RamGB) GB"
    $lines += "系统: $($hw.OS)"
    $others = @($hw.Gpus | Where-Object { $_.Name -and $_.Name -ne $hw.GpuName } | ForEach-Object { $_.Name })
    if ($others.Count -gt 0) { $lines += "其它显示适配器（未使用）: " + ($others -join '; ') }
    $txtHw.Text = $lines -join "`r`n"

    $rec = Recommend $hw
    $script:rec = $rec
    $recLines = @()
    $recName = switch ($rec.Build) {
        'nvidia' { 'NVIDIA 分支（vf-nvidia / vf-nv8gb）' }
        'amd'    { '上游主线（vf-main / upstream / 7900 / unified）' }
        default  { '未识别：先试 NVIDIA 分支，A 卡请手动选上游主线' }
    }
    $recLines += "推荐构建: $recName"
    $recLines += "推荐理由: $($rec.BuildWhy)"
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




function Get-BuildDirs([string]$name) {
    $cacheBase = ''
    $saveBase = ''
    try { $cacheBase = $tbCacheRoot.Text.Trim() } catch { }
    try { $saveBase = $tbSaveRoot.Text.Trim() } catch { }
    if (-not $cacheBase) { $cacheBase = $Root }
    if (-not $saveBase) { $saveBase = $cacheBase }
    # 盘不存在（比如配置里写着 E:\gta6，但这台机器只有 D:）→ 回退到启动器目录下，并提示一次
    if (-not (Test-RootUsable $cacheBase)) {
        $fallback = Combine-Path $Root 'gta6'
        if (-not $script:rootFallbackWarned) {
            $script:rootFallbackWarned = $true
            Add-Log ("缓存根目录 {0} 所在的盘不存在，暂时改用 {1}（可在①页改掉）" -f $cacheBase, $fallback)
        }
        $cacheBase = $fallback
    }
    if (-not (Test-RootUsable $saveBase)) {
        $fallback = Combine-Path (Combine-Path $Root 'gta6') 'work'
        if (-not $script:rootFallbackWarned) {
            $script:rootFallbackWarned = $true
            Add-Log ("存档根目录 {0} 所在的盘不存在，暂时改用 {1}（可在①页改掉）" -f $saveBase, $fallback)
        }
        $saveBase = $fallback
    }
    $known = @{
        'vf-nvidia' = @{ Cache = 'cache-nvidia'; Data = 'perf-data' }
        'vf-main'   = @{ Cache = 'cache-upstream'; Data = 'perf-data-up' }
        'cool_fox'  = @{ Cache = 'cache-coolfox'; Data = 'perf-data-cool' }
    }
    if ($known.ContainsKey($name)) {
        return @{ Cache = (Combine-Path $cacheBase $known[$name].Cache); Data = (Combine-Path $saveBase $known[$name].Data) }
    }
    return @{ Cache = (Combine-Path $cacheBase ("cache-" + $name)); Data = (Combine-Path $saveBase ("perf-data-" + $name)) }
}

# 这个构建支持哪些预热步骤（旧版 victory.exe 没有 warm / shaders 子命令）
function Get-BuildWarmCapability([string]$exe) {
    $sh = Test-ExeSub $exe 'shaders'
    $pi = Test-ExeSub $exe 'warm'
    $text = if ($sh -and $pi) { '' }
            elseif ($sh) { '该构建只支持着色器预热，不支持管线预编译' }
            elseif ($pi) { '该构建只支持管线预编译，不支持着色器预热' }
            else { '该构建不支持预热（victory.exe 没有 shaders / warm 子命令，旧版构建）' }
    return [pscustomobject]@{ Shaders = [bool]$sh; Pipes = [bool]$pi; None = (-not $sh -and -not $pi); Text = $text }
}

# 面板上的缓存状态：实时重算（预热完成后、启动前、点「检查预热状态」都走这里）
function Update-CacheStateLabel {
    if ($lstBuilds.SelectedIndex -lt 0 -or -not $script:builds) { return $null }
    $b = $script:builds[$lstBuilds.SelectedIndex]
    $dirs = Get-BuildDirs $b.Name
    $script:cacheDir = $dirs.Cache
    $script:dataDir = $dirs.Data
    $info = Get-ProjectInfo $b.Project
    $script:projInfo = $info
    $trId = Get-TranslatorId $b.Project $b.Exe
    $cache = Get-CacheState $b.Project $b.Time $trId $script:cacheDir $info.Commit $b.Exe $script:driverVer
    # 构建自己不支持预热：直接说清楚，别等点了才说“没产出”
    $cap = Get-BuildWarmCapability $b.Exe
    if ($cap.Text) {
        $cache.State = 'unsupported'
        $cache.Text = $cap.Text
        try { $lblStatus.Text = $cap.Text } catch { }
        try {
            if ($lstBuilds.SelectedIndex -ge 0 -and $lstBuilds.Items.Count -gt $lstBuilds.SelectedIndex) {
                $item = [string]$lstBuilds.Items[$lstBuilds.SelectedIndex]
                if ($item -notmatch '不支持预热') {
                    $lstBuilds.Items[$lstBuilds.SelectedIndex] = $item + '  [不支持预热]'
                }
            }
        } catch { }
    }
    $script:cacheState = $cache
    $ver = if ($info.Git) { "$($info.Branch)@$($info.Commit)" } else { '非 git 工程' }
    $tr = if ($trId) { "翻译器 $trId" } else { '翻译器指纹未知' }
    $lblBuildInfo.Text = "已选: $($script:buildName)  |  $ver  |  $tr  |  $($cache.Text)"
    return [pscustomobject]@{ State = $cache; Info = $info; TrId = $trId; Ver = $ver; Tr = $tr; Build = $b; Cap = $cap }
}

function Test-CacheStateNow {
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先选中一个构建'; return }
        $r = Update-CacheStateLabel
        if (-not $r) { return }
        $cs = $r.State
        Add-Log ("检查预热状态: {0} | {1}" -f $cs.State, $cs.Text)
        foreach ($d in $cs.Details) { Add-Log ("  " + $d) }
        $lblStatus.Text = $cs.Text
        if ($cs.State -eq 'unsupported') {
            Add-Log '这个 victory.exe 是旧版：换 20261126a/b 分发包，或用「更新并编译」升到含 warm 的版本'
        } elseif ($cs.State -eq 'never' -or $cs.State -eq 'stale') {
            Add-Log '建议：点「全部预热」（着色器 → 管线），完成后这里会显示“缓存就绪”'
        }
    } catch { Add-Log ("检查预热状态失败: " + $_.Exception.Message) }
}

function Select-Build {
    if ($lstBuilds.SelectedIndex -lt 0 -or -not $script:builds) { return }
    $b = $script:builds[$lstBuilds.SelectedIndex]
    $script:exe = $b.Exe
    $script:buildName = "$($b.Name) [$($b.Profile)]"
    $script:skipFile = Join-Path $b.Project 'scripts\rt_off_hashes.txt'
    $dirs = Get-BuildDirs $b.Name
    $script:cacheDir = $dirs.Cache
    $script:dataDir = $dirs.Data
    New-Item -ItemType Directory -Force -Path $script:cacheDir, $script:dataDir -EA SilentlyContinue | Out-Null
    Add-Log ("选中构建: {0} -> {1}" -f $script:buildName, $b.Exe)
    $r = Update-CacheStateLabel
    if ($r) {
        Add-Log ("  版本: {0}  {1}  {2}" -f $r.Ver, $r.Tr, $r.State.Text)
        foreach ($d in $r.State.Details) { Add-Log ("  " + $d) }
    }
}

# ---------------------------------------------------------------- 环境与启动
$script:exeCapCache = @{}
$script:subCache = @{}
# 解析 `victory --help` 的输出，判断某个子命令在不在（true/false；null = 看不出来）
function Test-HelpTextFor([string]$text, [string]$sub) {
    if (-not $text) { return $null }
    if ($text -match '(?im)unrecognized subcommand|invalid subcommand|not recognized|unknown command|unexpected argument') { return $false }
    if ($text -match ('(?im)^\s{0,6}' + [regex]::Escape($sub) + '\b')) { return $true }
    if ($text -match '(?im)^\s*Commands:') { return $false }
    return $null
}

# 这个 exe 支不支持某个子命令（旧版 victory.exe 没有 warm / shaders）。
# 跑一次 `exe --help`（clap 在 GPU 初始化之前就退出，实测 ~140ms），结果按 exe 缓存。
function Test-ExeSub([string]$exe, [string]$sub) {
    if (-not $exe -or -not (Test-Path $exe)) { return $true }
    $key = (Get-NormPath $exe) + '|' + $sub
    if ($script:subCache.ContainsKey($key)) { return $script:subCache[$key] }
    $res = $true
    $out = ''
    $err = ''
    try {
        $fi = Get-Item $exe
        $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $out = Join-Path $env:TEMP ("gta6-help-$tag.out.txt")
        $err = $out + '.err.txt'
        Remove-Item $out, $err -EA SilentlyContinue
        $p = Start-Process -FilePath $exe -ArgumentList @('--help') -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(6000)) { try { $p.Kill() } catch { } }
        $text = ''
        try { $text = [string](Get-Content $out -Raw -EA SilentlyContinue) + "`n" + [string](Get-Content $err -Raw -EA SilentlyContinue) } catch { }
        $verdict = Test-HelpTextFor $text $sub
        if ($null -ne $verdict) { $res = [bool]$verdict }
    } catch {
        $res = $true   # 探测失败就当支持，避免误伤
    } finally {
        try { Remove-Item $out, $err -Force -EA SilentlyContinue } catch { }
    }
    if ($script:subCache.Count -gt 100) { $script:subCache.Clear() }
    $script:subCache[$key] = $res
    return $res
}

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
    # 关光追：按 shader 哈希跳过 RT 绘制（与显卡厂商无关，A/N 卡通用）
    # 注意：引擎里这套代码是 diagnostics 特性才编进去的 → 只有 diag 构建生效，release 会忽略
    Remove-Item Env:VICTORY_SKIP_PIPELINES -EA SilentlyContinue
    try {
        $rtOn = $true
        try { $rtOn = [bool]$chkRtOff.Checked } catch { }
        if ($rtOn) {
            $rtFile = ''
            foreach ($cand in @($script:skipFile, (Combine-Path $Root 'rt_off_hashes.txt'))) {
                if ($cand -and (Test-Path $cand)) { $rtFile = $cand; break }
            }
            if (-not $rtFile) {
                Add-Log '关闭光追：这个构建没有带 rt_off_hashes.txt（scripts\ 下），本次不跳过任何绘制'
            } else {
                $hashes = @(Get-RtSkipHashes $rtFile)
                if ($hashes.Count -eq 0) {
                    Add-Log ("关闭光追：{0} 里没有有效哈希（要 16 位十六进制），本次不跳过任何绘制" -f $rtFile)
                } else {
                    $env:VICTORY_SKIP_PIPELINES = ($hashes -join ',')
                    Add-Log ("关闭光追：跳过 {0} 条 RT 管线（清单 {1}，A/N 卡通用）" -f $hashes.Count, (Split-Path $rtFile -Leaf))
                    if ($b.Profile -eq 'release') { Add-Log '  注意：跳过绘制只在 diag（诊断）构建生效，release 构建会忽略这个开关' }
                }
            }
        } else {
            Add-Log '关闭光追：已取消勾选 → 正常渲染光追'
        }
    } catch { Add-Log ("关闭光追设置失败: " + $_.Exception.Message) }
    return @{ Console = $console; Height = $height; Scale = $scale; Legacy = (-not $supportsScale) }
}

# 结束进程树：.NET Framework 的 Process.Kill 没有“整棵树”重载，
# 而 victory warm 会自己再开一堆 victory warm --these 子进程（占满 CPU、锁住缓存文件）
function Get-VictoryProcs {
    try { return @(Get-CimInstance Win32_Process -Filter "Name='victory.exe'" -EA SilentlyContinue) } catch { return @() }
}

function Get-VictoryWarmProcs {
    $out = @()
    foreach ($p in (Get-VictoryProcs)) {
        $cl = ''
        try { $cl = [string]$p.CommandLine } catch { }
        if ($cl -match '\bwarm\b') { $out += $p }
    }
    return $out
}

function Stop-ProcTree($proc) {
    if (-not $proc) { return 0 }
    $killed = 0
    try {
        $rootId = [int]$proc.Id
        $all = @(Get-CimInstance Win32_Process -EA SilentlyContinue)
        $kids = @{}
        foreach ($p in $all) {
            $pp = [int]$p.ParentProcessId
            if (-not $kids.ContainsKey($pp)) { $kids[$pp] = @() }
            $kids[$pp] += [int]$p.ProcessId
        }
        $victims = @()
        $stack = @($rootId)
        while ($stack.Count -gt 0) {
            $cur = [int]$stack[0]
            if ($stack.Count -gt 1) { $stack = @($stack[1..($stack.Count - 1)]) } else { $stack = @() }
            if ($kids.ContainsKey($cur)) {
                foreach ($c in $kids[$cur]) {
                    if ($victims -notcontains $c) { $victims += $c; $stack += $c }
                }
            }
        }
        foreach ($v in $victims) { try { Stop-Process -Id $v -Force -EA SilentlyContinue; $killed++ } catch { } }
        try { $proc.Kill() } catch { }
        try { Stop-Process -Id $rootId -Force -EA SilentlyContinue } catch { }
        if ($victims.Count -gt 0) { try { Wait-Process -Id $victims -Timeout 5 -EA SilentlyContinue } catch { } }
    } catch { }
    return $killed
}

# 清理上次异常退出留下的 warm 进程（否则会和新预热抢 CPU、锁文件，启动时报 0x80070005）
# 只清「孤儿」：父进程已经不在的。父进程还活着的说明是别人正在跑的预热，不动它（启动游戏时会被提示）
function Clear-StaleWarmProcs {
    $total = 0; $skipped = 0
    for ($pass = 0; $pass -lt 3; $pass++) {
        $warm = @(Get-VictoryWarmProcs)
        if ($warm.Count -eq 0) { break }
        $alive = @{}
        foreach ($p in @(Get-CimInstance Win32_Process -EA SilentlyContinue)) { $alive[[int]$p.ProcessId] = $true }
        $killedHere = 0
        foreach ($p in $warm) {
            $ppid = [int]$p.ParentProcessId
            $parentAlive = ($ppid -ne 0) -and $alive.ContainsKey($ppid) -and ($ppid -ne $PID)
            if ($parentAlive) { if ($pass -eq 0) { $skipped++ }; continue }
            try { Stop-Process -Id ([int]$p.ProcessId) -Force -EA SilentlyContinue; $total++; $killedHere++ } catch { }
        }
        if ($killedHere -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($total -gt 0) { Add-Log ("已清理上次残留的 warm 进程 {0} 个" -f $total) }
    if ($skipped -gt 0) { Add-Log ("另有 {0} 个 warm 进程的父进程还活着（判定为正在进行的预热，未结束）" -f $skipped) }
    return $total
}

function Start-Warm([string]$kind, [switch]$Auto) {
    try {
        if (-not $Auto) { $script:pipeRounds = 0; $script:pipeMissing = -1 }
        if ($script:proc -and -not $script:proc.HasExited) { Add-Log '预热已在运行'; return }
        if (-not $script:exe) { Add-Log '请先选择构建'; return }
        # 先问 exe 支不支持这些子命令：旧版 victory.exe 没有 warm / shaders，点了也是白点
        $cap = Get-BuildWarmCapability $script:exe
        $canShaders = $cap.Shaders
        $canPipes = $cap.Pipes
        if ($kind -eq 'pipelines' -and -not $canPipes) {
            $lblStatus.Text = '该构建不支持预热（管线预编译）'
            Add-Log ("预热[{0}] 跳过：{1}" -f $kind, $cap.Text)
            Add-Log '  → 换 20261126a/b 分发包，或用「更新并编译」把构建升到含 warm 的版本'
            return
        }
        if ($kind -eq 'shaders' -and -not $canShaders) {
            $lblStatus.Text = '该构建不支持预热（着色器翻译）'
            Add-Log ("预热[{0}] 跳过：{1}" -f $kind, $cap.Text)
            Add-Log '  → 换 20261126a/b 分发包，或用「更新并编译」把构建升到含 shaders 的版本'
            return
        }
        if ($kind -eq 'all') {
            if ($cap.None) {
                $lblStatus.Text = '该构建不支持预热'
                Add-Log ("该构建不支持预热：{0}" -f $cap.Text)
                Add-Log '  → 换 20261126a/b 分发包，或用「更新并编译」把构建升到新版本'
                return
            }
            if (-not $canShaders) { Add-Log '该构建不支持着色器翻译：跳过，只做管线预编译'; $kind = 'pipelines' }
            elseif (-not $canPipes) { Add-Log '该构建不支持管线预编译：只做着色器翻译'; $kind = 'shaders' }
        }
        $rpf = Combine-Path $tbGame.Text.Trim() 'shaders.rpf'
        if ($kind -ne 'pipelines' -and -not (Test-Path $rpf)) { Add-Log "找不到 $rpf"; return }
        $null = Build-Env
        [void](Clear-StaleWarmProcs)
        $stillWarm = @(Get-VictoryWarmProcs)
        if ($stillWarm.Count -gt 0) {
            $pids = (($stillWarm | ForEach-Object { [int]$_.ProcessId } | Select-Object -Unique) -join ', ')
            Add-Log ("已有预热进程在跑（PID: {0}），请先等它结束；不要同时开两个预热" -f $pids)
            $lblStatus.Text = '已有预热在运行'
            return
        }
        Remove-Item $script:outLog, $script:errLog -Force -EA SilentlyContinue
        $script:posOut = 0; $script:posErr = 0; $script:warmDone = 0; $script:warmSawDone = $false
        $script:warmKind = $kind
        # 管线预热默认开多少个子进程：显存小的机器少开几个（每个子进程一个 D3D12 设备）
        $warmJobs = $env:GTA6_LAUNCHER_WARM_JOBS
        if (-not $warmJobs) {
            $vramGB = 8
            if ($script:hw) { $vramGB = [math]::Round($script:hw.VramMB / 1024, 0) }
            if ($vramGB -le 8) { $warmJobs = 4 } elseif ($vramGB -le 12) { $warmJobs = 6 } else { $warmJobs = 8 }
        }
        $procArgs = if ($kind -eq 'pipelines') {
            if ($script:warmUseJobs -eq $false) { @('warm', '--used') }
            else { @('warm', '--used', '--jobs', "$warmJobs") }
        } else { @('shaders', (Quote-Arg $rpf)) }
        $script:warmTotal = if ($kind -eq 'pipelines') { 2400 } else { 26000 }
        # 预热过程中用户可能切构建：把这次预热对应的构建/版本固定下来
        $bb = $script:builds[$lstBuilds.SelectedIndex]
        $script:warmBuildIdx = $lstBuilds.SelectedIndex
        $script:warmBuild = $bb
        $script:warmProj = $bb.Project
        $script:warmExe = $bb.Exe
        $script:warmCacheDir = $script:cacheDir
        $script:warmBuildTime = $bb.Time
        $script:warmCommit = if ($script:projInfo) { [string]$script:projInfo.Commit } else { '' }
        $script:warmCommitFull = ''
        try { $script:warmCommitFull = [string](& git -C $bb.Project rev-parse HEAD 2>$null | Select-Object -First 1) } catch { }
        $script:warmTrId = Get-TranslatorId $bb.Project $bb.Exe
        $script:warmDriver = [string]$script:driverVer
        $script:warmStartedAt = Get-Date
        $script:warmFp = ''; $script:warmToMake = -1; $script:warmKnown = 0; $script:warmMade = 0; $script:warmShaders = 0
        $script:warmPre = Get-WarmArtifacts $script:warmCacheDir ''
        $lblStatus.Text = if ($kind -eq 'pipelines') { '正在预编译管线…' } else { '正在预翻译着色器…' }
        $script:proc = Start-Process -FilePath $script:exe -ArgumentList $procArgs -WorkingDirectory (Split-Path $script:exe) `
            -RedirectStandardOutput $script:outLog -RedirectStandardError $script:errLog -PassThru -WindowStyle Hidden
        Add-Log ("预热[{0}] PID={1} 缓存={2}" -f $kind, $script:proc.Id, $script:warmCacheDir)
        Add-Log ("  构建: {0} 版本={1} 翻译器={2} 驱动={3}" -f $bb.Name, $script:warmCommit, $script:warmTrId, $script:warmDriver)
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

# ---------------------------------------------------------------- 后台任务（更新/检查更新/扫描，不卡界面）
# 两种：外部程序（git，边跑边把 stderr 进度打进日志）和 PowerShell 作业（网络请求、目录扫描）
$script:bgProc = $null
$script:bgJob = $null

function Test-BgBusy {
    if ($script:bgProc) { Add-Log ("已有后台任务在跑（{0}），请等它结束" -f $script:bgProc.Name); return $true }
    if ($script:bgJob) { Add-Log ("已有后台任务在跑（{0}），请等它结束" -f $script:bgJob.Name); return $true }
    return $false
}

function Start-BgProc([string]$name, [string]$file, [string[]]$argList, [string]$workDir, [scriptblock]$onDone) {
    if (Test-BgBusy) { return $false }
    try {
        $lo = Join-Path $env:TEMP ("gta6-bg-" + (Get-Date -Format 'HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,4) + '.out.log')
        $le = $lo + '.err.log'
        Remove-Item $lo, $le -EA SilentlyContinue
        $p = Start-Process -FilePath $file -ArgumentList $argList -WorkingDirectory $(if ($workDir) { $workDir } else { $Root }) `
            -RedirectStandardOutput $lo -RedirectStandardError $le -PassThru -WindowStyle Hidden
        $script:bgProc = [pscustomobject]@{
            Name = $name; Proc = $p; LogOut = $lo; LogErr = $le; PosOut = 0; PosErr = 0
            OnDone = $onDone; Start = Get-Date; Shown = 0; Text = (New-Object System.Text.StringBuilder)
        }
        Add-Log ("{0}：已在后台执行（界面不会卡，日志实时显示）" -f $name)
        $lblStatus.Text = ("{0}…（可继续操作界面）" -f $name)
        return $true
    } catch {
        Add-Log ("{0} 启动失败: {1}" -f $name, $_.Exception.Message)
        return $false
    }
}

# 注意：PowerShell 5.1 里带 -RedirectStandard* 的 Start-Process 拿不到 ExitCode（总是空），
# 所以判断成败用「输出文本 + 命令自己的副作用」，OnDone 会同时收到 (退出码, 全部输出文本)
function Update-BgProc {
    $t = $script:bgProc
    if (-not $t) { return }
    try {
        $lines = @()
        $lines += Read-Log $t.LogOut ([ref]$t.PosOut)
        $lines += Read-Log $t.LogErr ([ref]$t.PosErr)
        foreach ($l in $lines) {
            $s = "$l".Trim()
            if ($s) { [void]$t.Text.AppendLine($s); Add-Log ('  │ ' + $s) }
        }
        $elapsed = [int]((Get-Date) - $t.Start).TotalSeconds
        $lblStatus.Text = ("{0}… {1:00}:{2:00}（界面可正常操作）" -f $t.Name, [math]::Floor($elapsed / 60), ($elapsed % 60))
        if ($t.Proc.HasExited) {
            $code = $null
            try { $null = $t.Proc.WaitForExit(2000); $code = $t.Proc.ExitCode } catch { }
            try {
                $tail = @()
                $tail += Read-Log $t.LogOut ([ref]$t.PosOut)
                $tail += Read-Log $t.LogErr ([ref]$t.PosErr)
                foreach ($l in $tail) { $s = "$l".Trim(); if ($s) { [void]$t.Text.AppendLine($s); Add-Log ('  │ ' + $s) } }
            } catch { }
            $script:bgProc = $null
            $text = ''
            try { $text = $t.Text.ToString() } catch { }
            Add-Log ("{0} 结束（退出码 {1}，用时 {2}s）" -f $t.Name, $(if ("$code" -eq '') { '未知' } else { $code }), $elapsed)
            if ($t.OnDone) { & $t.OnDone $code $text }
        }
    } catch { }
}

function Start-BgJob([string]$name, [scriptblock]$worker, [object[]]$arguments, [scriptblock]$onDone) {
    if (Test-BgBusy) { return $false }
    try {
        $j = $null
        if ($arguments -and $arguments.Count -gt 0) {
            $j = Start-Job -Name ('gta6-' + [guid]::NewGuid().ToString('N').Substring(0,6)) -ScriptBlock $worker -ArgumentList $arguments
        } else {
            $j = Start-Job -Name ('gta6-' + [guid]::NewGuid().ToString('N').Substring(0,6)) -ScriptBlock $worker
        }
        $script:bgJob = [pscustomobject]@{ Name = $name; Job = $j; OnDone = $onDone; Start = Get-Date }
        Add-Log ("{0}：已在后台执行（界面不会卡）" -f $name)
        $lblStatus.Text = ("{0}…（可继续操作界面）" -f $name)
        return $true
    } catch {
        Add-Log ("{0} 启动失败: {1}" -f $name, $_.Exception.Message)
        return $false
    }
}

function Update-BgJob {
    $t = $script:bgJob
    if (-not $t) { return }
    try {
        $elapsed = [int]((Get-Date) - $t.Start).TotalSeconds
        $lblStatus.Text = ("{0}… {1:00}:{2:00}（界面可正常操作）" -f $t.Name, [math]::Floor($elapsed / 60), ($elapsed % 60))
        $state = ''
        try { $state = [string]$t.Job.State } catch { $state = 'Unknown' }
        if ($state -eq 'Running' -or $state -eq 'NotStarted') { return }
        $out = @()
        try { $out = @(Receive-Job -Job $t.Job -EA SilentlyContinue) } catch { }
        $script:bgJob = $null
        try { Remove-Job -Job $t.Job -Force -EA SilentlyContinue } catch { }
        Add-Log ("{0} 结束（{1}，用时 {2}s）" -f $t.Name, $state, $elapsed)
        if ($t.OnDone) { & $t.OnDone $out $state }
    } catch { }
}

# 后台扫描构建：整个发现过程（含回退目录）放进作业，回来只填列表
# 注意：作业里没有主脚本的函数，所以扫描逻辑在 worker 里自带一份（与 Find-VictoryBuilds 保持一致）
function Scan-Builds([switch]$Async) {
    $root = $tbBuildRoot.Text.Trim()
    if (-not $Async) {
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
        Apply-BuildScan $root $found
        return
    }
    # ---- 异步：目录扫描放到后台作业里，界面不卡
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
    $worker = {
        param($root, $cands)
        $scan = {
            param($r)
            $out = @()
            if (-not $r -or -not (Test-Path $r)) { return @() }
            foreach ($pf in @('diag', 'release')) {
                foreach ($f in @(Get-ChildItem $r -Recurse -Depth 6 -Filter 'victory.exe' -EA SilentlyContinue)) {
                    if ($f.FullName -match "\\target\\$pf\\victory\.exe$") {
                        $proj = $f.FullName -replace "\\target\\$pf\\victory\.exe$", ''
                        $out += [pscustomobject]@{
                            Name = (Split-Path $proj -Leaf); Project = $proj; Exe = $f.FullName
                            Profile = $pf; SizeMB = [math]::Round($f.Length / 1MB, 1); Time = $f.LastWriteTime
                        }
                    }
                }
            }
            foreach ($f in @(Get-ChildItem $r -Recurse -Depth 6 -Filter 'victory*.exe' -EA SilentlyContinue)) {
                if ($f.FullName -match '\\target\\' -or $f.FullName -match '\\deps\\' -or $f.Name -match 'launcher') { continue }
                $proj = Split-Path $f.FullName -Parent
                $out += [pscustomobject]@{
                    Name = (Split-Path $proj -Leaf); Project = $proj; Exe = $f.FullName
                    Profile = 'exe'; SizeMB = [math]::Round($f.Length / 1MB, 1); Time = $f.LastWriteTime
                }
            }
            return @($out | Sort-Object Exe -Unique | Sort-Object @{Expression = { if ($_.Profile -in @('diag', 'release')) { 0 } else { 1 } }}, Project, Profile)
        }
        $found = @(& $scan $root)
        $used = $root
        $tried = @()
        if ($found.Count -eq 0) {
            foreach ($c in $cands) {
                if (-not $c -or -not (Test-Path $c)) { continue }
                $t = @(& $scan $c)
                $tried += ("{0}→{1}" -f $c, $t.Count)
                if ($t.Count -gt 0) { $found = $t; $used = $c; break }
            }
        }
        [pscustomobject]@{ Root = $used; Found = $found; Tried = $tried }
    }
    [void](Start-BgJob '扫描本地构建' $worker @($root, $candidates) {
        param($out, $state)
        try {
            $r = @($out | Where-Object { $null -ne $_ }) | Select-Object -Last 1
            if (-not $r) { Add-Log '扫描没有返回结果（作业可能出错）'; return }
            foreach ($t in @($r.Tried)) { if ($t) { Add-Log ("  尝试 {0}" -f $t) } }
            if ($r.Root -and $r.Root -ne $tbBuildRoot.Text.Trim()) {
                $tbBuildRoot.Text = $r.Root
                try { $Cfg.BuildRoot = $r.Root } catch { }
                Add-Log ("已自动切换到构建根目录: {0}" -f $r.Root)
            }
            Apply-BuildScan $r.Root @($r.Found)
        } catch { Add-Log ("扫描结果处理失败: " + $_.Exception.Message) }
    })
}

function Apply-BuildScan([string]$root, $found) {
    $found = @($found)
    $lstBuilds.Items.Clear()
    if ($found.Count -eq 0) {
        Add-Log ("没有找到任何 victory.exe。请在「构建根目录」选择含 */target/diag|release/victory.exe 的目录（当前: {0}）" -f $root)
        $lblStatus.Text = '没找到本地构建（检查「构建根目录」）'
        return
    }
    foreach ($f in $found) {
        try {
            $t = $f.Time
            if ($t -isnot [datetime]) { try { $t = [datetime]$t } catch { $t = Get-Date } }
            $lstBuilds.Items.Add(('{0}  [{1}]  {2} MB  {3:MM-dd HH:mm}' -f $f.Name, $f.Profile, $f.SizeMB, $t)) | Out-Null
        } catch { Add-Log ("构建条目格式异常: " + $_.Exception.Message) }
    }
    $script:builds = $found
    Add-Log ("扫描到 {0} 个本地构建" -f $found.Count)
    if ($lstBuilds.Items.Count -gt 0) {
        # N 卡优先 vf-nvidia，其次 nvidia / nv8gb；A 卡优先上游主线（原生 wave64）
        $prefs = @('vf-nvidia', 'nvidia', 'nv8gb')
        if ($script:hw -and $script:hw.Vendor -eq 'AMD') { $prefs = @('vf-main', 'upstream', '7900', 'unified', 'victory-main') }
        $idx = -1
        foreach ($pat in $prefs) {
            $cand = @()
            for ($i = 0; $i -lt $found.Count; $i++) { if ($found[$i].Name -match $pat) { $cand += $i } }
            if ($cand.Count -gt 0) {
                # 同一个工程有 diag / release 两份时选**较新的那个**（刚编出来的那份不该被旧 exe 顶掉）
                $best = $cand[0]
                foreach ($i in $cand) { try { if ($found[$i].Time -gt $found[$best].Time) { $best = $i } } catch { } }
                $idx = $best
                break
            }
        }
        if ($idx -lt 0) { $idx = 0 }
        $lstBuilds.SelectedIndex = $idx
        Add-Log ("默认构建: {0} [{1}]（{2:MM-dd HH:mm}）" -f $found[$idx].Name, $found[$idx].Profile, $found[$idx].Time)
    }
}

# 从引擎日志里取信息（引擎输出可能变，取到了就当补充，取不到也不影响判定）
function Read-WarmLine([string]$line) {
    # 旧版 victory.exe 没有 warm / shaders 子命令：clap 会直接报 unrecognized subcommand
    if ($line -match "unrecognized subcommand '([A-Za-z0-9_-]+)'" -or $line -match "invalid subcommand '([A-Za-z0-9_-]+)'") {
        $script:warmUnsupported = $matches[1]
        return
    }
    if ($line -match '(\d+)\s+pipelines known,\s*(\d+)\s+made before\s*\(([0-9a-fA-F]+)\),\s*(\d+)\s+bad;\s*(\d+)\s+to make') {
        $script:warmKnown = [int]$matches[1]
        $script:warmFp = $matches[3]
        $script:warmToMake = [int]$matches[5]
        $script:warmSawDone = $true
        return
    }
    if ($line -match '(\d+)\s+made in\s+[0-9.]+\s*s') { $script:warmMade = [int]$matches[1]; $script:warmSawDone = $true; return }
    if ($line -match '(\d+)\s+of\s+(\d+),\s+(\d+)\s*s') { $script:warmDone = [int]$matches[1]; $script:warmTotal = [int]$matches[2]; return }
    if ($line -match '(\d+)\s+shaders in the cache') {
        $script:warmShaders = [int]$matches[1]
        $script:warmDone = $script:warmShaders
        if ($script:warmTotal -lt $script:warmShaders) { $script:warmTotal = $script:warmShaders }
        $script:warmSawDone = $true
        return
    }
}

# 写预热记录（marker，跟着缓存目录走）+ 兼容旧版 meta；然后立即重算并刷新界面
function Save-WarmRecord([string]$kind, $outcome, [switch]$Quiet, [switch]$NoStatus) {
    try {
        $cacheDir = $script:warmCacheDir
        if (-not $cacheDir) { return $null }
        $mk = Get-WarmMarker $cacheDir
        if (-not $mk) { $mk = New-WarmRecord }
        $mk.Project = [string]$script:warmProj
        $mk.Exe = [string]$script:warmExe
        $mk.Commit = if ($script:warmCommitFull) { [string]$script:warmCommitFull } else { [string]$script:warmCommit }
        $mk.Translator = [string]$script:warmTrId
        $mk.Driver = [string]$script:warmDriver
        if ($script:warmBuildTime) { $mk.BuildTime = $script:warmBuildTime.ToString('o') }
        $now = (Get-Date).ToString('o')
        if ($kind -eq 'pipelines') {
            $post = Get-WarmArtifacts $cacheDir $script:warmFp
            $mk.PipesDone = [bool]$outcome.Done
            $mk.PipesTime = $now
            $mk.PipesFingerprint = [string]$script:warmFp
            $mk.PipesLines = [int]$post.PipesLines
            # 只有这次真的全部编译完才算完成；之前完成过的不降级
            if ([bool]$outcome.Complete) { $mk.PipesComplete = $true }
            $mk.PipesUnsupported = [bool]($script:warmUnsupported -eq 'warm')
        } else {
            $mk.ShadersDone = [bool]$outcome.Done
            $mk.ShadersTime = $now
            if ($script:warmShaders -gt 0) { $mk.ShadersCount = [int]$script:warmShaders }
            if ([bool]$outcome.Complete) { $mk.ShadersComplete = $true }
            $mk.ShadersUnsupported = [bool]($script:warmUnsupported -eq 'shaders')
        }
        Save-WarmMarker $cacheDir $mk
        # 旧版 builds-meta.json 一并写（老版本启动器/脚本读它）
        try {
            $mm = Get-Meta
            $p = $script:warmProj
            $mm[(Get-NormPath $p)] = [pscustomobject]@{
                project = $p; exe = $script:warmExe; cache = $cacheDir
                commit = $mk.Commit; branch = $(if ($script:projInfo) { [string]$script:projInfo.Branch } else { '' })
                translator = $script:warmTrId; driver = $script:warmDriver
                exeTime = $(if ($script:warmBuildTime) { $script:warmBuildTime.ToString('o') } else { '' })
                prewarmTime = $now
                shadersDone = $mk.ShadersDone; pipesDone = $mk.PipesDone
                shadersComplete = $mk.ShadersComplete; pipesComplete = $mk.PipesComplete
                pipesFingerprint = $mk.PipesFingerprint; pipesLines = $mk.PipesLines; shadersCount = $mk.ShadersCount
            }
            Save-Meta $mm
        } catch { }
        Add-Log ("已写预热记录: {0}" -f (Join-Path $cacheDir $script:markerName))
        if ($Quiet -or $NoStatus) { return $null }
        $r = Update-CacheStateLabel
        if ($r) {
            # 只有缓存真的就绪才说“预热完成”，否则别给假安心（以前没产出也会这么写）
            $lblStatus.Text = if ($r.State.State -eq 'ok') { '预热完成 · ' + $r.State.Text } else { '预热结束：' + $r.State.Text }
            Add-Log ("预热后缓存状态: {0} | {1}" -f $r.State.State, $r.State.Text)
            foreach ($d in $r.State.Details) { Add-Log ("  " + $d) }
        }
        return $r
    } catch {
        Add-Log ("写预热记录失败: " + $_.Exception.Message)
        return $null
    }
}

function Update-Warm {
    if (-not $script:proc) { return }
    $lines = @()
    $lines += Read-Log $script:outLog ([ref]$script:posOut)
    $lines += Read-Log $script:errLog ([ref]$script:posErr)
    foreach ($line in $lines) {
        Add-Log $line
        Read-WarmLine $line
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
            foreach ($l in $tail) { Add-Log $l; Read-WarmLine $l }
        } catch { }
        $kind = $script:warmKind
        Add-Log ("预热结束[{0}]（退出码 {1}）" -f $kind, $(if ("$code" -eq '') { '未知' } else { $code }))
        $post = Get-WarmArtifacts $script:warmCacheDir $script:warmFp
        $pre = $script:warmPre
        if (-not $pre) { $pre = [pscustomobject]@{ PipesLines = 0; ShaderFiles = 0 } }
        $outcome = Get-WarmOutcome $kind $code $script:warmToMake $script:warmShaders ([int]$pre.PipesLines) ([int]$post.PipesLines) ([int]$pre.ShaderFiles) ([int]$post.ShaderFiles) ([bool]($script:warmFp -ne '')) ([int]$post.MissingEarly)
        Add-Log ("  判定: done={0} complete={1} — {2}" -f $outcome.Done, $outcome.Complete, $outcome.Note)
        if ($script:warmUnsupported) {
            $sub = $script:warmUnsupported
            $what = if ($sub -eq 'warm') { '管线预编译' } elseif ($sub -eq 'shaders') { '着色器翻译' } else { $sub }
            Add-Log ("这个构建的 victory.exe 不认识 `"{0}`" 子命令（{1}做不了，旧版构建）" -f $sub, $what)
            Add-Log '  解决：换 20261126a/b 分发包，或自己编译一份新构建（新版 victory 才有 warm / shaders 子命令）'
            $lblStatus.Text = ('这个构建不支持' + $what + '（旧版 victory.exe）')
            if ($kind -ne 'all') { [void](Save-WarmRecord $kind ([pscustomobject]@{ Done = $true; Complete = $false; Note = '构建不支持该子命令' }) -NoStatus) }
        } elseif ($outcome.Done) { [void](Save-WarmRecord $kind $outcome) }
        $script:autoStage = if ($kind -eq 'all') { [int]$script:autoStage } else { 0 }
        if ($kind -eq 'all' -and $script:autoStage -eq 0) {
            # 着色器阶段记录完再继续管线（即使管线阶段失败/被停止，着色器记录也不会丢）
            $script:autoStage = 1
            $progress.Value = 0
            Start-Warm 'pipelines' -Auto
            return
        }
        $script:autoStage = 0
        if ($outcome.Complete) { $progress.Value = 100 }
        $btnWarmAll.Enabled = $true; $btnWarmShaders.Enabled = $true; $btnWarmPipes.Enabled = $true
        $btnStop.Enabled = $false; $btnLaunch.Enabled = $true
        if (-not $outcome.Done -and -not $script:warmUnsupported -and [int]$post.MissingEarly -lt 0) {
            $tailTxt = ''
            try { $tailTxt = ((Get-Content $script:errLog -EA SilentlyContinue | Select-Object -Last 3) -join ' ') } catch { }
            if ($tailTxt -match 'unexpected argument|invalid value|error:') {
                Add-Log '  引擎拒绝了这次调用（见上面日志）：常见是路径/参数没被正确识别'
                if ($tailTxt -match 'unexpected argument ''([^'']+)''') {
                    Add-Log ("  → 它把 '{0}' 当成了多余参数：说明某个带空格的路径被拆开了" -f $matches[1])
                }
            }
        }        if (-not $outcome.Done -and -not $script:warmUnsupported) {
            $lblStatus.Text = '预热没有产出，请查看日志'
            Add-Log '预热没有产出：缓存文件没有变化（退出码/日志见上）'
        }
        if (-not $outcome.Complete -and $outcome.Done) {
            Add-Log '预热未完成：可以再点一次「全部预热」/「预编译管线」从中断处续传'
        }
        # 管线阶段：引擎遇到编不出来的管线会静默收尾（不打印汇总）。只要这一轮有进展就自动接着跑，
        # 直到没有新进展为止——避免用户看到“点了没反应/一直说没产出”。
        if ($kind -eq 'pipelines' -and $outcome.Done -and -not $outcome.Complete) {
            $nowMissing = [int]$post.MissingEarly
            $prev = [int]$script:pipeMissing
            $progressed = ($nowMissing -ge 0) -and (($prev -lt 0) -or ($nowMissing -lt $prev))
            $script:pipeMissing = $nowMissing
            $script:pipeRounds = [int]$script:pipeRounds + 1
            if ($progressed -and ([int]$script:pipeRounds -lt 8)) {
                Add-Log ("管线预热没跑完（还差 {0} 条），引擎提前收尾 → 自动继续第 {1} 轮（已跑 {2} 轮）" -f $nowMissing, ([int]$script:pipeRounds + 1), [int]$script:pipeRounds)
                $progress.Value = 0
                Start-Warm 'pipelines' -Auto
                return
            }
            # 这一轮一点没动、但整体还差很多：可能是这个构建的 warm 不认 --jobs（老版本）→ 去掉再试一次
            if (-not $progressed -and [int]$nowMissing -lt 0) { $progressed = $false }
            if (-not $progressed -and $script:warmUseJobs -and [int]$script:pipeRounds -le 1) {
                $script:warmUseJobs = $false
                Add-Log '这个构建的 warm 可能不认识 --jobs 参数：去掉并发参数再试一次'
                Start-Warm 'pipelines' -Auto
                return
            }
            if (-not $progressed -and [int]$nowMissing -gt 0) {
                Add-Log ("还差 {0} 条，但这一轮没有新进展：这些管线被引擎/驱动拒绝编译（host refused），已完成的缓存不受影响" -f $nowMissing)
                $lblStatus.Text = ("管线已尽量预热（还差 {0} 条编不出来）" -f $nowMissing)
                # 剩下的确实编不出来：记成「已完成（含拒绝数）」，别一直显示未完成
                try {
                    $mk = Get-WarmMarker $script:warmCacheDir
                    if ($mk) {
                        $mk.PipesComplete = $true
                        $mk.PipesDone = $true
                        $mk.PipesRefused = [int]$nowMissing
                        Save-WarmMarker $script:warmCacheDir $mk
                    }
                    [void](Update-CacheStateLabel)
                } catch { }
            } else {
                Add-Log ("自动续传 {0} 轮后仍有 {1} 条未完成，可稍后再点「预编译管线」" -f [int]$script:pipeRounds, $nowMissing)
            }
        }
    }
}

function Stop-Warm {
    $kind = $script:warmKind
    $killed = 0
    try {
        if ($script:proc) {
            $killed = Stop-ProcTree $script:proc
            Add-Log ("已停止预热（同时结束子进程 {0} 个）" -f $killed)
        }
    } catch { }
    [void](Clear-StaleWarmProcs)
    $script:proc = $null; $script:autoStage = 0
    # 已经产出的部分也记下来：中断不是“没预热”，下次续传即可
    try {
        if ($kind -and $script:warmCacheDir) {
            $post = Get-WarmArtifacts $script:warmCacheDir $script:warmFp
            $pre = $script:warmPre
            if (-not $pre) { $pre = [pscustomobject]@{ PipesLines = 0; ShaderFiles = 0 } }
            $outcome = Get-WarmOutcome $kind 1 $script:warmToMake $script:warmShaders ([int]$pre.PipesLines) ([int]$post.PipesLines) ([int]$pre.ShaderFiles) ([int]$post.ShaderFiles) ([bool]($script:warmFp -ne '')) ([int]$post.MissingEarly)
            if ($outcome.Done) {
                [void](Save-WarmRecord $kind $outcome -Quiet)
                Add-Log ("已记录中断前的预热结果: {0}" -f $outcome.Note)
            }
        }
    } catch { }
    $script:autoStage = 0
    $btnWarmAll.Enabled = $true; $btnWarmShaders.Enabled = $true; $btnWarmPipes.Enabled = $true
    $btnStop.Enabled = $false; $btnLaunch.Enabled = $true
    $lblStatus.Text = '已停止'
    try { [void](Update-CacheStateLabel) } catch { }
}

# 启动前的缓存闸门：实时重算（此前用的是上次选构建时的旧值，预热完成后仍会误报“没预热”）
# 返回 $true 表示可以启动。只有“从没预热过/版本对不上”才弹窗，其余只写日志。
function Test-LaunchCacheGate($cs, [switch]$NoPrompt) {
    if (-not $cs) { [void](Update-CacheStateLabel); $cs = $script:cacheState }
    if (-not $cs) { return $true }
    Add-Log ("缓存状态: {0} | {1}" -f $cs.State, $cs.Text)
    foreach ($d in $cs.Details) { Add-Log ("  " + $d) }
    if ($cs.State -eq 'unsupported') {
        # 构建自己不支持预热：不用拦启动，但要说明白
        Add-Log ('提示: ' + $cs.Text + '（仍可直接启动，游戏会边跑边编译）')
        return $true
    }
    if ($cs.State -eq 'never' -or $cs.State -eq 'stale') {
        $tip = if ($cs.State -eq 'never') { '点「全部预热」一次，之后就不用再预热了。' } else { '重新「全部预热」即可；旧缓存不会被删。' }
        if ($NoPrompt) { return $false }
        $r2 = [System.Windows.Forms.MessageBox]::Show("$($cs.Text)`r`n`r`n$tip`r`n`r`n仍然启动吗？", '缓存可能过期', 'YesNo', 'Warning')
        return ($r2 -eq 'Yes')
    }
    if ($cs.State -eq 'partial') { Add-Log ("提示: " + $cs.Text) }
    return $true
}

function Launch-Game {
    try {
        if (-not $script:exe) { Add-Log '请先选择构建'; return }
        $already = @(Get-Process victory -EA SilentlyContinue)
        if ($already.Count -gt 0) {
            $pids = ($already | ForEach-Object { $_.Id }) -join ', '
            Add-Log ("检测到已有 victory 进程（PID: {0}），拒绝重复启动（否则会因文件锁报 0x80070005）" -f $pids)
            [System.Windows.Forms.MessageBox]::Show(("已经有游戏/预热进程在运行（PID: {0}）。`r`n`r`n请先关闭游戏窗口或结束这些进程，否则会报 0x80070005（拒绝访问）。`r`n`r`n（若是上次预热残留，点「停止」或重启启动器会自动清理。）" -f $pids), '已有实例在运行')
            return
        }
        if (-not (Test-LaunchCacheGate)) { return }
        $envInfo = Build-Env
        $gameExe = Combine-Path $tbGame.Text.Trim() 'game_scarlett_master.exe'
        if (-not (Test-Path $gameExe)) { Add-Log "找不到游戏: $gameExe"; return }
        Save-Cfg
        Add-Log ("启动: {0} / {1} / {2}p (scale {3})" -f $script:buildName, $envInfo.Console, $envInfo.Height, $envInfo.Scale)
        Add-Log ("缓存: {0}" -f $script:cacheDir)
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        $script:gameLog = Join-Path $script:logDir ("game-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
        $script:gameStart = Get-Date
        $script:game = Start-Process -FilePath $script:exe -ArgumentList @('run', (Quote-Arg $gameExe), '--execute', '--console', $envInfo.Console) `
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
        Scan-Builds -Async
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
            [void](Stop-ProcTree $script:compile.Proc)
            Add-Log '已取消编译（含 cargo/rustc 子进程）'
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
            # 新 exe 可能多了/少了子命令，也可能开始支持 RENDER_SCALE：清掉能力缓存重新探测
            try { $script:subCache.Clear(); $script:exeCapCache.Clear() } catch { }
            Scan-Builds -Async
            $lblStatus.Text = ('编译完成: ' + $c.Label)
            if ($script:updateCompile) {
                $script:updateCompile = $false
                $lblVerInfo.Text = '更新+编译完成 → 需要重新「全部预热」'
                Add-Log '更新完成：请重新执行「全部预热」（新版翻译器会让旧缓存失效）'
            }
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
# 检查更新 / 更新并编译：全部放后台（git fetch/pull 慢的时候界面也不卡，进度实时打进日志）
function Check-Update {
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先选中一个构建'; return }
        if (Test-BgBusy) { return }
        $b = $script:builds[$lstBuilds.SelectedIndex]
        $info = Get-ProjectInfo $b.Project
        $script:projInfo = $info
        $proxy = $tbProxy.Text.Trim()
        $script:checkCtx = [pscustomobject]@{ Project = $b.Project; Branch = [string]$info.Branch; Remote = [string]$info.Remote; Repo = $tbRepo.Text.Trim(); RepoBranch = $tbBranch.Text.Trim() }
        if ($info.Git) {
            $gp = if ($proxy) { @('-c', "http.proxy=$proxy", '-c', "https.proxy=$proxy") } else { @() }
            Add-Log ("检查上游: {0} 分支 {1}" -f $info.Remote, $info.Branch)
            $args = @('-C', (Quote-Arg $b.Project)) + $gp + @('fetch', 'origin')
            [void](Start-BgProc '检查上游（git fetch）' 'git' $args $b.Project {
                param($code, $text)
                try {
                    $c = $script:checkCtx
                    if (-not $c) { return }
                    # 不用退出码（PS5.1 带重定向时拿不到）：直接问 git 落后多少
                    $behind = & git -C $c.Project rev-list --count "HEAD..origin/$($c.Branch)" 2>$null
                    $head = & git -C $c.Project log -1 --format='%h %s' "origin/$($c.Branch)" 2>$null
                    if ("$behind" -match '^\d+$') {
                        if ([int]$behind -gt 0) {
                            $lblVerInfo.Text = "落后上游 $behind 个提交 | 上游最新: $head"
                            Add-Log ("有更新：落后 {0} 个提交，上游最新 {1}" -f $behind, $head)
                        } else {
                            $lblVerInfo.Text = '已是最新'
                            Add-Log '已是最新'
                        }
                        if ("$code" -ne '' -and "$code" -ne '0') { Add-Log ("（fetch 退出码 {0}，但比较可用）" -f $code) }
                    } else {
                        $lblVerInfo.Text = '检查失败（网络/代理？见日志）'
                        Add-Log '检查失败：无法比较 HEAD 与远端分支（多半是 fetch 没成功，检查代理）'
                    }
                } catch { Add-Log ("检查更新失败: " + $_.Exception.Message) }
            })
        } else {
            # 非 git 构建：用 GitHub API（网络请求放作业里，超时也不卡界面）
            $repo = $script:checkCtx.Repo
            $branch = $script:checkCtx.RepoBranch
            $worker = {
                param($repo, $branch)
                try {
                    $c = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/$branch" -Headers @{ 'User-Agent' = 'gta6-launcher' } -TimeoutSec 20
                    [pscustomobject]@{ Ok = $true; Sha = [string]$c.sha; Msg = (($c.commit.message -split "`n")[0]) }
                } catch {
                    [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
                }
            }
            [void](Start-BgJob '检查上游（GitHub API）' $worker @($repo, $branch) {
                param($out, $state)
                $r = @($out) | Select-Object -Last 1
                if (-not $r) { Add-Log '检查更新没有结果'; return }
                if ($r.Ok) {
                    $short = if ($r.Sha.Length -ge 7) { $r.Sha.Substring(0,7) } else { $r.Sha }
                    $lblVerInfo.Text = ("上游最新: {0} {1}" -f $short, $r.Msg)
                    Add-Log ("上游最新: {0} {1}" -f $short, $r.Msg)
                } else {
                    $lblVerInfo.Text = '检查失败'
                    Add-Log ("检查更新失败: " + $r.Error)
                }
            })
        }
    } catch { Add-Log ("检查更新失败: " + $_.Exception.Message); $lblVerInfo.Text = '检查失败' }
}

function Update-Build {
    param([switch]$ForceConfirm)
    try {
        if ($lstBuilds.SelectedIndex -lt 0) { Add-Log '先选中一个构建'; return }
        if (Test-BgBusy) { return }
        if ($script:compile -and $script:compile.Proc -and -not $script:compile.Proc.HasExited) { Add-Log '正在编译，等它结束再更新'; return }
        $b = $script:builds[$lstBuilds.SelectedIndex]
        $info = Get-ProjectInfo $b.Project
        if (-not $info.Git) { Add-Log '该构建不是 git 工程：请用「下载源码 ZIP」重新获取'; return }
        if (-not $ForceConfirm) {
            $r = [System.Windows.Forms.MessageBox]::Show("将更新 $($b.Name) 并重新编译。`r`n更新前会自动备份当前 exe。`r`n`r`n整个过程在后台进行，界面不会卡。`r`n`r`n继续吗？", '更新构建', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
        }
        # 备份 exe（约 10MB，几十毫秒；失败不拦更新）
        try {
            $bak = "$($b.Exe).bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item $b.Exe $bak -Force
            Add-Log ("已备份 exe: {0}" -f (Split-Path $bak -Leaf))
        } catch { Add-Log ("备份 exe 失败（继续）: " + $_.Exception.Message) }
        $proxy = $tbProxy.Text.Trim()
        $gitArgs = @('-C', (Quote-Arg $b.Project))
        if ($proxy) { $gitArgs += @('-c', "http.proxy=$proxy", '-c', "https.proxy=$proxy") }
        $gitArgs += @('pull', '--ff-only')
        $script:updateCtx = [pscustomobject]@{ Project = $b.Project; Name = $b.Name; Exe = $b.Exe; Branch = [string]$info.Branch; PreHead = [string](& git -C $b.Project rev-parse HEAD 2>$null) }
        $lblVerInfo.Text = '正在更新源码（后台）…'
        [void](Start-BgProc '更新源码（git pull）' 'git' $gitArgs $b.Project {
            param($code, $text)
            try {
                $c = $script:updateCtx
                if (-not $c) { return }
                $head = [string](& git -C $c.Project rev-parse HEAD 2>$null)
                $bad = ("$text" -match '(?im)(^|\s)(fatal|error|CONFLICT|rejected)\b')
                if ($bad -or -not $head) {
                    $lblVerInfo.Text = '更新失败（见日志）'
                    Add-Log '更新失败：源码没有变动，仍可编译当前版本'
                    return
                }
                $changed = ($c.PreHead -and $head -and ($c.PreHead -ne $head))
                if ($changed) { Add-Log ("源码已更新: {0} → {1}" -f $c.PreHead.Substring(0, [math]::Min(7, $c.PreHead.Length)), $head.Substring(0, [math]::Min(7, $head.Length))) }
                else { Add-Log '源码已是最新（没有新提交），继续编译当前版本' }
                # 源码变了：清掉旧预热记录（翻译器指纹变了，缓存要重做）
                try {
                    $mm = Get-Meta
                    $me = Find-MetaEntry $mm $c.Project $c.Exe $null
                    if ($me) { $me.prewarmTime = ''; Save-Meta $mm }
                } catch { }
                $lblVerInfo.Text = '源码已就绪，正在后台编译…'
                Add-Log '开始后台编译…'
                $script:updateCompile = $true
                $ok = Start-CompileAsync $c.Project $c.Name
                if (-not $ok) { $script:updateCompile = $false; Add-Log '编译没能启动（检查 cargo 是否可用）'; $lblVerInfo.Text = '源码已更新，编译未启动' }
            } catch { Add-Log ("更新后续处理失败: " + $_.Exception.Message) }
        })
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
        Scan-Builds -Async
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
        $dst = Combine-Path $tbDlDir.Text.Trim (Combine-Path $name 'target\release')
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item $exePath (Join-Path $dst 'victory.exe') -Force
        Add-Log ("已登记预编译 exe: {0}" -f (Join-Path $dst 'victory.exe'))
        Scan-Builds -Async
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
        $dst = Combine-Path $tbDlDir.Text.Trim (Combine-Path $repoName 'target\release')
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item $exe.FullName (Join-Path $dst 'victory.exe') -Force
        Add-Log ("已部署: {0}" -f (Join-Path $dst 'victory.exe'))
        Scan-Builds -Async
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
$btnScan.Add_Click({ Scan-Builds -Async })
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
$btnCheckCache.Add_Click({ Test-CacheStateNow })
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
    try { Update-BgProc } catch { Add-Log ("后台任务更新出错: " + $_.Exception.Message) }
    try { Update-BgJob } catch { }
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
    # 关窗口时若正在预热，先把已经产出的结果记下来（否则下次启动会误报“从未预热”）
    try {
        if ($script:proc -and -not $script:proc.HasExited -and $script:warmKind -and $script:warmCacheDir) {
            $post = Get-WarmArtifacts $script:warmCacheDir $script:warmFp
            $pre = $script:warmPre
            if (-not $pre) { $pre = [pscustomobject]@{ PipesLines = 0; ShaderFiles = 0 } }
            $outcome = Get-WarmOutcome $script:warmKind 1 $script:warmToMake $script:warmShaders ([int]$pre.PipesLines) ([int]$post.PipesLines) ([int]$pre.ShaderFiles) ([int]$post.ShaderFiles) ([bool]($script:warmFp -ne '')) ([int]$post.MissingEarly)
            if ($outcome.Done) { [void](Save-WarmRecord $script:warmKind $outcome -Quiet) }
        }
    } catch { }
    try { if ($script:proc) { [void](Stop-ProcTree $script:proc) } } catch { }
    try { [void](Clear-StaleWarmProcs) } catch { }
    try { if ($chkOpenDir.Checked -and $script:game -and -not $script:game.HasExited) { [void](Stop-ProcTree $script:game) } } catch { }
    try { if ('KeyMap' -as [type]) { [KeyMap]::Uninstall() } } catch { }
})
$form.Add_Shown({
    # 路径是自动检测出来的（配置里留空/失效时），把结论说清楚
    try { foreach ($n in @($script:pathNotes)) { Add-Log ("路径: " + $n) } } catch { }
    Refresh-Hw
    # 上次异常退出可能留下 warm 子进程（占 CPU、锁缓存），启动时先清掉
    try { [void](Clear-StaleWarmProcs) } catch { }
    Scan-Builds
    try {
        New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null
        Update-CrashLabel
    } catch { }
    try {
        if ($Cfg.KeyMap) { $txtKeyMap.Text = $Cfg.KeyMap }
        else { $txtKeyMap.Text = "# 每行一条：源键 = 目标键`r`n# CapsLock = Escape`r`n# F1 = Tab" }
        if ($Cfg.ContainsKey('KeyMapOn')) { $chkKeyAuto.Checked = [bool]$Cfg.KeyMapOn }
        if ($Cfg.ContainsKey('RtOff')) { $chkRtOff.Checked = [bool]$Cfg.RtOff }
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
            $lines += "raceTab=" + $tabRace.ClientSize.Width + "x" + $tabRace.ClientSize.Height
            $lines += ("localBuilds=({0},{1}) {2}x{3} readonly={4} scrollbars={5}" -f $lblLocalBuilds.Left, $lblLocalBuilds.Top, $lblLocalBuilds.Width, $lblLocalBuilds.Height, $lblLocalBuilds.ReadOnly, $lblLocalBuilds.ScrollBars)
            $lines += ("localBuilds fits tab: {0} (right={1} <= {2})" -f (($lblLocalBuilds.Left + $lblLocalBuilds.Width) -le $tabRace.ClientSize.Width), ($lblLocalBuilds.Left + $lblLocalBuilds.Width), $tabRace.ClientSize.Width)
            $lines += ("localBuilds text len=" + $lblLocalBuilds.Text.Length)
            # 用真实长度的长文本自检那一行：PrintWindow 直接抓窗口，不受别的窗口遮挡
            try {
                $lblLocalBuilds.Text = '本地构建在榜：cool_fox→CGBJ#11 | src→VIctory-7900XTX#27 | vf-latest→victory-fork#1 | VI-BR-PORT-main#23 | victory-unified#21 | itzfx#5 | Victory-RDNA#6 | amd#12 | victory#9 | 共 9 个本地构建在榜'
                $form.Refresh()
                if (-not ('PrintWin' -as [type])) {
                    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public class PrintWin {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  public static void Shot(IntPtr h, int w, int ht, string path) {
    using (var bmp = new Bitmap(w, ht)) {
      using (var g = Graphics.FromImage(bmp)) {
        IntPtr hdc = g.GetHdc();
        PrintWindow(h, hdc, 2);
        g.ReleaseHdc(hdc);
      }
      bmp.Save(path, ImageFormat.Png);
    }
  }
}
"@
                }
                # 切到排行榜页再抓，否则抓到的是第一页
                $tabs.SelectedIndex = 3
                $form.Refresh()
                Start-Sleep -Milliseconds 300
                $shot = $env:GTA6_LAUNCHER_LAYOUTTEST + '.png'
                [PrintWin]::Shot($form.Handle, $form.Width, $form.Height, $shot)
                $lines += ("shot=" + $shot + "  size=" + $form.Width + "x" + $form.Height)
                $lines += ("localBuilds text len=" + $lblLocalBuilds.Text.Length)
            } catch { $lines += ("shot ERR " + $_.Exception.Message) }
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
        # 跑到结束为止（默认 all；可用 GTA6_LAUNCHER_WARMTEST_KIND=shaders|pipelines 指定）
        $kind = if ($env:GTA6_LAUNCHER_WARMTEST_KIND) { [string]$env:GTA6_LAUNCHER_WARMTEST_KIND } else { 'all' }
        Start-Warm $kind
        $wt = New-Object System.Windows.Forms.Timer
        $wt.Interval = 2000
        $wt.Add_Tick({
            if ($script:proc) { return }          # 还在跑
            $this.Stop()
            $lines = @()
            try {
                $lines += "warmKind=" + $script:warmKind
                $lines += "warmDone=$($script:warmDone) / $($script:warmTotal)"
                $lines += "warmFp=" + $script:warmFp
                $lines += "warmToMake=" + $script:warmToMake + " warmMade=" + $script:warmMade + " warmShaders=" + $script:warmShaders
                $lines += "unsupported=" + $script:warmUnsupported
                $lines += "status=" + $lblStatus.Text
                if ($script:cacheState) { $lines += "cacheState=$($script:cacheState.State) | $($script:cacheState.Text)" }
                $lines += "--- findings ---"
                $lines += @(Select-String -Path $script:outLog -Pattern 'pipelines known|to make|made in|shaders in the cache|error' -EA SilentlyContinue | Select-Object -Last 6 | ForEach-Object { $_.Line })
            } catch { $lines += ("ERR " + $_.Exception.Message) }
            try { Set-Content -Path $env:GTA6_LAUNCHER_WARMTEST -Value ($lines -join "`r`n") -Encoding UTF8 } catch { }
            try { Set-Content -Path ($env:GTA6_LAUNCHER_WARMTEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $wt.Start()
        $wd = New-Object System.Windows.Forms.Timer
        $wd.Interval = 2700000     # 45 分钟看门狗
        $wd.Add_Tick({
            $this.Stop()
            try { Set-Content -Path $env:GTA6_LAUNCHER_WARMTEST -Value ("TIMEOUT`r`nstatus=" + $lblStatus.Text) -Encoding UTF8 } catch { }
            try { Set-Content -Path ($env:GTA6_LAUNCHER_WARMTEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            try { if ($script:proc) { [void](Stop-ProcTree $script:proc) } } catch { }
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $wd.Start()
    }
    if ($env:GTA6_LAUNCHER_LAUNCHTEST) {
        Start-Sleep -Milliseconds 500
        $script:launchTestState = if ($script:cacheState) { "$($script:cacheState.State)" } else { 'null' }
        Launch-Game
        $lt = New-Object System.Windows.Forms.Timer
        $lt.Interval = 75000
        $lt.Add_Tick({
            $this.Stop()
            $lines = @()
            try {
                $p = @(Get-Process victory -EA SilentlyContinue)
                $lines += "gameRunning=" + $(if ($p.Count -gt 0) { 'yes' } else { 'no' })
                $lines += "gameProcs=" + $p.Count
                try { $lines += "title=" + [string]$p[0].MainWindowTitle } catch { $lines += 'title=<n/a>' }
            } catch { $lines += ("proc ERR " + $_.Exception.Message) }
            try { $lines += "cacheStateAtLaunch=" + $script:launchTestState } catch { }
            try { $lines += "cacheStateNow=" + $(if ($script:cacheState) { "$($script:cacheState.State) | $($script:cacheState.Text)" } else { 'null' }) } catch { }
            try { $lines += "status=" + $lblStatus.Text } catch { }
            try { $lines += "cacheDir=" + $script:cacheDir } catch { }
            try { $lines += "gameLog=" + $script:gameLog } catch { }
            try { Set-Content -Path $env:GTA6_LAUNCHER_LAUNCHTEST -Value ($lines -join "`r`n") -Encoding UTF8 } catch { }
            try { Set-Content -Path ($env:GTA6_LAUNCHER_LAUNCHTEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $lt.Start()
        $ld = New-Object System.Windows.Forms.Timer
        $ld.Interval = 180000
        $ld.Add_Tick({
            $this.Stop()
            try { Set-Content -Path $env:GTA6_LAUNCHER_LAUNCHTEST -Value ("TIMEOUT`r`nstatus=" + $lblStatus.Text) -Encoding UTF8 } catch { }
            try { Set-Content -Path ($env:GTA6_LAUNCHER_LAUNCHTEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            Get-Process victory -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $ld.Start()
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
    if ($env:GTA6_LAUNCHER_FREETEST) {
        # 界面是否被阻塞：后台任务跑的时候，UI 定时器应该照常走动（阻塞时几乎不动）
        $script:freeOut = @()
        $script:freeTicks = 0
        $script:freePhase = 0
        $freeTimer = New-Object System.Windows.Forms.Timer
        $freeTimer.Interval = 100
        $freeTimer.Add_Tick({ $script:freeTicks++ })
        $freeTimer.Start()
        $script:freeOut += ("start=" + (Get-Date).ToString('HH:mm:ss'))
        # 阶段1：外部进程（模拟 git pull 这类会卡住的操作，3 秒）
        $okStart = Start-BgProc '阻塞测试进程' 'powershell' @('-NoProfile', '-Command', 'Start-Sleep -Seconds 3; Write-Output "bg-proc-done"') $env:TEMP {
            param($code)
            try {
                $script:freeOut += ("phase1_exit=" + $code)
                $script:freeOut += ("phase1_uiTicks=" + $script:freeTicks)
                # 阶段2：PowerShell 作业（模拟网络请求 / 目录扫描，2 秒）
                $script:freeTicks = 0
                $w = { Start-Sleep -Seconds 2; [pscustomobject]@{ Ok = $true; Value = 'bg-job-done' } }
                [void](Start-BgJob '阻塞测试作业' $w @() {
                    param($out, $state)
                    try {
                        $r = @($out) | Select-Object -Last 1
                        $script:freeOut += ("phase2_state=" + $state)
                        $script:freeOut += ("phase2_value=" + $(if ($r) { $r.Value } else { '' }))
                        $script:freeOut += ("phase2_uiTicks=" + $script:freeTicks)
                        $script:freeOut += ("bgIdle=" + ((-not $script:bgProc) -and (-not $script:bgJob)))
                    } catch { $script:freeOut += ("phase2 ERR " + $_.Exception.Message) }
                    # 阶段3：后台扫描构建（真实目录扫描，最容易卡界面的那个）
                    $script:freeTicks = 0
                    $script:freePhase = 3
                    try {
                        Scan-Builds -Async
                        $script:freeOut += ("phase3_scanStarted=True")
                    } catch { $script:freeOut += ("phase3 ERR " + $_.Exception.Message) }
                    $watch = New-Object System.Windows.Forms.Timer
                    $watch.Interval = 250
                    $watch.Add_Tick({
                        if ($script:bgJob -or $script:bgProc) { return }
                        $this.Stop()
                        try {
                            $script:freeOut += ("phase3_uiTicks=" + $script:freeTicks)
                            $script:freeOut += ("phase3_builds=" + @($script:builds).Count)
                            $script:freeOut += ("phase3_listItems=" + $lstBuilds.Items.Count)
                            $script:freeOut += ("phase3_bgIdle=" + ((-not $script:bgProc) -and (-not $script:bgJob)))
                        } catch { $script:freeOut += ("phase3 ERR " + $_.Exception.Message) }
                        Set-Content -Path $env:GTA6_LAUNCHER_FREETEST -Value ($script:freeOut -join "`r`n") -Encoding UTF8
                        try { Set-Content -Path ($env:GTA6_LAUNCHER_FREETEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
                        try { $freeTimer.Stop() } catch { }
                        try { $watch.Stop() } catch { }
                        try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
                    })
                    $watch.Start()
                })
            } catch { }
        }
        $script:freeOut += ("bgProcStarted=" + $okStart)
        # 看门狗：无论哪一步卡住，180 秒后也把结果写出来并关窗（避免测试把进程挂住）
        $deadline = New-Object System.Windows.Forms.Timer
        $deadline.Interval = 180000
        $deadline.Add_Tick({
            $this.Stop()
            try { $script:freeOut += 'TIMEOUT' } catch { }
            try { Set-Content -Path $env:GTA6_LAUNCHER_FREETEST -Value ($script:freeOut -join "`r`n") -Encoding UTF8 } catch { }
            try { Set-Content -Path ($env:GTA6_LAUNCHER_FREETEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            try { if ($script:bgJob) { Stop-Job $script:bgJob.Job -EA SilentlyContinue } } catch { }
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $deadline.Start()
    }
    if ($env:GTA6_LAUNCHER_UPDATETEST) {
        # 验证「检查上游更新」的异步路径：等后台任务自然结束再记录（不再卡界面/不再立即关窗）
        try { Check-Update } catch { Add-Log ("Check-Update ERR " + $_.Exception.Message) }
        $ut = New-Object System.Windows.Forms.Timer
        $ut.Interval = 500
        $ut.Add_Tick({
            if ($script:bgProc -or $script:bgJob) { return }
            $this.Stop()
            $lines = @()
            $lines += ("verInfo=" + $lblVerInfo.Text)
            $lines += ("status=" + $lblStatus.Text)
            $lines += ("bgIdle=" + ((-not $script:bgProc) -and (-not $script:bgJob)))
            Set-Content -Path $env:GTA6_LAUNCHER_UPDATETEST -Value ($lines -join "`r`n") -Encoding UTF8
            try { Set-Content -Path ($env:GTA6_LAUNCHER_UPDATETEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $ut.Start()
        $ud = New-Object System.Windows.Forms.Timer
        $ud.Interval = 150000
        $ud.Add_Tick({
            $this.Stop()
            try { Set-Content -Path $env:GTA6_LAUNCHER_UPDATETEST -Value ("TIMEOUT`r`nverInfo=" + $lblVerInfo.Text) -Encoding UTF8 } catch { }
            try { Set-Content -Path ($env:GTA6_LAUNCHER_UPDATETEST + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        })
        $ud.Start()
    }
    if ($env:GTA6_LAUNCHER_PULLTEST_ASYNC) {
        # 「更新并编译」异步流程测试：本地临时 git 仓库（绝不碰真实构建）
        $script:pullOut = @()
        $script:pullTicks = 0
        $tmp = Join-Path $env:TEMP ('gta6-pulltest-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        try {
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            $origin = Join-Path $tmp 'origin.git'
            $work = Join-Path $tmp 'work'
            & git init --bare $origin 2>&1 | Out-Null
            & git clone $origin $work 2>&1 | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $work 'target\diag') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $work 'crates\victory-shader\src') | Out-Null
            Set-Content -Path (Join-Path $work 'Cargo.toml') -Value "[workspace]`nmembers = []" -Encoding ASCII
            Set-Content -Path (Join-Path $work 'crates\victory-shader\src\lib.rs') -Value 'pub fn x() {}' -Encoding ASCII
            [System.IO.File]::WriteAllBytes((Join-Path $work 'target\diag\victory.exe'), (New-Object byte[] 4096))
            & git -C $work -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
            & git -C $work -c user.email=t@t -c user.name=t commit -m 'c1' 2>&1 | Out-Null
            & git -C $work push origin HEAD 2>&1 | Out-Null
            # 上游再提交一次，然后把工作副本退回上一版 → 现在落后 1 个提交
            Set-Content -Path (Join-Path $work 'upstream.txt') -Value 'v2' -Encoding ASCII
            & git -C $work -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
            & git -C $work -c user.email=t@t -c user.name=t commit -m 'c2-upstream' 2>&1 | Out-Null
            & git -C $work push origin HEAD 2>&1 | Out-Null
            & git -C $work reset --hard HEAD~1 2>&1 | Out-Null
            $before = [string](& git -C $work rev-parse HEAD)
            $script:pullBefore = $before
            $script:pullWork = $work
            # 让启动器扫到这个假构建
            $tbProxy.Text = ''
            $tbBuildRoot.Text = $tmp
            Scan-Builds
            $idx = -1
            for ($i = 0; $i -lt @($script:builds).Count; $i++) {
                if ((Get-NormPath $script:builds[$i].Project) -eq (Get-NormPath $work)) { $idx = $i; break }
            }
            $script:pullOut += ("buildIndex=" + $idx + " builds=" + @($script:builds).Count)
            if ($idx -ge 0) { $lstBuilds.SelectedIndex = $idx }
            # 界面响应计时器：后台跑 git pull 时它应该照常走动
            $pt = New-Object System.Windows.Forms.Timer
            $pt.Interval = 100
            $pt.Add_Tick({ $script:pullTicks++ })
            $pt.Start()
            if ($idx -ge 0) { Update-Build -ForceConfirm } else { $script:pullOut += 'noBuildSelected' }
            # 等 pull 结束（编译产物会失败，只关心 pull 与交接）
            $pw = New-Object System.Windows.Forms.Timer
            $pw.Interval = 500
            $pw.Add_Tick({
                if ($script:compile -and -not $script:compile.Done -and $script:compile.Proc -and -not $script:compile.Proc.HasExited) { return }
                if (-not $script:compile -and ($script:bgProc -or $script:bgJob)) { return }
                if ($script:bgProc -or $script:bgJob) { return }
                $this.Stop()
                try {
                    $after = [string](& git -C $script:pullWork rev-parse HEAD 2>$null)
                    $script:pullOut += ("after=" + $(if ($after.Length -ge 7) { $after.Substring(0,7) } else { $after }))
                    $script:pullOut += ("pulled=" + ($after -ne $script:pullBefore -and $after.Length -gt 0))
                    $script:pullOut += ("verInfo=" + $lblVerInfo.Text)
                    $script:pullOut += ("uiTicksDuringPull=" + $script:pullTicks)
                    $script:pullOut += ("compileStarted=" + ($null -ne $script:compile))
                    $script:pullOut += ("compileOk=" + $(if ($script:compile) { $script:compile.Ok } else { 'n/a' }))
                } catch { $script:pullOut += ("ERR " + $_.Exception.Message) }
                Set-Content -Path $env:GTA6_LAUNCHER_PULLTEST_ASYNC -Value ($script:pullOut -join "`r`n") -Encoding UTF8
                try { Set-Content -Path ($env:GTA6_LAUNCHER_PULLTEST_ASYNC + '.log') -Value $logBox.Text -Encoding UTF8 } catch { }
                try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
            })
            $pw.Start()
        } catch {
            $script:pullOut += ("EXCEPTION " + $_.Exception.Message)
            Set-Content -Path $env:GTA6_LAUNCHER_PULLTEST_ASYNC -Value ($script:pullOut -join "`r`n") -Encoding UTF8
            try { $form.BeginInvoke([System.Action]{ $form.Close() }) | Out-Null } catch { }
        }
    }
    if ($env:GTA6_LAUNCHER_CACHETEST) {
        # v1.9.1 回归测试：缓存状态判定（不需要真的跑几个小时预热）
        $lines = @()
        $pass = 0; $fail = 0
        $tmp = ''
        try {
            $tmp = Join-Path $env:TEMP ('gta6-cachetest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $oldMeta = $script:metaPath
            $script:metaPath = Join-Path $tmp 'builds-meta.json'
            $proj = Join-Path $tmp 'proj\vf-cachetest'
            $srcDir = Join-Path $proj 'crates\victory-shader\src'
            New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $proj 'crates\victory-gpu\src') | Out-Null
            Set-Content -Path (Join-Path $srcDir 'lib.rs') -Value 'pub fn a() {}' -Encoding ASCII
            Set-Content -Path (Join-Path $proj 'Cargo.lock') -Value '# lock' -Encoding ASCII
            $exe = Join-Path $proj 'target\diag\victory.exe'
            New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
            [System.IO.File]::WriteAllBytes($exe, [byte[]](1..255))
            $exeTime = (Get-Date '2026-11-20 10:00:00')
            [System.IO.File]::SetLastWriteTime($exe, $exeTime)
            $trId = Get-TranslatorId $proj $exe
            $lines += "setup: tmp=$tmp tr=$trId"

            # --- 空缓存目录 → never
            $empty = Join-Path $tmp 'cache-empty'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            $s1 = Get-CacheState $proj $exeTime $trId $empty 'commitA' $exe '566.03'
            $ok1 = ($s1.State -eq 'never')
            if ($ok1) { $pass++ } else { $fail++ }
            $lines += ("[{0}] empty-cache -> {1} | {2}" -f $(if ($ok1) { 'PASS' } else { 'FAIL' }), $s1.State, $s1.Text)

            # --- 旧版缓存（只有文件、没有记录）+ exe 比缓存老 → ok
            $c2 = Join-Path $tmp 'cache-artifacts'
            New-Item -ItemType Directory -Force -Path (Join-Path $c2 'pipelines') | Out-Null
            Set-Content -Path (Join-Path $c2 'pipelines\warm-done.txt') -Value ("aaaa000000000000 k1`r`naaaa000000000000 k2`r`naaaa000000000000 k3") -Encoding ASCII
            Set-Content -Path (Join-Path $c2 'pipelines\early-pipelines.txt') -Value ("k1`r`nk2`r`nk3") -Encoding ASCII
            foreach ($i in 0..39) { $d = Join-Path $c2 ("shaders\{0:x2}" -f $i); New-Item -ItemType Directory -Force -Path $d | Out-Null }
            Set-Content -Path (Join-Path $c2 'shaders\00\x1') -Value 'x' -Encoding ASCII
            $s2 = Get-CacheState $proj $exeTime $trId $c2 'commitA' $exe '566.03'
            $ok2 = ($s2.State -eq 'ok')
            if ($ok2) { $pass++ } else { $fail++ }
            $lines += ("[{0}] artifacts-no-record -> {1} | {2} | {3}" -f $(if ($ok2) { 'PASS' } else { 'FAIL' }), $s2.State, $s2.Text, ($s2.Details -join '; '))

            # --- 新记录：版本一致 → ok；exe 时间变新也一样 ok（这正是 v1.9.0 的 bug）
            $mk = New-WarmRecord
            $mk.Project = $proj; $mk.Exe = $exe; $mk.Commit = 'commitA'; $mk.Translator = $trId; $mk.Driver = '566.03'
            $mk.BuildTime = $exeTime.ToString('o')
            $mk.ShadersDone = $true; $mk.ShadersComplete = $true; $mk.ShadersTime = (Get-Date '2026-11-20 12:00:00').ToString('o'); $mk.ShadersCount = 26000
            $mk.PipesDone = $true; $mk.PipesComplete = $true; $mk.PipesTime = (Get-Date '2026-11-20 13:00:00').ToString('o'); $mk.PipesFingerprint = 'aaaa000000000000'; $mk.PipesLines = 3
            Save-WarmMarker $c2 $mk
            $s3 = Get-CacheState $proj $exeTime $trId $c2 'commitA' $exe '566.03'
            $ok3 = ($s3.State -eq 'ok')
            if ($ok3) { $pass++ } else { $fail++ }
            $lines += ("[{0}] record-match -> {1} | {2}" -f $(if ($ok3) { 'PASS' } else { 'FAIL' }), $s3.State, $s3.Text)

            $newerExe = $exeTime.AddHours(5)   # 重新编译：exe 变新，翻译器没变
            $s4 = Get-CacheState $proj $newerExe $trId $c2 'commitA' $exe '566.03'
            $ok4 = ($s4.State -eq 'ok')
            if ($ok4) { $pass++ } else { $fail++ }
            $lines += ("[{0}] recompiled-same-translator -> {1} | {2}" -f $(if ($ok4) { 'PASS' } else { 'FAIL' }), $s4.State, $s4.Text)

            # --- 构建更新（commit 变了）→ stale
            $s5 = Get-CacheState $proj $newerExe $trId $c2 'commitB' $exe '566.03'
            $ok5 = ($s5.State -eq 'stale')
            if ($ok5) { $pass++ } else { $fail++ }
            $lines += ("[{0}] commit-changed -> {1} | {2}" -f $(if ($ok5) { 'PASS' } else { 'FAIL' }), $s5.State, $s5.Text)

            # --- 短 sha 对完整 sha：同一个提交，不能误判
            $mkX = Get-WarmMarker $c2
            $mkX.Commit = 'abcdef1234567890abcdef1234567890abcdef12'
            Save-WarmMarker $c2 $mkX
            $s5b = Get-CacheState $proj $exeTime $trId $c2 'abcdef1' $exe '566.03'
            $ok5b = ($s5b.State -eq 'ok')
            if ($ok5b) { $pass++ } else { $fail++ }
            $lines += ("[{0}] short-vs-full-sha -> {1} | {2}" -f $(if ($ok5b) { 'PASS' } else { 'FAIL' }), $s5b.State, $s5b.Text)
            $mkX.Commit = 'commitA'
            Save-WarmMarker $c2 $mkX

            # --- 翻译器变了 → stale
            Set-Content -Path (Join-Path $srcDir 'lib.rs') -Value 'pub fn a() { /* changed */ }' -Encoding ASCII
            $trId2 = Get-TranslatorId $proj $exe
            $s6 = Get-CacheState $proj $newerExe $trId2 $c2 'commitA' $exe '566.03'
            $ok6 = ($s6.State -eq 'stale')
            if ($ok6) { $pass++ } else { $fail++ }
            $lines += ("[{0}] translator-changed ({1} -> {2}) -> {3}" -f $(if ($ok6) { 'PASS' } else { 'FAIL' }), $trId, $trId2, $s6.State)

            # --- 驱动更新 → stale（翻译器用原值，只让驱动不同）
            $s7 = Get-CacheState $proj $newerExe $trId $c2 'commitA' $exe '600.11'
            $ok7 = ($s7.State -eq 'stale')
            if ($ok7) { $pass++ } else { $fail++ }
            $lines += ("[{0}] driver-changed -> {1} | {2}" -f $(if ($ok7) { 'PASS' } else { 'FAIL' }), $s7.State, $s7.Text)

            # --- 记录里是「没跑完」+ early 里还有 k4 → partial（可续传）
            #     记录里是「跑完过」+ 之后又出现新管线 → ok（只提示，不判未完成）
            $ef2 = Join-Path $c2 'pipelines\early-pipelines.txt'
            Set-Content -Path $ef2 -Value ("k1`r`nk2`r`nk3`r`nk4") -Encoding ASCII
            $mkP = Get-WarmMarker $c2
            $mkP.PipesComplete = $false
            Save-WarmMarker $c2 $mkP
            $s8 = Get-CacheState $proj $exeTime $trId $c2 'commitA' $exe '566.03'
            $ok8 = ($s8.State -eq 'partial' -and $s8.MissingEarly -eq 1)
            if ($ok8) { $pass++ } else { $fail++ }
            $lines += ("[{0}] pipelines-incomplete -> {1} missingEarly={2} | {3}" -f $(if ($ok8) { 'PASS' } else { 'FAIL' }), $s8.State, $s8.MissingEarly, $s8.Text)

            $mkP.PipesComplete = $true
            Save-WarmMarker $c2 $mkP
            $s8b = Get-CacheState $proj $exeTime $trId $c2 'commitA' $exe '566.03'
            $ok8b = ($s8b.State -eq 'ok') -and ($s8b.Text -match '缓存就绪')
            if ($ok8b) { $pass++ } else { $fail++ }
            $lines += ("[{0}] pipelines-later-growth -> {1} | {2}" -f $(if ($ok8b) { 'PASS' } else { 'FAIL' }), $s8b.State, $s8b.Text)
            Set-Content -Path $ef2 -Value ("k1`r`nk2`r`nk3") -Encoding ASCII

            # --- 上次预热中途被停（complete=false）→ partial（可续传，不拦启动）
            $mk2 = Get-WarmMarker $c2
            $mk2.PipesComplete = $false
            Save-WarmMarker $c2 $mk2
            $s8b = Get-CacheState $proj $exeTime $trId $c2 'commitA' $exe '566.03'
            $ok8b = ($s8b.State -eq 'partial')
            if ($ok8b) { $pass++ } else { $fail++ }
            $lines += ("[{0}] incomplete-warm -> {1} | {2}" -f $(if ($ok8b) { 'PASS' } else { 'FAIL' }), $s8b.State, $s8b.Text)
            $mk2.PipesComplete = $true
            Save-WarmMarker $c2 $mk2

            # --- 只有着色器 → partial
            $c9 = Join-Path $tmp 'cache-shaders-only'
            foreach ($i in 0..39) { $d = Join-Path $c9 ("shaders\{0:x2}" -f $i); New-Item -ItemType Directory -Force -Path $d | Out-Null }
            Set-Content -Path (Join-Path $c9 'shaders\01\x2') -Value 'y' -Encoding ASCII
            $s9 = Get-CacheState $proj $exeTime $trId $c9 'commitA' $exe '566.03'
            $ok9 = ($s9.State -eq 'partial')
            if ($ok9) { $pass++ } else { $fail++ }
            $lines += ("[{0}] shaders-only -> {1} | {2}" -f $(if ($ok9) { 'PASS' } else { 'FAIL' }), $s9.State, $s9.Text)

            # --- 预热结果判定（纯函数）
            $o1 = Get-WarmOutcome 'pipelines' 0 0 0 3 3 1 1 $true
            $o2 = Get-WarmOutcome 'pipelines' 1 500 0 3 10 1 1 $true
            $o3 = Get-WarmOutcome 'pipelines' 1 500 0 3 3 1 1 $false
            $o4 = Get-WarmOutcome 'shaders' 0 0 26000 3 3 0 1 $false
            $o5 = Get-WarmOutcome 'shaders' 1 0 1000 3 3 0 0 $false
            $o6 = Get-WarmOutcome 'shaders' 0 0 0 3 3 0 0 $false
            $okW = ($o1.Done -and $o1.Complete) -and ($o2.Done -and -not $o2.Complete) -and (-not $o3.Done) -and ($o4.Done -and $o4.Complete) -and ($o5.Done -and -not $o5.Complete) -and (-not $o6.Done)
            if ($okW) { $pass++ } else { $fail++ }
            $lines += ("[{0}] outcome: done0/complete={1} partial={2} {3} shadersOK={4} shadersPartial={5} shadersNone={6}" -f $(if ($okW) { 'PASS' } else { 'FAIL' }), $o1.Complete, $o2.Done, $o3.Done, $o4.Complete, $o5.Done, $o6.Done)

            # --- meta key 兼容：旧写法（未规范化的全路径）也能读到
            $meta2 = @{}
            $meta2[$proj.ToUpper() + '\'] = [pscustomobject]@{ project = $proj; exe = $exe; cache = $c2; commit = 'commitA'; translator = $trId; prewarmTime = (Get-Date '2026-11-20 13:00:00').ToString('o') }
            Save-Meta $meta2
            $found = Find-MetaEntry (Get-Meta) $proj $exe $c2
            $okM = ($null -ne $found -and $found.translator -eq $trId)
            if ($okM) { $pass++ } else { $fail++ }
            $lines += ("[{0}] meta-key-normalized found={1}" -f $(if ($okM) { 'PASS' } else { 'FAIL' }), ($null -ne $found))

            # --- 预编译包（没有源码）：只改 exe 时间不算变化（重新解压/复制不该判过期）
            $proj2 = Join-Path $tmp 'proj2\prebuilt'
            New-Item -ItemType Directory -Force -Path $proj2 | Out-Null
            $exe2 = Join-Path $proj2 'victory.exe'
            [System.IO.File]::WriteAllBytes($exe2, [byte[]](7..99))
            [System.IO.File]::SetLastWriteTime($exe2, (Get-Date '2026-11-21 09:00:00'))
            $id2 = Get-TranslatorId $proj2 $exe2
            [System.IO.File]::SetLastWriteTime($exe2, (Get-Date '2026-11-25 09:00:00'))
            $id3 = Get-TranslatorId $proj2 $exe2
            $okE = ($id2 -eq $id3) -and ("$id2".StartsWith('exe')) -and ($id2 -ne '')
            if ($okE) { $pass++ } else { $fail++ }
            $lines += ("[{0}] exe-id-ignores-mtime {1} vs {2}" -f $(if ($okE) { 'PASS' } else { 'FAIL' }), $id2, $id3)

            # --- 启动闸门：never/stale 拦（NoPrompt 下返回 false），ok/partial 放行
            $gNever = Test-LaunchCacheGate ([pscustomobject]@{ State = 'never'; Text = 't'; Details = @() }) -NoPrompt
            $gStale = Test-LaunchCacheGate ([pscustomobject]@{ State = 'stale'; Text = 't'; Details = @() }) -NoPrompt
            $gOk = Test-LaunchCacheGate ([pscustomobject]@{ State = 'ok'; Text = 't'; Details = @() }) -NoPrompt
            $gPart = Test-LaunchCacheGate ([pscustomobject]@{ State = 'partial'; Text = 't'; Details = @() }) -NoPrompt
            $okG = (-not $gNever) -and (-not $gStale) -and $gOk -and $gPart
            if ($okG) { $pass++ } else { $fail++ }
            $lines += ("[{0}] launch-gate never={1} stale={2} ok={3} partial={4}" -f $(if ($okG) { 'PASS' } else { 'FAIL' }), $gNever, $gStale, $gOk, $gPart)

            # --- 进程树结束（不含真实进程：只验证空输入不报错、返回 0）
            $okStop = ((Stop-ProcTree $null) -eq 0)
            if ($okStop) { $pass++ } else { $fail++ }
            $lines += ("[{0}] stop-proctree-null -> 0" -f $(if ($okStop) { 'PASS' } else { 'FAIL' }))

            $script:metaPath = $oldMeta
        } catch {
            $fail++
            $lines += ("EXCEPTION: " + $_.Exception.Message)
            $lines += ($_.ScriptStackTrace -split "`n" | Select-Object -First 3)
        } finally {
            try { if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue } } catch { }
            try { if ($script:metaPath -ne (Join-Path $Root 'builds-meta.json')) { $script:metaPath = Join-Path $Root 'builds-meta.json' } } catch { }
        }
        # --- 旧版构建（victory.exe 没有 warm 子命令）：日志要能认出来，状态要说得明白
            $script:warmUnsupported = ''
            Read-WarmLine "error: unrecognized subcommand 'warm'"
            Read-WarmLine 'Usage: victory.exe <COMMAND>'
            $okU = ($script:warmUnsupported -eq 'warm')
            if ($okU) { $pass++ } else { $fail++ }
            $lines += ("[{0}] unsupported-subcommand detected: {1}" -f $(if ($okU) { 'PASS' } else { 'FAIL' }), $script:warmUnsupported)

            $mkU = $null
            $cU = Join-Path $env:TEMP ('gta6-unsup-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            try {
                foreach ($i in 0..39) { New-Item -ItemType Directory -Force -Path (Join-Path $cU ("shaders\{0:x2}" -f $i)) | Out-Null }
                Set-Content -Path (Join-Path $cU 'shaders\00\x1') -Value 'x' -Encoding ASCII
                New-Item -ItemType Directory -Force -Path (Join-Path $cU 'pipelines') | Out-Null
                Set-Content -Path (Join-Path $cU 'pipelines\warm-done.txt') -Value 'bbbb000000000000 k1' -Encoding ASCII
                $mkU = New-WarmRecord
                $mkU.Project = $proj; $mkU.Exe = $exe; $mkU.Commit = 'commitA'; $mkU.Translator = $trId; $mkU.Driver = '566.03'
                $mkU.ShadersDone = $true; $mkU.ShadersComplete = $true; $mkU.ShadersTime = (Get-Date).ToString('o')
                $mkU.PipesDone = $true; $mkU.PipesComplete = $true; $mkU.PipesFingerprint = 'bbbb000000000000'; $mkU.PipesTime = (Get-Date).ToString('o')
                $mkU.PipesUnsupported = $true
                Save-WarmMarker $cU $mkU
                $sU = Get-CacheState $proj $exeTime $trId $cU 'commitA' $exe '566.03'
                $okU2 = ($sU.State -eq 'partial') -and ($sU.Text -match '不支持管线预编译')
            } catch { $okU2 = $false; $lines += ("  unsupported-state ERR: " + $_.Exception.Message) }
            finally { try { if (Test-Path $cU) { Remove-Item $cU -Recurse -Force -EA SilentlyContinue } } catch { } }
            if ($okU2) { $pass++ } else { $fail++ }
            $lines += ("[{0}] unsupported-state -> {1} | {2}" -f $(if ($okU2) { 'PASS' } else { 'FAIL' }), $(if ($sU) { $sU.State } else { 'null' }), $(if ($sU) { $sU.Text } else { '' }))

            # --- 跑完的预热要记成「完成」（现在按差集判定，而不是按开始时还有几条要做）
            # 空缓存：warm 报 “0 to make”，但没有管线记录 → 不能算完成
            $oEmpty = Get-WarmOutcome 'pipelines' 0 0 0 0 0 0 0 $true -1
            $okEmpty = ($oEmpty.Done -eq $true) -and ($oEmpty.Complete -eq $false) -and ($oEmpty.Note -match '还没有任何管线记录')
            if ($okEmpty) { $pass++ } else { $fail++ }
            $lines += ("[{0}] empty-cache-not-complete -> done={1} complete={2} | {3}" -f $(if ($okEmpty) { 'PASS' } else { 'FAIL' }), $oEmpty.Done, $oEmpty.Complete, $oEmpty.Note)
            $oW = Get-WarmOutcome 'pipelines' 0 500 0 3 520 1 1 $true 0
            $oW2 = Get-WarmOutcome 'pipelines' 0 500 0 3 520 1 1 $true 7
            $okOutcome2 = ($oW.Done -and $oW.Complete) -and ($oW2.Done -and -not $oW2.Complete)
            if ($okOutcome2) { $pass++ } else { $fail++ }
            $lines += ("[{0}] outcome-by-missing complete={1} partial={2} | {3}" -f $(if ($okOutcome2) { 'PASS' } else { 'FAIL' }), $oW.Complete, $oW2.Note, $oW.Note)

            # --- 盘符不存在时拼路径不能炸（用户机器只有 D:，配置里却是 E:\gta6）
            $okPath = ((Test-RootUsable 'Z:\gta6') -eq $false) -and ((Test-RootUsable 'E:\gta6') -eq $true) -and ((Combine-Path 'Z:\gta6' 'cache') -eq 'Z:\gta6\cache')
            if ($okPath) { $pass++ } else { $fail++ }
            $lines += ("[{0}] missing-drive-safe combine={1} usableZ={2}" -f $(if ($okPath) { 'PASS' } else { 'FAIL' }), (Combine-Path 'Z:\gta6' 'cache'), (Test-RootUsable 'Z:\gta6'))
            # --- 「这个构建支不支持预热」的判定（选中就提示，不用等点了才说没产出）
            $helpOk = "Commands:`n  shaders      Translate every shader found...`n  warm         Make the host pipelines..."
            $helpBad = "error: unrecognized subcommand 'warm'`n`nUsage: victory.exe <COMMAND>"
            $okH = ((Test-HelpTextFor $helpOk 'warm') -eq $true) -and
                   ((Test-HelpTextFor $helpBad 'warm') -eq $false) -and
                   ((Test-HelpTextFor "$helpOk" 'shaders') -eq $true) -and
                   ($null -eq (Test-HelpTextFor '' 'warm'))
            if ($okH) { $pass++ } else { $fail++ }
            $lines += ("[{0}] help-text parse warm/shaders" -f $(if ($okH) { 'PASS' } else { 'FAIL' }))

            $fakeDir = Join-Path $env:TEMP ('gta6-fakebuild-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            try {
                New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
                $oldExe = Join-Path $fakeDir 'victory-old.bat'
                Set-Content -Path $oldExe -Value "@echo off`r`necho error: unrecognized subcommand 'warm'`r`nexit /b 2" -Encoding ASCII
                $newExe = Join-Path $fakeDir 'victory-new.bat'
                Set-Content -Path $newExe -Value "@echo off`r`necho Commands:`r`necho   shaders   translate all shaders`r`necho   warm      make host pipelines`r`nexit /b 0" -Encoding ASCII
                $capOld = Get-BuildWarmCapability $oldExe
                $capNew = Get-BuildWarmCapability $newExe
                $okCap = ($capOld.None -eq $true) -and ($capOld.Text -match '不支持预热') -and
                         ($capNew.Shaders -eq $true) -and ($capNew.Pipes -eq $true) -and (-not $capNew.Text)
                if ($okCap) { $pass++ } else { $fail++ }
                $lines += ("[{0}] capability old=None({1}) new=sh+pipe({2})" -f $(if ($okCap) { 'PASS' } else { 'FAIL' }), $capOld.Text, $capNew.Pipes)
            } catch {
                $fail++
                $lines += ("capability ERR: " + $_.Exception.Message)
            } finally {
                try { if (Test-Path $fakeDir) { Remove-Item $fakeDir -Recurse -Force -EA SilentlyContinue } } catch { }
            }

            # --- 剩下的管线是“驱动/引擎编不出来”：记成已完成并把拒绝数写进文案，不再一直说未完成
            $cR = Join-Path $env:TEMP ('gta6-refused-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $okR = $false
            try {
                foreach ($i in 0..39) { New-Item -ItemType Directory -Force -Path (Join-Path $cR ("shaders\{0:x2}" -f $i)) | Out-Null }
                Set-Content -Path (Join-Path $cR 'shaders\00\x1') -Value 'x' -Encoding ASCII
                New-Item -ItemType Directory -Force -Path (Join-Path $cR 'pipelines') | Out-Null
                Set-Content -Path (Join-Path $cR 'pipelines\warm-done.txt') -Value 'bbbb000000000000 k1' -Encoding ASCII
                Set-Content -Path (Join-Path $cR 'pipelines\early-pipelines.txt') -Value ("k1`nk2") -Encoding ASCII
                $mkR = New-WarmRecord
                $mkR.Project = $proj; $mkR.Exe = $exe; $mkR.Commit = 'commitA'; $mkR.Translator = $trId; $mkR.Driver = '566.03'
                $mkR.ShadersDone = $true; $mkR.ShadersComplete = $true; $mkR.ShadersTime = (Get-Date).ToString('o')
                $mkR.PipesDone = $true; $mkR.PipesComplete = $true; $mkR.PipesRefused = 48
                $mkR.PipesFingerprint = 'bbbb000000000000'; $mkR.PipesTime = (Get-Date).ToString('o')
                Save-WarmMarker $cR $mkR
                $sR = Get-CacheState $proj $exeTime $trId $cR 'commitA' $exe '566.03'
                $okR = ($sR.State -eq 'ok') -and ($sR.Text -match '另有 48 条')
                $lines += ("[{0}] refused-mark -> {1} | {2}" -f $(if ($okR) { 'PASS' } else { 'FAIL' }), $sR.State, $sR.Text)
            } catch { $lines += ("  refused ERR: " + $_.Exception.Message) }
            finally { try { if (Test-Path $cR) { Remove-Item $cR -Recurse -Force -EA SilentlyContinue } } catch { } }
            if ($okR) { $pass++ } else { $fail++ }
            # --- 关光追清单：逗号/换行都能解析，只认 16 位十六进制，重复去重
            $rtTmp = Join-Path $env:TEMP ('gta6-rt-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
            try {
                Set-Content -Path $rtTmp -Value ("002f8eb4802deb36,008f3e09ac72b1e0,XBOX,12`r`n009411de14bdaf7c,002f8EB4802DEB36,") -Encoding ASCII
                $rt = @(Get-RtSkipHashes $rtTmp)
                $okRt = ($rt.Count -eq 3) -and ($rt -contains '002f8eb4802deb36') -and ($rt -contains '009411de14bdaf7c')
                $lines += ("[{0}] rt-hash-parse count={1}" -f $(if ($okRt) { 'PASS' } else { 'FAIL' }), $rt.Count)
            } catch { $lines += ("  rt ERR: " + $_.Exception.Message); $okRt = $false }
            finally { try { if (Test-Path $rtTmp) { Remove-Item $rtTmp -Force -EA SilentlyContinue } } catch { } }
            if ($okRt) { $pass++ } else { $fail++ }
            # --- 带空格的路径要加引号（否则 victory 把 "GTA6 Xbox" 拆成两个参数）
            $q1 = Quote-Arg 'D:\Game\GTA6 Xbox v1 0 2 1 CYBERLEEK\shaders.rpf'
            $q2 = Quote-Arg 'C:\plain\victory.exe'
            $q3 = Quote-Arg 'C:\dir with space\'
            $okQ = ($q1.StartsWith('"') -and $q1.EndsWith('"')) -and ($q2 -eq 'C:\plain\victory.exe') -and ($q3.EndsWith('\"'))
            if ($okQ) { $pass++ } else { $fail++ }
            $lines += ("[{0}] quote-arg spaced={1} plain={2}" -f $(if ($okQ) { 'PASS' } else { 'FAIL' }), $q1, $q2)

            # --- 记录说“完成”但缓存是空的（预热没真跑起来）→ 不能报就绪
            $cE = Join-Path $env:TEMP ('gta6-emptyrec-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $okE = $false
            try {
                New-Item -ItemType Directory -Force -Path $cE | Out-Null
                $mkE = New-WarmRecord
                $mkE.Project = $proj; $mkE.Exe = $exe; $mkE.Commit = 'commitA'; $mkE.Translator = $trId; $mkE.Driver = '566.03'
                $mkE.ShadersDone = $true; $mkE.ShadersComplete = $true; $mkE.ShadersTime = (Get-Date).ToString('o')
                $mkE.PipesDone = $true; $mkE.PipesComplete = $true; $mkE.PipesTime = (Get-Date).ToString('o')
                Save-WarmMarker $cE $mkE
                $sE = Get-CacheState $proj $exeTime $trId $cE 'commitA' $exe '566.03'
                $okE = ($sE.State -ne 'ok')
                $lines += ("[{0}] complete-but-empty -> {1} | {2}" -f $(if ($okE) { 'PASS' } else { 'FAIL' }), $sE.State, $sE.Text)
            } catch { $lines += ("  emptyrec ERR: " + $_.Exception.Message) }
            finally { try { if (Test-Path $cE) { Remove-Item $cE -Recurse -Force -EA SilentlyContinue } } catch { } }
            if ($okE) { $pass++ } else { $fail++ }
            # --- A 卡 / N 卡都要认（含「核显 + 独显」的机器）
        $igpu = [pscustomobject]@{ Name = 'Intel(R) UHD Graphics 770'; AdapterRAM = 2147483648; DriverVersion = '32.0.101.5860' }
        $nvCard = [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3070'; AdapterRAM = 8589934592; DriverVersion = '621.24' }
        $amdCard = [pscustomobject]@{ Name = 'AMD Radeon RX 7900 XTX'; AdapterRAM = 0; DriverVersion = '32.0.21025.10016' }
        $svgV = @(
            ((Get-GpuVendor 'AMD Radeon RX 7900 XTX') -eq 'AMD'),
            ((Get-GpuVendor 'NVIDIA GeForce RTX 3070 Ti Laptop GPU') -eq 'NVIDIA'),
            ((Get-GpuVendor 'Intel(R) UHD Graphics 630') -eq 'Intel'),
            ((Get-GpuVendor 'Microsoft Basic Display Adapter') -eq 'Other')
        )
        $okV = ($svgV -notcontains $false)
        if ($okV) { $pass++ } else { $fail++ }
        $lines += ("[{0}] vendor-names amd/nv/intel/other" -f $(if ($okV) { 'PASS' } else { 'FAIL' }))

        $pick1 = Select-BestGpu @($igpu, $amdCard)
        $pick2 = Select-BestGpu @($igpu, $nvCard)
        $pick3 = Select-BestGpu @($igpu)
        $okPick = ($pick1 -and (Get-GpuVendor $pick1.Name) -eq 'AMD') -and ($pick2 -and (Get-GpuVendor $pick2.Name) -eq 'NVIDIA') -and ($pick3 -and (Get-GpuVendor $pick3.Name) -eq 'Intel')
        if ($okPick) { $pass++ } else { $fail++ }
        $lines += ("[{0}] igpu+amd -> {1} | igpu+nv -> {2} | igpu-only -> {3}" -f $(if ($okPick) { 'PASS' } else { 'FAIL' }), $pick1.Name, $pick2.Name, $pick3.Name)

        $recAmd = Recommend ([pscustomobject]@{ Vendor = 'AMD'; VramMB = 24576 })
        $recNv = Recommend ([pscustomobject]@{ Vendor = 'NVIDIA'; VramMB = 8192 })
        $recIntel = Recommend ([pscustomobject]@{ Vendor = 'Intel'; VramMB = 2048 })
        $okRec = ($recAmd.Build -eq 'amd') -and ($recAmd.Console -eq 'series-x') -and ($recAmd.Height -ge 1080) -and
                 ($recNv.Build -eq 'nvidia') -and ($recNv.Console -eq 'series-s') -and ($recNv.Height -eq 540) -and
                 ($recIntel.Build -eq 'unknown')
        if ($okRec) { $pass++ } else { $fail++ }
        $lines += ("[{0}] recommend amd={1}/{2}p/{3} nv={4}/{5}p/{6} intel={7}" -f $(if ($okRec) { 'PASS' } else { 'FAIL' }), $recAmd.Build, $recAmd.Height, $recAmd.Console, $recNv.Build, $recNv.Height, $recNv.Console, $recIntel.Build)

        $vramReg = Get-VramFromRegistry 'AMD Radeon RX 7900 XTX' 0
        $okReg = ($null -ne $vramReg) -and ($vramReg -ge 0)
        if ($okReg) { $pass++ } else { $fail++ }
        $lines += ("[{0}] vram-registry -> {1} MB" -f $(if ($okReg) { 'PASS' } else { 'FAIL' }), $vramReg)

        $lines += ("RESULT: pass={0} fail={1}" -f $pass, $fail)
        Set-Content -Path $env:GTA6_LAUNCHER_CACHETEST -Value ($lines -join "`r`n") -Encoding UTF8
        $form.Close()
    }
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
            $lines += "translatorId=$(Get-TranslatorId $script:builds[$lstBuilds.SelectedIndex].Project $script:builds[$lstBuilds.SelectedIndex].Exe)"
            $lines += "driver=$($script:driverVer)"
            $lines += "cacheState=$(($script:cacheState).State) | $(($script:cacheState).Text)"
            foreach ($d in @(($script:cacheState).Details)) { $lines += "  cache: $d" }
            $lines += "gameDir=$($tbGame.Text.Trim())"
            $lines += "buildRoot=$($tbBuildRoot.Text.Trim())"
            $lines += "cacheRoot=$($tbCacheRoot.Text.Trim())"
            $lines += "saveRoot=$($tbSaveRoot.Text.Trim())"
            $lines += "dlDir=$($tbDlDir.Text.Trim())"
            $lines += ("pathNotes=" + (@($script:pathNotes) -join ' / '))
            $lines += "cacheDir=$($script:cacheDir)"
            $lines += "dataDir=$($script:dataDir)"
            $lines += "marker=$(Test-Path (Join-Path $script:cacheDir $script:markerName))"
            Set-Content -Path $env:GTA6_LAUNCHER_SELFTEST -Value ($lines -join "`r`n") -Encoding UTF8
        } catch { Set-Content -Path $env:GTA6_LAUNCHER_SELFTEST -Value ("ERR " + $_.Exception.Message) }
        $form.Close()
    }
})

$lblAuthor = New-Label '作者: DKTTT (github.com/DKTTT)  ·  基于 VIctory 社区项目 (avatarmanz / trustno1-coder / fxceless / codec-d)  ·  v1.0' 16 776 1012 20 8.5 $Muted
$form.Controls.Add($lblAuthor)
Add-Log 'GTA VI 自动启动器 v1.9.8 by DKTTT'
[void]$form.ShowDialog()
