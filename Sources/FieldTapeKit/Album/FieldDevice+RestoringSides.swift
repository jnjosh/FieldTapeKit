import Foundation
import System

/// What ``FieldDevice/restoreSide(_:from:conflict:progress:)`` does when the side already has audio.
///
/// Replacing covers the side that's there first, with a verified copy or a person's confirmation (ADR 0002,
/// section 5, and safety rule 1). An empty side is written over whatever this says, since nothing is lost.
///
/// - Important: Album writing is off on firmware 1.7.3 (`album.write-again`).
public struct SideConflict: Sendable, Hashable {
    enum Rule: Sendable, Hashable {
        case fail
        case copying(URL)
        case confirmed(SideReplacement)
    }

    let rule: Rule

    /// Throws `alreadyExists` and changes nothing.
    public static let fail = SideConflict(rule: .fail)

    /// Copies the side that's there to a WAV file and verifies it, then replaces the side.
    ///
    /// An empty side isn't copied.
    ///
    /// - Parameter copy: Exactly where to put the copy. It must be free: a taken URL throws `localFileFailed` before
    ///   anything changes.
    /// - Returns: The rule, to pass as `conflict`.
    public static func replace(copyingExistingTo copy: URL) -> SideConflict { SideConflict(rule: .copying(copy)) }

    /// Replaces a side a person confirmed losing.
    ///
    /// It's refused if it's used, from another connection, or the side changed since, and it's used up once the old
    /// side is deleted.
    ///
    /// - Parameter replacement: From ``FieldDevice/prepareToReplace(_:)``, for the same side.
    /// - Returns: The rule, to pass as `conflict`.
    public static func replace(confirmed replacement: SideReplacement) -> SideConflict { SideConflict(rule: .confirmed(replacement)) }
}

/// A side a person can confirm losing, for ``SideConflict/replace(confirmed:)``.
///
/// Get one from ``FieldDevice/prepareToReplace(_:)``. It works once, only with the ``FieldDevice`` that made it, and
/// only while the side is as it was then.
public struct SideReplacement: Sendable, Hashable, Identifiable {
    /// Identifies this confirmation, which works once.
    public let id: UUID
    /// As read fresh when this was made.
    public let side: AlbumSide
    let deviceID: FieldDevice.ID

    /// How much audio would be lost.
    public var audio: Duration { side.isEmpty ? .zero : side.duration }
    /// The side is empty, so nothing would be lost and the prompt can be skipped.
    public var losesNothing: Bool { side.isEmpty }
}

extension FieldDevice {
    /// Reads a side fresh, for a person to confirm losing it before a restore replaces it.
    ///
    /// - Parameter side: The side that would be replaced.
    /// - Returns: The confirmation to show the person, then to pass to ``SideConflict/replace(confirmed:)``.
    /// - Throws: As ``album()``.
    public func prepareToReplace(_ side: Album.Side) async throws -> SideReplacement {
        do {
            return SideReplacement(id: UUID(), side: try await listAlbum().album[side], deviceID: id)
        } catch {
            throw FieldError.wrapping(error, path: FilePath.op1Mixdown.appending(side.fileName))
        }
    }

    /// Writes a WAV file as side A or B, and returns the side as the OP-1 lists it.
    ///
    /// - Important: Off on firmware 1.7.3: it throws `notAllowed` there, before anything is read. A side written
    ///   over MTP hung the OP-1 when it was written again after a reconnect, until it was restarted
    ///   (`album.write-again`), so album writing waits until that's understood (ADR 0002, 2026-11-16).
    ///
    /// It follows the file layer's replace, and stops at the first failure (ADR 0002, sections 5 and 6):
    /// 1. Everything is checked before anything changes. The file must be what the OP-1 records: the 44-byte
    ///    header, 16-bit stereo PCM at 44.1 kHz, matching its size, and at most 6 minutes. A side with audio must be
    ///    covered by `conflict`: copied and verified, or confirmed.
    /// 2. The old side is deleted, then the new one sent and read back byte for byte (`album.write-exact`).
    /// 3. The album is listed again and the side checked.
    ///
    /// Once the old side is deleted, cancelling no longer stops the restore. If anything fails after that, nothing
    /// more is written: the side's file may be missing, `changed` lists it, and the copy or confirmation covers what
    /// was there (safety rule 6). A copy made for `conflict` is kept, even if the restore fails.
    ///
    /// - Parameters:
    ///   - side: The side to write.
    ///   - file: A local WAV file in the OP-1's album format.
    ///   - conflict: What to do if the side has audio. The default, ``SideConflict/fail``, changes nothing.
    ///   - progress: One unit per byte of the new side, completed once it's written and read back.
    /// - Returns: The side as the OP-1 lists it after the write.
    /// - Throws: `FieldError` with `.notAllowed` where album writing is off, for a file in another format, or a
    ///   confirmation for the other side,
    ///   `.tapeTooLong` for one over 6 minutes, `.alreadyExists`, `.changedSinceConfirmation`,
    ///   `.confirmationAlreadyUsed`, `.localFileFailed`, `.insufficientSpace`, `.verificationFailed`, `.disconnected`,
    ///   `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func restoreSide(_ side: Album.Side, from file: URL, conflict: SideConflict = .fail,
                            progress: consuming Subprogress? = nil) async throws -> AlbumSide {
        let path = FilePath.op1Mixdown.appending(side.fileName)
        do {
            guard albumWritesAllowed else { throw FieldError(.notAllowed, path: path, reason: Self.albumWritesOff) }
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw FieldError(.localFileFailed, path: path, underlying: error)
            }
            try WriteRules(profile: profile).checkFile(["mixdown", side.fileName], data: data, path: path)
            var manager: ProgressManager?
            switch consume progress {
            case .some(let progress): manager = progress.start(totalCount: data.count)
            case .none: break
            }

            let (album, files) = try await listAlbum()
            let current = album[side]
            let existing: ExistingFile
            switch conflict.rule {
            case .confirmed(let replacement):
                try checkReplacement(replacement, for: current)
                if let file = files[side] {
                    // The file layer checks it against a fresh listing again, and uses it up at the delete.
                    existing = .replace(confirmed: FileDeletion(id: replacement.id, item: file.item, contents: [], deviceID: id))
                } else {
                    usedConfirmations.insert(replacement.id)
                    existing = .fail
                }
            case _ where current.isEmpty:
                // Nothing is lost, so the side as just listed is its own confirmation.
                existing = files[side].map { .replace(confirmed: FileDeletion(id: UUID(), item: $0.item, contents: [], deviceID: id)) } ?? .fail
            case .fail:
                throw FieldError(.alreadyExists, path: current.path)
            case .copying(let copy):
                existing = .replace(keepingCopyAt: copy)
            }

            _ = try await write(data, to: current.path, options: UploadOptions(existing: existing))
            do {
                let after = try await listAlbum().album[side]
                guard after.size == data.count, after.isSound else {
                    let why = after.problems.isEmpty ? "it's \(after.size) bytes, not \(data.count)" : after.problems.joined(separator: "; ")
                    throw FieldError(.verificationFailed, path: path, reason: "the restored side doesn't check out: \(why)")
                }
                manager?.complete(count: data.count)
                return after
            } catch {
                let wrapped = FieldError.wrapping(error, path: path)
                guard let wrapped = wrapped as? FieldError else { throw wrapped }
                throw wrapped.changed.contains(current.path) ? wrapped : wrapped.adding(changed: [current.path])
            }
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Refuses a confirmation that's used, from another connection, for the other side, or for a side that changed.
    private func checkReplacement(_ replacement: SideReplacement, for current: AlbumSide) throws {
        guard !usedConfirmations.contains(replacement.id) else {
            throw FieldError(.confirmationAlreadyUsed, path: replacement.side.path)
        }
        guard replacement.side.side == current.side else {
            throw FieldError(.notAllowed, path: current.path, reason: "the confirmation is for \(replacement.side.side)")
        }
        guard replacement.deviceID == id, replacement.side == current else {
            throw FieldError(.changedSinceConfirmation, path: current.path)
        }
    }
}
