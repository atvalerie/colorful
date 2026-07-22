[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$arguments = @{ Configuration = $Configuration }
if ($NoBuild) { $arguments.NoBuild = $true }
& (Join-Path $PSScriptRoot 'run-windows-qt.ps1') @arguments
