import Foundation

/// Building command containers and reading response containers. Carried over from the probe.
package enum PTPContainer {
    static let headerSize = 12
    /// For GetObjectHandles: every storage, and the root as parent.
    package static let allStorages: UInt32 = 0xFFFF_FFFF
    package static let rootParent: UInt32 = 0xFFFF_FFFF

    static func command(_ operation: PTPOperation, transactionID: UInt32, params: [UInt32]) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(headerSize + params.count * 4))
        data.appendLittleEndian(PTPContainerType.command)
        data.appendLittleEndian(operation.rawValue)
        data.appendLittleEndian(transactionID)
        params.forEach { data.appendLittleEndian($0) }
        return data
    }

    /// Whether ImageCaptureCore hands back the data phase with its container header isn't documented,
    /// so the header is stripped only when one is really there. The result always starts at index 0.
    static func payload(_ data: Data, for operation: PTPOperation) -> Data {
        let data = Data(data)
        guard hasContainerHeader(data, for: operation) else { return data }
        return Data(data.dropFirst(headerSize))
    }

    /// Whether the data starts with a data container header for this operation whose length is the whole data.
    static func hasContainerHeader(_ data: Data, for operation: PTPOperation) -> Bool {
        var reader = PTPReader(Data(data))
        guard let length = try? reader.u32(), let type = try? reader.u16(), let code = try? reader.u16() else {
            return false
        }
        return length == data.count && type == PTPContainerType.data && code == operation.rawValue
    }

    static func responseCode(_ data: Data) -> UInt16? {
        var reader = PTPReader(data)
        guard (try? reader.u32()) != nil, (try? reader.u16()) == PTPContainerType.response else { return nil }
        return try? reader.u16()
    }

    static func responseParams(_ data: Data) -> [UInt32] {
        var reader = PTPReader(data)
        guard (try? reader.u32()) != nil, (try? reader.u32()) != nil, (try? reader.u32()) != nil else { return [] }
        var params: [UInt32] = []
        while let param = try? reader.u32() { params.append(param) }
        return params
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// For AIFF, which is big-endian.
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// One-byte character count, including the terminator, then UTF-16LE. An empty string is a single zero.
    mutating func appendPTPString(_ string: String) {
        guard !string.isEmpty else { return append(0) }
        let units = Array(string.utf16) + [0]
        append(UInt8(units.count))
        units.forEach { appendLittleEndian($0) }
    }
}
