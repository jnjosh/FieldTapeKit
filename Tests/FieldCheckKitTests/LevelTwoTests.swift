import Foundation
import System
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct LevelTwoTests {
    static func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LevelTwoTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 1 second of audio on side B, which level 2 writes its tone over. Side A is empty.
    static let sideB = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 4 * 44_100)
        + Data(repeating: 7, count: 4 * 44_100)
    static let defaultAlbum: [PendingNode] = [.file("side_b.wav", .data(sideB))]

    static func device(_ faults: [SimulatedMTPDevice.Fault] = [], tapes: Int = 0,
                       album: [PendingNode] = defaultAlbum) -> (FieldDevice, SimulatedMTPDevice) {
        let added: [PendingNode] = [.folder("tapes", (0..<tapes).map { .folder("2026-300#0\($0)", []) }), .folder("mixdown", album)]
        let layout = SimulatedNode.merge(added, into: SimulatedNode.layout173, path: [])
        let simulator = SimulatedMTPDevice(faults: faults, contents: layout)
        return (FieldDevice.simulated(simulator), simulator)
    }

    static func run(_ device: FieldDevice, longCheck: Bool = false, in workspace: URL) async -> CheckReport {
        let plan = await LevelTwo.plan(for: device)
        return await LevelTwo.run(on: device, plan: plan, longCheck: longCheck, workspace: workspace, host: LevelOneTests.host)
    }

    static let expectations = ["names.maximum", "write.folder", "write.exact", "write.refused-name", "rebuild.tape-json",
                               "rebuild.stale-size", "tape.track-limit", "write.preset-converted", "write.speed",
                               "device.storage", "album.write-exact"]

    // MARK: A whole run

    @Test func passesOnASimulated173AndLeavesTheScratchTape() async throws {
        let (device, simulator) = Self.device()
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let report = await Self.run(device, in: workspace)
        #expect(report.level == 2)
        #expect(report.results.map(\.expectation) == Self.expectations)
        for result in report.results where !["tape.track-limit", "album.write-exact"].contains(result.expectation) {
            #expect(result.outcome == .pass, "\(result.expectation): \(result.summary)")
        }
        #expect(report.results[6].outcome == .notRun && report.results[6].summary == "The long check wasn't asked for.")

        // The scratch tape ends as generated, with tape.json written last.
        let names = try await device.contentsOfDirectory(at: LevelTwo.scratchTape).map(\.name)
        #expect(Set(names) == ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"])
        #expect(try await device.contents(of: LevelTwo.scratchTape.appending("tape.json")) == LevelTwo.Content.tapeJSON)
        #expect(try await device.contents(of: LevelTwo.scratchTape.appending("track_1.wav")) == LevelTwo.Content.replacement)
        for path in LevelTwo.presets { #expect(try await !device.fileExists(at: path)) }
        #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "drum-user-fieldcheck.wav").path))
        #expect(try Data(contentsOf: workspace.appending(path: "track_1.wav")) == LevelTwo.Content.tracks[0].1)
        // Album writing is off on 1.7.3 (`album.write-again`), so side B isn't touched.
        #expect(report.results.last?.summary == "Album writing is off on firmware 1.7.3, so the album wasn't touched.")
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
        // Only what level 2 makes was deleted: the replaced track, the stale tape.json, and the presets.
        #expect(await simulator.deleted == ["track_1.wav", "tape.json", "fieldcheck.wav", "fieldcheck.wav"])
    }

    @Test func theLongCheckWritesAFullTrackThenPutsTheTapeBack() async throws {
        let (device, simulator) = Self.device()
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let report = await Self.run(device, longCheck: true, in: workspace)
        for result in report.results where result.expectation != "album.write-exact" {
            #expect(result.outcome == .pass, "\(result.expectation): \(result.summary)")
        }
        let limit = try #require(report.results.first { $0.expectation == "tape.track-limit" })
        #expect(limit.summary.hasPrefix("A full 6-minute track of 127,008,044 bytes was written in "))
        guard case .record(let observed) = limit.observed else { Issue.record("No observations"); return }
        #expect(observed["bytes"] == 127_008_044 && observed["readBytes"] == 127_008_044)
        #expect(observed["footprintPeak"] != nil)

        // The scratch tape ends as it does without the long check.
        #expect(try await device.contents(of: LevelTwo.scratchTape.appending("track_2.wav")) == LevelTwo.Content.tracks[1].1)
        #expect(try await device.contents(of: LevelTwo.scratchTape.appending("tape.json")) == LevelTwo.Content.tapeJSON)
        #expect(await simulator.deleted.prefix(5) == ["track_1.wav", "tape.json", "track_2.wav", "track_2.wav", "tape.json"])

        let speed = try #require(report.results.first { $0.expectation == "write.speed" })
        #expect(speed.summary.contains("track_2.wav (6 minutes) alone: "))
    }

    @Test func theLongTrackIsTheLongestATapeAllows() throws {
        let long = LevelTwo.Content.longTrack()
        #expect(long.count == 127_008_044)
        try WriteRules(profile: .v1_7_3).checkFile(["tapes", "x", "track_2.wav"], data: long, path: "tapes/x/track_2.wav")
        let longer = LevelTwo.Content.longTrack(frames: FirmwareProfile.v1_7_3.maximumTapeFrames + 1)
        #expect(throws: FieldError.self) {
            try WriteRules(profile: .v1_7_3).checkFile(["tapes", "x", "track_2.wav"], data: longer, path: "tapes/x/track_2.wav")
        }
    }

    @Test func sideBIsCopiedAndWrittenOverWhenBothSidesHaveAudio() async throws {
        let a = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 4 * 44_100) + Data(repeating: 3, count: 4 * 44_100)
        let b = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 4 * 44_100) + Data(repeating: 7, count: 4 * 44_100)
        let (device, simulator) = Self.device(album: [.file("side_a.wav", .data(a)), .file("side_b.wav", .data(b))])
        await device.overrideAlbumWrites(true)  // Off on 1.7.3 (`album.write-again`).
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plan = await LevelTwo.plan(for: device)
        #expect(plan.albumSide?.side == .b)
        #expect(plan.steps.contains { $0.hasPrefix("mixdown/side_b.wav has 1s of your audio: copy it to this run's folder") })

        let report = await Self.run(device, in: workspace)
        let album = try #require(report.results.first { $0.expectation == "album.write-exact" })
        #expect(album.outcome == .pass, "\(album.summary)")
        #expect(album.summary.hasPrefix("mixdown/side_b.wav was copied off and verified, then a tone of the same length, 176,444 bytes"))
        #expect(try await device.contents(of: "mixdown/side_b.wav") == LevelTwo.Content.sideTone(bytes: b.count))
        #expect(try await device.contents(of: "mixdown/side_a.wav") == a, "side A isn't touched")
        #expect(try Data(contentsOf: workspace.appending(path: "side_b before level 2.wav")) == b)
        #expect(await simulator.deleted.filter { $0.hasPrefix("side_") } == ["side_b.wav"])
    }

    @Test func theAlbumIsLeftAloneOn173() async throws {
        let (device, _) = Self.device()
        let plan = await LevelTwo.plan(for: device)
        #expect(plan.albumSide == nil)
        #expect(plan.steps.contains { $0.hasPrefix("The album isn't touched: album writing is off on firmware 1.7.3") })
    }

    @Test func theAlbumIsLeftAloneWithoutASoundSideWithAudio() async throws {
        // Side A empty, which a tone would make grow, and side B not sound.
        let (device, simulator) = Self.device(album: [.file("side_b.wav", .data(Data("RIFF".utf8)))])
        await device.overrideAlbumWrites(true)  // Off on 1.7.3 (`album.write-again`).
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plan = await LevelTwo.plan(for: device)
        #expect(plan.albumSide == nil)
        #expect(plan.steps.contains("Neither album side has sound audio, so the album isn't touched: a tone over an empty side would make it grow, which hangs the OP-1."))
        let report = await Self.run(device, in: workspace)
        let album = try #require(report.results.first { $0.expectation == "album.write-exact" })
        #expect(album.outcome == .notRun && album.summary == "Neither album side has sound audio, so the album wasn't touched.")
        #expect(await !simulator.deleted.contains { $0.hasPrefix("side_") })
    }

    @Test func sideAIsUsedWhenSideBIsEmpty() async throws {
        let (device, _) = Self.device(album: [.file("side_a.wav", .silence(seconds: 3))])
        await device.overrideAlbumWrites(true)  // Off on 1.7.3 (`album.write-again`).
        #expect(await LevelTwo.plan(for: device).albumSide?.path == "mixdown/side_a.wav")
        let (empty, _) = Self.device(album: [])
        await empty.overrideAlbumWrites(true)
        #expect(await LevelTwo.plan(for: empty).albumSide == nil, "an empty side is never written")
    }

    @Test func aToneThatDoesntReadBackStopsAndSaysWhereTheCopyIs() async throws {
        let (device, _) = Self.device([.corruptStored(name: "side_b.wav")])
        await device.overrideAlbumWrites(true)  // Off on 1.7.3 (`album.write-again`).
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let report = await Self.run(device, in: workspace)
        let album = try #require(report.results.first { $0.expectation == "album.write-exact" })
        #expect(album.outcome == .fail)
        #expect(album.summary.hasPrefix("restoreSide stopped after deleting mixdown/side_b.wav: "))
        #expect(album.summary.hasSuffix("Its copy is in this run's folder as side_b before level 2.wav. The OP-1 may put its own side back once it leaves MTP mode."))
    }

    @Test func summaries() async throws {
        let (device, _) = Self.device()
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let summaries = Dictionary(uniqueKeysWithValues: (await Self.run(device, in: workspace)).results.map { ($0.expectation, $0.summary) })
        #expect(summaries["names.maximum"] == "The OP-1 took FIELDCK #1-2, 12 characters, as fieldck #1-2, and FIELDCK #2-13, "
                + "13 characters, as fieldck #2-13. What it keeps after a reconnect is level 3.")
        #expect(summaries["write.refused-name"] == "track_5.wav was refused with 0x2002, before any data was sent.")
        #expect(summaries["write.preset-converted"] == "Both came back as AIFC under the same name, with the samples sent; "
                + "of 25 s, drum/user/ kept 20.000 s, synth/user/ kept 6.000 s.")
    }

    @Test func theGeneratedTapeIsConsistent() throws {
        let sizes = Dictionary(uniqueKeysWithValues: LevelTwo.Content.tracks.map { ($0.0, $0.1.count) })
        #expect(TapeConsistency.problems(json: LevelTwo.Content.tapeJSON, trackSizes: sizes).isEmpty)
        #expect(LevelTwo.Content.replacement.count == LevelTwo.Content.trackBytes)
        // The blank tape.json is the one the probe read from a real blank tape.
        #expect(LevelTwo.Content.blankTapeJSON == Data(OP1Fixture.blankTapeJSON.utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: LevelTwo.Content.tapeJSON) as? [String: Any])
        #expect(Set(root.keys) == FirmwareProfile.v1_7_3.tapeJSON.keys)
        #expect(root["tape_type"] as? Int == 2 && root["loop"] as? Bool == true)
        let clips = try #require(root["clips"] as? [[String: Any]])
        #expect(clips.allSatisfy { $0["padding"] as? [Int] == [-1, -1, -1, -1] })
        for (_, track) in LevelTwo.Content.tracks {
            try WriteRules(profile: .v1_7_3).checkFile(["tapes", "x", "track_1.wav"], data: track, path: "tapes/x/track_1.wav")
        }
    }

    // MARK: Before it starts

    @Test func refusesWithNoFreeSlot() async throws {
        #expect(await LevelTwo.plan(for: Self.device(tapes: 7).0).refusal
                == "7 of the 8 tape slots are used, and level 2 needs two for its tapes. Move a tape off the OP-1 first.")
        #expect(await LevelTwo.plan(for: Self.device(tapes: 6).0).refusal == nil)
        let (device, simulator) = Self.device(tapes: 8)
        let plan = await LevelTwo.plan(for: device)
        #expect(plan.refusal == "8 of the 8 tape slots are used, and level 2 needs two for its tapes. Move two tapes off the OP-1 first.")
        let report = await LevelTwo.run(on: device, plan: plan, workspace: try Self.workspace(), host: LevelOneTests.host)
        #expect(report.results.allSatisfy { $0.outcome == .notRun && $0.summary == plan.refusal })
        #expect(await simulator.deleted.isEmpty)
        #expect(try await !device.fileExists(at: LevelTwo.scratchTape))
    }

    @Test func aPlanFromAnotherConnectionRunsNothing() async throws {
        let (device, simulator) = Self.device()
        let plan = await LevelTwo.plan(for: device)
        let report = await LevelTwo.run(on: FieldDevice.simulated(simulator), plan: plan, workspace: try Self.workspace(),
                                        host: LevelOneTests.host)
        #expect(report.results.allSatisfy { $0.outcome == .notRun })
        #expect(try await !device.fileExists(at: LevelTwo.scratchTape))
    }

    @Test func leftoversAreRefusedThenDeleted() async throws {
        let (device, _) = Self.device()
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = await Self.run(device, in: workspace)
        _ = try await device.write(LevelTwo.Content.preset, to: LevelTwo.presets[1])

        let plan = await LevelTwo.plan(for: device)
        #expect(plan.leftovers == [LevelTwo.scratchTape, LevelTwo.longTape, LevelTwo.presets[1]])
        #expect(plan.refusal?.hasPrefix("FieldCheck's content from an earlier run is on the OP-1") == true)

        let result = await LevelTwo.deleteLeftovers(on: device)
        #expect(result.expectation == "delete.files-then-folder")
        #expect(result.outcome == .pass, "\(result.summary)")
        #expect(result.summary == "Deleted fieldck #1-2's 5 files and fieldck #2-13's 5 files, each tape's files and then "
                + "its folder, and they're gone.")
        #expect(await LevelTwo.plan(for: device).refusal == nil)
        #expect(await LevelTwo.deleteLeftovers(on: device).outcome == .notRun)
    }

    // MARK: Stopping

    @Test func stopsAtTheFirstFailureAndLeavesWhatItMade() async throws {
        let (device, _) = Self.device([.corruptStored(name: "track_2.wav")])
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let report = await Self.run(device, in: workspace)
        let outcomes = report.results.map(\.outcome)
        // The long tape is filled first, in names.maximum, so that's where the bad track shows.
        #expect(outcomes == [.fail] + Array(repeating: .notRun, count: 10))
        #expect(report.results[0].summary.contains("track_2.wav"))
        #expect(report.results[1].summary == "Not run: names.maximum failed first, so the run stopped. What it made is left for cleanup.")
        #expect(try await device.fileExists(at: LevelTwo.scratchTape))
        for path in LevelTwo.presets { #expect(try await !device.fileExists(at: path)) }
    }

    // MARK: Judging

    @Test func judgesWhatTheOP1Did() async throws {
        #expect(LevelTwo.refusedName(responseCode: nil).outcome == .fail)
        #expect(LevelTwo.refusedName(responseCode: 0x2005).outcome == .fail)
        #expect(LevelTwo.rebuiltJSON(written: Data("a".utf8), read: Data("a".utf8)).outcome == .fail)
        #expect(LevelTwo.staleSize(written: 10, listed: 10, read: 10).outcome == .pass)
        #expect(LevelTwo.staleSize(written: 10, listed: 12, read: 10).outcome == .fail)
        #expect(LevelTwo.folder(format: PTPObjectFormat.association, associationType: 0, contents: 0).outcome == .fail)
        let finding = LevelTwo.freeSpace(before: 1_000, afterWrites: 400, afterCleanup: 700, tapeBytes: 300, presetBytes: 300)
        #expect(finding.summary == "Free space fell 600 bytes for 600 written, and after the presets were deleted it was 300 "
                + "below the start, for the tapes' 300.")
        #expect(finding.varies == ["before", "afterWrites", "afterCleanup"])

        let empty = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 0)
        let side = try await FieldDevice.simulated().album().b
        let tone = LevelTwo.Content.side
        #expect(LevelTwo.albumExact(side: side, tone: tone, read: Data("x".utf8), original: empty, copy: empty, restored: empty).summary
                == "mixdown/side_b.wav read back as 1 bytes that don't match the 352,844 written. It was put back from the copy, "
                + "and reads back as it was.")
        #expect(LevelTwo.albumExact(side: side, tone: tone, read: Data("x".utf8), original: empty, copy: empty, restored: nil).outcome == .fail)
        #expect(LevelTwo.albumExact(side: side, tone: tone, read: tone, original: empty, copy: Data(count: 45), restored: nil).outcome == .fail)
        let pass = LevelTwo.albumExact(side: side, tone: tone, read: tone, original: empty, copy: empty, restored: nil)
        #expect(pass.outcome == .pass && pass.varies == ["side", "copy"])
    }

    @Test func writeSpeedIsTheWriteLessItsRead() {
        let writes = [LevelTwo.TimedWrite(name: "track_1.wav", bytes: 700_000, write: .milliseconds(300), read: .milliseconds(100)),
                      LevelTwo.TimedWrite(name: "track_2.wav", bytes: 1_400_000, write: .milliseconds(500), read: .milliseconds(300)),
                      LevelTwo.TimedWrite(name: "tiny", bytes: 10, write: .milliseconds(5), read: .milliseconds(9))]
        #expect(writes[2].send == .zero)
        let finding = LevelTwo.writeSpeed(writes)
        #expect(finding.outcome == .pass)
        #expect(finding.summary == "Sent 2.1 MB in 3 writes in 0.4 s, 5.2 MB/s, timed as each write less a read of the same "
                + "file. On 1.7.3 the probe saw about 7 MB/s.")
        guard case .record(let observed) = finding.observed else { Issue.record("No observations"); return }
        #expect(observed["kilobytesPerSecond"] == 5_250)
        let long = LevelTwo.writeSpeed([writes[0], LevelTwo.TimedWrite(name: "long", bytes: 127_000_000, write: .seconds(24),
                                                                       read: .seconds(6))])
        #expect(long.summary.contains(" long alone: 7.1 MB/s."))
    }
}
