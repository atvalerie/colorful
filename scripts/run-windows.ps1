[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build-windows.ps1') -Configuration $Configuration
}

$executable = Join-Path $repoRoot (
    "apps\windows\bin\x64\$Configuration\net9.0-windows10.0.19041.0\win-x64\Colorful.Windows.exe"
)
if (-not (Test-Path $executable)) {
    throw "The Windows executable was not found at $executable"
}

Start-Process -FilePath $executable
