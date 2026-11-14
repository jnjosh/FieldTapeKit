import FieldTapeKit
import Foundation

/// The largest tape track or album side with audio, read once from the start in 1 MiB GetPartialObject chunks,
/// up to 16 MiB, as FieldTapeKit will stream. `read.partial` and `read.speed` both use it.
struct ReadSample: Sendable {
    static let chunkSize = 1 << 20
    static let limit = 16 << 20

    let file: CatalogEntry
    let chunks: [Data]
    let elapsed: Duration
    /// How long each chunk's request took, in order. On 2026-11-13 chunks averaged 0.53 s, against 0.11–0.16 s
    /// for the first two in the probe, so these show whether the time grows with the offset.
    let chunkTimes: [Duration]

    init(file: CatalogEntry, chunks: [Data], elapsed: Duration, chunkTimes: [Duration] = []) {
        self.file = file
        self.chunks = chunks
        self.elapsed = elapsed
        self.chunkTimes = chunkTimes
    }

    var bytes: Data { chunks.reduce(into: Data()) { $0.append($1) } }
    var count: Int { chunks.reduce(0) { $0 + $1.count } }
}

actor ReadSampler {
    private let catalog: Catalog
    private var taken: ReadSample??

    init(_ catalog: Catalog) {
        self.catalog = catalog
    }

    /// Nil when there's no audio to read.
    func sample() async throws -> ReadSample? {
        if let taken { return taken }
        let entries = try await catalog.entries()
        let audio = (entries.tapes().flatMap(\.contents) + entries.children(of: "mixdown")).filter { entry in
            !entry.isFolder && entry.name.lowercased().hasSuffix(".wav") && entry.size > WAVHeader.size
        }
        guard let file = audio.max(by: { ($0.size, $1.path) < ($1.size, $0.path) }) else {
            taken = .some(nil)
            return nil
        }
        let length = min(file.size, ReadSample.limit)
        var chunks: [Data] = []
        var times: [Duration] = []
        let clock = ContinuousClock()
        let start = clock.now
        var offset = 0
        while offset < length {
            let requested = clock.now
            let chunk = try await catalog.read(file, offset: offset, length: min(ReadSample.chunkSize, length - offset))
            times.append(clock.now - requested)
            chunks.append(chunk)
            guard !chunk.isEmpty else { break }
            offset += chunk.count
        }
        let sample = ReadSample(file: file, chunks: chunks, elapsed: clock.now - start, chunkTimes: times)
        taken = .some(sample)
        return sample
    }
}

extension LevelOne {
    /// One extra read for `read.partial`, and whether it matched what the chunks already read.
    struct PartialRead: Sendable, Equatable {
        let label: String
        let offset: Int
        let length: Int
        /// The bytes it should have returned. Nil past what the sample read, where only the length is known.
        let expected: Data?
        let expectedCount: Int
        let got: Data

        var matches: Bool { got.count == expectedCount && (expected == nil || got == expected) }
    }

    /// Small reads at awkward offsets, checked against the chunks already read: one at an odd offset, one across
    /// a chunk boundary, and one that runs past the end of the file.
    static func partialReads(of sample: ReadSample, in catalog: Catalog) async throws -> [PartialRead] {
        let bytes = sample.bytes
        var plans: [(label: String, offset: Int, length: Int)] = []
        if bytes.count >= 1_001 + 16_384 { plans.append(("16 KiB at offset 1001", 1_001, 16_384)) }
        if bytes.count >= ReadSample.chunkSize + 34_000 {
            plans.append(("64 KiB across the first chunk boundary", ReadSample.chunkSize - 30_000, 65_536))
        }
        if sample.file.size > 100 { plans.append(("1 MiB from 100 bytes before the end", sample.file.size - 100, ReadSample.chunkSize)) }

        var reads: [PartialRead] = []
        for plan in plans {
            let got = try await catalog.read(sample.file, offset: plan.offset, length: plan.length)
            let expectedCount = min(plan.length, sample.file.size - plan.offset)
            let end = plan.offset + expectedCount
            let expected = end <= bytes.count ? Data(bytes[plan.offset..<end]) : nil
            reads.append(PartialRead(label: plan.label, offset: plan.offset, length: plan.length, expected: expected,
                                     expectedCount: expectedCount, got: got))
        }
        return reads
    }

    static func readPartial(_ sample: ReadSample, checks: [PartialRead]) -> Finding {
        var problems: [String] = []
        let expectedTotal = min(sample.file.size, ReadSample.limit)
        for (index, chunk) in sample.chunks.enumerated() {
            let wanted = min(ReadSample.chunkSize, expectedTotal - index * ReadSample.chunkSize)
            if chunk.count != wanted { problems.append("chunk \(index + 1) came back with \(chunk.count) bytes, not \(wanted)") }
        }
        if sample.count != expectedTotal { problems.append("the chunks held \(sample.count) bytes, not \(expectedTotal)") }
        for check in checks where !check.matches {
            problems.append(check.got.count == check.expectedCount
                            ? "\(check.label) returned different bytes"
                            : "\(check.label) returned \(check.got.count) bytes, not \(check.expectedCount)")
        }
        let observed: CheckValue = ["chunkBytes": .int(ReadSample.chunkSize),
                                    "reads": .list(checks.map { .string($0.label) }),
                                    "problems": .list(problems.map(CheckValue.string))]
        // Which reads fit depends on the size of the file read, which depends on what's on the OP-1.
        let varies = ["reads"]
        guard problems.isEmpty else {
            return .fail("Reading \(sample.file.path): \(problems.joined(separator: "; ")).", observed: observed,
                         varies: varies)
        }
        let extra = checks.isEmpty ? "" : ". Reads of \(checks.map(\.label).formatted(.list(type: .and))) matched"
        return .pass("\(sample.chunks.count) chunks of up to 1 MiB came back whole\(extra).", observed: observed,
                     varies: varies)
    }

    static func readSpeed(_ sample: ReadSample) -> Finding {
        let seconds = Double(sample.elapsed.components.seconds) + Double(sample.elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? Double(sample.count) / seconds : 0
        let chunkMilliseconds = sample.chunkTimes.map(milliseconds)
        // Whole numbers only, so a baseline round-trips exactly through CheckValue.
        let observed: CheckValue = ["bytes": .int(sample.count), "milliseconds": .int(Int((seconds * 1_000).rounded())),
                                    "kilobytesPerSecond": .int(Int((rate / 1_000).rounded())),
                                    "chunkMilliseconds": .list(chunkMilliseconds.map(CheckValue.int))]
        let megabytes = (Double(sample.count) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        let speed = (rate / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        let time = seconds.formatted(.number.precision(.fractionLength(2)))
        var chunks = ""
        if let first = chunkMilliseconds.first, let last = chunkMilliseconds.last, chunkMilliseconds.count >= 2 {
            chunks = " The first chunk took \(first) ms and the last \(last) ms"
            if let slope = slope(chunkMilliseconds) {
                chunks += ", about \(slope) ms more for each MiB of offset"
            }
            chunks += "."
        }
        // A big drop is reported, not failed (ADR 0003). The baseline gives the range to compare with.
        // All of it varies: timings from run to run, and how much is read with the largest file on the OP-1.
        return .pass("Read \(megabytes) MB in 1 MiB chunks in \(time) s, \(speed) MB/s.\(chunks) On 1.7.3 the probe "
                     + "saw 1 MiB chunks at 6.5–9.5 MB/s and whole files at about 20 MB/s.", observed: observed,
                     varies: ["bytes", "milliseconds", "kilobytesPerSecond", "chunkMilliseconds"])
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int((Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15).rounded())
    }

    /// The least-squares slope of chunk time against chunk number, so how much each MiB of offset adds, rounded to
    /// whole milliseconds. Nil with fewer than four chunks, where a slope means little.
    static func slope(_ values: [Int]) -> Int? {
        guard values.count >= 4 else { return nil }
        let n = Double(values.count)
        let meanX = (n - 1) / 2
        let meanY = Double(values.reduce(0, +)) / n
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in values.enumerated() {
            covariance += (Double(x) - meanX) * (Double(y) - meanY)
            variance += (Double(x) - meanX) * (Double(x) - meanX)
        }
        return Int((covariance / variance).rounded())
    }
}
