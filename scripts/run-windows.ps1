[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$arguments = @('-Configuration', $Configuration)
if ($NoBuild) { $arguments += '-NoBuild' }
& (Join-Path $PSScriptRoot 'run-windows-qt.ps1') @arguments
