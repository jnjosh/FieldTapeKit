import Foundation
import System
import Testing
@testable import FieldTapeKit

/// Replacing a file: a verified copy or a person's confirmation first, then delete, then send (ADR 0002, safety
/// rules 1 and 6). The OP-1 can't replace a file in place.
@Suite struct ReplacingTests {
    static let track = "tapes/2026-312#01/track_1.wav"
    /// The blank track in `WritingTests.device()`.
    static let blank = WAVHeader.bytes(format: WritingTests.profile.trackFormat, dataBytes: 0)

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ReplacingTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: With a copy

    @Test func copiesTheOldFileThenReplacesIt() async throws {
        let (device, simulator) = await WritingTests.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appending(path: "track_1.wav")
        let track = WritingTests.wav(frames: 300)

        let item = try await device.write(track, to: "Tapes/2026-312#01/TRACK_1.wav",
                                          options: UploadOptions(existing: .replace(keepingCopyAt: backup)))
        #expect(item.path == FilePath(Self.track))
        #expect(try Data(contentsOf: backup) == Self.blank)
        #expect(try await device.contents(of: item.path) == track)
        #expect(await simulator.deleted == ["track_1.wav"])
    }

    @Test func aTakenCopyURLChangesNothing() async throws {
        let (device, simulator) = await WritingTests.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appending(path: "track_1.wav")
        try Data("mine".utf8).write(to: backup)

        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track),
                                   options: UploadOptions(existing: .replace(keepingCopyAt: backup)))
        } throws: { error in
            let error = error as? FieldError
            return error?.code == .localFileFailed && error?.changed == []
        }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "mine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["track_1.wav"])
        #expect(await simulator.deleted.isEmpty)
        #expect(try await device.contents(of: FilePath(Self.track)) == Self.blank)
    }

    @Test func aFailedCopyChangesNothing() async throws {
        let (device, simulator) = await WritingTests.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track),
                                   options: UploadOptions(existing: .replace(keepingCopyAt: folder.appending(path: "missing/t.wav"))))
        } throws: { ($0 as? FieldError)?.code == .localFileFailed && ($0 as? FieldError)?.changed == [] }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func withNothingThereItWritesAndCopiesNothing() async throws {
        let (device, simulator) = await WritingTests.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appending(path: "track_2.wav")
        _ = try await device.write(WritingTests.wav(), to: "tapes/2026-312#01/track_2.wav",
                                   options: UploadOptions(existing: .replace(keepingCopyAt: backup)))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func theRulesAreCheckedBeforeTheCopy() async throws {
        let (device, simulator) = await WritingTests.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appending(path: "track_1.wav")
        await #expect {
            try await device.write(WritingTests.wav(WritingTests.profile.sideFormat), to: FilePath(Self.track),
                                   options: UploadOptions(existing: .replace(keepingCopyAt: backup)))
        } throws: { ($0 as? FieldError)?.code == .notAllowed }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(await simulator.deleted.isEmpty)
    }

    // MARK: Confirmed by a person

    @Test func replacesWhatWasConfirmedOnce() async throws {
        let (device, simulator) = await WritingTests.device()
        let deletion = try await device.prepareToRemove(at: FilePath(Self.track))
        let track = WritingTests.wav()
        _ = try await device.write(track, to: FilePath(Self.track), options: UploadOptions(existing: .replace(confirmed: deletion)))
        #expect(try await device.contents(of: FilePath(Self.track)) == track)
        #expect(await simulator.deleted == ["track_1.wav"])

        await #expect {
            try await device.write(WritingTests.wav(frames: 5), to: FilePath(Self.track),
                                   options: UploadOptions(existing: .replace(confirmed: deletion)))
        } throws: { ($0 as? FieldError)?.code == .confirmationAlreadyUsed }
        #expect(try await device.contents(of: FilePath(Self.track)) == track)
    }

    @Test func aStaleConfirmationIsRefused() async throws {
        let (device, simulator) = await WritingTests.device()
        let deletion = try await device.prepareToRemove(at: FilePath(Self.track))
        let located = try #require(try await device.locate(FilePath(Self.track)))
        await simulator.replace(located.handle, with: WritingTests.wav(frames: 2))

        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track), options: UploadOptions(existing: .replace(confirmed: deletion)))
        } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation && ($0 as? FieldError)?.changed == [] }
        #expect(await simulator.deleted.isEmpty)
        // It wasn't used, but it still doesn't match.
        await #expect { try await device.removeItem(deletion) } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
    }

    @Test func aConfirmationForWhatsGoneIsRefused() async throws {
        let (device, _) = await WritingTests.device()
        let deletion = try await device.prepareToRemove(at: FilePath(Self.track))
        try await device.removeItem(try await device.prepareToRemove(at: FilePath(Self.track)))
        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track), options: UploadOptions(existing: .replace(confirmed: deletion)))
        } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
        #expect(try await device.item(at: FilePath(Self.track)) == nil)
    }

    @Test func aConfirmationBelongsToItsPathAndConnection() async throws {
        let (device, simulator) = await WritingTests.device()
        let json = try await device.prepareToRemove(at: "tapes/2026-312#01/tape.json")
        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track), options: UploadOptions(existing: .replace(confirmed: json)))
        } throws: { error in
            (error as? FieldError)?.code == .notAllowed
                && (error as? FieldError)?.errorDescription?.hasSuffix("because the confirmation is for tapes/2026-312#01/tape.json.") == true
        }
        let deletion = try await device.prepareToRemove(at: FilePath(Self.track))
        await #expect {
            try await FieldDevice.simulated(simulator).write(WritingTests.wav(), to: FilePath(Self.track),
                                                             options: UploadOptions(existing: .replace(confirmed: deletion)))
        } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aFolderIsntReplaced() async throws {
        let (device, simulator) = await WritingTests.device()
        let user = try #require(try await device.locate("drum/user"))
        await simulator.addFolder("kick.wav", in: user.handle)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect {
            try await device.write(PresetWritingTests.wav(), to: "drum/user/kick.wav",
                                   options: UploadOptions(existing: .replace(keepingCopyAt: folder.appending(path: "kick.wav"))))
        } throws: { ($0 as? FieldError)?.code == .isADirectory }
        #expect(await simulator.deleted.isEmpty)
    }

    // MARK: After the delete

    @Test func aFailedSendAfterTheDeleteSaysThePathChanged() async throws {
        let (device, simulator) = await WritingTests.device([.refuseSendObject(responseCode: 0x2002)])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appending(path: "track_1.wav")
        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track),
                                   options: UploadOptions(existing: .replace(keepingCopyAt: backup)))
        } throws: { error in
            let error = error as? FieldError
            return error?.code == .deviceRefused && error?.changed == [FilePath(Self.track)]
        }
        // The old file, then the half-made one.
        #expect(await simulator.deleted == ["track_1.wav", "track_1.wav"])
        #expect(try Data(contentsOf: backup) == Self.blank)
    }

    @Test func aBadReadBackAfterTheDeleteIsDeletedAndSaysThePathChanged() async throws {
        let (device, simulator) = await WritingTests.device([.corruptStored(name: "track_1.wav")])
        let deletion = try await device.prepareToRemove(at: FilePath(Self.track))
        await #expect {
            try await device.write(WritingTests.wav(), to: FilePath(Self.track), options: UploadOptions(existing: .replace(confirmed: deletion)))
        } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == [FilePath(Self.track)]
        }
        #expect(await simulator.deleted == ["track_1.wav", "track_1.wav"])
        #expect(try await device.item(at: FilePath(Self.track)) == nil)
    }

    @Test func cancellingBeforeTheDeleteChangesNothing() async throws {
        let (device, simulator) = await WritingTests.device()
        let deletion = try await device.prepareToRemove(at: FilePath(Self.track))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.write(WritingTests.wav(), to: FilePath(Self.track),
                                          options: UploadOptions(existing: .replace(confirmed: deletion)))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await simulator.deleted.isEmpty)
        // Not used, so it still works.
        _ = try await device.write(WritingTests.wav(), to: FilePath(Self.track), options: UploadOptions(existing: .replace(confirmed: deletion)))
    }

    @Test func aPresetIsReplacedToo() async throws {
        let (device, simulator) = PresetWritingTests.device()
        _ = try await device.write(PresetWritingTests.wav(frames: 10), to: "drum/user/kick.wav")
        let deletion = try await device.prepareToRemove(at: "drum/user/kick.wav")
        let item = try await device.write(PresetWritingTests.wav(frames: 20), to: "drum/user/kick.wav",
                                          options: UploadOptions(existing: .replace(confirmed: deletion)))
        #expect(try PCMAudio(try await device.contents(of: item.path)).frames == 20)
        #expect(await simulator.deleted == ["kick.wav"])
    }
}
