# MerpMod: launch control and flat foot shifting (for later)

Notes for adding MerpMod to the ROM editor later. Nothing of this is built yet.

## What it is

[MerpMod](https://github.com/Merp/MerpMod) by Merrill A. Myers III (GPL-3.0-or-later, so it fits this project) is a patch for 32-bit Subaru Denso ROMs. It adds code to the ROM's unused space and redirects a few function pointers to it. The free "Gratis" build adds:

- **Launch control**: with the clutch pressed and the car (nearly) standing still, a lower rev limit. It only cuts fuel at that RPM; there is no anti-lag or timing retard, so it builds less boost than EcuTek's launch control, and it is hard on the clutch.
- **Flat foot shifting**: with the clutch pressed above a set speed, the revs are held while you shift without lifting.
- **Speed density** (airflow worked out from manifold pressure instead of the MAF sensor), switched off by default: fueling stays on the MAF unless its tables are changed.

The project has been quiet since 2018. Its prebuilt patches are labelled "Testing".

## There is a prebuilt patch for AZ1G500F

`Release/Gratis/AZ1G500F.MeRpMoD.Gratis.Testing.v13.7.16.1227.patch` in the MerpMod repository (target files in `MerpMod/Targets/AZ1G500F.*`). AZ1G500F is the 2009 JDM Impreza WRX STI (ECU ID 6904784007), the calibration on Marvin's car.

Checked on 15 October 2026 against the ROM read from that car (10 October 2026), everything the patch expects matched byte for byte:

| What | Address | Expected and found |
|---|---|---|
| Calibration ID | 0x2004 | `AZ1G500F` |
| ECU ID | 0xD56A0 | `69 04 78 40 07` |
| Rev limit hook (pointer) | 0x3CDE4 | 0x0002F340, becomes 0x0002F380 |
| Memory reset hook | 0xF930 | 0x0000FED8, becomes 0x000E2EF4 |
| Speed density (MAF) hook | 0x4800 | 0x000BE714, becomes 0x000E2988 |
| Main routine hook (WGDC) | 0x3C900 | 0x00013AA4, becomes 0x000E30A8 |
| Free space for its code and tables | 0xE2000 to 0xE30D0 | all 0xFF |

How it hooks in (from disassembling the patched ROM):
- The pointer at 0x3CDE4 sits in a table of routines the ECU runs. Pointing it at 0x2F380 instead of 0x2F340 skips the stock rev limiter's comparison and keeps only its tail call, so the stock limiter is switched off.
- The main routine hook at 0x3C900 then runs MerpMod's own limiter from the free space. That limiter reads the clutch switch, RPM, speed and throttle, and sets the stock fuel cut flag (0xFFFF74C4) itself.

## The catches

1. **It lowers the rev limit unless that is changed.** The stock AZ1G500F cuts fuel at 8000 RPM and resumes at 7800. MerpMod's own limiter replaces it with a default redline of 7200 RPM (50 RPM hysteresis). Set its redline to the stock value before the ROM goes in a car.
2. Its other defaults are:
   - launch control at 4000 RPM, below 5 km/h, above 60% throttle
   - flat foot shifting above 40 km/h and 3500 RPM.
3. Nobody is known to have run this patch on AZ1G500F. One forum report (2024) says launch control did not cut on some MerpMod patch.
4. Its metadata gives `FFFFFFFF` as a new calibration ID. Whether SharpTune writes that into the ROM or treats it as "keep the old one" was not checked. If a patched ROM no longer says AZ1G500F, the ROM writer's calibration check (`DensoSH7058CANWriter`) needs `allowOtherCalibration`, or a better rule for patched ROMs.

## The patch file

A Motorola S-record file. Only part of it belongs in the ROM; the rest is for MerpMod's own tooling (SharpTune) and Renesas simulator testing:

- `0x000E2000` to `0x000E30D0`: MerpMod's code and tables, to copy into the free space. This is the only data in the ROM's range that goes in.
- `0x00000000` to `0x0000003C`: a simulator vector table. Never write it.
- `0xFF000000 + address`: the original bytes at every place the patch touches (calibration ID, ECU ID, the four hooks, the free space), to verify the ROM before patching.
- `0x80001000`: a metadata block of operations, defined in `MerpMod/Metadata.c`:
  - `OpReplace4Bytes` (address, old value, new value) carries the four hook pointers in the table above
  - `OpCalibrationId`, `OpECUID` and `OpNewPatch`
  - the mod's name and info.
- `0x00E00000`, `0x00F00000`, `0x07001000`, `0x0E005000`: test and simulator sections, not for the ROM.

SharpTune applies the metadata operations: check that every old value is in place, write the new values, copy the patch block. It also makes RomRaider definitions for MerpMod's new tables from the build's linker map. The prebuilt release has no map, so the table addresses (redline, launch control RPM, speed and throttle, flat foot shifting) still have to be worked out. They sit in the free space from about 0xE2800, where the default values (7200, 50, 4000, 5.0, 60.0 and so on, as big-endian floats) can be seen. Building MerpMod from source for this target would give the map.

## Plan

1. **Apply the patch to a file** (no car): parse the S-record and the metadata, refuse unless every original value matches, write the hooks and the free-space block, then correct the checksums with `SubaruChecksum`. Show this in the ROM editor as "Add launch control (MerpMod)", with the catches above in plain words.
2. **Definitions for the new tables**, so the redline, launch control and flat foot shifting values can be edited like any other map. The redline must be set to 8000/7800 (stock) before anything else.
3. **Getting it into the car** needs the ROM writer, which exists but is switched off (`DensoSH7058CANWriter.isEnabled`). Its test write mode is the first thing to run on a car.
4. Credit MerpMod (GPL-3.0-or-later) in the README when it ships.
