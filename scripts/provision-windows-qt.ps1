[CmdletBinding()]
param(
    [string]$QtVersion = '6.8.3'
)

# WinRM maps native stderr (including pip/aqt progress warnings) to the
# PowerShell error stream. Native exit codes are checked explicitly below.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
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

if (-not (Test-Path $python)) {
    $pythonArchive = Join-Path $env:TEMP 'colorful-python.zip'
    Invoke-WebRequest `
        -Uri 'https://www.python.org/ftp/python/3.13.5/python-3.13.5-embed-amd64.zip' `
        -OutFile $pythonArchive
    New-Item -ItemType Directory -Path $pythonRoot -Force | Out-Null
    Expand-Archive -Path $pythonArchive -DestinationPath $pythonRoot -Force
    $pathFile = Get-ChildItem $pythonRoot -Filter 'python*._pth' | Select-Object -First 1
    if (-not $pathFile) { throw 'The embedded Python path configuration was not found.' }
    (Get-Content $pathFile.FullName) -replace '^#import site$', 'import site' |
        Set-Content $pathFile.FullName -Encoding ascii
    $getPip = Join-Path $env:TEMP 'get-pip.py'
    Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip
    & $python $getPip --disable-pip-version-check 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "pip bootstrap failed with exit code $LASTEXITCODE." }
}

if (-not (Test-Path $qtPlatformRoot)) {
    & $python -m pip install --disable-pip-version-check --upgrade aqtinstall 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "aqtinstall installation failed with exit code $LASTEXITCODE." }
    & $python -m aqt install-qt windows desktop $QtVersion win64_msvc2022_64 `
        --outputdir $qtRoot 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "Qt installation failed with exit code $LASTEXITCODE." }
}

$mpvRuntime = Join-Path $mpvRoot 'bin\mpv-2.dll'
$mpvReady = (Test-Path (Join-Path $mpvRoot 'include\mpv\client.h')) -and `
    (Test-Path $mpvRuntime) -and ((Get-Item $mpvRuntime).Length -gt 10MB)
if (-not $mpvReady) {
    & $python -m pip install --disable-pip-version-check --upgrade py7zr 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "py7zr installation failed with exit code $LASTEXITCODE." }

    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/zhongfly/mpv-winbuild/releases/latest' `
        -Headers @{ 'User-Agent' = 'colorful-build' }
    $asset = $release.assets | Where-Object {
        $_.name -like 'mpv-dev-x86_64-*' -and $_.name -notlike '*-v3-*'
    } | Select-Object -First 1
    if (-not $asset) { throw 'The latest mpv-winbuild release has no x86_64 development bundle.' }

    $archive = Join-Path $env:TEMP $asset.name
    $extracted = Join-Path $env:TEMP 'colorful-mpv-extracted'
    $sevenZip = Join-Path $toolsRoot '7zr.exe'
    if (-not (Test-Path $sevenZip)) {
        Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $sevenZip
    }
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive
    if (Test-Path $extracted) { Remove-Item $extracted -Recurse -Force }
    New-Item -ItemType Directory -Path $extracted -Force | Out-Null
    & $sevenZip x $archive "-o$extracted" -y 2>&1 | Write-Host
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

if (-not (Test-Path $vulkanRuntime)) {
    $vulkanArchive = Join-Path $env:TEMP 'colorful-vulkan-runtime.zip'
    $vulkanExtracted = Join-Path $env:TEMP 'colorful-vulkan-runtime'
    Invoke-WebRequest `
        -Uri 'https://sdk.lunarg.com/sdk/download/latest/windows/vulkan-runtime-components.zip' `
        -OutFile $vulkanArchive
    if (Test-Path $vulkanExtracted) { Remove-Item $vulkanExtracted -Recurse -Force }
    Expand-Archive -Path $vulkanArchive -DestinationPath $vulkanExtracted -Force
    $loader = Get-ChildItem $vulkanExtracted -Filter 'vulkan-1.dll' -Recurse |
        Where-Object { $_.FullName -like '*\x64\vulkan-1.dll' } |
        Select-Object -First 1
    if (-not $loader) { throw 'The official Vulkan runtime archive had no x64 loader.' }
    New-Item -ItemType Directory -Path $vulkanRoot -Force | Out-Null
    Copy-Item $loader.FullName $vulkanRuntime -Force
}

New-Item -ItemType Directory -Path $mediaToolsRoot -Force | Out-Null
$githubHeaders = @{ 'User-Agent' = 'colorful-build' }
if (-not (Test-Path $ffmpeg) -or -not (Test-Path $ffprobe)) {
    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest' `
        -Headers $githubHeaders
    $asset = $release.assets |
        Where-Object { $_.name -eq 'ffmpeg-master-latest-win64-gpl.zip' } |
        Select-Object -First 1
    if (-not $asset) { throw 'The latest BtbN FFmpeg release has no win64 GPL archive.' }
    $ffmpegArchive = Join-Path $env:TEMP $asset.name
    $ffmpegExtracted = Join-Path $env:TEMP 'colorful-ffmpeg'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ffmpegArchive
    if (Test-Path $ffmpegExtracted) { Remove-Item $ffmpegExtracted -Recurse -Force }
    Expand-Archive -Path $ffmpegArchive -DestinationPath $ffmpegExtracted -Force
    $resolvedFfmpeg = Get-ChildItem $ffmpegExtracted -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1
    $resolvedFfprobe = Get-ChildItem $ffmpegExtracted -Filter 'ffprobe.exe' -Recurse | Select-Object -First 1
    if (-not $resolvedFfmpeg -or -not $resolvedFfprobe) { throw 'The FFmpeg archive layout was not recognized.' }
    Copy-Item $resolvedFfmpeg.FullName $ffmpeg -Force
    Copy-Item $resolvedFfprobe.FullName $ffprobe -Force
}

Write-Host "QtRoot=$qtPlatformRoot"
Write-Host "MpvRoot=$mpvRoot"
Write-Host "VulkanRuntime=$vulkanRuntime"
Write-Host "MediaToolsRoot=$mediaToolsRoot"
