[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$versionFile = Join-Path $repoRoot 'VERSION'
$currentText = (Get-Content $versionFile -Raw).Trim()
if ($currentText -notmatch '^\d+\.\d+\.\d+$') {
    throw "The current VERSION value is invalid: $currentText"
}

$current = [Version]$currentText
$next = [Version]$Version
if (-not $Force -and $next -le $current) {
    throw "The new version must be greater than $currentText. Use -Force only to correct an accidental version."
}

Set-Content -Path $versionFile -Value $Version -Encoding ascii -NoNewline
Write-Host "colorful version: $currentText -> $Version"
Write-Host 'Commit VERSION with the release changes before creating distributable packages.'
