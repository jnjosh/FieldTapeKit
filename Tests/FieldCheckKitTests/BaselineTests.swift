import Foundation
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct BaselineTests {
    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func fixtureReport() async -> CheckReport {
        await LevelOne.run(on: FieldDevice.simulated(await OP1Fixture.device()), host: LevelOneTests.host)
    }

    @Test func comesFromAPassingRun() async throws {
        let report = await Self.fixtureReport()
        let baseline = try Baseline(report: report)
        #expect(baseline.firmware == "1.7.3")
        #expect(baseline.format == 2)
        let level = try #require(baseline[level: 1])
        #expect(baseline.levels.count == 1)
        #expect(level.source.model == "OP-1")
        #expect(Set(level.expectations.keys) == Set(report.results.map(\.expectation)))
        #expect(level.expectations["read.speed"]?.varies == ["bytes", "milliseconds", "kilobytesPerSecond", "chunkMilliseconds"])
        #expect(level.expectations["device.storage"]?.varies == ["storages[].freeSpace"])
        #expect(level.expectations["device.operations"]?.varies == [])
    }

    @Test func leavesOutTheSerialNumber() async throws {
        let json = String(decoding: try Baseline(report: await Self.fixtureReport()).jsonData(), as: UTF8.self)
        #expect(!json.contains("SIMULATED"))
        #expect(!json.contains("serial"))
    }

    @Test func refusesARunWithFailures() async throws {
        let report = await Self.fixtureReport()
        let failing = CheckReport(level: 1, started: report.started, finished: report.finished, device: report.device,
                                  host: report.host, results: report.results.map { result in
                                      result.expectation == "names.lowercase"
                                          ? CheckResult(expectation: result.expectation, outcome: .fail, summary: "No")
                                          : result
                                  })
        #expect(throws: Baseline.Refusal.failures(level: 1, ["names.lowercase"])) { try Baseline(report: failing) }
    }

    @Test func recordsWhyACheckDidntRun() throws {
        let report = CheckReport(level: 1, started: .now, finished: .now, device: CheckReportTests.report.device,
                                 host: CheckReportTests.report.host,
                                 results: [CheckResult(expectation: "tape.files", outcome: .notRun, summary: "There are no tapes on the OP-1.")])
        let entry = try #require(try Baseline(report: report)[level: 1]?.expectations["tape.files"])
        #expect(entry == Baseline.Entry(observed: nil, varies: [], notObserved: "There are no tapes on the OP-1."))
    }

    @Test func roundTripsAndSavesUnderANewName() async throws {
        let baseline = try Baseline(report: await Self.fixtureReport())
        // Dates are saved to the second, so only what was observed is compared.
        #expect(try Baseline(json: baseline.jsonData()).levels.map(\.expectations) == baseline.levels.map(\.expectations))

        let directory = FileManager.default.temporaryDirectory.appending(path: "BaselineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try baseline.save(in: directory).lastPathComponent == "baseline-1.7.3.json")
        #expect(try baseline.save(in: directory).lastPathComponent == "baseline-1.7.3-2.json")
    }

    /// A typo in a check's `varies` would leave a changing value in the comparison.
    @Test func everyVaryingFieldIsThere() async {
        for result in await Self.fixtureReport().results {
            for path in result.varies {
                #expect(result.observed?.values(at: path).isEmpty == false, "\(result.expectation): \(path)")
            }
        }
    }

    @Test func pathsReachIntoRecordsAndLists() {
        let value: CheckValue = ["storages": [["freeSpace": 1], ["freeSpace": 2]], "bytes": 3]
        #expect(value.values(at: "storages[].freeSpace") == [1, 2])
        #expect(value.values(at: "bytes") == [3])
        #expect(value.values(at: "missing").isEmpty)
        #expect(value.values(at: "bytes[]").isEmpty)
    }

    @Test func onlyBlankTapesObserveNoClipKeys() {
        let result = LevelOne.tapeJSONKeys([("tapes/a/tape.json", Data(OP1Fixture.blankTapeJSON.utf8))],
                                           shape: FirmwareProfile.v1_7_3.tapeJSON)
        guard case .record(let observed) = result.observed else { Issue.record("no observation"); return }
        #expect(observed["clipKeys"] == nil)
        #expect(observed["versions"] == [1])
    }

    // MARK: The default simulated OP-1

    /// `FieldDevice.simulated()` is a 1.7.3 OP-1 with no tapes and empty album sides, so level 1 passes, apart from
    /// the checks that need tapes or audio.
    @Test func level1PassesOnTheDefaultSimulatedOP1() async {
        let report = await LevelOne.run(on: FieldDevice.simulated(), host: LevelOneTests.host)
        let notRun: Set = ["tape.files", "tape.wav-format", "tape.json-keys", "tape.json-units", "tape.types",
                           "read.partial", "read.speed", "read.cost"]
        for result in report.results {
            #expect(result.outcome == (notRun.contains(result.expectation) ? .notRun : .pass),
                    "\(result.expectation): \(result.summary)")
        }
    }

    /// The simulator's readme texts are the ones in the committed baseline.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: committed.path(percentEncoded: false))))
    func theSimulatorsReadmesMatchTheBaseline() async throws {
        let baseline = try Baseline(json: Data(contentsOf: Self.committed))
        let readmes = try #require(baseline[level: 1]?.expectations["layout.readmes"]?.observed)
        let report = await LevelOne.run(on: FieldDevice.simulated(), host: LevelOneTests.host)
        let simulated = try #require(report.results.first { $0.expectation == "layout.readmes" }?.observed)
        guard case .record(let fromBaseline) = readmes, case .record(let fromSimulator) = simulated else {
            Issue.record("no readmes")
            return
        }
        // The default simulated OP-1 has no tapes, so no tape readme.
        #expect(fromSimulator == fromBaseline.filter { $0.key != "tapes/*/readme.txt" })
    }

    // MARK: Older reports

    /// A real report saved on 2026-11-13, before reports had `durationMilliseconds` or `varies`.
    @Test func readsAReportFromBeforeDurationsAndVaries() throws {
        let url = Self.repository.appending(path: "firmware/1.7.3/runs/fieldcheck-2026-11-13T135316Z.json")
        let report = try CheckReport(json: Data(contentsOf: url))
        #expect(report.durationMilliseconds == 10_000)
        #expect(report.results.count == 17)
        #expect(report.results.allSatisfy { $0.varies.isEmpty })
    }

    // MARK: The committed baseline

    static let committed = repository.appending(path: "firmware/1.7.3/baseline.json")

    /// The 1.7.3 baseline is the source of the 1.7.3 profile and simulator (ADR 0003, section 4), so they must agree.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: committed.path(percentEncoded: false)),
                   "Runs once firmware/1.7.3/baseline.json is committed"))
    func theCommittedBaselineAgreesWithTheProfileAndSimulator() throws {
        try Self.expectAgreement(try Baseline(json: Data(contentsOf: Self.committed)))
    }

    /// The same, for a baseline made from the real 2026-11-13 run, so the agreement checks run before the baseline
    /// is committed too.
    @Test func aRealRunAgreesWithTheProfileAndSimulator() throws {
        let url = Self.repository.appending(path: "firmware/1.7.3/runs/fieldcheck-2026-11-13T135316Z.json")
        try Self.expectAgreement(try Baseline(report: CheckReport(json: Data(contentsOf: url))))
    }

    static func expectAgreement(_ baseline: Baseline) throws {
        let profile = FirmwareProfile.v1_7_3
        #expect(baseline.firmware == "1.7.3")
        #expect(baseline.format == Baseline.currentFormat)
        for level in baseline.levels {
            for id in level.expectations.keys { #expect(Expectation[id: id] != nil, "level \(level.source.level): \(id)") }
        }

        func observed(_ id: String, level: Int = 1) throws -> CheckValue {
            try #require(baseline[level: level]?.expectations[id]?.observed, "level \(level): \(id) wasn't observed")
        }
        #expect(try observed("device.operations").values(at: "operations")
                == [.list(SimulatedMTPDevice.operations173.map { .string(LevelOne.hex($0)) })])
        #expect(try observed("device.storage").values(at: "storages[].id") == [.string(LevelOne.hex(SimulatedMTPDevice.storageID, digits: 8))])
        #expect(try observed("device.storage").values(at: "storages[].capacity") == [.int(6_429_185_024)])
        #expect(try observed("layout.folders").values(at: "expected") == [.list(profile.folders.sorted().map(CheckValue.string))])
        #expect(try observed("tape.json-keys").values(at: "keys") == [.list(profile.tapeJSON.keys.sorted().map(CheckValue.string))])
        #expect(try observed("tape.json-keys").values(at: "versions") == [.list(profile.tapeJSON.versions.sorted().map(CheckValue.int))])
        #expect(try observed("album.files").values(at: "files")
                == [.list((profile.albumFiles.required + profile.albumFiles.optional).sorted().map(CheckValue.string))])

        let format = { (wav: WAVFormat) -> CheckValue in
            ["encoding": .int(Int(wav.encoding)), "channels": .int(wav.channels), "sampleRate": .int(wav.sampleRate),
             "bitsPerSample": .int(wav.bitsPerSample)]
        }
        #expect(try observed("tape.wav-format").values(at: "formats") == [[format(profile.trackFormat)]])
        #expect(try observed("album.wav-format").values(at: "formats") == [[format(profile.sideFormat)]])

        guard case .record(let readmes) = try observed("layout.readmes") else { Issue.record("no readmes"); return }
        for (folder, names) in profile.allowedNames {
            guard case .string(let text) = readmes["\(folder)/readme.txt"] else { continue }
            #expect(LevelOne.allowedNames(in: text) == names, "\(folder)")
        }

        // Levels 2 and 3, when the baseline has them: what the simulator does on writes and reconnects.
        if baseline[level: 2] != nil {
            #expect(try observed("write.refused-name", level: 2).values(at: "responseCode") == [.string(LevelOne.hex(PTPResponseCode.generalError))])
            #expect(try observed("write.preset-converted", level: 2).values(at: "stored[].frames") == [.int(20 * 44_100), .int(6 * 44_100)])
            #expect(try observed("write.preset-converted", level: 2).values(at: "stored[].container") == ["aifc", "aifc"])
            if let limit = baseline[level: 2]?.expectations["tape.track-limit"]?.observed {
                #expect(limit.values(at: "readBytes") == [.int(WAVHeader.size + profile.maximumTapeFrames * profile.trackFormat.frameBytes)])
            }
        }
        if baseline[level: 3] != nil {
            let names = try observed("names.maximum", level: 3)
            guard case .string(let long) = names.values(at: "longName").first else { Issue.record("no long name"); return }
            #expect(names.values(at: "longListedAs") == [.string(String(long.lowercased().prefix(profile.maximumTapeNameLength)))])
            #expect(try observed("delete.folder-with-files", level: 3).values(at: "folderGone") == [true])
            #expect(try observed("delete.folder-with-files", level: 3).values(at: "filesLeft") == [0])
            #expect(try observed("reconnect.renamed", level: 3).values(at: "files") == [.list(
                (profile.tapeFiles.required + profile.tapeFiles.optional).sorted().map(CheckValue.string))])
        }
    }

    // MARK: Three levels

    /// Levels 1, 2 and 3 on simulated OP-1s, as FieldCheck saves them after a full run.
    static func threeLevels() async throws -> [CheckReport] {
        let levelOne = await fixtureReport()
        let (device, simulator) = LevelTwoTests.device()
        let workspace = try LevelTwoTests.workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let levelTwo = await LevelTwoTests.run(device, longCheck: true, in: workspace)
        let pending = try #require(await LevelThree.pending(after: levelTwo, on: device, workspace: workspace))
        await simulator.leaveAndReenterMTPMode()
        let levelThree = await LevelThree.run(on: FieldDevice.simulated(simulator), pending: pending,
                                              files: workspace.deletingLastPathComponent(), host: LevelOneTests.host)
        return [levelOne, levelTwo, levelThree]
    }

    @Test func holdsEachLevelInItsOwnSection() async throws {
        let reports = try await Self.threeLevels()
        let baseline = try Baseline(reports: [reports[2], reports[0], reports[1]])
        #expect(baseline.levels.map(\.source.level) == [1, 2, 3])
        // The same expectation at two levels keeps both, with their own fields.
        let storage1 = try #require(baseline[level: 1]?.expectations["device.storage"]?.observed)
        let storage2 = try #require(baseline[level: 2]?.expectations["device.storage"]?.observed)
        #expect(!storage1.values(at: "storages").isEmpty && storage2.values(at: "storages").isEmpty)
        #expect(!storage2.values(at: "afterCleanup").isEmpty)
        #expect(baseline[level: 2]?.expectations["names.maximum"]?.observed?.values(at: "longListedAs") == ["fieldck #2-13"])
        #expect(baseline[level: 3]?.expectations["names.maximum"]?.observed?.values(at: "longListedAs") == ["fieldck #2-1"])
        #expect(baseline[level: 2]?.expectations["album.write-exact"]?.observed == nil, "album writing is off on 1.7.3")
        try Self.expectAgreement(baseline)
        // Dates are saved to the second, so only what was observed is compared.
        #expect(try Baseline(json: baseline.jsonData()).levels.map(\.expectations) == baseline.levels.map(\.expectations))
    }

    @Test func refusesRunsThatDontMakeOneBaseline() async throws {
        let reports = try await Self.threeLevels()
        #expect(throws: Baseline.Refusal.noReports) { try Baseline(reports: []) }
        #expect(throws: Baseline.Refusal.repeatedLevel(2)) { try Baseline(reports: [reports[1], reports[1]]) }
        let other = CheckReport(level: 3, started: reports[2].started, finished: reports[2].finished,
                                device: CheckReport.Device(model: "OP-1", firmware: "1.8.0", isFirmwareTested: false, serialNumber: "X"),
                                host: reports[2].host, results: reports[2].results)
        #expect(throws: Baseline.Refusal.mixedFirmware(["1.7.3", "1.8.0"])) { try Baseline(reports: [reports[0], other]) }
    }

    /// The 1.7.3 baseline as it was first committed, on 2026-11-14: format 1, one level at the top.
    @Test func readsAFormat1BaselineAsLevel1() throws {
        let json = Data(#"""
            {"expectations":{"names.lowercase":{"observed":{"tapes":["a"]},"varies":[]}},"firmware":"1.7.3","format":1,
             "source":{"host":{"app":"1.0","model":"iPad","system":"iPadOS 27.2.1"},"level":1,"model":"OP-1",
             "started":"2026-11-14T17:24:05Z"}}
            """#.utf8)
        let baseline = try Baseline(json: json)
        #expect(baseline.format == 2 && baseline.levels.count == 1)
        #expect(baseline[level: 1]?.expectations["names.lowercase"]?.observed == ["tapes": ["a"]])
        #expect(String(decoding: try baseline.jsonData(), as: UTF8.self).contains("\"levels\""))
    }
}
