import CryptoKit
import Foundation
import System

/// What a write does when its path is taken. Replacing comes in step 10 of the plan.
public enum ExistingFile: Sendable, Hashable {
    /// Throw `alreadyExists` and change nothing.
    case fail
}

public struct UploadOptions: Sendable {
    public var existing: ExistingFile
    /// Read the file back and match it by SHA-256 (ADR 0002, safety rule 2). On by default: harmless matters more
    /// than fast.
    public var verify: Bool

    public init(existing: ExistingFile = .fail, verify: Bool = true) {
        self.existing = existing
        self.verify = verify
    }
}

extension FieldDevice {
    /// Writes `data` as a new file at `path`, and returns it as the OP-1 lists it.
    ///
    /// In `synth/user/` and `drum/user/` the OP-1 converts what it receives: it stores AIFC under the name it was
    /// sent, `.wav` included, and may shorten it (to 20 seconds in `drum/user/`). The item returned is the file as
    /// stored, and the read-back checks its audio instead of its bytes: the same format, and the same samples as
    /// the start of what was sent. A preset must be 16-bit PCM, at 44.1 kHz mono or stereo or 22,050 Hz mono.
    ///
    /// Everything is checked before anything is sent: the folder exists, nothing is at the path, the folder allows
    /// the name, and audio is in the format the OP-1 uses there (`WriteRules`). The name is sent lowercase, as the
    /// OP-1 stores names. If the send fails or is cancelled partway, the half-made file is deleted. If the file reads
    /// back differently, it's deleted and `verificationFailed` is thrown. Either way, `changed` lists the file only
    /// if it couldn't be deleted.
    ///
    /// - Throws: `FieldError` with `.notFound` for a missing folder, `.notADirectory`, `.alreadyExists`,
    ///   `.notAllowed`, `.tapeTooLong`, `.insufficientSpace`, `.verificationFailed`, `.disconnected`, `.timedOut` or
    ///   `.deviceRefused`, or `CancellationError`.
    public func write(_ data: Data, to path: FilePath, options: UploadOptions = .init()) async throws -> FieldItem {
        try await send(data, to: path, options: options, progress: nil)
    }

    /// Copies the file at `source` on this device to a new file at `destination` on the OP-1, as `write` does.
    /// The whole file is held in memory, because the data phase is sent in one piece.
    ///
    /// - Parameter progress: Two steps, sending and reading back, or one without verifying.
    /// - Throws: As `write`, and `.localFileFailed` if `source` can't be read.
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

    /// Makes a new tape folder at `path`, which must be directly in `tapes/`, and returns it.
    ///
    /// The name must be one FieldTapeKit makes: at most 15 characters, of A–Z, 0–9, `#`, `-` and space. It's sent
    /// lowercase. One of the 8 tape slots must be free. The OP-1 makes a folder from SendObjectInfo alone
    /// (`write.folder`).
    ///
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
            let (parent, name) = try await parentAndName(of: path)
            let siblings = try await children(of: parent)
            switch options.existing {
            case .fail: try Self.refuseIfTaken(name, in: siblings, parent: parent)
            }
            let newName = name.lowercased()
            let newPath = parent.path.appending(newName)
            let names = try Self.components(of: parent.path).map { $0.lowercased() } + [newName]
            let readBack = try WriteRules(profile: profile).checkFile(names, data: data, path: newPath)
            try Task.checkCancellation()

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

            if options.verify {
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
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
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
