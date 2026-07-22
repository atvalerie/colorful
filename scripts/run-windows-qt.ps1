[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Import-ColorfulEnvironment([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('export ')) { $trimmed = $trimmed.Substring(7).Trim() }
        $separator = $trimmed.IndexOf('=')
        if ($separator -le 0) { continue }
        $name = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($name -match '^[A-Za-z_][A-Za-z0-9_]*$') {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

$siblingEnvironment = Join-Path (Split-Path -Parent $repoRoot) 'mocha\.env'
$repoEnvironment = Join-Path $repoRoot '.env'
Import-ColorfulEnvironment $siblingEnvironment
Import-ColorfulEnvironment $repoEnvironment

if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build-windows-qt.ps1') -Configuration $Configuration
}

$executable = Join-Path $repoRoot 'build\windows-qt\colorful.exe'
if (-not (Test-Path $executable)) {
    throw "The Qt Windows executable was not found at $executable"
}
$buildDirectory = Split-Path -Parent $executable
$stagedProvider = Join-Path $buildDirectory 'colorful-provider.next.exe'
$provider = Join-Path $buildDirectory 'colorful-provider.exe'
if (Test-Path $stagedProvider) {
    try {
        Move-Item $stagedProvider $provider -Force
    } catch {
        throw 'A colorful process is still using the old provider. Close colorful, then launch it again.'
    }
}
Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable)
