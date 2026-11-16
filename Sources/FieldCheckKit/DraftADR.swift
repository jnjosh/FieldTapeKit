import FieldTapeKit
import Foundation

extension CheckReport {
    /// A draft ADR for a compared report's changes and failures, or nil if it has none (ADR 0003, section 5).
    ///
    /// It follows the repository's ADR template, starts as Proposed, and is numbered `NNNN`, because FieldCheck can't
    /// see the repository. It fills in what the run measured: each change and failure, its old and new values, its
    /// "used by" entry, a suggested compatibility class, and a compatibility table. Deciding is left to a person.
    public func draftADR() -> String? {
        // A check the OP-1 stopped answering during says nothing about the firmware.
        let affected = results.filter { $0.outcome == .changed || ($0.outcome == .fail && !$0.stoppedAnswering) }
        guard !affected.isEmpty else { return nil }
        let day = started.formatted(.iso8601.year().month().day())
        let baselineFirmware = comparison?.firmware ?? "no baseline"
        var lines = [
            "# ADR-NNNN: OP-1 firmware \(device.firmware), compared with \(baselineFirmware)",
            "",
            "**Status:** Proposed",
            "**Date:** \(day)",
            "",
            "## Context",
            "",
            "FieldCheck \(host.app) ran level \(level) on an \(device.model) with firmware \(device.firmware) "
                + "(\(device.isFirmwareTested ? "tested" : "untested")), on \(host.model) with \(host.system), starting "
                + "\(started.formatted(.iso8601)). It compared the run with \(comparisonDescription).",
            "",
            "Results: \(countsDescription). Each change and failure follows, with what FieldCheck suggests. The suggestions "
                + "are for a person to confirm, and FieldCheck makes no recommendation.",
        ]
        for result in affected { lines += Self.draftSection(for: result, firmware: device.firmware, baseline: baselineFirmware) }
        lines += [
            "",
            "## Decision",
            "",
            "_To decide, for each change and failure above. The code each one affects:_",
            "",
        ]
        lines += affected.map { result in
            "- `\(result.expectation)`: \(Expectation[id: result.expectation]?.usedBy ?? "not in this version's expectation list")"
        }
        lines += [
            "",
            "## Alternatives Considered",
            "",
            "_To decide._",
            "",
            "## Consequences",
            "",
            "_To decide, including the version bump: minor for an added or divergent firmware, major for a dropped "
                + "firmware, an API break, a new archive format or looser safety (ADR 0002, section 12)._",
            "",
            "## Change Log",
            "",
            "- **\(day):** Drafted by FieldCheck from its level \(level) report of \(started.formatted(.iso8601)).",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func draftSection(for result: CheckResult, firmware: String, baseline: String) -> [String] {
        let expectation = Expectation[id: result.expectation]
        let suggested = suggestedClass(for: result)
        var lines = [
            "",
            "### `\(result.expectation)`: \(result.outcome == .fail ? "failed" : "changed")",
            "",
            "- **Expected:** \(expectation?.summary ?? "not in this version's expectation list")",
            "- **Used by:** \(expectation?.usedBy ?? "unknown")",
            "- **Simulator:** the simulated OP-1 and its tests that name `\(result.expectation)`.",
            "- **Seen:** \(result.summary)",
        ]
        for difference in result.differences {
            let path = difference.path.isEmpty ? "the whole value" : "`\(difference.path)`"
            lines += ["- **Changed:** \(path): was \(inline(difference.old)), now \(inline(difference.new))"]
        }
        lines.append("- **Suggested class, to confirm:** \(suggested.name). \(suggested.reason)")
        lines += ["", "| Who | Question for the person deciding |", "| --- | --- |"]
        let rows: [(String, String)] = [
            ("People on \(baseline), using the release that supports \(firmware)",
             "Does \(baseline) keep its own behavior and tests? Does anything they do change? The \(baseline) baseline and its simulator answer most of this."),
            ("People on \(firmware), using an older release",
             "They get the untested-firmware warning (ADR 0002, section 11). What does the \(baseline) behavior FieldTapeKit assumes do on their OP-1 now, and can the safety rules catch it?"),
            ("Archives made on \(baseline), restored onto \(firmware)", "Does \(firmware) accept them as they are?"),
            ("Archives made on \(firmware), restored onto \(baseline)", "Does \(baseline) cope with what's new?"),
            ("Apps using FieldTapeKit",
             "Is the version bump minor (an added or divergent firmware), or major (a dropped firmware, an API break, a new archive format, or looser safety)?"),
        ]
        lines += rows.map { "| \($0.0) | \($0.1) |" }
        return lines
    }

    /// Incompatible for a failure, additive if every difference only added something, and divergent otherwise.
    static func suggestedClass(for result: CheckResult) -> (name: String, reason: String) {
        if result.outcome == .fail {
            return ("Incompatible", "The behavior FieldTapeKit relies on is gone on this firmware.")
        }
        if result.differences.allSatisfy({ $0.suggested == .additive }) {
            return ("Additive", "Something new appeared alongside what was there, so one code path may handle both firmwares.")
        }
        return ("Divergent", "A value changed or disappeared, but the check still passes, so each firmware may need its own profile.")
    }
}
