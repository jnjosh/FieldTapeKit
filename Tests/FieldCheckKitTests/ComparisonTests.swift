import Foundation
import Testing
@testable import FieldCheckKit

@Suite struct ComparisonTests {
    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let device = CheckReport.Device(model: "OP-1", firmware: "1.7.3", isFirmwareTested: true, serialNumber: "SIMULATED")
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func report(_ results: [CheckResult], firmware: String = "1.7.3", level: Int = 1) -> CheckReport {
        let device = CheckReport.Device(model: "OP-1", firmware: firmware, isFirmwareTested: firmware == "1.7.3", serialNumber: "SIMULATED")
        return CheckReport(level: level, started: started, finished: started.addingTimeInterval(2), device: device,
                           host: LevelOneTests.host, results: results)
    }

    static func pass(_ id: String, _ observed: CheckValue, varies: [String] = []) -> CheckResult {
        CheckResult(expectation: id, outcome: .pass, summary: "fine", observed: observed, varies: varies)
    }

    /// A baseline of five checks, one of which didn't run.
    static let baseline: Baseline = {
        let results = [
            pass("device.operations", ["operations": ["0x1001", "0x1004"]]),
            pass("tape.json-keys", ["keys": ["a", "b"], "versions": [1]]),
            pass("device.storage", ["storages": [["id": "0x00010001", "freeSpace": 100]]], varies: ["storages[].freeSpace"]),
            pass("layout.readmes", ["mixdown": "allowed names: side_a.wav side_b.wav"]),
            CheckResult(expectation: "tape.types", outcome: .notRun, summary: "There are no tapes."),
        ]
        return try! Baseline(report: report(results))
    }()

    // MARK: Built in

    @Test func theBuiltInBaselineIsTheRepositorys() throws {
        let built = try #require(Baseline.builtIn.first)
        #expect(Baseline.builtIn.map(\.firmware) == ["1.7.3"])
        let repository = try Data(contentsOf: Self.repository.appending(path: "firmware/1.7.3/baseline.json"))
        let copy = try Data(contentsOf: Self.repository.appending(path: "Sources/FieldCheckKit/Baselines/1.7.3.json"))
        #expect(copy == repository, "Sources/FieldCheckKit/Baselines/1.7.3.json must be a copy of firmware/1.7.3/baseline.json")
        #expect(built == (try Baseline(json: repository)))
    }

    @Test func picksTheFirmwaresOwnBaselineOrTheClosestOlderOne() throws {
        let older = try Baseline(json: Baseline.builtIn[0].jsonData())
        let newer = try Baseline(report: Self.report([], firmware: "1.9"))
        let baselines = [older, newer]
        #expect(Baseline.for(firmware: "1.7.3", in: baselines)?.baseline.firmware == "1.7.3")
        #expect(Baseline.for(firmware: "1.7.3", in: baselines)?.isExact == true)
        #expect(Baseline.for(firmware: "1.8", in: baselines).map { ($0.baseline.firmware, $0.isExact) } ?? ("", true) == ("1.7.3", false))
        #expect(Baseline.for(firmware: "1.10", in: baselines)?.baseline.firmware == "1.9", "versions compare number by number")
        #expect(Baseline.for(firmware: "1.6", in: baselines)?.baseline.firmware == "1.7.3", "older than all: the oldest")
        #expect(Baseline.for(firmware: "1.7.3", in: []) == nil)
    }

    // MARK: Comparing

    @Test func judgesEachResultAgainstTheBaseline() throws {
        let run = Self.report([
            // Additive: a new operation, alongside the old ones.
            Self.pass("device.operations", ["operations": ["0x1001", "0x1004", "0x9999"]]),
            // Additive: a new key in a record. Divergent: a value changed.
            Self.pass("tape.json-keys", ["keys": ["a", "c"], "versions": [1], "extra": true]),
            // Only a field that varies changed, so it passes.
            Self.pass("device.storage", ["storages": [["id": "0x00010001", "freeSpace": 5]]], varies: ["storages[].freeSpace"]),
            // Incompatible: a fail stays a fail.
            CheckResult(expectation: "layout.readmes", outcome: .fail, summary: "mixdown/readme.txt is gone"),
            // The baseline didn't run it.
            Self.pass("tape.types", ["types": [0]]),
            // Newer than the baseline.
            Self.pass("names.lowercase", ["lowercase": true]),
            CheckResult(expectation: "read.speed", outcome: .notRun, summary: "No file to read."),
        ])
        let report = run.compared(with: Self.baseline, isExact: true)
        let results = Dictionary(uniqueKeysWithValues: report.results.map { ($0.expectation, $0) })

        let operations = try #require(results["device.operations"])
        #expect(operations.outcome == .changed)
        #expect(operations.differences == [CheckResult.Difference(path: "operations", old: ["0x1001", "0x1004"],
                                                                  new: ["0x1001", "0x1004", "0x9999"], suggested: .additive)])
        let keys = try #require(results["tape.json-keys"])
        #expect(keys.outcome == .changed)
        #expect(keys.differences.map(\.path) == ["extra", "keys"])
        #expect(keys.differences.map(\.suggested) == [.additive, .divergent])

        #expect(results["device.storage"]?.outcome == .pass)
        #expect(results["layout.readmes"]?.outcome == .fail)
        #expect(results["read.speed"]?.outcome == .notRun)
        #expect(results["tape.types"]?.outcome == .pass)
        #expect(results["tape.types"]?.baselineNote == "The baseline for 1.7.3 didn't run this check: There are no tapes.")
        #expect(results["names.lowercase"]?.baselineNote == "The baseline for 1.7.3 has no result for this check, which is newer than it.")

        #expect(report.comparison?.firmware == "1.7.3" && report.comparison?.isExact == true)
        #expect(report.countsDescription == "3 pass, 2 changed, 1 fail, 1 not run")
        // A changed run, once reviewed, can still be a baseline.
        #expect(throws: Baseline.Refusal.self) { try Baseline(report: report) }
        #expect(try Baseline(report: Self.report(report.results.filter { $0.outcome != .fail })).levels[0]
                    .expectations["device.operations"]?.observed == ["operations": ["0x1001", "0x1004", "0x9999"]])
    }

    @Test func aRemovedKeyOrAShorterListIsDivergent() {
        #expect(CheckReport.suggestedClass(old: ["a", "b"], new: ["a"]) == .divergent)
        #expect(CheckReport.suggestedClass(old: ["a", "b"], new: ["a", "c", "d"]) == .divergent)
        #expect(CheckReport.suggestedClass(old: 1, new: nil) == .divergent)
        #expect(CheckReport.suggestedClass(old: nil, new: 1) == .additive)
    }

    @Test func aLevelTheBaselineDoesntHaveIsntCompared() {
        let run = Self.report([Self.pass("names.maximum", ["name": "x"])], level: 2)
        let report = run.compared(with: Self.baseline, isExact: false)
        #expect(report.results == run.results)
        #expect(report.comparison?.levelStarted == nil)
        #expect(report.comparisonDescription == "the baseline for firmware 1.7.3, the closest to 1.7.3, which has none of its "
                + "own, which has no level 2, so nothing was compared")
    }

    @Test func theRealRunsMatchTheBuiltInBaseline() throws {
        // FieldCheck's own runs on the owner's OP-1, which only differ from the baseline in what varies.
        let baseline = try #require(Baseline.for(firmware: "1.7.3")?.baseline)
        for name in ["fieldcheck-2026-11-15T161558Z", "fieldcheck-2026-11-16T043329Z", "fieldcheck-2026-11-16T043349Z"] {
            let url = Self.repository.appending(path: "firmware/1.7.3/runs/\(name).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let report = try CheckReport(json: data).compared(with: baseline, isExact: true)
            // These runs were recorded before write.speed marked `bytes` and `writes` as varying: the baseline's level 2
            // ran with the long check, and these without it. New runs carry the new fields.
            for result in report.results where result.outcome == .changed && result.expectation != "write.speed" {
                Issue.record("\(name): \(result.expectation) changed: \(result.differences.map(\.path))")
            }
        }
    }

    // MARK: The report and the draft ADR

    static let compared: CheckReport = report([
        Self.pass("device.operations", ["operations": ["0x1001", "0x1004", "0x9999"]]),
        Self.pass("tape.json-keys", ["keys": ["a", "c"], "versions": [1]]),
        CheckResult(expectation: "layout.readmes", outcome: .fail, summary: "mixdown/readme.txt is gone"),
        CheckResult(expectation: "tape.types", outcome: .notRun, summary: "There are no tapes."),
        Self.pass("device.storage", ["storages": [["id": "0x00010001", "freeSpace": 5]]], varies: ["storages[].freeSpace"]),
    ]).compared(with: baseline, isExact: true)

    @Test func theReportPutsFailuresThenChangesFirst() throws {
        let markdown = Self.compared.markdown()
        let order = ["## Failures", "## Changes", "## Not run", "## Passed"].map { try! #require(markdown.range(of: $0)).lowerBound }
        #expect(order == order.sorted())
        #expect(markdown.contains("- **Compared with:** the baseline for firmware 1.7.3, level 1, from the run started "))
        #expect(markdown.contains("- **Results:** 1 pass, 2 changed, 1 fail, 1 not run"))
        #expect(markdown.contains("- **Changed:** `operations`: was `[\"0x1001\",\"0x1004\"]`, now `[\"0x1001\",\"0x1004\",\"0x9999\"]` "
                                  + "(additive, a suggestion to confirm)"))
        // A report that wasn't compared reads as before.
        let plain = Self.report([Self.pass("names.lowercase", ["lowercase": true])])
        #expect(plain.markdown().contains("- **Compared with:** no baseline"))
        #expect(plain.countsDescription == "1 pass, 0 fail, 0 not run")
        #expect(try !String(decoding: plain.jsonData(), as: UTF8.self).contains("differences"))
    }

    @Test func theDraftADRCoversEveryChangeAndFailure() throws {
        let draft = try #require(Self.compared.draftADR())
        #expect(draft.hasPrefix("# ADR-NNNN: OP-1 firmware 1.7.3, compared with 1.7.3\n\n**Status:** Proposed\n"))
        for heading in ["## Context", "## Decision", "## Alternatives Considered", "## Consequences", "## Change Log"] {
            #expect(draft.contains(heading))
        }
        #expect(draft.contains("### `device.operations`: changed"))
        #expect(draft.contains("- **Suggested class, to confirm:** Additive."))
        #expect(draft.contains("### `tape.json-keys`: changed"))
        #expect(draft.contains("- **Suggested class, to confirm:** Divergent."))
        #expect(draft.contains("### `layout.readmes`: failed"))
        #expect(draft.contains("- **Suggested class, to confirm:** Incompatible."))
        #expect(draft.components(separatedBy: "| Apps using FieldTapeKit |").count == 4, "a table for each of the three")
        #expect(!draft.contains("device.storage"), "a pass isn't in the draft")
        #expect(Self.report([Self.pass("names.lowercase", ["lowercase": true])]).compared(with: Self.baseline, isExact: true)
                    .draftADR() == nil)
        // A hang says nothing about the firmware.
        let stopped = Self.report([CheckResult(expectation: "layout.readmes", outcome: .fail, summary: CheckResult.disconnected),
                                   CheckResult(expectation: "tape.types", outcome: .notRun, summary: "The OP-1 disconnected.")])
            .compared(with: Self.baseline, isExact: true)
        #expect(stopped.draftADR() == nil)
        #expect(stopped.markdown().contains("- **Stopped:** the OP-1 stopped answering during `layout.readmes`"))
    }

    @Test func savesTheDraftNextToTheReport() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ComparisonTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try Self.compared.save(in: directory)
        #expect(saved.draftADR?.lastPathComponent == saved.json.deletingPathExtension().lastPathComponent + ".draft-adr.md")
        #expect(try String(contentsOf: try #require(saved.draftADR), encoding: .utf8) == Self.compared.draftADR())
        let clean = try Self.report([Self.pass("names.lowercase", ["lowercase": true])]).save(in: directory)
        #expect(clean.draftADR == nil)
    }
}
