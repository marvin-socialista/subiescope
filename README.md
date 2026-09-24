<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="SubieScope icon">
</p>

<h1 align="center">SubieScope</h1>

<p align="center">
  Live data, logging, diagnostics and a virtual dyno for your Subaru, on your Mac.<br>
  Plug in a cheap VAG KKL cable and see what your ECU sees.
</p>

<p align="center">
  <a href="https://github.com/marvin-socialista/subiescope/releases/latest"><b>Download for macOS</b></a> ·
  <a href="#supported-cars">Supported cars</a> ·
  <a href="#support">Buy me a coffee</a>
</p>

![SubieScope dashboard](docs/screenshots/dashboard.png)

SubieScope talks to the engine ECU over Subaru's SSM protocol, the same one the dealer tool uses. It stands on the shoulders of two great open-source projects: [FreeSSM](https://github.com/Comer352L/FreeSSM) (diagnostics) and [RomRaider](https://github.com/RomRaider/RomRaider) (logging and its huge parameter database). SubieScope brings both to the Mac as one native app.

> Not affiliated with or endorsed by Subaru Corporation. Use at your own risk; see [Safety](#safety).

## What it does

- **Dashboard**: live gauges as dials, big digital numbers, bars or trend graphs. Drag to reorder, pick a size per gauge, and see min/max markers. Knock correction turns orange or red and IAM turns green when it's at 1.0.
- **Logger**: choose from hundreds of parameters, including the ECU-specific "extended" ones (IAM, feedback and fine-learning knock correction, target boost and more), and record to CSV in RomRaider's format. Datazap, DataLog Lab and Virtual Dyno open these files too.
- **Troubleshooting**: 17 guided tests that tell you what to do, coach you live ("a bit more throttle", "hold 2,500 rpm") and explain the result in plain language:
  - *In the garage*: front A/F sensor, rear O2 sensor & catalyst, MAF sensor, idle quality & misfires, battery & charging, accelerator pedal sensor, temperature sensors, warm-up & thermostat, overheating & radiator fan
  - *On the road*: knock check (how much knock, where and why), full-throttle pull (knock, boost, fueling), AVCS, fuel trims while driving, catalyst efficiency (P0420), intercooler heat soak, throttle response, misfire hunt
- **Trouble codes**: read current and stored codes with an explanation for each code, and clear the ECU memory.
- **Log playback**: replay any log on the gauges, scrub through it and hover the charts to see every value at that moment. It also opens RomRaider logs, including ones written by Dutch or German Windows installs.
- **Virtual dyno**: turns a full-throttle pull into wheel horsepower and torque curves, tells you whether the pull was good or should be redone, and compares pulls.
- **Cable setup**: finds your cable, tells you whether it needs a driver, and tests the connection step by step.

<table>
  <tr>
    <td><img src="docs/screenshots/troubleshooting.png" alt="Troubleshooting result"></td>
    <td><img src="docs/screenshots/log-viewer.png" alt="Log viewer with hover snapshot"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/dyno.png" alt="Virtual dyno"></td>
    <td><img src="docs/screenshots/logger.png" alt="Logger"></td>
  </tr>
</table>

## What you need

- A Mac with **macOS 14 Sonoma or newer** (Apple silicon or Intel).
- A **VAG KKL 409.1 USB cable with an FTDI FT232RL chip**, about €10–15 online. macOS already has the FTDI driver, so there's nothing to install.
  - Avoid cables with a CH340 chip: they're known to be unreliable with Subarus.
  - Cables with a switch: use the position that puts K-line on pin 7.
- A Subaru that speaks SSM over K-line (see below).

## Supported cars

SubieScope works with Subarus whose engine ECU speaks **SSM2 over K-line** (OBD pin 7). That covers most petrol Subarus from **1999 to about 2014**. Newer cars talk to the diagnostic port over **CAN only**, which a KKL cable can't do.

| Model | Years | Status |
|---|---|---|
| Impreza, WRX, WRX STI (GC/GF, GD/GG, GE/GH/GR/GV) | 1999 to 2014 | Supported |
| Legacy, Liberty, Outback (BE/BH, BL/BP) | 1999 to 2009 | Supported |
| Legacy, Liberty, Outback (BM/BR) | 2010 to 2014 | Most models; some later ECUs are CAN-only |
| Forester (SF, SG, SH) | 1999 to 2013 | Supported (SH: most models) |
| Baja | 2003 to 2006 | Supported |
| Tribeca (B9 Tribeca) | 2006 to 2014 | Supported |
| WRX / STI (VA), Forester (SJ and newer), Levorg, XV/Crosstrek, BRZ | 2014 and newer | **Not supported**: CAN only (BRZ: Toyota ECU) |

What your car supports depends on its ECU:

- **Standard parameters, trouble codes and troubleshooting tests** work on every supported ECU. The ECU reports which values it has, and SubieScope only shows those.
- **Extended parameters** (IAM, fine and feedback knock correction, target boost and so on) are ECU-specific. They're available when your ECU ID is in RomRaider's definitions, which covers over 600 ECU IDs.

**Tested on:** SubieScope was developed against a simulated 2008 JDM WRX STI (GRB, EJ207, ECU ID `5A04784207`). Real-car testing is ongoing, and reports of which cars work are very welcome: please open an [issue](https://github.com/marvin-socialista/subiescope/issues) with your model, year, market and the ECU ID shown on the ECU Info page.

## Install

1. Download `SubieScope.dmg` from the [latest release](https://github.com/marvin-socialista/subiescope/releases/latest).
2. Open it and drag **SubieScope** to **Applications**. The app is signed and notarized by Apple, so it opens without warnings.
3. On first launch SubieScope downloads RomRaider's parameter definitions once (about 2 MB), then opens **Cable Setup**.

## First drive

1. Plug the cable into your Mac and into the OBD port under the dashboard (driver's side).
2. Turn the ignition **ON**. The engine may be off or running.
3. In Cable Setup press **Test Connection**, then **Connect**.
4. The dashboard comes alive. Press **⌘R** to record a log and **⌘R** again to stop.

No cable yet? Pick **Demo ECU** in the cable menu to explore everything with a simulated car. In **Troubleshooting** you can even make the demo car develop faults (a dirty MAF, a vacuum leak, a dying catalyst…) to see how the tests catch them.

## Command line

The app bundle also contains `subiescope-cli`, which is handy at the car or for bug reports:

```sh
/Applications/SubieScope.app/Contents/MacOS/subiescope-cli ports     # list cables
/Applications/SubieScope.app/Contents/MacOS/subiescope-cli probe     # connect and show the raw traffic
/Applications/SubieScope.app/Contents/MacOS/subiescope-cli log --csv pull.csv --seconds 30
/Applications/SubieScope.app/Contents/MacOS/subiescope-cli codes     # read trouble codes
```

Add `--demo` to any command to use the simulated car.

## Safety

- Do full-throttle pulls and driving tests **only on a closed road, a track or a dyno**. Let a passenger watch the screen.
- The troubleshooting results are rules of thumb from logged data, **not a replacement for a proper diagnosis**. When in doubt, ask a Subaru specialist and bring the log.
- **Clear memory** erases stored trouble codes and resets what the ECU has learned (fuel trims, IAM). The car relearns within a few drives.
- SubieScope only reads the ECU, apart from clearing memory. It never flashes or changes the ECU's program.

## Build from source

You need Xcode 16 or newer (Swift 6).

```sh
git clone https://github.com/marvin-socialista/subiescope.git
cd subiescope
scripts/fetch-definitions.sh   # RomRaider logger definitions, for development builds
swift test                     # protocol, parser, troubleshooting and dyno tests
scripts/build-app.sh           # builds build/SubieScope.app and build/subiescope-cli
open build/SubieScope.app
```

How the code is organised:

| Path | What's there |
|---|---|
| `Sources/SSMKit` | The engine, with no UI: serial port, SSM2 protocol, RomRaider definitions parser, polling and fast-poll session, CSV logs, troubleshooting tests, virtual dyno, and the simulated ECU |
| `Sources/SubieScope` | The SwiftUI app |
| `Sources/SubieScopeCLI` | `subiescope-cli` |
| `Tests/SSMKitTests` | Tests, including an end-to-end run over a pseudo-terminal and every troubleshooting test against simulated faults |

RomRaider's definitions file has no explicit license, so it isn't in this repository. The app downloads it on first launch, and `scripts/fetch-definitions.sh` fetches it for development builds. Both check it against a checksum.

## Credits

- [FreeSSM](https://github.com/Comer352L/FreeSSM) by Comer352L: SSM2 diagnostics, clear-memory procedure, trouble code layout and engine details.
- [RomRaider](https://github.com/RomRaider/RomRaider) and its community: the SSM logger protocol, fast polling and the logger definitions with extended parameters for hundreds of ECUs.

## Support

SubieScope is free and open source, made by one person in spare time. If it saves you a trip to the dealer, you can [buy me a coffee ☕](https://buymeacoffee.com/socialista). Bug reports and car compatibility reports are just as welcome: [open an issue](https://github.com/marvin-socialista/subiescope/issues).

## License

[GPL-3.0](LICENSE). Subaru, Impreza, WRX, STI, Legacy, Outback, Forester, Baja and Tribeca are trademarks of Subaru Corporation.
