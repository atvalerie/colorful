[CmdletBinding()]
param(
    [string]$QtVersion
)

# WinRM maps native stderr (including pip/aqt progress warnings) to the
# PowerShell error stream. Native exit codes are checked explicitly below.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'packaging\desktop-dependencies.json'
$pins = Get-Content $manifestPath -Raw | ConvertFrom-Json
if (-not $QtVersion) { $QtVersion = $pins.toolchains.qt }

function Invoke-ResilientDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [hashtable]$Headers = @{},
        [int]$Attempts = 4
    )

    $partial = "$OutFile.partial"
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Remove-Item $partial -Force -ErrorAction SilentlyContinue
        try {
            Write-Host "Downloading $Uri (attempt $attempt of $Attempts)"
            Invoke-WebRequest -Uri $Uri -OutFile $partial -Headers $Headers `
                -UseBasicParsing -ErrorAction Stop
            if (-not (Test-Path $partial) -or (Get-Item $partial).Length -eq 0) {
                throw 'The download completed without producing a non-empty file.'
            }
            $actual = (Get-FileHash -Path $partial -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $Sha256.ToLowerInvariant()) {
                throw "SHA-256 mismatch: expected $Sha256, got $actual."
            }
            Move-Item $partial $OutFile -Force
            return
        } catch {
            Remove-Item $partial -Force -ErrorAction SilentlyContinue
            if ($attempt -eq $Attempts) {
                throw "Download failed after $Attempts attempts: $Uri`n$($_.Exception.Message)"
            }
            $delay = [Math]::Pow(2, $attempt)
            Write-Warning "Download attempt $attempt failed: $($_.Exception.Message). Retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

function Test-PinMarker {
    param([string]$Root, [string]$Expected)
    $marker = Join-Path $Root '.colorful-pin'
    return (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $Expected)
}

function Set-PinMarker {
    param([string]$Root, [string]$Value)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Set-Content -Path (Join-Path $Root '.colorful-pin') -Value $Value -Encoding ascii
}

$toolsRoot = Join-Path $env:USERPROFILE 'colorful-deps'
$pythonRoot = Join-Path $toolsRoot 'python'
$python = Join-Path $pythonRoot 'python.exe'
$qtRoot = Join-Path $env:USERPROFILE 'Qt'
$qtPlatformRoot = Join-Path $qtRoot "$QtVersion\msvc2022_64"
$mpvRoot = Join-Path $toolsRoot 'mpv'
$vulkanRoot = Join-Path $toolsRoot 'vulkan'
$vulkanRuntime = Join-Path $vulkanRoot 'vulkan-1.dll'
$mediaToolsRoot = Join-Path $toolsRoot 'media-tools'
$ffmpeg = Join-Path $mediaToolsRoot 'ffmpeg.exe'
$ffprobe = Join-Path $mediaToolsRoot 'ffprobe.exe'
New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null

$pythonPin = $pins.toolchains.python
if (-not (Test-PinMarker $pythonRoot $pythonPin) -or -not (Test-Path $python)) {
    if (Test-Path $pythonRoot) { Remove-Item $pythonRoot -Recurse -Force }
    $pythonArchive = Join-Path $env:TEMP 'colorful-python.zip'
    Invoke-ResilientDownload `
        -Uri $pins.windows.python.url `
        -OutFile $pythonArchive `
        -Sha256 $pins.windows.python.sha256
    New-Item -ItemType Directory -Path $pythonRoot -Force | Out-Null
    Expand-Archive -Path $pythonArchive -DestinationPath $pythonRoot -Force
    $pathFile = Get-ChildItem $pythonRoot -Filter 'python*._pth' | Select-Object -First 1
    if (-not $pathFile) { throw 'The embedded Python path configuration was not found.' }
    (Get-Content $pathFile.FullName) -replace '^#import site$', 'import site' |
        Set-Content $pathFile.FullName -Encoding ascii
    $getPip = Join-Path $env:TEMP 'get-pip.py'
    Invoke-ResilientDownload -Uri $pins.windows.getPip.url -OutFile $getPip `
        -Sha256 $pins.windows.getPip.sha256
    & $python $getPip --disable-pip-version-check 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "pip bootstrap failed with exit code $LASTEXITCODE." }
    Set-PinMarker $pythonRoot $pythonPin
}

$pythonToolsPin = @(
    $pins.toolchains.aqtinstall, $pins.toolchains.py7zr,
    $pins.toolchains.cmake, $pins.toolchains.ninja
) -join '-'
$pythonToolsMarker = Join-Path $pythonRoot '.colorful-build-tools-pin'
if (-not (Test-Path $pythonToolsMarker) `
        -or (Get-Content $pythonToolsMarker -Raw).Trim() -ne $pythonToolsPin) {
    & $python -m pip install --disable-pip-version-check `
        "aqtinstall==$($pins.toolchains.aqtinstall)" `
        "py7zr==$($pins.toolchains.py7zr)" `
        "cmake==$($pins.toolchains.cmake)" `
        "ninja==$($pins.toolchains.ninja)" 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Pinned Python build tools failed to install with exit code $LASTEXITCODE." }
    Set-Content -Path $pythonToolsMarker -Value $pythonToolsPin -Encoding ascii
}

if (-not (Test-Path $qtPlatformRoot)) {
    & $python -m aqt install-qt windows desktop $QtVersion win64_msvc2022_64 `
        --outputdir $qtRoot 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Qt installation failed with exit code $LASTEXITCODE." }
}

$mpvRuntime = Join-Path $mpvRoot 'bin\mpv-2.dll'
$mpvReady = (Test-Path (Join-Path $mpvRoot 'include\mpv\client.h')) -and `
    (Test-Path $mpvRuntime) -and ((Get-Item $mpvRuntime).Length -gt 10MB) -and `
    (Test-PinMarker $mpvRoot $pins.mpv.sourceVersion)
if (-not $mpvReady) {
    if (Test-Path $mpvRoot) { Remove-Item $mpvRoot -Recurse -Force }
    $archive = Join-Path $env:TEMP $pins.windows.mpv.asset
    $extracted = Join-Path $env:TEMP 'colorful-mpv-extracted'
    Invoke-ResilientDownload -Uri $pins.windows.mpv.url -OutFile $archive `
        -Sha256 $pins.windows.mpv.sha256 `
        -Headers @{ 'User-Agent' = 'colorful-build'; 'Accept' = 'application/octet-stream' }
    if (Test-Path $extracted) { Remove-Item $extracted -Recurse -Force }
    New-Item -ItemType Directory -Path $extracted -Force | Out-Null
    & $python -c 'import py7zr,sys; py7zr.SevenZipFile(sys.argv[1], mode="r").extractall(path=sys.argv[2])' `
        $archive $extracted 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "libmpv extraction failed with exit code $LASTEXITCODE." }

    $clientHeader = Get-ChildItem $extracted -Filter client.h -Recurse |
        Where-Object { $_.Directory.Name -eq 'mpv' } | Select-Object -First 1
    $runtime = Get-ChildItem $extracted -Filter 'libmpv-2.dll' -Recurse | Select-Object -First 1
    if (-not $runtime) {
        $runtime = Get-ChildItem $extracted -Filter 'mpv-2.dll' -Recurse | Select-Object -First 1
    }
    if (-not $clientHeader -or -not $runtime) { throw 'The libmpv bundle layout was not recognized.' }
    New-Item -ItemType Directory -Path (Join-Path $mpvRoot 'include\mpv') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mpvRoot 'bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mpvRoot 'lib') -Force | Out-Null
    Copy-Item (Join-Path $clientHeader.Directory.FullName '*') (Join-Path $mpvRoot 'include\mpv') -Recurse -Force
    Copy-Item $runtime.FullName (Join-Path $mpvRoot 'bin\mpv-2.dll') -Force
    Set-PinMarker $mpvRoot $pins.mpv.sourceVersion
}

$importLibrary = Join-Path $mpvRoot 'lib\mpv.lib'
if (-not (Test-Path $importLibrary)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $visualStudio = & $vswhere -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $visualStudio) { throw 'Visual Studio with MSVC x64 tools was not found.' }
    $vsDevCmd = Join-Path $visualStudio 'Common7\Tools\VsDevCmd.bat'
    $environmentLines = & cmd.exe /d /s /c "`"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 && set"
    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { continue }
        Set-Item -Path "Env:$($line.Substring(0, $separator))" -Value $line.Substring($separator + 1)
    }
    $runtime = Join-Path $mpvRoot 'bin\mpv-2.dll'
    $definition = Join-Path $mpvRoot 'lib\mpv.def'
    $dumpbin = Get-ChildItem (Join-Path $visualStudio 'VC\Tools\MSVC') -Filter dumpbin.exe -Recurse |
        Where-Object FullName -Like '*Hostx64\x64*' | Select-Object -First 1
    $libraryTool = Get-ChildItem (Join-Path $visualStudio 'VC\Tools\MSVC') -Filter lib.exe -Recurse |
        Where-Object FullName -Like '*Hostx64\x64*' | Select-Object -First 1
    if (-not $dumpbin -or -not $libraryTool) { throw 'The MSVC x64 library tools were not found.' }
    $exports = & $dumpbin.FullName /nologo /exports $runtime
    $names = $exports | ForEach-Object {
        if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)\s*$') { $Matches[1] }
    }
    if (-not $names) { throw 'No libmpv exports were found.' }
    @('LIBRARY mpv-2.dll', 'EXPORTS') + $names | Set-Content -Path $definition -Encoding ascii
    & $libraryTool.FullName /nologo "/def:$definition" /machine:x64 "/out:$importLibrary"
    if ($LASTEXITCODE -ne 0) { throw "libmpv import-library generation failed with exit code $LASTEXITCODE." }
}

if (-not (Test-PinMarker $vulkanRoot $pins.windows.vulkan.version) -or -not (Test-Path $vulkanRuntime)) {
    if (Test-Path $vulkanRoot) { Remove-Item $vulkanRoot -Recurse -Force }
    $vulkanArchive = Join-Path $env:TEMP 'colorful-vulkan-runtime.zip'
    $vulkanExtracted = Join-Path $env:TEMP 'colorful-vulkan-runtime'
    Invoke-ResilientDownload `
        -Uri $pins.windows.vulkan.url `
        -OutFile $vulkanArchive `
        -Sha256 $pins.windows.vulkan.sha256
    if (Test-Path $vulkanExtracted) { Remove-Item $vulkanExtracted -Recurse -Force }
    Expand-Archive -Path $vulkanArchive -DestinationPath $vulkanExtracted -Force
    $loader = Get-ChildItem $vulkanExtracted -Filter 'vulkan-1.dll' -Recurse |
        Where-Object { $_.FullName -like '*\x64\vulkan-1.dll' } |
        Select-Object -First 1
    if (-not $loader) { throw 'The official Vulkan runtime archive had no x64 loader.' }
    New-Item -ItemType Directory -Path $vulkanRoot -Force | Out-Null
    Copy-Item $loader.FullName $vulkanRuntime -Force
    Set-PinMarker $vulkanRoot $pins.windows.vulkan.version
}

New-Item -ItemType Directory -Path $mediaToolsRoot -Force | Out-Null
$githubHeaders = @{ 'User-Agent' = 'colorful-build' }
if (-not (Test-PinMarker $mediaToolsRoot $pins.windows.ffmpeg.version) `
        -or -not (Test-Path $ffmpeg) -or -not (Test-Path $ffprobe)) {
    if (Test-Path $mediaToolsRoot) { Remove-Item $mediaToolsRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $mediaToolsRoot -Force | Out-Null
    $ffmpegArchive = Join-Path $env:TEMP $pins.windows.ffmpeg.asset
    $ffmpegExtracted = Join-Path $env:TEMP 'colorful-ffmpeg'
    Invoke-ResilientDownload -Uri $pins.windows.ffmpeg.url -OutFile $ffmpegArchive `
        -Sha256 $pins.windows.ffmpeg.sha256 `
        -Headers $githubHeaders
    if (Test-Path $ffmpegExtracted) { Remove-Item $ffmpegExtracted -Recurse -Force }
    Expand-Archive -Path $ffmpegArchive -DestinationPath $ffmpegExtracted -Force
    $resolvedFfmpeg = Get-ChildItem $ffmpegExtracted -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1
    $resolvedFfprobe = Get-ChildItem $ffmpegExtracted -Filter 'ffprobe.exe' -Recurse | Select-Object -First 1
    if (-not $resolvedFfmpeg -or -not $resolvedFfprobe) { throw 'The FFmpeg archive layout was not recognized.' }
    Copy-Item $resolvedFfmpeg.FullName $ffmpeg -Force
    Copy-Item $resolvedFfprobe.FullName $ffprobe -Force
    Set-PinMarker $mediaToolsRoot $pins.windows.ffmpeg.version
}

Write-Host "QtRoot=$qtPlatformRoot"
Write-Host "MpvRoot=$mpvRoot"
Write-Host "VulkanRuntime=$vulkanRuntime"
Write-Host "MediaToolsRoot=$mediaToolsRoot"
