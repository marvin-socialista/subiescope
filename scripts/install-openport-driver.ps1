# Puts a plugged-in Tactrix OpenPort 2.0 onto Microsoft's own USB serial driver (usbser.sys), so it
# shows up as a COM port that SubieScope can use. Run this only if Windows did not give the cable a
# COM port by itself. It needs administrator rights (it self-signs a one-off certificate for the
# driver package, the same way the Zadig tool does) and it changes nothing until you say yes.
#
# It installs ONLY Microsoft's in-box usbser.sys. It does not install Tactrix's driver or touch the
# cable's firmware, so it is safe for a replica cable. Do NOT install Tactrix's driver or EcuFlash
# on a PC with a replica: those rewrite the cable's firmware and break it for good.
#
# NOTE: this has not been tried on real hardware yet. If it does not work, you can also do it by
# hand: Device Manager, right-click the OpenPort, Update driver, Browse, "Let me pick from a list",
# and choose "USB Serial Device".
$ErrorActionPreference = 'Stop'

# Re-launch with administrator rights if we do not have them.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    "Asking for administrator rights..."
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    return
}

$wdi = Join-Path $PSScriptRoot 'wdi-simple.exe'
if (-not (Test-Path $wdi)) { throw "wdi-simple.exe was not found next to this script." }

# Which OpenPort is plugged in? CC4C is the composite form (bind interface 0); CC4D is the plain one.
$present = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object InstanceId -match 'VID_0403&PID_CC4[CD]'
if (-not $present) {
    Write-Warning "No Tactrix OpenPort 2.0 is plugged in. Plug the cable into this PC and run this again."
    Write-Warning "(If Windows already shows the cable as a COM port, you do not need this at all.)"
    return
}

$devPid, $mi = if ($present.InstanceId -match 'PID_CC4C') { '0xCC4C', '0x00' } else { '0xCC4D', $null }
"Found the OpenPort as $([regex]::Match($present.InstanceId, 'PID_CC4[CD]').Value). Installing the USB serial driver..."

$wdiArgs = @('-n', 'Tactrix OpenPort 2.0 (USB Serial)', '-m', 'Tactrix',
             '-v', '0x0403', '-p', $devPid, '-t', '3', '-f', 'openport_cdc.inf', '-b', '0')
if ($mi) { $wdiArgs += @('-i', $mi) }
& $wdi @wdiArgs
if ($LASTEXITCODE -ne 0) {
    Write-Warning "The driver install did not finish (code $LASTEXITCODE). Nothing lasting was changed."
    return
}

""
"Done. Unplug the cable and plug it back in, then open Device Manager and look under Ports (COM & LPT)"
"for a new COM port. Pick that port in SubieScope's Cable Setup."
