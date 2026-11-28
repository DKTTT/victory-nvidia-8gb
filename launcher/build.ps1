# Build the launcher: one self-contained exe (about 75 MB) that needs the ui folder beside it.
# Requires the .NET 8 SDK (https://dotnet.microsoft.com/download).
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
dotnet publish Neptune.csproj -c Release -r win-x64 --self-contained true -o dist
Write-Host ''
Write-Host 'Built: ' -NoNewline
Write-Host (Join-Path $PSScriptRoot 'dist\VictoryLauncher.exe') -ForegroundColor Green
