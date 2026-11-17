import CryptoKit
import Foundation
import System

extension FieldDevice {
    /// Reads a whole file on the OP-1 into memory, with one GetObject.
    ///
    /// The OP-1 charges every read for everything before it in the file (`read.cost`), so whole files are read in
    /// one go (ADR 0002, 2026-11-14). The size is checked fresh first. A file the OP-1 rewrote within this session
    /// still lists and reads at its old size (`rebuild.stale-size`), and nothing over MTP shows that.
    ///
    /// - Parameters:
    ///   - path: The file, relative to the device root, matched ignoring case.
    ///   - maximumSize: The largest file to hold in memory, 32 MiB by default. A tape track can be 127 MB;
    ///     ``copyItem(at:to:progress:)`` copies any size to disk.
    /// - Returns: The file's bytes.
    /// - Throws: `FieldError` with `.notFound`, `.isADirectory`, `.tooLarge`, `.notADirectory`, `.ambiguousPath`,
    ///   `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func contents(of path: FilePath, maximumSize: Int = 32 << 20) async throws -> Data {
        do {
            let file = try await file(at: path)
            guard file.size <= maximumSize else { throw FieldError(.tooLarge, path: file.path) }
            try Task.checkCancellation()
            return try await session.object(file.handle)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Reads part of a file on the OP-1, with one GetPartialObject.
    ///
    /// A range that runs past the end gives the bytes up to the end, and one that starts at or past the end gives
    /// empty data. A read costs about what reading from the file's start to the end of the range would
    /// (`read.cost`), so this suits small reads near the start, such as a WAV header.
    ///
    /// - Warning: On a Mac and on an iPad, a run of these reads deep into a large file has stalled: the read came
    ///   back empty after about 60 seconds, and so did every later request until the OP-1 was reconnected
    ///   (2026-11-17). To read a whole file, use ``contents(of:maximumSize:)`` or
    ///   ``copyItem(at:to:progress:)``.
    ///
    /// - Precondition: `range.lowerBound` isn't negative.
    /// - Parameters:
    ///   - path: The file, relative to the device root, matched ignoring case.
    ///   - range: The byte offsets to read.
    /// - Returns: The bytes in `range` that the file has.
    /// - Throws: As ``contents(of:maximumSize:)``, apart from `.tooLarge`.
    public func contents(of path: FilePath, range: Range<Int>) async throws -> Data {
        precondition(range.lowerBound >= 0, "A range on the OP-1 can't start before the file does")
        do {
            let file = try await file(at: path)
            let start = min(range.lowerBound, file.size)
            let end = min(range.upperBound, file.size)
            guard start < end else { return Data() }
            try Task.checkCancellation()
            return try await session.partialObject(file.handle, offset: UInt32(start), maxLength: UInt32(end - start))
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Copies a file off the OP-1 to this device, and returns where it went.
    ///
    /// It reads the file with one GetObject, so up to one track (127 MB) is held in memory. It never overwrites a
    /// local file: if `destination` is taken, a number is added as Finder does, such as `side_a 2.wav`. The copy is
    /// read back from disk and matched by SHA-256 before it counts (ADR 0002, safety rule 2). If it doesn't match,
    /// it's deleted.
    ///
    /// - Parameters:
    ///   - source: The file on the OP-1, relative to the device root, matched ignoring case.
    ///   - destination: The local file to write. Its folder must exist.
    ///   - progress: Three steps: reading from the OP-1, writing, and reading back. The read can't report anything
    ///     in between, and once sent it finishes before a cancel takes effect: up to about 7 s for a full track.
    /// - Returns: The URL written, which is `destination` unless that was taken.
    /// - Throws: `FieldError` with `.verificationFailed`, `.localFileFailed`, or the codes of
    ///   ``contents(of:maximumSize:)`` apart from `.tooLarge`, or `CancellationError`.
    @discardableResult
    public func copyItem(at source: FilePath, to destination: URL, progress: consuming Subprogress? = nil) async throws -> URL {
        try await verifiedCopy(of: source, to: destination, progress: progress).url
    }

    /// As `copyItem(at:to:progress:)`, and also returns the copy's SHA-256, for matching the file on the OP-1 again.
    func verifiedCopy(of source: FilePath, to destination: URL,
                      progress: consuming Subprogress? = nil) async throws -> (url: URL, sha256: SHA256.Digest) {
        var manager: ProgressManager?
        switch consume progress {
        case .some(let progress): manager = progress.start(totalCount: 3)
        case .none: break
        }
        do {
            let file = try await file(at: source)
            try Task.checkCancellation()
            let data = try await session.object(file.handle)
            // The OP-1 returns as much as it lists, so anything else is a read that went wrong.
            guard data.count == file.size else { throw FieldError(.verificationFailed, path: file.path) }
            let digest = SHA256.hash(data: data)
            manager?.complete(count: 1)

            try Task.checkCancellation()
            let url = try Self.writeWithoutOverwriting(data, to: destination, source: file.path)
            manager?.complete(count: 1)

            let readBack: Data
            do {
                readBack = try Data(contentsOf: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw FieldError(.localFileFailed, path: file.path, underlying: error)
            }
            guard SHA256.hash(data: readBack) == digest else {
                try? FileManager.default.removeItem(at: url)
                throw FieldError(.verificationFailed, path: file.path)
            }
            manager?.complete(count: 1)
            return (url, digest)
        } catch {
            throw FieldError.wrapping(error, path: source)
        }
    }

    // MARK: Helpers

    /// Reads a file whole from the OP-1 a second time and matches it to a copy's SHA-256, before the file is deleted.
    /// The copy was checked against the first read, so a read that went wrong would leave a bad copy that passes. A
    /// second read that agrees rules that out (ADR 0002, safety rule 2).
    func matchAgain(_ handle: UInt32, at path: FilePath, to sha256: SHA256.Digest) async throws {
        try Task.checkCancellation()
        let data = try await session.object(handle)
        guard SHA256.hash(data: data) == sha256 else {
            throw FieldError(.verificationFailed, path: path,
                             reason: "it read differently a second time, so the copy may not hold it, and it wasn't deleted")
        }
    }

    /// The file at `path`, fresh from the OP-1.
    private func file(at path: FilePath) async throws -> (handle: UInt32, path: FilePath, size: Int) {
        guard let found = try await locate(path), let info = found.info else { throw FieldError(.notFound, path: path) }
        guard !info.isFolder else { throw FieldError(.isADirectory, path: found.path) }
        return (found.handle, found.path, Int(info.compressedSize))
    }

    /// Writes `data` to `destination`, or the first free numbered name next to it. `.withoutOverwriting` refuses
    /// a name something took in between, and the next number is tried.
    static func writeWithoutOverwriting(_ data: Data, to destination: URL, source: FilePath) throws -> URL {
        var number = 1
        while true {
            let url = number == 1 ? destination : numbered(destination, number)
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                    return url
                } catch CocoaError.fileWriteFileExists {
                    // Taken since the check.
                } catch {
                    throw FieldError(.localFileFailed, path: source, underlying: error)
                }
            }
            number += 1
        }
    }

    /// `side_a.wav` becomes `side_a 2.wav`, as Finder names copies.
    static func numbered(_ url: URL, _ number: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
        return url.deletingLastPathComponent().appending(path: name)
    }
}
