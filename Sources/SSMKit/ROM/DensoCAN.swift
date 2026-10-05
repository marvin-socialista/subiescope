import Foundation

/// The pure maths behind reading a Denso SH7058 "subarucan" ECU over CAN: the security-access
/// seed-to-key answer, the little block cipher that scrambles the kernel before it is uploaded, and
/// the framing of that upload. None of this touches a car or a serial port, so it is all testable on
/// its own, which matters because the on-car path cannot be tested here.
///
/// This is a direct port of the read path in FastECU's
/// `flash_ecu_subaru_denso_sh7058_can.cpp` (GPLv3): `generate_seed_key` / `calculate_seed_key`,
/// `encrypt_payload` / `calculate_payload`, and the payload preparation inside `upload_kernel`.
/// Only the STOCK seed-key table is ported; the EcuTek/COBB/RaceRom variants are left out on purpose.
public enum DensoCAN {

    // MARK: Shared Feistel transform

    /// The 32-entry substitution table used by both the seed-key answer and the payload cipher. It is
    /// the same `indextransformation[]` in FastECU for the stock algorithm and for `encrypt_payload`.
    static let indexTransform: [UInt8] = [
        0x5, 0x6, 0x7, 0x1, 0x9, 0xC, 0xD, 0x8,
        0xA, 0xD, 0x2, 0xB, 0xF, 0x4, 0x0, 0x3,
        0xB, 0x4, 0x6, 0x0, 0xF, 0x2, 0xD, 0x9,
        0x5, 0xC, 0x1, 0xA, 0x3, 0xD, 0xE, 0x8,
    ]

    /// The round's key-schedule step: from the low 16 bits of the state and this round's key word,
    /// produce the 16-bit value that is mixed into the high half. Depends only on `low` and `key`,
    /// which is what makes the round reversible (a Feistel network).
    static func roundKey(low: UInt16, key: UInt16) -> UInt16 {
        var index = UInt32(low ^ key)
        index = index &+ (index << 16)
        var result: UInt16 = 0
        for n in 0..<4 {
            let nibble = indexTransform[Int((index >> (UInt32(n) * 4)) & 0x1F)]
            result = result &+ (UInt16(nibble) << (UInt16(n) * 4))
        }
        return (result >> 3) &+ (result << 13)
    }

    /// One forward round: (high, low) -> (low, roundKey(low) ^ high), packed as a 32-bit word with
    /// the low half in the low bytes. Matches FastECU's inner loop body.
    static func round(_ state: UInt32, key: UInt16) -> UInt32 {
        let low = UInt16(truncatingIfNeeded: state)
        let high = UInt16(truncatingIfNeeded: state >> 16)
        let newLow = roundKey(low: low, key: key) ^ high
        return UInt32(newLow) | (UInt32(low) << 16)
    }

    /// The exact inverse of `round`, used only to prove the port is self-consistent in tests.
    static func inverseRound(_ state: UInt32, key: UInt16) -> UInt32 {
        let low = UInt16(truncatingIfNeeded: state >> 16)
        let newLow = UInt16(truncatingIfNeeded: state)
        let high = roundKey(low: low, key: key) ^ newLow
        return UInt32(low) | (UInt32(high) << 16)
    }

    /// Runs the round for each key in turn, then swaps the two 16-bit halves. This is the whole of
    /// FastECU's `calculate_seed_key` and `calculate_payload` loops (they differ only in how many
    /// keys and which table).
    static func feistel(_ word: UInt32, keys: [UInt16]) -> UInt32 {
        var state = word
        for key in keys { state = round(state, key: key) }
        return (state >> 16) | (state << 16)
    }

    /// The exact inverse of `feistel`: undo the half-swap, then undo each round in reverse.
    static func inverseFeistel(_ word: UInt32, keys: [UInt16]) -> UInt32 {
        var state = (word >> 16) | (word << 16)
        for key in keys.reversed() { state = inverseRound(state, key: key) }
        return state
    }

    // MARK: Seed -> key (security access, stock)

    /// FastECU's stock `keytogenerateindex_1`.
    static let stockKeyTable: [UInt16] = [
        0x78B1, 0x4625, 0x201C, 0x9EA5,
        0xAD6B, 0x35F4, 0xFD21, 0x5E71,
        0xB046, 0x7F4A, 0x4B75, 0x93F9,
        0x1895, 0x8961, 0x3ECC, 0x862B,
    ]

    /// The answer to a security-access seed, for a stock (untuned) ECU. The seed comes from the ECU's
    /// `27 01` reply; the key is sent back in `27 02`. FastECU walks the table from index 15 down to 0.
    public static func stockKey(fromSeed seed: UInt32) -> UInt32 {
        feistel(seed, keys: stockKeyTable.reversed())
    }

    /// The inverse direction (key -> seed). Present only so a test can show `key(seed)` round-trips;
    /// the car never needs it.
    static func stockSeed(fromKey key: UInt32) -> UInt32 {
        inverseFeistel(key, keys: stockKeyTable.reversed())
    }

    /// The four seed bytes from the ECU, big-endian, to the four key bytes to send back.
    public static func stockKey(fromSeed seed: [UInt8]) -> [UInt8] {
        precondition(seed.count == 4, "Denso CAN seed is four bytes")
        let value = UInt32(seed[0]) << 24 | UInt32(seed[1]) << 16 | UInt32(seed[2]) << 8 | UInt32(seed[3])
        let key = stockKey(fromSeed: value)
        return [UInt8(key >> 24 & 0xFF), UInt8(key >> 16 & 0xFF), UInt8(key >> 8 & 0xFF), UInt8(key & 0xFF)]
    }

    // MARK: Kernel payload cipher

    /// FastECU `encrypt_payload` key table.
    static let encryptTable: [UInt16] = [0xC85B, 0x32C0, 0xE282, 0x92A0]
    /// FastECU `decrypt_payload` key table (the encrypt table reversed): decrypt is the inverse of encrypt.
    static let decryptTable: [UInt16] = [0x92A0, 0xE282, 0x32C0, 0xC85B]

    /// Runs the cipher over whole 32-bit big-endian words. Trailing bytes that do not fill a word are
    /// dropped, exactly as FastECU does (`len &= ~3`).
    static func crypt(_ data: [UInt8], keys: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count & ~3)
        var i = 0
        while i + 4 <= data.count {
            let word = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
            let result = feistel(word, keys: keys)
            out.append(UInt8(result >> 24 & 0xFF))
            out.append(UInt8(result >> 16 & 0xFF))
            out.append(UInt8(result >> 8 & 0xFF))
            out.append(UInt8(result & 0xFF))
            i += 4
        }
        return out
    }

    /// Scrambles a kernel image the way the ECU's loader expects it.
    public static func encryptPayload(_ data: [UInt8]) -> [UInt8] { crypt(data, keys: encryptTable) }
    /// The inverse of `encryptPayload`.
    public static func decryptPayload(_ data: [UInt8]) -> [UInt8] { crypt(data, keys: decryptTable) }

    // MARK: Kernel upload framing

    /// The magic constant the kernel's self-check adds up to (also the Subaru ROM checksum magic).
    static let kernelMagic: UInt32 = 0x5AA5A55A

    /// A kernel binary packed and encrypted ready to send to the ECU, with the shape of the transfer.
    public struct KernelUpload: Equatable, Sendable {
        /// The encrypted bytes to send, exactly `blockCount * 128` long.
        public let encryptedPayload: [UInt8]
        /// How many 128-byte blocks the payload is. FastECU sends these, then one final empty block.
        public let blockCount: Int
        /// The byte length declared to the ECU in the `34` request (equals `blockCount * 128`).
        public let dataLength: Int
        /// Where the kernel is loaded in ECU RAM.
        public let startAddress: UInt32
    }

    /// Reproduces FastECU `upload_kernel`'s payload preparation: pad to a whole number of 128-byte
    /// blocks, replace the last word with a checksum so the whole image sums to the magic, then
    /// encrypt. Pure, so the block count and checksum can be tested without a car.
    public static func prepareKernel(_ kernel: [UInt8], startAddress: UInt32) -> KernelUpload {
        let paddedLength = (kernel.count + 3) & ~3
        var blocks = paddedLength / 128
        if paddedLength % 128 != 0 { blocks += 1 }
        let dataLength = blocks * 128

        var payload = kernel
        while payload.count < dataLength { payload.append(0) }
        // Drop the final word; it is replaced by the checksum that makes the image sum to the magic.
        payload.removeLast(4)

        var sum: UInt32 = 0
        var i = 0
        while i + 4 <= payload.count {
            sum = sum &+ (UInt32(payload[i]) << 24 | UInt32(payload[i + 1]) << 16 | UInt32(payload[i + 2]) << 8 | UInt32(payload[i + 3]))
            i += 4
        }
        let checksum = kernelMagic &- sum
        payload.append(UInt8(checksum >> 24 & 0xFF))
        payload.append(UInt8(checksum >> 16 & 0xFF))
        payload.append(UInt8(checksum >> 8 & 0xFF))
        payload.append(UInt8(checksum & 0xFF))

        return KernelUpload(encryptedPayload: encryptPayload(payload),
                            blockCount: blocks, dataLength: dataLength, startAddress: startAddress)
    }
}
