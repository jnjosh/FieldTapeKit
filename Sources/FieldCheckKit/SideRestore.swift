import CryptoKit
import FieldTapeKit
import Foundation
import System

/// Puts an album side back from the copy level 2 kept of it, when the side still holds FieldCheck's tone: after a
/// level 3 that didn't finish putting it back (FieldCheck, 2026-11-16).
///
/// It writes only over FieldCheck's own tone, so nothing of the person's can be lost, and only after they confirm.
/// Every MTP request is traced while it runs, so if the OP-1 stops answering, the trace says which request.
public enum SideRestore {
    /// A copy of a side that level 2 kept, in its run folder.
    public struct Copy: Sendable, Hashable, Identifiable {
        public let side: Album.Side
        public let url: URL
        /// The run folder's name, such as `level2-2026-11-16T035851Z`.
        public let folder: String
        public let size: Int
        /// Read from the file when it was found.
        public let sha256: String
        public var id: URL { url }
    }

    public struct Outcome: Sendable, Hashable {
        public let succeeded: Bool
        public let summary: String
    }

    /// What the side holds now, compared with a copy.
    public enum Current: Sendable, Hashable {
        /// FieldCheck's tone, so putting the copy back loses nothing.
        case tone
        /// The copy itself: it's back already.
        case matches
        /// Something else, such as a recording the person made: it's copied off before it's replaced.
        case other(AlbumSide)
    }

    /// The copies level 2 kept in the run folders in `files` that haven't been put back, newest first.
    public static func copies(in files: URL) -> [Copy] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? []
        var copies: [Copy] = []
        for folder in folders where folder.lastPathComponent.hasPrefix("level2-") {
            for side in Album.Side.allCases {
                let url = folder.appending(path: LevelTwo.sideCopy(side))
                guard !FileManager.default.fileExists(atPath: marker(for: url).path(percentEncoded: false)),
                      let data = try? Data(contentsOf: url) else { continue }
                copies.append(Copy(side: side, url: url, folder: folder.lastPathComponent, size: data.count,
                                   sha256: LevelThree.sha256(data)))
            }
        }
        return copies.sorted { ($0.folder, $0.side.rawValue) > ($1.folder, $1.side.rawValue) }
    }

    /// The empty file that says a copy was put back, so it's offered no more: `side_b before level 2.wav.put-back`.
    static func marker(for copy: URL) -> URL {
        copy.deletingLastPathComponent().appending(path: copy.lastPathComponent + ".put-back")
    }

    /// Records that the copy at `url` is back on the OP-1.
    public static func markPutBack(_ url: URL) {
        try? Data().write(to: marker(for: url), options: .withoutOverwriting)
    }

    /// Whether `side` holds exactly FieldCheck's tone now, so `putBack` would write over nothing of the person's.
    /// It reads only.
    public static func holdsTone(_ side: Album.Side, on device: FieldDevice) async throws -> Bool {
        let listed = try await device.album()[side]
        guard listed.isSound, !listed.isEmpty else { return false }
        return LevelTwo.Content.isSideTone(try await device.contents(of: listed.path, maximumSize: 1 << 27))
    }

    /// What the copy's side holds now. It reads only.
    public static func current(_ copy: Copy, on device: FieldDevice) async throws -> Current {
        if try await holdsTone(copy.side, on: device) { return .tone }
        let listed = try await device.album()[copy.side]
        if listed.size == copy.size, LevelThree.sha256(try await device.contents(of: listed.path, maximumSize: 1 << 27)) == copy.sha256 {
            return .matches
        }
        return .other(listed)
    }

    /// The file a warm-up writes and deletes: level 2's drum preset, FieldCheck's own (ADR 0003, section 3).
    static let warmUpFile = LevelTwo.presets[0]

    /// Puts `copy` back as its side with `restoreSide`, as an app would, then reads it back. `trace` is told about
    /// every MTP request in between. Once it's back, the copy is marked, and offered no more.
    ///
    /// - Over FieldCheck's tone, the side is replaced with a confirmation, since nothing of the person's is lost.
    /// - Over anything else, only with `copyingReplacedTo`, a free file URL: the side is copied there and verified
    ///   first, with `.replace(copyingExistingTo:)`. And only if the side is at least as long as the copy: the one
    ///   put-back that worked on the OP-1 went over a longer side recorded on it (PROBE-NOTES.md, 2026-11-16).
    ///
    /// With `warmUp`, a write comes first in the same connection: `drum/user/fieldcheck.wav` is written and deleted.
    public static func putBack(_ copy: Copy, on device: FieldDevice, warmUp: Bool = false, copyingReplacedTo replaced: URL? = nil,
                               trace: @escaping @Sendable (String) -> Void) async -> Outcome {
        // Album writing is off on 1.7.3 (`album.write-again`). This puts back a side FieldCheck overwrote, from its own
        // copy, after a person confirms, so it's let through for this call only.
        await device.overrideAlbumWrites(true)
        await device.session.setTrace(trace)
        let outcome = await writeBack(copy, on: device, warmUp: warmUp, copyingReplacedTo: replaced, trace: trace)
        await device.session.setTrace(nil)
        await device.overrideAlbumWrites(false)
        return outcome
    }

    private static func writeBack(_ copy: Copy, on device: FieldDevice, warmUp: Bool, copyingReplacedTo replaced: URL?,
                                  trace: @escaping @Sendable (String) -> Void) async -> Outcome {
        let path = "mixdown/side_\(copy.side.rawValue).wav"
        let source = "\(copy.folder)/\(copy.url.lastPathComponent)"
        do {
            let data = try Data(contentsOf: copy.url)
            guard LevelThree.sha256(data) == copy.sha256 else {
                return Outcome(succeeded: false, summary: "\(source) changed since it was found, so \(path) wasn't touched.")
            }
            trace("Reading \(path)")
            let conflict: SideConflict
            switch try await current(copy, on: device) {
            case .matches:
                markPutBack(copy.url)
                return Outcome(succeeded: true, summary: "\(path) already holds \(source), so nothing was written.")
            case .tone:
                trace("Confirming \(path)")
                conflict = .replace(confirmed: try await device.prepareToReplace(copy.side))
            case .other(let listed):
                guard let replaced else {
                    return Outcome(succeeded: false, summary: "\(path) doesn't hold FieldCheck's tone, so it wasn't touched.")
                }
                guard listed.size >= data.count else {
                    let need = Duration.seconds((Double(data.count - 44) / 4 / 44_100).rounded(.up))
                    return Outcome(succeeded: false, summary: "\(path) is \(listed.size.formatted()) bytes, shorter than the "
                                   + "copy's \(data.count.formatted()). Only a put-back over a longer recording has worked on the "
                                   + "OP-1, so nothing was written. Record at least \(need.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) "
                                   + "on it on the OP-1, then try again.")
                }
                conflict = .replace(copyingExistingTo: replaced)
            }
            if warmUp {
                guard try await !device.fileExists(at: warmUpFile) else {
                    return Outcome(succeeded: false, summary: "\(warmUpFile) is already on the OP-1, from a run that didn't "
                                   + "finish, so nothing was written. Delete FieldCheck's content first.")
                }
                trace("Warm-up: writing \(warmUpFile)")
                _ = try await device.write(LevelTwo.Content.preset, to: warmUpFile)
                trace("Warm-up: deleting \(warmUpFile)")
                try await device.removeItem(try await device.prepareToRemove(at: warmUpFile))
                trace("Warm-up done")
            }
            trace("Restoring \(path) from \(source)")
            _ = try await device.restoreSide(copy.side, from: copy.url, conflict: conflict)
            trace("Reading \(path) back")
            let read = try await device.contents(of: FilePath(path), maximumSize: 1 << 27)
            guard read == data else {
                return Outcome(succeeded: false, summary: "\(path) was written, but reads back as \(read.count.formatted()) "
                               + "bytes that don't match the copy. The copy is kept.")
            }
            markPutBack(copy.url)
            let kept = replaced.map { " What it held before is kept as \($0.lastPathComponent)." } ?? ""
            return Outcome(succeeded: true, summary: "\(path) was put back from \(source), \(data.count.formatted()) bytes, "
                           + "and reads back byte for byte.\(kept)")
        } catch {
            let fieldError = error as? FieldError
            let changed = fieldError?.changed.map(\.string) ?? []
            let what = if !changed.isEmpty {
                "Changed: \(changed.joined(separator: ", "))."
            } else if fieldError?.code == .disconnected || fieldError?.code == .timedOut {
                "Whether the last request took effect isn't known: the trace shows which one got no answer."
            } else {
                "Nothing on the OP-1 changed."
            }
            return Outcome(succeeded: false, summary: "Putting \(path) back stopped: \(error.localizedDescription) \(what) "
                           + "The copy is kept.")
        }
    }
}
