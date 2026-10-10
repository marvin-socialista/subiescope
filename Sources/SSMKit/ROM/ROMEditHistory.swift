import Foundation

/// The edits made to an open ROM, in the order they were made, so each one can be taken back and put
/// back again. A step keeps only the bytes it touched, as they were and as they became, so a long
/// history costs next to nothing. Like the rest of the editor it works on the in-memory `ROMImage`
/// alone; nothing here touches a file or a car.
public struct ROMEditHistory: Sendable, Equatable {
    /// One edit: a stretch of the ROM before and after it.
    public struct Step: Sendable, Equatable {
        /// What the edit was, worded to follow "Undo" and "Redo": "the edit in Primary Fuel".
        public let label: String
        /// Where the stretch starts in the file.
        public let offset: Int
        public let before: [UInt8]
        public let after: [UInt8]
    }

    /// How many steps are kept unless asked otherwise. The oldest ones are forgotten first.
    public static let defaultLimit = 200

    public let limit: Int
    /// The steps that can be taken back, the newest last.
    public private(set) var undoSteps: [Step] = []
    /// The steps that were taken back and can be put back, the next one to put back last.
    public private(set) var redoSteps: [Step] = []

    public init(limit: Int = ROMEditHistory.defaultLimit) {
        self.limit = max(limit, 1)
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    /// The label of the step that Undo would take back, or nil when there is none.
    public var undoLabel: String? { undoSteps.last?.label }
    /// The label of the step that Redo would put back, or nil when there is none.
    public var redoLabel: String? { redoSteps.last?.label }

    // MARK: Recording

    /// Remembers one edit: the bytes at `offset` went from `before` to `after`. A new edit ends the
    /// chance to redo what was undone before it. Bytes that did not change are not an edit: nothing
    /// is remembered then, and false comes back.
    @discardableResult
    public mutating func record(_ label: String, at offset: Int, before: [UInt8], after: [UInt8]) -> Bool {
        guard offset >= 0, before.count == after.count, before != after else { return false }
        undoSteps.append(Step(label: label, offset: offset, before: before, after: after))
        if undoSteps.count > limit { undoSteps.removeFirst(undoSteps.count - limit) }
        redoSteps.removeAll()
        return true
    }

    /// Remembers whatever turned `before` into `after` as one step, from the first byte that differs
    /// to the last. This is how an edit that changes several places at once, such as correcting the
    /// checksums, is taken back in one go. Two ROMs of different sizes are not an edit.
    @discardableResult
    public mutating func record(_ label: String, from before: ROMImage, to after: ROMImage) -> Bool {
        guard let ranges = before.differingRanges(from: after), let first = ranges.first, let last = ranges.last else { return false }
        let span = first.lowerBound..<last.upperBound
        return record(label, at: span.lowerBound, before: Array(before.data[span]), after: Array(after.data[span]))
    }

    // MARK: Undo and redo

    /// Takes the newest step back and returns the ROM as it was before that step. Nil when there is
    /// nothing to take back, or when the step does not fit this ROM: the history is left alone then.
    public mutating func undo(_ rom: ROMImage) -> ROMImage? {
        guard let step = undoSteps.last else { return nil }
        var restored = rom
        guard restored.replace(at: step.offset, with: step.before) else { return nil }
        undoSteps.removeLast()
        redoSteps.append(step)
        return restored
    }

    /// Puts back the step that was taken back last and returns the ROM with that edit in it again.
    /// Nil when there is nothing to put back, or when the step does not fit this ROM.
    public mutating func redo(_ rom: ROMImage) -> ROMImage? {
        guard let step = redoSteps.last else { return nil }
        var edited = rom
        guard edited.replace(at: step.offset, with: step.after) else { return nil }
        redoSteps.removeLast()
        undoSteps.append(step)
        return edited
    }
}
