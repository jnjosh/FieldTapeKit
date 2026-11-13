import Foundation
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct LevelOneTests {
    static let host = CheckReport.Host(app: "test", model: "Mac", system: "macOS 27")

    static func run(_ id: String, on device: FieldDevice) async throws -> CheckResult {
        let check = try #require(LevelOne.checks(for: device).first { $0.expectation == id })
        return await CheckRunner.run([check])[0]
    }

    // MARK: A whole run

    @Test func everyCheckPassesOnASimulated173() async {
        let device = FieldDevice.simulated(await OP1Fixture.device())
        let report = await LevelOne.run(on: device, host: Self.host)
        #expect(report.level == 1)
        #expect(report.device == CheckReport.Device(device.info))
        #expect(report.results.map(\.expectation) == [
            "device.identity", "device.operations", "device.storage", "session.implicit", "session.data-phase",
            "layout.folders", "layout.readmes", "names.lowercase", "tape.files", "tape.wav-format", "tape.json-keys",
            "tape.json-units", "tape.types", "album.files", "album.wav-format", "read.partial", "read.speed",
        ])
        for result in report.results {
            #expect(result.outcome == .pass, "\(result.expectation): \(result.summary)")
            #expect(result.observed != nil, "\(result.expectation)")
        }
    }

    @Test func aDisconnectPartwayFailsThatCheckAndSkipsTheRest() async {
        let simulator = await OP1Fixture.device(faults: [.silent(fromRequest: 1)])
        let device = FieldDevice.simulated(simulator, timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
        let report = await LevelOne.run(on: device, host: Self.host)
        // device.identity sends nothing, so it still passes.
        #expect(report.results.map(\.outcome) == [.pass, .fail] + Array(repeating: .notRun, count: 15))
        #expect(report.results[1].summary == "The OP-1 disconnected during this check.")
    }

    @Test func checksAreRealExpectations() async {
        let ids = LevelOne.checks(for: FieldDevice.simulated()).map(\.expectation)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { Expectation[id: $0] != nil })
    }

    // MARK: device.*

    @Test func identity() {
        let pass = LevelOne.identity(.op1)
        #expect(pass.outcome == .pass)
        #expect(pass.observed == ["vendorID": "0x2367", "productID": "0x0102", "name": "OP-1"])

        // Outside MTP mode the OP-1 is product 0x8102 (PROBE-NOTES.md).
        let other = LevelOne.identity(USBIdentity(vendorID: 0x2367, productID: 0x8102, name: "OP-1 Field"))
        #expect(other.outcome == .fail)
        #expect(other.summary == "Connected, but not as 1.7.3 did: product 0x8102, name \"OP-1 Field\".")

        #expect(LevelOne.identity(nil).outcome == .notRun)
    }

    @Test func operations() async throws {
        let pass = try await Self.run("device.operations", on: FieldDevice.simulated(await OP1Fixture.device()))
        #expect(pass.summary == "21 operations listed, including all 10 that FieldTapeKit sends.")
        guard case .record(let observed) = pass.observed, case .list(let listed) = observed["operations"] else {
            Issue.record("no operation list")
            return
        }
        #expect(listed.count == 21)
        #expect(listed.first == "0x1002")
        #expect(observed["vendorExtensionID"] == 6)

        let withoutPartial = SimulatedMTPDevice.operations173.filter { $0 != 0x101B }
        let fail = try await Self.run("device.operations",
                                      on: FieldDevice.simulated(await OP1Fixture.device(operations: withoutPartial)))
        #expect(fail.outcome == .fail)
        #expect(fail.summary == "FieldTapeKit sends operations the OP-1 doesn't list: getPartialObject (0x101B).")
    }

    @Test func storage() async throws {
        let result = try await Self.run("device.storage", on: FieldDevice.simulated(await OP1Fixture.device()))
        #expect(result.outcome == .pass)
        #expect(result.summary.hasPrefix("One storage, 0x00010001, with "))
        guard case .record(let observed) = result.observed, case .list(let storages) = observed["storages"],
              case .record(let only) = storages.first else {
            Issue.record("no storage observed")
            return
        }
        #expect(only["capacity"] == 6_429_185_024)
        #expect(only["id"] == "0x00010001")

        #expect(LevelOne.storage([]).summary == "The OP-1 lists no storage.")
        #expect(LevelOne.storage([]).outcome == .fail)
    }

    // MARK: session.*

    @Test func implicitSession() async throws {
        let pass = try await Self.run("session.implicit", on: FieldDevice.simulated(await OP1Fixture.device()))
        #expect(pass.outcome == .pass)
        #expect(pass.summary == "GetObjectHandles answered with no OpenSession sent, listing 4 objects at the root.")

        let refusing = await OP1Fixture.device(faults: [.refuse(request: 1, responseCode: 0x2003)])
        let fail = try await Self.run("session.implicit", on: FieldDevice.simulated(refusing))
        #expect(fail.outcome == .fail)
        #expect(fail.summary == "GetObjectHandles, with no OpenSession sent, got Session Not Open (0x2003).")
        #expect(fail.observed == ["openSessionSent": false, "getObjectHandles": "0x2003"])
    }

    @Test func dataPhase() async throws {
        let simulator = await OP1Fixture.device()
        let pass = try await Self.run("session.data-phase", on: FieldDevice.simulated(simulator))
        #expect(pass.outcome == .pass)
        #expect(pass.summary == "Data arrived without its container header for getDeviceInfo and getStorageIDs.")

        let headed = FieldDevice(session: MTPSession(transport: HeaderedTransport(simulator)),
                                 info: FieldDevice.simulated(simulator).info, profile: .v1_7_3, usb: .op1)
        let fail = try await Self.run("session.data-phase", on: headed)
        #expect(fail.outcome == .fail)
        guard case .record(let observed) = fail.observed, case .record(let info) = observed["getDeviceInfo"] else {
            Issue.record("no observation")
            return
        }
        #expect(info["containerHeader"] == true)
    }

    // MARK: layout.*

    @Test func folders() async throws {
        let pass = try await Self.run("layout.folders", on: FieldDevice.simulated(await OP1Fixture.device()))
        #expect(pass.summary == "All 24 expected folders are there, and 2 tape folders.")

        let changed = await OP1Fixture.device(skipping: ["drum/slots/3"]) { simulator, folders in
            await simulator.addFolder("mine", in: folders["synth"]!)
        }
        let fail = try await Self.run("layout.folders", on: FieldDevice.simulated(changed))
        #expect(fail.outcome == .fail)
        #expect(fail.summary == "Missing: drum/slots/3.")
        guard case .record(let observed) = fail.observed, case .list(let found) = observed["expected"] else {
            Issue.record("no observation")
            return
        }
        #expect(found.count == 23)
        #expect(!found.contains("drum/slots/3"))
        // Only what the firmware decides, so a baseline doesn't depend on whose OP-1 it was.
        #expect(Set(observed.keys) == ["expected"])
    }

    @Test func foldersPeopleMakeAreAllowed() async throws {
        let device = await OP1Fixture.device { simulator, folders in
            await simulator.addFolder("mine", in: folders["drum"]!)
        }
        let result = try await Self.run("layout.folders", on: FieldDevice.simulated(device))
        #expect(result.outcome == .pass)
        #expect(result.summary.hasSuffix(" Also there: drum/mine."))
    }

    @Test func readmes() async throws {
        let pass = try await Self.run("layout.readmes", on: FieldDevice.simulated(await OP1Fixture.device()))
        #expect(pass.outcome == .pass, "\(pass.summary)")
        #expect(pass.summary == "Read 5 readme.txt files. The allowed names match FieldTapeKit's rules for mixdown and 2 tapes.")
        guard case .record(let observed) = pass.observed else { Issue.record("no observation"); return }
        #expect(Set(observed.keys) == ["mixdown/readme.txt", "tapes/*/readme.txt", "drum/user/readme.txt",
                                       "synth/user/readme.txt"])
        #expect(observed["tapes/*/readme.txt"] == .string(OP1Fixture.tapeReadme))
    }

    @Test func readmesThatChangeAFolderRuleFail() {
        let texts = [
            "mixdown/readme.txt": OP1Fixture.mixdownReadme,
            "tapes/a/readme.txt": OP1Fixture.tapeReadme,
            "tapes/b/readme.txt": OP1Fixture.tapeReadme.replacingOccurrences(of: "track_4.wav", with: "track_4.wav track_5.wav"),
        ]
        let result = LevelOne.readmes(texts, profile: .v1_7_3)
        #expect(result.outcome == .fail)
        #expect(result.summary == "Folder rules differ from FieldTapeKit's: tapes/b/readme.txt allows track_1.wav "
                + "track_2.wav track_3.wav track_4.wav track_5.wav, not track_1.wav track_2.wav track_3.wav track_4.wav.")
        guard case .record(let observed) = result.observed else { Issue.record("no observation"); return }
        #expect(observed["tapes/*/readme.txt"]?.isList == true)
    }

    @Test func aMissingMixdownReadmeFails() {
        let result = LevelOne.readmes(["tapes/a/readme.txt": OP1Fixture.tapeReadme], profile: .v1_7_3)
        #expect(result.outcome == .fail)
        #expect(result.summary == "Folder rules differ from FieldTapeKit's: mixdown/readme.txt is missing.")
    }

    @Test func noTapesIsFine() {
        let result = LevelOne.readmes(["mixdown/readme.txt": OP1Fixture.mixdownReadme], profile: .v1_7_3)
        #expect(result.outcome == .pass)
        #expect(result.summary == "Read 1 readme.txt files. The allowed names match FieldTapeKit's rules for mixdown.")
    }

    @Test func allowedNames() {
        #expect(LevelOne.allowedNames(in: OP1Fixture.mixdownReadme) == ["side_a.wav", "side_b.wav"])
        #expect(LevelOne.allowedNames(in: OP1Fixture.presetReadme) == nil)
        #expect(LevelOne.allowedNames(in: "Allowed Names:  a.wav\tb.wav ") == ["a.wav", "b.wav"])
    }

    // MARK: names.lowercase

    @Test func lowercase() async throws {
        let pass = try await Self.run("names.lowercase", on: FieldDevice.simulated(await OP1Fixture.device()))
        #expect(pass.outcome == .pass)
        #expect(pass.summary == "All 47 names are lowercase.")
        #expect(pass.observed == ["notLowercase": []])

        let mixed = await OP1Fixture.device { simulator, folders in
            await simulator.addFolder("PROBE 1-#A", in: folders["tapes"]!)
        }
        let fail = try await Self.run("names.lowercase", on: FieldDevice.simulated(mixed))
        #expect(fail.outcome == .fail)
        #expect(fail.summary == "1 of 48 names aren't lowercase: tapes/PROBE 1-#A.")
    }

    @Test func hex() {
        #expect(LevelOne.hex(0x2367) == "0x2367")
        #expect(LevelOne.hex(UInt16(0x101B)) == "0x101B")
        #expect(LevelOne.hex(UInt32(0x0001_0001), digits: 8) == "0x00010001")
        #expect(LevelOne.hex(6) == "0x0006")
    }
}

extension CheckValue {
    var isList: Bool {
        if case .list = self { true } else { false }
    }
}

/// Hands back every data phase with a container header in front, as ImageCaptureCore never has on 1.7.3.
struct HeaderedTransport: MTPTransport {
    let base: SimulatedMTPDevice

    init(_ base: SimulatedMTPDevice) {
        self.base = base
    }

    func transact(command: Data, dataOut: Data?) async throws -> MTPTransaction {
        var transaction = try await base.transact(command: command, dataOut: dataOut)
        guard !transaction.data.isEmpty else { return transaction }
        var header = Data()
        header.appendLittleEndian(UInt32(PTPContainer.headerSize + transaction.data.count))
        header.appendLittleEndian(PTPContainerType.data)
        header.append(command[6..<8])
        header.append(command[8..<12])
        transaction.data = header + transaction.data
        return transaction
    }
}
