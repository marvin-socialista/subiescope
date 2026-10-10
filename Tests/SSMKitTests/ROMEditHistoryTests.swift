import Foundation
import Testing
@testable import SSMKit

/// Undo and redo in the ROM editor. The history works on a ROM in memory, so every kind of edit the
/// editor makes (a cell of a map, raw bytes, correcting the checksums) is taken back and put back
/// here against the ROMs and the definition the other ROM tests build.
struct ROMEditHistoryTests {

    /// The ROM with one cell of a map set, the way the editor writes a cell.
    static func editing(_ rom: ROMImage, _ map: String, row: Int, column: Int, to value: Double) throws -> ROMImage {
        let set = try ROMDefinitionTests.load()
        let def = try #require(set.resolvedTables(forXmlID: "TESTROM1").first { $0.name == map })
        return try ROMTable.read(rom, def: def, scalings: set.scalings).write(rom, row: row, column: column, realValue: value)
    }

    @Test func undoAndRedoRoundTrip() throws {
        let original = ROMDefinitionTests.makeROM()
        let edited = try Self.editing(original, "Primary Fuel", row: 1, column: 2, to: 33)
        var history = ROMEditHistory()
        #expect(!history.canUndo && !history.canRedo)

        let recorded = history.record("the edit in Primary Fuel", from: original, to: edited)
        #expect(recorded)
        #expect(history.undoLabel == "the edit in Primary Fuel")
        #expect(history.redoLabel == nil)
        // The step holds the one byte that changed, not the ROM.
        #expect(history.undoSteps == [.init(label: "the edit in Primary Fuel", offset: 0x3005, before: [60], after: [66])])

        let undone = history.undo(edited)
        #expect(undone == original)
        #expect(!history.canUndo)
        #expect(history.redoLabel == "the edit in Primary Fuel")

        let redone = history.redo(original)
        #expect(redone == edited)
        #expect(history.canUndo && !history.canRedo)
    }

    @Test func stepsComeBackNewestFirst() throws {
        let original = ROMDefinitionTests.makeROM()
        var history = ROMEditHistory()
        let one = try Self.editing(original, "Primary Fuel", row: 0, column: 0, to: 7)
        history.record("one", from: original, to: one)
        let two = try Self.editing(one, "Target Boost", row: 0, column: 3, to: 1.5)
        history.record("two", from: one, to: two)
        var three = two
        three.replace(at: 0x9000, with: [1, 2, 3])
        history.record("three", from: two, to: three)

        // Back to the start, the newest step first.
        var rom = three
        var labels: [String] = []
        var seen: [ROMImage] = []
        while let label = history.undoLabel, let earlier = history.undo(rom) {
            labels.append(label)
            seen.append(earlier)
            rom = earlier
        }
        #expect(labels == ["three", "two", "one"])
        #expect(seen == [two, one, original])
        // And forward again, in the order they were made.
        labels = []
        seen = []
        while let label = history.redoLabel, let later = history.redo(rom) {
            labels.append(label)
            seen.append(later)
            rom = later
        }
        #expect(labels == ["one", "two", "three"])
        #expect(seen == [one, two, three])
        #expect(!history.canRedo)
    }

    @Test func aNewEditDropsWhatCouldBeRedone() throws {
        let original = ROMDefinitionTests.makeROM()
        var history = ROMEditHistory()
        let first = try Self.editing(original, "Primary Fuel", row: 0, column: 0, to: 7)
        history.record("first", from: original, to: first)
        let undone = history.undo(first)
        let back = try #require(undone)
        #expect(back == original)
        #expect(history.canRedo)

        let second = try Self.editing(back, "Primary Fuel", row: 0, column: 1, to: 9)
        history.record("second", from: back, to: second)
        #expect(!history.canRedo)
        let redone = history.redo(second)
        #expect(redone == nil)
        #expect(history.undoSteps.map(\.label) == ["second"])
        let start = history.undo(second)
        #expect(start == original)
    }

    @Test func correctingTheChecksumsIsOneStep() throws {
        let original = ROMTests.makeROM()
        var history = ROMEditHistory()
        var edited = original
        edited.replace(at: 0x1008, with: [0x55, 0x66])
        history.record("the bytes written at 0x1008", from: original, to: edited)
        let (fixed, report) = try #require(try SubaruChecksum.correctPetrol(edited))
        #expect(report.ok)
        history.record("the checksum correction", from: edited, to: fixed)
        #expect(history.undoSteps.map(\.label) == ["the bytes written at 0x1008", "the checksum correction"])

        // One undo brings the wrong checksums back, the next one the bytes.
        let broken = history.undo(fixed)
        #expect(broken == edited)
        #expect(try SubaruChecksum.verifyPetrol(edited)?.ok == false)
        let start = history.undo(edited)
        #expect(start == original)
    }

    @Test func nothingChangedIsNotAStep() {
        let rom = ROMDefinitionTests.makeROM()
        var history = ROMEditHistory()
        let same = history.record("nothing", from: rom, to: rom)
        let sameBytes = history.record("nothing", at: 0x3000, before: [10, 20], after: [10, 20])
        // A ROM of another size is another ROM, not an edit of this one.
        let otherSize = history.record("another ROM", from: rom, to: ROMImage(data: [1, 2, 3]))
        #expect(!same && !sameBytes && !otherSize)
        #expect(!history.canUndo)
    }

    @Test func theOldestStepsAreForgottenPastTheLimit() {
        var history = ROMEditHistory(limit: 3)
        var rom = ROMImage(data: [UInt8](repeating: 0, count: 16))
        var states = [rom]
        for step in 1...5 {
            let before = rom
            rom.replace(at: step, with: [UInt8(step)])
            history.record("step \(step)", from: before, to: rom)
            states.append(rom)
        }
        #expect(history.undoSteps.map(\.label) == ["step 3", "step 4", "step 5"])
        // Undo goes back as far as the ROM after step 2, and no further.
        var current = rom
        while let earlier = history.undo(current) { current = earlier }
        #expect(current == states[2])
        #expect(ROMEditHistory.defaultLimit >= 100)
    }

    @Test func aStepThatDoesNotFitIsLeftAlone() {
        var history = ROMEditHistory()
        history.record("far away", at: 100, before: [1], after: [2])
        let undone = history.undo(ROMImage(data: [0, 0, 0, 0]))
        #expect(undone == nil)
        #expect(history.canUndo)
    }
}
