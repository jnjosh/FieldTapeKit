import FieldTapeConformance
import FieldTapeKit
import Foundation
import Testing

/// The conformance suite against the simulator. FieldCheck runs the same checks against a real OP-1.
@Suite struct SimulatorConformanceTests {
    /// A 1.7.3 OP-1 with no tapes, as `FieldDevice.simulated()` starts.
    static let empty = FieldDevice.simulated()

    /// One with a tape, a recorded track, and audio on side A.
    static let populated = FieldDevice.simulated {
        SimulatedTape("2026-220#02", type: .vintage, seconds: [2])
        Directory("tapes") {
            // Not sound: its tape.json has no clips for the recorded track.
            Directory("2026-286#01") {
                File("tape.json", data: Data(#"{"clips":[]}"#.utf8))
                File("track_1.wav", seconds: 1)
                for track in 2...4 { File("track_\(track).wav", seconds: 0) }
            }
        }
        Directory("mixdown") { File("side_a.wav", seconds: 1) }
    }

    /// Checks that need a tape, or a tape track with audio, skip on the empty OP-1.
    static let needTapes: Set = ["A tape's tape.json is JSON and its tracks are WAV files", "A tape's details agree with its files",
                                 "Copying the largest tape track off matches the OP-1"]

    static func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Conformance-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func run(_ name: String, on device: FieldDevice) async throws -> Conformance.Result {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let check = try #require(Conformance.checks.first { $0.name == name })
        return await check.run(on: device, workspace: workspace)
    }

    @Test(arguments: Conformance.checks.map(\.name))
    func onAnEmptyOP1(check name: String) async throws {
        let result = try await Self.run(name, on: Self.empty)
        switch result.outcome {
        case .pass: #expect(!Self.needTapes.contains(name), "passed without tapes")
        case .skipped(let reason): #expect(Self.needTapes.contains(name), "skipped: \(reason)")
        case .fail(let message): Issue.record("\(name): \(message)")
        }
    }

    @Test(arguments: Conformance.checks.map(\.name))
    func onAPopulatedOP1(check name: String) async throws {
        let result = try await Self.run(name, on: Self.populated)
        #expect(result.outcome == .pass, "\(name): \(result.outcome)")
    }

    @Test func runsEveryCheckInOrder() async throws {
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let results = await Conformance.run(on: Self.empty, workspace: workspace)
        #expect(results.map(\.name) == Conformance.checks.map(\.name))
        #expect(Set(Conformance.checks.map(\.name)).count == Conformance.checks.count)
    }

    @Test func keepsOneCopyOfEachFileAndSaysItsSHA256() async throws {
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let results = await Conformance.run(on: Self.populated, workspace: workspace)
        let copies = try FileManager.default.contentsOfDirectory(atPath: workspace.path(percentEncoded: false)).sorted()
        #expect(copies == ["2026-220#02 track_1.wav", "side_a.wav"])

        let side = try #require(results.first { $0.name == "Copying album side A off matches the OP-1" })
        let detail = try #require(side.detail)
        #expect(detail.hasPrefix("mixdown/side_a.wav: \(44 + 44_100 * 4) bytes, SHA-256 "))
        #expect(detail.hasSuffix(", copied to side_a.wav"))
    }

    @Test func aFailureSaysWhatWasWrong() async throws {
        // An OP-1 whose side A is a folder.
        let broken = FieldDevice.simulated { Directory("mixdown") { Directory("side_a.wav") } }
        let workspace = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let results = Dictionary(uniqueKeysWithValues: await Conformance.run(on: broken, workspace: workspace)
            .map { ($0.name, $0.outcome) })
        #expect(results["The album sides are WAV files, and the readmes text"] == .fail("mixdown/side_a.wav isn't a WAV file"))
        #expect(results["The root holds the four well-known folders"] == .pass)
    }
}
