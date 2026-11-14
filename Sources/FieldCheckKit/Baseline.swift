import Foundation

/// What one firmware did on every check, kept in the repository as `firmware/<version>/baseline.json`
/// (ADR 0003, section 4).
///
/// It's made from a run with no failures, and holds only what the firmware decides: what each check observed,
/// and which of those fields vary between runs. It leaves out the serial number, because a baseline belongs to a
/// firmware, not to one OP-1. A new firmware gets a baseline of its own next to the others, and none replaces
/// another. It covers level 1 for now; levels 2 and 3 add their checks in steps 11 and 12 of the plan.
public struct Baseline: Sendable, Hashable, Codable {
    /// Raised when the JSON changes shape.
    public static let currentFormat = 1

    /// What one check found.
    public struct Entry: Sendable, Hashable, Codable {
        /// Nil when the check didn't run.
        public let observed: CheckValue?
        /// The fields of `observed` whose values a comparison leaves out (`CheckResult.varies`).
        public let varies: [String]
        /// Why the check didn't run, such as an OP-1 with no tapes.
        public let notObserved: String?
    }

    /// The run it came from.
    public struct Source: Sendable, Hashable, Codable {
        public let started: Date
        public let level: Int
        public let model: String
        public let host: CheckReport.Host
    }

    public let format: Int
    public let firmware: String
    public let source: Source
    /// By expectation ID.
    public let expectations: [String: Entry]

    public enum Refusal: Error, Equatable, LocalizedError {
        /// The run had failures, listed by expectation ID.
        case failures([String])

        public var errorDescription: String? {
            switch self {
            case .failures(let ids):
                "A run with failures can't be a baseline. Failed: \(ids.joined(separator: ", "))."
            }
        }
    }

    /// The baseline for the run's firmware.
    ///
    /// - Throws: `Refusal.failures` if any check failed.
    public init(report: CheckReport) throws(Refusal) {
        let failed = report.results.filter { $0.outcome == .fail }.map(\.expectation)
        guard failed.isEmpty else { throw .failures(failed) }
        format = Self.currentFormat
        firmware = report.device.firmware
        source = Source(started: report.started, level: report.level, model: report.device.model, host: report.host)
        expectations = Dictionary(uniqueKeysWithValues: report.results.map { result in
            (result.expectation, result.outcome == .pass
                ? Entry(observed: result.observed, varies: result.varies, notObserved: nil)
                : Entry(observed: nil, varies: [], notObserved: result.summary))
        })
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
