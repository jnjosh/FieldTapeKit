import XCTest
@testable import OP1Probe

final class PTPParsingTests: XCTestCase {
    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func le32(_ value: UInt32) -> [UInt8] { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }
    private func ptpString(_ value: String) -> [UInt8] {
        guard !value.isEmpty else { return [0] }
        let units = Array(value.utf16) + [0]
        return [UInt8(units.count)] + units.flatMap(le16)
    }
    private func u16Array(_ values: [UInt16]) -> [UInt8] { le32(UInt32(values.count)) + values.flatMap(le16) }

    func testCommandContainerLayout() {
        let command = PTP.command(.getObjectHandles, transactionID: 7, params: [0xFFFF_FFFF, 0, 0xFFFF_FFFF])
        XCTAssertEqual(Array(command), le32(24) + le16(1) + le16(0x1007) + le32(7) + le32(0xFFFF_FFFF) + le32(0) + le32(0xFFFF_FFFF))
    }

    func testResponseCode() {
        XCTAssertEqual(PTP.responseCode(Data(le32(12) + le16(3) + le16(0x2001) + le32(1))), 0x2001)
        XCTAssertNil(PTP.responseCode(Data(le32(12) + le16(2) + le16(0x2001) + le32(1))))
        XCTAssertNil(PTP.responseCode(Data()))
    }

    func testPayloadStripsOnlyAMatchingContainer() {
        let body: [UInt8] = [1, 2, 3, 4]
        let wrapped = Data(le32(16) + le16(2) + le16(0x1009) + le32(1) + body)
        XCTAssertEqual(Array(PTP.payload(wrapped, op: .getObject)), body)
        XCTAssertEqual(Array(PTP.payload(Data(body), op: .getObject)), body)
        XCTAssertEqual(PTP.payload(wrapped, op: .getObjectInfo), wrapped)
    }

    func testPayloadIsZeroIndexedForParsers() throws {
        let wrapped = Data(le32(24) + le16(2) + le16(0x1004) + le32(1) + le32(2) + le32(0x10001) + le32(0x20001))
        XCTAssertEqual(try PTPReader.u32Array(from: PTP.payload(wrapped, op: .getStorageIDs)), [0x10001, 0x20001])
    }

    func testDeviceInfo() throws {
        let bytes: [UInt8] = le16(100) + le32(6) + le16(100) + ptpString("microsoft.com: 1.0;") + le16(0)
            + u16Array([0x1001, 0x1009, 0x9805]) + u16Array([]) + u16Array([]) + u16Array([]) + u16Array([0x3000])
            + ptpString("teenage engineering") + ptpString("OP-1") + ptpString("1.0") + ptpString("ABC")
        let info = try PTPDeviceInfo(Data(bytes))
        XCTAssertEqual(info.vendorExtensionID, 6)
        XCTAssertEqual(info.vendorExtensionDescription, "microsoft.com: 1.0;")
        XCTAssertEqual(info.operations, [0x1001, 0x1009, 0x9805])
        XCTAssertEqual(info.manufacturer, "teenage engineering")
        XCTAssertEqual(info.model, "OP-1")
        XCTAssertEqual(info.serialNumber, "ABC")
    }

    func testObjectInfo() throws {
        var bytes: [UInt8] = le32(0x10001) + le16(0x3007) + le16(0) + le32(4096) + le16(0)
        for _ in 0..<6 { bytes += le32(0) }
        bytes += le32(0x55) + le16(0) + le32(0) + le32(0) + ptpString("track_1.aif") + ptpString("") + ptpString("") + ptpString("")

        let info = try PTPObjectInfo(Data(bytes))
        XCTAssertEqual(info.storageID, 0x10001)
        XCTAssertEqual(info.compressedSize, 4096)
        XCTAssertEqual(info.parent, 0x55)
        XCTAssertEqual(info.filename, "track_1.aif")
        XCTAssertFalse(info.isFolder)
    }

    func testResponseParams() {
        XCTAssertEqual(PTP.responseParams(Data(le32(24) + le16(3) + le16(0x2001) + le32(1) + le32(0x10001) + le32(2) + le32(0x4C))), [0x10001, 2, 0x4C])
        XCTAssertEqual(PTP.responseParams(Data(le32(12) + le16(3) + le16(0x2001) + le32(1))), [])
    }

    func testObjectInfoDatasetParsesBack() throws {
        let dataset = PTP.objectInfoDataset(storageID: 0x10001, format: 0x3007, size: 62012, parent: 2, filename: "probe-copy.aif")
        let info = try PTPObjectInfo(dataset)
        XCTAssertEqual(info.storageID, 0x10001)
        XCTAssertEqual(info.format, 0x3007)
        XCTAssertEqual(info.compressedSize, 62012)
        XCTAssertEqual(info.parent, 2)
        XCTAssertEqual(info.filename, "probe-copy.aif")
        XCTAssertFalse(info.isFolder)
    }

    func testDifferences() {
        XCTAssertEqual(PTP.differences(Data([1, 2, 3]), Data([1, 2, 3])).count, 0)
        XCTAssertNil(PTP.differences(Data([1, 2, 3]), Data([1, 2, 3])).firstOffset)

        let changed = PTP.differences(Data([1, 2, 3, 4]), Data([1, 9, 3, 8]))
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(changed.firstOffset, 1)

        let shorter = PTP.differences(Data([1, 2, 3]), Data([1, 2]))
        XCTAssertEqual(shorter.count, 1)
        XCTAssertEqual(shorter.firstOffset, 2)
    }

    private func object(_ handle: UInt32, _ path: String, size: UInt32, parent: UInt32, format: UInt16 = 0x3008) throws -> ProbeObject {
        let filename = String(path.split(separator: "/").last!)
        let dataset = PTP.objectInfoDataset(storageID: 0x10001, format: format, size: size, parent: parent, filename: filename)
        return ProbeObject(handle: handle, path: path, info: try PTPObjectInfo(dataset))
    }

    private func tape(_ folder: UInt32, _ name: String, sizes: [UInt32]) throws -> [ProbeObject] {
        var objects = [try object(folder, "tapes/\(name)", size: 0, parent: 100, format: PTP.associationFormat)]
        for (index, size) in sizes.enumerated() {
            objects.append(try object(folder + UInt32(index) + 1, "tapes/\(name)/track_\(index + 1).wav", size: size, parent: folder))
        }
        return objects
    }

    func testTapeWritePlanTargetsAllBlankTapeAndSmallestRealTrack() throws {
        let objects = try tape(10, "partly", sizes: [44, 44, 44, 22_000_000])
            + tape(20, "blank", sizes: [44, 44, 44, 44])
            + tape(30, "real", sizes: [1_521_204, 1_514_988, 44, 44])
            + [try object(40, "mixdown/side_a.wav", size: 1_000, parent: 41)]
        let plan = try XCTUnwrap(ProbeObject.tapeWritePlan(in: objects))
        XCTAssertEqual(plan.folder.handle, 20)
        XCTAssertEqual(plan.blank.path, "tapes/blank/track_1.wav")
        XCTAssertEqual(plan.source.path, "tapes/real/track_2.wav")

        let large = try XCTUnwrap(ProbeObject.tapeWritePlan(in: objects, largest: true))
        XCTAssertEqual(large.blank.path, "tapes/blank/track_1.wav")
        XCTAssertEqual(large.source.path, "tapes/partly/track_4.wav")
    }

    func testTapeWritePlanNeedsABlankTape() throws {
        XCTAssertNil(ProbeObject.tapeWritePlan(in: try tape(10, "real", sizes: [1_000, 44, 44, 44])))
    }

    func testBlankTrackIsAHeaderOnlyRIFF() {
        XCTAssertTrue(PTP.isBlankTrack(Data(Array("RIFF".utf8)) + Data(count: 40)))
        XCTAssertFalse(PTP.isBlankTrack(Data(Array("RIFF".utf8)) + Data(count: 41)))
        XCTAssertFalse(PTP.isBlankTrack(Data(count: 44)))
    }

    func testTruncatedDatasetThrows() {
        XCTAssertThrowsError(try PTPObjectInfo(Data([1, 2, 3])))
        XCTAssertThrowsError(try PTPReader.u32Array(from: Data(le32(5))))
    }

    private func tapeWithJSON(_ folder: UInt32, _ name: String, sizes: [UInt32]) throws -> [ProbeObject] {
        try tape(folder, name, sizes: sizes) + [try object(folder + 5, "tapes/\(name)/tape.json", size: 300, parent: folder, format: PTP.textFormat)]
    }

    func testWholeTapePlanCopiesSmallestRealTapeOntoBlankTape() throws {
        let objects = try tapeWithJSON(10, "big", sizes: [21_168_044, 17_992_844, 17_992_844, 21_172_100])
            + tapeWithJSON(20, "blank", sizes: [44, 44, 44, 44])
            + tapeWithJSON(30, "small", sizes: [1_164_852, 1_206_836, 44, 44])
            + tape(40, "nojson", sizes: [100, 44, 44, 44])
        let plan = try XCTUnwrap(ProbeObject.wholeTapePlan(in: objects))
        XCTAssertEqual(plan.source.path, "tapes/small")
        XCTAssertEqual(plan.target.path, "tapes/blank")
        XCTAssertEqual(try XCTUnwrap(ProbeObject.wholeTapePlan(in: objects, largest: true)).source.path, "tapes/big")
    }

    func testWholeTapePlanNeedsABlankTapeWithTapeJSON() throws {
        let objects = try tape(20, "blank", sizes: [44, 44, 44, 44]) + tapeWithJSON(30, "small", sizes: [1_164_852, 44, 44, 44])
        XCTAssertNil(ProbeObject.wholeTapePlan(in: objects))
    }

    /// tapes/2026-220#02 as read from the OP-1 on 2026-11-08.
    private let realTapeJSON = Data(#"{"clips":[{"ch":0,"id":0,"padding":[112,113,-1,-1],"start":0,"stop":145601},{"ch":1,"id":1,"padding":[114,115,-1,-1],"start":0,"stop":150849}],"loop":true,"loop_in":0,"loop_out":264600,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,"tape_type":1,"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,"temposyncout":1,"temposynctype":0,"track":1,"version":1}"#.utf8)
    private let realTrackSizes: [String: UInt64] = ["track_1.wav": 1_164_852, "track_2.wav": 1_206_836, "track_3.wav": 44, "track_4.wav": 44]

    func testTapeProblemsAcceptsARealTape() {
        XCTAssertEqual(PTP.tapeProblems(json: realTapeJSON, trackSizes: realTrackSizes), [])
        XCTAssertEqual(PTP.clipCount(realTapeJSON), 2)
    }

    func testTapeProblemsCatchesWrongSizesAndMissingTracks() {
        var sizes = realTrackSizes
        sizes["track_1.wav"] = 1_000
        sizes["track_4.wav"] = nil
        let problems = PTP.tapeProblems(json: realTapeJSON, trackSizes: sizes)
        XCTAssertEqual(problems, ["track_1.wav is 1000 bytes, clips imply 1164852", "track_4.wav missing"])
        XCTAssertEqual(PTP.tapeProblems(json: Data("{}".utf8), trackSizes: sizes), ["tape.json has no clips array"])
    }

    func testTapeProblemsCatchesClipsPastSixMinutes() {
        let json = Data(#"{"clips":[{"ch":0,"id":0,"start":0,"stop":15876001}]}"#.utf8)
        let sizes: [String: UInt64] = ["track_1.wav": 44 + 8 * 15_876_001, "track_2.wav": 44, "track_3.wav": 44, "track_4.wav": 44]
        XCTAssertEqual(PTP.tapeProblems(json: json, trackSizes: sizes), ["clip on ch 0 ends past 6 minutes, at frame 15876001"])
    }

    func testTapeNameCharacters() {
        XCTAssertEqual(PTP.unexpectedTapeNameCharacters("2026-312#01"), [])
        XCTAssertEqual(PTP.unexpectedTapeNameCharacters("PROBE 1-#A"), [])
        XCTAssertEqual(PTP.unexpectedTapeNameCharacters("probe_1_é"), ["p", "r", "o", "b", "e", "_", "é"])
    }

    func testFolderDatasetCarriesAssociationType() throws {
        let dataset = PTP.objectInfoDataset(storageID: 0x10001, format: PTP.associationFormat, size: 0, parent: 7,
                                            filename: "PROBE 1-#A", associationType: PTP.genericFolder)
        let info = try PTPObjectInfo(dataset)
        XCTAssertEqual(info.associationType, PTP.genericFolder)
        XCTAssertEqual(info.filename, "PROBE 1-#A")
        XCTAssertTrue(info.isFolder)
    }

    func testCopySourceIgnoresBlankAndIncompleteTapes() throws {
        let objects = try tapeWithJSON(20, "blank", sizes: [44, 44, 44, 44])
            + tapeWithJSON(30, "small", sizes: [1_164_852, 44, 44, 44])
            + tape(40, "nojson", sizes: [100, 44, 44, 44])
        XCTAssertEqual(ProbeObject.copySource(in: objects)?.path, "tapes/small")
        XCTAssertNil(ProbeObject.copySource(in: try tapeWithJSON(20, "blank", sizes: [44, 44, 44, 44])))
    }
}
