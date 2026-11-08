import Foundation

/// The DeviceInfo dataset (GetDeviceInfo).
struct PTPDeviceInfo: Sendable, Equatable {
    let standardVersion: UInt16
    let vendorExtensionID: UInt32
    let vendorExtensionDescription: String
    let operations: [UInt16]
    let manufacturer: String
    let model: String
    let deviceVersion: String
    let serialNumber: String

    init(_ data: Data) throws {
        var reader = PTPReader(data)
        standardVersion = try reader.u16()
        vendorExtensionID = try reader.u32()
        _ = try reader.u16() // VendorExtensionVersion
        vendorExtensionDescription = try reader.string()
        _ = try reader.u16() // FunctionalMode
        operations = try reader.u16Array()
        _ = try reader.u16Array() // EventsSupported
        _ = try reader.u16Array() // DevicePropertiesSupported
        _ = try reader.u16Array() // CaptureFormats
        _ = try reader.u16Array() // ImageFormats
        manufacturer = try reader.string()
        model = try reader.string()
        deviceVersion = try reader.string()
        serialNumber = try reader.string()
    }
}

/// The ObjectInfo dataset (GetObjectInfo), as far as FieldTapeKit reads it.
struct PTPObjectInfo: Sendable, Equatable {
    let storageID: UInt32
    let format: UInt16
    let compressedSize: UInt32
    let parent: UInt32
    let associationType: UInt16
    let filename: String

    var isFolder: Bool { format == PTPObjectFormat.association || associationType != 0 }

    init(_ data: Data) throws {
        var reader = PTPReader(data)
        storageID = try reader.u32()
        format = try reader.u16()
        _ = try reader.u16() // ProtectionStatus
        compressedSize = try reader.u32()
        _ = try reader.u16() // ThumbFormat
        for _ in 0..<6 { _ = try reader.u32() } // Thumb and image dimensions
        parent = try reader.u32()
        associationType = try reader.u16()
        _ = try reader.u32() // AssociationDesc
        _ = try reader.u32() // SequenceNumber
        filename = try reader.string()
    }

    /// The dataset SendObjectInfo sends ahead of a new file or folder.
    static func dataset(storageID: UInt32, format: UInt16, size: UInt32, parent: UInt32,
                        filename: String, associationType: UInt16 = 0) -> Data {
        var data = Data()
        data.appendLittleEndian(storageID)
        data.appendLittleEndian(format)
        data.appendLittleEndian(UInt16(0)) // ProtectionStatus
        data.appendLittleEndian(size)
        data.appendLittleEndian(UInt16(0)) // ThumbFormat
        for _ in 0..<6 { data.appendLittleEndian(UInt32(0)) } // Thumb and image dimensions
        data.appendLittleEndian(parent)
        data.appendLittleEndian(associationType)
        data.appendLittleEndian(UInt32(0)) // AssociationDesc
        data.appendLittleEndian(UInt32(0)) // SequenceNumber
        data.appendPTPString(filename)
        for _ in 0..<3 { data.appendPTPString("") } // CaptureDate, ModificationDate, Keywords
        return data
    }
}

/// The StorageInfo dataset (GetStorageInfo). Whether the OP-1's free space is accurate is untested
/// (ADR 0002, section 1; ADR 0003, `device.storage`).
struct PTPStorageInfo: Sendable, Equatable {
    let storageType: UInt16
    let filesystemType: UInt16
    let accessCapability: UInt16
    let maxCapacity: UInt64
    let freeSpaceInBytes: UInt64
    let freeSpaceInObjects: UInt32
    let storageDescription: String
    let volumeLabel: String

    init(_ data: Data) throws {
        var reader = PTPReader(data)
        storageType = try reader.u16()
        filesystemType = try reader.u16()
        accessCapability = try reader.u16()
        maxCapacity = try reader.u64()
        freeSpaceInBytes = try reader.u64()
        freeSpaceInObjects = try reader.u32()
        storageDescription = try reader.string()
        volumeLabel = try reader.string()
    }
}
