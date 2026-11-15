import CryptoKit
import Foundation
import System

extension FieldDevice {
    /// Copies a tape off the OP-1 into a new `.reelarchive` in `folder`, checks it, and returns it. The tape stays on
    /// the OP-1, unchanged (ADR 0002, section 4).
    ///
    /// It copies the tape as it is on the OP-1 when the copy starts, which the archive describes, even if that
    /// differs from `tape`, a listing that may be older. In order:
    /// 1. The tape is read fresh. One that isn't sound is refused, with its problems.
    /// 2. Each track, then `tape.json`, is read with one GetObject and written into a temporary archive in `folder`,
    ///    so only one track is in memory at a time.
    /// 3. The tape is read again. If its files or `tape.json` changed while it was copied, the copy is refused.
    /// 4. The archive is opened from disk and checked against the SHA-256 of what came off the OP-1.
    /// 5. It's moved into place as `<tape name>.reelarchive`, never over a file: a taken name gets a number, as
    ///    Finder does.
    ///
    /// Nothing is left in `folder` unless the copy succeeds. Cancelling is checked between files; a read already sent
    /// finishes first, up to about 7 s for a full track.
    ///
    /// - Parameters:
    ///   - compression: None by default, since PCM audio barely shrinks.
    ///   - progress: One unit per byte of the tape's files, completed as each file is in the archive.
    /// - Throws: `FieldError` with `.notFound` if the tape is gone, `.notAllowed` if it isn't sound,
    ///   `.verificationFailed` if it changed while being copied or the archive doesn't check out, `.localFileFailed`,
    ///   `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func copyTape(_ tape: Tape, to folder: URL, compression: ReelArchive.Compression = .none,
                         progress: consuming Subprogress? = nil) async throws -> ReelArchive {
        var writer: ReelArchiveWriter?
        do {
            guard let before = try await self.tape(named: tape.name) else { throw FieldError(.notFound, path: tape.path) }
            guard before.isSound, let type = before.type, let manifest = before.manifest else {
                throw FieldError(.notAllowed, path: before.path,
                                 reason: "it isn't a sound tape: " + before.problems.joined(separator: "; "))
            }
            var files: [(name: String, handle: UInt32, size: Int)] = []
            for name in ReelArchiveWriter.tapeFiles {
                guard let found = try await locate(before.path.appending(name)), let info = found.info else {
                    throw Self.changed(before, "\(name) is gone")
                }
                files.append((name, found.handle, Int(info.compressedSize)))
            }
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress): manager = progress.start(totalCount: files.reduce(0) { $0 + $1.size })
            case .none: break
            }

            let temporary = folder.appending(path: ".\(UUID().uuidString).reelarchive")
            writer = try ReelArchiveWriter(creating: temporary, compression: compression)
            var digests: [String: String] = [:]
            for file in files {
                try Task.checkCancellation()
                let data = try await session.object(file.handle)
                guard data.count == file.size else {
                    throw Self.changed(before, "\(file.name) read as \(data.count) bytes, not the \(file.size) listed")
                }
                if file.name == "tape.json", data != manifest.data {
                    throw Self.changed(before, "tape.json isn't what it was a moment ago")
                }
                digests[file.name] = Self.hex(SHA256.hash(data: data))
                try writer!.add(file.name, data: data)
                manager?.complete(count: data.count)
            }

            guard let after = try await self.tape(named: before.name),
                  after.tracks == before.tracks, after.manifest?.data == manifest.data, after.problems == before.problems else {
                throw Self.changed(before, "its files or tape.json changed while it was copied")
            }
            try writer!.finish(name: before.name, type: type, model: info.model, serialNumber: info.serialNumber,
                               firmware: info.firmware)
            writer = nil

            let archive: ReelArchive
            do {
                archive = try ReelArchive(contentsOf: temporary)
                let sha = Dictionary(uniqueKeysWithValues: archive.tracks.map { ("track_\($0.number).wav", $0.sha256) })
                guard ReelArchiveWriter.tapeFiles.dropLast().allSatisfy({ sha[$0] == digests[$0] }),
                      Self.hex(SHA256.hash(data: archive.manifest.data)) == digests["tape.json"] else {
                    throw FieldError(.verificationFailed, path: before.path,
                                     reason: "the archive doesn't hold what came off the OP-1")
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            return archive.moved(to: try Self.moveIntoPlace(temporary, as: folder.appending(path: "\(before.name.string).reelarchive")))
        } catch {
            writer?.abandon()
            throw FieldError.wrapping(error, path: tape.path)
        }
    }

    private static func changed(_ tape: Tape, _ what: String) -> FieldError {
        FieldError(.verificationFailed, path: tape.path, reason: "it changed on the OP-1 while it was being copied: \(what)")
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Moves `temporary` to `destination`, or the first free numbered name next to it. A move never replaces a file,
    /// so a name taken in between is skipped too. If nothing can be moved, the temporary file is deleted.
    private static func moveIntoPlace(_ temporary: URL, as destination: URL) throws -> URL {
        var number = 1
        while true {
            let url = number == 1 ? destination : numbered(destination, number)
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
                return url
            } catch CocoaError.fileWriteFileExists {
                number += 1
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw FieldError(.localFileFailed, underlying: error)
            }
        }
    }
}

extension ReelArchive {
    /// The same archive, after its file was moved.
    func moved(to url: URL) -> ReelArchive {
        var copy = self
        copy.url = url
        return copy
    }
}
