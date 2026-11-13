/// The MTP operations FieldTapeKit sends. Nothing outside this list can be sent: it's ADR 0002, safety rule 7.
package enum PTPOperation: UInt16, Sendable, CaseIterable {
    // Reads
    case getDeviceInfo = 0x1001
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getPartialObject = 0x101B

    // Writes
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
}

package enum PTPResponseCode {
    package static let ok: UInt16 = 0x2001
    /// What the OP-1 answers when a folder doesn't allow a name.
    static let generalError: UInt16 = 0x2002
    static let storeFull: UInt16 = 0x200C
}

enum PTPContainerType {
    static let command: UInt16 = 1
    static let data: UInt16 = 2
    static let response: UInt16 = 3
}

package enum PTPObjectFormat {
    package static let association: UInt16 = 0x3001
    /// What the OP-1 reports for `readme.txt` and other plain files.
    package static let undefined: UInt16 = 0x3000
    package static let text: UInt16 = 0x3004
    package static let wav: UInt16 = 0x3008
}

enum PTPAssociationType {
    static let genericFolder: UInt16 = 0x0001
}

enum PTPError: Error, Equatable, CustomStringConvertible {
    case truncated(offset: Int)

    var description: String {
        switch self {
        case .truncated(let offset): "dataset truncated at byte \(offset)"
        }
    }
}
