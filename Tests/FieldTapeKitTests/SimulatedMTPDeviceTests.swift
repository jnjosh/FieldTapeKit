import Foundation
import Testing
@testable import FieldTapeKit

/// The session against the simulated OP-1, so every command is encoded, decoded and answered for real.
@Suite struct SimulatedMTPDeviceTests {
    private let track = Data((0..<1_000).map { UInt8($0 % 251) })

    /// tapes/2026-220#02/track_1.wav, tape.json, and an empty mixdown/.
    private func populated(faults: [SimulatedMTPDevice.Fault] = []) async -> (SimulatedMTPDevice, Handles) {
        let device = SimulatedMTPDevice(capacity: 10_000, faults: faults)
        let tapes = await device.addFolder("tapes")
        let tape = await device.addFolder("2026-220#02", in: tapes)
        let trackHandle = await device.addFile("track_1.wav", data: track, in: tape)
        let json = await device.addFile("tape.json", data: Data("{}".utf8), format: PTPObjectFormat.text, in: tape)
        let mixdown = await device.addFolder("mixdown")
        return (device, Handles(tapes: tapes, tape: tape, track: trackHandle, json: json, mixdown: mixdown))
    }

    private struct Handles {
        let tapes, tape, track, json, mixdown: UInt32
    }

    private func session(_ device: SimulatedMTPDevice) -> MTPSession {
        MTPSession(transport: device, timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
    }

    @Test func deviceInfoLooksLikeFirmware173() async throws {
        let info = try await session(SimulatedMTPDevice()).deviceInfo()
        #expect(info.manufacturer == "teenage engineering")
        #expect(info.model == "OP-1")
        #expect(info.deviceVersion == "1.7.3")
        #expect(info.vendorExtensionID == 6)
        #expect(info.operations.count == 21)
        for operation in [PTPOperation.getDeviceInfo, .getStorageIDs, .getStorageInfo, .getObjectHandles, .getObjectInfo,
                          .getObject, .getPartialObject, .deleteObject, .sendObjectInfo, .sendObject] {
            #expect(info.operations.contains(operation.rawValue), "1.7.3 lists every operation FieldTapeKit sends")
        }
        #expect(!info.operations.contains(0x1019) && !info.operations.contains(0x101A), "no MoveObject or CopyObject")
    }

    @Test func oneStorageWithFreeSpace() async throws {
        let (device, _) = await populated()
        let session = session(device)
        #expect(try await session.storageIDs() == [0x0001_0001])
        let storage = try await session.storageInfo(0x0001_0001)
        #expect(storage.maxCapacity == 10_000)
        #expect(storage.freeSpaceInBytes == 10_000 - 1_000 - 2)
        await #expect(throws: MTPError.refused(.getStorageInfo, responseCode: 0x2008)) {
            try await session.storageInfo(0x0002_0001)
        }
    }

    @Test func listsFolderByFolder() async throws {
        let (device, handles) = await populated()
        let session = session(device)
        #expect(try await session.objectHandles(parent: PTPContainer.rootParent) == [handles.tapes, handles.mixdown])
        #expect(try await session.objectHandles(parent: handles.tapes) == [handles.tape])
        #expect(try await session.objectHandles(parent: handles.tape) == [handles.track, handles.json])
        #expect(try await session.objectHandles(parent: handles.mixdown) == [])
        #expect(try await session.objectHandles(parent: 0).count == 5, "parent 0 means every object")
    }

    @Test func refusesABadParent() async throws {
        let (device, handles) = await populated()
        let session = session(device)
        await #expect(throws: MTPError.refused(.getObjectHandles, responseCode: 0x2009)) {
            try await session.objectHandles(parent: 999)
        }
        await #expect(throws: MTPError.refused(.getObjectHandles, responseCode: 0x201A)) {
            try await session.objectHandles(parent: handles.track)
        }
    }

    @Test func objectInfoForFilesAndFolders() async throws {
        let (device, handles) = await populated()
        let session = session(device)

        let file = try await session.objectInfo(handles.track)
        #expect(file.filename == "track_1.wav")
        #expect(file.compressedSize == 1_000)
        #expect(file.parent == handles.tape)
        #expect(file.format == PTPObjectFormat.wav)
        #expect(!file.isFolder)

        let folder = try await session.objectInfo(handles.tapes)
        #expect(folder.isFolder)
        #expect(folder.parent == 0, "root-level objects have parent 0")
        await #expect(throws: MTPError.refused(.getObjectInfo, responseCode: 0x2009)) { try await session.objectInfo(999) }
    }

    @Test func readsWholeAndInRanges() async throws {
        let (device, handles) = await populated()
        let session = session(device)
        #expect(try await session.object(handles.track) == track)
        #expect(try await session.partialObject(handles.track, offset: 100, maxLength: 50) == track[100..<150])
        #expect(try await session.partialObject(handles.track, offset: 990, maxLength: 50) == track[990..<1_000],
                "fewer bytes come back at the end of the file")
        #expect(try await session.partialObject(handles.track, offset: 2_000, maxLength: 50).isEmpty)
    }

    /// DeleteObject arrived in step 8. Sending files arrives in step 9.
    @Test(arguments: [PTPOperation.sendObjectInfo, .sendObject])
    func refusesWritesForNow(operation: PTPOperation) async {
        await #expect(throws: MTPError.refused(operation, responseCode: 0x2005)) {
            try await session(SimulatedMTPDevice()).send(operation, [1])
        }
    }

    // MARK: Faults

    @Test func aRequestWithNoAnswerIsATimeoutWhenThePingAnswers() async throws {
        let (device, handles) = await populated(faults: [.noAnswer(request: 1)])
        let session = session(device)
        await #expect(throws: MTPError.timedOut(.getObject)) { try await session.object(handles.track) }
        #expect(try await session.object(handles.track) == track)
    }

    @Test func aSilentDeviceIsDisconnected() async throws {
        let (device, handles) = await populated(faults: [.silent(fromRequest: 2)])
        let session = session(device)
        #expect(try await session.object(handles.json) == Data("{}".utf8))
        await #expect(throws: MTPError.disconnected) { try await session.object(handles.track) }
        #expect(await device.requestCount == 3, "the request, then one ping")
        await #expect(throws: MTPError.disconnected) { try await session.storageIDs() }
        #expect(await device.requestCount == 3)
    }

    @Test func aSessionNotOpenRefusalIsReportedAsIs() async {
        let device = SimulatedMTPDevice(faults: [.refuse(request: 1, responseCode: 0x2003)])
        await #expect(throws: MTPError.refused(.getStorageIDs, responseCode: 0x2003)) {
            try await session(device).storageIDs()
        }
        #expect(await device.requestCount == 1, "no OpenSession follows")
    }
}
