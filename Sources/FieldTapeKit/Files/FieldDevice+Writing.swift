import CryptoKit
import Foundation
import System

/// What a write does when its path is taken.
///
/// MTP can't replace a file in place, so replacing is delete, then send, and the file that's there is covered first
/// by a verified copy or a person's confirmation (ADR 0002, safety rule 1).
public struct ExistingFile: Sendable, Hashable {
    enum Rule: Sendable, Hashable {
        case fail
        case keepingCopy(URL)
        case confirmed(FileDeletion)
    }

    let rule: Rule

    /// Throws `alreadyExists` and changes nothing.
    public static let fail = ExistingFile(rule: .fail)

    /// Copies the file that's there and verifies the copy, matches the file on the OP-1 to it again with a second
    /// read, then replaces it.
    ///
    /// If nothing is at the path, the write goes ahead and no copy is made.
    ///
    /// - Parameter backup: Exactly where to put the copy. It must be free: a taken URL throws `localFileFailed`
    ///   before anything changes.
    /// - Returns: The rule, for ``UploadOptions/existing``.
    public static func replace(keepingCopyAt backup: URL) -> ExistingFile { ExistingFile(rule: .keepingCopy(backup)) }

    /// Replaces a file a person confirmed losing.
    ///
    /// The confirmation is checked as ``FieldDevice/removeItem(_:)`` checks one, and used up. If nothing is at the
    /// path any more, it's `changedSinceConfirmation`.
    ///
    /// - Parameter deletion: From ``FieldDevice/prepareToRemove(at:)``, for the same path.
    /// - Returns: The rule, for ``UploadOptions/existing``.
    public static func replace(confirmed deletion: FileDeletion) -> ExistingFile { ExistingFile(rule: .confirmed(deletion)) }
}

/// How a file is written to the OP-1.
public struct UploadOptions: Sendable {
    /// What to do if the path is taken. ``ExistingFile/fail`` by default.
    public var existing: ExistingFile
    /// Whether to read the file back and match it by SHA-256 (ADR 0002, safety rule 2). On by default: harmless
    /// matters more than fast.
    public var verify: Bool

    /// Creates options for a write.
    ///
    /// - Parameters:
    ///   - existing: What to do if the path is taken. The default changes nothing and throws `alreadyExists`.
    ///   - verify: Whether to read the file back and match it. On by default.
    public init(existing: ExistingFile = .fail, verify: Bool = true) {
        self.existing = existing
        self.verify = verify
    }
}

extension FieldDevice {
    /// Why a write to `mixdown/` is refused on firmware with album writing off (`album.write-again`).
    static let albumWritesOff = "album sides aren't written on this firmware: a side written over MTP hangs the OP-1 when "
        + "it's written again after a reconnect, until it's restarted"

    /// Writes data as a file on the OP-1, and returns it as the OP-1 lists it.
    ///
    /// In `synth/user/` and `drum/user/` the OP-1 converts what it receives: it stores AIFC under the name it was
    /// sent, `.wav` included, and may shorten it (to 20 seconds in `drum/user/` and 6 in `synth/user/`). The item
    /// returned is the file as stored, and the read-back checks its audio instead of its bytes: the same format, and
    /// the same samples as the start of what was sent. A preset must be 16-bit PCM, at 44.1 kHz mono or stereo or
    /// 22,050 Hz mono.
    ///
    /// Everything is checked before anything is sent: the folder exists, nothing is at the path, the folder allows
    /// the name, and audio is in the format the OP-1 uses there (`WriteRules`). The name is sent lowercase, as the
    /// OP-1 stores names. If the send fails or is cancelled partway, the half-made file is deleted. If the file reads
    /// back differently, it's deleted and `verificationFailed` is thrown. Either way, `changed` lists the file only
    /// if it couldn't be deleted.
    ///
    /// A replace checks all of that, and the copy or the confirmation, before deleting the old file. Once it's
    /// deleted, cancelling no longer stops the write, so the path isn't left empty for that, and any failure after
    /// the delete lists the path in `changed`: the old file is gone, and the copy or the confirmation covers it.
    /// There's no automatic retry.
    ///
    /// - Parameters:
    ///   - data: The whole file.
    ///   - path: Where to write it, relative to the device root. Its folder must exist.
    ///   - options: What to do if the path is taken, and whether to read the file back. By default, a taken path
    ///     changes nothing, and the file is read back.
    /// - Returns: The file as the OP-1 lists it after the write.
    /// - Throws: `FieldError` with `.notFound` for a missing folder, `.notADirectory`, `.alreadyExists`,
    ///   `.isADirectory` for a folder at the path, `.notAllowed`, `.tapeTooLong`, `.insufficientSpace`,
    ///   `.verificationFailed`, `.changedSinceConfirmation`, `.confirmationAlreadyUsed`, `.localFileFailed` for the
    ///   copy, `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func write(_ data: Data, to path: FilePath, options: UploadOptions = .init()) async throws -> FieldItem {
        try await send(data, to: path, options: options, progress: nil)
    }

    /// Copies a file from this device to the OP-1, as ``write(_:to:options:)`` writes one.
    ///
    /// The whole file is held in memory, because the data phase is sent in one piece.
    ///
    /// - Parameters:
    ///   - source: The local file.
    ///   - destination: Where to write it on the OP-1, relative to the device root. Its folder must exist.
    ///   - options: As for ``write(_:to:options:)``.
    ///   - progress: Two steps, sending and reading back, or one without verifying.
    /// - Returns: The file as the OP-1 lists it after the write.
    /// - Throws: As ``write(_:to:options:)``, and `.localFileFailed` if `source` can't be read.
    public func copyItem(at source: URL, to destination: FilePath, options: UploadOptions = .init(),
                         progress: consuming Subprogress? = nil) async throws -> FieldItem {
        var manager: ProgressManager?
        switch consume progress {
        case .some(let progress): manager = progress.start(totalCount: options.verify ? 2 : 1)
        case .none: break
        }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw FieldError(.localFileFailed, path: destination, underlying: error)
        }
        return try await send(data, to: destination, options: options, progress: manager)
    }

    /// Makes a new, empty tape folder on the OP-1, and returns it.
    ///
    /// The name must be one FieldTapeKit makes: at most 12 characters, the most the OP-1 keeps, of A–Z, 0–9, `#`,
    /// `-` and space. It's sent lowercase. One of the 8 tape slots must be free. The OP-1 makes a folder from
    /// SendObjectInfo alone (`write.folder`). To make a tape with its `tape.json`, use
    /// ``createTape(named:type:)``.
    ///
    /// - Parameter path: The new folder, directly in `tapes/`.
    /// - Returns: The folder as the OP-1 lists it.
    /// - Throws: `FieldError` with `.notAllowed`, `.invalidName`, `.alreadyExists`, `.tapeLimitReached`,
    ///   `.insufficientSpace`, `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func createDirectory(at path: FilePath) async throws -> FieldItem {
        do {
            let (parent, name) = try await parentAndName(of: path)
            try WriteRules(profile: profile).checkFolder(Self.components(of: path).map { $0.lowercased() }, path: path)
            let siblings = try await children(of: parent)
            try Self.refuseIfTaken(name, in: siblings, parent: parent)
            if siblings.count(where: { $0.info.isFolder }) >= profile.maximumTapes {
                throw FieldError(.tapeLimitReached, path: path)
            }
            try Task.checkCancellation()
            let newName = name.lowercased()
            let dataset = PTPObjectInfo.dataset(storageID: storageID, format: PTPObjectFormat.association, size: 0,
                                                parent: parent.handle, filename: newName,
                                                associationType: PTPAssociationType.genericFolder)
            let handle = try await session.sendObjectInfo(storage: storageID, parent: parent.handle, dataset: dataset)
            let newPath = parent.path.appending(newName)
            do {
                return FieldItem(path: newPath, info: try await session.objectInfo(handle))
            } catch {
                throw (FieldError.wrapping(error, path: newPath) as? FieldError)?.adding(changed: [newPath]) ?? error
            }
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    // MARK: Sending

    private func send(_ data: Data, to path: FilePath, options: UploadOptions,
                      progress: ProgressManager?) async throws -> FieldItem {
        do {
            let lowered = try Self.components(of: path).map { $0.lowercased() }
            if lowered.count == 2, lowered[0] == "mixdown", profile.albumFiles.required.contains(lowered[1]), !albumWritesAllowed {
                throw FieldError(.notAllowed, path: path, reason: Self.albumWritesOff)
            }
            let (parent, name) = try await parentAndName(of: path)
            let siblings = try await children(of: parent)
            let newName = name.lowercased()
            let newPath = parent.path.appending(newName)
            let existing = siblings.first { $0.info.filename.lowercased() == newName }
                .map { Located(handle: $0.handle, path: parent.path.appending($0.info.filename), info: $0.info) }
            if case .fail = options.existing.rule, let existing {
                throw FieldError(.alreadyExists, path: existing.path)
            }
            let names = try Self.components(of: parent.path).map { $0.lowercased() } + [newName]
            let readBack = try WriteRules(profile: profile).checkFile(names, data: data, path: newPath)

            try await coverReplacing(existing, at: newPath, as: options.existing.rule)
            try Task.checkCancellation()

            guard let existing else {
                return try await sendNew(data, parent: parent, at: newPath, readBack: readBack, verify: options.verify,
                                         progress: progress)
            }
            if case .confirmed(let confirmation) = options.existing.rule { usedConfirmations.insert(confirmation.id) }
            try await session.deleteObject(existing.handle)
            // The old file is gone, so the write runs to the end whatever happens to the caller's task: an
            // unstructured task isn't cancelled with it.
            let send = Task {
                try await sendNew(data, parent: parent, at: newPath, readBack: readBack, verify: options.verify,
                                  progress: progress)
            }
            do {
                return try await send.value
            } catch {
                let wrapped = FieldError.wrapping(error, path: newPath)
                guard let wrapped = wrapped as? FieldError else { throw wrapped }
                throw wrapped.changed.contains(existing.path) ? wrapped : wrapped.adding(changed: [existing.path])
            }
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Checks that the file at the path is covered before it's replaced: copied and verified, or confirmed by a
    /// person and unchanged since. Nothing on the OP-1 changes here.
    private func coverReplacing(_ existing: Located?, at path: FilePath, as rule: ExistingFile.Rule) async throws {
        switch rule {
        case .fail:
            return
        case .keepingCopy(let backup):
            guard let existing, let info = existing.info else { return }
            guard !info.isFolder else { throw FieldError(.isADirectory, path: existing.path) }
            if FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
                throw FieldError(.localFileFailed, path: existing.path,
                                 underlying: CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: backup.path]))
            }
            let copy = try await verifiedCopy(of: existing.path, to: backup)
            guard copy.url == backup else {
                // The URL was taken after the check, so the copy went elsewhere and the caller wouldn't find it.
                try? FileManager.default.removeItem(at: copy.url)
                throw FieldError(.localFileFailed, path: existing.path,
                                 underlying: CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: backup.path]))
            }
            // The copy is of the file as it was. If the OP-1 lists it differently now, the copy doesn't cover it.
            guard let after = try await locate(existing.path), after.handle == existing.handle,
                  after.info?.compressedSize == info.compressedSize else {
                throw FieldError(.verificationFailed, path: existing.path)
            }
            try await matchAgain(after.handle, at: existing.path, to: copy.sha256)
        case .confirmed(let confirmation):
            let confirmed = confirmation.item.path
            guard !usedConfirmations.contains(confirmation.id) else { throw FieldError(.confirmationAlreadyUsed, path: confirmed) }
            guard confirmed.string.lowercased() == path.string.lowercased() else {
                throw FieldError(.notAllowed, path: path, reason: "the confirmation is for \(confirmed)")
            }
            guard !confirmation.item.isDirectory else { throw FieldError(.isADirectory, path: confirmed) }
            guard confirmation.deviceID == id, let existing, let info = existing.info,
                  FieldItem(path: existing.path, info: info) == confirmation.item else {
                throw FieldError(.changedSinceConfirmation, path: confirmed)
            }
        }
    }

    /// Sends a file to a path that's free, reads it back, and returns it. A file that doesn't come out right is
    /// deleted, and `changed` lists it only if that fails.
    private func sendNew(_ data: Data, parent: Located, at newPath: FilePath, readBack: WriteRules.ReadBack,
                         verify: Bool, progress: ProgressManager?) async throws -> FieldItem {
        let newName = newPath.lastComponent!.string
        let dataset = PTPObjectInfo.dataset(storageID: storageID, format: WriteRules.format(of: newName),
                                            size: UInt32(data.count), parent: parent.handle, filename: newName)
        let handle = try await session.sendObjectInfo(storage: storageID, parent: parent.handle, dataset: dataset)
        do {
            try Task.checkCancellation()
            try await session.sendObject(data)
        } catch {
            throw await cleanUp(handle, at: newPath, after: error)
        }
        progress?.complete(count: 1)

        if verify {
            let stored: Data
            do {
                stored = try await session.object(handle)
            } catch {
                throw await cleanUp(handle, at: newPath, after: error)
            }
            if let mismatch = Self.mismatch(stored, sent: data, as: readBack) {
                let error = FieldError(.verificationFailed, path: newPath, reason: mismatch)
                throw await cleanUp(handle, at: newPath, after: error)
            }
            progress?.complete(count: 1)
        }
        return FieldItem(path: newPath, info: try await session.objectInfo(handle))
    }

    /// Why the stored file doesn't match what was sent, or nil if it does.
    private static func mismatch(_ stored: Data, sent: Data, as readBack: WriteRules.ReadBack) -> String? {
        switch readBack {
        case .exact:
            return SHA256.hash(data: stored) == SHA256.hash(data: sent) ? nil : "it read back differently"
        case .preset(let audio):
            do {
                return try PCMAudio(stored).mismatch(asStoredFrom: audio)
            } catch {
                return "what the OP-1 stored isn't audio: \(error)"
            }
        }
    }

    /// Deletes a file this call just made and that didn't come out right, then returns the error to throw. If the
    /// delete fails, the error says the file is still there (ADR 0002, safety rule 6).
    private func cleanUp(_ handle: UInt32, at path: FilePath, after error: any Error) async -> any Error {
        let wrapped = FieldError.wrapping(error, path: path)
        do {
            try await session.deleteObject(handle)
            return wrapped
        } catch {
            if let wrapped = wrapped as? FieldError { return wrapped.adding(changed: [path]) }
            // Cancelled, but the half-made file couldn't be deleted: that has to be said.
            return (FieldError.wrapping(error, path: path) as? FieldError)?.adding(changed: [path]) ?? wrapped
        }
    }

    /// The folder `path` goes in, which must exist, and the new item's name.
    private func parentAndName(of path: FilePath) async throws -> (Located, String) {
        let names = try Self.components(of: path)
        guard let name = names.last else { throw FieldError(.notAllowed, path: path, reason: "it's the root") }
        let parentPath = FilePath(names.dropLast().joined(separator: "/"))
        guard let parent = try await locate(parentPath) else { throw FieldError(.notFound, path: parentPath) }
        guard parent.isDirectory else { throw FieldError(.notADirectory, path: parent.path) }
        return (parent, name)
    }

    private static func refuseIfTaken(_ name: String, in siblings: [(handle: UInt32, info: PTPObjectInfo)],
                                      parent: Located) throws {
        let lowered = name.lowercased()
        if let taken = siblings.first(where: { $0.info.filename.lowercased() == lowered }) {
            throw FieldError(.alreadyExists, path: parent.path.appending(taken.info.filename))
        }
    }
}
