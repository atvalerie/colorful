[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild,
    [switch]$Installer
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build-windows-qt.ps1') -Configuration $Configuration
}

$buildDirectory = Join-Path $repoRoot 'build\windows-qt'
$executable = Join-Path $buildDirectory 'colorful.exe'
if (-not (Test-Path $executable)) { throw "colorful.exe was not found at $executable" }

$git = Get-Command git.exe -ErrorAction Stop
$commit = (& $git.Source -C $repoRoot rev-parse --short=12 HEAD).Trim()
$version = '0.1.0'
$artifactName = "colorful-windows-x64-$version-$commit"
$distRoot = Join-Path $repoRoot 'dist'
$stage = Join-Path $distRoot $artifactName
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item $stage -ItemType Directory -Force | Out-Null

$runtimeFiles = @(
    'colorful.exe', 'colorful_core.dll', 'colorful-credential-helper.exe',
    'colorful-provider.exe', 'mpv-2.dll', 'vulkan-1.dll',
    'yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe'
)
foreach ($name in $runtimeFiles) {
    $source = Join-Path $buildDirectory $name
    if (-not (Test-Path $source)) { throw "Required runtime file is missing: $source" }
    Copy-Item $source $stage -Force
}
Copy-Item (Join-Path $repoRoot 'LICENSE') $stage -Force
Copy-Item (Join-Path $repoRoot 'README.md') $stage -Force
Copy-Item (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') $stage -Force

$qtRoot = $env:COLORFUL_QT_ROOT
if (-not $qtRoot) {
    $qtRoot = Get-ChildItem (Join-Path $env:USERPROFILE 'Qt') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'msvc2022_64' } |
        Where-Object { Test-Path (Join-Path $_ 'bin\windeployqt.exe') } |
        Select-Object -First 1
}
if (-not $qtRoot) { throw 'Qt for MSVC was not found. Set COLORFUL_QT_ROOT.' }
$deploy = Join-Path $qtRoot 'bin\windeployqt.exe'
$deployArgs = @('--dir', $stage, '--qmldir', (Join-Path $repoRoot 'apps\linux\qml'), '--compiler-runtime')
$deployArgs += if ($Configuration -eq 'Release') { '--release' } else { '--debug' }
$deployArgs += (Join-Path $stage 'colorful.exe')
& $deploy @deployArgs
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed with exit code $LASTEXITCODE" }

$zip = Join-Path $distRoot "$artifactName-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host "Portable archive: $zip"

if ($Installer) {
    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it or package without -Installer.' }
    & $iscc.Source "/DSourceDir=$stage" "/DOutputDir=$distRoot" "/DAppVersion=$version" "/DCommit=$commit" `
        (Join-Path $repoRoot 'packaging\windows\colorful.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }
}
