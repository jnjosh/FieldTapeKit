import Foundation
import Testing
@testable import FieldTapeKit

private let le16 = Bytes.le16, le32 = Bytes.le32, le64 = Bytes.le64
private let ptpString = Bytes.ptpString, u16Array = Bytes.u16Array

@Suite struct PTPDatasetTests {
    @Test func deviceInfo() throws {
        let bytes: [UInt8] = le16(100) + le32(6) + le16(100) + ptpString("microsoft.com: 1.0;") + le16(0)
            + u16Array([0x1001, 0x1009, 0x9805]) + u16Array([]) + u16Array([]) + u16Array([]) + u16Array([0x3000])
            + ptpString("teenage engineering") + ptpString("OP-1") + ptpString("1.0") + ptpString("ABC")
        let info = try PTPDeviceInfo(Data(bytes))
        #expect(info.vendorExtensionID == 6)
        #expect(info.vendorExtensionDescription == "microsoft.com: 1.0;")
        #expect(info.operations == [0x1001, 0x1009, 0x9805])
        #expect(info.manufacturer == "teenage engineering")
        #expect(info.model == "OP-1")
        #expect(info.deviceVersion == "1.0")
        #expect(info.serialNumber == "ABC")
    }

    @Test func objectInfo() throws {
        var bytes: [UInt8] = le32(0x10001) + le16(0x3007) + le16(0) + le32(4096) + le16(0)
        for _ in 0..<6 { bytes += le32(0) }
        bytes += le32(0x55) + le16(0) + le32(0) + le32(0) + ptpString("track_1.aif") + ptpString("") + ptpString("") + ptpString("")

        let info = try PTPObjectInfo(Data(bytes))
        #expect(info.storageID == 0x10001)
        #expect(info.compressedSize == 4096)
        #expect(info.parent == 0x55)
        #expect(info.filename == "track_1.aif")
        #expect(!info.isFolder)
    }

    @Test func objectInfoDatasetParsesBack() throws {
        let dataset = PTPObjectInfo.dataset(storageID: 0x10001, format: 0x3007, size: 62012, parent: 2, filename: "probe-copy.aif")
        let info = try PTPObjectInfo(dataset)
        #expect(info.storageID == 0x10001)
        #expect(info.format == 0x3007)
        #expect(info.compressedSize == 62012)
        #expect(info.parent == 2)
        #expect(info.filename == "probe-copy.aif")
        #expect(!info.isFolder)
    }

    @Test func folderDatasetCarriesAssociationType() throws {
        let dataset = PTPObjectInfo.dataset(storageID: 0x10001, format: PTPObjectFormat.association, size: 0, parent: 7,
                                            filename: "PROBE 1-#A", associationType: PTPAssociationType.genericFolder)
        let info = try PTPObjectInfo(dataset)
        #expect(info.associationType == PTPAssociationType.genericFolder)
        #expect(info.filename == "PROBE 1-#A")
        #expect(info.isFolder)
    }

    @Test func truncatedDatasetThrows() {
        #expect(throws: PTPError.self) { try PTPObjectInfo(Data([1, 2, 3])) }
        #expect(throws: PTPError.self) { try PTPReader.u32Array(from: Data(le32(5))) }
    }

    // StorageInfo, built to the PTP spec's StorageInfo dataset. The probe never captured a real reply,
    // so FieldCheck's `device.storage` check is what confirms the OP-1's layout.

    private func storageInfoBytes(free: UInt64) -> [UInt8] {
        le16(0x0003) + le16(0x0002) + le16(0x0000)   // fixed RAM, generic hierarchical, read-write
            + le64(64 << 30) + le64(free) + le32(0xFFFF_FFFF)
            + ptpString("OP-1 Field") + ptpString("")
    }

    @Test func storageInfo() throws {
        let info = try PTPStorageInfo(Data(storageInfoBytes(free: 12_345_678_901)))
        #expect(info.storageType == 3)
        #expect(info.filesystemType == 2)
        #expect(info.accessCapability == 0)
        #expect(info.maxCapacity == 64 << 30)
        #expect(info.freeSpaceInBytes == 12_345_678_901)
        #expect(info.freeSpaceInObjects == 0xFFFF_FFFF)
        #expect(info.storageDescription == "OP-1 Field")
        #expect(info.volumeLabel == "")
    }

    @Test func storageInfoReadsFreeSpaceAbove4GB() throws {
        let free: UInt64 = 0x0000_0001_0000_0002
        #expect(try PTPStorageInfo(Data(storageInfoBytes(free: free))).freeSpaceInBytes == free)
    }

    @Test func truncatedStorageInfoThrows() {
        let bytes = storageInfoBytes(free: 1)
        #expect(throws: PTPError.truncated(offset: 14)) { try PTPStorageInfo(Data(bytes.prefix(14))) }
    }
}
