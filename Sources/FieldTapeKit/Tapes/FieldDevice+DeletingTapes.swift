import CryptoKit
import Foundation
import System

/// A copy that lets `deleteTape(_:keeping:)` delete a tape with no prompt (ADR 0002, section 6).
public enum TapeCopy: Sendable, Hashable {
    /// A `.reelarchive` of the tape, still on disk as it was when it was opened.
    case archive(ReelArchive)
    /// Another tape on the OP-1 with the same tracks and `tape.json`, such as a duplicate.
    case tape(Tape)
}

/// A tape that a person can confirm deleting, from `prepareToDelete(_:)` (ADR 0002, section 6).
///
/// Show it to the person, then pass it to `deleteTape(_:)`. It works once, only on the connection that made it,
/// and only while the tape's files and `tape.json` are as they were when it was made.
public struct TapeDeletion: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// As read fresh when this was made.
    public let tape: Tape
    /// Everything in the tape's folder, as listed when this was made.
    public let contents: [FieldItem]
    let deviceID: FieldDevice.ID

    /// How much audio would be lost: to the end of the last clip.
    public var audio: Duration { tape.duration }
    /// How many clips would be lost.
    public var clipCount: Int { tape.manifest?.clips.count ?? 0 }
    /// A sound tape with every track blank and no clips, such as a new one from `createTape`, so nothing would be
    /// lost and the prompt can be skipped.
    public var losesNothing: Bool { tape.isSound && tape.isEmpty }
}

extension FieldDevice {
    /// Copies a tape off the OP-1 into a new `.reelarchive` in `folder`, checks it, and only then deletes the tape,
    /// freeing its slot (ADR 0002, section 4).
    ///
    /// The copy is made as `copyTape(_:to:compression:progress:)` makes one, of the tape as it is when the copy
    /// starts. Then the tape is deleted as `deleteTape(_:keeping:progress:)` deletes one, keeping the archive: each
    /// track is read from the OP-1 a second time and matched to the archive by SHA-256, so a read that went wrong
    /// can't leave a bad archive (ADR 0002, safety rule 2). If its track sizes or `tape.json` aren't what was
    /// archived, it isn't deleted. Its files are deleted first, then its folder.
    ///
    /// If anything fails after the archive is made, or the task is cancelled then, the archive is kept in `folder`.
    /// If a delete fails part way, the error's `changed` lists the files already deleted.
    ///
    /// - Parameter progress: One unit per byte of the tape's files as each is in the archive, then one per byte of
    ///   its tracks as each is matched again.
    /// - Returns: The archive, which holds the only copy of the tape once this returns.
    /// - Throws: The codes of `copyTape` and `deleteTape(_:keeping:progress:)`, with `.verificationFailed` if the
    ///   tape changed after it was archived or read differently the second time, or `CancellationError`.
    public func moveTape(_ tape: Tape, to folder: URL, progress: consuming Subprogress? = nil) async throws -> ReelArchive {
        let trackBytes = tape.tracks.reduce(0) { $0 + $1.size }
        let copyBytes = trackBytes + (tape.manifest?.data.count ?? 0)
        var manager: ProgressManager?
        switch consume progress {
        case .some(let progress): manager = progress.start(totalCount: copyBytes + trackBytes)
        case .none: break
        }
        let archive = try await copyTape(tape, to: folder, progress: manager?.subprogress(assigningCount: copyBytes))
        try await deleteTape(tape, keeping: .archive(archive), progress: manager?.subprogress(assigningCount: trackBytes))
        return archive
    }

    /// Deletes a tape from the OP-1 once `copy` is shown to hold exactly what it holds, with no prompt
    /// (ADR 0002, safety rules 1 and 2).
    ///
    /// In order:
    /// 1. The tape is read fresh. One that isn't sound is refused: it needs `prepareToDelete` and a person.
    /// 2. The copy's track sizes and `tape.json` are checked against it. Another tape is read fresh too.
    /// 3. Each of the tape's tracks is read from the OP-1, one at a time, and matched by SHA-256 to the archive's
    ///    record, or to the other tape's track, read the same way. A full tape takes about 25 s, twice that with
    ///    a tape as the copy.
    /// 4. An archive is read again from disk and checked against what it held when it was opened.
    /// 5. The tape is listed again, unchanged, and its files are deleted, then its folder.
    ///
    /// Nothing changes before the last step. If a delete fails part way, the error's `changed` lists the files
    /// already deleted. Cancelling is checked between reads.
    ///
    /// - Parameter progress: One unit per byte read from the OP-1, completed as each track is matched.
    /// - Throws: `FieldError` with `.notFound` if the tape or the other tape is gone, `.notAllowed` if either isn't
    ///   sound or the copy is the tape itself, `.verificationFailed` if the copy doesn't match or the tape changed,
    ///   `.archiveMismatch` if the archive changed on disk, `.invalidArchive` or `.localFileFailed` if it can't be
    ///   read, `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func deleteTape(_ tape: Tape, keeping copy: TapeCopy, progress: consuming Subprogress? = nil) async throws {
        do {
            let (before, manifest) = try await soundTape(tape)
            var other: Tape?
            switch copy {
            case .archive(let archive):
                guard archive.tracks.map(\.size) == before.tracks.map(\.size), archive.manifest.data == manifest.data else {
                    throw Self.copyDoesntMatch(before, "the archive's track sizes or tape.json are different")
                }
            case .tape(let copy):
                guard copy.name != before.name else {
                    throw FieldError(.notAllowed, path: before.path, reason: "a tape can't be its own copy")
                }
                let (found, copyManifest) = try await soundTape(copy)
                guard found.tracks.map(\.size) == before.tracks.map(\.size), copyManifest.data == manifest.data else {
                    throw Self.copyDoesntMatch(before, "\(found.path)'s track sizes or tape.json are different")
                }
                other = found
            }

            let handles = try await trackHandles(before)
            let otherHandles = if let other { try await trackHandles(other) } else { [UInt32]() }
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress):
                manager = progress.start(totalCount: before.tracks.reduce(0) { $0 + $1.size } * (other == nil ? 1 : 2))
            case .none: break
            }
            for (index, track) in before.tracks.enumerated() {
                try Task.checkCancellation()
                let digest = try await trackDigest(before, track, handle: handles[index])
                manager?.complete(count: track.size)
                let expected: String
                switch copy {
                case .archive(let archive):
                    expected = archive.tracks[index].sha256
                case .tape:
                    try Task.checkCancellation()
                    expected = try await trackDigest(other!, other!.tracks[index], handle: otherHandles[index])
                    manager?.complete(count: track.size)
                }
                guard digest == expected else {
                    throw Self.copyDoesntMatch(before, "track_\(track.number).wav holds different audio")
                }
            }

            if case .archive(let archive) = copy {
                let onDisk = try ReelArchive(contentsOf: archive.url)
                guard onDisk.tracks == archive.tracks, onDisk.manifest == archive.manifest else {
                    throw FieldError(.archiveMismatch, reason: "it no longer holds what it held when it was opened")
                }
            }
            if let other {
                guard try await self.tape(named: other.name) == other else {
                    throw Self.copyDoesntMatch(before, "\(other.path) changed while it was checked")
                }
            }
            guard let after = try await self.tape(named: before.name), after == before else {
                throw FieldError(.verificationFailed, path: before.path,
                                 reason: "it changed on the OP-1 while it was checked, so it wasn't deleted")
            }
            try await deleteFolder(of: after)
        } catch {
            throw FieldError.wrapping(error, path: tape.path)
        }
    }

    /// Reads the tape fresh, and everything in its folder, so a person can confirm losing exactly that. A tape that
    /// isn't sound can be deleted this way.
    ///
    /// - Throws: `FieldError` with `.notFound`, `.disconnected`, `.timedOut` or `.deviceRefused`, or
    ///   `CancellationError`.
    public func prepareToDelete(_ tape: Tape) async throws -> TapeDeletion {
        do {
            guard let now = try await self.tape(named: tape.name), let folder = try await locate(now.path) else {
                throw FieldError(.notFound, path: tape.path)
            }
            let contents = try await everything(in: folder).map(\.item)
            return TapeDeletion(id: UUID(), tape: now, contents: contents, deviceID: id)
        } catch {
            throw FieldError.wrapping(error, path: tape.path)
        }
    }

    /// Deletes what a person confirmed: the tape's files, then its folder.
    ///
    /// It checks first that the confirmation is unused, from this connection, and that the tape's files and
    /// `tape.json` are still exactly as confirmed. It's used up as soon as the first delete is sent. If a delete
    /// fails part way, the error's `changed` lists the files already deleted, and nothing more is tried.
    ///
    /// - Throws: `FieldError` with `.changedSinceConfirmation`, `.confirmationAlreadyUsed`, `.disconnected`,
    ///   `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func deleteTape(_ deletion: TapeDeletion) async throws {
        let path = deletion.tape.path
        guard !usedConfirmations.contains(deletion.id) else { throw FieldError(.confirmationAlreadyUsed, path: path) }
        guard deletion.deviceID == id else { throw FieldError(.changedSinceConfirmation, path: path) }
        let targets: [(handle: UInt32, item: FieldItem)]
        do {
            guard try await tape(named: deletion.tape.name) == deletion.tape,
                  let folder = try await locate(path), let info = folder.info else {
                throw FieldError(.changedSinceConfirmation, path: path)
            }
            let contents = try await everything(in: folder)
            guard contents.map(\.item) == deletion.contents else { throw FieldError(.changedSinceConfirmation, path: path) }
            targets = Self.deletionOrder((folder.handle, FieldItem(path: folder.path, info: info)), contents: contents)
            try Task.checkCancellation()
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
        usedConfirmations.insert(deletion.id)
        try await deleteInOrder(targets)
    }

    // MARK: Helpers

    /// Deletes a sound tape's files, then its folder, after listing it one last time: only the files `tape` lists,
    /// at the sizes it lists, and an optional `readme.txt` (ADR 0002, safety rule 4).
    private func deleteFolder(of tape: Tape) async throws {
        guard let folder = try await locate(tape.path), let info = folder.info, info.isFolder,
              let manifest = tape.manifest else {
            throw FieldError(.verificationFailed, path: tape.path, reason: "it changed on the OP-1, so it wasn't deleted")
        }
        let contents = try await everything(in: folder)
        var expected = Dictionary(uniqueKeysWithValues: tape.tracks.map { ("track_\($0.number).wav", $0.size) })
        expected["tape.json"] = manifest.data.count
        let listed = Dictionary(contents.map { ($0.item.name, $0.item.size) }, uniquingKeysWith: { first, _ in first })
        let extra = contents.filter { expected[$0.item.name] == nil }
        guard listed.filter({ expected[$0.key] != nil }) == expected, contents.count == listed.count,
              extra.allSatisfy({ !$0.item.isDirectory && profile.tapeFiles.optional.contains($0.item.name) }) else {
            throw FieldError(.verificationFailed, path: tape.path,
                             reason: "its files changed on the OP-1 after it was checked, so it wasn't deleted")
        }
        try Task.checkCancellation()
        try await deleteInOrder(Self.deletionOrder((folder.handle, FieldItem(path: folder.path, info: info)), contents: contents))
    }

    /// Reads each of the tape's tracks from the OP-1, one at a time, and matches it by SHA-256 to the archive's
    /// record, before the tape is written over. The archive was checked against the first read, so this second one
    /// is what shows it holds the tape (ADR 0002, safety rule 2).
    func matchTracks(_ tape: Tape, to archive: ReelArchive, progress: ProgressManager?) async throws {
        let handles = try await trackHandles(tape)
        for (index, track) in tape.tracks.enumerated() {
            try Task.checkCancellation()
            guard try await trackDigest(tape, track, handle: handles[index]) == archive.tracks[index].sha256 else {
                throw FieldError(.verificationFailed, path: tape.path,
                                 reason: "track_\(track.number).wav read differently a second time, so the archive may "
                                    + "not hold it, and nothing was replaced")
            }
            progress?.complete(count: track.size)
        }
    }

    /// Each track's handle, in the tape's order.
    private func trackHandles(_ tape: Tape) async throws -> [UInt32] {
        var handles: [UInt32] = []
        for track in tape.tracks {
            guard let found = try await locate(track.path), found.info != nil else {
                throw FieldError(.verificationFailed, path: tape.path,
                                 reason: "it changed on the OP-1 while it was checked: track_\(track.number).wav is gone")
            }
            handles.append(found.handle)
        }
        return handles
    }

    /// One track read whole from the OP-1, checked against its listed size, as a SHA-256.
    private func trackDigest(_ tape: Tape, _ track: TapeTrack, handle: UInt32) async throws -> String {
        let data = try await session.object(handle)
        guard data.count == track.size else {
            throw FieldError(.verificationFailed, path: tape.path,
                             reason: "it changed on the OP-1 while it was checked: track_\(track.number).wav read as "
                                + "\(data.count) bytes, not the \(track.size) listed")
        }
        return Self.hex(SHA256.hash(data: data))
    }

    private static func copyDoesntMatch(_ tape: Tape, _ what: String) -> FieldError {
        FieldError(.verificationFailed, path: tape.path, reason: "the copy doesn't match it, so it wasn't deleted: \(what)")
    }
}
