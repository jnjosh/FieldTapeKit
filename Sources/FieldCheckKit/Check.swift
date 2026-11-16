import FieldTapeKit
import Foundation

/// The result of checking one expectation on a connected OP-1 (ADR 0003, section 4).
public struct CheckResult: Sendable, Hashable, Codable {
    /// A check judges the behavior FieldTapeKit relies on, as its expectation states it: pass, fail or not run.
    /// Comparing the report with a baseline turns a pass that observed something else into `changed`
    /// (ADR 0003, section 4).
    public enum Outcome: String, Sendable, Hashable, Codable {
        case pass
        /// It works, but differs from the baseline: `differences` says how.
        case changed
        case fail
        case notRun = "not run"
    }

    /// One way a result differs from its baseline, with the compatibility class FieldCheck suggests for it
    /// (ADR 0003, section 5).
    public struct Difference: Sendable, Hashable, Codable {
        public enum Class: String, Sendable, Hashable, Codable {
            /// Something new appeared alongside what was there.
            case additive
            /// A value changed or disappeared.
            case divergent
        }

        /// Keys separated by dots, with `[]` for a list's elements, as in `varies`. Empty for the whole value.
        public let path: String
        /// Nil if the baseline didn't have it.
        public let old: CheckValue?
        /// Nil if this run didn't have it.
        public let new: CheckValue?
        public let suggested: Class
    }

    /// The expectation's stable ID, such as `device.operations`.
    public let expectation: String
    public let outcome: Outcome
    /// One line on what was seen, or why the check didn't run.
    public let summary: String
    /// What the check observed, for the baseline. Nil when it didn't run, or failed before seeing anything.
    public let observed: CheckValue?
    /// The fields of `observed` expected to change from run to run, such as free space or read speed, so a
    /// comparison with a baseline leaves their values out. Each is a path of keys, with `[]` for every element of
    /// a list, such as `storages[].freeSpace`. Ranges for them come with the comparison, in step 22 of the plan.
    public let varies: [String]
    /// The summary of a check the OP-1 stopped answering during. It fails, since the check couldn't see the
    /// behavior, but it says nothing about the firmware, so it gets no draft ADR.
    public static let disconnected = "The OP-1 disconnected during this check."

    /// Whether the check failed only because the OP-1 stopped answering.
    public var stoppedAnswering: Bool { outcome == .fail && summary == Self.disconnected }

    /// How a `changed` result differs from its baseline. Empty otherwise.
    public let differences: [Difference]
    /// What the comparison found worth saying about a result that isn't changed, such as a check the baseline
    /// doesn't have.
    public let baselineNote: String?

    public init(expectation: String, outcome: Outcome, summary: String, observed: CheckValue? = nil,
                varies: [String] = [], differences: [Difference] = [], baselineNote: String? = nil) {
        self.expectation = expectation
        self.outcome = outcome
        self.summary = summary
        self.observed = observed
        self.varies = varies
        self.differences = differences
        self.baselineNote = baselineNote
    }

    private enum CodingKeys: String, CodingKey {
        case expectation, outcome, summary, observed, varies, differences, baselineNote
    }

    /// Reports from before `varies` existed have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectation = try container.decode(String.self, forKey: .expectation)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        summary = try container.decode(String.self, forKey: .summary)
        observed = try container.decodeIfPresent(CheckValue.self, forKey: .observed)
        varies = try container.decodeIfPresent([String].self, forKey: .varies) ?? []
        differences = try container.decodeIfPresent([Difference].self, forKey: .differences) ?? []
        baselineNote = try container.decodeIfPresent(String.self, forKey: .baselineNote)
    }

    /// Leaves out the comparison's fields when they're empty, so a report that wasn't compared reads as before.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectation, forKey: .expectation)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(observed, forKey: .observed)
        try container.encode(varies, forKey: .varies)
        if !differences.isEmpty { try container.encode(differences, forKey: .differences) }
        try container.encodeIfPresent(baselineNote, forKey: .baselineNote)
    }
}

/// What a check found, before the runner attaches its expectation's ID.
struct Finding: Sendable, Hashable {
    let outcome: CheckResult.Outcome
    let summary: String
    let observed: CheckValue?
    var varies: [String] = []

    static func pass(_ summary: String, observed: CheckValue? = nil, varies: [String] = []) -> Finding {
        Finding(outcome: .pass, summary: summary, observed: observed, varies: varies)
    }

    static func fail(_ summary: String, observed: CheckValue? = nil, varies: [String] = []) -> Finding {
        Finding(outcome: .fail, summary: summary, observed: observed, varies: varies)
    }

    static func notRun(_ reason: String) -> Finding {
        Finding(outcome: .notRun, summary: reason, observed: nil)
    }
}

/// One check: a plain async function that looks at the OP-1 and returns one finding for one expectation
/// (ADR 0003, section 6). It has no UI, so it can be tested against recorded device replies.
struct Check: Sendable {
    let expectation: String
    let body: @Sendable () async throws -> Finding

    init(_ expectation: String, _ body: @escaping @Sendable () async throws -> Finding) {
        precondition(Expectation[id: expectation] != nil, "\(expectation) isn't in the expectation list")
        self.expectation = expectation
        self.body = body
    }
}

/// Runs checks one after another, in order.
///
/// A check that throws fails, with the error as its summary, and the run goes on, since every level 1 check only
/// reads. Level 2 writes, so it stops at its first failure, and the checks after it are reported as not run. Once the OP-1 disconnects, or the run is cancelled, the checks left are reported as not run, so a
/// report always has a result for every check it was given.
enum CheckRunner {
    static let cancelled = "The run was cancelled."

    static func run(_ checks: [Check], stopAtFirstFailure: Bool = false) async -> [CheckResult] {
        var results: [CheckResult] = []
        var stopped: String?
        for check in checks {
            if stopped == nil, Task.isCancelled { stopped = cancelled }
            if let stopped {
                results.append(CheckResult(expectation: check.expectation, outcome: .notRun, summary: stopped))
                continue
            }
            let finding: Finding
            do {
                finding = try await check.body()
            } catch {
                // Checks use the MTP layer directly, so its errors are turned into FieldErrors here.
                switch FieldError.wrapping(error) {
                case is CancellationError:
                    stopped = cancelled
                    finding = .notRun(cancelled)
                case let error as FieldError where error.code == .disconnected:
                    stopped = "The OP-1 disconnected."
                    finding = .fail(CheckResult.disconnected)
                case let error:
                    finding = .fail(Self.describe(error))
                }
            }
            results.append(CheckResult(expectation: check.expectation, outcome: finding.outcome,
                                       summary: finding.summary, observed: finding.observed, varies: finding.varies))
            if stopAtFirstFailure, stopped == nil, finding.outcome == .fail {
                stopped = "Not run: \(check.expectation) failed first, so the run stopped. What it made is left for cleanup."
            }
        }
        return results
    }

    /// The error's description, and what went wrong underneath when that isn't a plain refusal or timeout,
    /// such as a dataset that couldn't be parsed.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? FieldError, let description = error.errorDescription else {
            return "Couldn't check: \(error)"
        }
        guard let underlying = error.underlying, error.responseCode == nil, error.code == .deviceRefused else {
            return "Couldn't check: \(description)"
        }
        return "Couldn't check: \(description) (\(underlying))"
    }
}
