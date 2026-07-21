[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path -Parent $PSScriptRoot

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$env:Path = "$userPath;$machinePath;$env:Path"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw 'Visual Studio Installer (vswhere.exe) was not found.'
}

$visualStudio = & $vswhere `
    -latest `
    -products '*' `
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
    $name = $line.Substring(0, $separator)
    $value = $line.Substring($separator + 1)
    Set-Item -Path "Env:$name" -Value $value
}

$cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
if (-not $cargo) {
    # The Windows VM is provisioned through a restricted build account. When
    # the interactive desktop user launches this checkout, infer the profile
    # that owns <profile>\src\colorful instead of requiring a second Rust SDK.
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
    throw 'Rust Cargo was not found. Install Rust with rustup or set CARGO_HOME and RUSTUP_HOME before building.'
}

Push-Location $repoRoot
try {
    $cargoArguments = @('build', '-p', 'colorful-core')
    if ($Configuration -eq 'Release') {
        $cargoArguments += '--release'
    }
    & $cargo.Source @cargoArguments
    if ($LASTEXITCODE -ne 0) { throw "Rust build failed with exit code $LASTEXITCODE." }

    & dotnet build `
        '.\apps\windows\Colorful.Windows.csproj' `
        '--configuration' $Configuration `
        '-p:Platform=x64'
    if ($LASTEXITCODE -ne 0) { throw "WinUI build failed with exit code $LASTEXITCODE." }
} finally {
    Pop-Location
}
