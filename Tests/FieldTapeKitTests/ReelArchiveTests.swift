import AppleArchive
import CryptoKit
import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct ReelArchiveTests {
    static let format = FirmwareProfile.v1_7_3.trackFormat

    /// A Vintage tape with audio on tracks 1 and 3, as its files would come off the OP-1. The samples aren't silence,
    /// so a changed byte changes the SHA-256.
    static let files: [(String, Data)] = {
        let frames = [1_000, 0, 500, 0]
        var files: [(String, Data)] = frames.enumerated().map { index, count in
            let samples = Data((0..<(count * format.frameBytes)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) })
            return ("track_\(index + 1).wav", WAVHeader.bytes(format: format, dataBytes: samples.count) + samples)
        }
        files.append(("tape.json", SimulatedTape.tapeJSON(type: .vintage, frames: frames)))
        return files
    }()

    static let created = Date(timeIntervalSince1970: 1_794_700_000)

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ReelArchiveTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(to url: URL, compression: ReelArchive.Compression = .none,
                      files: [(String, Data)] = files) throws -> URL {
        let writer = try ReelArchiveWriter(creating: url, compression: compression)
        for (name, data) in files { try writer.add(name, data: data) }
        try writer.finish(name: TapeName(listed: "2026-220#02"), type: .vintage, model: "OP-1", serialNumber: "SIMULATED",
                          firmware: "1.7.3", created: created)
        return url
    }

    /// Writes any entries at all, for archives FieldTapeKit's writer wouldn't make.
    static func writeRaw(to url: URL, _ entries: [(String, Data)]) throws {
        try ArchiveByteStream.withFileStream(path: FilePath(url.path), mode: .writeOnly, options: [.create, .truncate],
                                             permissions: FilePermissions(rawValue: 0o644)) { file in
            try ArchiveStream.withEncodeStream(writingTo: file) { encoder in
                for (name, data) in entries {
                    let header = ArchiveHeader()
                    header.append(.uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
                    header.append(.string(key: .init("PAT"), value: name))
                    header.append(.blob(key: .init("DAT"), size: UInt64(data.count)))
                    try encoder.writeHeader(header)
                    try data.withUnsafeBytes { try encoder.writeBlob(key: .init("DAT"), from: $0) }
                }
            }
        }
    }

    static func reel(format: Int = 1, files: [(String, Data)] = files) throws -> Data {
        let infos = files.map { name, data in
            ReelMetadata.FileInfo(name: name, size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return try ReelMetadata.encoder().encode(ReelMetadata(format: format, tape: .init(name: "x", type: 0),
                                                              device: .init(model: "OP-1", serialNumber: "S", firmware: "1.7.3"),
                                                              created: created, files: infos))
    }

    static func expectRefusal(_ code: FieldError.Code, _ reason: String, opening url: URL) {
        #expect { try ReelArchive(contentsOf: url) } throws: { error in
            let error = error as? FieldError
            return error?.code == code && error?.reason == reason
        }
    }

    // MARK: Writing and opening

    @Test(arguments: [ReelArchive.Compression.none, .lz4, .lzfse, .zlib, .lzma])
    func roundTrips(compression: ReelArchive.Compression) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.write(to: folder.appending(path: "2026-220#02.reelarchive"), compression: compression)

        let archive = try ReelArchive(contentsOf: url)
        #expect(archive.format == 1)
        #expect(archive.name.string == "2026-220#02" && archive.type == .vintage)
        #expect(archive.model == "OP-1" && archive.serialNumber == "SIMULATED" && archive.firmware == "1.7.3")
        #expect(archive.created == Self.created)
        #expect(archive.manifest.data == Self.files[4].1)
        #expect(archive.tracks.map(\.size) == Self.files.prefix(4).map(\.1.count))
        #expect(archive.tracks.map(\.isBlank) == [false, true, false, true])
        #expect(archive.tracks[0].sha256 == SHA256.hash(data: Self.files[0].1).map { String(format: "%02x", $0) }.joined())
        #expect(archive.duration == .milliseconds(22))
        #expect(archive.url == url)
    }

    @Test func compressionShrinksSilence() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let silent = Self.files.map { name, data in
            name.hasPrefix("track_") ? (name, WAVHeader.bytes(format: Self.format, dataBytes: data.count - 44) + Data(count: data.count - 44)) : (name, data)
        }
        let plain = try Self.write(to: folder.appending(path: "plain.reelarchive"), files: silent)
        let small = try Self.write(to: folder.appending(path: "small.reelarchive"), compression: .lzfse, files: silent)
        let size = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0 }
        #expect(try size(small) < size(plain) / 4)
        #expect(try size(plain) > silent.reduce(0) { $0 + $1.1.count })
    }

    @Test func neverWritesOverAFile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "taken.reelarchive")
        try Data("mine".utf8).write(to: url)
        #expect { try ReelArchiveWriter(creating: url) } throws: { ($0 as? FieldError)?.code == .localFileFailed }
        #expect(try Data(contentsOf: url) == Data("mine".utf8))
    }

    @Test func anAbandonedArchiveIsDeleted() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "half.reelarchive")
        let writer = try ReelArchiveWriter(creating: url)
        try writer.add("track_1.wav", data: Self.files[0].1)
        writer.abandon()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Tracks

    @Test func extractsATrackWithoutOverwriting() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try ReelArchive(contentsOf: Self.write(to: folder.appending(path: "a.reelarchive"), compression: .lz4))
        let first = try archive.extractTrack(3, to: folder)
        #expect(first.lastPathComponent == "2026-220#02 track_3.wav")
        #expect(try Data(contentsOf: first) == Self.files[2].1)
        let second = try archive.extractTrack(3, to: folder)
        #expect(second.lastPathComponent == "2026-220#02 track_3 2.wav")
        #expect(try Data(contentsOf: second) == Self.files[2].1)
        #expect(try Data(contentsOf: archive.extractTrack(2, to: folder)) == Self.files[1].1)
    }

    @Test func aTrackChangedSinceOpeningIsntKept() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.write(to: folder.appending(path: "a.reelarchive"))
        let archive = try ReelArchive(contentsOf: url)
        try Self.damage(url)
        let out = folder.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #expect { try archive.extractTrack(1, to: out) } throws: { ($0 as? FieldError)?.code == .archiveMismatch }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    // MARK: Refusing

    /// Changes one byte of track 1's samples in an uncompressed archive.
    static func damage(_ url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let samples = files[0].1.dropFirst(44).prefix(64)
        let offset = try #require(bytes.range(of: samples)).lowerBound + 10
        bytes[offset] ^= 0xFF
        try bytes.write(to: url)
    }

    @Test func refusesADamagedTrack() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.write(to: folder.appending(path: "a.reelarchive"))
        try Self.damage(url)
        Self.expectRefusal(.archiveMismatch, "track_1.wav's SHA-256 isn't the one reel.json records", opening: url)
    }

    @Test func refusesWhatIsntATapeArchive() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "x.reelarchive")

        try Data("not an archive at all".utf8).write(to: url)
        Self.expectRefusal(.invalidArchive, "it isn't an Apple Archive that can be read", opening: url)

        try Self.writeRaw(to: url, Self.files)
        Self.expectRefusal(.invalidArchive, "it has no reel.json", opening: url)

        try Self.writeRaw(to: url, Self.files + [("notes.txt", Data("hi".utf8)), ("reel.json", try Self.reel())])
        Self.expectRefusal(.invalidArchive, "it holds notes.txt, which a tape archive doesn't", opening: url)

        try Self.writeRaw(to: url, Array(Self.files.dropLast()) + [("reel.json", try Self.reel())])
        Self.expectRefusal(.invalidArchive, "it's missing tape.json", opening: url)

        try Self.writeRaw(to: url, Self.files + [("reel.json", try Self.reel(format: 2))])
        Self.expectRefusal(.invalidArchive, "it's format 2, from a newer FieldTapeKit than this one, which reads up to 1", opening: url)

        try Self.writeRaw(to: url, Self.files + [("reel.json", Data("{".utf8))])
        Self.expectRefusal(.invalidArchive, "its reel.json can't be read", opening: url)

        // tape.json says track 1 ends at frame 1,000, but this track 1 is shorter.
        var short = Self.files
        short[0].1 = short[0].1.prefix(44 + 8 * 999)
        try Self.writeRaw(to: url, short + [("reel.json", try Self.reel(files: short))])
        Self.expectRefusal(.invalidArchive, "its tape.json doesn't match its tracks: track_1.wav is 8036 bytes, clips imply 8044",
                           opening: url)

        // reel.json records a size the file doesn't have.
        var listed = Self.files
        listed[2].1.append(0)
        try Self.writeRaw(to: url, Self.files + [("reel.json", try Self.reel(files: listed))])
        Self.expectRefusal(.archiveMismatch, "track_3.wav is 4044 bytes, but reel.json says 4045", opening: url)
    }

    @Test func aMissingFileCantBeRead() {
        let url = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).reelarchive")
        #expect { try ReelArchive(contentsOf: url) } throws: { ($0 as? FieldError)?.code == .localFileFailed }
    }

    // MARK: Other tools and older formats

    #if os(macOS)
    /// The Mac's own `aa` extracts it, so a person can get the WAVs out without FieldTapeKit.
    @Test(arguments: [ReelArchive.Compression.none, .lzfse])
    func theMacsAATakesItApart(compression: ReelArchive.Compression) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.write(to: folder.appending(path: "a.reelarchive"), compression: compression)
        let out = folder.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let aa = Process()
        aa.executableURL = URL(filePath: "/usr/bin/aa")
        aa.arguments = ["extract", "-i", url.path, "-d", out.path]
        try aa.run()
        aa.waitUntilExit()
        #expect(aa.terminationStatus == 0)
        for (name, data) in Self.files { #expect(try Data(contentsOf: out.appending(path: name)) == data, "\(name)") }
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "reel.json").path))
    }
    #endif

    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/format-1.reelarchive")

    /// An archive written in format 1 and kept, so every later version must still open it (ADR 0002, section 11).
    @Test func opensTheFormat1Fixture() throws {
        let archive = try ReelArchive(contentsOf: Self.fixture)
        #expect(archive.format == 1)
        #expect(archive.name.string == "2026-220#02" && archive.type == .vintage && archive.serialNumber == "SIMULATED")
        #expect(archive.created == Self.created)
        #expect(archive.manifest.data == Self.files[4].1)
        #expect(archive.tracks.map(\.size) == Self.files.prefix(4).map(\.1.count))
    }

    /// Makes the fixture. It runs only when asked, as `FIELDTAPEKIT_WRITE_FIXTURE=1 swift test`, and refuses to
    /// replace one: a fixture is kept as it was written.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIELDTAPEKIT_WRITE_FIXTURE"] == "1"))
    func writeTheFormat1Fixture() throws {
        try FileManager.default.createDirectory(at: Self.fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.write(to: Self.fixture)
    }
}
