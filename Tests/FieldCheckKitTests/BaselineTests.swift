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
        #expect(baseline.source.level == 1)
        #expect(baseline.source.model == "OP-1")
        #expect(Set(baseline.expectations.keys) == Set(report.results.map(\.expectation)))
        #expect(baseline.expectations["read.speed"]?.varies == ["bytes", "milliseconds", "kilobytesPerSecond", "chunkMilliseconds"])
        #expect(baseline.expectations["device.storage"]?.varies == ["storages[].freeSpace"])
        #expect(baseline.expectations["device.operations"]?.varies == [])
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
        #expect(throws: Baseline.Refusal.failures(["names.lowercase"])) { try Baseline(report: failing) }
    }

    @Test func recordsWhyACheckDidntRun() throws {
        let report = CheckReport(level: 1, started: .now, finished: .now, device: CheckReportTests.report.device,
                                 host: CheckReportTests.report.host,
                                 results: [CheckResult(expectation: "tape.files", outcome: .notRun, summary: "There are no tapes on the OP-1.")])
        let entry = try #require(try Baseline(report: report).expectations["tape.files"])
        #expect(entry == Baseline.Entry(observed: nil, varies: [], notObserved: "There are no tapes on the OP-1."))
    }

    @Test func roundTripsAndSavesUnderANewName() async throws {
        let baseline = try Baseline(report: await Self.fixtureReport())
        #expect(try Baseline(json: baseline.jsonData()).expectations == baseline.expectations)

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
                           "read.partial", "read.speed"]
        for result in report.results {
            #expect(result.outcome == (notRun.contains(result.expectation) ? .notRun : .pass),
                    "\(result.expectation): \(result.summary)")
        }
    }

    /// The simulator's readme texts are the ones in the committed baseline.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: committed.path(percentEncoded: false))))
    func theSimulatorsReadmesMatchTheBaseline() async throws {
        let baseline = try Baseline(json: Data(contentsOf: Self.committed))
        let readmes = try #require(baseline.expectations["layout.readmes"]?.observed)
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
        for id in baseline.expectations.keys { #expect(Expectation[id: id] != nil, "\(id)") }

        func observed(_ id: String) throws -> CheckValue {
            try #require(baseline.expectations[id]?.observed, "\(id) wasn't observed")
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
    }
}
