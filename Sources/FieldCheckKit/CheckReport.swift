import FieldTapeKit
import Foundation

/// One FieldCheck run: which OP-1, on what, and a result for every check (ADR 0003, section 4).
///
/// It's saved as JSON, for baselines and for comparing runs, and as Markdown, for reading. Reports from real
/// firmware go into the repository's `firmware/<version>/`.
public struct CheckReport: Sendable, Hashable, Codable {
    /// Raised when the JSON changes shape, so an older report can still be read or refused clearly.
    public static let currentFormat = 1

    public struct Device: Sendable, Hashable, Codable {
        public let model: String
        public let firmware: String
        public let isFirmwareTested: Bool
        public let serialNumber: String

        public init(model: String, firmware: String, isFirmwareTested: Bool, serialNumber: String) {
            self.model = model
            self.firmware = firmware
            self.isFirmwareTested = isFirmwareTested
            self.serialNumber = serialNumber
        }

        public init(_ info: FieldDeviceInfo) {
            self.init(model: info.model, firmware: info.firmware, isFirmwareTested: info.isFirmwareTested,
                      serialNumber: info.serialNumber)
        }
    }

    /// What FieldCheck ran on. The app fills it in, because FieldCheckKit doesn't use UIKit.
    public struct Host: Sendable, Hashable, Codable {
        /// FieldCheck's version.
        public let app: String
        /// Such as "iPad".
        public let model: String
        /// Such as "iPadOS 27.2".
        public let system: String

        public init(app: String, model: String, system: String) {
            self.app = app
            self.model = model
            self.system = system
        }
    }

    public let format: Int
    public let level: Int
    /// To the second in JSON.
    public let started: Date
    /// To the second in JSON.
    public let finished: Date
    /// How long the run took. It's kept apart from the dates, because JSON keeps those only to the second.
    public let durationMilliseconds: Int
    public let device: Device
    public let host: Host
    /// In the order the checks ran.
    public let results: [CheckResult]
    /// The baseline the results were compared with, or nil if they weren't (ADR 0003, section 4).
    public let comparison: Comparison?

    /// Which baseline a report was compared with.
    public struct Comparison: Sendable, Hashable, Codable {
        /// The baseline's firmware.
        public let firmware: String
        /// Whether it's the OP-1's own firmware's baseline, rather than the newest older one's.
        public let isExact: Bool
        /// When the baseline's run of this level started, or nil if the baseline has no section for this level, so
        /// nothing was compared.
        public let levelStarted: Date?
    }

    public init(level: Int, started: Date, finished: Date, device: Device, host: Host, results: [CheckResult]) {
        format = Self.currentFormat
        self.level = level
        self.started = started
        self.finished = finished
        durationMilliseconds = Int((finished.timeIntervalSince(started) * 1_000).rounded())
        self.device = device
        self.host = host
        self.results = results
        comparison = nil
    }

    /// The same report with compared results.
    init(_ report: CheckReport, results: [CheckResult], comparison: Comparison) {
        format = report.format
        level = report.level
        started = report.started
        finished = report.finished
        durationMilliseconds = report.durationMilliseconds
        device = report.device
        host = report.host
        self.results = results
        self.comparison = comparison
    }

    private enum CodingKeys: String, CodingKey {
        case format, level, started, finished, durationMilliseconds, device, host, results, comparison
    }

    /// Reports from before `durationMilliseconds` existed fall back to their dates, to the second.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        level = try container.decode(Int.self, forKey: .level)
        started = try container.decode(Date.self, forKey: .started)
        finished = try container.decode(Date.self, forKey: .finished)
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
            ?? Int((finished.timeIntervalSince(started) * 1_000).rounded())
        device = try container.decode(Device.self, forKey: .device)
        host = try container.decode(Host.self, forKey: .host)
        results = try container.decode([CheckResult].self, forKey: .results)
        comparison = try container.decodeIfPresent(Comparison.self, forKey: .comparison)
    }

    public func count(_ outcome: CheckResult.Outcome) -> Int {
        results.count { $0.outcome == outcome }
    }
}

// MARK: - JSON

extension CheckReport {
    public func jsonData() throws -> Data {
        try ReportFiles.encoder().encode(self)
    }

    public init(json: Data) throws {
        self = try ReportFiles.decoder().decode(Self.self, from: json)
    }
}

// MARK: - Markdown

extension CheckReport {
    /// The firmware, OS and device first, and the baseline it was compared with, then failures, changes, checks that
    /// didn't run, and passes (ADR 0003, section 4). Each result has its expectation and its "used by" entry, so a
    /// failure or a change points at the code that relies on it, and a change shows its old and new values.
    public func markdown() -> String {
        var lines = ["# FieldCheck report", ""]
        let tested = device.isFirmwareTested ? "tested" : "untested"
        lines += [
            "- **OP-1:** \(device.model), firmware \(device.firmware) (\(tested)), serial \(device.serialNumber)",
            "- **Ran on:** \(host.model), \(host.system), FieldCheck \(host.app)",
            "- **Level:** \(level)",
            "- **Started:** \(started.formatted(.iso8601)), took "
                + "\((Double(durationMilliseconds) / 1_000).formatted(.number.precision(.fractionLength(1)))) s",
            "- **Compared with:** \(comparisonDescription)",
            "- **Results:** \(countsDescription)",
        ]
        if let stopped = results.first(where: \.stoppedAnswering) {
            lines.append("- **Stopped:** the OP-1 stopped answering during `\(stopped.expectation)`, so the checks after it "
                         + "didn't run. That says nothing about the firmware, so there's no draft ADR for it.")
        }
        for (title, outcome) in [("Failures", CheckResult.Outcome.fail), ("Changes", .changed), ("Not run", .notRun),
                                 ("Passed", .pass)] {
            let matching = results.filter { $0.outcome == outcome }
            guard !matching.isEmpty else { continue }
            lines += ["", "## \(title)"]
            for result in matching { lines += Self.section(for: result) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Such as "10 pass, 1 changed, 0 fail, 1 not run". `changed` appears only for a compared report.
    public var countsDescription: String {
        let changed = comparison == nil ? "" : "\(count(.changed)) changed, "
        return "\(count(.pass)) pass, \(changed)\(count(.fail)) fail, \(count(.notRun)) not run"
    }

    /// Which baseline the report was compared with, in a sentence.
    public var comparisonDescription: String {
        guard let comparison else { return "no baseline" }
        let whose = comparison.isExact ? "the baseline for firmware \(comparison.firmware)"
            : "the baseline for firmware \(comparison.firmware), the closest to \(device.firmware), which has none of its own"
        guard let started = comparison.levelStarted else { return "\(whose), which has no level \(level), so nothing was compared" }
        return "\(whose), level \(level), from the run started \(started.formatted(.iso8601))"
    }

    private static func section(for result: CheckResult) -> [String] {
        var lines = ["", "### `\(result.expectation)`", ""]
        if let expectation = Expectation[id: result.expectation] {
            lines += ["- **Expected:** \(expectation.summary)", "- **Used by:** \(expectation.usedBy)"]
        } else {
            lines += ["- **Expected:** not in this version's expectation list"]
        }
        lines += ["- **\(result.outcome == .notRun ? "Why" : "Seen"):** \(result.summary)"]
        for difference in result.differences {
            let path = difference.path.isEmpty ? "the whole value" : "`\(difference.path)`"
            lines += ["- **Changed:** \(path): was \(Self.inline(difference.old)), now \(Self.inline(difference.new)) "
                      + "(\(difference.suggested.rawValue), a suggestion to confirm)"]
        }
        if let note = result.baselineNote { lines += ["- **Baseline:** \(note)"] }
        if !result.varies.isEmpty {
            lines += ["- **Varies between runs:** \(result.varies.map { "`\($0)`" }.joined(separator: ", "))"]
        }
        if let observed = result.observed, let json = try? Self.prettyJSON(observed) {
            lines += ["", "```json", json, "```"]
        }
        return lines
    }

    /// A value on one line, such as `["a","b"]`, or "nothing".
    static func inline(_ value: CheckValue?) -> String {
        guard let value else { return "nothing" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { "`" + String(decoding: $0, as: UTF8.self) + "`" } ?? "?"
    }

    private static func prettyJSON(_ value: CheckValue) throws -> String {
        String(decoding: try ReportFiles.encoder().encode(value), as: UTF8.self)
    }
}

// MARK: - Saving

extension CheckReport {
    /// Writes `fieldcheck-<started>.json` and `.md` into `directory`, and `fieldcheck-<started>.draft-adr.md` when
    /// the report has changes or failures (ADR 0003, section 5). It never overwrites a file: if any name is taken,
    /// they all get a number, such as `fieldcheck-<started>-2`.
    ///
    /// - Returns: The JSON file's URL, the Markdown file's, and the draft ADR's, if there is one.
    @discardableResult
    public func save(in directory: URL) throws -> (json: URL, markdown: URL, draftADR: URL?) {
        let stamp = started.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var files: [(extension: String, data: Data)] = [("json", try jsonData()), ("md", Data(markdown().utf8))]
        if let draft = draftADR() { files.append(("draft-adr.md", Data(draft.utf8))) }
        let urls = try ReportFiles.write(files, named: "fieldcheck-\(stamp)", in: directory)
        return (urls[0], urls[1], urls.count > 2 ? urls[2] : nil)
    }
}
