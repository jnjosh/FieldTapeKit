import Foundation

extension CheckReport {
    /// The report with each result judged against `baseline`'s section for its level (ADR 0003, section 4):
    /// - A fail stays a fail, and a check that didn't run stays not run.
    /// - A pass whose observed values differ from the baseline's becomes `changed`, with its differences. Fields
    ///   either side marks as varying are left out.
    /// - A pass the baseline has no value for stays a pass, with a note: a check newer than the baseline, or one it
    ///   didn't run.
    ///
    /// `isExact` says whether the baseline is for the OP-1's own firmware.
    public func compared(with baseline: Baseline, isExact: Bool) -> CheckReport {
        guard let section = baseline[level: level] else {
            return CheckReport(self, results: results, comparison: Comparison(firmware: baseline.firmware, isExact: isExact,
                                                                              levelStarted: nil))
        }
        let compared = results.map { result -> CheckResult in
            guard result.outcome == .pass else { return result }
            func noted(_ note: String) -> CheckResult {
                CheckResult(expectation: result.expectation, outcome: .pass, summary: result.summary, observed: result.observed,
                            varies: result.varies, baselineNote: note)
            }
            guard let entry = section.expectations[result.expectation] else {
                return noted("The baseline for \(baseline.firmware) has no result for this check, which is newer than it.")
            }
            guard let old = entry.observed else {
                return noted("The baseline for \(baseline.firmware) didn't run this check: \(entry.notObserved ?? "no reason given")")
            }
            let differences = Self.differences(old, result.observed, path: "", ignoring: Set(entry.varies + result.varies))
            guard !differences.isEmpty else { return result }
            return CheckResult(expectation: result.expectation, outcome: .changed, summary: result.summary,
                               observed: result.observed, varies: result.varies, differences: differences)
        }
        return CheckReport(self, results: compared, comparison: Comparison(firmware: baseline.firmware, isExact: isExact,
                                                                           levelStarted: section.source.started))
    }

    /// Where `old` and `new` differ, leaving out `ignoring`'s paths. Records are compared key by key, and a list
    /// element by element when one of its elements' fields varies and the lengths match; otherwise a list is one value.
    static func differences(_ old: CheckValue?, _ new: CheckValue?, path: String,
                            ignoring: Set<String>) -> [CheckResult.Difference] {
        guard !ignoring.contains(path), old != new else { return [] }
        switch (old, new) {
        case (.record(let before)?, .record(let after)?):
            return Set(before.keys).union(after.keys).sorted().flatMap { key in
                differences(before[key], after[key], path: path.isEmpty ? key : "\(path).\(key)", ignoring: ignoring)
            }
        case (.list(let before)?, .list(let after)?)
            where before.count == after.count && ignoring.contains(where: { $0.hasPrefix(path + "[]") }):
            return zip(before, after).flatMap { differences($0, $1, path: path + "[]", ignoring: ignoring) }
        default:
            return [CheckResult.Difference(path: path, old: old, new: new, suggested: suggestedClass(old: old, new: new))]
        }
    }

    /// Additive when only something new appeared: a value where there was none, or a list that kept every element it
    /// had and gained more. Divergent otherwise (ADR 0003, section 5).
    static func suggestedClass(old: CheckValue?, new: CheckValue?) -> CheckResult.Difference.Class {
        switch (old, new) {
        case (nil, _?):
            return .additive
        case (.list(let before)?, .list(let after)?) where after.count > before.count && before.allSatisfy(after.contains):
            return .additive
        default:
            return .divergent
        }
    }
}
