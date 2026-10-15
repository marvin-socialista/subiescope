# The Tactrix OpenPort on Windows: a COM port, not Tactrix's driver

How SubieScope reaches a Tactrix OpenPort 2.0 on Windows, and the small driver helper in the
Windows zip. This matters most for replica cables, which must never meet Tactrix's own software.

## The idea

SubieScope talks to the OpenPort 2.0 as a plain USB serial cable: it opens a COM port and sends the
cable's text protocol (`ati`, `ato`, `att`, `atf` and so on). It never uses Tactrix's `op20pt32.dll`
or any J2534 driver. So on Windows the only thing the cable needs is Microsoft's own in-box USB
serial driver, `usbser.sys`, bound to it so it appears under Ports (COM & LPT).

Two reasons not to use Tactrix's driver:

- Tactrix's driver is a J2534 "VehiclePassThru" driver. Its INF (`openport2.inf` in the EcuFlash
  1.44 installer) binds its own `openport.sys` to `USB\VID_0403&PID_CC4D` (the whole device),
  `PID_CC4C&MI_00` and `PID_CC4B` (the bootloader). That is a hardware-ID match, which beats the
  compatible-ID match of Windows' `usbser.inf`, so with Tactrix's driver on the PC the cable gets no
  COM port and SubieScope cannot see it.
- Installing Tactrix's driver or EcuFlash on a PC updates the cable's firmware, and that **breaks a
  replica cable for good**. SubieScope's whole point here is to avoid that.

## What usually happens

The OpenPort is a USB CDC-ACM device (`VID_0403`, `PID_CC4D`, or `PID_CC4C&MI_00` in its composite
form): `bDeviceClass` 0x02, interface 0 CDC ACM (class 2, subclass 2), interface 1 CDC data (see
`reference/openport-j2534/docs/PROTOCOL.md`, section 1). Windows 10 and 11 bind `usbser.sys` to a CDC
device by the compatible ID `USB\Class_02&SubClass_02`, which for a device-level class comes from the
device descriptor's `bDeviceSubClass`. If that byte is 0x02, Windows gives the cable a COM port on its
own and nothing else is needed; if it is 0x00, as on many CDC devices, it does not. The notes do not
record that byte and no cable has been on the PC, so this is still unverified.

## When Windows does not do it by itself

Then the cable has to be pointed at `usbser.sys`. Two ways, both described for users in
`Assets/openport-driver/README.txt` (which ships in the zip):

1. **The helper in the zip.** `openport-driver\Install OpenPort driver.cmd` runs
   `install-openport-driver.ps1`, which asks for administrator rights, finds the plugged-in cable,
   asks once more, and installs a tiny driver package that binds `usbser.sys` to it.
2. **By hand, no extra files.** Device Manager, Update driver, Browse my computer, Let me pick from a
   list, Ports (COM & LPT), then "USB Serial Device" (with "Show compatible hardware" unticked:
   Microsoft, USB Serial Device). Works everywhere, including Arm PCs.

Either way takes the cable away from Tactrix's driver on that PC, so an original cable's owner who
also uses EcuFlash there loses EcuFlash's access to it until that driver is put back.

## The helper

`openport-driver\` in the Windows zip holds:

- `Install OpenPort driver.cmd`: what the user double-clicks. It runs the script with
  `-ExecutionPolicy Bypass` (a `.ps1` opens in Notepad when double-clicked) and pauses at the end.
- `install-openport-driver.ps1`: self-elevates, refuses on an Arm PC (see below), detects whether the
  cable is the `CC4D` or the composite `CC4C&MI_00` form, asks for a Y, and runs `wdi-simple` for it.
  libwdi writes the package into `%SystemRoot%\Temp\subiescope-openport-driver` (an ASCII path:
  `wdi-simple` gets it as 8-bit text and libwdi reads it as UTF-8, so a user folder with accents
  would break it), and the folder is removed afterwards (Windows keeps its own copy in the driver
  store). If the install fails, the script takes libwdi's certificate away again.
- `wdi-simple.exe`: the headless installer from **libwdi** (Pete Batard, LGPL-3.0), the library the
  Zadig tool is built on. It builds a Ports-class INF that binds the OpenPort to in-box `usbser.sys`,
  self-signs the driver catalogue with a one-off certificate (added to the machine's Root and
  TrustedPublisher stores, the same thing Zadig does), and installs it. The private key is thrown
  away straight after. It references only Windows' own `usbser.sys`; it embeds nothing of Tactrix's.
  It carries the x64 installer only, so on Windows on Arm libwdi would look for
  `installer_arm64.exe` and fail; the script says so up front and points at the manual route.
- `openport_cdc_cc4d.inf`, `openport_cdc_cc4c.inf`: the generated INFs, kept for inspection. The
  install regenerates and signs these itself, so they are only there to show the binding.
- `README.txt`: the user's instructions, both routes.
- `NOTICE.txt`, `COPYING.txt`, `COPYING-LGPL.txt`: where libwdi's source is, and its licence texts.

### How it is built

`scripts\fetch-openport-driver.ps1` clones libwdi at a pinned commit (the `v1.5.1` tag) with
`core.autocrlf=true` (its edits look for CRLF, and libwdi's `.gitattributes` does not fix headers),
configures it for CDC only (no WinUSB, no libusb-win32/K, no ARM64), builds `wdi-simple.exe` for x64
with the newest C++ toolset of the Visual Studio it finds (v142 on the PC, which only has the 2019
Build Tools; libwdi's projects ask for v143), and generates the two reference INFs into
`.openport-driver\` (git-ignored). Its stamp names the libwdi commit and a hash of the script itself,
so changing the script rebuilds. `scripts\build-windows.ps1` calls it and copies that folder plus
`Assets\openport-driver\` into the zip. This mirrors how `fetch-webview2.ps1` handles the WebView2
SDK. Rebuilding needs the Visual Studio Build Tools and git on the PC.

**Certificates during the build.** libwdi signs a catalogue whenever it runs with administrator
rights, even with `-x` (extract only), and trusts the certificate it signed with. An SSH session on
the PC has those rights, so generating the reference INFs used to leave two "USB\VID_0403&PID_CC4D /
CC4C&MI_00 (libwdi autogenerated)" certificates in the PC's Root and TrustedPublisher stores (found
and removed on 15 October 2026). The script now removes them right after each extract and stops if
it cannot.

## Not yet tried on hardware

As of 15 October 2026 no OpenPort has been plugged into the Windows PC, so none of this has run on a
real cable: not the automatic COM port, not the manual Device Manager route, and not the helper. The
helper builds, its scripts parse, the generated INFs bind `usbser.sys` correctly, and the script's
"no cable plugged in" path runs, but the install step itself is unverified. So is whether `CC4C&MI_00`
is a function `usbser.sys` can drive. Treat it as experimental, like the rest of the cable's Windows
support (the "Tactrix OpenPort 2.0 cable" switch in Settings).

## The licence point

libwdi is LGPL-3.0, which SubieScope (GPL-3.0) may include. `wdi-simple.exe` is used unmodified
except for build configuration; its source and the exact build steps are the fetch script above, and
the licence texts are in `COPYING-LGPL.txt` and `COPYING.txt` next to it (named in `NOTICES.txt`).
SubieScope does not ship, embed or install any Tactrix file; `usbser.sys` and `mdmcpq.inf` are
Microsoft's own, already on the PC.
