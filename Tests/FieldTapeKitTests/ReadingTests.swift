import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct ReadingTests {
    static let json = Data(#"{"clips":[],"version":1}"#.utf8)
    static let device = FieldDevice.simulated {
        Directory("tapes") { Directory("2026-220#02") { File("tape.json", data: json) } }
        Directory("mixdown") { File("side_a.wav", seconds: 1) }
    }
    static let sideSize = 44 + 44_100 * 4

    // MARK: Whole reads

    @Test func readsAWholeFile() async throws {
        #expect(try await Self.device.contents(of: "tapes/2026-220#02/tape.json") == Self.json)
        #expect(try await Self.device.contents(of: "TAPES/2026-220#02/TAPE.JSON") == Self.json)
        #expect(try await Self.device.contents(of: "mixdown/side_a.wav").count == Self.sideSize)
    }

    @Test func refusesAFileOverTheLimit() async throws {
        await #expect { try await Self.device.contents(of: "Mixdown/side_a.wav", maximumSize: 1_000) } throws: { error in
            let error = error as? FieldError
            return error?.code == .tooLarge && error?.path == "mixdown/side_a.wav"
                && error?.errorDescription == "On the OP-1, mixdown/side_a.wav is too large to read into memory."
        }
        #expect(try await Self.device.contents(of: "mixdown/side_a.wav", maximumSize: Self.sideSize).count == Self.sideSize)
    }

    @Test func aFolderIsNotAFile() async {
        await #expect { try await Self.device.contents(of: .op1Tapes) } throws: { error in
            let error = error as? FieldError
            return error?.code == .isADirectory && error?.errorDescription == "On the OP-1, tapes is a folder, not a file."
        }
    }

    @Test func somethingMissingIsNotFound() async {
        await #expect { try await Self.device.contents(of: "mixdown/side_c.wav") } throws: {
            ($0 as? FieldError)?.code == .notFound && ($0 as? FieldError)?.path == "mixdown/side_c.wav"
        }
    }

    // MARK: Ranges

    @Test func readsARange() async throws {
        let whole = try await Self.device.contents(of: "tapes/2026-220#02/tape.json")
        #expect(try await Self.device.contents(of: "tapes/2026-220#02/tape.json", range: 2..<7) == whole[2..<7])
        let header = try await Self.device.contents(of: "mixdown/side_a.wav", range: 0..<WAVHeader.size)
        let parsed = try WAVHeader(header)
        #expect(parsed.format == FirmwareProfile.v1_7_3.sideFormat)
    }

    @Test func aRangePastTheEndGivesWhatsThere() async throws {
        let path: FilePath = "tapes/2026-220#02/tape.json"
        let count = Self.json.count
        #expect(try await Self.device.contents(of: path, range: (count - 3)..<(count + 100)) == Self.json.suffix(3))
        #expect(try await Self.device.contents(of: path, range: count..<(count + 5)).isEmpty)
        #expect(try await Self.device.contents(of: path, range: 4..<4).isEmpty)
    }

    // MARK: The OP-1's stale sizes

    /// As `rebuild.stale-size` describes: within the session, a rebuilt file still lists and reads at its old size.
    @Test func aRebuiltFileReadsAtItsOldSize() async throws {
        let simulator = SimulatedMTPDevice()
        let tape = await simulator.addFolder("2026-312#01")
        let handle = await simulator.addFile("tape.json", data: Data(repeating: 0x61, count: 251), format: PTPObjectFormat.text, in: tape)
        await simulator.rebuild(handle, with: Data(repeating: 0x62, count: 386))
        let device = FieldDevice.simulated(simulator)

        #expect(try await device.item(at: "2026-312#01/tape.json")?.size == 251)
        let read = try await device.contents(of: "2026-312#01/tape.json")
        #expect(read == Data(repeating: 0x62, count: 251))
    }

    /// `reconnect.renamed` and `reconnect.handles`: after the OP-1 leaves MTP mode and comes back, names are
    /// lowercase, a tape made over MTP has a readme.txt, handles are new, and a rebuilt file lists at its real size.
    @Test func aReconnectRenamesRenumbersAndRefreshes() async throws {
        let simulator = SimulatedMTPDevice()
        let tapes = await simulator.addFolder("tapes")
        let tape = await simulator.addFolder("New Tape", in: tapes)
        let handle = await simulator.addFile("tape.json", data: Data(repeating: 0x61, count: 251), format: PTPObjectFormat.text, in: tape)
        await simulator.rebuild(handle, with: Data(repeating: 0x62, count: 386))
        let before = FieldDevice.simulated(simulator)
        let old = try #require(try await before.locate("tapes/new tape/tape.json"))

        await simulator.leaveAndReenterMTPMode()
        let after = FieldDevice.simulated(simulator)
        #expect(after.id != before.id)
        #expect(try await after.contentsOfDirectory(at: "tapes").map(\.name) == ["new tape"])
        #expect(Set(try await after.contentsOfDirectory(at: "tapes/new tape").map(\.name)) == ["tape.json", "readme.txt"])
        let new = try #require(try await after.locate("tapes/new tape/tape.json"))
        #expect(new.handle != old.handle)
        #expect(try await after.contents(of: "tapes/new tape/tape.json") == Data(repeating: 0x62, count: 386))
    }

    /// `names.maximum`: a tape name longer than 12 characters is cut to 12 once the OP-1 leaves MTP mode.
    @Test func aReconnectCutsALongTapeName() async throws {
        let simulator = SimulatedMTPDevice()
        let tapes = await simulator.addFolder("tapes")
        await simulator.addFolder("fieldcheck #1-2", in: tapes)
        await simulator.addFolder("fieldck #1-2", in: tapes)
        await simulator.leaveAndReenterMTPMode()
        let names = try await FieldDevice.simulated(simulator).contentsOfDirectory(at: "tapes").map(\.name)
        #expect(Set(names) == ["fieldcheck #", "fieldck #1-2"])
    }
}

@Suite struct CopyingTests {
    static let device = ReadingTests.device

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CopyingTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copiesAFileAndSaysWhere() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "side_a.wav")
        let url = try await Self.device.copyItem(at: "mixdown/side_a.wav", to: destination)
        #expect(url == destination)
        let original = try await Self.device.contents(of: "mixdown/side_a.wav")
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func neverOverwritesALocalFile() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "tape.json")
        try Data("mine".utf8).write(to: destination)

        let second = try await Self.device.copyItem(at: "tapes/2026-220#02/tape.json", to: destination)
        let third = try await Self.device.copyItem(at: "tapes/2026-220#02/tape.json", to: destination)
        #expect(second.lastPathComponent == "tape 2.json")
        #expect(third.lastPathComponent == "tape 3.json")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "mine")
        #expect(try Data(contentsOf: third) == ReadingTests.json)
    }

    @Test func numbersANameWithoutAnExtension() {
        let url = URL(filePath: "/tmp/readme")
        #expect(FieldDevice.numbered(url, 2).lastPathComponent == "readme 2")
        #expect(FieldDevice.numbered(URL(filePath: "/tmp/abc- 012#-#.reelarchive"), 3).lastPathComponent
                == "abc- 012#-# 3.reelarchive")
    }

    @Test func reportsProgressInThreeSteps() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = ProgressManager(totalCount: 1)
        try await Self.device.copyItem(at: "mixdown/side_a.wav", to: folder.appending(path: "a.wav"),
                                       progress: parent.subprogress(assigningCount: 1))
        #expect(parent.fractionCompleted == 1)
    }

    @Test func aMissingLocalFolderIsALocalFailure() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "missing/side_a.wav")
        await #expect { try await Self.device.copyItem(at: "mixdown/side_a.wav", to: destination) } throws: { error in
            let error = error as? FieldError
            return error?.code == .localFileFailed && error?.path == "mixdown/side_a.wav" && error?.underlying != nil
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    /// GetObject coming back shorter than the file lists is a bad read, and nothing is written.
    @Test func aShortReadIsNotACopy() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let simulator = SimulatedMTPDevice()
        let mixdown = await simulator.addFolder("mixdown")
        await simulator.addFile("side_a.wav", data: Data(count: 1_000), in: mixdown)
        let device = FieldDevice.simulated(simulator)
        // Listing the root and mixdown takes four requests (handles and info for each), and GetObject is the fifth.
        await simulator.add(faults: [.shortData(request: 5, keeping: 10)])

        await #expect { try await device.copyItem(at: "mixdown/side_a.wav", to: folder.appending(path: "a.wav")) } throws: {
            ($0 as? FieldError)?.code == .verificationFailed
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    @Test func cancellingFirstCopiesNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.device.copyItem(at: "mixdown/side_a.wav", to: folder.appending(path: "a.wav"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    @Test func aDisconnectCopiesNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let simulator = SimulatedMTPDevice()
        let mixdown = await simulator.addFolder("mixdown")
        await simulator.addFile("side_a.wav", data: Data(count: 1_000), in: mixdown)
        let device = FieldDevice.simulated(simulator, timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
        await simulator.add(faults: [.silent(fromRequest: 5)])

        await #expect { try await device.copyItem(at: "mixdown/side_a.wav", to: folder.appending(path: "a.wav")) } throws: {
            ($0 as? FieldError)?.code == .disconnected
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    /// The copy is of what the OP-1 serves, so a file rebuilt within the session copies at its old size.
    @Test func aRebuiltFileCopiesAsTheOP1ServesIt() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let simulator = SimulatedMTPDevice()
        let handle = await simulator.addFile("tape.json", data: Data(count: 251), format: PTPObjectFormat.text)
        await simulator.rebuild(handle, with: Data(repeating: 1, count: 386))
        let url = try await FieldDevice.simulated(simulator).copyItem(at: "tape.json", to: folder.appending(path: "tape.json"))
        #expect(try Data(contentsOf: url) == Data(repeating: 1, count: 251))
    }
}
