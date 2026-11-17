import Foundation
import System
import Testing
@testable import FieldTapeKit

/// ADR 0002's safety rules, section 6, one group per rule, against the simulated OP-1 and its faults. Run them on
/// their own with `swift test --filter SafetyRules`. The other test files check each call in depth; these check each
/// rule across the calls it covers.
@Suite enum SafetyRules {
    typealias Fault = SimulatedMTPDevice.Fault

    static let tapeName = "2026-220#02"
    static let tapePath: FilePath = "tapes/2026-220#02"

    /// An OP-1 with one tape, 2026-220#02, with audio on tracks 1 and 3, plus `extra`.
    static func device(_ faults: [Fault] = [], seconds: [Double] = [0.5, 0, 0.25], extra: [PendingNode] = [],
                       timeout: Duration = .seconds(90), slowAfter: Duration = .seconds(30))
        -> (FieldDevice, SimulatedMTPDevice) {
        let layout = SimulatedNode.merge([SimulatedTape(tapeName, type: .vintage, seconds: seconds).node] + extra,
                                         into: SimulatedNode.layout173, path: [])
        let simulator = SimulatedMTPDevice(faults: faults, contents: layout)
        return (FieldDevice.simulated(simulator, timeout: timeout, slowAfter: slowAfter), simulator)
    }

    /// A new, empty local folder. Delete it when done.
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SafetyRules-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An archive of 2026-220#02 from its own OP-1, with this audio, in `folder`.
    static func archive(seconds: [Double] = [0.5, 0, 0.25], in folder: URL) async throws -> ReelArchive {
        let (source, _) = device(seconds: seconds)
        return try await source.copyTape(try #require(try await source.tape(named: TapeName(tapeName))), to: folder)
    }

    static func tape(_ device: FieldDevice) async throws -> Tape {
        try #require(try await device.tape(named: TapeName(tapeName)))
    }

    static let writeOperations: Set<UInt16> = [PTPOperation.sendObjectInfo, .sendObject, .deleteObject].map(\.rawValue).reduce(into: []) { $0.insert($1) }

    /// The writes and deletes the simulator has been sent.
    static func writes(_ simulator: SimulatedMTPDevice) async -> [UInt16] {
        await simulator.sentOperations.filter { writeOperations.contains($0) }
    }

    static func local(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    static func code(_ error: any Error) -> FieldError.Code? { (error as? FieldError)?.code }

    /// A track in the OP-1's own format.
    static let track = WritingTests.wav(frames: 200)

    // MARK: - Rule 1

    /// Nothing on the OP-1 is deleted or overwritten unless a verified copy exists, or a person confirmed losing it.
    @Suite("Rule 1: a verified copy or a person's confirmation") struct Rule1 {
        @Test func withNeitherNothingIsReplaced() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = try await archive(in: folder)
            let (device, simulator) = device()
            await #expect { try await device.write(track, to: tapePath.appending("track_1.wav")) } throws: { code($0) == .alreadyExists }
            await #expect { try await device.restoreTape(from: archive) } throws: { code($0) == .alreadyExists }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aCopyThatDoesntMatchDeletesNothing() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let other = try await archive(seconds: [0.5, 0, 0.5], in: folder)
            let (device, simulator) = device()
            await #expect { try await device.deleteTape(try await tape(device), keeping: .archive(other)) } throws: {
                code($0) == .verificationFailed && ($0 as? FieldError)?.changed == []
            }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aConfirmationGoesStaleWhenTheTapeChanges() async throws {
            let (device, simulator) = device()
            let deletion = try await device.prepareToDelete(try await tape(device))
            await simulator.overwrite("track_3.wav", in: tapeName, with: track)
            await #expect { try await device.deleteTape(deletion) } throws: { code($0) == .changedSinceConfirmation }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aConfirmationWorksOnce() async throws {
            let (device, simulator) = device()
            let blank = try await device.createTape(named: TapeName("Blank"))
            let deletion = try await device.prepareToDelete(blank)
            try await device.deleteTape(deletion)
            let deletes = await simulator.deleted.count
            await #expect { try await device.deleteTape(deletion) } throws: { code($0) == .confirmationAlreadyUsed }
            #expect(await simulator.deleted.count == deletes)
        }

        @Test func aConfirmationDoesntSurviveAReconnect() async throws {
            let (device, simulator) = device()
            let deletion = try await device.prepareToRemove(at: tapePath.appending("track_1.wav"))
            await simulator.leaveAndReenterMTPMode()
            let reconnected = FieldDevice.simulated(simulator)
            await #expect { try await reconnected.removeItem(deletion) } throws: { code($0) == .changedSinceConfirmation }
            #expect(await writes(simulator).isEmpty)
        }
    }

    // MARK: - Rule 2

    /// A copy counts as verified only after it has been read back from where it was stored and matched by SHA-256.
    /// Writes to the OP-1 are read back too, unless the caller opts out.
    @Suite("Rule 2: verified means read back and matched by SHA-256") struct Rule2 {
        @Test func aCorruptedReadCantCoverMovingATape() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device([.corruptRead(name: "track_1.wav")])
            await #expect { try await device.moveTape(try await tape(device), to: folder) } throws: {
                code($0) == .verificationFailed && ($0 as? FieldError)?.changed == []
            }
            #expect(await writes(simulator).isEmpty)
            #expect(try local(folder) == ["\(tapeName).reelarchive"], "the archive is kept, since which read went wrong isn't known")
        }

        @Test func aCorruptedReadCantCoverRestoringOverATape() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = try await archive(seconds: [1], in: folder)
            let (device, simulator) = device([.corruptRead(name: "track_3.wav")])
            let existing = folder.appending(path: "existing.reelarchive")
            await #expect {
                try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: existing))
            } throws: { code($0) == .verificationFailed && ($0 as? FieldError)?.changed == [] }
            #expect(await writes(simulator).isEmpty)
            #expect(FileManager.default.fileExists(atPath: existing.path(percentEncoded: false)))
        }

        @Test func aCorruptedReadCantCoverRemovingAFile() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device([.corruptRead(name: "track_1.wav")])
            await #expect {
                try await device.removeItem(at: tapePath.appending("track_1.wav"), keepingCopyAt: folder.appending(path: "track_1.wav"))
            } throws: { code($0) == .verificationFailed }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aCorruptedReadCantCoverReplacingAFile() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device([.corruptRead(name: "track_1.wav")])
            let options = UploadOptions(existing: .replace(keepingCopyAt: folder.appending(path: "track_1.wav")))
            await #expect { try await device.write(track, to: tapePath.appending("track_1.wav"), options: options) } throws: {
                code($0) == .verificationFailed && ($0 as? FieldError)?.changed == []
            }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aWriteThatReadsBackWrongIsDeleted() async throws {
            for fault in [Fault.corruptStored(name: "track_2.wav"), .corruptRead(name: "track_2.wav")] {
                let (device, _) = device([fault])
                let path = tapePath.appending("track_2.wav")
                let options = UploadOptions(existing: .replace(confirmed: try await device.prepareToRemove(at: path)))
                await #expect { try await device.write(track, to: path, options: options) } throws: { error in
                    // The old file is gone, and the confirmation covers it, so changed names it.
                    (error as? FieldError)?.code == .verificationFailed && (error as? FieldError)?.changed == [path]
                }
                #expect(try await device.item(at: path) == nil, "the bad file isn't left")
            }
        }

        @Test func aNewFileThatReadsBackWrongIsDeletedAndNothingChanged() async throws {
            let (device, simulator) = device()
            let blank = try await device.createTape(named: TapeName("Blank"))
            let path = blank.path.appending("track_1.wav")
            try await device.removeItem(try await device.prepareToRemove(at: path))
            await simulator.add(faults: [.corruptRead(name: "track_1.wav")])
            await #expect { try await device.write(track, to: path) } throws: {
                code($0) == .verificationFailed && ($0 as? FieldError)?.changed == []
            }
            #expect(try await device.item(at: path) == nil)
        }

        @Test func optingOutSkipsTheReadBack() async throws {
            let (device, simulator) = device()
            let blank = try await device.createTape(named: TapeName("Blank"))
            let path = blank.path.appending("track_1.wav")
            try await device.removeItem(try await device.prepareToRemove(at: path))
            await simulator.add(faults: [.corruptStored(name: "track_1.wav")])
            let reads = await simulator.sentOperations.count { $0 == PTPOperation.getObject.rawValue }
            _ = try await device.write(track, to: path, options: .init(verify: false))
            #expect(await simulator.sentOperations.count { $0 == PTPOperation.getObject.rawValue } == reads)
        }
    }

    // MARK: - Rule 3

    /// Everything is checked before the first change. A refusal changes nothing.
    @Suite("Rule 3: everything is checked before the first change") struct Rule3 {
        @Test func aFullSetOfSlotsChangesNothing() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = try await archive(in: folder)
            let spares = (0..<7).map { SimulatedTape("spare \($0)").node }
            let (device, simulator) = device(extra: spares)
            await #expect { try await device.restoreTape(from: archive, as: TapeName("Ninth")) } throws: {
                code($0) == .tapeLimitReached && ($0 as? FieldError)?.changed == []
            }
            await #expect { try await device.createTape(named: TapeName("Ninth")) } throws: { code($0) == .tapeLimitReached }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aNameTheFolderDoesntAllowChangesNothing() async throws {
            let (device, simulator) = device()
            await #expect { try await device.write(Data("notes".utf8), to: tapePath.appending("notes.txt")) } throws: {
                code($0) == .notAllowed
            }
            await #expect { try await device.write(track, to: "mixdown/side_c.wav") } throws: { code($0) == .notAllowed }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aTrackInTheWrongFormatChangesNothing() async throws {
            let (device, simulator) = device()
            let mono = WAVFormat(encoding: WAVFormat.pcm, channels: 1, sampleRate: 44_100, bitsPerSample: 16)
            let options = UploadOptions(existing: .replace(confirmed: try await device.prepareToRemove(at: tapePath.appending("track_1.wav"))))
            await #expect { try await device.write(WritingTests.wav(mono), to: tapePath.appending("track_1.wav"), options: options) } throws: {
                code($0) == .notAllowed
            }
            #expect(await writes(simulator).isEmpty)
        }

        @Test func aMissingArchiveFolderChangesNothing() async throws {
            let (device, simulator) = device()
            let nowhere = FileManager.default.temporaryDirectory.appending(path: "SafetyRules-missing-\(UUID())")
            await #expect { try await device.moveTape(try await tape(device), to: nowhere) } throws: { _ in true }
            #expect(await writes(simulator).isEmpty)
        }
    }

    // MARK: - Rule 4

    /// FieldTapeKit never touches files it didn't name, and never writes `readme.txt` or outside `tapes/`, `mixdown/`,
    /// `synth/user/` and `drum/user/`.
    @Suite("Rule 4: it never touches files it didn't name") struct Rule4 {
        @Test func movingATapeDeletesOnlyItsOwnFiles() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device(extra: [SimulatedTape("2026-276#01", seconds: [0.25]).node])
            _ = try await device.moveTape(try await tape(device), to: folder)
            let own: Set = ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json", "readme.txt", tapeName]
            #expect(Set(await simulator.deleted).isSubset(of: own))
            #expect(await simulator.deleted.last == tapeName, "the folder goes last")
            #expect(try await device.tape(named: TapeName("2026-276#01")) != nil)
        }

        @Test func aTapeFolderHoldingSomethingElseIsntDeleted() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let notes = PendingNode.folder("tapes", [.folder(tapeName, [.file("notes.txt", .data(Data("mine".utf8)))])])
            let (device, simulator) = device(extra: [notes])
            await #expect { try await device.moveTape(try await tape(device), to: folder) } throws: { _ in true }
            #expect(await simulator.deleted.isEmpty)
        }

        @Test(arguments: ["tapes/2026-220#02/readme.txt", "mixdown/readme.txt", "synth/user", "tapes", "drum"])
        func whatBelongsToTheOP1IsRefused(path: String) async throws {
            let (device, simulator) = device()
            await #expect { try await device.prepareToRemove(at: FilePath(path)) } throws: { code($0) == .notAllowed }
            #expect(await writes(simulator).isEmpty)
        }

        @Test(arguments: ["readme.txt", "tapes/2026-220#02/readme.txt", "synth/track.wav", "other/track.wav"])
        func nothingIsWrittenOutsideItsFolders(path: String) async throws {
            let (device, simulator) = device()
            await #expect { try await device.write(track, to: FilePath(path)) } throws: { _ in true }
            #expect(await writes(simulator).isEmpty)
        }
    }

    // MARK: - Rule 5

    /// It never overwrites a local file. Archives get a new name rather than replacing one.
    @Suite("Rule 5: it never overwrites a local file") struct Rule5 {
        @Test func aCopyTakesTheNextFreeName() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, _) = device()
            let mine = Data("mine".utf8)
            let taken = folder.appending(path: "track_1.wav")
            try mine.write(to: taken)
            let copy = try await device.copyItem(at: tapePath.appending("track_1.wav"), to: taken)
            #expect(copy.lastPathComponent == "track_1 2.wav")
            #expect(try Data(contentsOf: taken) == mine)
        }

        @Test func anArchiveTakesANewName() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, _) = device()
            let first = try await device.copyTape(try await tape(device), to: folder)
            let second = try await device.copyTape(try await tape(device), to: folder)
            #expect(first.url != second.url)
            #expect(try local(folder).count == 2)
        }

        @Test func aTakenCopyURLChangesNothing() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = try await archive(in: folder)
            let (device, simulator) = device()
            let taken = folder.appending(path: "taken")
            let mine = Data("mine".utf8)
            try mine.write(to: taken)
            await #expect {
                try await device.write(track, to: tapePath.appending("track_1.wav"), options: .init(existing: .replace(keepingCopyAt: taken)))
            } throws: { code($0) == .localFileFailed }
            await #expect {
                try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: taken))
            } throws: { code($0) == .localFileFailed }
            #expect(await writes(simulator).isEmpty)
            #expect(try Data(contentsOf: taken) == mine)
        }
    }

    // MARK: - Rule 6

    /// It stops at the first failure and reports exactly what changed. There's no automatic retry of writes and no
    /// rollback of an existing tape. (The ping after a timeout was dropped on 2026-11-16: ADR 0002's change log.)
    @Suite("Rule 6: it stops at the first failure and reports what changed") struct Rule6 {
        @Test func anUnplugMidRestoreReportsWhatChangedAndRetriesNothing() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = try await archive(seconds: [1, 0, 1], in: folder)
            let (device, simulator) = device([.unplug(during: .sendObject, name: "track_3.wav")])
            let deletion = try await device.prepareToDelete(try await tape(device))
            await #expect { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) } throws: { error in
                let error = error as? FieldError
                return error?.code == .disconnected
                    && error?.changed == [tapePath.appending("track_1.wav"), tapePath.appending("track_3.wav")]
            }
            let unplugged = try #require(await simulator.unpluggedAt)
            let after = await simulator.sentOperations.dropFirst(unplugged)
            #expect(!after.contains(PTPOperation.sendObjectInfo.rawValue) && !after.contains(PTPOperation.sendObject.rawValue),
                    "no write is retried")
            #expect(await simulator.stored("track_1.wav", in: tapeName) == (try archive.trackData(1)), "no rollback")
            #expect(await !device.isConnected)
        }

        @Test func anUnplugMidCopyChangesNothingAndLeavesNoFile() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device([.unplug(during: .getObject, name: "track_3.wav")])
            await #expect { try await device.copyTape(try await tape(device), to: folder) } throws: {
                code($0) == .disconnected && ($0 as? FieldError)?.changed == []
            }
            #expect(try local(folder).isEmpty, "the half-made archive is deleted")
            #expect(await writes(simulator).isEmpty)
        }

        @Test func anUnplugMidWriteSaysTheHalfFileIsThere() async throws {
            let (device, simulator) = device([.unplug(during: .sendObject, name: "track_2.wav")])
            let path = tapePath.appending("track_2.wav")
            try await device.removeItem(try await device.prepareToRemove(at: path))
            await #expect { try await device.write(track, to: path) } throws: { error in
                (error as? FieldError)?.code == .disconnected && (error as? FieldError)?.changed == [path]
            }
            #expect(await simulator.stored("track_2.wav", in: tapeName) == track.prefix(track.count / 2))
        }

        @Test func aTimeoutDisconnectsAndSendsNothingMore() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device(timeout: .milliseconds(200), slowAfter: .milliseconds(100))
            let tape = try await tape(device)
            let stalled = await simulator.requestCount + 8
            await simulator.add(faults: [.noAnswer(request: stalled)])
            await #expect { try await device.copyTape(tape, to: folder) } throws: { code($0) == .disconnected }
            #expect(await simulator.sentOperations.count == stalled, "no ping and no retry")
            #expect(try local(folder).isEmpty)
            #expect(await !device.isConnected)
        }

        @Test func aSlowTransferAtTheOP1sSpeedIsWaitedFor() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, _) = device([Fault.op1Speed], seconds: [3, 0, 3], slowAfter: .milliseconds(10))
            let clock = ContinuousClock()
            let tape = try await tape(device)
            let bytes = tape.tracks.reduce(0) { $0 + $1.size }
            var archive: ReelArchive?
            let elapsed = try await clock.measure { archive = try await device.copyTape(tape, to: folder) }
            #expect(archive != nil)
            #expect(elapsed >= .seconds(Double(bytes) / 20_000_000), "every track read at 20 MB/s")
            #expect(await device.isConnected, "slow isn't lost")
        }

        @Test func cancellingARestoreOverATapeOnceItStartedRunsToTheEnd() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = try await archive(seconds: [3, 0, 3], in: folder)
            let (device, simulator) = device([Fault.op1Speed], seconds: [1])
            let deletion = try await device.prepareToDelete(try await tape(device))
            let restore = Task { try await device.restoreTape(from: archive, conflict: .replace(confirmed: deletion)) }
            while await simulator.deleted.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
            restore.cancel()
            let restored = try await restore.value
            #expect(restored.tracks.map(\.size) == archive.tracks.map(\.size), "a tape isn't left half-written")
        }
    }

    // MARK: - Rule 7

    /// It sends only the standard MTP operations it uses. Nothing vendor-specific, and no MIDI.
    @Suite("Rule 7: only the standard MTP operations it lists") struct Rule7 {
        static let allowed: Set<UInt16> = [
            0x1001, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x101B, // GetDeviceInfo to GetPartialObject
            0x100C, 0x100D, 0x100B,                                 // SendObjectInfo, SendObject, DeleteObject
        ]

        @Test func itKnowsNoOtherOperation() {
            #expect(Set(PTPOperation.allCases.map(\.rawValue)) == Self.allowed)
        }

        @Test func everyCallSendsOnlyThose() async throws {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (device, simulator) = device(extra: [.folder("mixdown", [.file("side_a.wav", .silence(seconds: 0.5))])])
            let tape = try await tape(device)
            _ = try await device.tapeSlots()
            _ = try await device.contents(of: tape.path.appending("tape.json"))
            _ = try await device.contents(of: tape.path.appending("track_1.wav"), range: 0..<44)
            let archive = try await device.copyTape(tape, to: folder)
            _ = try await device.copyAlbum(to: folder)
            let duplicate = try await device.duplicateTape(tape, as: TapeName("Copy"))
            try await device.deleteTape(duplicate, keeping: .tape(tape))
            let moved = try await device.moveTape(tape, to: folder)
            _ = try await device.restoreTape(from: moved)
            let blank = try await device.createTape(named: TapeName("Blank"))
            _ = try await device.restoreTape(from: archive, as: blank.name, conflict: .replace(confirmed: try await device.prepareToDelete(blank)))
            _ = try await device.write(PresetWritingTests.wav(), to: "drum/user/kick.wav")
            try await device.removeItem(try await device.prepareToRemove(at: "drum/user/kick.wav"))
            let sent = Set(await simulator.sentOperations)
            #expect(sent.isSubset(of: Self.allowed), "sent \(sent.subtracting(Self.allowed).map { String(format: "0x%04X", $0) })")
            #expect(sent.isSuperset(of: writeOperations), "the calls above wrote and deleted")
        }
    }
}
