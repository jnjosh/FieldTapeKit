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

    static func device(_ faults: [SimulatedMTPDevice.Fault] = [], tapes: Int = 0) -> (FieldDevice, SimulatedMTPDevice) {
        let added: [PendingNode] = [.folder("tapes", (0..<tapes).map { .folder("2026-300#0\($0)", []) })]
        let layout = SimulatedNode.merge(added, into: SimulatedNode.layout173, path: [])
        let simulator = SimulatedMTPDevice(faults: faults, contents: layout)
        return (FieldDevice.simulated(simulator), simulator)
    }

    static func run(_ device: FieldDevice, in workspace: URL) async -> CheckReport {
        let plan = await LevelTwo.plan(for: device)
        return await LevelTwo.run(on: device, plan: plan, workspace: workspace, host: LevelOneTests.host)
    }

    // MARK: A whole run

    @Test func passesOnASimulated173AndLeavesTheScratchTape() async throws {
        let (device, simulator) = Self.device()
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let report = await Self.run(device, in: workspace)
        #expect(report.level == 2)
        #expect(report.results.map(\.expectation) == ["names.maximum", "write.folder", "write.exact", "write.refused-name",
                                                      "rebuild.tape-json", "rebuild.stale-size", "write.preset-converted",
                                                      "device.storage"])
        for result in report.results { #expect(result.outcome == .pass, "\(result.expectation): \(result.summary)") }

        // The scratch tape ends as generated, with tape.json written last.
        let names = try await device.contentsOfDirectory(at: LevelTwo.scratchTape).map(\.name)
        #expect(Set(names) == ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"])
        #expect(try await device.contents(of: LevelTwo.scratchTape.appending("tape.json")) == LevelTwo.Content.tapeJSON)
        #expect(try await device.contents(of: LevelTwo.scratchTape.appending("track_1.wav")) == LevelTwo.Content.replacement)
        for path in LevelTwo.presets { #expect(try await !device.fileExists(at: path)) }
        #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "drum-user-fieldcheck.wav").path))
        #expect(try Data(contentsOf: workspace.appending(path: "track_1.wav")) == LevelTwo.Content.tracks[0].1)
        // Only what level 2 makes was deleted: the replaced track, the stale tape.json, and the presets.
        #expect(await simulator.deleted == ["track_1.wav", "tape.json", "fieldcheck.wav", "fieldcheck.wav"])
    }

    @Test func summaries() async throws {
        let (device, _) = Self.device()
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let summaries = Dictionary(uniqueKeysWithValues: (await Self.run(device, in: workspace)).results.map { ($0.expectation, $0.summary) })
        #expect(summaries["names.maximum"] == "The OP-1 took FIELDCHECK #1-2, 15 characters, as fieldcheck #1-2. "
                + "Whether it's kept after a reconnect is level 3.")
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
        let (device, simulator) = Self.device(tapes: 8)
        let plan = await LevelTwo.plan(for: device)
        #expect(plan.refusal == "All 8 tape slots are used, and level 2 needs one for its scratch tape. Move a tape off the OP-1 first.")
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
        #expect(plan.leftovers == [LevelTwo.scratchTape, LevelTwo.presets[1]])
        #expect(plan.refusal?.hasPrefix("FieldCheck's content from an earlier run is on the OP-1") == true)

        let result = await LevelTwo.deleteLeftovers(on: device)
        #expect(result.expectation == "delete.files-then-folder")
        #expect(result.outcome == .pass, "\(result.summary)")
        #expect(result.summary == "Deleted the scratch tape's 5 files, then its folder, and it's gone.")
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
        #expect(outcomes == [.pass, .pass, .fail, .notRun, .notRun, .notRun, .notRun, .notRun])
        #expect(report.results[2].summary.contains("track_2.wav"))
        #expect(report.results[3].summary == "Not run: write.exact failed first, so the run stopped. What it made is left for cleanup.")
        #expect(try await device.fileExists(at: LevelTwo.scratchTape))
        for path in LevelTwo.presets { #expect(try await !device.fileExists(at: path)) }
    }

    // MARK: Judging

    @Test func judgesWhatTheOP1Did() {
        #expect(LevelTwo.refusedName(responseCode: nil).outcome == .fail)
        #expect(LevelTwo.refusedName(responseCode: 0x2005).outcome == .fail)
        #expect(LevelTwo.rebuiltJSON(written: Data("a".utf8), read: Data("a".utf8)).outcome == .fail)
        #expect(LevelTwo.staleSize(written: 10, listed: 10, read: 10).outcome == .pass)
        #expect(LevelTwo.staleSize(written: 10, listed: 12, read: 10).outcome == .fail)
        #expect(LevelTwo.folder(format: PTPObjectFormat.association, associationType: 0, contents: 0).outcome == .fail)
        let finding = LevelTwo.freeSpace(before: 1_000, afterWrites: 400, afterCleanup: 700, tapeBytes: 300, presetBytes: 300)
        #expect(finding.summary == "Free space fell 600 bytes for 600 written, and after the presets were deleted it was 300 "
                + "below the start, for the scratch tape's 300.")
        #expect(finding.varies == ["before", "afterWrites", "afterCleanup"])
    }
}
