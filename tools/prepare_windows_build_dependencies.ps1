# Provision the existing package pins through the original GitHub release API.
# Package hooks and CMake still independently validate every reused artifact.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    function Get-PinnedAsset($Repository, $Tag, $Name, $Destination, $Hash, $Algorithm = 'SHA256') {
        if (Test-Path $Destination) {
            if ((Get-FileHash $Destination -Algorithm $Algorithm).Hash.ToLowerInvariant() -eq $Hash) { return }
            throw "Existing build cache differs from its package pin: $Destination"
        }
        $directory = Split-Path $Destination -Parent
        New-Item -ItemType Directory -Force $directory | Out-Null
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('triomi-pinned-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $temporary | Out-Null
        try {
            gh release download $Tag --repo $Repository --pattern $Name --dir $temporary
            if ($LASTEXITCODE -ne 0) { throw "Upstream asset download failed: $Name" }
            $asset = Join-Path $temporary $Name
            if ((Get-FileHash $asset -Algorithm $Algorithm).Hash.ToLowerInvariant() -ne $Hash) {
                throw "Upstream asset differs from the existing package pin: $Name"
            }
            Move-Item $asset $Destination
        } finally {
            Remove-Item $temporary -Recurse -Force
        }
    }

    Get-PinnedAsset 'simolus3/sqlite3.dart' 'sqlite3-3.6.0' 'sqlite3.x64.windows.dll' `
        '.dart_tool/hooks_runner/shared/sqlite3/build/download-c5a4ebf9/sqlite3.dll' `
        'c5a4ebf9922c63fa252a01c4679992f1fbaa2762b962b78ba6cbdc5cbf7ca91c'

    $manifest = Get-Content packages/ech_http/lib/src/build_support/dependencies.json -Raw | ConvertFrom-Json
    $pin = $manifest.targets.'windows-x64'
    $url = [Uri]$pin.url
    if ($url.Host -ne 'github.com') { throw 'Unexpected SDK asset host' }
    $parts = $url.AbsolutePath.Trim('/').Split('/')
    Get-PinnedAsset ($parts[0] + '/' + $parts[1]) $pin.release $parts[-1] `
        ('.dart_tool/hooks_runner/shared/ech_http/build/prebuilt/windows-x64-' + $pin.sha256 + '.zip') $pin.sha256

    Get-PinnedAsset 'media-kit/libmpv-win32-video-build' '2023-09-24' 'mpv-dev-x86_64-20230924-git-652a1dd.7z' `
        'build/windows/x64/mpv-dev-x86_64-20230924-git-652a1dd.7z' 'a832ef24b3a6ff97cd2560b5b9d04cd8' 'MD5'
    Get-PinnedAsset 'alexmercerind/flutter-windows-ANGLE-OpenGL-ES' 'v1.0.1' 'ANGLE.7z' `
        'build/windows/x64/ANGLE.7z' 'e866f13e8d552348058afaafe869b1ed' 'MD5'
    Get-PinnedAsset 'Suwayomi/Suwayomi-Server' 'v2.4.2366' 'Suwayomi-Server-v2.4.2366.jar' `
        'build/extension-runtime-cache/Suwayomi-Server-v2.4.2366.jar' `
        'af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd'
    Write-Host 'Original Windows dependency pins verified and available'
} finally {
    Pop-Location
}
