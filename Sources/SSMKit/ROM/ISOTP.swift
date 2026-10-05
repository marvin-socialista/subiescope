import Foundation

/// ISO-TP (ISO 15765-2) frame segmentation and reassembly, for classic 8-byte CAN frames with
/// normal addressing. The Denso ECU talks ISO-TP on 11-bit IDs 0x7E0 (tester) / 0x7E8 (ECU).
///
/// On an STN-based adapter (OBDLink EX) the adapter itself does this segmentation when
/// `STCSEGR`/`STCSEGT` are on, so the transport does not send raw frames. These functions are the
/// reference model of that behaviour: they are unit-tested on their own and used by the simulated ECU
/// in the tests, so the framing is pinned down even though the car path is untested here.
public enum ISOTP {
    public static let frameSize = 8
    /// The most a single ISO-TP message can carry with a classic (non-extended) length field.
    public static let maxMessageLength = 0x0FFF

    public enum FrameError: Error, Equatable {
        case empty
        case unexpectedFrameType(UInt8)
        case outOfOrder(expected: UInt8, got: UInt8)
        case truncated
        case tooLong
    }

    /// Splits a message into the frames that would go on the bus: one single frame for up to 7 bytes,
    /// otherwise a first frame (6 bytes) followed by consecutive frames (7 bytes each) numbered 1, 2,
    /// … wrapping at 16. Frames are padded to 8 bytes with `pad`.
    public static func segment(_ payload: [UInt8], pad: UInt8 = 0x00) -> [[UInt8]] {
        precondition(payload.count <= maxMessageLength, "ISO-TP message too long")
        func padded(_ frame: [UInt8]) -> [UInt8] {
            frame.count >= frameSize ? frame : frame + [UInt8](repeating: pad, count: frameSize - frame.count)
        }
        if payload.count <= 7 {
            return [padded([UInt8(payload.count)] + payload)]
        }
        var frames: [[UInt8]] = []
        let first = [UInt8(0x10 | (payload.count >> 8)), UInt8(payload.count & 0xFF)] + payload.prefix(6)
        frames.append(padded(first))
        var index = 6
        var sequence: UInt8 = 1
        while index < payload.count {
            let chunk = payload[index..<min(index + 7, payload.count)]
            frames.append(padded([0x20 | (sequence & 0x0F)] + chunk))
            index += 7
            sequence = sequence &+ 1
        }
        return frames
    }

    /// Rebuilds the message from its frames, the inverse of `segment`. Flow-control frames (type 0x3)
    /// are ignored, since on a real bus the tester sends those, not the ECU.
    public static func reassemble(_ frames: [[UInt8]]) throws -> [UInt8] {
        var iterator = frames.makeIterator()
        guard var frame = nextDataFrame(&iterator) else { throw FrameError.empty }

        let type = frame[0] >> 4
        switch type {
        case 0x0:   // single frame
            let length = Int(frame[0] & 0x0F)
            guard frame.count >= 1 + length else { throw FrameError.truncated }
            return Array(frame[1..<(1 + length)])
        case 0x1:   // first frame + consecutive frames
            guard frame.count >= 2 else { throw FrameError.truncated }
            let length = (Int(frame[0] & 0x0F) << 8) | Int(frame[1])
            guard length <= maxMessageLength else { throw FrameError.tooLong }
            var data = Array(frame.dropFirst(2))
            var expected: UInt8 = 1
            while data.count < length {
                guard let next = nextDataFrame(&iterator) else { throw FrameError.truncated }
                frame = next
                guard frame[0] >> 4 == 0x2 else { throw FrameError.unexpectedFrameType(frame[0] >> 4) }
                let sequence = frame[0] & 0x0F
                guard sequence == (expected & 0x0F) else { throw FrameError.outOfOrder(expected: expected & 0x0F, got: sequence) }
                data.append(contentsOf: frame.dropFirst())
                expected = expected &+ 1
            }
            guard data.count >= length else { throw FrameError.truncated }
            return Array(data.prefix(length))
        default:
            throw FrameError.unexpectedFrameType(type)
        }
    }

    /// The next frame that is not a flow-control frame (0x3).
    private static func nextDataFrame(_ iterator: inout IndexingIterator<[[UInt8]]>) -> [UInt8]? {
        while let frame = iterator.next() {
            guard let first = frame.first else { continue }
            if first >> 4 == 0x3 { continue }   // flow control, not our data
            return frame
        }
        return nil
    }
}
