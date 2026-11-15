import Foundation
import System
import Testing
@testable import FieldTapeKit

/// ADR 0002's safety rules 1, 4 and 6, first tested here: nothing goes without a verified copy or a person's
/// confirmation, nothing that belongs to the OP-1 goes, and a failure stops and says what changed.
@Suite struct RemovingTests {
    /// A tape with a subfolder, a file in it, and album side A.
    static func simulator() async -> (SimulatedMTPDevice, sideA: UInt32) {
        let simulator = SimulatedMTPDevice()
        let tapes = await simulator.addFolder("tapes")
        let tape = await simulator.addFolder("2026-220#02", in: tapes)
        await simulator.addFile("tape.json", data: Data("{}".utf8), format: PTPObjectFormat.text, in: tape)
        await simulator.addFile("readme.txt", data: Data("allowed".utf8), format: PTPObjectFormat.undefined, in: tape)
        await simulator.addFile("track_1.wav", data: Data(count: 100), in: tape)
        let extra = await simulator.addFolder("extra", in: tape)
        await simulator.addFile("inside.wav", data: Data(count: 10), in: extra)
        await simulator.addFolder("empty", in: tapes)
        let mixdown = await simulator.addFolder("mixdown")
        let side = await simulator.addFile("side_a.wav", data: Data(repeating: 7, count: 1_000), in: mixdown)
        await simulator.addFile("readme.txt", data: Data("rules".utf8), format: PTPObjectFormat.undefined, in: mixdown)
        return (simulator, side)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "RemovingTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: With a copy

    @Test func copiesVerifiesThenDeletes() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let copy = try await device.removeItem(at: "Mixdown/SIDE_A.WAV", keepingCopyAt: folder.appending(path: "side_a.wav"))
        #expect(try Data(contentsOf: copy) == Data(repeating: 7, count: 1_000))
        #expect(try await device.item(at: "mixdown/side_a.wav") == nil)
        #expect(await simulator.deleted == ["side_a.wav"])
    }

    @Test func aCopyNeverOverwritesALocalFile() async throws {
        let (simulator, _) = await Self.simulator()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = folder.appending(path: "side_a.wav")
        try Data("mine".utf8).write(to: backup)

        let copy = try await FieldDevice.simulated(simulator).removeItem(at: "mixdown/side_a.wav", keepingCopyAt: backup)
        #expect(copy.lastPathComponent == "side_a 2.wav")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "mine")
    }

    @Test func aFailedCopyDeletesNothing() async throws {
        let (simulator, _) = await Self.simulator()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect {
            try await FieldDevice.simulated(simulator).removeItem(at: "mixdown/side_a.wav",
                                                                  keepingCopyAt: folder.appending(path: "missing/side_a.wav"))
        } throws: { error in
            (error as? FieldError)?.code == .localFileFailed && (error as? FieldError)?.changed == []
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aFolderNeedsAConfirmation() async throws {
        let (simulator, _) = await Self.simulator()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect {
            try await FieldDevice.simulated(simulator).removeItem(at: "tapes/2026-220#02", keepingCopyAt: folder)
        } throws: { ($0 as? FieldError)?.code == .isADirectory }
        #expect(await simulator.deleted.isEmpty)
    }

    // MARK: What belongs to the OP-1

    @Test(arguments: ["", "/", "tapes", "TAPES", "mixdown", "synth", "drum/user", "synth/slots/3",
                      "mixdown/readme.txt", "tapes/2026-220#02/readme.txt", "synth/you may create folders here"])
    func refusesWhatBelongsToTheOP1(path: String) async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let isOwned = { (error: any Error) in
            (error as? FieldError)?.code == .notAllowed && (error as? FieldError)?.path == FilePath(path)
        }
        await #expect { try await device.prepareToRemove(at: FilePath(path)) } throws: { isOwned($0) }
        await #expect { try await device.removeItem(at: FilePath(path), keepingCopyAt: folder.appending(path: "x")) } throws: {
            isOwned($0)
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func explainsWhyItRefuses() {
        #expect(FieldError(.notAllowed, path: "mixdown/readme.txt").errorDescription
                == "FieldTapeKit won't do that with mixdown/readme.txt, because it belongs to the OP-1.")
    }

    // MARK: Confirmed by a person

    @Test func describesAFileAndDeletesItOnce() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "mixdown/side_a.wav")
        #expect(deletion.item.path == "mixdown/side_a.wav")
        #expect(deletion.size == 1_000)
        #expect(deletion.contents.isEmpty)
        #expect(!deletion.losesNothing)

        try await device.removeItem(deletion)
        #expect(try await device.item(at: "mixdown/side_a.wav") == nil)
        await #expect { try await device.removeItem(deletion) } throws: { error in
            let error = error as? FieldError
            return error?.code == .confirmationAlreadyUsed && error?.changed == []
        }
    }

    @Test func aConfirmationBelongsToItsConnection() async throws {
        let (simulator, _) = await Self.simulator()
        let deletion = try await FieldDevice.simulated(simulator).prepareToRemove(at: "mixdown/side_a.wav")
        // A reconnect makes a new FieldDevice.
        await #expect { try await FieldDevice.simulated(simulator).removeItem(deletion) } throws: {
            ($0 as? FieldError)?.code == .changedSinceConfirmation
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aFileThatChangedSizeIsRefused() async throws {
        let (simulator, side) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "mixdown/side_a.wav")
        await simulator.replace(side, with: Data(count: 2_000))
        await #expect { try await device.removeItem(deletion) } throws: { error in
            let error = error as? FieldError
            return error?.code == .changedSinceConfirmation
                && error?.errorDescription == "mixdown/side_a.wav changed on the OP-1 since it was confirmed, so nothing was deleted."
        }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aFolderThatGainedAFileIsRefused() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "tapes/2026-220#02")
        let tape = try #require(try await device.locate("tapes/2026-220#02"))
        await simulator.addFile("track_2.wav", data: Data(count: 44), in: tape.handle)
        await #expect { try await device.removeItem(deletion) } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func somethingAlreadyGoneIsRefused() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "mixdown/side_a.wav")
        try await device.removeItem(try await device.prepareToRemove(at: "mixdown/side_a.wav"))
        await #expect { try await device.removeItem(deletion) } throws: { ($0 as? FieldError)?.code == .changedSinceConfirmation }
    }

    @Test func deletesAFoldersContentsDeepestFirstThenTheFolder() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "tapes/2026-220#02")
        #expect(deletion.contents.map(\.path) == ["tapes/2026-220#02/tape.json", "tapes/2026-220#02/readme.txt",
                                                  "tapes/2026-220#02/track_1.wav", "tapes/2026-220#02/extra",
                                                  "tapes/2026-220#02/extra/inside.wav"])
        #expect(deletion.size == 2 + 7 + 100 + 10)

        try await device.removeItem(deletion)
        // The OP-1's own readme.txt goes with its tape.
        #expect(await simulator.deleted == ["inside.wav", "tape.json", "readme.txt", "track_1.wav", "extra", "2026-220#02"])
        #expect(try await device.contentsOfDirectory(at: .op1Tapes).map(\.name) == ["empty"])
    }

    @Test func anEmptyFolderLosesNothing() async throws {
        let (simulator, _) = await Self.simulator()
        let deletion = try await FieldDevice.simulated(simulator).prepareToRemove(at: "tapes/empty")
        #expect(deletion.losesNothing)
        #expect(deletion.size == 0)
    }

    @Test func stopsAtTheFirstFailureAndSaysWhatChanged() async throws {
        let (simulator, _) = await Self.simulator()
        await simulator.add(faults: [.refuseDeleting(name: "readme.txt", responseCode: PTPResponseCode.generalError)])
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "tapes/2026-220#02")

        await #expect { try await device.removeItem(deletion) } throws: { error in
            let error = error as? FieldError
            return error?.code == .deviceRefused && error?.responseCode == 0x2002
                && error?.path == "tapes/2026-220#02/readme.txt"
                && error?.changed == ["tapes/2026-220#02/extra/inside.wav", "tapes/2026-220#02/tape.json"]
        }
        #expect(await simulator.deleted == ["inside.wav", "tape.json"])
        // It was used, so it can't be tried again.
        await #expect { try await device.removeItem(deletion) } throws: { ($0 as? FieldError)?.code == .confirmationAlreadyUsed }
    }

    @Test func cancellingFirstDeletesNothingAndKeepsTheConfirmation() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let deletion = try await device.prepareToRemove(at: "mixdown/side_a.wav")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await device.removeItem(deletion)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await simulator.deleted.isEmpty)
        try await device.removeItem(deletion)
        #expect(await simulator.deleted == ["side_a.wav"])
    }

    // MARK: The simulator

    /// `delete.folder-with-files`: on 1.7.3, one DeleteObject on a folder deletes it and what's in it.
    @Test func theSimulatorDeletesAFolderWithItsFiles() async throws {
        let (simulator, _) = await Self.simulator()
        let device = FieldDevice.simulated(simulator)
        let tape = try #require(try await device.locate("tapes/2026-220#02"))
        try await device.session.deleteObject(tape.handle)
        #expect(try await !device.fileExists(at: "tapes/2026-220#02"))
        // Everything under it, the folder inside it too, then the folder itself.
        #expect(Set(await simulator.deleted) == ["2026-220#02", "tape.json", "readme.txt", "track_1.wav", "extra", "inside.wav"])
        #expect(await simulator.deleted.last == "2026-220#02")
    }
}
