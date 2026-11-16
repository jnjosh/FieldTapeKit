import Foundation

/// What one firmware did on every check, kept in the repository as `firmware/<version>/baseline.json`
/// (ADR 0003, section 4).
///
/// It's made from runs with no failures, one per level, and holds only what the firmware decides: what each check
/// observed, and which of those fields vary between runs. Each level has its own section, because an expectation can
/// be checked at two levels with different fields, such as `device.storage` at levels 1 and 2. It leaves out the
/// serial number, because a baseline belongs to a firmware, not to one OP-1. A new firmware gets a baseline of its
/// own next to the others, and none replaces another.
public struct Baseline: Sendable, Hashable, Codable {
    /// Raised when the JSON changes shape. Format 1 had one level, at the top; format 2 has a section per level.
    public static let currentFormat = 2

    /// What one check found.
    public struct Entry: Sendable, Hashable, Codable {
        /// Nil when the check didn't run.
        public let observed: CheckValue?
        /// The fields of `observed` whose values a comparison leaves out (`CheckResult.varies`).
        public let varies: [String]
        /// Why the check didn't run, such as an OP-1 with no tapes.
        public let notObserved: String?
    }

    /// The run a level came from.
    public struct Source: Sendable, Hashable, Codable {
        public let started: Date
        public let level: Int
        public let model: String
        public let host: CheckReport.Host
    }

    /// One level's checks.
    public struct Level: Sendable, Hashable, Codable {
        public let source: Source
        /// By expectation ID.
        public let expectations: [String: Entry]
    }

    public let format: Int
    public let firmware: String
    /// In level order.
    public let levels: [Level]

    /// The section for a level, or nil if the baseline doesn't cover it.
    public subscript(level level: Int) -> Level? {
        levels.first { $0.source.level == level }
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case noReports
        /// A level's run had failures, listed by expectation ID.
        case failures(level: Int, [String])
        /// The runs are from different firmwares.
        case mixedFirmware([String])
        /// Two runs are of the same level.
        case repeatedLevel(Int)

        public var errorDescription: String? {
            switch self {
            case .noReports:
                "A baseline needs at least one run."
            case .failures(let level, let ids):
                "A run with failures can't be a baseline. Level \(level) failed: \(ids.joined(separator: ", "))."
            case .mixedFirmware(let versions):
                "A baseline is for one firmware, and these runs are from \(versions.joined(separator: " and "))."
            case .repeatedLevel(let level):
                "A baseline takes one run of each level, and there are two of level \(level)."
            }
        }
    }

    /// The baseline for one run's firmware, covering its level.
    ///
    /// - Throws: `Refusal.failures` if any check failed.
    public init(report: CheckReport) throws(Refusal) {
        try self.init(reports: [report])
    }

    /// The baseline for the runs' firmware, one section per run, in level order.
    ///
    /// - Throws: `Refusal` if there are no runs, any check failed, the firmwares differ, or two runs are of the
    ///   same level.
    public init(reports: [CheckReport]) throws(Refusal) {
        guard let first = reports.first else { throw .noReports }
        let versions = Set(reports.map(\.device.firmware))
        guard versions.count == 1 else { throw .mixedFirmware(versions.sorted()) }
        var seen: Set<Int> = []
        for report in reports.sorted(by: { $0.level < $1.level }) {
            guard seen.insert(report.level).inserted else { throw .repeatedLevel(report.level) }
            let failed = report.results.filter { $0.outcome == .fail }.map(\.expectation)
            guard failed.isEmpty else { throw .failures(level: report.level, failed) }
        }
        format = Self.currentFormat
        firmware = first.device.firmware
        levels = reports.sorted { $0.level < $1.level }.map { report in
            Level(source: Source(started: report.started, level: report.level, model: report.device.model, host: report.host),
                  expectations: Dictionary(uniqueKeysWithValues: report.results.map { result in
                      // A changed result is what this firmware does now, once a person has reviewed it.
                      (result.expectation, result.outcome == .pass || result.outcome == .changed
                          ? Entry(observed: result.observed, varies: result.varies, notObserved: nil)
                          : Entry(observed: nil, varies: [], notObserved: result.summary))
                  }))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format, firmware, levels
        // Format 1's single level.
        case source, expectations
    }

    /// Reads format 2, and format 1 as a baseline with one level.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firmware = try container.decode(String.self, forKey: .firmware)
        switch try container.decode(Int.self, forKey: .format) {
        case 1:
            levels = [Level(source: try container.decode(Source.self, forKey: .source),
                            expectations: try container.decode([String: Entry].self, forKey: .expectations))]
        case 2:
            levels = try container.decode([Level].self, forKey: .levels)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .format, in: container,
                                                   debugDescription: "Baseline format \(other) is newer than this FieldCheck")
        }
        format = Self.currentFormat
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(firmware, forKey: .firmware)
        try container.encode(levels, forKey: .levels)
    }

    public func jsonData() throws -> Data {
        try ReportFiles.encoder().encode(self)
    }

    public init(json: Data) throws {
        self = try ReportFiles.decoder().decode(Self.self, from: json)
    }

    /// Writes `baseline-<firmware>.json` into `directory`, never overwriting a file: if the name is taken, it gets
    /// a number, such as `baseline-1.7.3-2.json`. Commit it as `firmware/<firmware>/baseline.json`.
    @discardableResult
    public func save(in directory: URL) throws -> URL {
        try ReportFiles.write([("json", try jsonData())], named: "baseline-\(firmware)", in: directory)[0]
    }
}

extension CheckValue {
    /// The values at a `varies` path, such as `storages[].freeSpace`: keys separated by dots, with `[]` for every
    /// element of a list. Empty when nothing is there.
    func values(at path: String) -> [CheckValue] {
        var current = [self]
        for part in path.split(separator: ".") {
            let eachElement = part.hasSuffix("[]")
            let key = String(eachElement ? part.dropLast(2) : part)
            current = current.compactMap { value in
                guard case .record(let fields) = value else { return nil }
                return fields[key]
            }
            if eachElement {
                current = current.flatMap { value -> [CheckValue] in
                    guard case .list(let elements) = value else { return [] }
                    return elements
                }
            }
        }
        return current
    }
}
