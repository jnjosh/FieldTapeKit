import CryptoKit
import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct CopyingTapeTests {
    /// 2026-220#02, Vintage, with tracks 1 and 3; and a tape that isn't sound.
    static func device(_ faults: [SimulatedMTPDevice.Fault] = []) -> (FieldDevice, SimulatedMTPDevice) {
        let header = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.trackFormat, dataBytes: 0)
        let contents: [PendingNode] = [
            SimulatedTape("2026-220#02", type: .vintage, seconds: [0.5, 0, 0.25]).node,
            .folder("tapes", [.folder("broken", (1...4).map { .file("track_\($0).wav", .data(header)) })]),
        ]
        let simulator = SimulatedMTPDevice(faults: faults, contents: SimulatedNode.merge(contents, into: SimulatedNode.layout173, path: []))
        return (FieldDevice.simulated(simulator), simulator)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CopyingTapeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    static func tape(_ device: FieldDevice, _ name: String = "2026-220#02") async throws -> Tape {
        try #require(try await device.tape(named: TapeName(name)))
    }

    @Test(arguments: [ReelArchive.Compression.none, .lzfse])
    func copiesATapeOff(compression: ReelArchive.Compression) async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)

        let archive = try await device.copyTape(tape, to: folder, compression: compression)
        #expect(archive.url.lastPathComponent == "2026-220#02.reelarchive")
        #expect(try Self.listing(folder) == ["2026-220#02.reelarchive"], "nothing else is left in the folder")
        #expect(archive.name == tape.name && archive.type == .vintage)
        #expect(archive.serialNumber == "SIMULATED" && archive.firmware == "1.7.3" && archive.model == "OP-1")
        #expect(archive.manifest == tape.manifest)
        for track in tape.tracks {
            let data = try await device.contents(of: track.path, maximumSize: 1 << 30)
            #expect(archive.tracks[track.number - 1].sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        // It opens again, and the OP-1 wasn't touched.
        #expect(try ReelArchive(contentsOf: archive.url).tracks == archive.tracks)
        #expect(await simulator.deleted.isEmpty)
        #expect(try await Self.tape(device) == tape)
    }

    @Test func neverWritesOverAnArchive() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        _ = try await device.copyTape(tape, to: folder)
        let second = try await device.copyTape(tape, to: folder)
        #expect(second.url.lastPathComponent == "2026-220#02 2.reelarchive")
        #expect(try Self.listing(folder) == ["2026-220#02 2.reelarchive", "2026-220#02.reelarchive"])
    }

    @Test func copiesTheTapeAsItIsNow() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let listed = try await Self.tape(device)
        // The tape changes after it was listed, before the copy: the copy is of the tape as it is now.
        let json = try #require(try await device.locate("tapes/2026-220#02/tape.json"))
        let newer = SimulatedTape.tapeJSON(type: .porta, frames: [22_050, 0, 11_025, 0])
        await simulator.replace(json.handle, with: newer)
        let archive = try await device.copyTape(listed, to: folder)
        #expect(archive.type == .porta)
        #expect(archive.manifest.data == newer)
    }

    @Test func refusesATapeThatIsntSound() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copyTape(try await Self.tape(device, "broken"), to: folder) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.path == "tapes/broken"
                && error?.errorDescription == "FieldTapeKit won't do that with tapes/broken, because it isn't a sound tape: missing tape.json."
        }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func aTapeThatsGoneIsNotFound() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        try await device.removeItem(try await device.prepareToRemove(at: tape.path))
        await #expect { try await device.copyTape(tape, to: folder) } throws: { ($0 as? FieldError)?.code == .notFound }
    }

    @Test(arguments: [
        ("track_1.wav", "it changed on the OP-1 while it was being copied: its files or tape.json changed while it was copied"),
        // Caught as the copy reads it: the test's listing and copyTape's own each read tape.json first.
        ("tape.json", "it changed on the OP-1 while it was being copied: tape.json isn't what it was a moment ago"),
    ])
    func refusesATapeThatChangesWhileItsCopied(file: String, reason: String) async throws {
        let changed = file == "tape.json" ? SimulatedTape.tapeJSON(type: .studio, frames: [22_050, 0, 11_025, 0])
            : WAVHeader.bytes(format: FirmwareProfile.v1_7_3.trackFormat, dataBytes: 8) + Data(count: 8)
        let (device, _) = Self.device([.changeAfterReading(name: file, to: changed, reads: file == "tape.json" ? 2 : 1)])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copyTape(try await Self.tape(device), to: folder) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.reason == reason && error?.path == "tapes/2026-220#02"
        }
        #expect(try Self.listing(folder).isEmpty, "the half-made archive is deleted")
    }

    @Test func aShortReadIsRefused() async throws {
        let (device, _) = Self.device([.shortRead(name: "track_3.wav")])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copyTape(try await Self.tape(device), to: folder) } throws: { error in
            (error as? FieldError)?.reason == "it changed on the OP-1 while it was being copied: track_3.wav read as 88243 bytes, not the 88244 listed"
        }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func cancellingLeavesNothing() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tape = try await Self.tape(device)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.copyTape(tape, to: folder)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func reportsProgressByBytes() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = ProgressManager(totalCount: 1)
        _ = try await device.copyTape(try await Self.tape(device), to: folder, progress: parent.subprogress(assigningCount: 1))
        #expect(parent.fractionCompleted == 1)
    }

    @Test func aMissingFolderIsALocalFailure() async throws {
        let (device, _) = Self.device()
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID())")
        await #expect { try await device.copyTape(try await Self.tape(device), to: missing) } throws: {
            ($0 as? FieldError)?.code == .localFileFailed
        }
    }
}
