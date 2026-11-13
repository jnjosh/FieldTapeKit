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
    public let started: Date
    public let finished: Date
    public let device: Device
    public let host: Host
    /// In the order the checks ran.
    public let results: [CheckResult]

    public init(level: Int, started: Date, finished: Date, device: Device, host: Host, results: [CheckResult]) {
        format = Self.currentFormat
        self.level = level
        self.started = started
        self.finished = finished
        self.device = device
        self.host = host
        self.results = results
    }

    public func count(_ outcome: CheckResult.Outcome) -> Int {
        results.count { $0.outcome == outcome }
    }
}

// MARK: - JSON

extension CheckReport {
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys keep runs diffable in the repository.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Self.self, from: json)
    }
}

// MARK: - Markdown

extension CheckReport {
    /// The firmware, OS and device first, then failures, then checks that didn't run, then passes. Each result
    /// has its expectation and its "used by" entry, so a failure points at the code that relies on it.
    public func markdown() -> String {
        var lines = ["# FieldCheck report", ""]
        let tested = device.isFirmwareTested ? "tested" : "untested"
        lines += [
            "- **OP-1:** \(device.model), firmware \(device.firmware) (\(tested)), serial \(device.serialNumber)",
            "- **Ran on:** \(host.model), \(host.system), FieldCheck \(host.app)",
            "- **Level:** \(level)",
            "- **Started:** \(started.formatted(.iso8601)), took "
                + "\(finished.timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))) s",
            "- **Results:** \(count(.pass)) pass, \(count(.fail)) fail, \(count(.notRun)) not run",
        ]
        for (title, outcome) in [("Failures", CheckResult.Outcome.fail), ("Not run", .notRun), ("Passed", .pass)] {
            let matching = results.filter { $0.outcome == outcome }
            guard !matching.isEmpty else { continue }
            lines += ["", "## \(title)"]
            for result in matching { lines += Self.section(for: result) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(for result: CheckResult) -> [String] {
        var lines = ["", "### `\(result.expectation)`", ""]
        if let expectation = Expectation[id: result.expectation] {
            lines += ["- **Expected:** \(expectation.summary)", "- **Used by:** \(expectation.usedBy)"]
        } else {
            lines += ["- **Expected:** not in this version's expectation list"]
        }
        lines += ["- **\(result.outcome == .notRun ? "Why" : "Seen"):** \(result.summary)"]
        if let observed = result.observed, let json = try? Self.prettyJSON(observed) {
            lines += ["", "```json", json, "```"]
        }
        return lines
    }

    private static func prettyJSON(_ value: CheckValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

// MARK: - Saving

extension CheckReport {
    /// Writes `fieldcheck-<started>.json` and `.md` into `directory`. It never overwrites a file: if either name
    /// is taken, both get a number, such as `fieldcheck-<started>-2`.
    ///
    /// - Returns: The JSON file's URL, then the Markdown file's.
    @discardableResult
    public func save(in directory: URL) throws -> (json: URL, markdown: URL) {
        let stamp = started.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let json = try jsonData()
        let text = Data(markdown().utf8)
        var number = 1
        while true {
            let base = number == 1 ? "fieldcheck-\(stamp)" : "fieldcheck-\(stamp)-\(number)"
            let urls = (json: directory.appending(path: "\(base).json"), markdown: directory.appending(path: "\(base).md"))
            let manager = FileManager.default
            if !manager.fileExists(atPath: urls.json.path(percentEncoded: false)),
               !manager.fileExists(atPath: urls.markdown.path(percentEncoded: false)) {
                // .withoutOverwriting refuses if something took the name in between.
                try json.write(to: urls.json, options: .withoutOverwriting)
                try text.write(to: urls.markdown, options: .withoutOverwriting)
                return urls
            }
            number += 1
        }
    }
}
