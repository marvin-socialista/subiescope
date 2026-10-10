import Foundation

/// The freeze frame of the demo cars: what the engine was doing when the ECU stored the catalytic
/// converter code. Warm, in closed loop, on a steady cruise, which is when a real ECU tests the
/// converter.
enum DemoFreezeFrame {
    /// The values the frame holds, besides the code itself (02).
    static let held: Set<UInt8> = [0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11]

    /// The moment itself, in the demo world's own names and units.
    static let moment: [String: Double] = [
        "rpm": 2350, "speed": 78, "load": 19, "throttle": 19, "coolant": 91, "iat": 24,
        "map": 62, "maf": 21.5, "afc": 2.3, "afl": -1.6, "timing": 24,
    ]

    /// What an ECU that kept this frame for `code` answers to a service 02 request (`02`, the value,
    /// the frame number), from the service byte on. Nil is silence. An ECU without a stored code still
    /// answers which code its frame is for: none.
    static func answer(to request: [UInt8], code: String?) -> [UInt8]? {
        guard request.count >= 2, request[0] == 0x02 else { return nil }
        let pid = request[1]
        guard request.count < 3 || request[2] == 0 else { return nil }   // only frame 0 exists
        if pid == 0x02 { return [0x42, 0x02, 0x00] + (code.map(SimulatedELM.codeBytes) ?? [0, 0]) }
        guard code != nil else { return nil }
        if pid == 0x00 {
            var mask = [UInt8](repeating: 0, count: 4)
            for value in held.union([0x02]) {
                mask[Int(value - 1) / 8] |= 0x80 >> UInt8(Int(value - 1) % 8)
            }
            return [0x42, 0x00, 0x00] + mask
        }
        guard held.contains(pid) else { return nil }
        // Closed loop, and no second fuel system.
        guard let data = pid == 0x03 ? [0x02, 0x00] : SimulatedELM.encode(pid, world: moment, runTime: 1260) else { return nil }
        return [0x42, pid, 0x00] + data
    }
}
