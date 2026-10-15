# The Tactrix OpenPort on Windows: a COM port, not Tactrix's driver

How SubieScope reaches a Tactrix OpenPort 2.0 on Windows, and the small driver helper in the
Windows zip. This matters most for replica cables, which must never meet Tactrix's own software.

## The idea

SubieScope talks to the OpenPort 2.0 as a plain USB serial cable: it opens a COM port and sends the
cable's text protocol (`ati`, `ato`, `att`, `atf` and so on). It never uses Tactrix's `op20pt32.dll`
or any J2534 driver. So on Windows the only thing the cable needs is Microsoft's own in-box USB
serial driver, `usbser.sys`, bound to it so it appears under Ports (COM & LPT).

Two reasons not to use Tactrix's driver:

- Tactrix's driver is a J2534 "VehiclePassThru" driver. It does not create a COM port, so SubieScope
  cannot see the cable through it at all.
- Installing Tactrix's driver or EcuFlash on a PC updates the cable's firmware, and that **breaks a
  replica cable for good**. SubieScope's whole point here is to avoid that.

## What usually happens

The OpenPort is a USB CDC-ACM device (`VID_0403`, `PID_CC4D`, or `PID_CC4C&MI_00` in its composite
form). Windows 10 and 11 bind `usbser.sys` to a CDC device by a compatible-ID match
(`USB\Class_02&SubClass_02`). If the cable's device descriptor carries subclass `0x02`, Windows
gives it a COM port on its own and nothing else is needed. We could not confirm the descriptor's
subclass byte without the cable, so whether the COM port appears by itself is still unverified.

## When Windows does not do it by itself

Then the cable has to be pointed at `usbser.sys` by hand. Two ways:

1. **By hand, no extra files.** Device Manager, right-click the OpenPort, Update driver, Browse,
   "Let me pick from a list", choose "USB Serial Device". Always available, nothing to download.
2. **The helper in the zip.** `openport-driver\install-openport-driver.ps1` (run it, it asks for
   administrator rights) finds the plugged-in cable and installs a tiny driver package that binds
   `usbser.sys` to it.

## The helper

`openport-driver\` in the Windows zip holds:

- `wdi-simple.exe`: the headless installer from **libwdi** (Pete Batard, LGPL-3.0), the library the
  Zadig tool is built on. It builds a Ports-class INF that binds the OpenPort to in-box `usbser.sys`,
  self-signs the driver catalogue with a one-off certificate (added to the machine's Root and
  TrustedPublisher stores, the same thing Zadig does), and installs it. The private key is thrown
  away straight after. It references only Windows' own `usbser.sys`; it embeds nothing of Tactrix's.
- `openport_cdc_cc4d.inf`, `openport_cdc_cc4c.inf`: the generated INFs, kept for inspection. The
  install regenerates and signs these itself, so they are only there to show the binding.
- `install-openport-driver.ps1`: self-elevates, detects whether the cable is the `CC4D` or the
  composite `CC4C&MI_00` form, and runs `wdi-simple` for it.
- `NOTICE.txt`: the libwdi licence and where its source is.

### How it is built

`scripts\fetch-openport-driver.ps1` clones libwdi at a pinned commit (the `v1.5.1` tag), configures
it for CDC only (no WinUSB, no libusb-win32/K, no ARM64), builds `wdi-simple.exe` for x64, and
generates the two reference INFs into `.openport-driver\` (git-ignored). `scripts\build-windows.ps1`
calls it and copies the folder into the zip. This mirrors how `fetch-webview2.ps1` handles the
WebView2 SDK. Rebuilding needs the Visual Studio Build Tools and git on the PC.

## Not yet tried on hardware

As of 15 October 2026 no OpenPort has been plugged into the Windows PC, so none of this has run on a
real cable: not the automatic COM port, not the manual Device Manager route, and not the helper. The
helper builds and its scripts parse, and the generated INFs bind `usbser.sys` correctly, but the
install step itself is unverified. Treat it as experimental, like the rest of the cable's Windows
support (the "Tactrix OpenPort 2.0 cable" switch in Settings).

## The licence point

libwdi is LGPL-3.0, which SubieScope (GPL-3.0) may include. `wdi-simple.exe` is used unmodified
except for build configuration; its source and the exact build steps are the fetch script above, and
the licence is in `NOTICE.txt` and `NOTICES.txt`. SubieScope does not ship, embed or install any
Tactrix file; `usbser.sys` and `mdmcpq.inf` are Microsoft's own, already on the PC.
