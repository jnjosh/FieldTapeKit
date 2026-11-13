import FieldTapeKit
import Foundation

/// The result of checking one expectation on a connected OP-1 (ADR 0003, section 4).
public struct CheckResult: Sendable, Hashable, Codable {
    /// Until baselines exist, a check judges the behavior FieldTapeKit relies on, as its expectation states it.
    /// Comparing with a baseline, and the `changed` result that comes with it, is step 22 of the plan.
    public enum Outcome: String, Sendable, Hashable, Codable {
        case pass
        case fail
        case notRun = "not run"
    }

    /// The expectation's stable ID, such as `device.operations`.
    public let expectation: String
    public let outcome: Outcome
    /// One line on what was seen, or why the check didn't run.
    public let summary: String
    /// What the check observed, for the baseline. Nil when it didn't run, or failed before seeing anything.
    public let observed: CheckValue?

    public init(expectation: String, outcome: Outcome, summary: String, observed: CheckValue? = nil) {
        self.expectation = expectation
        self.outcome = outcome
        self.summary = summary
        self.observed = observed
    }
}

/// What a check found, before the runner attaches its expectation's ID.
struct Finding: Sendable, Hashable {
    let outcome: CheckResult.Outcome
    let summary: String
    let observed: CheckValue?

    static func pass(_ summary: String, observed: CheckValue? = nil) -> Finding {
        Finding(outcome: .pass, summary: summary, observed: observed)
    }

    static func fail(_ summary: String, observed: CheckValue? = nil) -> Finding {
        Finding(outcome: .fail, summary: summary, observed: observed)
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
/// A check that throws fails, with the error as its summary, and the run goes on: every level 1 check only
/// reads. Once the OP-1 disconnects, or the run is cancelled, the checks left are reported as not run, so a
/// report always has a result for every check it was given.
enum CheckRunner {
    static let cancelled = "The run was cancelled."

    static func run(_ checks: [Check]) async -> [CheckResult] {
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
            } catch is CancellationError {
                stopped = cancelled
                finding = .notRun(cancelled)
            } catch let error as FieldError where error.code == .disconnected {
                stopped = "The OP-1 disconnected."
                finding = .fail("The OP-1 disconnected during this check.")
            } catch {
                finding = .fail(Self.describe(error))
            }
            results.append(CheckResult(expectation: check.expectation, outcome: finding.outcome,
                                       summary: finding.summary, observed: finding.observed))
        }
        return results
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? FieldError, let description = error.errorDescription {
            return "Couldn't check: \(description)"
        }
        return "Couldn't check: \(error)"
    }
}
