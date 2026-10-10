# Builds SubieScope for Windows: the folder build\SubieScope that is the app (SubieScope.exe, the
# command line tool, and everything they need next to them) and a zip of it.
#
#   scripts\build-windows.ps1                      release build; the app downloads RomRaider's definitions itself
#   scripts\build-windows.ps1 -KeepDefinitions     development build with the local copy of the definitions inside
#   scripts\build-windows.ps1 -Configuration debug
#
# Needs: Swift 6 for Windows (swift.org), the Visual Studio Build Tools with the C++ tools and a
# Windows SDK, and an internet connection the first time (for Microsoft's WebView2 SDK).
param(
    [ValidateSet('release', 'debug')][string]$Configuration = 'release',
    [switch]$KeepDefinitions,
    [switch]$NoZip
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$version = (Get-Content VERSION -TotalCount 1).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION must look like 1.2.3, not '$version'." }

& (Join-Path $PSScriptRoot 'fetch-webview2.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Could not get the WebView2 SDK.' }

# A development build carries RomRaider's logger definitions, so the demo car works at once. They are
# not among the app's resources in git (they have no license that allows shipping them): the copy the
# app itself downloads from, in the definitions folder, is put there for this build.
$definitions = 'Sources\SSMKit\Resources\Definitions\logger_METRIC_EN_v370.xml'
if ($KeepDefinitions -and -not (Test-Path $definitions)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $definitions) | Out-Null
    Copy-Item 'definitions\logger_METRIC_EN_v370.xml' $definitions
}

function Invoke-Checked([string]$what, [scriptblock]$command) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw "$what failed." }
}

# The icon, the version and the manifest are linked into SubieScope.exe as resources.
$resources = Join-Path $root '.build\windows-resources'
New-Item -ItemType Directory -Force $resources | Out-Null
Copy-Item Assets\AppIcon.ico $resources -Force
(Get-Content Assets\SubieScope.manifest -Raw).Replace('@VERSION@', $version) | Set-Content (Join-Path $resources 'app.manifest') -Encoding UTF8
$numbers = $version.Replace('.', ',') + ',0'
@"
1 ICON "AppIcon.ico"
1 24 "app.manifest"
1 VERSIONINFO
FILEVERSION $numbers
PRODUCTVERSION $numbers
FILEOS 0x40004
FILETYPE 0x1
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Marvin Visser"
      VALUE "FileDescription", "SubieScope"
      VALUE "FileVersion", "$version"
      VALUE "InternalName", "SubieScope"
      VALUE "LegalCopyright", "GPL-3.0. Not affiliated with Subaru Corporation."
      VALUE "OriginalFilename", "SubieScope.exe"
      VALUE "ProductName", "SubieScope"
      VALUE "ProductVersion", "$version"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"@ | Set-Content (Join-Path $resources 'app.rc') -Encoding ASCII
Push-Location $resources
try { Invoke-Checked 'Compiling the resources' { llvm-rc /nologo /fo app.res app.rc } } finally { Pop-Location }
$res = Join-Path $resources 'app.res'

Invoke-Checked 'Building SubieScope' { swift build -c $Configuration --product SubieScope -Xlinker $res }
Invoke-Checked 'Building subiescope-cli' { swift build -c $Configuration --product subiescope-cli }
$bin = (swift build -c $Configuration --show-bin-path | Select-Object -Last 1).Trim()

$app = Join-Path $root 'build\SubieScope'
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
New-Item -ItemType Directory -Force $app | Out-Null
Copy-Item (Join-Path $bin 'SubieScope.exe'), (Join-Path $bin 'subiescope-cli.exe') $app
foreach ($bundle in 'SubieScope_SSMKit', 'SubieScope_SubieScope') {
    # The name of the folder SwiftPM puts a target's resources in differs between its versions.
    $source = @("$bundle.bundle", "$bundle.resources") | ForEach-Object { Join-Path $bin $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $source) { throw "The resources of $bundle are missing in $bin." }
    Copy-Item $source (Join-Path $app (Split-Path -Leaf $source)) -Recurse
}
if (-not $KeepDefinitions) {
    # RomRaider's logger definitions have no license that allows shipping them: the app downloads them on first start.
    Get-ChildItem $app -Recurse -Filter *.xml | Where-Object { $_.FullName -match '\\Definitions\\' } | Remove-Item -Force
}
Copy-Item '.webview2\x64\WebView2Loader.dll' $app
Copy-Item VERSION, LICENSE $app
Copy-Item Assets\windows-notices.txt (Join-Path $app 'NOTICES.txt')

# The Swift runtime: every one of its DLLs that the two programs use, directly or through another.
$runtime = Split-Path -Parent (Get-Command swiftCore.dll).Source
function Get-Imports([string]$file) {
    & llvm-readobj --coff-imports $file 2>$null | ForEach-Object { if ($_ -match '^\s*Name:\s*(\S+\.dll)\s*$') { $Matches[1] } } | Sort-Object -Unique
}
$needed = @{}
$queue = New-Object System.Collections.Queue
$queue.Enqueue((Join-Path $app 'SubieScope.exe'))
$queue.Enqueue((Join-Path $app 'subiescope-cli.exe'))
$usesCppRuntime = $false
while ($queue.Count -gt 0) {
    foreach ($name in Get-Imports $queue.Dequeue()) {
        if ($name -match '^(vcruntime|msvcp)') { $usesCppRuntime = $true }
        $candidate = Join-Path $runtime $name
        if ((Test-Path $candidate) -and -not $needed.ContainsKey($name.ToLower())) {
            $needed[$name.ToLower()] = $candidate
            $queue.Enqueue($candidate)
        }
    }
}
$needed.Values | ForEach-Object { Copy-Item $_ $app }

# Microsoft's C++ runtime is on most PCs, but not on all: a copy next to the program always works.
# It has to be at least as new as the one the Swift runtime was built with: with an older one next to
# it, the program crashes the moment it starts. So the newest copy on this PC is taken.
if ($usesCppRuntime) {
    $folders = @(Join-Path $env:SystemRoot 'System32') +
        @(Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $newest = $folders | Where-Object { Test-Path (Join-Path $_ 'vcruntime140.dll') } |
        Sort-Object { [version](Get-Item (Join-Path $_ 'vcruntime140.dll')).VersionInfo.ProductVersion.Split(' ')[0] } -Descending | Select-Object -First 1
    $found = if ($newest) { [version](Get-Item (Join-Path $newest 'vcruntime140.dll')).VersionInfo.ProductVersion.Split(' ')[0] } else { [version]'0.0' }
    if ($found -ge [version]'14.40') {
        foreach ($name in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
            if (Test-Path (Join-Path $newest $name)) { Copy-Item (Join-Path $newest $name) $app }
        }
    } else {
        Write-Warning "No current Visual C++ runtime on this PC (found $found). The app is built without it: a PC that runs it needs the Microsoft Visual C++ Redistributable (x64)."
    }
}

$size = (Get-ChildItem $app -Recurse | Measure-Object Length -Sum).Sum / 1MB
"Built {0} ({1:N0} MB, {2} runtime files)" -f $app, $size, $needed.Count
if (-not $NoZip) {
    $zip = Join-Path $root "build\SubieScope-$version-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path $app -DestinationPath $zip
    "Zipped {0} ({1:N0} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)
}
