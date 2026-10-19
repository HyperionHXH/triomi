param(
    [switch]$SkipBuild,
    [string]$OutputDirectory = 'build/release',
    [string]$Flutter = 'flutter',
    [string]$Python = 'python',
    [string]$Dotnet = 'dotnet',
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$RuntimeCache = 'build/extension-runtime-cache',
    [string]$SuwayomiJar = '',
    [string]$ApksigJar = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    # WiX runs on .NET 8 or a newer installed LTS runtime.
    $oldRollForward = $env:DOTNET_ROLL_FORWARD
    $env:DOTNET_ROLL_FORWARD = 'LatestMajor'
    if (-not $SkipBuild) {
        & $Flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed' }
    }
    $runtimeArgs = @('tools/prepare_windows_extension_runtime.py', '--cache', $RuntimeCache)
    if ($JavaHome) { $runtimeArgs += @('--java-home', $JavaHome) }
    if ($SuwayomiJar) { $runtimeArgs += @('--server-jar', $SuwayomiJar) }
    if ($ApksigJar) { $runtimeArgs += @('--apksig-jar', $ApksigJar) }
    & $Python @runtimeArgs
    if ($LASTEXITCODE -ne 0) { throw 'Windows extension runtime preparation failed' }
    & $Dotnet tool restore
    if ($LASTEXITCODE -ne 0) { throw 'WiX tool restore failed; install the .NET 10 SDK' }
    & $Dotnet tool run wix -- extension add -g WixToolset.UI.wixext/6.0.2
    if ($LASTEXITCODE -ne 0) { throw 'WiX UI extension restore failed' }
    & $Python tools/package_windows.py --output $OutputDirectory --dotnet $Dotnet
    if ($LASTEXITCODE -ne 0) { throw 'Windows packaging failed' }
} finally {
    $env:DOTNET_ROLL_FORWARD = $oldRollForward
    Pop-Location
}
