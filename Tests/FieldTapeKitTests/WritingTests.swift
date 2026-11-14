import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct WritingTests {
    static let profile = FirmwareProfile.v1_7_3

    /// A WAV in the format the OP-1 uses for tape tracks, or another one.
    static func wav(_ format: WAVFormat = profile.trackFormat, frames: Int = 100) -> Data {
        let bytes = frames * format.frameBytes
        return WAVHeader.bytes(format: format, dataBytes: bytes) + Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) })
    }

    static let blankJSON = Data(#"{"clips":[],"loop":false,"tape_type":3,"version":1}"#.utf8)

    /// A 1.7.3 OP-1 with one blank tape, made as the OP-1 makes one.
    static func device(_ faults: [SimulatedMTPDevice.Fault] = [], capacity: UInt64 = 6_429_185_024)
        async -> (FieldDevice, SimulatedMTPDevice) {
        let layout = SimulatedNode.merge([.folder("tapes", [.folder("2026-312#01", [
            .file("tape.json", .data(blankJSON)),
            .file("track_1.wav", .data(WAVHeader.bytes(format: profile.trackFormat, dataBytes: 0))),
        ])])], into: SimulatedNode.layout173, path: [])
        let simulator = SimulatedMTPDevice(capacity: capacity, faults: faults, contents: layout)
        return (FieldDevice.simulated(simulator), simulator)
    }

    // MARK: Writing

    @Test func writesATrackAndReadsItBack() async throws {
        let (device, _) = await Self.device()
        let track = Self.wav()
        let item = try await device.write(track, to: "tapes/2026-312#01/track_2.wav")
        #expect(item.path == "tapes/2026-312#01/track_2.wav")
        #expect(item.size == track.count)
        #expect(item.format == .wav)
        #expect(try await device.contents(of: item.path) == track)
    }

    @Test func sendsNamesLowercase() async throws {
        let (device, simulator) = await Self.device()
        let item = try await device.write(Self.wav(), to: "TAPES/2026-312#01/Track_2.WAV")
        #expect(item.path == "tapes/2026-312#01/track_2.wav")
        #expect(await simulator.stored("track_2.wav", in: "2026-312#01") != nil)
    }

    /// `rebuild.tape-json`: after a track write, the OP-1 rebuilds `tape.json` with one clip per track, and within
    /// the session it still lists at its old size.
    @Test func aTrackWriteRebuildsTapeJSON() async throws {
        let (device, simulator) = await Self.device()
        _ = try await device.write(Self.wav(frames: 250), to: "tapes/2026-312#01/track_2.wav")
        let stored = try #require(await simulator.stored("tape.json", in: "2026-312#01"))
        let root = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let clips = try #require(root["clips"] as? [[String: Any]])
        #expect(clips.count == 1)
        #expect(clips.first?["ch"] as? Int == 1)
        #expect(clips.first?["stop"] as? Int == 250)
        #expect(try await device.item(at: "tapes/2026-312#01/tape.json")?.size == Self.blankJSON.count)
    }

    @Test func writesAnAlbumSide() async throws {
        let (device, _) = await Self.device()
        // The default layout's sides exist, so this writes to a mixdown with side B removed first.
        try await device.removeItem(try await device.prepareToRemove(at: "mixdown/side_b.wav"))
        let side = Self.wav(Self.profile.sideFormat)
        let item = try await device.write(side, to: "mixdown/side_b.wav")
        #expect(try await device.contents(of: item.path) == side)
    }

    @Test func aPathThatsTakenIsRefused() async throws {
        let (device, _) = await Self.device()
        await #expect { try await device.write(Self.wav(), to: "tapes/2026-312#01/TRACK_1.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .alreadyExists && error?.path == "tapes/2026-312#01/track_1.wav" && error?.changed == []
        }
    }

    @Test func aMissingFolderIsNotFound() async throws {
        let (device, _) = await Self.device()
        await #expect { try await device.write(Self.wav(), to: "tapes/missing/track_1.wav") } throws: {
            ($0 as? FieldError)?.code == .notFound && ($0 as? FieldError)?.path == "tapes/missing"
        }
        await #expect { try await device.write(Self.wav(), to: "mixdown/side_a.wav/x.wav") } throws: {
            ($0 as? FieldError)?.code == .notADirectory
        }
    }

    // MARK: Folder rules, before anything is sent

    @Test(arguments: [
        ("tapes/2026-312#01/track_5.wav", "a tape holds only tape.json and track_1.wav to track_4.wav"),
        ("tapes/2026-312#01/readme.txt", "a tape holds only tape.json and track_1.wav to track_4.wav"),
        ("mixdown/side_c.wav", "mixdown holds only side_a.wav and side_b.wav"),
        ("synth/user/pad.wav", "writing presets isn't supported yet"),
        ("tapes/loose.wav", "FieldTapeKit writes only tape files and album sides"),
        ("synth/slots/1/pad.aif", "FieldTapeKit writes only tape files and album sides"),
    ])
    func refusesWhatAFolderDoesntAllow(path: String, reason: String) async throws {
        let (device, simulator) = await Self.device()
        let before = await simulator.requestCount
        await #expect { try await device.write(Self.wav(), to: FilePath(path)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.errorDescription?.hasSuffix("because \(reason).") == true
        }
        // Only listings were sent, and nothing was made.
        #expect(try await device.item(at: FilePath(path)) == nil)
        #expect(await simulator.requestCount > before)
    }

    @Test(arguments: [
        ("tapes/2026-312#01/track_2.wav", WAVFormat(encoding: 1, channels: 2, sampleRate: 44_100, bitsPerSample: 16)),
        ("tapes/2026-312#01/track_2.wav", WAVFormat(encoding: 1, channels: 2, sampleRate: 48_000, bitsPerSample: 32)),
        ("tapes/2026-312#01/track_2.wav", WAVFormat(encoding: 1, channels: 1, sampleRate: 44_100, bitsPerSample: 32)),
        ("mixdown/side_b.wav", WAVFormat(encoding: 1, channels: 2, sampleRate: 44_100, bitsPerSample: 32)),
    ])
    func refusesAudioInAnotherFormat(path: String, format: WAVFormat) async throws {
        let (device, _) = await Self.device()
        try await device.removeItem(try await device.prepareToRemove(at: "mixdown/side_b.wav"))
        await #expect { try await device.write(Self.wav(format), to: FilePath(path)) } throws: {
            ($0 as? FieldError)?.code == .notAllowed
        }
    }

    @Test func refusesWhatIsntAWAVOrJSON() async throws {
        let (device, _) = await Self.device()
        var mismatched = Self.wav()
        mismatched.append(contentsOf: [0, 0, 0, 0])
        for data in [Data("not audio".utf8), mismatched] {
            await #expect { try await device.write(data, to: "tapes/2026-312#01/track_2.wav") } throws: {
                ($0 as? FieldError)?.code == .notAllowed
            }
        }
        let rules = WriteRules(profile: Self.profile)
        #expect(throws: FieldError.self) {
            try rules.checkFile(["tapes", "a", "tape.json"], data: Data("[1]".utf8), path: "tapes/a/tape.json")
        }
        try rules.checkFile(["tapes", "a", "tape.json"], data: Self.blankJSON, path: "tapes/a/tape.json")
    }

    @Test func aTrackPastSixMinutesIsTooLong() throws {
        let frames = Self.profile.maximumTapeFrames + 1
        let data = WAVHeader.bytes(format: Self.profile.trackFormat, dataBytes: frames * 8) + Data(count: frames * 8)
        #expect { try WriteRules(profile: Self.profile).checkFile(["tapes", "a", "track_1.wav"], data: data, path: "tapes/a/track_1.wav") }
            throws: { ($0 as? FieldError)?.code == .tapeTooLong }
    }

    // MARK: When the OP-1 doesn't take it

    @Test func aStoreFullIsInsufficientSpace() async throws {
        let (device, _) = await Self.device(capacity: 2_000)
        await #expect { try await device.write(Self.wav(frames: 1_000), to: "tapes/2026-312#01/track_2.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .insufficientSpace && error?.responseCode == 0x200C && error?.changed == []
        }
        #expect(try await device.item(at: "tapes/2026-312#01/track_2.wav") == nil)
    }

    @Test func aRefusedSendDeletesTheHalfMadeFile() async throws {
        let (device, simulator) = await Self.device([.refuseSendObject(responseCode: 0x2002)])
        await #expect { try await device.write(Self.wav(), to: "tapes/2026-312#01/track_2.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .deviceRefused && error?.changed == []
        }
        #expect(await simulator.deleted == ["track_2.wav"])
        #expect(try await device.item(at: "tapes/2026-312#01/track_2.wav") == nil)
    }

    @Test func aBadReadBackIsDeletedAndReported() async throws {
        let (device, simulator) = await Self.device([.corruptStored(name: "track_2.wav")])
        await #expect { try await device.write(Self.wav(), to: "tapes/2026-312#01/track_2.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == []
        }
        #expect(await simulator.deleted == ["track_2.wav"])
    }

    @Test func aBadReadBackThatCantBeDeletedIsInChanged() async throws {
        let (device, _) = await Self.device([.corruptStored(name: "track_2.wav"),
                                             .refuseDeleting(name: "track_2.wav", responseCode: 0x2002)])
        await #expect { try await device.write(Self.wav(), to: "tapes/2026-312#01/track_2.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == ["tapes/2026-312#01/track_2.wav"]
        }
    }

    @Test func withoutVerifyingABadWriteGoesUnnoticed() async throws {
        let (device, _) = await Self.device([.corruptStored(name: "track_2.wav")])
        let track = Self.wav()
        let item = try await device.write(track, to: "tapes/2026-312#01/track_2.wav", options: UploadOptions(verify: false))
        #expect(try await device.contents(of: item.path) != track)
    }

    @Test func cancellingFirstSendsNothing() async throws {
        let (device, simulator) = await Self.device()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.write(Self.wav(), to: "tapes/2026-312#01/track_2.wav")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await simulator.stored("track_2.wav", in: "2026-312#01") == nil)
    }

    // MARK: Uploading a local file

    @Test func uploadsALocalFileWithProgress() async throws {
        let (device, _) = await Self.device()
        let folder = FileManager.default.temporaryDirectory.appending(path: "WritingTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appending(path: "take.wav")
        try Self.wav().write(to: local)

        let parent = ProgressManager(totalCount: 1)
        let item = try await device.copyItem(at: local, to: "tapes/2026-312#01/track_3.wav",
                                             progress: parent.subprogress(assigningCount: 1))
        #expect(parent.fractionCompleted == 1)
        #expect(try await device.contents(of: item.path) == Self.wav())

        await #expect { try await device.copyItem(at: folder.appending(path: "missing.wav"), to: "tapes/2026-312#01/track_4.wav") }
            throws: { ($0 as? FieldError)?.code == .localFileFailed }
    }

    // MARK: New tapes

    @Test func makesATapeFolderLowercase() async throws {
        let (device, simulator) = await Self.device()
        // FieldCheck's scratch tape: 15 characters, using every kind the OP-1 allows.
        let item = try await device.createDirectory(at: "tapes/FIELDCHECK #1-2")
        #expect(item.path == "tapes/fieldcheck #1-2")
        #expect(item.isDirectory)
        #expect(await simulator.stored("fieldcheck #1-2", in: "tapes") != nil)
    }

    @Test(arguments: [("tapes/probe_1", "it uses “_”"), ("tapes/fieldcheck #1-23", "it's longer than 15 characters"),
                      ("tapes/   ", "it's empty"), ("tapes/é", "it uses “é”")])
    func refusesANameTheOP1CantUse(path: String, reason: String) async throws {
        let (device, _) = await Self.device()
        await #expect { try await device.createDirectory(at: FilePath(path)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .invalidName && error?.errorDescription?.hasSuffix(": \(reason).") == true
        }
    }

    @Test func foldersAreOnlyTapes() async throws {
        let (device, _) = await Self.device()
        for path: FilePath in ["synth/mine", "tapes/2026-312#01/inside", "mixdown/more"] {
            await #expect { try await device.createDirectory(at: path) } throws: { ($0 as? FieldError)?.code == .notAllowed }
        }
    }

    @Test func aTakenTapeNameIsRefused() async throws {
        let (device, _) = await Self.device()
        await #expect { try await device.createDirectory(at: "tapes/2026-312#01") } throws: {
            ($0 as? FieldError)?.code == .alreadyExists
        }
    }

    @Test func aNinthTapeIsRefused() async throws {
        let (device, _) = await Self.device()
        for number in 2...8 { _ = try await device.createDirectory(at: FilePath("tapes/tape \(number)")) }
        await #expect { try await device.createDirectory(at: "tapes/tape 9") } throws: { error in
            (error as? FieldError)?.code == .tapeLimitReached
                && (error as? FieldError)?.recoverySuggestion == "Move a tape off the OP-1 first."
        }
    }
}
