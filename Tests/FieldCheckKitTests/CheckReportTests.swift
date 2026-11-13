import Foundation
import Testing
@testable import FieldCheckKit

@Suite struct CheckReportTests {
    /// A recorded run, with the device and host from the 2026-11-09 FieldCheck run on the iPad.
    static let report = CheckReport(
        level: 1,
        started: Date(timeIntervalSince1970: 1_794_230_276),
        finished: Date(timeIntervalSince1970: 1_794_230_288),
        device: CheckReport.Device(model: "OP-1", firmware: "1.7.3", isFirmwareTested: true, serialNumber: "L1PXE14W"),
        host: CheckReport.Host(app: "1.0", model: "iPad", system: "iPadOS 27.2"),
        results: [
            CheckResult(expectation: "device.operations", outcome: .pass, summary: "All 10 operations FieldTapeKit sends are listed",
                        observed: ["operations": [0x1001, 0x1002], "vendorExtension": 6]),
            CheckResult(expectation: "names.lowercase", outcome: .fail, summary: "1 name isn't lowercase",
                        observed: ["notLowercase": ["tapes/Mixed Case"]]),
            CheckResult(expectation: "device.identity", outcome: .notRun, summary: "Only ImageCaptureCore knows the USB IDs"),
        ])

    @Test func jsonRoundTrips() throws {
        let decoded = try CheckReport(json: Self.report.jsonData())
        #expect(decoded == Self.report)
        #expect(decoded.format == CheckReport.currentFormat)
    }

    @Test func jsonIsStableAndReadable() throws {
        let json = String(decoding: try Self.report.jsonData(), as: UTF8.self)
        #expect(json.contains(#""started" : "2026-11-09T13:17:56Z""#))
        #expect(json.contains(#""outcome" : "not run""#))
        #expect(json.contains(#""tapes/Mixed Case""#))
        // Sorted keys, so the same run always encodes the same way.
        #expect(try Self.report.jsonData() == Self.report.jsonData())
        #expect(json.range(of: #""device""#)!.lowerBound < json.range(of: #""results""#)!.lowerBound)
    }

    @Test func observedValuesKeepTheirTypes() throws {
        let value: CheckValue = ["flag": true, "count": 1, "zero": 0, "name": "op-1", "list": [false, 2, "x"], "empty": [:]]
        let decoded = try JSONDecoder().decode(CheckValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func markdownStartsWithTheDeviceThenFailures() throws {
        let markdown = Self.report.markdown()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "# FieldCheck report")
        #expect(lines.contains("- **OP-1:** OP-1, firmware 1.7.3 (tested), serial L1PXE14W"))
        #expect(lines.contains("- **Ran on:** iPad, iPadOS 27.2, FieldCheck 1.0"))
        #expect(lines.contains("- **Results:** 1 pass, 1 fail, 1 not run"))
        #expect(markdown.contains("took 12.0 s"))

        let order = ["## Failures", "### `names.lowercase`", "## Not run", "### `device.identity`",
                     "## Passed", "### `device.operations`"]
        let positions = try order.map { heading in try #require(lines.firstIndex(of: heading), "\(heading)") }
        #expect(positions == positions.sorted())
    }

    @Test func markdownGivesEachResultItsExpectationAndUsedBy() {
        let markdown = Self.report.markdown()
        #expect(markdown.contains("- **Expected:** Names on the device are stored lowercase."))
        #expect(markdown.contains("- **Used by:** Case-insensitive paths, TapeName"))
        #expect(markdown.contains("- **Seen:** 1 name isn't lowercase"))
        #expect(markdown.contains("- **Why:** Only ImageCaptureCore knows the USB IDs"))
        #expect(markdown.contains("```json\n{\n  \"notLowercase\" : [\n    \"tapes/Mixed Case\"\n  ]\n}\n```"))
    }

    @Test func markdownLeavesOutEmptySections() {
        let passing = CheckReport(level: 1, started: .now, finished: .now, device: Self.report.device,
                                  host: Self.report.host, results: [Self.report.results[0]])
        let markdown = passing.markdown()
        #expect(!markdown.contains("## Failures"))
        #expect(!markdown.contains("## Not run"))
        #expect(markdown.contains("## Passed"))
    }

    @Test func savingNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CheckReportTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try Self.report.save(in: directory)
        #expect(first.json.lastPathComponent == "fieldcheck-2026-11-09T131756Z.json")
        #expect(first.markdown.lastPathComponent == "fieldcheck-2026-11-09T131756Z.md")
        #expect(try CheckReport(json: Data(contentsOf: first.json)) == Self.report)
        #expect(try String(contentsOf: first.markdown, encoding: .utf8) == Self.report.markdown())

        let second = try Self.report.save(in: directory)
        #expect(second.json.lastPathComponent == "fieldcheck-2026-11-09T131756Z-2.json")

        // A Markdown file alone taking the name is enough to move both on.
        try Data("someone else's".utf8).write(to: directory.appending(path: "fieldcheck-2026-11-09T131756Z-3.md"))
        let third = try Self.report.save(in: directory)
        #expect(third.json.lastPathComponent == "fieldcheck-2026-11-09T131756Z-4.json")
        #expect(try String(contentsOf: directory.appending(path: "fieldcheck-2026-11-09T131756Z-3.md"),
                           encoding: .utf8) == "someone else's")
    }
}
