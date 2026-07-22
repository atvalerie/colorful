[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build-windows-qt.ps1') -Configuration $Configuration
}

$executable = Join-Path $repoRoot 'build\windows-qt\colorful.exe'
if (-not (Test-Path $executable)) {
    throw "The Qt Windows executable was not found at $executable"
}
Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable)
