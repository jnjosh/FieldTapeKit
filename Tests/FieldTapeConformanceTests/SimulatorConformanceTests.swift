import FieldTapeConformance
import FieldTapeKit
import Foundation
import Testing

/// The conformance suite against the simulator. FieldCheck runs the same checks against a real OP-1.
@Suite struct SimulatorConformanceTests {
    /// A 1.7.3 OP-1 with no tapes, as `FieldDevice.simulated()` starts.
    static let empty = FieldDevice.simulated()

    /// One with a tape and audio on side A.
    static let populated = FieldDevice.simulated {
        Directory("tapes") {
            Directory("2026-220#02") {
                File("tape.json", data: Data(#"{"clips":[]}"#.utf8))
                for track in 1...4 { File("track_\(track).wav", seconds: 0) }
            }
        }
        Directory("mixdown") { File("side_a.wav", seconds: 1) }
    }

    @Test(arguments: Conformance.checks.map(\.name))
    func onAnEmptyOP1(check name: String) async throws {
        let result = await Conformance.checks.first { $0.name == name }!.run(on: Self.empty)
        switch result.outcome {
        case .pass: break
        case .skipped(let reason): #expect(name.hasPrefix("A tape's"), "skipped: \(reason)")
        case .fail(let message): Issue.record("\(name): \(message)")
        }
    }

    @Test(arguments: Conformance.checks.map(\.name))
    func onAPopulatedOP1(check name: String) async throws {
        let result = await Conformance.checks.first { $0.name == name }!.run(on: Self.populated)
        #expect(result.outcome == .pass, "\(name)")
    }

    @Test func runsEveryCheckInOrder() async {
        let results = await Conformance.run(on: Self.empty)
        #expect(results.map(\.name) == Conformance.checks.map(\.name))
        #expect(Set(Conformance.checks.map(\.name)).count == Conformance.checks.count)
    }

    @Test func aFailureSaysWhatWasWrong() async {
        // An OP-1 whose side A is a folder.
        let broken = FieldDevice.simulated { Directory("mixdown") { Directory("side_a.wav") } }
        let results = Dictionary(uniqueKeysWithValues: await Conformance.run(on: broken).map { ($0.name, $0.outcome) })
        #expect(results["The album sides are WAV files, and the readmes text"] == .fail("mixdown/side_a.wav isn't a WAV file"))
        #expect(results["The root holds the four well-known folders"] == .pass)
    }
}
