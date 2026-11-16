import CryptoKit
import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct AlbumTests {
    static let profile = FirmwareProfile.v1_7_3

    /// A side of `seconds` in the OP-1's format, with bytes that aren't all zero.
    static func side(seconds: Double, seed: UInt8 = 1) -> Data {
        let bytes = Int(seconds * 44_100) * profile.sideFormat.frameBytes
        return WAVHeader.bytes(format: profile.sideFormat, dataBytes: bytes) + Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }

    /// Side A 1.5 s, side B 0.5 s, unless given.
    static func device(a: Data? = side(seconds: 1.5), b: Data? = side(seconds: 0.5, seed: 9),
                       faults: [SimulatedMTPDevice.Fault] = []) -> (FieldDevice, SimulatedMTPDevice) {
        var files: [PendingNode] = []
        if let a { files.append(.file("side_a.wav", .data(a))) }
        if let b { files.append(.file("side_b.wav", .data(b))) }
        let simulator = SimulatedMTPDevice(faults: faults,
                                           contents: SimulatedNode.merge([.folder("mixdown", files)], into: SimulatedNode.layout173, path: []))
        return (FieldDevice.simulated(simulator), simulator)
    }

    /// A device whose `mixdown/` holds only `nodes`, with no sides unless they're among them.
    static func device(mixdown nodes: [SimulatedNode]) -> FieldDevice {
        let layout = SimulatedNode.layout173.map { node in
            if case .folder("mixdown", _) = node { SimulatedNode.folder("mixdown", nodes) } else { node }
        }
        return FieldDevice.simulated(SimulatedMTPDevice(contents: layout))
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AlbumTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func name(_ side: Album.Side, _ number: Int = 1) -> String {
        let day = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        return number == 1 ? "\(side) \(day).wav" : "\(side) \(day) \(number).wav"
    }

    // MARK: Listing

    @Test func aNewOP1HasTwoEmptySides() async throws {
        let album = try await FieldDevice.simulated().album()
        for side in Album.Side.allCases {
            let listed = album[side]
            #expect(listed.side == side && listed.path == FilePath("mixdown/side_\(side.rawValue).wav"))
            #expect(listed.isEmpty && listed.isSound && listed.size == 44 && listed.duration == .zero)
            #expect(listed.format == AudioFormat(Self.profile.sideFormat))
        }
        #expect(album.sides.map(\.side) == [.a, .b])
    }

    @Test func listsSidesWithAudio() async throws {
        let (device, _) = Self.device()
        let album = try await device.album()
        #expect(!album.a.isEmpty && album.a.isSound && album.a.size == Self.side(seconds: 1.5).count)
        #expect(album.a.duration == .milliseconds(1_500) && album.b.duration == .milliseconds(500))
        let format = try #require(album.a.format)
        #expect(format.isPCM && format.sampleRate == 44_100 && format.bitDepth == 16 && format.channels == 2)
        #expect(format.description == "PCM, 2 channels, 16 bits, 44100 Hz")
    }

    @Test func aSideInAnotherFormatIsListedWithItsProblem() async throws {
        let wide = WAVHeader.bytes(format: Self.profile.trackFormat, dataBytes: 800) + Data(count: 800)
        let (device, _) = Self.device(b: wide)
        let b = try await device.album().b
        #expect(!b.isSound && b.format?.bitDepth == 32)
        #expect(b.problems == ["it's PCM, 2 channels, 32 bits, 44100 Hz, not PCM, 2 channels, 16 bits, 44100 Hz as the OP-1 records"])
    }

    @Test func aHeaderThatDoesntMatchTheSizeIsAProblem() async throws {
        let (device, _) = Self.device(a: Self.side(seconds: 0.5) + Data(count: 4))
        let a = try await device.album().a
        #expect(!a.isSound && a.problems.count == 2)
        #expect(a.problems.allSatisfy { $0.hasPrefix("its WAV header doesn't match its size") })
    }

    @Test func aShortOrMissingSideIsAProblem() async throws {
        let device = Self.device(mixdown: [.file("side_a.wav", Data("RIFF".utf8), format: PTPObjectFormat.wav)])
        let album = try await device.album()
        #expect(album.a.problems == ["it isn't a WAV file the OP-1 writes: only 4 bytes, not a 44-byte header"])
        #expect(album.a.format == nil && album.a.isEmpty)
        #expect(album.b.problems == ["side_b.wav is missing"] && album.b.size == 0)
    }

    @Test func aMissingMixdownIsNotFound() async throws {
        let layout = SimulatedNode.layout173.filter { $0.name != "mixdown" }
        let device = FieldDevice.simulated(SimulatedMTPDevice(contents: layout))
        await #expect { try await device.album() } throws: { ($0 as? FieldError)?.code == .notFound }
    }

    // MARK: Copying a side

    @Test func copiesASideOff() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = Date()

        let copy = try await device.copySide(.a, to: folder)
        #expect(copy.url.lastPathComponent == Self.name(.a))
        #expect(try Self.listing(folder) == [Self.name(.a)], "nothing else is left in the folder")
        let expected = Self.side(seconds: 1.5)
        #expect(try Data(contentsOf: copy.url) == expected)
        #expect(copy.side == .a && copy.size == expected.count && copy.sha256 == Self.sha256(expected))
        #expect(copy.copiedAt >= before && copy.copiedAt <= Date())
        #expect(await simulator.deleted.isEmpty)
        #expect(await simulator.sentNames.isEmpty)
    }

    @Test func neverWritesOverACopy() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("mine".utf8).write(to: folder.appending(path: Self.name(.a)))

        let copy = try await device.copySide(.a, to: folder)
        #expect(copy.url.lastPathComponent == Self.name(.a, 2))
        #expect(try Data(contentsOf: folder.appending(path: Self.name(.a))) == Data("mine".utf8))
    }

    @Test func anEmptySideIsNotFound() async throws {
        let device = FieldDevice.simulated()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copySide(.b, to: folder) } throws: {
            ($0 as? FieldError)?.code == .notFound && ($0 as? FieldError)?.path == "mixdown/side_b.wav"
        }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func aSideThatIsntSoundIsRefused() async throws {
        let (device, _) = Self.device(a: Self.side(seconds: 0.5) + Data(count: 4))
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copySide(.a, to: folder) } throws: {
            ($0 as? FieldError)?.code == .notAllowed && ($0 as? FieldError)?.reason?.hasPrefix("it isn't sound") == true
        }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func aShortReadLeavesNothing() async throws {
        let (device, _) = Self.device(faults: [.shortRead(name: "side_a.wav")])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copySide(.a, to: folder) } throws: { ($0 as? FieldError)?.code == .verificationFailed }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func aMissingFolderIsALocalFailure() async throws {
        let (device, _) = Self.device()
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID())")
        await #expect { try await device.copySide(.a, to: missing) } throws: { ($0 as? FieldError)?.code == .localFileFailed }
    }

    @Test func reportsProgressByBytes() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = ProgressManager(totalCount: 1)
        _ = try await device.copySide(.b, to: folder, progress: parent.subprogress(assigningCount: 1))
        #expect(parent.fractionCompleted == 1)
    }

    @Test func aCopyIsCodable() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try await device.copySide(.a, to: folder)
        #expect(try JSONDecoder().decode(AlbumSideCopy.self, from: JSONEncoder().encode(copy)) == copy)
    }

    // MARK: Copying the album

    @Test func copiesEverySideWithAudio() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = ProgressManager(totalCount: 1)
        let copies = try await device.copyAlbum(to: folder, progress: parent.subprogress(assigningCount: 1))
        #expect(copies.map(\.side) == [.a, .b])
        #expect(try Self.listing(folder) == [Self.name(.a), Self.name(.b)])
        #expect(try Data(contentsOf: copies[1].url) == Self.side(seconds: 0.5, seed: 9))
        #expect(parent.fractionCompleted == 1)
    }

    @Test func skipsEmptySides() async throws {
        let empty = WAVHeader.bytes(format: Self.profile.sideFormat, dataBytes: 0)
        let (device, _) = Self.device(a: empty)
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try await device.copyAlbum(to: folder).map(\.side) == [.b])
        #expect(try await FieldDevice.simulated().copyAlbum(to: folder).isEmpty)
        #expect(try Self.listing(folder) == [Self.name(.b)])
    }

    @Test func checksBothSidesBeforeCopying() async throws {
        let (device, _) = Self.device(b: Self.side(seconds: 0.5) + Data(count: 4))
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copyAlbum(to: folder) } throws: {
            ($0 as? FieldError)?.code == .notAllowed && ($0 as? FieldError)?.path == "mixdown/side_b.wav"
        }
        #expect(try Self.listing(folder).isEmpty)
    }

    @Test func aFailureOnSideBDeletesSideAsCopy() async throws {
        let (device, _) = Self.device(faults: [.shortRead(name: "side_b.wav")])
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect { try await device.copyAlbum(to: folder) } throws: {
            ($0 as? FieldError)?.code == .verificationFailed && ($0 as? FieldError)?.path == "mixdown/side_b.wav"
        }
        #expect(try Self.listing(folder).isEmpty)
    }

    // MARK: Matching

    @Test func aSideMatchesItsCopyUntilRecordedOver() async throws {
        let (device, simulator) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try await device.copySide(.a, to: folder)
        #expect(try await device.side(.a, matches: copy))
        #expect(try await !device.side(.b, matches: copy), "side B has another size")

        // Recorded over with the same length: only the SHA-256 tells.
        await simulator.overwrite("side_a.wav", in: "mixdown", with: Self.side(seconds: 1.5, seed: 2))
        #expect(try await !device.side(.a, matches: copy))
        await simulator.overwrite("side_a.wav", in: "mixdown", with: Self.side(seconds: 2))
        #expect(try await !device.side(.a, matches: copy))
    }

    @Test func aCopyOfOneSideCanMatchTheOther() async throws {
        let (device, _) = Self.device(b: Self.side(seconds: 1.5))
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try await device.copySide(.a, to: folder)
        #expect(try await device.side(.b, matches: copy))
    }

    @Test func aMissingSideMatchesNothing() async throws {
        let (device, _) = Self.device()
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try await device.copySide(.a, to: folder)
        let other = Self.device(mixdown: [])
        #expect(try await !other.side(.a, matches: copy))
    }
}
