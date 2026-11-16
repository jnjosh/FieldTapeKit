import Foundation
import System
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct LevelThreeTests {
    /// A clean level 2 run on a simulated 1.7.3, and the level 3 it leaves. Level 2's folder is left for level 3,
    /// in the temporary directory, which `files` is.
    /// `writesAlbum` lets album writing through, which 1.7.3 has off (`album.write-again`), so the album checks can
    /// be tested. Level 3 then lets it through on its new connection too.
    static func afterLevelTwo(_ faults: [SimulatedMTPDevice.Fault] = [], album: [PendingNode] = LevelTwoTests.defaultAlbum,
                              writesAlbum: Bool = false) async throws
        -> (FieldDevice, SimulatedMTPDevice, CheckReport, LevelThree.Pending?) {
        let (device, simulator) = LevelTwoTests.device(faults, album: album)
        await device.overrideAlbumWrites(writesAlbum)
        let workspace = try LevelTwoTests.workspace()
        let report = await LevelTwoTests.run(device, in: workspace)
        return (device, simulator, report, await LevelThree.pending(after: report, on: device, workspace: workspace))
    }

    static let files = FileManager.default.temporaryDirectory

    static func run(_ device: FieldDevice, _ pending: LevelThree.Pending) async -> CheckReport {
        await device.overrideAlbumWrites(pending.album != nil)
        return await LevelThree.run(on: device, pending: pending, files: files, host: LevelOneTests.host)
    }

    static let expectations = ["reconnect.handles", "names.maximum", "reconnect.renamed", "reconnect.kept",
                               "delete.folder-with-files", "delete.files-then-folder"]

    // MARK: A whole run

    @Test func passesAfterAReconnectAndDeletesTheScratchTape() async throws {
        let (first, simulator, _, pending) = try await Self.afterLevelTwo()
        let saved = try #require(pending)
        #expect(saved.handles.count == 6, "the folder and its 5 files")
        #expect(await LevelThree.refusal(on: first, pending: saved) == .sameConnection)

        await simulator.leaveAndReenterMTPMode()
        let device = FieldDevice.simulated(simulator)
        #expect(await LevelThree.refusal(on: device, pending: saved) == nil)
        let report = await Self.run(device, saved)
        #expect(report.level == 3)
        #expect(report.results.map(\.expectation) == Self.expectations)
        for result in report.results { #expect(result.outcome == .pass, "\(result.expectation): \(result.summary)") }

        let summaries = Dictionary(uniqueKeysWithValues: report.results.map { ($0.expectation, $0.summary) })
        #expect(summaries["reconnect.handles"] == "6 of the scratch tape's 6 objects have new handles since level 2.")
        #expect(summaries["names.maximum"] == "After the reconnect, FIELDCK #1-2, 12 characters, is still listed as fieldck #1-2, "
                + "and FIELDCK #2-13, 13 characters, was cut to fieldck #2-1.")
        #expect(summaries["reconnect.renamed"]?.hasPrefix("The tape is listed lowercase, as fieldck #1-2, and the OP-1 added a ") == true)
        #expect(summaries["reconnect.kept"] == "After the reconnect, all 4 tracks read back byte for byte, and tape.json is unchanged.")
        // As 1.7.3 does.
        #expect(summaries["delete.folder-with-files"] == "One DeleteObject on the folder deleted it and its 6 files.")
        #expect(summaries["delete.files-then-folder"] == "Deleted fieldck #2-1's 6 files, each tape's files and then its "
                + "folder, and it's gone.")
        #expect(saved.album == nil, "album writing is off on 1.7.3")
        #expect(try await device.contents(of: "mixdown/side_b.wav") == LevelTwoTests.sideB, "side B isn't touched")
        for tape in LevelTwo.tapes { #expect(try await !device.fileExists(at: tape)) }
    }

    @Test func aRefusedFolderDeleteFallsBackToFilesFirst() async throws {
        let (_, simulator, _, pending) = try await Self.afterLevelTwo()
        let saved = try #require(pending)
        await simulator.leaveAndReenterMTPMode()
        await simulator.add(faults: [.refuseDeleting(name: "fieldck #1-2", responseCode: PTPResponseCode.generalError)])
        let device = FieldDevice.simulated(simulator)
        let report = await Self.run(device, saved)
        #expect(report.results[4].outcome == .pass)
        #expect(report.results[4].summary == "DeleteObject on the folder, with its 6 files in it, was refused with 0x2002, "
                + "and nothing was deleted. So the files go first.")
        // The fallback then deletes the files, but the folder is still refused, so it fails and says so.
        #expect(report.results[5].outcome == .fail)
        #expect(try await device.fileExists(at: LevelTwo.scratchTape))
    }

    @Test func aPendingLevelThreeSurvivesARelaunchButNotItsConnection() async throws {
        let (_, _, _, pending) = try await Self.afterLevelTwo()
        let saved = try #require(pending)
        let reloaded = try LevelThree.Pending(json: try saved.jsonData())
        #expect(reloaded.connection == nil)
        #expect(reloaded.handles == saved.handles && reloaded.serialNumber == saved.serialNumber)
        #expect(reloaded.album == saved.album)
    }

    // MARK: Before it starts

    @Test func onlyACleanLevelTwoLeavesOne() async throws {
        let (_, _, report, pending) = try await Self.afterLevelTwo([.corruptStored(name: "track_2.wav")])
        #expect(report.results.contains { $0.outcome == .fail })
        #expect(pending == nil)
    }

    @Test func refusesAnotherOP1OrAMissingTape() async throws {
        let (_, simulator, _, pending) = try await Self.afterLevelTwo()
        var saved = try #require(pending)
        await simulator.leaveAndReenterMTPMode()
        let device = FieldDevice.simulated(simulator)
        saved = LevelThree.Pending(serialNumber: "OTHER", levelTwoStarted: saved.levelTwoStarted, handles: saved.handles,
                                   album: nil, connection: nil)
        #expect(await LevelThree.refusal(on: device, pending: saved)?.description
                == "Level 3 is waiting for the OP-1 with serial OTHER, not SIMULATED.")
        #expect(await LevelThree.refusal(on: device, pending: saved)?.endsLevelThree == false)

        _ = await LevelTwo.deleteLeftovers(on: device)
        let mine = LevelThree.Pending(serialNumber: "SIMULATED", levelTwoStarted: saved.levelTwoStarted, handles: saved.handles,
                                      album: nil, connection: nil)
        let report = await Self.run(device, mine)
        #expect(report.results.allSatisfy {
            $0.outcome == .notRun && $0.summary == "The scratch tape fieldck #1-2 isn't on the OP-1 any more, so there's nothing "
                + "for level 3 to check. tapes/ holds: nothing."
        })
        #expect(await LevelThree.refusal(on: device, pending: mine)?.endsLevelThree == true)
    }

    @Test func withoutLeavingMTPModeTheHandlesGiveItAway() async throws {
        // A relaunch of the app without the OP-1 leaving MTP mode: a new connection, the same handles.
        let (_, simulator, _, pending) = try await Self.afterLevelTwo()
        var saved = try #require(pending)
        saved.connection = nil
        let report = await Self.run(FieldDevice.simulated(simulator), saved)
        #expect(report.results[0].outcome == .fail)
        #expect(report.results[0].summary.hasPrefix("All 6 of the scratch tape's objects kept their handles."))
        #expect(report.results.dropFirst().allSatisfy { $0.outcome == .notRun })
        #expect(try await FieldDevice.simulated(simulator).fileExists(at: LevelTwo.scratchTape))
    }

    // MARK: The album

    static let sideB = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 4 * 44_100)
        + Data(repeating: 7, count: 4 * 44_100)
    static let recorded: [PendingNode] = [.file("side_a.wav", .silence(seconds: 1)), .file("side_b.wav", .data(sideB))]

    @Test func sideBIsPutBackWhenTheToneLasted() async throws {
        let (_, simulator, _, pending) = try await Self.afterLevelTwo(album: Self.recorded, writesAlbum: true)
        let saved = try #require(pending)
        #expect(saved.album?.side == .b)
        #expect(LevelThree.steps(for: saved).last?.hasPrefix("Read mixdown/side_b.wav, to see whether level 2's tone lasted") == true)
        await simulator.leaveAndReenterMTPMode()
        let device = FieldDevice.simulated(simulator)
        let report = await Self.run(device, saved)
        let album = try #require(report.results.last)
        #expect(album.expectation == "album.write-kept" && album.outcome == .pass, "\(album.summary)")
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
    }

    @Test func anOP1ThatPutsItsOwnSideBackFailsAndWritesNothing() async throws {
        let (_, simulator, _, pending) = try await Self.afterLevelTwo([.albumKeepsItsOwn], album: Self.recorded, writesAlbum: true)
        let saved = try #require(pending)
        await simulator.leaveAndReenterMTPMode()
        let device = FieldDevice.simulated(simulator)
        let deletedBefore = await simulator.deleted
        let report = await Self.run(device, saved)
        let album = try #require(report.results.last)
        #expect(album.outcome == .fail)
        #expect(album.summary.hasPrefix("After the reconnect, mixdown/side_b.wav was back as it was before level 2: the OP-1 put its own side back"))
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
        #expect(await simulator.deleted.filter { $0.hasPrefix("side_") } == deletedBefore.filter { $0.hasPrefix("side_") },
                "no side was deleted in level 3")
        // The tape checks ran in full before it.
        #expect(report.results.dropLast().allSatisfy { $0.outcome == .pass })
    }

    @Test func aMissingCopyLeavesTheSideAlone() async throws {
        let (_, simulator, _, pending) = try await Self.afterLevelTwo(album: Self.recorded, writesAlbum: true)
        let saved = try #require(pending)
        let album = try #require(saved.album)
        try FileManager.default.removeItem(at: Self.files.appending(path: album.folder).appending(path: album.file))
        await simulator.leaveAndReenterMTPMode()
        let device = FieldDevice.simulated(simulator)
        let report = await Self.run(device, saved)
        #expect(report.results.last?.outcome == .fail)
        #expect(report.results.last?.summary.hasPrefix("Level 2's copy of mixdown/side_b.wav,") == true)
        #expect(try await device.contents(of: "mixdown/side_b.wav") == LevelTwo.Content.sideTone(bytes: Self.sideB.count))
    }

    @Test func theSideIsPutBackEvenIfTheScratchTapeIsGone() async throws {
        let (_, simulator, _, pending) = try await Self.afterLevelTwo(album: Self.recorded, writesAlbum: true)
        let saved = try #require(pending)
        await simulator.leaveAndReenterMTPMode()
        let device = FieldDevice.simulated(simulator)
        _ = await LevelTwo.deleteLeftovers(on: device)
        #expect(await LevelThree.refusal(on: device, pending: saved) == nil)
        let report = await Self.run(device, saved)
        #expect(report.results.dropLast().allSatisfy { $0.outcome == .notRun })
        #expect(report.results.last?.outcome == .pass)
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
    }

    @Test func judgesWhetherTheToneLasted() {
        let copy = Self.sideB
        #expect(LevelThree.writeKept(side: "mixdown/side_b.wav", now: LevelTwo.Content.side, copy: copy, restored: copy).outcome == .pass)
        #expect(LevelThree.writeKept(side: "mixdown/side_b.wav", now: LevelTwo.Content.side, copy: copy, restored: Data()).outcome == .fail)
        #expect(LevelThree.writeKept(side: "mixdown/side_b.wav", now: copy, copy: copy, restored: nil).outcome == .fail)
        #expect(LevelThree.writeKept(side: "mixdown/side_b.wav", now: Data(count: 50), copy: copy, restored: nil).summary
                == "After the reconnect, mixdown/side_b.wav is 50 bytes, neither level 2's tone nor the side as it was. Nothing was "
                + "written. Level 2's copy is kept.")
    }

    // MARK: Judging

    @Test func judgesWhatWasKept() throws {
        let tracks = [("track_1.wav", true), ("track_2.wav", true)]
        let written = LevelTwo.Content.tapeJSON
        var json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        json["pos"] = 1234
        json["tempometronomelevel"] = 22.955
        let played = try JSONSerialization.data(withJSONObject: json)
        let finding = LevelThree.kept(tracks: tracks, written: written, read: played)
        #expect(finding.outcome == .pass)
        #expect(finding.summary == "After the reconnect, all 2 tracks read back byte for byte, and tape.json is the same "
                + "apart from pos and tempometronomelevel.")

        json["loop"] = false
        #expect(LevelThree.kept(tracks: tracks, written: written, read: try JSONSerialization.data(withJSONObject: json)).summary
                == "After the reconnect, tape.json changed in loop.")
        #expect(LevelThree.kept(tracks: [("track_1.wav", false)], written: written, read: written).outcome == .fail)
        #expect(LevelThree.kept(tracks: tracks, written: written, read: nil).summary == "tape.json is gone after the reconnect.")
    }

    @Test func judgesTheFolderDelete() {
        #expect(LevelThree.folderWithFiles(responseCode: nil, files: 6, folderGone: true, filesLeft: 0).summary
                == "One DeleteObject on the folder deleted it and its 6 files.")
        #expect(LevelThree.folderWithFiles(responseCode: nil, files: 6, folderGone: true, filesLeft: 2).outcome == .fail)
        #expect(LevelThree.folderWithFiles(responseCode: 0x2002, files: 6, folderGone: false, filesLeft: 4).outcome == .fail)
        #expect(LevelThree.folderWithFiles(responseCode: nil, files: 6, folderGone: false, filesLeft: 6).summary
                == "DeleteObject on the folder was answered OK, but the folder is still there and 6 of its 6 files are left.")
    }

    static func folder(_ path: FilePath) throws -> FieldItem {
        let dataset = PTPObjectInfo.dataset(storageID: SimulatedMTPDevice.storageID, format: PTPObjectFormat.association,
                                            size: 0, parent: 0, filename: path.lastComponent!.string,
                                            associationType: PTPAssociationType.genericFolder)
        return FieldItem(path: path, info: try PTPObjectInfo(dataset))
    }

    @Test func judgesTheNames() throws {
        let item = try Self.folder("tapes/fieldck #1-2")
        #expect(LevelThree.nameKept(sent: "FIELDCK #1-2", listed: item, long: "FIELDCK #2-13", longListed: "fieldck #2-1").outcome == .pass)
        #expect(LevelThree.nameKept(sent: "FIELDCK #1-2", listed: item, long: "FIELDCK #2-13", longListed: "fieldck #2-13").summary
                == "After the reconnect, FIELDCK #1-2 is still listed as fieldck #1-2, but FIELDCK #2-13 is listed as fieldck #2-13, "
                + "not cut to fieldck #2-1.")
        #expect(LevelThree.nameKept(sent: "FIELDCK #1-2", listed: item, long: "FIELDCK #2-13", longListed: nil).outcome == .fail)
        let cut = try Self.folder("tapes/fieldck #1-")
        #expect(LevelThree.nameKept(sent: "FIELDCK #1-2", listed: cut, long: "FIELDCK #2-13", longListed: "fieldck #2-1").outcome == .fail)
    }

    @Test func judgesTheRename() {
        #expect(LevelThree.renamed(listed: "fieldck #1-2", files: ["tape.json"], readmeBytes: nil).outcome == .fail)
        #expect(LevelThree.renamed(listed: "FieldCheck #1-2", files: ["readme.txt"], readmeBytes: 104).outcome == .fail)
        #expect(LevelThree.handles(before: ["a": 1], after: [:]).outcome == .fail)
        #expect(LevelThree.handles(before: ["a": 1, "b": 2], after: ["a": 1, "b": 9]).outcome == .pass)
    }
}
