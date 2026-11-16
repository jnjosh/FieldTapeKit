import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct RestoringSideTests {
    static let profile = FirmwareProfile.v1_7_3
    static let empty = WAVHeader.bytes(format: profile.sideFormat, dataBytes: 0)
    static let old = AlbumTests.side(seconds: 0.5, seed: 9)
    static let new = AlbumTests.side(seconds: 0.75, seed: 4)

    /// Side A empty, side B with 0.5 s of audio, with album writing let through, which 1.7.3 has off
    /// (`album.write-again`), so the code that writes sides can be tested.
    static func device(_ faults: [SimulatedMTPDevice.Fault] = []) async -> (FieldDevice, SimulatedMTPDevice) {
        let (device, simulator) = AlbumTests.device(a: empty, b: old, faults: faults)
        await device.overrideAlbumWrites(true)
        return (device, simulator)
    }

    /// A folder holding `new.wav`, the side to restore, or `data` if given.
    static func source(_ data: Data = new) throws -> (file: URL, folder: URL) {
        let folder = try AlbumTests.folder()
        let file = folder.appending(path: "new.wav")
        try data.write(to: file)
        return (file, folder)
    }

    static func contents(_ device: FieldDevice, _ side: Album.Side) async throws -> Data {
        try await device.contents(of: FilePath("mixdown/side_\(side.rawValue).wav"))
    }

    static func unchanged(_ simulator: SimulatedMTPDevice) async -> Bool {
        let deleted = await simulator.deleted
        let sent = await simulator.sentNames
        return deleted.isEmpty && sent.isEmpty
    }

    // MARK: Off on 1.7.3

    @Test func albumWritingIsOffOn173() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = AlbumTests.device(a: Self.empty, b: Self.old)
        for conflict in [SideConflict.fail, .replace(confirmed: try await device.prepareToReplace(.b))] {
            await #expect { try await device.restoreSide(.b, from: file, conflict: conflict) } throws: {
                ($0 as? FieldError)?.code == .notAllowed && ($0 as? FieldError)?.reason?.hasPrefix("album sides aren't written on this firmware") == true
            }
        }
        await #expect { try await device.write(Self.empty, to: "mixdown/side_a.wav") } throws: { ($0 as? FieldError)?.code == .notAllowed }
        #expect(await Self.unchanged(simulator))
    }

    // MARK: An empty side

    @Test func anEmptySideIsWrittenFreely() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        let parent = ProgressManager(totalCount: 1)

        let side = try await device.restoreSide(.a, from: file, progress: parent.subprogress(assigningCount: 1))
        #expect(side.side == .a && side.size == Self.new.count && side.isSound && side.duration == .milliseconds(750))
        #expect(try await Self.contents(device, .a) == Self.new)
        #expect(await simulator.deleted == ["side_a.wav"])
        #expect(await simulator.sentNames == ["side_a.wav"])
        #expect(parent.fractionCompleted == 1)
    }

    @Test func anEmptySideIsntCopied() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = await Self.device()
        let copy = folder.appending(path: "old side a.wav")
        _ = try await device.restoreSide(.a, from: file, conflict: .replace(copyingExistingTo: copy))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func aMissingSideIsWrittenNew() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = AlbumTests.device(mixdown: [])
        await device.overrideAlbumWrites(true)
        #expect(try await device.restoreSide(.b, from: file).size == Self.new.count)
        #expect(try await Self.contents(device, .b) == Self.new)
    }

    // MARK: A side with audio

    @Test func aSideWithAudioIsRefusedByDefault() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        await #expect { try await device.restoreSide(.b, from: file) } throws: {
            ($0 as? FieldError)?.code == .alreadyExists && ($0 as? FieldError)?.path == "mixdown/side_b.wav"
        }
        #expect(await Self.unchanged(simulator))
    }

    @Test func copiesTheSideFirst() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        let copy = folder.appending(path: "old side b.wav")

        let side = try await device.restoreSide(.b, from: file, conflict: .replace(copyingExistingTo: copy))
        #expect(try Data(contentsOf: copy) == Self.old)
        #expect(side.size == Self.new.count && side.isSound)
        #expect(try await Self.contents(device, .b) == Self.new)
        #expect(await simulator.deleted == ["side_b.wav"])
    }

    @Test func aTakenCopyURLChangesNothing() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        await #expect { try await device.restoreSide(.b, from: file, conflict: .replace(copyingExistingTo: file)) } throws: {
            ($0 as? FieldError)?.code == .localFileFailed
        }
        #expect(try Data(contentsOf: file) == Self.new)
        #expect(await Self.unchanged(simulator))
    }

    @Test func replacesAConfirmedSideOnce() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = await Self.device()
        let replacement = try await device.prepareToReplace(.b)
        #expect(!replacement.losesNothing && replacement.audio == .milliseconds(500))
        #expect(replacement.side == (try await device.album().b))

        _ = try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement))
        #expect(try await Self.contents(device, .b) == Self.new)
        await #expect { try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement)) } throws: {
            ($0 as? FieldError)?.code == .confirmationAlreadyUsed
        }
    }

    @Test func anEmptySideLosesNothing() async throws {
        let replacement = try await Self.device().0.prepareToReplace(.a)
        #expect(replacement.losesNothing && replacement.audio == .zero)
    }

    @Test func aSideChangedSinceConfirmationIsRefused() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        let replacement = try await device.prepareToReplace(.b)
        await simulator.overwrite("side_b.wav", in: "mixdown", with: AlbumTests.side(seconds: 1))
        await #expect { try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement)) } throws: {
            ($0 as? FieldError)?.code == .changedSinceConfirmation
        }
        #expect(await Self.unchanged(simulator))
    }

    @Test func aConfirmationForTheOtherSideIsRefused() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        let replacement = try await device.prepareToReplace(.a)
        await #expect { try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement)) } throws: {
            ($0 as? FieldError)?.code == .notAllowed && ($0 as? FieldError)?.reason == "the confirmation is for Side A"
        }
        #expect(await Self.unchanged(simulator))
    }

    @Test func aConfirmationFromAnotherConnectionIsRefused() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        let replacement = try await device.prepareToReplace(.b)
        let reconnected = FieldDevice.simulated(simulator)
        await reconnected.overrideAlbumWrites(true)
        await #expect { try await reconnected.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement)) } throws: {
            ($0 as? FieldError)?.code == .changedSinceConfirmation
        }
        #expect(await Self.unchanged(simulator))
    }

    @Test func cancellingBeforeTheDeleteLeavesTheConfirmationUsable() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        let replacement = try await device.prepareToReplace(.b)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await Self.unchanged(simulator))
        _ = try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement))
    }

    // MARK: The file

    @Test func anotherFormatIsRefusedFirst() async throws {
        let wide = WAVHeader.bytes(format: Self.profile.trackFormat, dataBytes: 800) + Data(count: 800)
        let (file, folder) = try Self.source(wide)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        // Refused for the format, before the side with audio is even looked at.
        await #expect { try await device.restoreSide(.b, from: file) } throws: { ($0 as? FieldError)?.code == .notAllowed }
        #expect(await Self.unchanged(simulator))
    }

    @Test func aWAVWithOtherChunksIsRefused() async throws {
        var chunked = Data("RIFF".utf8) + Data(count: 4) + Data("WAVELIST".utf8)
        chunked += Data([4, 0, 0, 0]) + Data("INFO".utf8) + Self.new.dropFirst(12)
        let (file, folder) = try Self.source(chunked)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        await #expect { try await device.restoreSide(.a, from: file) } throws: { ($0 as? FieldError)?.code == .notAllowed }
        #expect(await Self.unchanged(simulator))
    }

    @Test func aSideOverSixMinutesIsRefused() async throws {
        let bytes = (Self.profile.maximumSideFrames + 1) * Self.profile.sideFormat.frameBytes
        let long = WAVHeader.bytes(format: Self.profile.sideFormat, dataBytes: bytes) + Data(count: bytes)
        let (file, folder) = try Self.source(long)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device()
        await #expect { try await device.restoreSide(.a, from: file) } throws: { ($0 as? FieldError)?.code == .tapeTooLong }
        #expect(await Self.unchanged(simulator))
    }

    @Test func aMissingFileIsALocalFailure() async throws {
        let (device, simulator) = await Self.device()
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).wav")
        await #expect { try await device.restoreSide(.a, from: missing) } throws: { ($0 as? FieldError)?.code == .localFileFailed }
        #expect(await Self.unchanged(simulator))
    }

    // MARK: After a reconnect, in the simulator

    @Test func aDeletedSideComesBackAfterAReconnect() async throws {
        let (device, simulator) = await Self.device()
        try await device.removeItem(try await device.prepareToRemove(at: "mixdown/side_b.wav"))
        #expect(try await !device.fileExists(at: "mixdown/side_b.wav"))
        await simulator.leaveAndReenterMTPMode()
        #expect(try await Self.contents(FieldDevice.simulated(simulator), .b) == Self.old)
    }

    @Test func aWrittenSideLastsUnlessTheOP1KeepsItsOwn() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        for keepsItsOwn in [false, true] {
            let (device, simulator) = await Self.device(keepsItsOwn ? [.albumKeepsItsOwn] : [])
            _ = try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: try await device.prepareToReplace(.b)))
            await simulator.leaveAndReenterMTPMode()
            #expect(try await Self.contents(FieldDevice.simulated(simulator), .b) == (keepsItsOwn ? Self.old : Self.new))
        }
    }

    // MARK: Failing after the delete

    @Test func aRefusedSendStopsAndReportsTheSide() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = await Self.device([.refuseSendObject(responseCode: 0x2002)])
        let copy = folder.appending(path: "old side b.wav")
        await #expect { try await device.restoreSide(.b, from: file, conflict: .replace(copyingExistingTo: copy)) } throws: {
            ($0 as? FieldError)?.changed == ["mixdown/side_b.wav"]
        }
        // The copy covers the side, and nothing more was written.
        #expect(try Data(contentsOf: copy) == Self.old)
        // The old side, then the half-made new one the refused send left, as any failed send is cleaned up.
        #expect(await simulator.deleted == ["side_b.wav", "side_b.wav"])
        #expect(await simulator.sentNames == ["side_b.wav"])
        #expect(try await !device.fileExists(at: "mixdown/side_b.wav"))
    }

    @Test func aBadReadBackStopsAndReportsTheSide() async throws {
        let (file, folder) = try Self.source()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = await Self.device([.corruptStored(name: "side_b.wav")])
        let replacement = try await device.prepareToReplace(.b)
        await #expect { try await device.restoreSide(.b, from: file, conflict: .replace(confirmed: replacement)) } throws: {
            ($0 as? FieldError)?.code == .verificationFailed && ($0 as? FieldError)?.changed == ["mixdown/side_b.wav"]
        }
    }
}
