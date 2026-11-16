import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct DeletingTapeTests {
    static let name = "2026-220#02"

    /// 2026-220#02, Vintage, with tracks 1 and 3, and a tape that isn't sound.
    static func device(_ faults: [SimulatedMTPDevice.Fault] = []) -> (FieldDevice, SimulatedMTPDevice) {
        let header = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.trackFormat, dataBytes: 0)
        let contents: [PendingNode] = [
            SimulatedTape(name, type: .vintage, seconds: [0.5, 0, 0.25]).node,
            .folder("tapes", [.folder("broken", (1...4).map { .file("track_\($0).wav", .data(header)) })]),
        ]
        let simulator = SimulatedMTPDevice(faults: faults, contents: SimulatedNode.merge(contents, into: SimulatedNode.layout173, path: []))
        return (FieldDevice.simulated(simulator), simulator)
    }

    static func tape(_ device: FieldDevice, _ name: String = Self.name) async throws -> Tape {
        try #require(try await device.tape(named: TapeName(listed: name)))
    }

    static func names(_ device: FieldDevice) async throws -> [String] {
        try await device.contentsOfDirectory(at: .op1Tapes).map(\.name).sorted()
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DeletingTapeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Changes the last byte of track 1, keeping its size, as recording over it on the OP-1 would.
    static func recordOver(_ simulator: SimulatedMTPDevice, in tape: String = Self.name) async throws {
        var data = try #require(await simulator.stored("track_1.wav", in: tape))
        data[data.index(before: data.endIndex)] ^= 0xFF
        await simulator.overwrite("track_1.wav", in: tape, with: data)
    }

    static let filesThenFolder = ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json", name]

    // MARK: moveTape

    @Test func moveArchivesThenDeletesFilesThenFolder() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await Self.tape(device)
        let parent = ProgressManager(totalCount: 1)
        let archive = try await device.moveTape(before, to: folder, progress: parent.subprogress(assigningCount: 1))
        #expect(archive.name == before.name && archive.tracks.map(\.size) == before.tracks.map(\.size))
        #expect(try ReelArchive(contentsOf: archive.url).tracks == archive.tracks, "the archive is on disk")
        #expect(try await Self.names(device) == ["broken"])
        #expect(await simulator.deleted == Self.filesThenFolder)
        #expect(parent.fractionCompleted == 1)
    }

    @Test func moveKeepsATapeThatChangedAfterItWasArchived() async throws {
        // tape.json changes once the copy is done with it, before moveTape lists the tape again.
        let json = SimulatedTape.tapeJSON(type: .porta, frames: [22_050, 0, 11_025])
        let (device, simulator) = Self.device([.changeAfterReading(name: "tape.json", to: json, reads: 4)])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.moveTape(try await Self.tape(device), to: folder) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.path == "tapes/2026-220#02" && error?.changed == []
        }
        #expect(try await Self.names(device) == ["2026-220#02", "broken"])
        #expect(await simulator.deleted.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(kept == ["2026-220#02.reelarchive"], "the archive is kept: \(kept)")
    }

    // MARK: deleteTape(_:keeping:)

    @Test func deletesKeepingAnArchive() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        let archive = try await device.copyTape(tape, to: folder)
        let parent = ProgressManager(totalCount: 1)
        try await device.deleteTape(tape, keeping: .archive(archive), progress: parent.subprogress(assigningCount: 1))
        #expect(try await Self.names(device) == ["broken"])
        #expect(await simulator.deleted == Self.filesThenFolder)
        #expect(parent.fractionCompleted == 1)
    }

    @Test func anArchiveOfAudioRecordedOverIsRefused() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try await device.copyTape(try await Self.tape(device), to: folder)
        // Same sizes and tape.json, different audio.
        try await Self.recordOver(simulator)
        let tape = try await Self.tape(device)
        #expect(tape.tracks.map(\.size) == archive.tracks.map(\.size) && tape.manifest == archive.manifest)
        await #expect { try await device.deleteTape(tape, keeping: .archive(archive)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == []
                && error?.reason == "the copy doesn't match it, so it wasn't deleted: track_1.wav holds different audio"
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func anArchiveOfADifferentLengthIsRefused() async throws {
        let other = FieldDevice.simulated { SimulatedTape(Self.name, type: .vintage, seconds: [0.25]) }
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try await other.copyTape(try await Self.tape(other), to: folder)
        let (device, simulator) = Self.device()
        await #expect { try await device.deleteTape(try await Self.tape(device), keeping: .archive(archive)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed
                && error?.reason == "the copy doesn't match it, so it wasn't deleted: the archive's track sizes or tape.json are different"
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func anArchiveChangedOnDiskIsRefused() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        let archive = try await device.copyTape(tape, to: folder)
        // An archive of the same tape recorded over, at the same sizes, takes its place on disk.
        let (other, otherSimulator) = Self.device()
        try await Self.recordOver(otherSimulator)
        let otherFolder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: otherFolder) }
        let replacement = try await other.copyTape(try await Self.tape(other), to: otherFolder)
        try FileManager.default.removeItem(at: archive.url)
        try FileManager.default.copyItem(at: replacement.url, to: archive.url)

        await #expect { try await device.deleteTape(tape, keeping: .archive(archive)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .archiveMismatch && error?.changed == []
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aMissingArchiveIsRefused() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        let archive = try await device.copyTape(tape, to: folder)
        try FileManager.default.removeItem(at: archive.url)
        await #expect { try await device.deleteTape(tape, keeping: .archive(archive)) } throws: { $0 is FieldError }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func deletesKeepingADuplicate() async throws {
        let (device, simulator) = Self.device()
        let tape = try await Self.tape(device)
        let duplicate = try await device.duplicateTape(tape, as: TapeName("Copy"))
        let parent = ProgressManager(totalCount: 1)
        try await device.deleteTape(tape, keeping: .tape(duplicate), progress: parent.subprogress(assigningCount: 1))
        #expect(try await Self.names(device) == ["broken", "copy"])
        #expect(await simulator.deleted == Self.filesThenFolder)
        #expect(parent.fractionCompleted == 1)
    }

    @Test func aDuplicateRecordedOverIsRefused() async throws {
        let (device, simulator) = Self.device()
        let tape = try await Self.tape(device)
        _ = try await device.duplicateTape(tape, as: TapeName("Copy"))
        try await Self.recordOver(simulator, in: "copy")
        await #expect { try await device.deleteTape(tape, keeping: .tape(try await Self.tape(device, "copy"))) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.reason?.hasSuffix("track_1.wav holds different audio") == true
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aTapeIsntItsOwnCopy() async throws {
        let (device, simulator) = Self.device()
        let tape = try await Self.tape(device)
        await #expect { try await device.deleteTape(tape, keeping: .tape(tape)) } throws: { ($0 as? FieldError)?.code == .notAllowed }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aTapeThatIsntSoundNeedsAPerson() async throws {
        let (device, simulator) = Self.device()
        let broken = try await Self.tape(device, "broken")
        await #expect { try await device.deleteTape(broken, keeping: .tape(try await Self.tape(device))) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.path == "tapes/broken"
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aTapeThatChangesWhileItsCheckedIsKept() async throws {
        // track_3 changes right after it's read for its SHA-256, to another size.
        let (device, simulator) = Self.device([.changeAfterReading(name: "track_3.wav", to: Data(count: 100))])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        let other = FieldDevice.simulated { SimulatedTape(Self.name, type: .vintage, seconds: [0.5, 0, 0.25]) }
        let archive = try await other.copyTape(try await Self.tape(other), to: folder)
        await #expect { try await device.deleteTape(tape, keeping: .archive(archive)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.reason == "it changed on the OP-1 while it was checked, so it wasn't deleted"
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aDeleteThatFailsPartWayListsWhatWent() async throws {
        let (device, _) = Self.device([.refuseDeleting(name: "track_3.wav", responseCode: PTPResponseCode.generalError)])
        let tape = try await Self.tape(device)
        let duplicate = try await device.duplicateTape(tape, as: TapeName("Copy"))
        await #expect { try await device.deleteTape(tape, keeping: .tape(duplicate)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .deviceRefused && error?.path == "tapes/2026-220#02/track_3.wav"
                && error?.changed == ["tapes/2026-220#02/track_1.wav", "tapes/2026-220#02/track_2.wav"]
        }
    }

    @Test func cancellingChangesNothing() async throws {
        let (device, simulator) = Self.device()
        let tape = try await Self.tape(device)
        let duplicate = try await device.duplicateTape(tape, as: TapeName("Copy"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await device.deleteTape(tape, keeping: .tape(duplicate))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await simulator.deleted.isEmpty)
    }

    // MARK: Confirmed by a person

    @Test func aConfirmationDescribesTheTape() async throws {
        let (device, _) = Self.device()
        let deletion = try await device.prepareToDelete(try await Self.tape(device))
        #expect(deletion.tape.name.string == Self.name && deletion.clipCount == 2)
        #expect(deletion.audio == .milliseconds(500) && !deletion.losesNothing)
        #expect(deletion.contents.map(\.name) == ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"])
        let blank = try await device.prepareToDelete(try await device.createTape(named: TapeName("Blank")))
        #expect(blank.losesNothing && blank.audio == .zero && blank.clipCount == 0)
        let broken = try await device.prepareToDelete(try await Self.tape(device, "broken"))
        #expect(!broken.losesNothing, "a tape that isn't sound always needs the prompt")
    }

    @Test func deletesWhatWasConfirmed() async throws {
        let (device, simulator) = Self.device()
        let deletion = try await device.prepareToDelete(try await Self.tape(device))
        try await device.deleteTape(deletion)
        #expect(try await Self.names(device) == ["broken"])
        #expect(await simulator.deleted == Self.filesThenFolder)
    }

    @Test func aTapeThatIsntSoundCanBeConfirmed() async throws {
        let (device, simulator) = Self.device()
        try await device.deleteTape(try await device.prepareToDelete(try await Self.tape(device, "broken")))
        #expect(try await Self.names(device) == ["2026-220#02"])
        #expect(await simulator.deleted.last == "broken")
    }

    @Test func aConfirmationWorksOnce() async throws {
        let (device, _) = Self.device()
        let deletion = try await device.prepareToDelete(try await Self.tape(device))
        try await device.deleteTape(deletion)
        await #expect { try await device.deleteTape(deletion) } throws: { ($0 as? FieldError)?.code == .confirmationAlreadyUsed }
    }

    @Test func aConfirmationOfAudioRecordedOverIsStale() async throws {
        let (device, simulator) = Self.device()
        let deletion = try await device.prepareToDelete(try await Self.tape(device))
        // A changed tape.json: the confirmation's fingerprint is the track sizes and tape.json.
        await simulator.overwrite("tape.json", in: Self.name, with: SimulatedTape.tapeJSON(type: .porta, frames: [22_050, 0, 11_025]))
        await #expect { try await device.deleteTape(deletion) } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aConfirmationFromAnotherConnectionIsRefused() async throws {
        let (first, _) = Self.device()
        let (second, simulator) = Self.device()
        let deletion = try await first.prepareToDelete(try await Self.tape(first))
        await #expect { try await second.deleteTape(deletion) } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
        #expect(await simulator.deleted.isEmpty)
    }
}
