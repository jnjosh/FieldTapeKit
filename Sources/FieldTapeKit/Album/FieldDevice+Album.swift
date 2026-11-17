import CryptoKit
import Foundation
import System

extension FieldDevice {
    /// Both album sides, read fresh: `mixdown/` is listed, and each side's 44-byte WAV header is read.
    ///
    /// A side that isn't sound is listed too, with its ``AlbumSide/problems``.
    ///
    /// - Returns: Both sides, as they are now.
    /// - Throws: `FieldError` with `.notFound` if there's no `mixdown/` folder, `.ambiguousPath`, `.disconnected`,
    ///   `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func album() async throws -> Album {
        do {
            return try await listAlbum().album
        } catch {
            throw FieldError.wrapping(error, path: .op1Mixdown)
        }
    }

    /// Copies one side off the OP-1 into a new WAV file in a folder, checks it, and returns what it holds.
    ///
    /// The side stays on the OP-1, unchanged (ADR 0002, section 5).
    ///
    /// The side is read fresh, then read whole with one GetObject, so all of it is in memory at once: about 10 MB a
    /// minute. The copy is written to a hidden temporary file in `folder`, read back and matched by SHA-256 (safety
    /// rule 2), then moved into place as `Side A <date>.wav`, with today's date in this device's time zone. It
    /// never goes over a file: a taken name gets a number, as Finder does. Nothing is left in `folder` unless the copy
    /// succeeds.
    ///
    /// - Parameters:
    ///   - side: The side to copy.
    ///   - folder: The local folder to copy it into. It must exist.
    ///   - progress: One unit per byte of the side, completed once the copy is checked. The read can't report
    ///     anything in between, and once sent it finishes before a cancel takes effect.
    /// - Returns: The copy: its URL, size and SHA-256.
    /// - Throws: `FieldError` with `.notFound` if the side is empty or missing, `.notAllowed` if it isn't sound,
    ///   `.verificationFailed` if what came off doesn't match its listing or the copy doesn't check out,
    ///   `.localFileFailed`, `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func copySide(_ side: Album.Side, to folder: URL, progress: consuming Subprogress? = nil) async throws -> AlbumSideCopy {
        let path = FilePath.op1Mixdown.appending(side.fileName)
        do {
            let (album, files) = try await listAlbum()
            let listed = album[side]
            try Self.checkCopyable(listed)
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress): manager = progress.start(totalCount: listed.size)
            case .none: break
            }
            return try await copy(listed, handle: files[side]!.handle, to: folder, progress: manager)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Copies every side with audio off the OP-1, A first, and returns their copies.
    ///
    /// Each side is copied as ``copySide(_:to:progress:)`` copies it. Empty sides are skipped, so an empty album
    /// gives none.
    ///
    /// Both sides are checked before anything is copied. If a copy fails, the copies already made in this call are
    /// deleted, so nothing is left in `folder` unless all of it succeeds.
    ///
    /// - Parameters:
    ///   - folder: The local folder to copy the sides into. It must exist.
    ///   - progress: One unit per byte of the sides with audio.
    /// - Returns: A copy of each side with audio, A first.
    /// - Throws: As ``copySide(_:to:progress:)``, apart from `.notFound` for an empty side.
    public func copyAlbum(to folder: URL, progress: consuming Subprogress? = nil) async throws -> [AlbumSideCopy] {
        var copies: [AlbumSideCopy] = []
        do {
            let (album, files) = try await listAlbum()
            let recorded = album.sides.filter { !$0.isEmpty }
            for side in recorded { try Self.checkCopyable(side) }
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress): manager = progress.start(totalCount: recorded.reduce(0) { $0 + $1.size })
            case .none: break
            }
            for side in recorded {
                do {
                    copies.append(try await copy(side, handle: files[side.side]!.handle, to: folder, progress: manager))
                } catch {
                    throw FieldError.wrapping(error, path: side.path)
                }
            }
            return copies
        } catch {
            for copy in copies { try? FileManager.default.removeItem(at: copy.url) }
            throw FieldError.wrapping(error, path: .op1Mixdown)
        }
    }

    /// Checks whether a side on the OP-1 now holds exactly what a copy holds.
    ///
    /// The sizes are compared first. Only if they're equal is the whole side read and matched by SHA-256. It compares
    /// with whichever side is named, even if `copy` came from the other one. A missing side matches nothing.
    ///
    /// - Parameters:
    ///   - side: The side on the OP-1 to compare.
    ///   - copy: A copy made by ``copySide(_:to:progress:)`` or ``copyAlbum(to:progress:)``.
    /// - Returns: True if the side holds exactly what the copy holds.
    /// - Throws: `FieldError` with `.verificationFailed` if what came off doesn't match its listing,
    ///   `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func side(_ side: Album.Side, matches copy: AlbumSideCopy) async throws -> Bool {
        let path = FilePath.op1Mixdown.appending(side.fileName)
        do {
            let (album, files) = try await listAlbum()
            guard let handle = files[side]?.handle, album[side].size == copy.size else { return false }
            try Task.checkCancellation()
            let data = try await session.object(handle)
            guard data.count == copy.size else {
                throw FieldError(.verificationFailed, path: path, reason: "it read as \(data.count) bytes, not the \(copy.size) listed")
            }
            return Self.hex(SHA256.hash(data: data)) == copy.sha256
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    // MARK: Helpers

    /// The album from a fresh listing of `mixdown/`, and each side's file, where there is one.
    func listAlbum() async throws -> (album: Album, files: [Album.Side: (handle: UInt32, item: FieldItem)]) {
        guard let folder = try await locate(.op1Mixdown), folder.isDirectory else { throw FieldError(.notFound, path: .op1Mixdown) }
        let children = try await children(of: folder)
        var sides: [Album.Side: AlbumSide] = [:]
        var files: [Album.Side: (handle: UInt32, item: FieldItem)] = [:]
        for side in Album.Side.allCases {
            try Task.checkCancellation()
            let path = folder.path.appending(side.fileName)
            guard let child = try Self.match(side.fileName, in: children, path: path) else {
                sides[side] = AlbumSide(side: side, path: path, size: 0, format: nil, problems: ["\(side.fileName) is missing"])
                continue
            }
            let listedPath = folder.path.appending(child.info.filename)
            guard !child.info.isFolder else {
                sides[side] = AlbumSide(side: side, path: listedPath, size: 0, format: nil, problems: ["\(child.info.filename) is a folder"])
                continue
            }
            let size = Int(child.info.compressedSize)
            let start = size > 0 ? try await session.partialObject(child.handle, offset: 0, maxLength: UInt32(min(size, WAVHeader.size))) : Data()
            let (format, problems) = sideProblems(header: start, size: size)
            sides[side] = AlbumSide(side: side, path: listedPath, size: size, format: format, problems: problems)
            files[side] = (child.handle, FieldItem(path: listedPath, info: child.info))
        }
        return (Album(a: sides[.a]!, b: sides[.b]!), files)
    }

    /// A side's format and problems, from the start of its file and its size.
    private func sideProblems(header data: Data, size: Int) -> (AudioFormat?, [String]) {
        let header: WAVHeader
        do {
            header = try WAVHeader(data)
        } catch {
            return (nil, ["it isn't a WAV file the OP-1 writes: \(error)"])
        }
        var problems: [String] = []
        if header.format != profile.sideFormat {
            problems.append("it's \(header.format), not \(profile.sideFormat) as the OP-1 records")
        }
        problems += header.problems(fileSize: size).map { "its WAV header doesn't match its size: \($0)" }
        return (AudioFormat(header.format), problems)
    }

    private static func checkCopyable(_ side: AlbumSide) throws {
        guard !side.isEmpty else {
            throw FieldError(.notFound, path: side.path, reason: "it has no audio")
        }
        guard side.isSound else {
            throw FieldError(.notAllowed, path: side.path, reason: "it isn't sound: " + side.problems.joined(separator: "; "))
        }
    }

    /// Reads `side` whole, writes it to a temporary file in `folder`, reads that back and matches it, then moves it
    /// into place.
    private func copy(_ side: AlbumSide, handle: UInt32, to folder: URL, progress: ProgressManager?) async throws -> AlbumSideCopy {
        try Task.checkCancellation()
        let data = try await session.object(handle)
        guard data.count == side.size else {
            throw FieldError(.verificationFailed, path: side.path, reason: "it read as \(data.count) bytes, not the \(side.size) listed")
        }
        guard (try? WAVHeader(data))?.format == side.format?.wav else {
            throw FieldError(.verificationFailed, path: side.path, reason: "its header isn't what it was a moment ago")
        }
        let sha256 = Self.hex(SHA256.hash(data: data))
        try Task.checkCancellation()

        let temporary = folder.appending(path: ".\(UUID().uuidString).wav")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            let readBack = try Data(contentsOf: temporary)
            guard Self.hex(SHA256.hash(data: readBack)) == sha256 else {
                try? FileManager.default.removeItem(at: temporary)
                throw FieldError(.verificationFailed, path: side.path, reason: "the copy doesn't hold what came off the OP-1")
            }
        } catch let error as FieldError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FieldError(.localFileFailed, path: side.path, underlying: error)
        }
        let copiedAt = Date()
        let url = try Self.moveIntoPlace(temporary, as: folder.appending(path: Self.copyName(side.side, at: copiedAt)))
        progress?.complete(count: side.size)
        return AlbumSideCopy(side: side.side, url: url, size: side.size, sha256: sha256, copiedAt: copiedAt)
    }

    /// Such as `Side A 2026-11-16.wav`, with the date in this device's time zone.
    static func copyName(_ side: Album.Side, at date: Date) -> String {
        "\(side) \(date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())).wav"
    }
}
