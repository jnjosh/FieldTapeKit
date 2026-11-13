import Foundation

/// The DeviceInfo dataset (GetDeviceInfo).
package struct PTPDeviceInfo: Sendable, Equatable {
    package let standardVersion: UInt16
    package let vendorExtensionID: UInt32
    package let vendorExtensionDescription: String
    package let operations: [UInt16]
    package let manufacturer: String
    package let model: String
    package let deviceVersion: String
    package let serialNumber: String

    package init(_ data: Data) throws {
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
package struct PTPObjectInfo: Sendable, Equatable {
    package let storageID: UInt32
    package let format: UInt16
    package let compressedSize: UInt32
    package let parent: UInt32
    package let associationType: UInt16
    package let filename: String

    package var isFolder: Bool { format == PTPObjectFormat.association || associationType != 0 }

    package init(_ data: Data) throws {
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
package struct PTPStorageInfo: Sendable, Equatable {
    package let storageType: UInt16
    package let filesystemType: UInt16
    package let accessCapability: UInt16
    package let maxCapacity: UInt64
    package let freeSpaceInBytes: UInt64
    package let freeSpaceInObjects: UInt32
    package let storageDescription: String
    package let volumeLabel: String

    package init(_ data: Data) throws {
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
