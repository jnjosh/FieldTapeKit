import AppleArchive
import CryptoKit
import Foundation
import System
import UniformTypeIdentifiers

extension UTType {
    /// A `.reelarchive`: one tape, as an Apple Archive.
    ///
    /// Every app that uses FieldTapeKit shares this one identifier, so archives open in any of them, and two such
    /// apps on one device don't fight over the extension. The type belongs to FieldTapeKit, not to an app, so an app
    /// declares it in its Info.plist under `UTImportedTypeDeclarations`, to open these files from Files and from other
    /// apps:
    ///
    /// ```xml
    /// <key>UTImportedTypeDeclarations</key>
    /// <array>
    ///     <dict>
    ///         <key>UTTypeIdentifier</key>
    ///         <string>com.jnjosh.fieldtapekit.reelarchive</string>
    ///         <key>UTTypeDescription</key>
    ///         <string>OP-1 Tape Archive</string>
    ///         <key>UTTypeConformsTo</key>
    ///         <array>
    ///             <string>public.data</string>
    ///             <string>public.archive</string>
    ///         </array>
    ///         <key>UTTypeTagSpecification</key>
    ///         <dict>
    ///             <key>public.filename-extension</key>
    ///             <array><string>reelarchive</string></array>
    ///         </dict>
    ///     </dict>
    /// </array>
    /// ```
    ///
    /// Its identifier and extension never change: archives already shared depend on them.
    public static let reelArchive = UTType(importedAs: "com.jnjosh.fieldtapekit.reelarchive", conformingTo: .archive)
}

/// One tape kept off the OP-1: a `.reelarchive` file, an Apple Archive of its four tracks and `tape.json` exactly as
/// they were on the OP-1, and `reel.json`, which records the tape and the size and SHA-256 of every file
/// (ADR 0002, section 4).
///
/// Opening one checks all of it, so a `ReelArchive` is always one that was complete and undamaged when opened.
public struct ReelArchive: Sendable, Hashable {
    /// The format this version writes. Every version reads every earlier format; writing one an earlier 1.x can't
    /// open is a major version (ADR 0002, section 11).
    public static let currentFormat = 1

    /// The compression an archive is written with. Uncompressed PCM barely shrinks, so the default is none.
    public enum Compression: Sendable, Hashable {
        case none, lz4, lzfse, zlib, lzma

        var algorithm: ArchiveCompression? {
            switch self {
            case .none: nil
            case .lz4: .lz4
            case .lzfse: .lzfse
            case .zlib: .zlib
            case .lzma: .lzma
            }
        }
    }

    /// One of the archived tracks.
    public struct Track: Sendable, Hashable {
        /// 1 to 4.
        public let number: Int
        /// The WAV file's size, header included.
        public let size: Int
        /// Lowercase hex.
        public let sha256: String

        public var isBlank: Bool { size <= WAVHeader.size }
        public var duration: Duration {
            Tape.duration(frames: max(size - WAVHeader.size, 0) / FirmwareProfile.v1_7_3.trackFormat.frameBytes)
        }
    }

    public let url: URL
    /// The format it was written in.
    public let format: Int
    /// The tape's name on the OP-1 when it was archived.
    public let name: TapeName
    public let type: TapeType
    /// The OP-1 it came from.
    public let model: String
    public let serialNumber: String
    /// The firmware it was archived on. Restoring onto another isn't refused, so an app can warn.
    public let firmware: String
    public let created: Date
    /// The archived `tape.json`.
    public let manifest: TapeManifest
    /// All four, in order.
    public let tracks: [Track]

    /// To the end of the last clip.
    public var duration: Duration { Tape.duration(frames: manifest.endFrame) }

    /// Opens a `.reelarchive` and checks all of it: it holds exactly a tape's files and `reel.json`, every file's size
    /// and SHA-256 match `reel.json`, and `tape.json` matches the tracks' sizes.
    ///
    /// - Throws: `FieldError` with `.invalidArchive`, `.archiveMismatch`, or `.localFileFailed` if the file can't be
    ///   read.
    public init(contentsOf url: URL) throws(FieldError) {
        var found: [String: (size: Int, sha256: String)] = [:]
        var small: [String: Data] = [:]
        try Self.read(url) { name, size, chunks in
            guard Self.expected.contains(name), found[name] == nil else {
                throw FieldError(.invalidArchive, reason: "it holds \(name), which a tape archive doesn't")
            }
            var hash = SHA256()
            var kept = Data()
            let keep = !name.hasPrefix("track_")
            try chunks { chunk in
                hash.update(data: chunk)
                if keep { kept.append(chunk) }
            }
            found[name] = (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
            if keep { small[name] = kept }
            return true
        }

        guard let reel = small[ReelMetadata.fileName] else { throw FieldError(.invalidArchive, reason: "it has no reel.json") }
        let metadata: ReelMetadata
        do {
            metadata = try ReelMetadata.decoder().decode(ReelMetadata.self, from: reel)
        } catch {
            throw FieldError(.invalidArchive, underlying: error, reason: "its reel.json can't be read")
        }
        guard metadata.format <= Self.currentFormat else {
            throw FieldError(.invalidArchive, reason: "it's format \(metadata.format), from a newer FieldTapeKit than this one, "
                                 + "which reads up to \(Self.currentFormat)")
        }
        let missing = ReelArchiveWriter.tapeFiles.filter { found[$0] == nil }
        guard missing.isEmpty else { throw FieldError(.invalidArchive, reason: "it's missing " + missing.joined(separator: ", ")) }
        guard Set(metadata.files.map(\.name)) == Set(ReelArchiveWriter.tapeFiles), metadata.files.count == ReelArchiveWriter.tapeFiles.count else {
            throw FieldError(.invalidArchive, reason: "its reel.json doesn't list exactly a tape's files")
        }
        for file in metadata.files {
            let actual = found[file.name]!
            guard actual.size == file.size else {
                throw FieldError(.archiveMismatch, reason: "\(file.name) is \(actual.size) bytes, but reel.json says \(file.size)")
            }
            guard actual.sha256 == file.sha256 else {
                throw FieldError(.archiveMismatch, reason: "\(file.name)'s SHA-256 isn't the one reel.json records")
            }
        }

        let json = small["tape.json"]!
        do {
            manifest = try TapeManifest(json)
        } catch {
            throw FieldError(.invalidArchive, reason: error.description)
        }
        let sizes = Dictionary(uniqueKeysWithValues: metadata.files.filter { $0.name.hasPrefix("track_") }.map { ($0.name, $0.size) })
        if let problem = TapeConsistency.problems(json: json, trackSizes: sizes).first {
            throw FieldError(.invalidArchive, reason: "its tape.json doesn't match its tracks: \(problem)")
        }

        self.url = url
        format = metadata.format
        name = TapeName(listed: metadata.tape.name)
        type = TapeType(rawValue: metadata.tape.type)
        model = metadata.device.model
        serialNumber = metadata.device.serialNumber
        firmware = metadata.device.firmware
        created = metadata.created
        tracks = (1...4).map { number in
            let file = metadata.files.first { $0.name == "track_\(number).wav" }!
            return Track(number: number, size: file.size, sha256: file.sha256)
        }
    }

    /// Writes one track into `folder` as a WAV file, `<tape name> track_<n>.wav`, checking its SHA-256 on the way.
    /// It never overwrites a file: a taken name gets a number, as Finder does. Only a little of the track is in
    /// memory at a time.
    ///
    /// - Returns: The file written.
    /// - Throws: `FieldError` with `.archiveMismatch` if the track no longer matches (the file isn't kept),
    ///   `.invalidArchive`, or `.localFileFailed`.
    public func extractTrack(_ number: Int, to folder: URL) throws(FieldError) -> URL {
        precondition((1...4).contains(number), "a tape's tracks are 1 to 4")
        let track = tracks[number - 1]
        let name = "track_\(number).wav"
        let destination = try Self.create(folder.appending(path: "\(self.name.string) \(name)"))
        var hash = SHA256()
        var size = 0
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try Self.read(url) { entry, _, chunks in
                guard entry == name else { return false }
                do {
                    try chunks { chunk in
                        hash.update(data: chunk)
                        size += chunk.count
                        try handle.write(contentsOf: chunk)
                    }
                } catch let error as FieldError {
                    throw error
                } catch {
                    throw FieldError(.localFileFailed, underlying: error)
                }
                return true
            }
            guard size == track.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == track.sha256 else {
                throw FieldError(.archiveMismatch, reason: "\(name) no longer matches what was checked when the archive was opened")
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw FieldError.local(error)
        }
    }

    // MARK: Reading

    static let expected = Set(ReelArchiveWriter.tapeFiles + [ReelMetadata.fileName])
    private static let chunkSize = 1 << 20

    /// Reads the archive's entries in order. For each, `visit` gets its name, its size and a function that reads its
    /// data in chunks, and returns whether it read them; data it skips is read past.
    private static func read(_ url: URL, visit: (String, Int, (_ each: (Data) throws -> Void) throws -> Void) throws -> Bool)
        throws(FieldError) {
        // Apple Archive reports a missing or unreadable file only as an I/O error, so that's told apart first.
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw FieldError(.localFileFailed, underlying: CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]))
        }
        do {
            try ArchiveByteStream.withFileStream(path: FilePath(url.path(percentEncoded: false)), mode: .readOnly,
                                                 options: [], permissions: []) { file in
                try ArchiveByteStream.withDecompressionStream(readingFrom: file) { decompressed in
                    try ArchiveStream.withDecodeStream(readingFrom: decompressed) { decoder in
                        while let header = try decoder.readHeader() {
                            guard case .string(_, let name)? = header.field(forKey: ArchiveHeader.FieldKey("PAT")),
                                  case .uint(_, let type)? = header.field(forKey: ArchiveHeader.FieldKey("TYP")),
                                  type == UInt64(ArchiveHeader.EntryType.regularFile.rawValue) else {
                                throw FieldError(.invalidArchive, reason: "it holds something other than files")
                            }
                            var size = 0
                            if case .blob(_, let blobSize, _)? = header.field(forKey: ArchiveHeader.FieldKey("DAT")) {
                                size = Int(blobSize)
                            }
                            let chunks = { (each: (Data) throws -> Void) throws in
                                var buffer = Data(count: min(chunkSize, max(size, 1)))
                                var remaining = size
                                while remaining > 0 {
                                    let count = min(remaining, buffer.count)
                                    try buffer.withUnsafeMutableBytes {
                                        try decoder.readBlob(key: ArchiveHeader.FieldKey("DAT"),
                                                             into: UnsafeMutableRawBufferPointer(rebasing: $0[..<count]))
                                    }
                                    try each(buffer.prefix(count))
                                    remaining -= count
                                }
                            }
                            if try !visit(name, size, chunks), size > 0 {
                                try chunks { _ in }
                            }
                        }
                    }
                }
            }
        } catch {
            throw local(error, reading: true)
        }
    }

    /// A FieldError as it is, and anything else from Apple Archive or the file system as a file that can't be read.
    private static func local(_ error: any Error, reading: Bool) -> FieldError {
        if let error = error as? FieldError { return error }
        if error is ArchiveError, reading {
            return FieldError(.invalidArchive, underlying: error, reason: "it isn't an Apple Archive that can be read")
        }
        return FieldError(.localFileFailed, underlying: error)
    }

    /// Makes an empty file at `url`, or at the first free numbered name next to it, never one that exists.
    private static func create(_ url: URL) throws(FieldError) -> URL {
        var number = 1
        while true {
            let candidate = number == 1 ? url : FieldDevice.numbered(url, number)
            do {
                let descriptor = try FileDescriptor.open(FilePath(candidate.path(percentEncoded: false)), .writeOnly,
                                                         options: [.create, .exclusiveCreate],
                                                         permissions: FilePermissions(rawValue: 0o644))
                try descriptor.close()
                return candidate
            } catch Errno.fileExists {
                number += 1
            } catch {
                throw FieldError(.localFileFailed, underlying: error)
            }
        }
    }
}

extension FieldError {
    /// A FieldError as it is, and any other error as a local file that couldn't be read or written.
    static func local(_ error: any Error) -> FieldError {
        error as? FieldError ?? FieldError(.localFileFailed, underlying: error)
    }
}
