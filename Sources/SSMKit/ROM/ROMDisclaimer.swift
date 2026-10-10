import Foundation

/// The warnings shown wherever the app works with an ECU ROM. ROM work is a world away from
/// logging and diagnostics: a wrong map can damage an engine, and only you are responsible for a
/// car you change. These strings are the single source for that message, used by the app, the CLI
/// and the docs, so the wording stays the same everywhere.
public enum ROMDisclaimer {
    /// One line for a window title bar or a section subtitle.
    public static let short = "ROM editing is for advanced users and entirely at your own risk."

    /// The full warning. Plain English, for a car owner, not an engineer.
    public static let full = """
    SubieScope works on a ROM: a copy of your ECU's tune. You can open a ROM file that is already on \
    your \(Platform.computer), or read the ROM from the car. Editing always happens in the copy on your \(Platform.computer), so no \
    edit you make here changes the car.

    Reading the ROM from the car is the one thing here that talks to the car. It loads a small \
    helper program into the ECU's memory and copies the ROM out. It only reads: it never erases or \
    writes the ECU's program, and the helper program is gone once you turn the ignition off and on \
    again. This is new and has not been tested on a real car yet, so it may not work on yours, and \
    you use it at your own risk.

    Editing a tune is a different thing from logging and diagnostics. The numbers in a ROM decide \
    how much fuel and boost the engine runs and when it ignites. A wrong change can make the engine \
    knock, run lean or be damaged, and that damage is not covered by any warranty. Tuning may also \
    be against the law for a car used on public roads where you live.

    SubieScope cannot write a ROM back to the car, on purpose: putting a bad tune on an ECU can \
    leave it dead. To flash a ROM you edit here you still need another tool and the right hardware.

    Only change values you understand, always keep the original file, and treat every number as \
    yours to answer for. If you are not sure, do not change it.
    """

    /// The one fact that matters most, for a prominent callout.
    public static let noWriteToCar = "SubieScope never writes to the car. Editing and saving only change a file on your \(Platform.computer)."
}
