# ECU definitions

SubieScope downloads these files at runtime; they are kept here so the download has a stable source. The app pins a specific commit and checks each file against a checksum.

## Files

- **`logger_METRIC_EN_v370.xml`** — RomRaider's SSM logger parameter definitions (metric, English, v3.70). Used for live logging and the extended parameters.
- **`ecu_defs.xml`** — RomRaider's consolidated Subaru ECU definitions (standard units). The ROM editor uses these to show a ROM's maps by name, with their axes and scaling.

## Credits and origin

These files are **not original work**. They are the result of years of reverse-engineering by the RomRaider project and the Subaru tuning community, and all credit for them belongs there:

- **[RomRaider](https://github.com/RomRaider/RomRaider)** and its community created and maintain both files. RomRaider is licensed GPLv2.
- **`ecu_defs.xml`** is the consolidated standard-units Subaru definition set as distributed through the community repository [Merp/SubaruDefs](https://github.com/Merp/SubaruDefs) (Stable branch).
- **`logger_METRIC_EN_v370.xml`** is RomRaider's official logger definition file, version 3.70.

The files carry RomRaider's own terms and disclaimers in their header comments, and those apply here too: they come with no warranty, reverse-engineering a factory ECU involves assumptions that can be wrong, and using them to change a tune is entirely at your own risk.

## License note

The definition files have no explicit license of their own. They are included here only so this open-source, non-commercial tool can use them for interoperability, with full credit to RomRaider and the community above. If a rights holder would like a file removed, open an issue and it will be taken down.

SubieScope itself is GPL-3.0.
