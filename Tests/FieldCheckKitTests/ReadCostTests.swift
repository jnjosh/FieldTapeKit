import Foundation
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct ReadCostTests {
    /// What 2026-11-13 measured in order: 110 ms plus 56 ms for each MiB of offset.
    static let forward = (0..<16).map { 110 + 56 * $0 }

    @Test func aCostFromTheOffsetStillRisesWithTheOffsetInReverse() {
        #expect(LevelOne.costGrowth(forward: Self.forward, reverseByOffset: Self.forward) == "offset")
    }

    @Test func aCostPerReadFallsWithTheOffsetInReverse() {
        // Read last chunk first, so the chunk at offset 0 is the 16th read, and the slowest.
        let reverse = (0..<16).map { 110 + 56 * (15 - $0) }
        #expect(LevelOne.costGrowth(forward: Self.forward, reverseByOffset: reverse) == "requests")
    }

    @Test func flatTimesAreNeither() {
        let flat = Array(repeating: 530, count: 16)
        #expect(LevelOne.costGrowth(forward: flat, reverseByOffset: flat) == "neither")
    }

    @Test func anythingElseIsUnclear() {
        let flat = Array(repeating: 530, count: 16)
        #expect(LevelOne.costGrowth(forward: Self.forward, reverseByOffset: flat) == "unclear")
        #expect(LevelOne.costGrowth(forward: Self.forward.reversed(), reverseByOffset: Self.forward) == "unclear")
        #expect(LevelOne.costGrowth(forward: [1, 2], reverseByOffset: [1, 2]) == "unclear")
    }

    // MARK: The finding

    static let file = CatalogEntry(handle: 0, path: "tapes/a/track_1.wav", name: "track_1.wav", isFolder: false,
                                   format: 0x3008, size: 6 << 20)
    static let chunks = (0..<4).map { Data(repeating: UInt8($0), count: 1 << 20) }

    static func sample(times: [Int]) -> ReadSample {
        ReadSample(file: file, chunks: chunks, elapsed: .milliseconds(times.reduce(0, +)),
                   chunkTimes: times.map { .milliseconds($0) })
    }

    static func reads(reverseTimes: [Int], whole: Data? = nil) -> LevelOne.CostReads {
        let all = chunks.reduce(into: Data()) { $0.append($1) }
        return LevelOne.CostReads(
            reverse: (0..<4).reversed().map { ($0 << 20, chunks[$0], .milliseconds(reverseTimes[$0])) },
            single: (all, .milliseconds(250)),
            whole: (whole ?? all + Data(count: 2 << 20), .milliseconds(300)))
    }

    @Test func reportsWhatTheCostGrowsWithAndEveryTime() {
        let times = [100, 160, 220, 280]
        let result = LevelOne.readCost(Self.sample(times: times), Self.reads(reverseTimes: times))
        #expect(result.outcome == .pass)
        #expect(result.summary == "The time grows with the offset, not the number of reads: in order about 60 ms more "
                + "per MiB of offset, in reverse about 60 ms. One 4.2 MB read took 0.25 s, 16.8 MB/s. "
                + "One GetObject of the whole 6.3 MB file took 0.30 s, 21.0 MB/s.")
        guard case .record(let observed) = result.observed else { Issue.record("no observation"); return }
        #expect(observed["costGrowsWith"] == "offset")
        #expect(observed["reverseMilliseconds"] == [100, 160, 220, 280])
        #expect(observed["wholeFileBytes"] == .int(6 << 20))
        #expect(result.varies.contains("wholeFileMilliseconds"))
        #expect(!result.varies.contains("costGrowsWith"))
    }

    @Test func differentBytesFail() {
        let times = [100, 100, 100, 100]
        let short = LevelOne.readCost(Self.sample(times: times), Self.reads(reverseTimes: times, whole: Data(count: 10)))
        #expect(short.outcome == .fail)
        #expect(short.summary == "Reading tapes/a/track_1.wav: GetObject returned 10 bytes, not 6291456.")

        let wrong = LevelOne.readCost(Self.sample(times: times),
                                      Self.reads(reverseTimes: times, whole: Data(repeating: 9, count: 6 << 20)))
        #expect(wrong.summary.contains("GetObject's first 4194304 bytes differ from the chunks"))
    }

    // MARK: On the simulated OP-1

    @Test func runsOnASimulatedOP1() async throws {
        // About 5.3 MB of audio on side A, so six chunks.
        let device = FieldDevice.simulated { Directory("mixdown") { File("side_a.wav", seconds: 30) } }
        let result = try await LevelOneTests.run("read.cost", on: device)
        #expect(result.outcome == .pass, "\(result.summary)")
        guard case .record(let observed) = result.observed else { Issue.record("no observation"); return }
        #expect(observed["problems"] == [])
        #expect(observed["wholeFileBytes"] == .int(44 + 30 * 44_100 * 4))
        #expect(observed["reverseMilliseconds"]?.isList == true)
    }

    @Test func aShortFileIsTooShortToTell() async throws {
        let device = FieldDevice.simulated { Directory("mixdown") { File("side_a.wav", seconds: 5) } }
        let result = try await LevelOneTests.run("read.cost", on: device)
        #expect(result.outcome == .notRun)
        #expect(result.summary == "The largest audio file is under 4 MiB, too short to tell.")
    }
}
