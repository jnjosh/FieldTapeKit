import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct RestoringTapeTests {
    /// 2026-220#02, Vintage, with tracks 1 and 3, and `extra` more blank tapes.
    static func device(_ faults: [SimulatedMTPDevice.Fault] = [], extra: Int = 0,
                       name: String = "2026-220#02") -> (FieldDevice, SimulatedMTPDevice) {
        let contents = [SimulatedTape(name, type: .vintage, seconds: [0.5, 0, 0.25]).node]
            + (0..<extra).map { SimulatedTape("spare \($0)").node }
        let simulator = SimulatedMTPDevice(faults: faults, contents: SimulatedNode.merge(contents, into: SimulatedNode.layout173, path: []))
        return (FieldDevice.simulated(simulator), simulator)
    }

    /// An archive of a device's only tape, in a new folder, and the folder.
    static func archive(of device: FieldDevice) async throws -> (ReelArchive, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RestoringTapeTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tape = try #require(try await device.tapes().first)
        return (try await device.copyTape(tape, to: folder), folder)
    }

    static func names(_ device: FieldDevice) async throws -> [String] {
        try await device.contentsOfDirectory(at: .op1Tapes).map(\.name).sorted()
    }

    static let order = ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"]

    @Test func restoresUnderTheArchivedName() async throws {
        let (source, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device(name: "other")
        let parent = ProgressManager(totalCount: 1)
        let tape = try await device.restoreTape(from: archive, progress: parent.subprogress(assigningCount: 1))
        #expect(tape.name == archive.name && tape.path == "tapes/2026-220#02")
        #expect(tape.isSound && tape.manifest == archive.manifest && tape.type == .vintage)
        #expect(tape.tracks.map(\.size) == archive.tracks.map(\.size))
        for number in 1...4 {
            #expect(await simulator.stored("track_\(number).wav", in: "2026-220#02") == (try archive.trackData(number)))
        }
        #expect(await simulator.stored("tape.json", in: "2026-220#02") == archive.manifest.data)
        #expect(await simulator.sentNames == ["2026-220#02"] + Self.order, "tracks first, tape.json last")
        #expect(parent.fractionCompleted == 1)
    }

    @Test func restoresUnderANewName() async throws {
        let (device, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: device)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await device.restoreTape(from: archive, as: TapeName("Restored"))
        #expect(tape.path == "tapes/restored" && tape.manifest == archive.manifest)
        #expect(try await Self.names(device) == ["2026-220#02", "restored"])
    }

    @Test func aTakenNameChangesNothing() async throws {
        let (device, simulator) = Self.device()
        let (archive, folder) = try await Self.archive(of: device)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.restoreTape(from: archive, as: TapeName("2026-220#02".uppercased())) } throws: { error in
            let error = error as? FieldError
            return error?.code == .alreadyExists && error?.path == "tapes/2026-220#02" && error?.changed == []
        }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func aFullSetOfSlotsChangesNothing() async throws {
        let (source, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device(extra: 7, name: "other")
        await #expect { try await device.restoreTape(from: archive) } throws: { ($0 as? FieldError)?.code == .tapeLimitReached }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func anArchivedNameTheFirmwareWouldCutIsRefused() async throws {
        let (source, _) = Self.device(name: "fieldck #2-13")
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device(name: "other")
        await #expect { try await device.restoreTape(from: archive) } throws: { error in
            let error = error as? FieldError
            return error?.code == .invalidName
                && error?.reason == "it's longer than 12 characters, so restore it under another name"
        }
        #expect(await simulator.sentNames.isEmpty)
        // Under a name the firmware keeps, it's restored.
        #expect(try await device.restoreTape(from: archive, as: TapeName("fieldck #2-1")).isSound)
    }

    @Test func aFailedWriteRemovesTheHalfMadeTape() async throws {
        let (source, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = Self.device([.corruptStored(name: "track_3.wav")], name: "other")
        await #expect { try await device.restoreTape(from: archive) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.path == "tapes/2026-220#02/track_3.wav" && error?.changed == []
        }
        #expect(try await Self.names(device) == ["other"])
    }

    @Test func aCleanupThatFailsIsReportedInChanged() async throws {
        let (source, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = Self.device([.corruptStored(name: "tape.json"),
                                       .refuseDeleting(name: "track_1.wav", responseCode: PTPResponseCode.generalError)], name: "other")
        await #expect { try await device.restoreTape(from: archive) } throws: { ($0 as? FieldError)?.changed == ["tapes/2026-220#02"] }
        #expect(try await Self.names(device) == ["2026-220#02", "other"])
    }

    @Test func anArchiveChangedSinceItWasOpenedIsRefused() async throws {
        let (source, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        // An archive of a different tape takes its place on disk.
        let other = FieldDevice.simulated { SimulatedTape("2026-220#02", type: .vintage, seconds: [0.25, 0, 0.25]) }
        let (replacement, replacementFolder) = try await Self.archive(of: other)
        defer { try? FileManager.default.removeItem(at: replacementFolder) }
        try FileManager.default.removeItem(at: archive.url)
        try FileManager.default.copyItem(at: replacement.url, to: archive.url)

        let (device, _) = Self.device(name: "other")
        await #expect { try await device.restoreTape(from: archive) } throws: { error in
            let error = error as? FieldError
            return error?.code == .archiveMismatch && error?.changed == []
        }
        #expect(try await Self.names(device) == ["other"])
    }

    @Test func cancellingChangesNothing() async throws {
        let (source, _) = Self.device()
        let (archive, folder) = try await Self.archive(of: source)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = Self.device(name: "other")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.restoreTape(from: archive)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await Self.names(device) == ["other"])
    }

    // MARK: Over an existing tape

    /// An archive of 2026-220#02 with different audio: Studio, tracks 1 and 2. Track 4 is blank in it and on the
    /// default device, so a replace leaves it as it is.
    static func otherArchive() async throws -> (ReelArchive, URL) {
        try await archive(of: FieldDevice.simulated { SimulatedTape("2026-220#02", seconds: [0.25, 0.5]) })
    }

    static let replaced = ["track_1.wav", "track_2.wav", "track_3.wav", "tape.json"]

    static func expectHolds(_ archive: ReelArchive, _ simulator: SimulatedMTPDevice, in folder: String = "2026-220#02") async throws {
        for number in 1...4 {
            #expect(await simulator.stored("track_\(number).wav", in: folder) == (try archive.trackData(number)), "track_\(number)")
        }
        #expect(await simulator.stored("tape.json", in: folder) == archive.manifest.data)
    }

    @Test func replacesArchivingTheExistingTapeFirst() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device()
        let original = try #require(try await device.tapes().first)
        let backup = folder.appending(path: "before.reelarchive")
        let parent = ProgressManager(totalCount: 1)
        let tape = try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: backup),
                                                progress: parent.subprogress(assigningCount: 1))
        #expect(tape.path == "tapes/2026-220#02" && tape.manifest == archive.manifest && tape.type == .studio)
        try await Self.expectHolds(archive, simulator)
        let kept = try ReelArchive(contentsOf: backup)
        #expect(kept.manifest == original.manifest && kept.tracks.map(\.size) == original.tracks.map(\.size))
        #expect(await simulator.deleted == Self.replaced, "each old file deleted just before its new one, track_4 left")
        #expect(await simulator.sentNames == Self.replaced, "tracks first, tape.json last, and no new folder")
        #expect(parent.fractionCompleted == 1)
    }

    @Test func aTakenArchiveURLChangesNothing() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device()
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: archive.url)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .localFileFailed && error?.changed == []
        }
        #expect(await simulator.deleted.isEmpty)
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func archivingWithNoTapeThereRestoresANewTape() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, _) = Self.device(name: "other")
        let backup = folder.appending(path: "before.reelarchive")
        let tape = try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: backup))
        #expect(tape.path == "tapes/2026-220#02")
        #expect(!FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)), "there was nothing to archive")
    }

    @Test func aTapeThatChangedAfterItWasArchivedIsntReplaced() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        // tape.json changes once it's archived, before the tape is listed again.
        let json = SimulatedTape.tapeJSON(type: .porta, frames: [22_050, 0, 11_025])
        let (device, simulator) = Self.device([.changeAfterReading(name: "tape.json", to: json, reads: 4)])
        let backup = folder.appending(path: "before.reelarchive")
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: backup)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == []
        }
        #expect(await simulator.deleted.isEmpty)
        #expect(await simulator.sentNames.isEmpty)
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)), "the archive is kept")
    }

    @Test func replacesWhatAPersonConfirmed() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device()
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        let tape = try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion))
        #expect(tape.manifest == archive.manifest)
        try await Self.expectHolds(archive, simulator)
        #expect(await simulator.deleted == Self.replaced)
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            (error as? FieldError)?.code == .confirmationAlreadyUsed
        }
    }

    @Test func aStaleConfirmationChangesNothing() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device()
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        await simulator.overwrite("tape.json", in: "2026-220#02", with: SimulatedTape.tapeJSON(type: .porta, frames: [22_050, 0, 11_025]))
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .changedSinceConfirmation && error?.changed == []
        }
        #expect(await simulator.deleted.isEmpty)
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func aConfirmationForAnotherTapeIsRefused() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device(extra: 1)
        let deletion = try await device.prepareToDelete(try #require(try await device.tape(named: TapeName("spare 0"))))
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.reason == "the confirmation is for tapes/spare 0"
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aConfirmedTapeThatsGoneIsStale() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device()
        let tape = try #require(try await device.tapes().first)
        let deletion = try await device.prepareToDelete(tape)
        try await device.deleteTape(try await device.prepareToDelete(tape))
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            (error as? FieldError)?.code == .changedSinceConfirmation
        }
        #expect(await simulator.sentNames.isEmpty, "it isn't restored as a new tape")
    }

    @Test func aFolderWithOtherFilesIsntReplaced() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents: [PendingNode] = [
            SimulatedTape("2026-220#02", type: .vintage, seconds: [0.5, 0, 0.25]).node,
            .folder("tapes", [.folder("2026-220#02", [.file("notes.txt", .data(Data("mine".utf8)))])]),
        ]
        let simulator = SimulatedMTPDevice(contents: SimulatedNode.merge(contents, into: SimulatedNode.layout173, path: []))
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.reason == "its folder holds files a tape doesn't: notes.txt"
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func anArchiveChangedOnDiskChangesNothing() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (replacement, replacementFolder) = try await Self.archive(of: FieldDevice.simulated {
            SimulatedTape("2026-220#02", seconds: [0.5, 0.5])
        })
        defer { try? FileManager.default.removeItem(at: replacementFolder) }
        try FileManager.default.removeItem(at: archive.url)
        try FileManager.default.copyItem(at: replacement.url, to: archive.url)
        let (device, simulator) = Self.device()
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            (error as? FieldError)?.code == .archiveMismatch
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aFailurePartWayListsWhatChangedAndRollsNothingBack() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device([.corruptStored(name: "track_2.wav")])
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.path == "tapes/2026-220#02/track_2.wav"
                && error?.changed == ["tapes/2026-220#02/track_1.wav", "tapes/2026-220#02/track_2.wav"]
        }
        #expect(try await Self.names(device) == ["2026-220#02"], "the tape is left as it is, not deleted")
        #expect(await simulator.stored("track_1.wav", in: "2026-220#02") == (try archive.trackData(1)))
        #expect(await simulator.stored("track_2.wav", in: "2026-220#02") == nil, "a track that read back wrong is deleted")
    }

    @Test func aLongNameOnTheOP1IsKept() async throws {
        let (device, simulator) = Self.device(name: "fieldck #2-13")
        let (archive, folder) = try await Self.archive(of: FieldDevice.simulated { SimulatedTape("fieldck #2-13", seconds: [0.25]) })
        defer { try? FileManager.default.removeItem(at: folder) }
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        let tape = try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion))
        #expect(tape.path == "tapes/fieldck #2-13" && tape.manifest == archive.manifest)
        try await Self.expectHolds(archive, simulator, in: "fieldck #2-13")
    }

    @Test func cancellingBeforeTheFirstDeleteChangesNothing() async throws {
        let (archive, folder) = try await Self.otherArchive()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (device, simulator) = Self.device()
        let deletion = try await device.prepareToDelete(try #require(try await device.tapes().first))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await simulator.deleted.isEmpty)
        // The confirmation wasn't used.
        #expect(try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)).manifest == archive.manifest)
    }
}
