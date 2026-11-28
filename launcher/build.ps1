# Build the launcher.
#   .\build.ps1                         one self-contained exe (about 75 MB); the ui folder (and the release's
#                                       other folders, if copied there) sit beside it: development layout
#   .\build.ps1 -Bundle <packageDir>    one self-contained exe with the package built in: victory.exe, ui,
#                                       amd-sdk, shvi and the docs are embedded as a zip and extracted to
#                                       %LOCALAPPDATA%\VictoryLauncher\payload-... on first start, so the
#                                       player only sees VictoryLauncher.exe
# Requires the .NET 8 SDK (https://dotnet.microsoft.com/download).
[CmdletBinding()]
param(
    # package folder to take amd-sdk, shvi and the docs from (the kernel comes from target\release)
    [string]$Bundle = ''
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$dist = Join-Path $PSScriptRoot 'dist'
$payloadDir = Join-Path $PSScriptRoot 'payload'
$payloadZip = Join-Path $PSScriptRoot 'payload.zip'
$modeFile = Join-Path $PSScriptRoot 'obj\.build-mode'

function Step([string]$text) { Write-Host $text -ForegroundColor Cyan }

if ($Bundle) {
    if (-not (Test-Path -LiteralPath $Bundle -PathType Container)) { throw "package folder not found: $Bundle" }
    $Bundle = (Resolve-Path -LiteralPath $Bundle).Path
    Step "payload: $Bundle"

    # staging (gitignored): the files that will be embedded, in the layout the launcher expects
    Remove-Item -LiteralPath $payloadDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $payloadZip -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $payloadDir | Out-Null

    # 1. the kernel: this tree's target\release\victory.exe, else the package's own copy
    $kernel = Join-Path (Split-Path $PSScriptRoot -Parent) 'target\release\victory.exe'
    if (-not (Test-Path -LiteralPath $kernel)) { $kernel = Join-Path $Bundle 'victory.exe' }
    if (-not (Test-Path -LiteralPath $kernel)) { throw "victory.exe not found: build the kernel first (cargo build --release)" }
    Copy-Item -LiteralPath $kernel -Destination (Join-Path $payloadDir 'victory.exe')
    Step ('kernel: {0:N1} MB' -f ((Get-Item -LiteralPath $kernel).Length / 1MB))

    # 2. the page: the launcher source's ui (the package may carry an older copy)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ui') -Destination (Join-Path $payloadDir 'ui') -Recurse

    # 3. the package's FidelityFX DLLs and the script hook / trainer (dlssg-sm86 and nvidia-sdk stay optional
    #    drop-in folders: too big, and only for NVIDIA cards)
    foreach ($name in 'amd-sdk', 'shvi') {
        $source = Join-Path $Bundle $name
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "$name not found in the package folder: $Bundle" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $payloadDir $name) -Recurse
    }

    # 4. the docs and bats the launcher opens (教程 / 启动器说明 / 修改器说明 / BUILD-INFO)
    $docPatterns = @('从零开始教程*.txt', 'README*.txt', '修改器说明*.txt', '启动-*.bat', 'BUILD-INFO*.txt', '更新说明*.txt', 'release.json', 'victory.ico')
    $copied = 0
    foreach ($pattern in $docPatterns) {
        foreach ($file in Get-ChildItem -LiteralPath $Bundle -Filter $pattern -File -ErrorAction SilentlyContinue) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $payloadDir $file.Name)
            $copied++
        }
    }
    if ($copied -eq 0) { throw "no docs found in the package folder: $Bundle" }
    Step "docs: $copied files"

    # 5. one zip: embedded in the exe (Neptune.csproj) and extracted on first start (Payload.cs)
    if (-not ('System.IO.Compression.ZipFile' -as [type])) { Add-Type -AssemblyName System.IO.Compression.FileSystem }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $payloadZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Step ('payload.zip: {0:N1} MB' -f ((Get-Item -LiteralPath $payloadZip).Length / 1MB))
}
elseif (Test-Path -LiteralPath $payloadDir) {
    # a plain build must not carry an old staging folder into the output
    Remove-Item -LiteralPath $payloadDir -Recurse -Force
    Remove-Item -LiteralPath $payloadZip -Force -ErrorAction SilentlyContinue
}

# Building with and without the payload changes the embedded resources: start from a clean obj when the mode
# changes so a stale embedded zip never ends up in a plain build (or the other way round)
$mode = if ($Bundle) { 'bundle' } else { 'plain' }
$lastMode = if (Test-Path -LiteralPath $modeFile) { (Get-Content -LiteralPath $modeFile -Raw).Trim() } else { '' }
if ($lastMode -ne $mode) {
    Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'obj') -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path (Split-Path $modeFile) -Force | Out-Null
    Set-Content -LiteralPath $modeFile -Value $mode -NoNewline
}

$publishArgs = @('publish', 'Neptune.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-o', 'dist')
if ($Bundle) { $publishArgs += "-p:BundlePayload=$payloadZip" }
Step ('dotnet ' + ($publishArgs -join ' '))
& dotnet @publishArgs
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit code $LASTEXITCODE)" }

if ($Bundle) {
    # the point of -Bundle: dist holds nothing but the exe (payload inside)
    Get-ChildItem -LiteralPath $dist -Force | Where-Object { $_.Name -ne 'VictoryLauncher.exe' } | Remove-Item -Recurse -Force
}

$exe = Join-Path $dist 'VictoryLauncher.exe'
$size = (Get-Item -LiteralPath $exe).Length / 1MB
$sha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
Write-Host ''
Write-Host 'Built: ' -NoNewline
Write-Host $exe -ForegroundColor Green
Write-Host ('Size: {0:N1} MB   SHA256 (first 16): {1}' -f $size, $sha.Substring(0, 16))
if ($Bundle) { Write-Host 'Payload: extracted on first start to %LOCALAPPDATA%\VictoryLauncher\payload-<version>-<hash>' }