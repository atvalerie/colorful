[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [string]$QtRoot = $env:COLORFUL_QT_ROOT,
    [string]$MpvRoot = $env:COLORFUL_MPV_ROOT
)

$ErrorActionPreference = 'Stop'
$arguments = @{ Configuration = $Configuration }
if ($QtRoot) { $arguments.QtRoot = $QtRoot }
if ($MpvRoot) { $arguments.MpvRoot = $MpvRoot }
& (Join-Path $PSScriptRoot 'build-windows-qt.ps1') @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
