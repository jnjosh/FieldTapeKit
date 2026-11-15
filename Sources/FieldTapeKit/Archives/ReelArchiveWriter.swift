import AppleArchive
import CryptoKit
import Foundation
import System

/// `reel.json`: what FieldTapeKit records about the tape in a `.reelarchive` (ADR 0002, section 4).
struct ReelMetadata: Codable, Hashable {
    struct TapeInfo: Codable, Hashable {
        let name: String
        let type: Int
    }

    struct DeviceInfo: Codable, Hashable {
        let model: String
        let serialNumber: String
        let firmware: String
    }

    struct FileInfo: Codable, Hashable {
        let name: String
        let size: Int
        let sha256: String
    }

    /// Which format the archive is. Every version reads every earlier one (ADR 0002, section 11).
    let format: Int
    let tape: TapeInfo
    let device: DeviceInfo
    let created: Date
    let files: [FileInfo]

    static let fileName = "reel.json"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Writes a `.reelarchive` one file at a time, so only one track is held in memory, with each file's SHA-256 taken
/// as it's written. `reel.json` goes last, once every file is in. Step 15's `copyTape` uses it, then opens the
/// archive again to check it.
final class ReelArchiveWriter {
    /// The files a tape archive holds besides `reel.json`, in the order they're written.
    static let tapeFiles = ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"]

    let url: URL
    private let file: ArchiveByteStream
    private let compressed: ArchiveByteStream?
    private let encoder: ArchiveStream
    private var written: [ReelMetadata.FileInfo] = []
    private var isClosed = false

    /// Starts a new archive at `url`, which must not exist.
    ///
    /// - Throws: `FieldError` with `.localFileFailed` if the file can't be made, such as when something is there.
    init(creating url: URL, compression: ReelArchive.Compression = .none) throws(FieldError) {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path(percentEncoded: false)), mode: .writeOnly,
                                                      options: [.create, .exclusiveCreate],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw FieldError(.localFileFailed, underlying: CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]))
        }
        var compressed: ArchiveByteStream?
        if let algorithm = compression.algorithm {
            guard let stream = ArchiveByteStream.compressionStream(using: algorithm, writingTo: file) else {
                try? file.close()
                try? FileManager.default.removeItem(at: url)
                throw FieldError(.localFileFailed, underlying: CocoaError(.fileWriteUnknown))
            }
            compressed = stream
        }
        guard let encoder = ArchiveStream.encodeStream(writingTo: compressed ?? file) else {
            try? compressed?.close()
            try? file.close()
            try? FileManager.default.removeItem(at: url)
            throw FieldError(.localFileFailed, underlying: CocoaError(.fileWriteUnknown))
        }
        self.url = url
        self.file = file
        self.compressed = compressed
        self.encoder = encoder
    }

    /// Adds one of a tape's files, exactly as read from the OP-1.
    ///
    /// - Throws: `FieldError` with `.localFileFailed`.
    func add(_ name: String, data: Data) throws(FieldError) {
        precondition(Self.tapeFiles.contains(name) && !written.contains { $0.name == name }, "\(name) isn't a tape file still to add")
        do {
            try write(name, data: data)
        } catch {
            throw FieldError(.localFileFailed, underlying: error)
        }
        written.append(ReelMetadata.FileInfo(name: name, size: data.count,
                                              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    /// Writes `reel.json` and closes the archive. Every tape file must have been added.
    ///
    /// - Throws: `FieldError` with `.localFileFailed`.
    func finish(name: TapeName, type: TapeType, model: String, serialNumber: String, firmware: String,
                created: Date = .now) throws(FieldError) {
        precondition(Set(written.map(\.name)) == Set(Self.tapeFiles), "not every tape file was added")
        let metadata = ReelMetadata(format: ReelArchive.currentFormat, tape: .init(name: name.string, type: type.rawValue),
                                    device: .init(model: model, serialNumber: serialNumber, firmware: firmware),
                                    created: created, files: written)
        do {
            try write(ReelMetadata.fileName, data: try ReelMetadata.encoder().encode(metadata))
            try close()
        } catch {
            throw FieldError(.localFileFailed, underlying: error)
        }
    }

    /// Closes the archive and deletes it, after a failure.
    func abandon() {
        try? close()
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        if !isClosed { abandon() }
    }

    private func write(_ name: String, data: Data) throws {
        let header = ArchiveHeader()
        header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: name))
        header.append(.uint(key: ArchiveHeader.FieldKey("MOD"), value: 0o644))
        header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(data.count)))
        try encoder.writeHeader(header)
        try data.withUnsafeBytes { try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }
    }

    private func close() throws {
        guard !isClosed else { return }
        isClosed = true
        try encoder.close()
        try compressed?.close()
        try file.close()
    }
}
