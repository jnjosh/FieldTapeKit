import Foundation
import Synchronization
import System
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct SideRestoreTests {
    static let sideB = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 4 * 44_100)
        + Data(repeating: 7, count: 4 * 44_100)

    /// Side B holding FieldCheck's tone, and a level 2 folder in a new `files` folder with the copy of side B.
    static func setUp(sideB now: Data = LevelTwo.Content.side, timeout: Duration = .seconds(30))
        throws -> (FieldDevice, SimulatedMTPDevice, files: URL) {
        let (_, simulator) = LevelTwoTests.device(album: [.file("side_a.wav", .silence(seconds: 1)), .file("side_b.wav", .data(now))])
        let files = try LevelTwoTests.workspace()
        let folder = files.appending(path: "level2-2026-11-16T035851Z")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.sideB.write(to: folder.appending(path: "side_b before level 2.wav"))
        return (FieldDevice.simulated(simulator, timeout: timeout, pingTimeout: .milliseconds(100)), simulator, files)
    }

    final class Lines: Sendable {
        let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    @Test func findsLevelTwosCopiesNewestFirst() throws {
        let (_, _, files) = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: files) }
        let older = files.appending(path: "level2-2026-11-15T000000Z")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try Data([1]).write(to: older.appending(path: "side_a before level 2.wav"))
        try Data([2]).write(to: files.appending(path: "side_b before level 2.wav"), options: [])  // not in a level 2 folder

        let copies = SideRestore.copies(in: files)
        #expect(copies.map(\.folder) == ["level2-2026-11-16T035851Z", "level2-2026-11-15T000000Z"])
        #expect(copies[0].side == .b && copies[0].size == Self.sideB.count && copies[0].sha256 == LevelThree.sha256(Self.sideB))
    }

    @Test func putsTheSideBackOverTheToneAndTracesEachRequest() async throws {
        let (device, simulator, files) = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        #expect(try await SideRestore.holdsTone(.b, on: device))

        let lines = Lines()
        let outcome = await SideRestore.putBack(copy, on: device) { lines.append($0) }
        #expect(outcome.succeeded, "\(outcome.summary)")
        #expect(outcome.summary == "mixdown/side_b.wav was put back from level2-2026-11-16T035851Z/side_b before level 2.wav, "
                + "176,444 bytes, and reads back byte for byte.")
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
        #expect(await simulator.deleted == ["side_b.wav"])
        #expect(lines.all.contains { $0.hasPrefix("→ deleteObject 0x") })
        #expect(lines.all.contains("→ sendObject, 176444 bytes out"))
        #expect(lines.all.contains { $0.hasPrefix("← sendObject 0x2001, 0 bytes in, ") && $0.hasSuffix(" ms") })
        #expect(try await !SideRestore.holdsTone(.b, on: device))
    }

    @Test func aWarmUpWritesAndDeletesThePresetFirst() async throws {
        let (device, simulator, files) = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        let lines = Lines()
        let outcome = await SideRestore.putBack(copy, on: device, warmUp: true) { lines.append($0) }
        #expect(outcome.succeeded, "\(outcome.summary)")
        #expect(await simulator.deleted == ["fieldcheck.wav", "side_b.wav"])
        let warmUp = try #require(lines.all.firstIndex(of: "Warm-up done"))
        // The preset's delete comes before the warm-up ends, and the side's after it.
        let sideDelete = try #require(lines.all.lastIndex { $0.hasPrefix("→ deleteObject ") })
        #expect(warmUp < sideDelete)
        #expect(try await !device.fileExists(at: "drum/user/fieldcheck.wav"))
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
    }

    @Test func aLeftoverPresetStopsTheWarmUp() async throws {
        let (device, simulator, files) = try Self.setUp()
        defer { try? FileManager.default.removeItem(at: files) }
        _ = try await device.write(LevelTwo.Content.preset, to: "drum/user/fieldcheck.wav")
        let copy = try #require(SideRestore.copies(in: files).first)
        let outcome = await SideRestore.putBack(copy, on: device, warmUp: true) { _ in }
        #expect(!outcome.succeeded && outcome.summary.hasPrefix("drum/user/fieldcheck.wav is already on the OP-1"))
        #expect(await simulator.deleted.isEmpty)
    }

    /// A recording of `seconds` the person made, not FieldCheck's tone or the copy.
    static func recording(seconds: Int) -> Data {
        WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: seconds * 4 * 44_100)
            + Data(repeating: 9, count: seconds * 4 * 44_100)
    }

    @Test func aRecordingIsntTouchedWithoutACopyOfIt() async throws {
        let (device, simulator, files) = try Self.setUp(sideB: Self.recording(seconds: 2))
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        let outcome = await SideRestore.putBack(copy, on: device) { _ in }
        #expect(!outcome.succeeded && outcome.summary == "mixdown/side_b.wav doesn't hold FieldCheck's tone, so it wasn't touched.")
        #expect(await simulator.deleted.isEmpty)
    }

    @Test func aLongerRecordingIsCopiedOffThenReplaced() async throws {
        let recording = Self.recording(seconds: 2)
        let (device, simulator, files) = try Self.setUp(sideB: recording)
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        guard case .other(let side) = try await SideRestore.current(copy, on: device) else { Issue.record("not other"); return }
        #expect(side.size == recording.count)

        let replaced = files.appending(path: "level2-2026-11-16T035851Z/side_b replaced.wav")
        let outcome = await SideRestore.putBack(copy, on: device, copyingReplacedTo: replaced) { _ in }
        #expect(outcome.succeeded, "\(outcome.summary)")
        #expect(outcome.summary.hasSuffix(" What it held before is kept as side_b replaced.wav."))
        #expect(try Data(contentsOf: replaced) == recording)
        #expect(try await device.contents(of: "mixdown/side_b.wav") == Self.sideB)
        #expect(await simulator.deleted == ["side_b.wav"])
        #expect(SideRestore.copies(in: files).isEmpty, "a copy that's back is offered no more")
    }

    @Test func aShorterRecordingIsRefusedSoTheSideDoesntGrow() async throws {
        // 100 frames of a recording, 444 bytes, shorter than the copy.
        let short = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 400) + Data(repeating: 1, count: 400)
        let (device, simulator, files) = try Self.setUp(sideB: short)
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        let replaced = files.appending(path: "level2-2026-11-16T035851Z/side_b replaced.wav")
        let outcome = await SideRestore.putBack(copy, on: device, copyingReplacedTo: replaced) { _ in }
        #expect(!outcome.succeeded)
        #expect(outcome.summary == "mixdown/side_b.wav is 444 bytes, shorter than the copy's 176,444. Only a put-back over a longer "
                + "recording has worked on the OP-1, so nothing was written. Record at least 1s on it on the OP-1, then try again.")
        #expect(await simulator.deleted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: replaced.path))
    }

    @Test func aSideThatsBackAlreadyIsMarked() async throws {
        let (device, simulator, files) = try Self.setUp(sideB: Self.sideB)
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        #expect(try await SideRestore.current(copy, on: device) == .matches)
        let outcome = await SideRestore.putBack(copy, on: device) { _ in }
        #expect(outcome.succeeded && outcome.summary.hasSuffix("so nothing was written."))
        #expect(await simulator.deleted.isEmpty)
        #expect(SideRestore.copies(in: files).isEmpty)
    }

    @Test func aHangIsTracedToItsRequest() async throws {
        let (device, simulator, files) = try Self.setUp(timeout: .milliseconds(200))
        defer { try? FileManager.default.removeItem(at: files) }
        let copy = try #require(SideRestore.copies(in: files).first)
        // The OP-1 stops answering a few requests in.
        await simulator.add(faults: [.silent(fromRequest: await simulator.requestCount + 8)])
        let lines = Lines()
        let outcome = await SideRestore.putBack(copy, on: device) { lines.append($0) }
        #expect(!outcome.succeeded)
        #expect(outcome.summary.hasSuffix("Whether the last request took effect isn't known: the trace shows which one got no answer. "
                + "The copy is kept."))
        let failed = try #require(lines.all.firstIndex { $0.hasPrefix("✕ ") })
        #expect(lines.all[failed].hasSuffix(": no answer after 0.2 seconds"))
        #expect(lines.all[failed - 1].hasPrefix("→ "), "the request before it is the one that hung")
        #expect(lines.all.last == "  a GetDeviceInfo ping got no answer in 0.1 seconds either")
    }
}
