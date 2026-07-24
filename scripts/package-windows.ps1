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

$version = (Get-Content (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'VERSION must contain a three-part numeric version such as 0.2.0.'
}
$embeddedVersion = (Get-Item $executable).VersionInfo.ProductVersion
$embeddedVersionMatch = [regex]::Match($embeddedVersion, '^(\d+\.\d+\.\d+)')
if (-not $embeddedVersionMatch.Success) {
    throw "colorful.exe has no usable embedded product version. Rebuild it before packaging."
}
$builtVersion = $embeddedVersionMatch.Groups[1].Value
if ($builtVersion -ne $version) {
    throw "colorful.exe is version $builtVersion, but VERSION is $version. Rebuild it before packaging."
}
$git = Get-Command git.exe -ErrorAction Stop
$commit = (& $git.Source -C $repoRoot rev-parse --short=12 HEAD).Trim()
$buildChannel = if ($env:COLORFUL_BUILD_CHANNEL) { $env:COLORFUL_BUILD_CHANNEL } else { 'release' }
switch ($buildChannel) {
    'release' { $artifactVersion = $version }
    'dev' {
        $buildNumber = if ($env:COLORFUL_BUILD_NUMBER) { $env:COLORFUL_BUILD_NUMBER } else { 'local' }
        $artifactVersion = "$version-dev.$buildNumber"
    }
    default { throw 'COLORFUL_BUILD_CHANNEL must be release or dev.' }
}
$artifactName = "colorful-windows-x64-$artifactVersion-$commit"
$distRoot = Join-Path $repoRoot 'dist'
$stage = Join-Path $distRoot $artifactName
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item $stage -ItemType Directory -Force | Out-Null

$runtimeFiles = @(
    'colorful.exe', 'colorful_core.dll', 'colorful-credential-helper.exe',
    'colorful-provider.exe', 'mpv-2.dll', 'vulkan-1.dll',
    'ffmpeg.exe', 'ffprobe.exe'
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
$tar = Get-Command tar.exe -ErrorAction Stop
Push-Location $stage
try {
    & $tar.Source -a -c -f $zip '.'
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
Write-Host "Portable archive: $zip"

if ($Installer) {
    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $isccCandidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        ) | Where-Object { $_ -and (Test-Path $_) }
        $iscc = $isccCandidates | Select-Object -First 1
    }
    if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it or package without -Installer.' }
    $isccPath = if ($iscc -is [System.Management.Automation.CommandInfo]) { $iscc.Source } else { $iscc }
    & $isccPath "/DSourceDir=$stage" "/DOutputDir=$distRoot" "/DAppVersion=$version" `
        "/DBuildLabel=$artifactVersion" "/DCommit=$commit" `
        (Join-Path $repoRoot 'packaging\windows\colorful.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }
}
