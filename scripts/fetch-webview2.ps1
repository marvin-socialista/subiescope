# Gets Microsoft's WebView2 SDK, which the Windows app needs to build: the header the C shim
# is compiled against and the small loader DLL that goes next to SubieScope.exe.
#
# The SDK is not kept in this repository. This script downloads the pinned version from
# nuget.org, checks it, and puts the two files where the build expects them:
#   .webview2\WebView2.h                 (the folder is ignored by git)
#   .webview2\x64\WebView2Loader.dll
$ErrorActionPreference = 'Stop'
$version = '1.0.4258.31'
$sha256 = '56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9'
$root = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $root '.webview2'
$stamp = Join-Path $sdk "version-$version.txt"
if ((Test-Path $stamp) -and (Test-Path (Join-Path $sdk 'WebView2.h'))) {
    "WebView2 SDK $version is already there."
    exit 0
}

$work = Join-Path ([IO.Path]::GetTempPath()) "subiescope-webview2-$version"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null
$package = Join-Path $work 'webview2.zip'
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
"Downloading WebView2 SDK $version..."
& curl.exe -L --fail --silent --show-error -o $package $url
if ($LASTEXITCODE -ne 0) { throw "Could not download $url" }

$hash = (Get-FileHash -Algorithm SHA256 $package).Hash.ToLower()
if ($hash -ne $sha256) { throw "The download does not match the expected file (SHA-256 $hash)." }

Expand-Archive -Path $package -DestinationPath (Join-Path $work 'sdk') -Force
$native = Join-Path $work 'sdk\build\native'
foreach ($arch in 'x64', 'arm64') {
    $dll = Join-Path $native "$arch\WebView2Loader.dll"
    $signature = Get-AuthenticodeSignature $dll
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "WebView2Loader.dll ($arch) is not signed by Microsoft."
    }
}

if (Test-Path $sdk) { Remove-Item -Recurse -Force $sdk }
New-Item -ItemType Directory -Force (Join-Path $sdk 'x64'), (Join-Path $sdk 'arm64') | Out-Null
Copy-Item (Join-Path $native 'include\WebView2.h') $sdk
Copy-Item (Join-Path $native 'x64\WebView2Loader.dll') (Join-Path $sdk 'x64')
Copy-Item (Join-Path $native 'arm64\WebView2Loader.dll') (Join-Path $sdk 'arm64')
Copy-Item (Join-Path $work 'sdk\LICENSE.txt') (Join-Path $sdk 'LICENSE.txt')
Set-Content -Path $stamp -Value $hash
Remove-Item -Recurse -Force $work
"WebView2 SDK $version is in $sdk"
