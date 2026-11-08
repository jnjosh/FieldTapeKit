/// Little-endian byte builders for PTP test fixtures.
enum Bytes {
    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }
    static func le64(_ value: UInt64) -> [UInt8] { le32(UInt32(value & 0xFFFF_FFFF)) + le32(UInt32(value >> 32)) }

    static func ptpString(_ value: String) -> [UInt8] {
        guard !value.isEmpty else { return [0] }
        let units = Array(value.utf16) + [0]
        return [UInt8(units.count)] + units.flatMap(le16)
    }

    static func u16Array(_ values: [UInt16]) -> [UInt8] { le32(UInt32(values.count)) + values.flatMap(le16) }
}
