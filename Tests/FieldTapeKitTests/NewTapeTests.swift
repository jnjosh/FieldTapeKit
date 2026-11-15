import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct NewTapeTests {
    /// 2026-220#02, Vintage, with tracks 1 and 3; a tape that isn't sound; and `extra` more blank tapes.
    static func device(_ faults: [SimulatedMTPDevice.Fault] = [], extra: Int = 0) -> (FieldDevice, SimulatedMTPDevice) {
        let header = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.trackFormat, dataBytes: 0)
        let contents: [PendingNode] = [
            SimulatedTape("2026-220#02", type: .vintage, seconds: [0.5, 0, 0.25]).node,
            .folder("tapes", [.folder("broken", (1...4).map { .file("track_\($0).wav", .data(header)) })]),
        ] + (0..<extra).map { SimulatedTape("spare \($0)").node }
        let simulator = SimulatedMTPDevice(faults: faults, contents: SimulatedNode.merge(contents, into: SimulatedNode.layout173, path: []))
        return (FieldDevice.simulated(simulator), simulator)
    }

    static func source(_ device: FieldDevice, _ name: String = "2026-220#02") async throws -> Tape {
        try #require(try await device.tape(named: TapeName(listed: name)))
    }

    static func names(_ device: FieldDevice) async throws -> [String] {
        try await device.contentsOfDirectory(at: .op1Tapes).map(\.name).sorted()
    }

    static let before = ["2026-220#02", "broken"]

    // MARK: createTape

    @Test(arguments: [TapeType.studio, .diskMini])
    func createsAnEmptyTape(type: TapeType) async throws {
        let (device, _) = Self.device()
        let tape = try await device.createTape(named: TapeName("New Tape #1"), type: type)
        #expect(tape.name.string == "new tape #1" && tape.path == "tapes/new tape #1")
        #expect(tape.isSound && tape.isEmpty && tape.type == type)
        #expect(tape.tracks.map(\.size) == [44, 44, 44, 44])
        #expect(tape.manifest?.data == TapeManifest.blankData(type: type))
        #expect(try await device.tapeSlots().used == 3)
    }

    @Test func theBlankTemplateIsTheProbesDiskMiniTape() throws {
        let probe = #"{"clips":[],"loop":false,"loop_in":0,"loop_out":0,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,"tape_type":3,"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,"temposyncout":1,"temposynctype":0,"track":0,"version":1}"#
        #expect(TapeManifest.blankData(type: .diskMini) == Data(probe.utf8))
        #expect(try TapeManifest(TapeManifest.blankData(type: .studio)).type == .studio)
    }

    @Test func createWritesTracksFirstAndTapeJSONLast() async throws {
        let (device, simulator) = Self.device()
        _ = try await device.createTape(named: TapeName("order"))
        let written = await simulator.sentNames
        #expect(written == ["order", "track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"])
    }

    @Test func aTakenNameIsRefusedIgnoringCase() async throws {
        let (device, simulator) = Self.device()
        await #expect { try await device.createTape(named: TapeName("2026-220#02")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .alreadyExists && error?.path == "tapes/2026-220#02" && error?.changed == []
        }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func aFullSetOfSlotsIsRefused() async throws {
        let (device, simulator) = Self.device(extra: 6)
        await #expect { try await device.createTape(named: TapeName("ninth")) } throws: {
            ($0 as? FieldError)?.code == .tapeLimitReached
        }
        await #expect { try await device.duplicateTape(try await Self.source(device), as: TapeName("ninth")) } throws: {
            ($0 as? FieldError)?.code == .tapeLimitReached
        }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func aNameTheFirmwareWouldCutIsRefused() async throws {
        let (device, simulator) = Self.device()
        await #expect { try await device.createTape(named: TapeName(listed: "fieldck #2-13")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .invalidName && error?.reason == "it's longer than 12 characters"
        }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test(arguments: ["track_3.wav", "tape.json"])
    func aFailedWriteRemovesTheHalfMadeTape(file: String) async throws {
        let (device, _) = Self.device([.corruptStored(name: file)])
        await #expect { try await device.createTape(named: TapeName("half")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.path == FilePath("tapes/half").appending(file)
                && error?.changed == []
        }
        #expect(try await Self.names(device) == Self.before)
    }

    @Test func aCleanupThatFailsIsReportedInChanged() async throws {
        let (device, _) = Self.device([.corruptStored(name: "track_2.wav"),
                                       .refuseDeleting(name: "track_1.wav", responseCode: PTPResponseCode.generalError)])
        await #expect { try await device.createTape(named: TapeName("stuck")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == ["tapes/stuck"]
        }
        #expect(try await Self.names(device) == Self.before + ["stuck"])
    }

    @Test func cancellingRemovesTheHalfMadeTape() async throws {
        let (device, _) = Self.device()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await device.createTape(named: TapeName("cancelled"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await Self.names(device) == Self.before)
    }

    // MARK: duplicateTape

    @Test func duplicatesATape() async throws {
        let (device, simulator) = Self.device()
        let source = try await Self.source(device)
        let parent = ProgressManager(totalCount: 1)
        let copy = try await device.duplicateTape(source, as: TapeName("Copy"), progress: parent.subprogress(assigningCount: 1))
        #expect(copy.name.string == "copy" && copy.isSound)
        #expect(copy.manifest == source.manifest && copy.type == .vintage)
        #expect(copy.tracks.map(\.size) == source.tracks.map(\.size))
        for number in 1...4 {
            #expect(await simulator.stored("track_\(number).wav", in: "copy")
                == simulator.stored("track_\(number).wav", in: "2026-220#02"))
        }
        #expect(parent.fractionCompleted == 1)
        // The source was only read.
        #expect(try await Self.source(device) == source)
        #expect(await simulator.deleted.isEmpty)
        #expect(await simulator.sentNames == ["copy", "track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"])
    }

    @Test func aSourceThatIsntSoundIsRefused() async throws {
        let (device, simulator) = Self.device()
        await #expect { try await device.duplicateTape(try await Self.source(device, "broken"), as: TapeName("copy")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.path == "tapes/broken" && error?.changed == []
        }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func aSourceThatsGoneIsNotFound() async throws {
        let (device, simulator) = Self.device()
        let source = try await Self.source(device)
        try await device.removeItem(try await device.prepareToRemove(at: source.path))
        await #expect { try await device.duplicateTape(source, as: TapeName("copy")) } throws: {
            ($0 as? FieldError)?.code == .notFound
        }
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func duplicatingUnderItsOwnNameIsRefused() async throws {
        let (device, _) = Self.device()
        await #expect { try await device.duplicateTape(try await Self.source(device), as: TapeName("2026-220#02")) } throws: {
            ($0 as? FieldError)?.code == .alreadyExists
        }
    }

    @Test(arguments: [
        ("track_1.wav", "it changed on the OP-1 while it was being copied: its files or tape.json changed while it was copied"),
        ("tape.json", "it changed on the OP-1 while it was being copied: its files or tape.json changed while it was copied"),
    ])
    func aSourceThatChangesIsRefusedAndTheCopyRemoved(file: String, reason: String) async throws {
        let changed = file == "tape.json" ? SimulatedTape.tapeJSON(type: .porta, frames: [22_050, 0, 11_025, 0])
            : WAVHeader.bytes(format: FirmwareProfile.v1_7_3.trackFormat, dataBytes: 8) + Data(count: 8)
        // The test's listing reads tape.json first, so the change follows duplicateTape's own read.
        let (device, simulator) = Self.device([.changeAfterReading(name: file, to: changed, reads: file == "tape.json" ? 2 : 1)])
        let source = try await Self.source(device)
        await #expect { try await device.duplicateTape(source, as: TapeName("copy")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.reason == reason && error?.path == "tapes/2026-220#02"
                && error?.changed == []
        }
        #expect(try await Self.names(device) == Self.before)
        #expect(await !simulator.sentNames.contains("tape.json"), "tape.json is never written")
    }

    @Test func aShortReadOfTheSourceIsRefused() async throws {
        let (device, _) = Self.device([.shortRead(name: "track_3.wav")])
        await #expect { try await device.duplicateTape(try await Self.source(device), as: TapeName("copy")) } throws: { error in
            (error as? FieldError)?.reason == "it changed on the OP-1 while it was being copied: track_3.wav read as 88243 bytes, not the 88244 listed"
        }
        #expect(try await Self.names(device) == Self.before)
    }

    @Test func aFailedDuplicateWriteRemovesTheCopy() async throws {
        let (device, _) = Self.device([.refuseSendObject(responseCode: PTPResponseCode.storeFull)])
        await #expect { try await device.duplicateTape(try await Self.source(device), as: TapeName("copy")) } throws: { error in
            let error = error as? FieldError
            return error?.code == .insufficientSpace && error?.changed == []
        }
        #expect(try await Self.names(device) == Self.before)
    }
}
