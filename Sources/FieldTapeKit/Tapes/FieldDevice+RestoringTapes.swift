import Foundation
import System

/// What `restoreTape` does when a tape with the name is already on the OP-1 (ADR 0002, section 4).
public enum TapeConflict: Sendable, Hashable {
    /// Throw `alreadyExists` and change nothing.
    case fail
}

extension FieldDevice {
    /// Puts an archived tape back on the OP-1 as a new tape, and returns it as the OP-1 lists it.
    ///
    /// It follows the order the probe proved, and stops at the first failure (ADR 0002, section 4):
    /// 1. Everything is checked before anything changes: the name against this firmware's rules, a taken name
    ///    (ignoring case), a free slot, and each track against the 6-minute limit. The archive itself was checked
    ///    when it was opened.
    /// 2. `tapes/<name>` is made, lowercase.
    /// 3. Each track is read from the archive and checked against its SHA-256, then written and read back. The
    ///    tracks go first, because the OP-1 rebuilds `tape.json` when a track changes.
    /// 4. `tape.json` is written last and read back, so the archived clips, loop, tempo and mix are what's kept.
    /// 5. The tape is listed again and checked against the archive.
    ///
    /// Restoring onto other firmware than the archive's isn't refused; `archive.firmware` lets an app warn. If
    /// anything fails after the folder is made, the half-made tape is deleted once, its files first, then its folder.
    /// If that fails too, `changed` lists it. Cancelling is checked between files.
    ///
    /// - Parameters:
    ///   - name: The new tape's name, or nil for the archived name. Either must be one this firmware keeps, at most
    ///     12 characters: an archived name that's longer is refused, so the tape can't come back later under another
    ///     name.
    ///   - conflict: What to do if the name is taken.
    ///   - progress: One unit per byte of the tape's files, completed as each is written and read back.
    /// - Throws: `FieldError` with `.invalidName`, `.alreadyExists`, `.tapeLimitReached`, `.tapeTooLong`,
    ///   `.archiveMismatch` if the archive changed since it was opened, `.invalidArchive`, `.localFileFailed`,
    ///   `.insufficientSpace`, `.verificationFailed`, `.disconnected`, `.timedOut` or `.deviceRefused`, or
    ///   `CancellationError`.
    public func restoreTape(from archive: ReelArchive, as name: TapeName? = nil, conflict: TapeConflict = .fail,
                            progress: consuming Subprogress? = nil) async throws -> Tape {
        let name = name ?? archive.name
        let path = FilePath.op1Tapes.appending(name.string)
        do {
            switch conflict {
            case .fail:
                do {
                    try await checkNewTape(name)
                } catch let error as FieldError where error.code == .invalidName && name == archive.name {
                    throw FieldError(.invalidName, path: path,
                                     reason: (error.reason ?? "it can't be a new tape's name") + ", so restore it under another name")
                }
            }
            for track in archive.tracks where track.frames > profile.maximumTapeFrames {
                throw FieldError(.tapeTooLong, path: path.appending("track_\(track.number).wav"))
            }
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress):
                manager = progress.start(totalCount: archive.tracks.reduce(archive.manifest.data.count) { $0 + $1.size })
            case .none: break
            }
            var files: [(String, () async throws -> Data)] = archive.tracks.map { track in
                ("track_\(track.number).wav", { try archive.trackData(track.number) })
            }
            files.append(("tape.json", { archive.manifest.data }))
            return try await makeTape(named: name, files: files, progress: manager)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }
}
