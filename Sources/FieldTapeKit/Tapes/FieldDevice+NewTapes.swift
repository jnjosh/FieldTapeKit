import Foundation
import System

extension FieldDevice {
    /// Makes a new, empty tape on the OP-1 and returns it (ADR 0002, section 4).
    ///
    /// It's a complete tape, not just a folder: four blank tracks (the 44-byte header) and a blank `tape.json` of
    /// `type`, from the blank Disk Mini tape the probe read (2026-312#01). In order:
    /// 1. The name is checked against this firmware's rules, then a fresh listing of `tapes/`: it mustn't be taken,
    ///    ignoring case, and one of the 8 slots must be free.
    /// 2. `tapes/<name>` is made, lowercase.
    /// 3. Each track, then `tape.json` last, is written and read back.
    /// 4. The tape is read again and checked against what was written.
    ///
    /// If anything fails after the folder is made, the half-made tape is deleted once, its files first, then its
    /// folder. If that fails too, `changed` lists it.
    ///
    /// - Throws: `FieldError` with `.invalidName`, `.alreadyExists`, `.tapeLimitReached`, `.insufficientSpace`,
    ///   `.verificationFailed`, `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func createTape(named name: TapeName, type: TapeType = .studio) async throws -> Tape {
        let path = FilePath.op1Tapes.appending(name.string)
        do {
            try await checkNewTape(name)
            let blank = WAVHeader.bytes(format: profile.trackFormat, dataBytes: 0)
            let json = TapeManifest.blankData(type: type)
            let files: [(String, () async throws -> Data)] = ReelArchiveWriter.tapeFiles.map { name in
                (name, { name == "tape.json" ? json : blank })
            }
            return try await makeTape(named: name, files: files, progress: nil)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Copies a tape on the OP-1 to a new tape named `name`, and returns the copy. The source is only read.
    ///
    /// The OP-1 has no CopyObject, so each track comes through memory, one at a time: read with one GetObject,
    /// written to the new tape and read back. The copy keeps the source's `tape.json` as it is, `padding` included.
    /// In order:
    /// 1. The new name and a free slot are checked, as `createTape` checks them.
    /// 2. The source is read fresh. One that isn't sound is refused, with its problems.
    /// 3. `tapes/<name>` is made, and each track is copied.
    /// 4. The source is read again. If its files or `tape.json` changed, the copy is refused.
    /// 5. `tape.json` is written last, and the new tape is read again and checked against the source.
    ///
    /// If anything fails after the folder is made, the half-made tape is deleted once, as `createTape` does.
    /// Cancelling is checked between files; a read or write already sent finishes first.
    ///
    /// - Parameter progress: One unit per byte of the source's files, completed as each is written and read back.
    /// - Throws: `FieldError` with `.notFound` if the source is gone, `.notAllowed` if it isn't sound,
    ///   `.invalidName`, `.alreadyExists`, `.tapeLimitReached`, `.tapeTooLong`, `.insufficientSpace`,
    ///   `.verificationFailed` if the source changed or the copy doesn't check out, `.disconnected`, `.timedOut` or
    ///   `.deviceRefused`, or `CancellationError`.
    public func duplicateTape(_ tape: Tape, as name: TapeName,
                              progress: consuming Subprogress? = nil) async throws -> Tape {
        let path = FilePath.op1Tapes.appending(name.string)
        do {
            try await checkNewTape(name)
            let (source, manifest) = try await soundTape(tape)
            var sources: [(name: String, handle: UInt32, size: Int)] = []
            for file in ReelArchiveWriter.tapeFiles.dropLast() {
                guard let found = try await locate(source.path.appending(file)), let info = found.info else {
                    throw Self.sourceChanged(source, "\(file) is gone")
                }
                sources.append((file, found.handle, Int(info.compressedSize)))
            }
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress):
                manager = progress.start(totalCount: sources.reduce(manifest.data.count) { $0 + $1.size })
            case .none: break
            }

            var files: [(String, () async throws -> Data)] = sources.map { file in
                (file.name, {
                    let data = try await self.session.object(file.handle)
                    guard data.count == file.size else {
                        throw Self.sourceChanged(source, "\(file.name) read as \(data.count) bytes, not the \(file.size) listed")
                    }
                    return data
                })
            }
            files.append(("tape.json", {
                guard let after = try await self.tape(named: source.name), after.tracks == source.tracks,
                      after.manifest?.data == manifest.data, after.problems == source.problems else {
                    throw Self.sourceChanged(source, "its files or tape.json changed while it was copied")
                }
                return manifest.data
            }))
            return try await makeTape(named: name, files: files, progress: manager)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// The tape as it is now, and its manifest, or an error if it's gone or isn't sound.
    func soundTape(_ tape: Tape) async throws -> (Tape, TapeManifest) {
        guard let now = try await self.tape(named: tape.name) else { throw FieldError(.notFound, path: tape.path) }
        guard now.isSound, let manifest = now.manifest else {
            throw FieldError(.notAllowed, path: now.path, reason: "it isn't a sound tape: " + now.problems.joined(separator: "; "))
        }
        return (now, manifest)
    }

    // MARK: Making a tape

    /// Refuses a name this firmware won't keep, a name that's taken, or a full set of slots, from a fresh listing.
    /// Nothing on the OP-1 changes here.
    func checkNewTape(_ name: TapeName) async throws {
        let path = FilePath.op1Tapes.appending(name.string)
        if let problem = TapeName.problem(with: name.string, maximumLength: profile.maximumTapeNameLength) {
            throw FieldError(.invalidName, path: path, reason: problem)
        }
        let listed = try await contentsOfDirectory(at: .op1Tapes)
        if let taken = listed.first(where: { $0.name.lowercased() == name.string }) {
            throw FieldError(.alreadyExists, path: taken.path)
        }
        if listed.count(where: \.isDirectory) >= profile.maximumTapes {
            throw FieldError(.tapeLimitReached, path: path)
        }
    }

    /// Makes `tapes/<name>` and writes `files` into it in order, each read back, then reads the tape again and
    /// checks it holds what was written. Each file's data is made just before it's written, so only one is held at
    /// a time. If anything fails after the folder is made, the tape is deleted (ADR 0002, section 6).
    func makeTape(named name: TapeName, files: [(String, () async throws -> Data)],
                          progress: ProgressManager?) async throws -> Tape {
        let folder = try await createDirectory(at: FilePath.op1Tapes.appending(name.string))
        do {
            var sizes: [String: Int] = [:]
            var manifest = Data()
            for (file, make) in files {
                try Task.checkCancellation()
                let data = try await make()
                _ = try await write(data, to: folder.path.appending(file))
                sizes[file] = data.count
                if file == "tape.json" { manifest = data }
                progress?.complete(count: data.count)
            }
            guard let made = try await tape(named: name) else {
                throw FieldError(.verificationFailed, path: folder.path, reason: "the new tape isn't listed")
            }
            let listed = Dictionary(uniqueKeysWithValues: made.tracks.map { ("track_\($0.number).wav", $0.size) })
            guard made.isSound, made.manifest?.data == manifest, listed == sizes.filter({ $0.key != "tape.json" }) else {
                let why = made.problems.isEmpty ? "it isn't what was written" : made.problems.joined(separator: "; ")
                throw FieldError(.verificationFailed, path: folder.path, reason: "the new tape doesn't check out: \(why)")
            }
            return made
        } catch {
            throw await removeHalfMadeTape(folder.path, after: error)
        }
    }

    /// Deletes a tape this call made and that didn't come out right, its files first, then its folder, and returns
    /// the error to throw. Once it's gone, nothing on the OP-1 was changed. If the delete fails, the error lists
    /// the tape in `changed`.
    private func removeHalfMadeTape(_ path: FilePath, after error: any Error) async -> any Error {
        let wrapped = FieldError.wrapping(error, path: path)
        do {
            if let folder = try await locate(path) {
                for child in try await children(of: folder) {
                    try await session.deleteObject(child.handle)
                }
                try await session.deleteObject(folder.handle)
            }
            guard let wrapped = wrapped as? FieldError else { return wrapped }
            return wrapped.replacing(changed: [])
        } catch {
            if let wrapped = wrapped as? FieldError { return wrapped.replacing(changed: [path]) }
            // Cancelled, but the half-made tape couldn't be deleted: that has to be said.
            return (FieldError.wrapping(error, path: path) as? FieldError)?.replacing(changed: [path]) ?? wrapped
        }
    }

    private static func sourceChanged(_ tape: Tape, _ what: String) -> FieldError {
        FieldError(.verificationFailed, path: tape.path, reason: "it changed on the OP-1 while it was being copied: \(what)")
    }
}
