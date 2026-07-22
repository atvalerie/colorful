[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [string]$QtRoot = $env:COLORFUL_QT_ROOT,
    [string]$MpvRoot = $env:COLORFUL_MPV_ROOT
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path -Parent $PSScriptRoot

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$env:Path = "$userPath;$machinePath;$env:Path"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw 'Visual Studio Installer (vswhere.exe) was not found.'
}
$visualStudio = & $vswhere -latest -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $visualStudio) {
    throw 'Visual Studio with the MSVC x64 build tools was not found.'
}
$vsDevCmd = Join-Path $visualStudio 'Common7\Tools\VsDevCmd.bat'
$environmentLines = & cmd.exe /d /s /c "`"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 && set"
foreach ($line in $environmentLines) {
    $separator = $line.IndexOf('=')
    if ($separator -le 0) { continue }
    Set-Item -Path "Env:$($line.Substring(0, $separator))" -Value $line.Substring($separator + 1)
}

if (-not $QtRoot) {
    $qtCandidates = Get-ChildItem (Join-Path $env:USERPROFILE 'Qt') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'msvc2022_64' } |
        Where-Object { Test-Path (Join-Path $_ 'bin\windeployqt.exe') }
    $QtRoot = $qtCandidates | Select-Object -First 1
}
if (-not $QtRoot -or -not (Test-Path (Join-Path $QtRoot 'bin\windeployqt.exe'))) {
    throw 'Qt 6 for MSVC 2022 x64 was not found. Set COLORFUL_QT_ROOT to its msvc2022_64 directory.'
}
if (-not $MpvRoot) {
    $MpvRoot = Join-Path $env:USERPROFILE 'colorful-deps\mpv'
}
if (-not (Test-Path (Join-Path $MpvRoot 'include\mpv\client.h'))) {
    throw "A libmpv development bundle was not found at $MpvRoot. Set COLORFUL_MPV_ROOT."
}

$cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
if (-not $cargo) {
    $sourceRoot = Split-Path -Parent $repoRoot
    $repoOwnerProfile = Split-Path -Parent $sourceRoot
    $repoOwnerCargoHome = Join-Path $repoOwnerProfile '.cargo'
    $repoOwnerRustupHome = Join-Path $repoOwnerProfile '.rustup'
    $repoOwnerCargo = Join-Path $repoOwnerCargoHome 'bin\cargo.exe'
    if (Test-Path $repoOwnerCargo) {
        $env:CARGO_HOME = $repoOwnerCargoHome
        $env:RUSTUP_HOME = $repoOwnerRustupHome
        $env:Path = "$(Split-Path -Parent $repoOwnerCargo);$env:Path"
        $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
    }
}
if (-not $cargo) {
    throw 'Rust Cargo was not found. Install Rust with rustup or set CARGO_HOME and RUSTUP_HOME.'
}

$profile = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
$buildDirectory = Join-Path $repoRoot 'build\windows-qt'

Push-Location $repoRoot
try {
    $cargoArguments = @('build', '-p', 'colorful-core')
    if ($Configuration -eq 'Release') { $cargoArguments += '--release' }
    & $cargo.Source @cargoArguments
    if ($LASTEXITCODE -ne 0) { throw "Rust build failed with exit code $LASTEXITCODE." }

    $coreDirectory = Join-Path $repoRoot "target\$profile"
    $coreLibrary = Join-Path $coreDirectory 'colorful_core.dll'
    $coreImportLibrary = @(
        (Join-Path $coreDirectory 'colorful_core.dll.lib'),
        (Join-Path $coreDirectory 'colorful_core.lib')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not (Test-Path $coreLibrary) -or -not $coreImportLibrary) {
        throw "Rust did not produce the colorful-core DLL and import library in $coreDirectory."
    }

    & cmake.exe `
        '-S' '.\apps\linux' `
        '-B' $buildDirectory `
        '-G' 'Ninja' `
        "-DCMAKE_BUILD_TYPE=$Configuration" `
        "-DCMAKE_PREFIX_PATH=$QtRoot" `
        "-DCOLORFUL_MPV_ROOT=$MpvRoot" `
        "-DCOLORFUL_CORE_LIBRARY=$coreLibrary" `
        "-DCOLORFUL_CORE_IMPORT_LIBRARY=$coreImportLibrary"
    if ($LASTEXITCODE -ne 0) { throw "Qt configure failed with exit code $LASTEXITCODE." }
    & cmake.exe --build $buildDirectory --parallel
    if ($LASTEXITCODE -ne 0) { throw "Qt build failed with exit code $LASTEXITCODE." }

    $executable = Join-Path $buildDirectory 'colorful.exe'
    $deployArguments = @('--qmldir', (Join-Path $repoRoot 'apps\linux\qml'))
    $deployArguments += if ($Configuration -eq 'Debug') { '--debug' } else { '--release' }
    $deployArguments += $executable
    & (Join-Path $QtRoot 'bin\windeployqt.exe') @deployArguments
    if ($LASTEXITCODE -ne 0) { throw "Qt deployment failed with exit code $LASTEXITCODE." }
    Write-Host "Built $executable"
} finally {
    Pop-Location
}
