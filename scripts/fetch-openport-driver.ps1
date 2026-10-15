# Builds the small helper that puts a Tactrix OpenPort 2.0 onto Microsoft's own USB serial driver
# (usbser.sys), so the cable shows up as a COM port that SubieScope can talk to. This replaces any
# need for Tactrix's op20pt32.dll / J2534 driver, which gives no COM port and, on a replica cable,
# rewrites its firmware and breaks it.
#
# The helper is wdi-simple from libwdi (Pete Batard, LGPL-3.0), the same library Zadig is built on.
# libwdi is not kept in this repository: this script clones a pinned version, builds it for CDC only
# (no WinUSB, no libusb-win32/K, no ARM64), and writes everything the Windows build bundles into:
#   .openport-driver\wdi-simple.exe          the installer the user runs (self-signs at install)
#   .openport-driver\openport_cdc_cc4d.inf   binds VID_0403&PID_CC4D       to usbser.sys
#   .openport-driver\openport_cdc_cc4c.inf   binds VID_0403&PID_CC4C&MI_00 to usbser.sys
#   .openport-driver\NOTICE.txt              the LGPL notice and where to get the source
# The folder is ignored by git. The install itself has not been tried on real hardware yet.
$ErrorActionPreference = 'Stop'

# Pinned libwdi: the commit the lightweight tag v1.5.1 points at.
$commit = '9b23b82a2dd1cbffc16d46c212f92c6bf8c0c602'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root '.openport-driver'
$stamp = Join-Path $out "version-$commit.txt"
if ((Test-Path $stamp) -and (Test-Path (Join-Path $out 'wdi-simple.exe'))) {
    "The OpenPort driver helper for libwdi $commit is already built."
    exit 0
}

function Invoke-Checked([string]$what, [scriptblock]$command) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)." }
}

# A string replacement that fails loudly if the text to replace is not there, so a new libwdi
# version cannot silently build with the wrong configuration.
function Edit-File([string]$path, [string]$find, [string]$replace) {
    $text = Get-Content -Raw $path
    if (-not $text.Contains($find)) { throw "Expected to find in $($path): `n$find" }
    Set-Content -NoNewline -Path $path -Value $text.Replace($find, $replace)
}

$work = Join-Path ([IO.Path]::GetTempPath()) "subiescope-libwdi-$commit"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null

"Cloning libwdi $commit..."
Invoke-Checked 'git clone' { git clone --quiet https://github.com/pbatard/libwdi.git $work }
Push-Location $work
try {
    Invoke-Checked 'git checkout' { git -c advice.detachedHead=false checkout --quiet $commit }
    $head = (git rev-parse HEAD).Trim()
    if ($head -ne $commit) { throw "Checked out $head, not the pinned $commit." }

    # Configure for CDC only: no embedded WinUSB/libusb driver binaries (we reference in-box
    # usbser.sys), no ARM64 (we ship x64). libwdi still needs one embeddable source, so point
    # USER_DIR at a folder holding only our notice.
    $userdir = Join-Path $work 'userdir'
    New-Item -ItemType Directory -Force $userdir | Out-Null
    Set-Content -Path (Join-Path $userdir 'README.txt') `
        -Value "Built for SubieScope: only the in-box USB CDC (usbser.sys) driver is used."
    $config = Join-Path $work 'msvc\config.h'
    Edit-File $config "#ifndef WDK_DIR`r`n#define WDK_DIR `"C:/Program Files (x86)/Windows Kits/8.0`"`r`n#endif" "/* SubieScope: CDC only, no WinUSB redist */"
    Edit-File $config "#ifndef LIBUSB0_DIR`r`n#define LIBUSB0_DIR `"D:/libusb-win32`"`r`n#endif" "/* SubieScope: no libusb-win32 */"
    Edit-File $config "#ifndef LIBUSBK_DIR`r`n#define LIBUSBK_DIR `"D:/libusbK/bin`"`r`n#endif" "/* SubieScope: no libusbK */"
    Edit-File $config "// #define USER_DIR `"C:/signed-driver`"" "#define USER_DIR `"$($userdir -replace '\\','\\')`""
    Edit-File $config "/* ARM64 support */`r`n#define OPT_ARM" "/* ARM64 support off for SubieScope */"

    # wdi-simple pulls in libwdi_static, which references the ARM64 installer helper as an embedded
    # resource. We build x64 only, so drop that reference (its tools are not installed).
    $static = Join-Path $work 'libwdi\.msvc\libwdi_static.vcxproj'
    $text = Get-Content -Raw $static
    $pattern = "(?s)\s*<ProjectReference Include=`"installer_arm64.vcxproj`">.*?</ProjectReference>"
    if ($text -notmatch $pattern) { throw "Could not find the installer_arm64 reference in $static." }
    Set-Content -NoNewline -Path $static -Value ([regex]::Replace($text, $pattern, ''))

    # Find MSBuild and the newest installed Windows 10 SDK.
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; Visual Studio Build Tools are required." }
    $vs = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    $msbuild = Join-Path $vs 'MSBuild\Current\Bin\MSBuild.exe'
    if (-not (Test-Path $msbuild)) { throw "MSBuild.exe not found under $vs." }
    $sdk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory |
        Where-Object Name -match '^10\.' | Sort-Object Name | Select-Object -Last 1
    if (-not $sdk) { throw "No Windows 10 SDK found." }

    "Building wdi-simple (x64) with SDK $($sdk.Name)..."
    Invoke-Checked 'msbuild' {
        & $msbuild 'libwdi.sln' /m /v:minimal /nologo '/t:examples\wdi-simple' `
            /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v142 `
            /p:WindowsTargetPlatformVersion=$($sdk.Name)
    }
    $exe = Join-Path $work 'x64\Release\examples\wdi-simple.exe'
    if (-not (Test-Path $exe)) { throw "wdi-simple.exe was not produced." }

    # Lay out the folder the Windows build bundles.
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    New-Item -ItemType Directory -Force $out | Out-Null
    Copy-Item $exe (Join-Path $out 'wdi-simple.exe')

    # Generate one reference INF per OpenPort identity, so the usbser binding can be inspected. The
    # install itself runs wdi-simple directly (it regenerates and signs these), so these are only
    # for transparency. CC4D is the plain device; CC4C exposes the interface as interface 0 of a
    # composite device. Extract into a fresh temp dir (libwdi makes its own subfolders), then copy
    # the one .inf out. Extract only: no install, no certificate.
    foreach ($id in @(
        @{ pid = '0xCC4D'; mi = $null; name = 'openport_cdc_cc4d.inf' },
        @{ pid = '0xCC4C'; mi = '0x00'; name = 'openport_cdc_cc4c.inf' })) {
        $ref = Join-Path $work "ref_$($id.pid)"
        $wdiArgs = @('-n', 'Tactrix OpenPort 2.0 (USB Serial)', '-m', 'Tactrix',
                     '-v', '0x0403', '-p', $id.pid, '-t', '3', '-f', $id.name, '-d', $ref, '-x', '-b', '0')
        if ($id.mi) { $wdiArgs += @('-i', $id.mi) }
        Invoke-Checked "wdi-simple extract $($id.pid)" { & (Join-Path $out 'wdi-simple.exe') @wdiArgs }
        Copy-Item (Join-Path $ref $id.name) (Join-Path $out $id.name)
    }

    Set-Content -Path (Join-Path $out 'NOTICE.txt') -Value @"
wdi-simple.exe is built from libwdi $commit (https://github.com/pbatard/libwdi),
Copyright (c) Pete Batard, licensed under the GNU LGPL version 3 or later.
It is used unmodified except for build configuration (CDC/usbser only, x64).
The source and the exact build steps are in SubieScope's scripts\fetch-openport-driver.ps1.
The .inf files reference Microsoft's in-box usbser.sys and are generated by libwdi.
"@
    Set-Content -Path $stamp -Value $commit
    "OpenPort driver helper built in $out"
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $work
}
