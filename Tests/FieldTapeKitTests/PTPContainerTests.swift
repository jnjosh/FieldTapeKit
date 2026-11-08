import Foundation
import Testing
@testable import FieldTapeKit

private let le16 = Bytes.le16, le32 = Bytes.le32

@Suite struct PTPContainerTests {
    @Test func commandContainerLayout() {
        let command = PTPContainer.command(.getObjectHandles, transactionID: 7, params: [0xFFFF_FFFF, 0, 0xFFFF_FFFF])
        #expect(Array(command) == le32(24) + le16(1) + le16(0x1007) + le32(7) + le32(0xFFFF_FFFF) + le32(0) + le32(0xFFFF_FFFF))
    }

    @Test func responseCode() {
        #expect(PTPContainer.responseCode(Data(le32(12) + le16(3) + le16(0x2001) + le32(1))) == 0x2001)
        #expect(PTPContainer.responseCode(Data(le32(12) + le16(2) + le16(0x2001) + le32(1))) == nil)
        #expect(PTPContainer.responseCode(Data()) == nil)
    }

    @Test func payloadStripsOnlyAMatchingContainer() {
        let body: [UInt8] = [1, 2, 3, 4]
        let wrapped = Data(le32(16) + le16(2) + le16(0x1009) + le32(1) + body)
        #expect(Array(PTPContainer.payload(wrapped, for: .getObject)) == body)
        #expect(Array(PTPContainer.payload(Data(body), for: .getObject)) == body)
        #expect(PTPContainer.payload(wrapped, for: .getObjectInfo) == wrapped)
    }

    @Test func payloadIsZeroIndexedForParsers() throws {
        let wrapped = Data(le32(24) + le16(2) + le16(0x1004) + le32(1) + le32(2) + le32(0x10001) + le32(0x20001))
        let payload = PTPContainer.payload(wrapped, for: .getStorageIDs)
        #expect(payload.startIndex == 0)
        #expect(try PTPReader.u32Array(from: payload) == [0x10001, 0x20001])
    }

    @Test func responseParams() {
        #expect(PTPContainer.responseParams(Data(le32(24) + le16(3) + le16(0x2001) + le32(1) + le32(0x10001) + le32(2) + le32(0x4C))) == [0x10001, 2, 0x4C])
        #expect(PTPContainer.responseParams(Data(le32(12) + le16(3) + le16(0x2001) + le32(1))) == [])
    }

    @Test func differences() {
        #expect(Data([1, 2, 3]).differences(from: Data([1, 2, 3])).count == 0)
        #expect(Data([1, 2, 3]).differences(from: Data([1, 2, 3])).firstOffset == nil)

        let changed = Data([1, 2, 3, 4]).differences(from: Data([1, 9, 3, 8]))
        #expect(changed.count == 2)
        #expect(changed.firstOffset == 1)

        let shorter = Data([1, 2, 3]).differences(from: Data([1, 2]))
        #expect(shorter.count == 1)
        #expect(shorter.firstOffset == 2)
    }

    @Test func blankTrackIsAHeaderOnlyRIFF() {
        #expect(WAV.isHeaderOnly(Data(Array("RIFF".utf8)) + Data(count: 40)))
        #expect(!WAV.isHeaderOnly(Data(Array("RIFF".utf8)) + Data(count: 41)))
        #expect(!WAV.isHeaderOnly(Data(count: 44)))
    }
}
