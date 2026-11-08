import Foundation

/// Reads little-endian PTP datasets. Every read past the end throws `PTPError.truncated`.
struct PTPReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw PTPError.truncated(offset: offset) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        let low = try u8(), high = try u8()
        return UInt16(low) | UInt16(high) << 8
    }

    mutating func u32() throws -> UInt32 {
        let low = try u16(), high = try u16()
        return UInt32(low) | UInt32(high) << 16
    }

    mutating func u64() throws -> UInt64 {
        let low = try u32(), high = try u32()
        return UInt64(low) | UInt64(high) << 32
    }

    /// One-byte character count, including the terminator, then UTF-16LE.
    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try u16()) }
        return String(decoding: units.dropLast(), as: UTF16.self)
    }

    mutating func u16Array() throws -> [UInt16] {
        try (0..<(try u32())).map { _ in try u16() }
    }

    mutating func u32Array() throws -> [UInt32] {
        try (0..<(try u32())).map { _ in try u32() }
    }

    static func u32Array(from data: Data) throws -> [UInt32] {
        var reader = PTPReader(data)
        return try reader.u32Array()
    }
}
