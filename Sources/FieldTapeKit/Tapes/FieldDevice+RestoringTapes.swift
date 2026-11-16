import Foundation
import System

/// What `restoreTape` does when a tape with the name is already on the OP-1 (ADR 0002, section 4). Replacing
/// covers the tape that's there first, with a verified archive or a person's confirmation (safety rule 1).
public struct TapeConflict: Sendable, Hashable {
    enum Rule: Sendable, Hashable {
        case fail
        case archiving(URL)
        case confirmed(TapeDeletion)
    }

    let rule: Rule

    /// Throw `alreadyExists` and change nothing.
    public static let fail = TapeConflict(rule: .fail)

    /// Copy the tape that's there into a `.reelarchive` at exactly `archive`, and verify it, then replace the tape.
    /// `archive` must be free: a taken one throws `localFileFailed` before anything changes. If no tape has the
    /// name, it's restored as a new tape and no archive is made.
    public static func replace(archivingExistingTo archive: URL) -> TapeConflict { TapeConflict(rule: .archiving(archive)) }

    /// Replace the tape a person confirmed losing, from `prepareToDelete(_:)` for the same name. The confirmation
    /// is checked as `deleteTape(_:)` checks one, and used up. If no tape has the name any more, it's
    /// `changedSinceConfirmation`.
    public static func replace(confirmed deletion: TapeDeletion) -> TapeConflict { TapeConflict(rule: .confirmed(deletion)) }
}

extension FieldDevice {
    /// Puts an archived tape back on the OP-1, as a new tape or over the one with the name, and returns it as the
    /// OP-1 lists it.
    ///
    /// It follows the order the probe proved, and stops at the first failure (ADR 0002, section 4):
    /// 1. Everything is checked before anything changes: each track against the 6-minute limit, then for a new
    ///    tape the name against this firmware's rules, a taken name (ignoring case) and a free slot. The archive
    ///    itself was checked when it was opened.
    /// 2. Over an existing tape, `conflict` covers it: it's archived and verified, or its confirmation is checked.
    ///    Only the tape's own files may be in its folder. The archive is read again from disk and checked.
    /// 3. Each track is read from the archive and checked against its SHA-256, then written and read back. The
    ///    tracks go first, because the OP-1 rebuilds `tape.json` when a track changes. Over an existing tape, the
    ///    old track is deleted just before, and a track blank on both sides is left as it is.
    /// 4. `tape.json` is written last and read back, so the archived clips, loop, tempo and mix are what's kept.
    /// 5. The tape is listed again and checked against the archive.
    ///
    /// Restoring onto other firmware than the archive's isn't refused; `archive.firmware` lets an app warn.
    ///
    /// A new tape that fails after its folder is made is deleted once, its files first, then its folder. If that
    /// fails too, `changed` lists it. Cancelling is checked between files.
    ///
    /// Over an existing tape there's no rollback (safety rule 6). Once its first file is deleted, cancelling no
    /// longer stops the restore, so a tape isn't left half-written for that. If anything fails, `changed` lists
    /// the files already replaced, and the archive or confirmation covers what was there. An archive made in step 2
    /// is kept, even if the restore fails.
    ///
    /// - Parameters:
    ///   - name: The tape's name, or nil for the archived name. A new tape's must be one this firmware keeps, at
    ///     most 12 characters: an archived name that's longer is refused, so the tape can't come back later under
    ///     another name. A tape already on the OP-1 keeps its name, however long.
    ///   - conflict: What to do if the name is taken.
    ///   - progress: One unit per byte of the tape's files, completed as each is written and read back, and over an
    ///     existing tape that's archived, per byte of it as it's archived.
    /// - Throws: `FieldError` with `.invalidName`, `.alreadyExists`, `.tapeLimitReached`, `.tapeTooLong`,
    ///   `.notAllowed` if the existing tape's folder holds other files or it isn't sound enough to archive,
    ///   `.changedSinceConfirmation`, `.confirmationAlreadyUsed`, `.archiveMismatch` if the archive changed since
    ///   it was opened, `.invalidArchive`, `.localFileFailed`, `.insufficientSpace`, `.verificationFailed`,
    ///   `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func restoreTape(from archive: ReelArchive, as name: TapeName? = nil, conflict: TapeConflict = .fail,
                            progress: consuming Subprogress? = nil) async throws -> Tape {
        let name = name ?? archive.name
        let path = FilePath.op1Tapes.appending(name.string)
        do {
            for track in archive.tracks where track.frames > profile.maximumTapeFrames {
                throw FieldError(.tapeTooLong, path: path.appending("track_\(track.number).wav"))
            }
            let existing: Tape?
            switch conflict.rule {
            case .fail: existing = nil
            case .archiving, .confirmed: existing = try await tape(named: name)
            }
            let archiveBytes = archive.tracks.reduce(archive.manifest.data.count) { $0 + $1.size }
            let existingBytes = if case .archiving = conflict.rule, let existing {
                existing.tracks.reduce(existing.manifest?.data.count ?? 0) { $0 + $1.size }
            } else { 0 }
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress): manager = progress.start(totalCount: archiveBytes + existingBytes)
            case .none: break
            }

            switch (conflict.rule, existing) {
            case (.confirmed(let deletion), nil):
                throw FieldError(.changedSinceConfirmation, path: deletion.tape.path)
            case (.confirmed(let deletion), let existing?):
                try checkConfirmation(deletion, for: existing)
                return try await replaceTape(existing, with: archive, confirmation: deletion, progress: manager)
            case (.archiving(let url), let existing?):
                let copy = try await copyTape(existing, toExactly: url,
                                              progress: manager?.subprogress(assigningCount: existingBytes))
                return try await replaceTape(existing, with: archive, coveredBy: copy, progress: manager)
            case (.fail, _), (.archiving, nil):
                do {
                    try await checkNewTape(name)
                } catch let error as FieldError where error.code == .invalidName && name == archive.name {
                    throw FieldError(.invalidName, path: path,
                                     reason: (error.reason ?? "it can't be a new tape's name") + ", so restore it under another name")
                }
                return try await makeTape(named: name, files: Self.files(of: archive), progress: manager)
            }
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// The tape's files in the order they're written: each track, read from the archive and checked just before,
    /// then `tape.json`.
    private static func files(of archive: ReelArchive) -> [(String, () async throws -> Data)] {
        archive.tracks.map { track in ("track_\(track.number).wav", { try archive.trackData(track.number) }) }
            + [("tape.json", { archive.manifest.data })]
    }

    // MARK: Replacing

    /// Refuses a confirmation that's used, from another connection, or for another tape. Whether the tape still
    /// matches it is checked with a fresh listing, in `replaceTape`.
    private func checkConfirmation(_ deletion: TapeDeletion, for existing: Tape) throws {
        guard !usedConfirmations.contains(deletion.id) else { throw FieldError(.confirmationAlreadyUsed, path: deletion.tape.path) }
        guard deletion.tape.name == existing.name else {
            throw FieldError(.notAllowed, path: existing.path, reason: "the confirmation is for \(deletion.tape.path)")
        }
        guard deletion.deviceID == id, existing == deletion.tape else {
            throw FieldError(.changedSinceConfirmation, path: deletion.tape.path)
        }
    }

    /// Writes the archive over `existing`, file by file, once it's covered: by `copy`, an archive of it just made,
    /// or by `confirmation`. Everything is checked again from a fresh listing before the first delete.
    private func replaceTape(_ existing: Tape, with archive: ReelArchive, coveredBy copy: ReelArchive? = nil,
                             confirmation: TapeDeletion? = nil, progress: ProgressManager?) async throws -> Tape {
        guard let folder = try await locate(existing.path) else { throw FieldError(.notFound, path: existing.path) }
        let contents = try await everything(in: folder)
        if let confirmation {
            guard try await tape(named: existing.name) == confirmation.tape, contents.map(\.item) == confirmation.contents else {
                throw FieldError(.changedSinceConfirmation, path: confirmation.tape.path)
            }
        }
        if let copy {
            // The archive is of the tape as it was. If the OP-1 lists it differently now, the archive doesn't cover it.
            guard let now = try await tape(named: existing.name), now.tracks.map(\.size) == copy.tracks.map(\.size),
                  now.manifest?.data == copy.manifest.data else {
                throw FieldError(.verificationFailed, path: existing.path,
                                 reason: "it changed on the OP-1 after it was archived, so it wasn't replaced")
            }
        }
        let allowed = Set(profile.tapeFiles.required + profile.tapeFiles.optional)
        let others = contents.filter { $0.item.isDirectory || !allowed.contains($0.item.name.lowercased()) }
        guard others.isEmpty else {
            throw FieldError(.notAllowed, path: existing.path,
                             reason: "its folder holds files a tape doesn't: " + others.map(\.item.name).joined(separator: ", "))
        }
        let onDisk = try ReelArchive(contentsOf: archive.url)
        guard onDisk.tracks == archive.tracks, onDisk.manifest == archive.manifest else {
            throw FieldError(.archiveMismatch, reason: "it no longer holds what it held when it was opened")
        }
        let handles = Dictionary(contents.map { ($0.item.name.lowercased(), $0.handle) }, uniquingKeysWith: { first, _ in first })
        let blank = Set(existing.tracks.filter(\.isBlank).map { "track_\($0.number).wav" })
        let skipped = Set(archive.tracks.filter(\.isBlank).map { "track_\($0.number).wav" }).intersection(blank)
        try Task.checkCancellation()

        if let confirmation { usedConfirmations.insert(confirmation.id) }
        // From the first delete on, the restore runs to the end whatever happens to the caller's task: an
        // unstructured task isn't cancelled with it.
        let work = Task {
            try await self.writeOver(existing, files: Self.files(of: archive), handles: handles, skipping: skipped,
                                     progress: progress)
        }
        return try await work.value
    }

    /// Replaces each file in turn: the data is made, the old file deleted, the new one written and read back. Then
    /// the tape is listed again and checked. Any failure lists in `changed` every file already touched.
    private func writeOver(_ existing: Tape, files: [(String, () async throws -> Data)], handles: [String: UInt32],
                           skipping skipped: Set<String>, progress: ProgressManager?) async throws -> Tape {
        var changed: [FilePath] = []
        var sizes: [String: Int] = [:]
        var manifest = Data()
        for (file, make) in files {
            let path = existing.path.appending(file)
            do {
                let data = try await make()
                sizes[file] = data.count
                if file == "tape.json" { manifest = data }
                if !skipped.contains(file) {
                    if let handle = handles[file] {
                        try await session.deleteObject(handle)
                        changed.append(path)
                    }
                    _ = try await write(data, to: path)
                    if !changed.contains(path) { changed.append(path) }
                }
                progress?.complete(count: data.count)
            } catch {
                guard let error = FieldError.wrapping(error, path: path) as? FieldError else { throw error }
                throw error.replacing(changed: changed)
            }
        }
        guard let made = try await tape(named: existing.name) else {
            throw FieldError(.verificationFailed, path: existing.path, changed: changed, reason: "the tape isn't listed")
        }
        let listed = Dictionary(uniqueKeysWithValues: made.tracks.map { ("track_\($0.number).wav", $0.size) })
        guard made.isSound, made.manifest?.data == manifest, listed == sizes.filter({ $0.key != "tape.json" }) else {
            let why = made.problems.isEmpty ? "it isn't what was written" : made.problems.joined(separator: "; ")
            throw FieldError(.verificationFailed, path: existing.path, changed: changed,
                             reason: "the restored tape doesn't check out: \(why)")
        }
        return made
    }
}
