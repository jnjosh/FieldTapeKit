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
}
