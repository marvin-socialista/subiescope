Tactrix OpenPort 2.0 on Windows: getting a COM port
===================================================

SubieScope talks to a Tactrix OpenPort 2.0 as a plain USB serial cable: a COM port, on Windows' own
USB serial driver. It does not use Tactrix's driver.

IMPORTANT, above all for a replica cable: do NOT install Tactrix's driver or EcuFlash, and do not
plug a replica into a PC that has them. With them the cable gets no COM port, so SubieScope cannot
use it, and they update the cable's firmware, which breaks a replica for good. Nothing in this
folder installs anything of Tactrix's or touches the cable's firmware.

First, take the microSD card out of the cable if it has one, and plug the cable in. If Device
Manager shows it under "Ports (COM & LPT)" with a COM number, you are ready and need nothing from
this folder.

If it gets no COM port, there are two ways to give it one. Neither has been tried on a real cable
yet, so please report how it went.


1. With the helper in this folder

   Double-click "Install OpenPort driver.cmd". Windows asks for administrator rights, then a new
   window opens, finds the cable, and asks you once more before it changes anything. When it is
   done, unplug the cable and plug it back in.

   What it does: it makes a small driver package that points the cable at Windows' own usbser.sys,
   signs it with a one-off certificate that it adds to this PC's trusted certificates (the
   certificate's private key is thrown away at once, so it can vouch for nothing else; the Zadig
   tool does the same), and installs it. It works on PCs with an Intel or AMD processor, not on Arm
   ones: use the steps under 2 there.


2. By hand, in Device Manager

   a. Open Device Manager (right-click the Start button). The cable shows up by a name like
      "OpenPort 2.0", usually under "Other devices" with a yellow mark.
   b. Right-click it, choose "Update driver", then "Browse my computer for drivers", then "Let me
      pick from a list of available drivers on my computer".
   c. If Windows asks for a type of device, choose "Ports (COM & LPT)".
   d. If "USB Serial Device" is in the list, choose it. If not, untick "Show compatible hardware",
      choose "Microsoft" on the left and "USB Serial Device" on the right.
   e. Click Next, and Yes if Windows warns that it cannot confirm the driver fits.
   f. Unplug the cable and plug it back in.


Then, in SubieScope: turn on "Tactrix OpenPort 2.0 cable" in Settings and pick the cable's COM port.
Car > Cable Setup tests it step by step.

Have an original cable that you also use with EcuFlash on this PC? Either way above takes the cable
away from Tactrix's driver, so EcuFlash cannot reach it on this PC until that driver is put back.


The files here

  Install OpenPort driver.cmd       double-click this
  install-openport-driver.ps1       what the .cmd runs
  wdi-simple.exe                    libwdi's installer, which the script uses
  openport_cdc_cc4d.inf
  openport_cdc_cc4c.inf             the driver description the installer writes, to read for
                                    yourself (the install writes and signs its own copy)
  NOTICE.txt                        where libwdi's source is
  COPYING.txt, COPYING-LGPL.txt     libwdi's licence: the GNU LGPL, version 3 or later
